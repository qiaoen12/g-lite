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
  for name in gate-reader gate-fetch main-check review-check auto-check contract-check diff-check issue-check guard-check pr-lookup pr-view pr-fields pr-contract required checks; do
    printf '0\n' > "$COUNT/$name"
  done
  set_gate human-merge absent
  set_gate transaction stable
  set_gate lease stable
  set_gate head "$Z_HEAD"
  set_gate pr-head "$Z_HEAD"
  set_gate main current
  set_gate review valid
  set_gate contract stable
  set_gate diff valid
  set_gate pr none
  set_gate pr-fields valid
  set_gate issue-title stable
  CHANGE_ON_REFRESH=""
}

Z_WT="$ROOT"
Z_MAIN=main
Z_OWNER=o
Z_REPO=r
Z_NUMBER=14
Z_GIT_BR="$(git -C "$Z_WT" symbolic-ref --short HEAD)"
Z_HEAD="$(git -C "$Z_WT" rev-parse HEAD)"
Z_BASE=origin/main
Z_SCOPE=.agents/skills/zmerge/
Z_CONTRACT_BLOB=contract-fixed
Z_CONTRACT_JSON="$TDIR/contract.json"
Z_ISSUE_JSON="$TDIR/issue.json"
FAILURE_DOMAIN=guard-staging
DELIVER_MODE=stale
REFRESH_MODE=refreshed

# These replacements are only external providers/fault injection.  The
# production zmerge_guard_recovery_preflight, zmerge_reread_pre_push_gates and
# zmerge_reread_all_merge_gates below are deliberately not redefined.
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

z_fetch_origin_main() { bump gate-fetch; return 0; }
z_main_is_current() {
  bump main-check
  [ "$(gate main)" = current ]
}
z_require_passing_review() {
  bump review-check
  [ "$(gate review)" = valid ] || {
    err_code z.no_passing_review 'production review provider reports Review invalid'
    return 1
  }
  [ "$(gate head)" = "$Z_HEAD" ] || {
    err_code z.pr_head_changed 'candidate HEAD 已改变，需要新的 zreview'
    return 1
  }
  Z_SQUASH_TITLE='feat(meta): x'
  Z_REVIEW_BODY='review-fixed'
  Z_SELF_REVIEW=no
}
z_require_auto_merge_safe_review() {
  bump auto-check
  [ "$(gate review)" = valid ]
}
contract_fetch_main() { bump contract-check; return 0; }
contract_main_blob() { printf '%s\n' "$Z_CONTRACT_BLOB"; }
contract_stale() {
  if [ "$(gate contract)" = changed ]; then
    err_code contract.stale 'production contract provider reports Contract changed'
    return 0
  fi
  return 1
}
contract_require_diff_in_scope() {
  bump diff-check
  [ "$(gate diff)" = valid ]
}
task_fetch_issue() {
  local out="$4" label_json='[]' title='stable'
  bump issue-check
  [ "$(gate issue-title)" = stable ] || title='changed'
  if [ "$(gate human-merge)" = present ]; then
    label_json='[{"name":"human-merge"}]'
  fi
  jq -n --arg title "$title" --argjson labels "$label_json" \
    '{data:{repository:{issue:{id:"I",title:$title,state:"OPEN",labels:{nodes:$labels},projectItems:{nodes:[]}}}}}' > "$out"
}
task_issue_labels() { jq -c '[.data.repository.issue.labels.nodes[]?.name] // []' "$1"; }
derive_task_state() {
  printf '%s\n' "$TASK_STATUS_PROGRESS"
}
task_read_status_name() { printf '%s\n' "$TASK_STATUS_PROGRESS"; }
task_find_matching_pr() {
  bump pr-lookup
  if [ "$(gate pr)" = exists ]; then
    jq -n --arg h "$Z_GIT_BR" '{number:3,url:"https://github.com/o/r/pull/3",isDraft:false,headRefName:$h,baseRefName:"main",state:"OPEN",body:"Fixes #14",title:"feat(meta): x"}'
  else
    printf '\n'
  fi
}
task_pr_view_json() {
  local h
  bump pr-view
  h="$(gate pr-head)"
  jq -n --arg h "$h" '{number:3,url:"https://github.com/o/r/pull/3",baseRefName:"main",headRefName:"meta/issue-14",headRefOid:$h,isDraft:false,state:"OPEN",body:"Fixes #14",title:"feat(meta): x"}'
}
task_pr_fields_ok() { bump pr-fields; [ "$(gate pr-fields)" = valid ]; }
contract_pr_validate() { bump pr-contract; return 0; }
z_required_contexts() {
  bump required
  Z_REQUIRED_OK=1
  Z_REQUIRED_CONTEXTS=
  Z_REQUIRED_ERR=
}
z_pr_checks_ok() { bump checks; return 0; }
guard_merge_gate_validate() {
  bump guard-check
  [ "$(gate transaction)" = stable ] || {
    err_code z.transaction_changed 'production Guard provider reports transaction changed'
    return 1
  }
  [ "$(gate lease)" = stable ] || {
    err_code z.lease_changed 'production Guard provider reports lease changed'
    return 1
  }
  GUARD_MERGE_GATE_FINGERPRINT="$(printf '%s\n' "$(gate transaction)" "$(gate lease)" "$(gate human-merge)" | shasum -a 256 | awk '{print $1}')"
}

