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
gate() { cat "$COUNT/gate-$1" 2>/dev/null || printf 'unknown\n'; }
set_gate() { printf '%s\n' "$2" > "$COUNT/gate-$1"; }
reset_counts() {
  printf '0\n' > "$COUNT/deliver"
  printf '0\n' > "$COUNT/refresh"
  printf '0\n' > "$COUNT/preflight"
  set_gate human-merge present
  set_gate transaction stable
  set_gate lease stable
  set_gate head "$Z_HEAD"
  set_gate pr-head "$Z_HEAD"
  CHANGE_ON_REFRESH=""
}

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
  if [ "$REFRESH_MODE" = refreshed ] || [ "$REFRESH_MODE" = noop ]; then
    case "$CHANGE_ON_REFRESH" in
      human-merge) set_gate human-merge removed ;;
      transaction) set_gate transaction changed ;;
      lease) set_gate lease changed ;;
      head) set_gate head head-changed ;;
      pr-head) set_gate pr-head pr-head-changed ;;
    esac
  fi
  case "$REFRESH_MODE" in
    refreshed|noop) printf '%s\n' "$REFRESH_MODE"; return 0 ;;
    blocked) printf '%s\n' 'refresh blocked' >&2; return 1 ;;
    *) printf '%s\n' "$REFRESH_MODE"; return 0 ;;
  esac
}

zmerge_guard_recovery_preflight() {
  bump preflight
  case "$PREFLIGHT_MODE" in
    ok) ;;
    behind) err_code z.main_ahead 'candidate 真落后；下一步：new z sync'; return 1 ;;
    head-changed) err_code z.pr_head_changed 'candidate HEAD 已改变；需要新的 zreview'; return 1 ;;
    review-invalid) err_code z.no_passing_review '当前 HEAD 没有有效 Review'; return 1 ;;
    *) err_code z.guard_recovery_preflight 'merge gates 未通过'; return 1 ;;
  esac
  [ "$(gate human-merge)" = present ] || {
    err_code z.human_merge_changed 'refresh 期间 human-merge gate 改变，停止'; return 1;
  }
  [ "$(gate transaction)" = stable ] || {
    err_code z.transaction_changed 'refresh 期间 transaction state 改变，停止'; return 1;
  }
  [ "$(gate lease)" = stable ] || {
    err_code z.lease_changed 'refresh 期间 lease 改变，停止'; return 1;
  }
  [ "$(gate head)" = "$Z_HEAD" ] || {
    err_code z.pr_head_changed 'refresh 期间 candidate HEAD 改变，停止'; return 1;
  }
  [ "$(gate pr-head)" = "$Z_HEAD" ] || {
    err_code z.pr_head_changed 'refresh 期间 PR head 改变，停止'; return 1;
  }
  return 0
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

# refresh 不是把前一轮授权冻结成可复用的 mock：每次 fault injection 都在
# refresh 成功后改变一个 durable merge gate，第二次完整 preflight 必须读到
# 变化并 fail-closed，绝不能进入 retry。
for mutation in human-merge transaction lease head pr-head; do
  reset_counts
  DELIVER_MODE=stale
  FAILURE_DOMAIN=guard-staging
  PREFLIGHT_MODE=ok
  REFRESH_MODE=refreshed
  CHANGE_ON_REFRESH="$mutation"
  run_capture MUTATION_OUT MUTATION_RC zmerge_deliver_review_with_guard_recovery
  expect_true "R3 refresh 后 ${mutation} 改变阻断 retry" \
    '[ "$MUTATION_RC" -ne 0 ] && [ "$(count deliver)" = 1 ] && [ "$(count refresh)" = 1 ] && [ "$(count preflight)" = 2 ]'
  expect_true "R3 refresh 后 ${mutation} 有 gate 诊断" \
    'printf "%s\n" "$MUTATION_OUT" | grep -Eiq "改变|changed|停止"'
done
CHANGE_ON_REFRESH=""

expect_true 'R3 zmerge_do_merge 已使用 recovery adapter' \
  'grep -Fq "zmerge_deliver_review_with_guard_recovery" "$ROOT/.agents/skills/zmerge/scripts/merge-lib.sh"'

echo "check-guard-recovery.sh: 通过 ${pass}，失败 ${fail}"
[ "$fail" = 0 ]
