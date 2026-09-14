#!/usr/bin/env bash
# Issue #13 定向测试：Developer/Fixer 交接必须是 committed + clean HEAD。
# 只用本地临时仓库；不调用 GitHub、Orca、候选 runtime 或真实 consumer。
set -Eeuo pipefail
export LC_COLLATE=C
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

# shellcheck source=/dev/null
. "$ROOT/0-meta/lib/new/core.sh"
# shellcheck source=/dev/null
. "$ROOT/0-meta/lib/new/task.sh"
# shellcheck source=/dev/null
. "$ROOT/0-meta/lib/new/contract.sh"
# shellcheck source=/dev/null
. "$ROOT/0-meta/lib/new/review.sh"
# shellcheck source=/dev/null
. "$ROOT/0-meta/lib/new/check.sh"
trap tmp_cleanup EXIT

fail=0
pass=0
TDIR=""
tmp_mkd TDIR issue-13-completion

ok() { pass=$((pass + 1)); }
bad() { printf '✗ %s\n' "$*" >&2; fail=$((fail + 1)); }

expect_eq() {
  if [ "$2" = "$3" ]; then ok; else bad "$1：期望 [$2] 实际 [$3]"; fi
}

expect_contains() {
  if printf '%s\n' "$2" | grep -Fq -- "$3"; then ok; else bad "$1：缺少 [$3]"; fi
}

expect_rc() {
  local name="$1" want="$2" got="$3"
  expect_eq "$name 返回码" "$want" "$got"
}

expect_true() {
  if eval "$2"; then ok; else bad "$1"; fi
}

git_cfg() {
  git -C "$1" config user.email issue-13@example.test
  git -C "$1" config user.name issue-13
  git -C "$1" config commit.gpgsign false
  git -C "$1" config core.hooksPath /dev/null
}

make_repo() {
  local name="$1" dir="$TDIR/$1"
  mkdir -p "$dir"
  git init --bare -q -b main "$dir/origin.git"
  git clone -q "$dir/origin.git" "$dir/main"
  git_cfg "$dir/main"
  printf '%s\n' base > "$dir/main/file.txt"
  git -C "$dir/main" add file.txt
  git -C "$dir/main" commit -qm 'chore: issue 13 fixture base'
  git -C "$dir/main" push -q -u origin main
  git -C "$dir/main" worktree add -q -b "meta/issue-13-$name" "$dir/wt" main
  git_cfg "$dir/wt"
  printf '%s\n' "$dir"
}

reset_wt() {
  local dir="$1"
  git -C "$dir/wt" reset -q --hard main
  git -C "$dir/wt" clean -fdq
}

DIR="$(make_repo cases)"
BASE_HEAD="$(git -C "$DIR/wt" rev-parse HEAD)"

# ── A1：dev / fix 共用同一个 canonical gate，三类 dirty 都拒绝 ──────
for phase in dev fix; do
  reset_wt "$DIR"
  printf '%s\n' untracked > "$DIR/wt/untracked.txt"
  if task_completion_gate "$DIR/wt" main changed >"$TDIR/${phase}-untracked.out" 2>&1; then
    bad "$phase + untracked 应拒绝"
  else
    rc=$?
    expect_rc "$phase + untracked" 1 "$rc"
    expect_contains "$phase + untracked" "$(cat "$TDIR/${phase}-untracked.out")" 'untracked=1'
  fi

  reset_wt "$DIR"
  printf '%s\n' unstaged > "$DIR/wt/file.txt"
  if task_completion_gate "$DIR/wt" main changed >"$TDIR/${phase}-unstaged.out" 2>&1; then
    bad "$phase + unstaged 应拒绝"
  else
    rc=$?
    expect_rc "$phase + unstaged" 1 "$rc"
    expect_contains "$phase + unstaged" "$(cat "$TDIR/${phase}-unstaged.out")" 'unstaged=1'
  fi

  reset_wt "$DIR"
  printf '%s\n' staged > "$DIR/wt/file.txt"
  git -C "$DIR/wt" add file.txt
  if task_completion_gate "$DIR/wt" main changed >"$TDIR/${phase}-staged.out" 2>&1; then
    bad "$phase + staged-but-uncommitted 应拒绝"
  else
    rc=$?
    expect_rc "$phase + staged-but-uncommitted" 1 "$rc"
    expect_contains "$phase + staged-but-uncommitted" "$(cat "$TDIR/${phase}-staged.out")" 'staged=1'
  fi
