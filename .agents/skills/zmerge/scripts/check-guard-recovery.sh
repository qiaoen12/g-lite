#!/usr/bin/env bash
# Issue #14 R3 production-path fixture。
#
# 只把外部边界替换成 provider：GitHub API 由临时 gh 可执行文件提供，首次
# delivery 由一个返回真实 push stderr 的 action provider 提供，refresh 完成
# 后的 durable-state mutation 由 Guard 的空操作 provider seam 注入。
# zmerge orchestration、gate reader、validator、classifier 与 Guard merge gate
# 都来自 production source；本测试不得定义同名 decision function。
set -Eeuo pipefail
export LC_COLLATE=C
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "✗ 不在 git 工作树" >&2
  exit 1
}
# shellcheck source=/dev/null
. "$ROOT/0-meta/lib/new/core.sh"
# shellcheck source=/dev/null
. "$ROOT/0-meta/lib/new/task.sh"
# shellcheck source=/dev/null
. "$ROOT/0-meta/lib/new/review.sh"
# shellcheck source=/dev/null
. "$ROOT/.agents/skills/z-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/.agents/skills/zmerge/scripts/merge-lib.sh"
trap tmp_cleanup EXIT

fail=0
pass=0
ok() { pass=$((pass + 1)); }
bad() { echo "✗ $*" >&2; fail=$((fail + 1)); }
expect_eq() {
  if [ "$2" = "$3" ]; then ok; else bad "$1: 期望 [$2] 实际 [$3]"; fi
}
expect_true() { if eval "$2"; then ok; else bad "$1"; fi; }
run_capture() {
  local __outvar="$1" __rcvar="$2"; shift 2
  local out rc=0
  out="$($@ 2>&1)" || rc=$?
  printf -v "$__outvar" '%s' "$out"
  printf -v "$__rcvar" '%s' "$rc"
}

TDIR=""
tmp_mkd TDIR zmerge-guard-recovery-production
export HOME="$TDIR/home"
export XDG_STATE_HOME="$TDIR/state-home"
mkdir -p "$HOME" "$XDG_STATE_HOME"

EVENTS="$TDIR/provider-events"
CALLS="$TDIR/provider-calls"
BIN="$TDIR/bin"
PR_STATE_FILE="$TDIR/pr-state"
mkdir -p "$BIN"
: > "$EVENTS"
: > "$CALLS"
: > "$PR_STATE_FILE"

# 外部 GitHub API provider；不包含任何 production gate 判断。
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >> "${GH_CALLS:?}"
event() { printf '%s\n' "$1" >> "${GH_EVENTS:?}"; }

if [ "${1:-}" = api ]; then
  if [[ "$*" == *"issues/14/comments"* ]]; then
    event comments
    jq -n --rawfile body "${GH_REVIEW_BODY:?}" '[{id:1401,body:$body}]'
    exit 0
  fi
  if [[ "$*" == *graphql* ]]; then
    if [[ "$*" == *requiredStatusCheckContexts* ]]; then
      event required
      jq -n '{data:{repository:{
        ref:{name:"main",refUpdateRule:{requiredStatusCheckContexts:["ci/test"]},
          branchProtectionRule:null,
          rules:{pageInfo:{hasNextPage:false},nodes:[]}},
        rulesets:{pageInfo:{hasNextPage:false},nodes:[]}
      }}}'
    else
      event issue
      cat "${GH_ISSUE_JSON:?}"
    fi
    exit 0
  fi
fi

if [ "${1:-}" = pr ] && [ "${2:-}" = list ]; then
  event pr-list
  pr_state="${GH_PR_STATE:-none}"
  if [ -f "${GH_PR_STATE_FILE:-}" ]; then
    pr_state="$(cat "$GH_PR_STATE_FILE")"
  fi
  if [ "$pr_state" = exists ]; then
    # gh 本身已经按 head/base 过滤；这里仅把结构化 provider 响应包装成
    # task_find_matching_pr 期待的数组。不要用 jq input 读取第二个输入，
    # 那会在单文件 provider 上产生 EOF/break，而不是 PR missing。
    jq -c '[.]' "${GH_PR_JSON:?}"
  else
    printf '%s\n' '[]'
  fi
  exit 0
fi

if [ "${1:-}" = pr ] && [ "${2:-}" = view ]; then
  if [[ "$*" == *statusCheckRollup* ]]; then
    event pr-checks
    jq -n '{statusCheckRollup:[{name:"ci/test",conclusion:"SUCCESS"}]}'
  else
    event pr-view
    cat "${GH_PR_JSON:?}"
  fi
  exit 0
fi

echo "unexpected fake gh invocation: $*" >&2
exit 2
EOF
chmod 755 "$BIN/gh"
PATH="$BIN:$PATH"
export PATH GH_EVENTS="$EVENTS" GH_CALLS="$CALLS" GH_PR_STATE_FILE="$PR_STATE_FILE"

git_cfg() {
  git -C "$1" config user.email fixture@example.test
  git -C "$1" config user.name fixture
  git -C "$1" config commit.gpgsign false
  git -C "$1" config core.hooksPath /dev/null
}

event_count() {
  awk -v want="$1" '$0 == want { n++ } END { print n + 0 }' "$EVENTS"
}

file_count() {
  cat "$1" 2>/dev/null || printf '0\n'
}

