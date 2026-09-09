#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# backup-cold.sh — restic 冷备。路径由策略生成，口令来源可插拔。
#
# 本脚本里没有任何路径常量、仓库地址、保留期数字。全部读自 0-meta/derived.lock，
# 而 lock 由 policy.yaml 推导。换目的地、改保留期、换口令库，都是改 policy 再跑
# `new plan --apply`，不是回来改这个文件。
#
# 每次运行都会先重跑 gen-restic-args.sh。清单不可能过期，因为它不被缓存。
#
# 用法：
#   backup-cold.sh [--dest <name>] --list        只算清单，不碰仓库，不要口令
#   backup-cold.sh [--dest <name>]               dry-run（默认）
#   backup-cold.sh [--dest <name>] --apply       真备份 + 保留期 + 完整性检查
#   backup-cold.sh [--dest <name>] --snapshots   列快照
#   backup-cold.sh [--dest <name>] --init        初始化一个新仓库
#
# --dest 默认取 backup.destinations 里 schedule=daily 的那个。
# ─────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SELF_DIR/lib.sh"

GEN="$SELF_DIR/gen-restic-args.sh"
OUT_DIR="$UNIT_DIR/_out"

mode=dry-run
dest=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dest)      dest="${2:?--dest 后面要跟目的地名字}"; shift 2 ;;
    --list)      mode=list; shift ;;
    --dry-run)   mode=dry-run; shift ;;
    --apply)     mode=apply; shift ;;
    --snapshots) mode=snapshots; shift ;;
    --init)      mode=init; shift ;;
    -h|--help)   sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

command -v restic >/dev/null 2>&1 || { c_err "缺 restic。brew install restic"; exit 2; }

[ -n "$dest" ] || dest="$(default_dest)" \
  || { c_err "derived.lock 里没有 schedule=daily 的目的地，用 --dest 指定"; exit 2; }

REPO="$(dest_repo "$dest")" || exit 2
case "$REPO" in
  rclone:*) command -v rclone >/dev/null 2>&1 || { c_err "目的地走 rclone 后端，但缺 rclone"; exit 2; } ;;
esac

restic_env
export RESTIC_REPOSITORY="$REPO"
LOG_DIR="${HOME}/Library/Logs/g-lite-backup"

# 保留期是 --group-by host,tags 算的，所以主机名必须稳定。
# 本机三个来源互不相同（LocalHostName=qiaoendeMacBook-Air、hostname -s=qiaoendeAir、
# ComputerName=中文），一旦某次换了个来源，就会凭空多出一个保留期分组：
# 旧分组不再有新快照进来，它的 keep-last 会被永久冻结不再清理。
# 所以取不到就直接失败，不做静默兜底——兜底成另一个名字比失败更糟。
HOST_TAG="$(scutil --get LocalHostName 2>/dev/null || true)"
if [ -z "$HOST_TAG" ]; then
  c_err "取不到 LocalHostName（scutil）。"
  c_err "  不用 hostname -s 兜底：那是另一个值，会让 restic 的保留期分组分裂。"
  c_err "  查一下 scutil --get LocalHostName 为什么失败。"
  exit 1
fi

# ── 清单 ─────────────────────────────────────────────────────────────────────
# 每次都重算。缓存一份清单就等于给它一个过期的机会，而清单过期正是
# backup_closure 这项审计存在的理由。
log "重算备份清单"
"$GEN" >&2
FILES_FROM="$OUT_DIR/files-from.txt"
EXCLUDE="$OUT_DIR/exclude.txt"

echo
echo "目的地   ${dest}"
echo "仓库     ${REPO}"
echo "口令     $(lock_get backup.password_source)"
echo "恢复     $(lock_get backup.password_recovery)"
echo "模式     ${mode}"
echo

[ "$mode" = list ] && exit 0

require_password || exit 2

restic_backup() {
  local args=(
    backup
    --host "$HOST_TAG"
    --tag "$BACKUP_TAG"
    --files-from "$FILES_FROM"
    --exclude-file "$EXCLUDE"
  )
  [ "$mode" = dry-run ] && args+=(--dry-run --verbose)
  restic "${args[@]}"
}

case "$mode" in
  init)
    if restic cat config >/dev/null 2>&1; then
      c_warn "仓库已存在，无需初始化：${REPO}"
    else
      log "初始化仓库"
      restic init
      c_ok "✓ 已初始化"
    fi
    ;;

  snapshots)
    restic snapshots --compact
    ;;

  dry-run)
    restic cat config >/dev/null 2>&1 || {
      c_err "仓库不存在或连不上：${REPO}"
      c_err "  首次使用先跑：$(basename "$0") --dest ${dest} --init"
      exit 1
    }
    restic_backup
    ;;

  apply)
    mkdir -p "$LOG_DIR" "$XDG_CACHE_HOME"
    LOG_FILE="${LOG_DIR}/$(date -u +%Y%m%dT%H%M%SZ)-${dest}.log"
    exec > >(tee -a "$LOG_FILE") 2>&1
    log "开始冷备 → ${dest}"
    restic cat config >/dev/null 2>&1 || { c_err "仓库不存在，先 --init"; exit 1; }
    restic_backup

    log "应用保留期"
    restic forget \
      --keep-last    "$(lock_get backup.retention.keep_last)" \
      --keep-weekly  "$(lock_get backup.retention.keep_weekly)" \
      --keep-monthly "$(lock_get backup.retention.keep_monthly)" \
      --group-by host,tags --prune

    log "最近快照"
    restic snapshots latest --compact

    log "完整性检查"
    restic check

    c_ok "✓ 冷备完成"
    log "日志：${LOG_FILE}"
    ;;
esac