done

# ── A1：changed + committed + clean HEAD 可以交接 ───────────────────
reset_wt "$DIR"
printf '%s\n' committed > "$DIR/wt/file.txt"
git -C "$DIR/wt" add file.txt
git -C "$DIR/wt" commit -qm 'feat(meta): issue 13 committed fixture'
changed_head="$(git -C "$DIR/wt" rev-parse HEAD)"
if out="$(task_completion_gate "$DIR/wt" main changed 2>&1)"; then
  expect_contains 'changed + committed + clean completion' "$out" 'completion=changed'
  expect_contains 'changed + committed + clean HEAD' "$out" "HEAD=$changed_head"
  expect_eq 'changed + committed + clean status' '' "$(git -C "$DIR/wt" status --porcelain)"
else
  bad 'changed + committed + clean 应通过'
fi

# ── A1：合法 no-change 必须显式 no-change 且 clean ───────────────────
reset_wt "$DIR"
if out="$(task_completion_gate "$DIR/wt" main no-change 2>&1)"; then
  expect_contains 'no-change 结论明确' "$out" 'completion=no-change'
  expect_eq 'no-change 不新增 HEAD' "$BASE_HEAD" "$(git -C "$DIR/wt" rev-parse HEAD)"
  expect_eq 'no-change worktree clean' '' "$(git -C "$DIR/wt" status --porcelain)"
else
  bad 'clean no-change 应通过'
fi

# ── A2：git add/index.lock 失败时，不得写完成 Checkpoint ─────────────
reset_wt "$DIR"
printf '%s\n' index-lock-failure > "$DIR/wt/index-lock.txt"
mkdir -p "$DIR/index-dir/index.lock"
set +e
GIT_INDEX_FILE="$DIR/index-dir/index" git -C "$DIR/wt" add index-lock.txt >"$TDIR/index-lock-add.out" 2>&1
add_rc=$?
set -e
if [ "$add_rc" = 0 ]; then
  bad 'index.lock 夹具应让 git add 失败'
else
  expect_contains 'index.lock 失败可见' "$(cat "$TDIR/index-lock-add.out")" 'index.lock'
fi
if out="$(task_completion_gate "$DIR/wt" main changed 2>&1)"; then
  bad 'git add/index.lock 失败后不得 completion'
else
  expect_contains 'git add/index.lock 失败后 BLOCKED' "$out" 'BLOCKED'
  expect_contains 'git add/index.lock 失败后 untracked' "$out" 'untracked=1'
fi

# ── A2：git commit 失败时，不得写完成 Checkpoint ────────────────────
reset_wt "$DIR"
printf '%s\n' commit-failure > "$DIR/wt/commit-failure.txt"
git -C "$DIR/wt" add commit-failure.txt
mkdir -p "$DIR/failing-hooks"
printf '%s\n' '#!/bin/sh' 'exit 1' > "$DIR/failing-hooks/pre-commit"
chmod +x "$DIR/failing-hooks/pre-commit"
set +e
git -C "$DIR/wt" -c core.hooksPath="$DIR/failing-hooks" commit -qm 'feat(meta): should fail'
commit_rc=$?
set -e
expect_rc 'git commit 失败注入' 1 "$commit_rc"
if out="$(task_completion_gate "$DIR/wt" main changed 2>&1)"; then
  bad 'git commit 失败后不得 completion'
