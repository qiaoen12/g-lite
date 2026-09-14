#!/usr/bin/env bash
# Issue #14 R3 adapter fixture：只允许 Guard staging stale 触发一次 scoped
# refresh；其它失败域、candidate 落后、HEAD 改变都不得隐式同步或重试。
set -Eeuo pipefail
export LC_COLLATE=C
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "✗ 不在 git 工作树" >&2; exit 1; }
. "$ROOT/0-meta/lib/new/core.sh"
. "$ROOT/0-meta/lib/new/task.sh"
. "$ROOT/.agents/skills/z-lib.sh"
. "$ROOT/.agents/skills/zmerge/scripts/merge-lib.sh"
trap tmp_cleanup EXIT

fail=0
pass=0
ok() { pass=$((pass + 1)); }
bad() { echo "✗ $*" >&2; fail=$((fail + 1)); }
expect_eq() { if [ "$2" = "$3" ]; then ok; else bad "$1: 期望 [$2] 实际 [$3]"; fi; }
expect_true() { if eval "$2"; then ok; else bad "$1"; fi; }
run_capture() {
  local __outvar="$1" __rcvar="$2"; shift 2
  local out rc=0
  out="$($@ 2>&1)" || rc=$?
  printf -v "$__outvar" '%s' "$out"
  printf -v "$__rcvar" '%s' "$rc"
}

TDIR=""
tmp_mkd TDIR zmerge-guard-recovery
COUNT="$TDIR/counts"
mkdir -p "$COUNT"
count() { cat "$COUNT/$1" 2>/dev/null || printf '0\n'; }
bump() { local n; n="$(count "$1")"; printf '%s\n' "$((n + 1))" > "$COUNT/$1"; }
reset_counts() { printf '0\n' > "$COUNT/deliver"; printf '0\n' > "$COUNT/refresh"; printf '0\n' > "$COUNT/preflight"; }

Z_WT="$ROOT"
Z_MAIN=main
Z_HEAD=head-fixed
Z_NUMBER=14
FAILURE_DOMAIN=guard-staging
PREFLIGHT_MODE=ok
DELIVER_MODE=stale
REFRESH_MODE=refreshed

# These replacements are intentionally limited to the adapter boundary. The
# actual guard-issue14 fixture above exercises guard_refresh_staging_for_merge
# against real bare repositories and durable transaction directories.
zmerge_deliver_review() {
  local n
  bump deliver
  n="$(count deliver)"
  case "$DELIVER_MODE:$n" in
    stale:1)
      printf '%s\n' 'GitHub main 已前进，staging 未同步，拒绝使用陈旧 contract' >&2
      return 1
      ;;
    route:*)
      printf '%s\n' 'git-guard: route failed' >&2
      return 1
      ;;
    *)
      printf '%s\n' 'review-ok'
      return 0
      ;;
  esac
}

guard_classify_push_failure() { printf '%s\n' "$FAILURE_DOMAIN"; }

guard_refresh_staging_for_merge() {
  bump refresh
  case "$REFRESH_MODE" in
    refreshed|noop) printf '%s\n' "$REFRESH_MODE"; return 0 ;;
    blocked) printf '%s\n' 'refresh blocked' >&2; return 1 ;;
    *) printf '%s\n' "$REFRESH_MODE"; return 0 ;;
  esac
}

zmerge_guard_recovery_preflight() {
  bump preflight
  case "$PREFLIGHT_MODE" in
    ok) return 0 ;;
    behind) err_code z.main_ahead 'candidate 真落后；下一步：new z sync'; return 1 ;;
    head-changed) err_code z.pr_head_changed 'candidate HEAD 已改变；需要新的 zreview'; return 1 ;;
    review-invalid) err_code z.no_passing_review '当前 HEAD 没有有效 Review'; return 1 ;;
    *) err_code z.guard_recovery_preflight 'merge gates 未通过'; return 1 ;;
  esac
}