guard_refresh_staging_for_merge() {
  bump refresh
  if [ "$REFRESH_MODE" = refreshed ] || [ "$REFRESH_MODE" = noop ]; then
    case "$CHANGE_ON_REFRESH" in
      human-merge) set_gate human-merge removed ;;
      transaction) set_gate transaction changed ;;
      lease) set_gate lease changed ;;
      head) set_gate head head-changed ;;
      pr-head) set_gate pr-head pr-head-changed ;;
      main) set_gate main advanced ;;
    esac
  fi
  case "$REFRESH_MODE" in
    refreshed|noop) printf '%s\n' "$REFRESH_MODE"; return 0 ;;
    blocked) printf '%s\n' 'refresh blocked' >&2; return 1 ;;
    *) printf '%s\n' "$REFRESH_MODE"; return 0 ;;
  esac
}

# ── stale → 一次 refresh + 两次 preflight + 一次 retry ───────────────────
reset_counts
DELIVER_MODE=stale
FAILURE_DOMAIN=guard-staging
REFRESH_MODE=refreshed
run_capture A1_OUT A1_RC zmerge_deliver_review_with_guard_recovery
expect_eq 'R3 adapter stale recovery 成功' 0 "$A1_RC"
expect_eq 'R3 adapter stale 只 retry 一次' 2 "$(count deliver)"
expect_eq 'R3 adapter stale 只 refresh 一次' 1 "$(count refresh)"
expect_eq 'R3 adapter stale 真实 production pre-push reader 两次复读 Review' 2 "$(count review-check)"
expect_eq 'R3 adapter stale 两次确认无 PR' 2 "$(count pr-lookup)"
expect_eq 'R3 adapter stale 不读取 PR gate' 0 "$(count pr-view)"
expect_eq 'R3 adapter stale 不读取 required checks' 0 "$(count required)"
expect_true 'R3 adapter stale retry 输出成功' 'printf "%s\n" "$A1_OUT" | grep -Fq "review-ok"'