else
  expect_contains 'git commit 失败后 BLOCKED' "$out" 'BLOCKED'
  expect_contains 'git commit 失败后 staged' "$out" 'staged=1'
fi

# ── A2：实际交付入口在 gate 失败前不写 Checkpoint ───────────────────
delivery_ck=0
setup_delivery_fixture() {
  wt="$DIR/wt"
  git_br='meta/issue-13-cases'
  logical_br="$git_br"
  number=13
  owner=o
  repo=r
  main=main
  base_git=main
  head="$(git -C "$wt" rev-parse HEAD)"
  issue_title='issue 13'
  contract_blob=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
  contract_json="$TDIR/contract.json"
  printf '%s\n' '{"schema_version":"task-contract/v1"}' > "$contract_json"
  ws_status=干净
  scope='0-meta/lib/new/'
  evidence=''
  issue_json="$TDIR/issue.json"
  printf '%s\n' '{}' > "$issue_json"
  derived_status="$TASK_STATUS_PROGRESS"
  project_status="$TASK_STATUS_PROGRESS"
  item_json='{"id":"I1","project":{"id":"P1"},"fieldValueByName":{"field":{"id":"F1","options":[]},"name":"In progress"}}'
  TASK_PROJECT_TITLE=Tasks
  TASK_PROJECT_NUMBER=1
  task_checkpoint_body() { printf '%s' 'claim_actor=alpha'; }
  task_confirm_gh_access() { return 0; }
  task_resolve_pr_title() { TASK_PR_TITLE='feat(meta): issue 13'; TASK_PR_TITLE_SRC=review; }
  task_unique_marked_comment() { printf '%s\n' '{"body":"review"}'; }
  contract_stale() { return 1; }
  contract_review_validate() { return 0; }
  task_push_task_branch() { printf '%s\n' "$head"; }
  task_change_summary() { printf '%s\n' summary; }
  contract_pr_validate() { return 0; }
  task_ensure_pr() { printf '%s\n' '1 https://example.test/pr/1'; }
  task_write_checkpoint() { delivery_ck=$((delivery_ck + 1)); return 0; }
  task_project_item() { printf '%s' "$item_json"; }
  task_read_status_name() { printf '%s\n' "$TASK_STATUS_PROGRESS"; }
  task_set_status() { return 0; }
  task_fetch_issue() { return 0; }
}

reset_wt "$DIR"
printf '%s\n' delivery > "$DIR/wt/file.txt"
git -C "$DIR/wt" add file.txt
git -C "$DIR/wt" commit -qm 'feat(meta): issue 13 delivery fixture'
git -C "$DIR/wt" remote set-url origin https://github.com/o/r.git
setup_delivery_fixture
delivery_ck=0
if task_review_deliver >"$TDIR/delivery-success.out" 2>&1; then
  expect_eq 'committed clean delivery 写 Checkpoint' 1 "$delivery_ck"
else
  bad 'committed clean delivery 应成功'
fi

reset_wt "$DIR"
printf '%s\n' dirty-delivery > "$DIR/wt/dirty.txt"
setup_delivery_fixture
delivery_ck=0
if task_review_deliver >"$TDIR/delivery-dirty.out" 2>&1; then
  bad 'dirty delivery 应拒绝'
else
  expect_eq 'dirty delivery 不写 Checkpoint' 0 "$delivery_ck"
  expect_contains 'dirty delivery BLOCKED' "$(cat "$TDIR/delivery-dirty.out")" 'BLOCKED'
fi

# ── A3/A4：dirty review fail-closed，且 reviewer 不改工作树 ──────────
reset_wt "$DIR"
printf '%s\n' review-untracked > "$DIR/wt/review-untracked.txt"
review_before="$(git -C "$DIR/wt" status --porcelain)"
review_index_before="$(git -C "$DIR/wt" diff --cached --name-status)"
Z_WT="$DIR/wt"
Z_BASE=main
Z_MAIN=main
Z_NUMBER=13
z_require_current_main() { return 0; }
review_input="$TDIR/review.input"
printf '%s\n' 'not parsed because completion gate must fail' > "$review_input"
if out="$(review_publish "$review_input" 2>&1)"; then
  bad 'dirty review 应拒绝'