bump_file() {
  local file="$1" n
  n="$(file_count "$file")"
  printf '%s\n' "$((n + 1))" > "$file"
}

reset_events() {
  : > "$EVENTS"
  printf '0\n' > "$TDIR/deliver-count"
}

make_issue() {
  local labels="$1"
  jq -n --argjson labels "$labels" '{data:{repository:{issue:{
    id:"I14", title:"Issue 14 production recovery fixture",
    url:"https://github.com/o/r/issues/14", body:"fixture",
    state:"OPEN", labels:{nodes:$labels}, projectItems:{nodes:[]}
  }}}}' > "$GH_ISSUE_JSON"
}

make_contract() {
  jq -n '{
    schema_version:"task-contract/v1",
    requirements:[{id:"R1",text:"production recovery gate"}],
    acceptances:[{id:"A1",text:"scoped state mutation is fail-closed",requires:["R1"],applicable_when:null,validators:[]}],
    scope:[".agents/skills/zmerge/"]
  }' > "$1"
}

ORIGIN="$TDIR/github.git"
SEED="$TDIR/seed"
MAIN_WT="$TDIR/main"
STAGING="$TDIR/staging.git"
WT="$TDIR/candidate"
BR="meta/recovery-14"
OTHER_BR="meta/recovery-other-14"
CONTRACT_PATH="0-meta/tasks/14/contract.json"
TITLE='feat(meta): recovery fixture'
GH_ISSUE_JSON="$TDIR/issue.json"
GH_REVIEW_BODY="$TDIR/review.md"
GH_PR_JSON="$TDIR/pr.json"
GH_PR_STATE=none
GH_BRANCH="$BR"
export GH_ISSUE_JSON GH_REVIEW_BODY GH_PR_JSON GH_PR_STATE GH_BRANCH

# 真实 Git fixture：GitHub bare、candidate branch、staging heads 与 snapshot
# 都是真实 ref。staging 在 main 的 m1 之前完成镜像，然后 candidate 从 m1
# 派生，因此 candidate 已含最新 main，而 Guard snapshot/staging 仍是 stale。
git init -q --bare -b main "$ORIGIN"
git clone -q "$ORIGIN" "$SEED"
git_cfg "$SEED"
mkdir -p "$SEED/0-meta/tasks/14" "$SEED/.agents/skills/zmerge"
make_contract "$SEED/$CONTRACT_PATH"
printf 'base\n' > "$SEED/README"
git -C "$SEED" add README "$CONTRACT_PATH"
git -C "$SEED" commit -qm 'feat(meta): recovery fixture base'
git -C "$SEED" push -q origin main
BASE_OID="$(git --git-dir="$ORIGIN" rev-parse refs/heads/main)"

git init -q --bare -b main "$STAGING"
TEST_STAGING="$STAGING"
guard_staging_git() { printf '%s\n' "$TEST_STAGING"; }
guard_install_hooks "$STAGING" >/dev/null
git --git-dir="$STAGING" config receive.denyNonFastForwards false
git --git-dir="$STAGING" config receive.denyDeletes false
git --git-dir="$STAGING" config git-guard.main main
git --git-dir="$STAGING" remote add github "$ORIGIN"
git --git-dir="$STAGING" fetch -q --no-tags github \
  'refs/heads/main:refs/heads/main'
git --git-dir="$STAGING" fetch -q --no-tags github \
  'refs/heads/main:refs/guard/github/heads/main'
STAGE_OLD="$BASE_OID"
git --git-dir="$STAGING" update-ref refs/heads/unrelated "$STAGE_OLD"
git --git-dir="$STAGING" update-ref refs/guard/github/heads/unrelated "$STAGE_OLD"

printf 'latest-main\n' >> "$SEED/README"
git -C "$SEED" add README
git -C "$SEED" commit -qm 'feat(meta): latest main fixture'
git -C "$SEED" push -q origin main
MAIN_LATEST="$(git --git-dir="$ORIGIN" rev-parse refs/heads/main)"
# 预先把 m1 对象放入 staging object store，但不改变任何 Guard ref；这样
# 每个失败/阻断场景都能从同一真实 stale 基线 reset，而不是依赖首次 refresh
# 先成功才能拥有目标对象。
git --git-dir="$STAGING" fetch -q --no-tags github \
  "refs/heads/main:refs/guard/fixture/main-latest"
git --git-dir="$STAGING" update-ref -d refs/guard/fixture/main-latest
git --git-dir="$STAGING" update-ref refs/guard/github/heads/main "$MAIN_LATEST"
# 为 post-refresh relation mutation 准备真实的 staging 对象：一个 snapshot
# 的子提交（ahead），以及从旧 main 分叉的提交（diverged）。它们只存在于
# 临时 staging object store，不改变 GitHub/provider 的业务状态。
STAGE_AHEAD="$(printf '%s\n' post-refresh-ahead | \
  GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.test \
  GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.test \
  git --git-dir="$STAGING" commit-tree \
    "$(git --git-dir="$STAGING" rev-parse "${MAIN_LATEST}^{tree}")" -p "$MAIN_LATEST")"
STAGE_DIVERGED="$(printf '%s\n' post-refresh-diverged | \
  GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.test \
  GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.test \
  git --git-dir="$STAGING" commit-tree \
    "$(git --git-dir="$STAGING" rev-parse "${BASE_OID}^{tree}")" -p "$BASE_OID")"