# staging 已经追平时，noop 仍可在相同授权内完成一次 retry。
reset_counts
DELIVER_MODE=stale
REFRESH_MODE=noop
run_capture A2_OUT A2_RC zmerge_deliver_review_with_guard_recovery
expect_eq 'R3 adapter noop recovery 成功' 0 "$A2_RC"
expect_eq 'R3 adapter noop 只 retry 一次' 2 "$(count deliver)"
expect_eq 'R3 adapter noop 只 refresh 一次' 1 "$(count refresh)"
expect_eq 'R3 adapter noop 仍走 production pre-push reader' 2 "$(count review-check)"
expect_eq 'R3 adapter noop 不读取 PR gate' 0 "$(count pr-view)"

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
set_gate main advanced
run_capture A4_OUT A4_RC zmerge_deliver_review_with_guard_recovery
expect_true 'R3 adapter candidate behind fail-closed' '[ "$A4_RC" -ne 0 ] && [ "$(count refresh)" = 0 ] && [ "$(count deliver)" = 1 ]'
expect_true 'R3 adapter candidate behind 指向 zsync' 'printf "%s\n" "$A4_OUT" | grep -Fq "zsync"'

# 首次交付尚无 PR 时，transaction/lease 仍是 pre-push durable gates；不能
# 因为 PR 尚不存在而把歧义降级成可 refresh。
for blocked_gate in transaction lease; do
  reset_counts
  DELIVER_MODE=stale
  FAILURE_DOMAIN=guard-staging
  REFRESH_MODE=refreshed
  set_gate "$blocked_gate" ambiguous
  run_capture NOPR_BLOCKED_OUT NOPR_BLOCKED_RC zmerge_deliver_review_with_guard_recovery
  expect_true "R3 no-PR ${blocked_gate} ambiguous fail-closed" \
    '[ "$NOPR_BLOCKED_RC" -ne 0 ] && [ "$(count deliver)" = 1 ] && [ "$(count refresh)" = 0 ]'
  expect_true "R3 no-PR ${blocked_gate} 有 durable gate 诊断" \
    'printf "%s\n" "$NOPR_BLOCKED_OUT" | grep -Eiq "transaction|lease|改变|changed|停止"'
done

# human-merge 是现有 zmerge 授权边界；无 PR 也必须由 pre-push reader 拒绝，
# 不能把「PR missing」当成忽略 Issue label。
reset_counts
DELIVER_MODE=stale
FAILURE_DOMAIN=guard-staging
set_gate human-merge present
run_capture NOPR_HUMAN_OUT NOPR_HUMAN_RC zmerge_deliver_review_with_guard_recovery
expect_true 'R3 no-PR human-merge fail-closed' \
  '[ "$NOPR_HUMAN_RC" -ne 0 ] && [ "$(count deliver)" = 1 ] && [ "$(count refresh)" = 0 ]'
expect_true 'R3 no-PR human-merge 有明确诊断' \
  'printf "%s\n" "$NOPR_HUMAN_OUT" | grep -Fq "human-merge"'

# Review HEAD 改变：必须要求新的 Review，不能 refresh 后沿用旧授权。
reset_counts
Z_HEAD_SAVED="$Z_HEAD"
Z_HEAD=head-changed
run_capture A5_OUT A5_RC zmerge_deliver_review_with_guard_recovery
expect_true 'R3 adapter HEAD changed 不 refresh' '[ "$A5_RC" -ne 0 ] && [ "$(count refresh)" = 0 ] && [ "$(count deliver)" = 1 ]'
expect_true 'R3 adapter HEAD changed 指向新 zreview' 'printf "%s\n" "$A5_OUT" | grep -Fq "新的 zreview"'
Z_HEAD="$Z_HEAD_SAVED"

# refresh 事实不完整时停止；不 replay transaction，也不第二次调用 review。
reset_counts
REFRESH_MODE=blocked
run_capture A6_OUT A6_RC zmerge_deliver_review_with_guard_recovery
expect_true 'R3 adapter refresh blocked 不 retry' '[ "$A6_RC" -ne 0 ] && [ "$(count refresh)" = 1 ] && [ "$(count deliver)" = 1 ]'
expect_true 'R3 adapter refresh blocked 提示显式核对' 'printf "%s\n" "$A6_OUT" | grep -Fq "new guard sync"'