# ── stale → 一次 refresh + 两次 preflight + 一次 retry ───────────────────
reset_counts
DELIVER_MODE=stale
FAILURE_DOMAIN=guard-staging
PREFLIGHT_MODE=ok
REFRESH_MODE=refreshed
run_capture A1_OUT A1_RC zmerge_deliver_review_with_guard_recovery
expect_eq 'R3 adapter stale recovery 成功' 0 "$A1_RC"
expect_eq 'R3 adapter stale 只 retry 一次' 2 "$(count deliver)"
expect_eq 'R3 adapter stale 只 refresh 一次' 1 "$(count refresh)"
expect_eq 'R3 adapter stale 前后复读 preflight' 2 "$(count preflight)"
expect_true 'R3 adapter stale retry 输出成功' 'printf "%s\n" "$A1_OUT" | grep -Fq "review-ok"'

# staging 已经追平时，noop 仍可在相同授权内完成一次 retry。
reset_counts
DELIVER_MODE=stale
REFRESH_MODE=noop
run_capture A2_OUT A2_RC zmerge_deliver_review_with_guard_recovery
expect_eq 'R3 adapter noop recovery 成功' 0 "$A2_RC"
expect_eq 'R3 adapter noop 只 retry 一次' 2 "$(count deliver)"
expect_eq 'R3 adapter noop 只 refresh 一次' 1 "$(count refresh)"

# Guard route / network 等其它域不具备 stale 证明，不能 refresh。
reset_counts
DELIVER_MODE=route
FAILURE_DOMAIN=guard-route
run_capture A3_OUT A3_RC zmerge_deliver_review_with_guard_recovery
expect_true 'R3 adapter Guard route 不自动 retry' '[ "$A3_RC" -ne 0 ] && [ "$(count deliver)" = 1 ] && [ "$(count refresh)" = 0 ]'
expect_true 'R3 adapter Guard route 保留原始域' 'printf "%s\n" "$A3_OUT" | grep -Fq "route failed"'

# candidate 真落后：preflight 明确指向 zsync，不能把 staging refresh 当同步。
reset_counts
DELIVER_MODE=stale
FAILURE_DOMAIN=guard-staging
PREFLIGHT_MODE=behind
run_capture A4_OUT A4_RC zmerge_deliver_review_with_guard_recovery
expect_true 'R3 adapter candidate behind fail-closed' '[ "$A4_RC" -ne 0 ] && [ "$(count refresh)" = 0 ] && [ "$(count deliver)" = 1 ]'
expect_true 'R3 adapter candidate behind 指向 zsync' 'printf "%s\n" "$A4_OUT" | grep -Fq "z sync"'

# Review HEAD 改变：必须要求新的 Review，不能 refresh 后沿用旧授权。
reset_counts
PREFLIGHT_MODE=head-changed
run_capture A5_OUT A5_RC zmerge_deliver_review_with_guard_recovery
expect_true 'R3 adapter HEAD changed 不 refresh' '[ "$A5_RC" -ne 0 ] && [ "$(count refresh)" = 0 ] && [ "$(count deliver)" = 1 ]'
expect_true 'R3 adapter HEAD changed 指向新 zreview' 'printf "%s\n" "$A5_OUT" | grep -Fq "新的 zreview"'

# refresh 事实不完整时停止；不 replay transaction，也不第二次调用 review。
reset_counts
PREFLIGHT_MODE=ok
REFRESH_MODE=blocked
run_capture A6_OUT A6_RC zmerge_deliver_review_with_guard_recovery
expect_true 'R3 adapter refresh blocked 不 retry' '[ "$A6_RC" -ne 0 ] && [ "$(count refresh)" = 1 ] && [ "$(count deliver)" = 1 ]'
expect_true 'R3 adapter refresh blocked 提示显式核对' 'printf "%s\n" "$A6_OUT" | grep -Fq "new guard sync"'

expect_true 'R3 zmerge_do_merge 已使用 recovery adapter' \
  'grep -Fq "zmerge_deliver_review_with_guard_recovery" "$ROOT/.agents/skills/zmerge/scripts/merge-lib.sh"'

echo "check-guard-recovery.sh: 通过 ${pass}，失败 ${fail}"
[ "$fail" = 0 ]