git -C "$SEED" switch -qc "$BR" main
printf 'task-change\n' > "$SEED/.agents/skills/zmerge/recovery-fixture.txt"
git -C "$SEED" add .agents/skills/zmerge/recovery-fixture.txt
git -C "$SEED" commit -qm "$TITLE"
git -C "$SEED" push -q origin "$BR"

# candidate 必须是 linked worktree；standalone clone 会被产品判作 main，
# 反而不能验证 worktree-local transport 隔离。
git clone -q "$ORIGIN" "$MAIN_WT"
git_cfg "$MAIN_WT"
git -C "$MAIN_WT" worktree add -qb "$BR" "$WT" "origin/$BR"
git_cfg "$WT"
git -C "$WT" fetch -q origin main
guard_wire_worktree "$WT" >/dev/null

Z_WT="$WT"
Z_MAIN=main
Z_OWNER=o
Z_REPO=r
Z_NUMBER=14
Z_GIT_BR="$BR"
Z_HEAD="$(git -C "$WT" rev-parse HEAD)"
Z_BASE=origin/main
Z_SCOPE='.agents/skills/zmerge/'
Z_CONTRACT_JSON="$TDIR/contract.json"
git -C "$WT" show "origin/main:$CONTRACT_PATH" > "$Z_CONTRACT_JSON"
Z_CONTRACT_BLOB="$(git -C "$WT" rev-parse "origin/main:$CONTRACT_PATH")"
# Provider source 与 production reader 的输出文件必须分离；否则 shell
# redirect 会在 fake gh 读取前截断 source，制造一个与远端 API 无关的假性
# Issue missing/unknown。production task_fetch_issue 仍真实写入这个输出路径。
Z_ISSUE_JSON="$TDIR/fetched-issue.json"
export Z_WT Z_MAIN Z_OWNER Z_REPO Z_NUMBER Z_GIT_BR Z_HEAD Z_BASE Z_SCOPE \
  Z_CONTRACT_JSON Z_CONTRACT_BLOB Z_ISSUE_JSON

jq -n --arg title "$TITLE" '{
  verdict:"通过",title:$title,
  notes:"真实临时 Git/ref 与 production gate reread fixture",
  requirements:[{id:"R1",status:"满足",evidence:"production-path state mutation"}],
  acceptances:[{id:"A1",status:"通过",evidence:"provider boundary plus durable state"}]
}' > "$TDIR/review-input.json"
printf '%s\n' '[]' > "$TDIR/review-results.json"
review_render "$TDIR/review-input.json" "$TDIR/review-results.json" \
  "$GH_REVIEW_BODY" beta alpha no \
  '.agents/skills/zmerge/recovery-fixture.txt'

PR_BODY="$TDIR/pr-body.md"
cat > "$PR_BODY" <<EOF
${TASK_PR_MARK_BEGIN}
## 任务身份