# refresh 不是把前一轮授权冻结成可复用的 mock：每次 fault injection 都在
# refresh 成功后改变一个 durable merge gate，第二次 production reader 必须
# 重新读取并 fail-closed，绝不能进入 retry。
for mutation in human-merge transaction lease head main; do
  reset_counts
  DELIVER_MODE=stale
  FAILURE_DOMAIN=guard-staging
  REFRESH_MODE=refreshed
  CHANGE_ON_REFRESH="$mutation"
  run_capture MUTATION_OUT MUTATION_RC zmerge_deliver_review_with_guard_recovery
  if [ "$mutation" = main ]; then
    expect_true "R3 refresh 后 ${mutation} 改变阻断 retry" \
      '[ "$MUTATION_RC" -ne 0 ] && [ "$(count deliver)" = 1 ] && [ "$(count refresh)" = 1 ] && [ "$(count main-check)" = 2 ]'
  else
    expect_true "R3 refresh 后 ${mutation} 改变阻断 retry" \
      '[ "$MUTATION_RC" -ne 0 ] && [ "$(count deliver)" = 1 ] && [ "$(count refresh)" = 1 ] && [ "$(count review-check)" = 2 ]'
  fi
  if [ "$mutation" = main ]; then
    expect_true "R3 refresh 后 ${mutation} 有 gate 诊断" \
      'printf "%s\n" "$MUTATION_OUT" | grep -Fq "zsync"'
  else
    expect_true "R3 refresh 后 ${mutation} 有 gate 诊断" \
      'printf "%s\n" "$MUTATION_OUT" | grep -Eiq "改变|changed|停止"'
  fi
done
CHANGE_ON_REFRESH=""

# PR 已存在时 recovery 必须进入 production full-merge reader，而不是把
# PR/Checks gate 当成「已有阶段」跳过。
reset_counts
set_gate pr exists
run_capture FULL_OUT FULL_RC zmerge_guard_recovery_preflight
expect_eq 'R3 PR exists 使用 full merge reader' 0 "$FULL_RC"
expect_eq 'R3 PR exists 读取 PR view' 1 "$(count pr-view)"
expect_eq 'R3 PR exists 读取 required checks' 1 "$(count required)"
expect_eq 'R3 PR exists 读取 review gate' 1 "$(count review-check)"

# PR head 在 refresh 后改变：第二次仍由 production full reader 读取并阻断。
reset_counts
set_gate pr exists
CHANGE_ON_REFRESH=pr-head
DELIVER_MODE=stale
FAILURE_DOMAIN=guard-staging
REFRESH_MODE=refreshed
run_capture PR_HEAD_OUT PR_HEAD_RC zmerge_deliver_review_with_guard_recovery
expect_true 'R3 PR head 改变阻断 retry' '[ "$PR_HEAD_RC" -ne 0 ] && [ "$(count deliver)" = 1 ] && [ "$(count refresh)" = 1 ] && [ "$(count pr-view)" = 2 ]'
expect_true 'R3 PR head 改变有新 Review 诊断' 'printf "%s\n" "$PR_HEAD_OUT" | grep -Eiq "PR head|重新 zreview|changed"'
CHANGE_ON_REFRESH=""

expect_true 'R3 zmerge_do_merge 已使用 recovery adapter' \
  'grep -Fq "zmerge_deliver_review_with_guard_recovery" "$ROOT/.agents/skills/zmerge/scripts/merge-lib.sh"'
expect_true 'R3 recovery adapter 未覆盖 production preflight' \
  '! grep -Eq "^[[:space:]]*zmerge_guard_recovery_preflight\(\)" "$ROOT/.agents/skills/zmerge/scripts/check-guard-recovery.sh"'
expect_true 'R3 recovery adapter 未覆盖 production full reader' \
  '! grep -Eq "^[[:space:]]*zmerge_reread_all_merge_gates\(\)" "$ROOT/.agents/skills/zmerge/scripts/check-guard-recovery.sh"'

echo "check-guard-recovery.sh: 通过 ${pass}，失败 ${fail}"
[ "$fail" = 0 ]
