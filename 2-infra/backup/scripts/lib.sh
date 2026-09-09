#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# lib.sh — 备份单元的共享部分：读 lock、解析口令来源、上色。
# 只被 source，不单独执行。
# ─────────────────────────────────────────────────────────────────────────────

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_DIR="$(cd "$LIB_DIR/.." && pwd)"
ROOT="$(cd "$UNIT_DIR/../.." && pwd)"
LOCK="$ROOT/0-meta/derived.lock"

c_err()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }
c_warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }
c_ok()   { printf '\033[32m%s\033[0m\n' "$*"; }
log()    { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

[ -f "$LOCK" ] || { c_err "找不到 $LOCK —— 先跑 new plan --apply"; exit 2; }
lock_get() { awk -F' = ' -v k="$1" '$1==k{sub(/^[^=]* = /,"");print;exit}' "$LOCK"; }

# 目的地名 → 仓库地址。占位符直接挡住：让它跑下去只会得到一个语义不明的
# 连接错误，而真正的问题是「这个目的地还没决定」。
dest_repo() {
  local dest="$1" repo
  repo="$(lock_get "backup.dest.${dest}.repo")"
  [ -n "$repo" ] || { c_err "derived.lock 里没有目的地 ${dest}（有：$(lock_get backup.destinations)）"; return 2; }
  case "$repo" in
    *REPLACE-ME*)
      c_err "目的地 ${dest} 的 repo 还是占位符：${repo}"
      c_err "  在 0-meta/policy.yaml 的 backup.destinations 里填好，再跑 new plan --apply。"
      return 2 ;;
  esac
  printf '%s' "$repo"
}

# 默认目的地 = schedule 为 daily 的那个
default_dest() {
  local d
  for d in $(lock_get backup.destinations); do
    [ "$(lock_get "backup.dest.${d}.schedule")" = daily ] && { printf '%s' "$d"; return 0; }
  done
  return 1
}

# ── 口令 ─────────────────────────────────────────────────────────────────────
# 口令必须存在于「你要防的那台机器」之外。典型的死循环是：Mac 挂了 → 要恢复
# → 需要口令 → 口令在 Mac 上。所以这里只接受一个引用（由 policy 声明），
# 把引用翻译成取值命令，从不把口令写进任何文件。
#
# 返回的是**命令**而不是口令本身，交给 restic 的 RESTIC_PASSWORD_COMMAND 执行——
# 口令因此不经过本单元任何脚本的环境变量，也不出现在 ps 输出里。
#
# password_source 是机器取值（无人值守必须本机可取）。
# password_recovery 是人取值（必须含离机来源）。换来源 = 改 policy + new plan --apply。
# 下面这张表是唯一需要动脚本的地方，而且只在支持一个全新的库时才动。
password_command() {
  local src="$1" rest svc acct
  case "$src" in
    op://*)       printf "op read %q" "$src" ;;
    keychain://*) rest="${src#keychain://}"; svc="${rest%%/*}"; acct="${rest#*/}"
                  printf "security find-generic-password -s %q -a %q -w" "$svc" "$acct" ;;
    bw://*)       printf "bw get password %q" "${src#bw://}" ;;
    pass://*)     printf "pass show %q" "${src#pass://}" ;;
    file://*)     printf "cat %q" "${src#file://}" ;;
    cmd://*)      printf '%s' "${src#cmd://}" ;;
    *) return 1 ;;
  esac
}

password_tool() {
  case "$1" in
    op://*) echo op ;; bw://*) echo bw ;; pass://*) echo pass ;;
    keychain://*) echo security ;; *) echo "" ;;
  esac
}

# 成功时导出 RESTIC_PASSWORD_COMMAND
require_password() {
  local src cmd tool
  src="$(lock_get backup.password_source)"
  [ -n "$src" ] || { c_err "derived.lock 里 backup.password_source 为空"; return 2; }

  cmd="$(password_command "$src")" || {
    c_err "看不懂的口令来源：${src}"
    c_err "  支持的前缀：op:// keychain:// bw:// pass:// file:// cmd://"
    return 2
  }

  tool="$(password_tool "$src")"
  if [ -n "$tool" ] && ! command -v "$tool" >/dev/null 2>&1; then
    c_err "口令来源是 ${src}，但本机没有 ${tool}"
    c_err "  装上它，或在 0-meta/policy.yaml 改 backup.password_source 换一个口令库，"
    c_err "  然后 new plan --apply。"
    return 2
  fi

  # 提前验一次。等 restic 报 wrong password 再回头查，中间隔着一次网络往返。
  #
  # 判据是「有没有取到东西」，不是「退出码是不是 0」。bw 在非交互环境里会试图
  # 弹出主口令提示，然后崩掉——但仍然返回 0。只看退出码的话预检会放行，
  # 最后由 restic 报一句「空口令不允许」，而真正的原因是 vault 没解锁。
  local probe
  probe="$(eval "$cmd" 2>/dev/null | head -1)" || true
  if [ -z "$probe" ]; then
    c_err "取口令失败（命令没有输出）：${cmd}"
    case "$src" in
      bw://*)
        c_err "  Bitwarden 需要已解锁的 session。当前状态：$(bw status 2>/dev/null | jq -r '.status' 2>/dev/null || echo '未知')"
        c_err "  交互时：export BW_SESSION=\"\$(bw unlock --raw)\""
        c_err "  无人值守应改用 keychain:// —— 见 2-infra/backup/README.md「无人值守」一节。" ;;
      keychain://*)
        c_err "  Keychain 里没有这一项，或当前会话无权读取。"
        c_err "  装一次：2-infra/backup/scripts/install-unattended-password.sh"
        c_err "  人恢复走：$(lock_get backup.password_recovery)" ;;
      *)
        c_err "  确认 ${src} 这一项存在且当前环境能读到。"
        c_err "  人恢复走：$(lock_get backup.password_recovery)" ;;
    esac
    return 2
  fi

  export RESTIC_PASSWORD_COMMAND="$cmd"
}

# ── restic 运行环境 ──────────────────────────────────────────────────────────
restic_env() {
  export XDG_CACHE_HOME="${HOME}/Library/Caches/g-lite-backup/cache"
  # Google Drive 的 API 配额很容易打满，打满之后 restic 会一路重试到超时。
  # 这几个值是 v1 踩出来的，换 B2 / R2 时可以放宽。
  export RCLONE_TPSLIMIT="${RCLONE_TPSLIMIT:-2}"
  export RCLONE_TPSLIMIT_BURST="${RCLONE_TPSLIMIT_BURST:-2}"
  export RCLONE_DRIVE_PACER_MIN_SLEEP="${RCLONE_DRIVE_PACER_MIN_SLEEP:-500ms}"
  export RCLONE_DRIVE_PACER_BURST="${RCLONE_DRIVE_PACER_BURST:-5}"
}

BACKUP_TAG=workspace-cold