| 项 | 值 |
| --- | --- |
| Issue | o/r#14 |
| Contract | ${Z_CONTRACT_BLOB} |
| reviewed HEAD | \`${Z_HEAD}\` |

## 变更摘要

真实 production recovery fixture。

## 验证摘要

production-path、negative、state mutation。

Fixes #14
${TASK_PR_MARK_END}
EOF
jq -n --arg body "$(cat "$PR_BODY")" --arg br "$BR" \
  --arg head "$Z_HEAD" --arg title "$TITLE" \
  '{number:3,url:"https://github.com/o/r/pull/3",baseRefName:"main",
    headRefName:$br,headRefOid:$head,isDraft:false,state:"OPEN",body:$body,title:$title}' \
  > "$GH_PR_JSON"
make_issue '[]'
cp "$GH_ISSUE_JSON" "$TDIR/issue-base.json"
cp "$GH_PR_JSON" "$TDIR/pr-base.json"
UNRELATED_SENTINEL="$STAGE_OLD"

MUTATION=none
DELIVER_MODE=stale

# delivery 是真实 action 的外部 provider seam；production classifier 仍由
# guard.sh 执行，provider 只模拟 Git 返回的 stdout/stderr 与第二次成功。
zmerge_deliver_review() {
  local n
  bump_file "$TDIR/deliver-count"
  n="$(file_count "$TDIR/deliver-count")"
  if [ "$DELIVER_MODE" = stale ] && [ "$n" = 1 ]; then
    printf '%s\n' \
      '! [remote rejected] meta/recovery-14 -> meta/recovery-14 (staging mirror stale)' >&2
    printf '%s\n' \
      'GitHub main 已前进，staging 未同步，拒绝使用陈旧 contract' >&2
    printf '%s\n' 'error: failed to push some refs' >&2
    return 1
  fi
  if [ "$DELIVER_MODE" = route ]; then
    printf '%s\n' \
      '! [remote rejected] meta/recovery-14 -> meta/recovery-14 (pre-receive hook declined)' >&2
    return 1
  fi
  printf '%s\n' 'review-ok'
}

seed_clean_transaction() {
  local status="${1:-noop}" lease="${2:-}"
  mkdir -p "$STAGING/git-guard/transactions/mutated"
  printf '%s\n' "$status" > "$STAGING/git-guard/transactions/mutated/receive-status"
  printf '%s\n' noop > "$STAGING/git-guard/transactions/mutated/forward-status"
  if [ -n "$lease" ]; then
    printf '%s\n' "$lease" > "$STAGING/git-guard/transactions/mutated/lease-status"
  else
    rm -f "$STAGING/git-guard/transactions/mutated/lease-status"
  fi
}

advance_remote_main() {
  env -u GIT_DIR -u GIT_WORK_TREE git -C "$SEED" switch -q main
  printf 'advanced-main\n' >> "$SEED/README"
  env -u GIT_DIR -u GIT_WORK_TREE git -C "$SEED" add README
  env -u GIT_DIR -u GIT_WORK_TREE git -C "$SEED" commit -qm 'feat(meta): advance main during refresh'
  env -u GIT_DIR -u GIT_WORK_TREE git -C "$SEED" push -q origin main
}

# 只在 production scoped fetch 完成后改变真实状态源；不是 gate 替身。
guard_refresh_staging_after_snapshot() {
  case "$MUTATION" in
    human-merge)
      jq '.data.repository.issue.labels.nodes=[{name:"human-merge"}]' \
        "$GH_ISSUE_JSON" > "$GH_ISSUE_JSON.tmp"
      mv "$GH_ISSUE_JSON.tmp" "$GH_ISSUE_JSON"
      ;;
    branch)
      env -u GIT_DIR -u GIT_WORK_TREE git -C "$WT" branch -f "$OTHER_BR" "$Z_HEAD"
      env -u GIT_DIR -u GIT_WORK_TREE git -C "$WT" checkout -q "$OTHER_BR"
      ;;
    head)
      env -u GIT_DIR -u GIT_WORK_TREE git -C "$WT" commit --allow-empty -qm 'test: mutate candidate head during refresh'
      ;;
    main)
      advance_remote_main
      ;;
    pr-head)
      jq '.headRefOid="1111111111111111111111111111111111111111"' \
        "$GH_PR_JSON" > "$GH_PR_JSON.tmp"
      mv "$GH_PR_JSON.tmp" "$GH_PR_JSON"
      ;;
    pr-appear)
      printf '%s\n' exists > "$PR_STATE_FILE"
      ;;
    pr-disappear)
      printf '%s\n' none > "$PR_STATE_FILE"
      ;;
    pr-title)
      jq '.title="changed title during refresh"' \
        "$GH_PR_JSON" > "$GH_PR_JSON.tmp"
      mv "$GH_PR_JSON.tmp" "$GH_PR_JSON"
      ;;
    pr-base)
      jq '.baseRefName="release"' \
        "$GH_PR_JSON" > "$GH_PR_JSON.tmp"
      mv "$GH_PR_JSON.tmp" "$GH_PR_JSON"
      ;;
    pr-body)
      jq '.body=(.body + "\nrefresh body mutation")' \
        "$GH_PR_JSON" > "$GH_PR_JSON.tmp"
      mv "$GH_PR_JSON.tmp" "$GH_PR_JSON"
      ;;
    pr-fixes)
      jq '.body=(.body | sub("Fixes #14"; "Fixes #99"))' \
        "$GH_PR_JSON" > "$GH_PR_JSON.tmp"
      mv "$GH_PR_JSON.tmp" "$GH_PR_JSON"
      ;;
    transaction|lease|retreat|post-ahead|post-diverged|post-missing)
      # 这些 mutation 必须发生在 update-ref 之后；这里只保持
      # production refresh 的 snapshot provider 正常返回。
      ;;
    none) ;;
    *)
      echo "unknown refresh mutation: $MUTATION" >&2
      return 1
      ;;
  esac
}

guard_refresh_staging_after_update() {
  printf 'post-%s\n' "$MUTATION" >> "$EVENTS"
  case "$MUTATION" in
    transaction)
      printf '%s\n' pending > "$STAGING/git-guard/transactions/mutated/receive-status"
      ;;
    lease)
      printf '%s\n' ambiguous > "$STAGING/git-guard/transactions/mutated/lease-status"
      ;;
    retreat)
      git --git-dir="$STAGING" update-ref refs/heads/main "$STAGE_OLD" "$MAIN_LATEST"
      ;;
    post-ahead)
      git --git-dir="$STAGING" update-ref refs/heads/main "$STAGE_AHEAD"
      ;;
    post-diverged)
      git --git-dir="$STAGING" update-ref refs/heads/main "$STAGE_DIVERGED"
      ;;
    post-missing)
      git --git-dir="$STAGING" update-ref -d refs/heads/main
      ;;
    none|human-merge|branch|head|main|pr-head|pr-appear|pr-disappear|pr-title|pr-base|pr-body|pr-fixes) ;;
    *)
      echo "unknown post-refresh mutation: $MUTATION" >&2
      return 1
      ;;
  esac
}

guard_refresh_staging_after_lock() {
  printf 'lock-%s\n' "$MUTATION" >> "$EVENTS"
  case "$MUTATION" in
    lock-transaction)
      seed_clean_transaction pending
      ;;
    lock-lease)
      seed_clean_transaction noop known
      ;;
    lock-identity)
      git --git-dir="$STAGING" remote set-url github "$TDIR/lock-other.git"
      ;;
    lock-transport)
      git -C "$WT" config --worktree remote.origin.pushurl "$TDIR/lock-push.git"
      ;;
    lock-claim)
      git -C "$WT" config --worktree remote.claim.pushurl "$TDIR/lock-claim.git"
      ;;
    lock-target)
      git --git-dir="$STAGING" update-ref refs/heads/main "$STAGE_AHEAD" "$STAGE_OLD"
      ;;
    lock-unrelated)
      git --git-dir="$STAGING" update-ref refs/heads/unrelated "$MAIN_LATEST" "$UNRELATED_SENTINEL"
      ;;
    none|human-merge|transaction|lease|retreat|post-ahead|post-diverged|post-missing|branch|head|main|pr-head|pr-appear|pr-disappear|pr-title|pr-base|pr-body|pr-fixes) ;;
    *)
      echo "unknown lock mutation: $MUTATION" >&2
      return 1
      ;;
  esac
}

reset_fixture() {
  MUTATION=none
  DELIVER_MODE=stale
  GH_PR_STATE=none
  printf '%s\n' "$GH_PR_STATE" > "$PR_STATE_FILE"
  reset_events
  cp "$TDIR/issue-base.json" "$GH_ISSUE_JSON"
  cp "$TDIR/pr-base.json" "$GH_PR_JSON"
  git -C "$SEED" switch -q main
  git -C "$SEED" reset -q --hard "$MAIN_LATEST"
  git -C "$SEED" push -q --force origin 'refs/heads/main:refs/heads/main'
  git -C "$WT" checkout -q "$BR"
  git -C "$WT" reset -q --hard "$Z_HEAD"
  git -C "$WT" clean -q -fd
  git -C "$WT" update-ref refs/remotes/origin/main "$MAIN_LATEST"
  git -C "$WT" config --worktree remote.origin.pushurl "$STAGING"
  git -C "$WT" config --worktree --unset-all remote.claim.pushurl >/dev/null 2>&1 || true
  git -C "$WT" branch -D "$OTHER_BR" >/dev/null 2>&1 || true
  git --git-dir="$STAGING" remote set-url github "$ORIGIN"
  git --git-dir="$STAGING" update-ref refs/heads/main "$STAGE_OLD"
  git --git-dir="$STAGING" update-ref refs/guard/github/heads/main "$MAIN_LATEST"
  git --git-dir="$STAGING" update-ref refs/heads/unrelated "$UNRELATED_SENTINEL"
  git --git-dir="$STAGING" update-ref refs/guard/github/heads/unrelated "$UNRELATED_SENTINEL"
  rm -rf "$STAGING/git-guard/transactions"
}

# 生产符号存在，且本测试没有定义正在验证的 decision function。
for symbol in \
  guard_classify_push_failure \
  z_require_passing_review z_require_auto_merge_safe_review \
  contract_review_validate contract_stale contract_require_diff_in_scope \
  task_fetch_issue task_find_matching_pr task_pr_view_json task_pr_fields_ok \
  contract_pr_validate z_required_contexts z_pr_checks_ok \
  guard_recovery_pre_refresh_preflight guard_recovery_post_refresh_preflight \
  zmerge_reread_all_merge_gates zmerge_reread_head_branch_main_gates \
  zmerge_reread_branch_gate zmerge_reread_recovery_common_gates \
  zmerge_recovery_pre_refresh_preflight zmerge_recovery_post_refresh_preflight \
  zmerge_recovery_pre_retry_preflight; do
  if grep -Eq "^[[:space:]]*${symbol}[[:space:]]*\(\)" "$0"; then
    bad "测试不应覆盖 production symbol：${symbol}"
  else
    ok
  fi
done
expect_true 'production full reader 已加载' \
  '[ "$(type -t zmerge_reread_all_merge_gates)" = function ]'
expect_true 'production branch reader 已加载' \
  '[ "$(type -t zmerge_reread_branch_gate)" = function ]'
expect_true 'production Guard gate 已加载' \
  '[ "$(type -t guard_recovery_pre_refresh_preflight)" = function ] && [ "$(type -t guard_recovery_post_refresh_preflight)" = function ]'
expect_true '真实 Review fixture 通过 production validator' \
  'contract_review_validate "$(cat "$GH_REVIEW_BODY")" "$Z_CONTRACT_JSON" "$Z_CONTRACT_BLOB" "$Z_HEAD"'
expect_true '真实 PR fixture 通过 production validator' \
  'contract_pr_validate "$(jq -r .body "$GH_PR_JSON")" "$Z_NUMBER" "$Z_CONTRACT_BLOB" "$Z_HEAD"'

# no PR + candidate 最新 + staging stale：production pre-push reader 两次执行，
# scoped refresh 后只 retry 一次；main 之外的 snapshot/ref 保持 sentinel。
reset_fixture
run_capture NOPR_OK_OUT NOPR_OK_RC zmerge_deliver_review_with_guard_recovery
expect_eq 'R3 no-PR valid recovery 成功' 0 "$NOPR_OK_RC"
expect_eq 'R3 no-PR valid delivery 一次 retry' 2 "$(file_count "$TDIR/deliver-count")"
expect_eq 'R3 no-PR valid refresh 一次' "$MAIN_LATEST" \
  "$(git --git-dir="$STAGING" rev-parse refs/heads/main)"
expect_eq 'R3 no-PR valid unrelated staging 不变' "$UNRELATED_SENTINEL" \
  "$(git --git-dir="$STAGING" rev-parse refs/heads/unrelated)"
expect_eq 'R3 no-PR valid unrelated snapshot 不变' "$UNRELATED_SENTINEL" \
  "$(git --git-dir="$STAGING" rev-parse refs/guard/github/heads/unrelated)"
expect_true 'R3 no-PR valid retry 成功输出' \
  'printf "%s\n" "$NOPR_OK_OUT" | grep -Fq review-ok'
expect_true 'R3 no-PR pre-push reader 两次读取 Issue provider' \
  '[ "$(event_count issue)" -ge 2 ]'
expect_true 'R3 no-PR pre-push reader 两次读取 Review provider' \
  '[ "$(event_count comments)" -ge 4 ]'
expect_eq 'R3 no-PR pre-push 不读取 PR view' 0 "$(event_count pr-view)"
expect_eq 'R3 no-PR pre-push 不读取 required checks' 0 "$(event_count required)"

# Guard lock 外建立 proof 后，lock 内每个关键事实都必须重新读取。provider
# 只模拟 lock 取得后的 durable mutation；若 lock-in reread 缺失，refresh 会
# 继续 update-ref，下面的 after-update 事件和目标 ref 断言会暴露问题。
for lock_mutation in lock-transaction lock-lease lock-identity lock-transport lock-claim lock-target lock-unrelated; do
  reset_fixture
  MUTATION="$lock_mutation"
  run_capture LOCK_OUT LOCK_RC guard_refresh_staging_for_merge "$WT" main
  expected_stage="$STAGE_OLD"
  [ "$lock_mutation" = lock-target ] && expected_stage="$STAGE_AHEAD"
  actual_stage="$(git --git-dir="$STAGING" rev-parse --verify --quiet refs/heads/main 2>/dev/null || true)"
  expect_true "R3 ${lock_mutation} lock-in reread BLOCK" \
    '[ "$LOCK_RC" -ne 0 ] && [ "$actual_stage" = "$expected_stage" ] && [ "$(event_count post-$MUTATION)" = 0 ]'
  expect_true "R3 ${lock_mutation} lock mutation provider 被执行" \
    '[ "$(event_count lock-$MUTATION)" -ge 1 ]'
done

# stale 但实际已同步：仍走同一 production pre-push reader，并在 scoped
# refresh 中返回 noop。
reset_fixture
git --git-dir="$STAGING" update-ref refs/heads/main "$MAIN_LATEST"
git --git-dir="$STAGING" update-ref refs/guard/github/heads/main "$MAIN_LATEST"
run_capture NOPR_NOOP_OUT NOPR_NOOP_RC zmerge_deliver_review_with_guard_recovery
expect_eq 'R3 no-PR noop recovery 成功' 0 "$NOPR_NOOP_RC"
expect_eq 'R3 no-PR noop delivery 一次 retry' 2 "$(file_count "$TDIR/deliver-count")"
expect_true 'R3 no-PR noop 输出' 'printf "%s\n" "$NOPR_NOOP_OUT" | grep -Fq review-ok'

# 其它 push failure domain 不具备 stale 证明，不能进入 refresh。
reset_fixture
DELIVER_MODE=route
run_capture ROUTE_OUT ROUTE_RC zmerge_deliver_review_with_guard_recovery
expect_true 'R3 Guard hook route 不 refresh/retry' \
  '[ "$ROUTE_RC" -ne 0 ] && [ "$(file_count "$TDIR/deliver-count")" = 1 ] && [ "$(git --git-dir="$STAGING" rev-parse refs/heads/main)" = "$STAGE_OLD" ]'
expect_true 'R3 Guard hook route 保留 root cause' \
  'printf "%s\n" "$ROUTE_OUT" | grep -Fq "pre-receive hook declined"'

# no PR + candidate 落后 main：pre-push reader 明确要求 zsync，不得 refresh。
reset_fixture
advance_remote_main
run_capture BEHIND_OUT BEHIND_RC zmerge_deliver_review_with_guard_recovery
expect_true 'R3 no-PR candidate behind BLOCK' \
  '[ "$BEHIND_RC" -ne 0 ] && [ "$(file_count "$TDIR/deliver-count")" = 1 ] && [ "$(git --git-dir="$STAGING" rev-parse refs/heads/main)" = "$STAGE_OLD" ]'
expect_true 'R3 no-PR candidate behind 指向 zsync' \
  'printf "%s\n" "$BEHIND_OUT" | grep -Fq zsync'

# no PR 阶段也必须检查 transaction / lease / human-merge，不能以 PR missing
# 为由跳过授权和 durable-fact gates。
for blocked in transaction lease human; do
  reset_fixture
  case "$blocked" in
    transaction) seed_clean_transaction pending ;;
    lease)
      seed_clean_transaction noop known
      printf '%s\n' ambiguous > "$STAGING/git-guard/transactions/mutated/lease-status"
      ;;
    human) make_issue '[{"name":"human-merge"}]' ;;
  esac
  run_capture BLOCKED_OUT BLOCKED_RC zmerge_deliver_review_with_guard_recovery
  expect_true "R3 no-PR ${blocked} gate BLOCK" \
    '[ "$BLOCKED_RC" -ne 0 ] && [ "$(file_count "$TDIR/deliver-count")" = 1 ] && [ "$(git --git-dir="$STAGING" rev-parse refs/heads/main)" = "$STAGE_OLD" ]'
  expect_true "R3 no-PR ${blocked} 有明确诊断" \
    'printf "%s\n" "$BLOCKED_OUT" | grep -Eiq "transaction|lease|human-merge|停止|changed"'
done

# refresh 之后分别改变真实 durable source；每个 case 都只能读取一次 stale
# delivery、一次 refresh，第二次 production reader 必须 BLOCK，绝不 retry。
for mutation in human-merge transaction lease retreat post-ahead post-diverged post-missing branch head main; do
  reset_fixture
  case "$mutation" in
    transaction) seed_clean_transaction noop ;;
    lease) seed_clean_transaction noop known ;;
  esac
  MUTATION="$mutation"
  run_capture MUTATION_OUT MUTATION_RC zmerge_deliver_review_with_guard_recovery
  if [ "$mutation" = transaction ] || [ "$mutation" = lease ]; then
    expect_true "R3 ${mutation} post-update provider called" \
      "[ \"\$(event_count post-${mutation})\" -ge 1 ]"
  fi
  expected_stage="$MAIN_LATEST"
  case "$mutation" in
    retreat) expected_stage="$STAGE_OLD" ;;
    post-ahead) expected_stage="$STAGE_AHEAD" ;;
    post-diverged) expected_stage="$STAGE_DIVERGED" ;;
    post-missing) expected_stage='' ;;
  esac
  actual_stage="$(git --git-dir="$STAGING" rev-parse --verify --quiet refs/heads/main 2>/dev/null || true)"
  expect_true "R3 refresh 后 ${mutation} 改变阻断 retry" \
    '[ "$MUTATION_RC" -ne 0 ] && [ "$(file_count "$TDIR/deliver-count")" = 1 ] && [ "$actual_stage" = "$expected_stage" ]'
  case "$mutation" in
    human-merge)
      expect_true 'R3 human-merge 由第二次 Issue reread 发现' \
        '[ "$(event_count issue)" -ge 2 ] && printf "%s\n" "$MUTATION_OUT" | grep -Fq human-merge'
      ;;
    transaction)
      expect_eq 'R3 transaction mutation 是真实 pending' pending \
        "$(cat "$STAGING/git-guard/transactions/mutated/receive-status")"
      expect_true 'R3 transaction mutation 由 production Guard gate 阻断' \
        'printf "%s\n" "$MUTATION_OUT" | grep -Eiq "transaction|lease|一致"'
      ;;
    lease)
      expect_eq 'R3 lease mutation 是真实 ambiguous' ambiguous \
        "$(cat "$STAGING/git-guard/transactions/mutated/lease-status")"
      expect_true 'R3 lease mutation 由 production Guard gate 阻断' \
        'printf "%s\n" "$MUTATION_OUT" | grep -Eiq "lease|transaction|一致"'
      ;;
    branch)
      expect_eq 'R3 branch mutation 真实切换到 other branch' "$OTHER_BR" \
        "$(git -C "$WT" symbolic-ref --short HEAD)"
      expect_true 'R3 branch mutation 由 production branch gate 阻断' \
        'printf "%s\n" "$MUTATION_OUT" | grep -Fq branch'
      ;;
    head)
      expect_true 'R3 HEAD mutation 真实改变且由 production HEAD gate 阻断' \
        '[ "$(git -C "$WT" rev-parse HEAD)" != "$Z_HEAD" ] && printf "%s\n" "$MUTATION_OUT" | grep -Eiq "HEAD|zreview"'
      ;;
    main)
      expect_true 'R3 main mutation 真实推进 origin/main 且要求 zsync' \
        '[ "$(git --git-dir="$ORIGIN" rev-parse refs/heads/main)" != "$MAIN_LATEST" ] && printf "%s\n" "$MUTATION_OUT" | grep -Fq zsync'
      ;;
    retreat)
      expect_true 'R3 Finding 7 retreat 在 retry 前由 POST_REFRESH 阻断' \
        'printf "%s\n" "$MUTATION_OUT" | grep -Eiq "POST_REFRESH|stale|relation"'
      ;;
    post-ahead)
      expect_true 'R3 post-refresh ahead 由 production gate 阻断' \
        'printf "%s\n" "$MUTATION_OUT" | grep -Eiq "ahead|POST_REFRESH"'
      ;;
    post-diverged)
      expect_true 'R3 post-refresh diverged 由 production gate 阻断' \
        'printf "%s\n" "$MUTATION_OUT" | grep -Eiq "diverged|POST_REFRESH"'
      ;;
    post-missing)
      expect_true 'R3 post-refresh missing 由 production gate 阻断' \
        'printf "%s\n" "$MUTATION_OUT" | grep -Eiq "missing|缺少|POST_REFRESH"'
      ;;
  esac
done

# PR 已存在时必须走完整 production reader：PR、Review、checks、Issue、Guard
# 等都由真实 reader 调用，且 branch gate 已显式包含在 full reader 中。
reset_fixture
GH_PR_STATE=exists
printf '%s\n' "$GH_PR_STATE" > "$PR_STATE_FILE"
run_capture FULL_OUT FULL_RC zmerge_recovery_pre_refresh_preflight
expect_eq 'R3 PR exists full reader PASS' 0 "$FULL_RC"
expect_true 'R3 full reader 读取 PR view' '[ "$(event_count pr-view)" -ge 1 ]'
expect_true 'R3 full reader 读取 required checks' '[ "$(event_count required)" -ge 1 ]'
expect_true 'R3 full reader 读取 Review provider' '[ "$(event_count comments)" -ge 2 ]'
expect_true 'R3 full reader 读取 Issue provider' '[ "$(event_count issue)" -ge 1 ]'

# 同一 HEAD 切到另一条 branch：只改变 symbolic ref，HEAD/OID 不变；full
# production reader 仍必须拒绝。
reset_fixture
GH_PR_STATE=exists
printf '%s\n' "$GH_PR_STATE" > "$PR_STATE_FILE"
BRANCH_OK_RC=0
zmerge_recovery_pre_refresh_preflight >/dev/null 2>&1 || BRANCH_OK_RC=$?
expect_eq 'R3 full reader 正确 branch PASS' 0 "$BRANCH_OK_RC"
git -C "$WT" branch -f "$OTHER_BR" "$Z_HEAD"
git -C "$WT" checkout -q "$OTHER_BR"
run_capture BRANCH_BAD BRANCH_BAD_RC zmerge_recovery_post_refresh_preflight
expect_true 'R3 HEAD 不变但 branch 改变 BLOCK' \
  '[ "$BRANCH_BAD_RC" -ne 0 ] && printf "%s\n" "$BRANCH_BAD" | grep -Fq branch'
git -C "$WT" checkout -q "$BR"
git -C "$WT" branch -D "$OTHER_BR" >/dev/null 2>&1 || true

# PR head 变化发生在 refresh 之后：第二次 full reader 必须重新读取 PR 并
# 在真正 retry 前停止。
reset_fixture
GH_PR_STATE=exists
printf '%s\n' "$GH_PR_STATE" > "$PR_STATE_FILE"
MUTATION=pr-head
run_capture PR_HEAD_OUT PR_HEAD_RC zmerge_deliver_review_with_guard_recovery
expect_true 'R3 refresh 后 PR head 改变 BLOCK' \
  '[ "$PR_HEAD_RC" -ne 0 ] && [ "$(file_count "$TDIR/deliver-count")" = 1 ] && [ "$(event_count pr-view)" -ge 2 ]'
expect_true 'R3 PR head mutation 有新 Review 诊断' \
  'printf "%s\n" "$PR_HEAD_OUT" | grep -Eiq "PR head|zreview|changed"'

# PR lane 不能在一次 recovery 中隐式切换或改变事实。覆盖 no-PR→PR、
# PR→no-PR，以及 matching PR 的 base/title/body/Fixes 改变；所有情况都在
# POST_REFRESH/PRE_RETRY 之前停止，delivery 计数保持 1。
reset_fixture
MUTATION=pr-appear
run_capture PR_APPEAR_OUT PR_APPEAR_RC zmerge_deliver_review_with_guard_recovery
expect_true 'R3 no-PR→PR lane change BLOCK' \
  '[ "$PR_APPEAR_RC" -ne 0 ] && [ "$(file_count "$TDIR/deliver-count")" = 1 ] && printf "%s\n" "$PR_APPEAR_OUT" | grep -Eiq "lane|PR|recovery"'

reset_fixture
GH_PR_STATE=exists
printf '%s\n' "$GH_PR_STATE" > "$PR_STATE_FILE"
MUTATION=pr-disappear
run_capture PR_DISAPPEAR_OUT PR_DISAPPEAR_RC zmerge_deliver_review_with_guard_recovery
expect_true 'R3 PR→no-PR lane change BLOCK' \
  '[ "$PR_DISAPPEAR_RC" -ne 0 ] && [ "$(file_count "$TDIR/deliver-count")" = 1 ] && printf "%s\n" "$PR_DISAPPEAR_OUT" | grep -Eiq "lane|PR|recovery"'

for pr_mutation in pr-title pr-base pr-body pr-fixes; do
  reset_fixture
  GH_PR_STATE=exists
  printf '%s\n' "$GH_PR_STATE" > "$PR_STATE_FILE"
  MUTATION="$pr_mutation"
  run_capture PR_MUTATION_OUT PR_MUTATION_RC zmerge_deliver_review_with_guard_recovery
  expect_true "R3 matching PR ${pr_mutation} change BLOCK" \
    '[ "$PR_MUTATION_RC" -ne 0 ] && [ "$(file_count "$TDIR/deliver-count")" = 1 ] && printf "%s\n" "$PR_MUTATION_OUT" | grep -Eiq "PR|title|base|body|Fixes|changed|不一致"'
done

# 静态护栏：未来若有人再把同名 decision function 放回本测试，直接失败。
for symbol in \
  guard_classify_push_failure z_require_passing_review z_require_auto_merge_safe_review \
  contract_review_validate contract_stale contract_require_diff_in_scope \
  task_fetch_issue task_find_matching_pr task_pr_view_json task_pr_fields_ok \
  contract_pr_validate z_required_contexts z_pr_checks_ok \
  guard_recovery_pre_refresh_preflight guard_recovery_post_refresh_preflight \
  zmerge_reread_all_merge_gates zmerge_reread_head_branch_main_gates \
  zmerge_reread_branch_gate zmerge_reread_recovery_common_gates \
  zmerge_recovery_pre_refresh_preflight zmerge_recovery_post_refresh_preflight \
  zmerge_recovery_pre_retry_preflight; do
  if grep -Eq "^[[:space:]]*${symbol}[[:space:]]*\(\)" "$0"; then
    bad "TOCTOU fixture 仍覆盖 production ${symbol}"
  else
    ok
  fi
done

echo "check-guard-recovery.sh: 通过 ${pass}，失败 ${fail}"
[ "$fail" = 0 ]
