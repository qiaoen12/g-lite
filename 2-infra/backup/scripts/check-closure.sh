#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# check-closure.sh — 审计第 4 项 backup_closure
#
# 拿 restic 真实快照里的路径集合，和策略推导出的应备份集合做差集。
# 非空即失败。这是闭环校验，能抓到三种「配置看起来是对的」：
#
#   配置写对但从没跑过   → 快照里根本没有这条路径
#   跑了但失败           → 最近快照的时间对不上频率
#   清单过期             → 策略加了一个域，快照里还是旧的那几条
#
# v1 的审计报告写着「漂移 0 项、错误 0 项」，而当时 60-dev、80-data、80-research
# 三个目录是零副本。原因是它只检查了配置文件的内容，没有检查仓库里实际有什么。
#
# 两层判据，缺一不可：
#
#   源路径集合   快照的 paths 字段 vs 生成器算出的 files-from
#                抓「worktree 根压根没进备份」这类
#
#   域是否在里面 快照内容里逐个找 backup.include 的域
#                源是备份根一条路径，所以上一层会恒为空——只比源路径的话，
#                「5-record 因为卷没挂载而整域缺席」查不出来。
#
# 还回答不了的：域里某个文件有没有被 exclude 误伤。那要逐文件比对，
# 是同一档位的下一步。
#
# 用法：
#   check-closure.sh              检查所有已配置的目的地
#   check-closure.sh --dest <n>   只检查一个
# ─────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SELF_DIR/lib.sh"

GEN="$SELF_DIR/gen-restic-args.sh"

only_dest=""
case "${1:-}" in
  "")      ;;
  --dest)  only_dest="${2:?--dest 后面要跟目的地名字}" ;;
  -h|--help) sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *)       echo "未知参数：$1" >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { c_err "缺 jq"; exit 2; }
command -v restic >/dev/null 2>&1 || { c_err "缺 restic"; exit 2; }
restic_env
require_password || exit 2

# 应备份集合。跑生成器而不是读上次的产物——读缓存就等于放过「清单过期」这一类。
"$GEN" >/dev/null 2>&1 || { c_err "生成应备份集合失败，先单独跑 $GEN 看错在哪"; exit 1; }
EXPECTED="$(sort -u "$UNIT_DIR/_out/files-from.txt")"

fail=0
checked=0

for dest in $(lock_get backup.destinations); do
  [ -n "$only_dest" ] && [ "$dest" != "$only_dest" ] && continue

  # 还没决定的目的地不算失败，但也绝不算通过——它是一个已声明却零副本的承诺。
  repo="$(dest_repo "$dest" 2>/dev/null)" || {
    c_warn "  ⚠ ${dest}：repo 仍是占位符，该目的地当前零副本"
    continue
  }

  checked=$((checked + 1))
  echo "  · ${dest}  ${repo}"
  bad=0

  snap_json="$(RESTIC_REPOSITORY="$repo" \
    restic snapshots latest --tag "$BACKUP_TAG" --json 2>/dev/null)" || snap_json=""

  if [ -z "$snap_json" ] || [ "$(jq -r 'length' <<<"$snap_json" 2>/dev/null || echo 0)" = 0 ]; then
    c_err "  ✗ ${dest}：拿不到快照。仓库连不上、口令不对，或者从来没跑过备份。"
    fail=1
    continue
  fi

  ACTUAL="$(jq -r '.[0].paths[]' <<<"$snap_json" | sort -u)"
  SNAP_TIME="$(jq -r '.[0].time' <<<"$snap_json")"

  missing="$(comm -23 <(printf '%s\n' "$EXPECTED") <(printf '%s\n' "$ACTUAL"))"
  extra="$(comm -13 <(printf '%s\n' "$EXPECTED") <(printf '%s\n' "$ACTUAL"))"

  if [ -n "$missing" ]; then
    c_err "  ✗ ${dest}：应备份的源路径不在最近快照里"
    printf '%s\n' "$missing" | sed 's/^/      /' >&2
    bad=1
  fi
  if [ -n "$extra" ]; then
    # 不是硬失败：策略缩小范围之后，旧快照里多出来的路径是正常的历史。
    c_warn "  ⚠ ${dest}：快照里有但策略已不再要求（策略缩小过？）"
    printf '%s\n' "$extra" | sed 's/^/      /' >&2
  fi

  # 第二层：逐个域确认它真的在快照内容里。
  # 只列一次，深度 1 就够——域缺席是整域缺席，不会只少半个。
  listing="$(RESTIC_REPOSITORY="$repo" restic ls latest --tag "$BACKUP_TAG" 2>/dev/null)" || listing=""
  if [ -z "$listing" ]; then
    c_err "  ✗ ${dest}：列不出快照内容"
    bad=1
  else
    dom_missing=""
    for dom in $(lock_get backup.include); do
      grep -qxF "${ROOT}/${dom}" <<<"$listing" || dom_missing="$dom_missing $dom"
    done
    if [ -n "$dom_missing" ]; then
      c_err "  ✗ ${dest}：以下域声明为 backup:required，但快照里没有"
      c_err "     ${dom_missing}"
      c_err "     （卷没挂载？exclude 写过头了？）"
      bad=1
    fi
  fi

  # 保留期按 --group-by host,tags 分组。仓库里出现第二个主机名意味着分组已经分裂：
  # 旧分组不再有新快照进来，它的 keep-last 会被永久冻结，占着空间不再清理。
  hosts="$(RESTIC_REPOSITORY="$repo" restic snapshots --tag "$BACKUP_TAG" --json 2>/dev/null \
    | jq -r '.[].hostname' 2>/dev/null | sort -u)"
  n_hosts="$(printf '%s\n' "$hosts" | grep -c . || true)"
  if [ "${n_hosts:-0}" -gt 1 ]; then
    c_warn "  ⚠ ${dest}：仓库里有 ${n_hosts} 个主机名，保留期分组已分裂"
    printf '%s\n' "$hosts" | sed 's/^/      /' >&2
    c_warn "      改过机器名，或者某次跑备份时主机名取自另一个来源。"
    c_warn "      旧分组不会再被清理——确认哪个是当前的，把另一个 restic forget 掉。"
  fi

  # 频率对不上说明「跑了但失败」或者调度根本没装
  sched="$(lock_get "backup.dest.${dest}.schedule")"
  case "$sched" in daily) max_h=48 ;; weekly) max_h=336 ;; *) max_h=720 ;; esac
  snap_epoch="$(date -j -f '%Y-%m-%dT%H:%M:%S' "${SNAP_TIME:0:19}" +%s 2>/dev/null || echo 0)"
  age_h="?"
  if [ "$snap_epoch" != 0 ]; then
    age_h=$(( ( $(date +%s) - snap_epoch ) / 3600 ))
    if [ "$age_h" -gt "$max_h" ]; then
      c_err "  ✗ ${dest}：最近快照 ${age_h} 小时前，频率声明是 ${sched}（上限 ${max_h} 小时）"
      bad=1
    fi
  fi

  # 一个目的地只出一个结论。分项已经各自报过，这里不重复。
  if [ "$bad" = 0 ]; then
    c_ok "  ✓ ${dest}：源路径与各域齐全，最近快照 ${age_h} 小时前"
  else
    fail=1
  fi
done

if [ "$checked" = 0 ]; then
  c_err "  ✗ 没有任何可检查的目的地——全部还是占位符"
  exit 1
fi
exit "$fail"