else
  expect_contains 'dirty review 报 HEAD' "$out" 'HEAD='
  expect_contains 'dirty review 报 untracked 数量' "$out" 'untracked=1'
  expect_contains 'dirty review 报 unstaged 数量' "$out" 'unstaged=0'
  expect_contains 'dirty review 报 staged 数量' "$out" 'staged=0'
fi
expect_eq 'review 不自动 add/commit/stash/delete' "$review_before" "$(git -C "$DIR/wt" status --porcelain)"
expect_eq 'review 不改变 staged 集合' "$review_index_before" "$(git -C "$DIR/wt" diff --cached --name-status)"
expect_true 'review 不删除 untracked' '[ -f "$DIR/wt/review-untracked.txt" ]'

# ── A2/A3：commit-tier PASS 只说明 staged 检查，不是 completion ──────
FRAME="$TDIR/framework"
mkdir -p "$FRAME"
git clone -q --no-hardlinks "$ROOT" "$FRAME/main"
git_cfg "$FRAME/main"
git -C "$FRAME/main" worktree add -q -b meta/issue-13-check "$FRAME/wt" main
git_cfg "$FRAME/wt"
printf '%s\n' commit-tier-only > "$FRAME/wt/0-meta/lib/new/commit-tier-only.txt"
if check_out="$(cd "$FRAME/wt" && 0-meta/bin/new check --tier commit 2>&1)"; then
  expect_contains 'commit-tier dirty PASS 明确范围' "$check_out" '只检查暂存区'
  expect_contains 'commit-tier dirty PASS 不构成 completion' "$check_out" '不构成'
  expect_contains 'commit-tier dirty PASS 报 untracked' "$check_out" 'untracked=1'
  expect_eq 'commit-tier PASS 未生成 HEAD' "$(git -C "$FRAME/main" rev-parse HEAD)" "$(git -C "$FRAME/wt" rev-parse HEAD)"
else
  bad 'dirty + staged=0 的 commit-tier fixture 应按原语义返回 0'
fi

# ── A2 正向 linked worktree：add → check → commit → clean HEAD ──────
reset_wt "$DIR"
printf '%s\n' linked-positive > "$DIR/wt/linked-positive.txt"
git -C "$DIR/wt" add linked-positive.txt
if linked_check="$(cd "$DIR/wt" && git diff --cached --name-only 2>&1)"; then
  expect_contains 'linked worktree add 进入 index' "$linked_check" linked-positive.txt
else
  bad 'linked worktree git add 应成功'
fi
positive_before="$(git -C "$DIR/wt" rev-parse HEAD)"
if git -C "$DIR/wt" commit -qm 'feat(meta): linked completion fixture'; then
  expect_eq 'linked worktree commit 后 clean' '' "$(git -C "$DIR/wt" status --porcelain)"
  positive_after="$(git -C "$DIR/wt" rev-parse HEAD)"
  [ "$positive_before" != "$positive_after" ] && ok || bad 'linked worktree commit 应推进 HEAD'
  if out="$(task_completion_gate "$DIR/wt" main changed 2>&1)"; then
    expect_contains 'linked worktree completion' "$out" 'completion=changed'
  else
    bad 'linked worktree clean HEAD 应通过 completion'
  fi
else
  bad 'linked worktree commit 应成功'
fi

if [ "$fail" -ne 0 ]; then
  printf '✗ Issue #13 completion 定向测试失败：%s 项（通过 %s）\n' "$fail" "$pass" >&2
  exit 1
fi
printf '✓ Issue #13 completion 定向测试通过（%s）\n' "$pass"
