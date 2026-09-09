#!/usr/bin/env bash
# 定向测试：zmerge 互斥 / 持锁复读 / 幂等 finalize / 本地 main ff-only（A1–A6）
# 以及 #38 fail-closed / 安全删分支 / 锁返回码（38-A1–A5）、
# #40 squash 等价证明与 mergeCommit 未观察（40-A1/A2/A4）。
# 不调用真实 GitHub；远端用本地 bare 仓。
set -Eeuo pipefail
export LC_COLLATE=C
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "✗ 不在 git 工作树" >&2; exit 1; }
# shellcheck source=/dev/null
. "$ROOT/0-meta/lib/new/core.sh"
# shellcheck source=/dev/null
. "$ROOT/0-meta/lib/new/task.sh"
# shellcheck source=/dev/null
. "$ROOT/.agents/skills/z-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/.agents/skills/zmerge/scripts/squash-body.sh"
# shellcheck source=/dev/null
. "$ROOT/.agents/skills/zmerge/scripts/merge-lib.sh"
trap 'z_merge_lock_release; tmp_cleanup' EXIT

fail=0
pass=0
TDIR=""
tmp_mkd TDIR zmerge-finalize-test
export XDG_STATE_HOME="$TDIR/state"
MOCK="$TDIR/mockbin"
mkdir -p "$MOCK"
COUNT_DIR="$TDIR/counts"
mkdir -p "$COUNT_DIR"
zero() { printf '0\n' > "$COUNT_DIR/$1"; }
bump() {
  local f="$COUNT_DIR/$1" n
  n="$(cat "$f" 2>/dev/null || echo 0)"
  printf '%s\n' "$((n+1))" > "$f"
}
got() { cat "$COUNT_DIR/$1"; }

printf '%s\n' '[]' > "$TDIR/merged.json"
printf '%s\n' '[]' > "$TDIR/open.json"
printf '%s\n' '[]' > "$TDIR/all.json"
export GH_MERGED_FIXTURE="$TDIR/merged.json"
export GH_OPEN_FIXTURE="$TDIR/open.json"
export GH_ALL_FIXTURE="$TDIR/all.json"
export GH_PR_VIEW_FIXTURE="$TDIR/pr-view.json"
printf '%s\n' '{}' > "$GH_PR_VIEW_FIXTURE"
export COUNT_DIR

cat > "$MOCK/gh" <<'EOF'
#!/bin/bash
if [ "$1" = pr ] && [ "$2" = list ]; then
  state=open
  prev=""
  for a in "$@"; do
    if [ "$prev" = --state ]; then state="$a"; fi
    prev="$a"
  done
  case "$state" in
    merged)
      if [ "${GH_MERGED_FAIL:-}" = 1 ]; then
        echo "gh pr list merged failed" >&2
        exit 1
      fi
      cat "${GH_MERGED_FIXTURE}"
      ;;
    all)
      if [ "${GH_ALL_FAIL:-}" = 1 ]; then
        echo "gh pr list all failed" >&2
        exit 1
      fi
      cat "${GH_ALL_FIXTURE}"
      ;;
    *) cat "${GH_OPEN_FIXTURE}" ;;
  esac
  exit 0
fi
if [ "$1" = pr ] && [ "$2" = merge ]; then
  n="$(cat "${COUNT_DIR}/merge" 2>/dev/null || echo 0)"
  printf '%s\n' "$((n+1))" > "${COUNT_DIR}/merge"
  exit "${GH_MERGE_RC:-0}"
fi
if [ "$1" = pr ] && [ "$2" = view ]; then
  n="$(cat "${COUNT_DIR}/view" 2>/dev/null || echo 0)"
  printf '%s\n' "$((n+1))" > "${COUNT_DIR}/view"
  cat "${GH_PR_VIEW_FIXTURE}"
  exit 0
fi
if [ "$1" = issue ]; then
  printf '%s\n' '{"state":"CLOSED","stateReason":"COMPLETED"}'
  exit 0
fi
if [ "$1" = api ]; then
  printf '%s\n' 'feat(meta): x\n\n背景\n- x\n'
  exit 0
fi
echo "unexpected gh $*" >&2
exit 1
EOF
chmod +x "$MOCK/gh"
export PATH="$MOCK:$PATH"

ok() { pass=$((pass+1)); }
bad() { echo "✗ $*" >&2; fail=$((fail+1)); }
expect_eq() {
  if [ "$2" = "$3" ]; then ok
  else bad "$1: 期望 [$2] 实际 [$3]"; fi
}
expect_true() { if eval "$2"; then ok; else bad "$1"; fi; }

git_cfg() {
  git -C "$1" config user.email t@t
  git -C "$1" config user.name t
  git -C "$1" config commit.gpgsign false
  git -C "$1" config core.hooksPath /dev/null
}

make_pair() {
  local dest="$1"
  mkdir -p "$dest/wt"
  git init -q -b main "$dest/wt"
  git_cfg "$dest/wt"
  printf 'base\n' > "$dest/wt/f.txt"
  git -C "$dest/wt" add f.txt
  git -C "$dest/wt" commit -qm base
  git init --bare -q -b main "$dest/origin.git"
  git -C "$dest/wt" remote add origin "$dest/origin.git"
  git -C "$dest/wt" push -qu origin main >/dev/null
}

setup_z() {
  Z_WT="$1"
  Z_MAIN=main
  Z_OWNER=o
  Z_REPO=r
  Z_NUMBER=21
  Z_GIT_BR="${2:-task-21}"
  Z_HEAD="$(git -C "$Z_WT" rev-parse HEAD)"
  Z_SQUASH_TITLE="feat(meta): x"
  Z_CONTRACT_BLOB=deadbeef
  Z_SCOPE=".agents/skills/zmerge/"
  ZMERGE_MERGED_PR=""
  Z_ISSUE_JSON="$TDIR/issue.json"
  printf '%s\n' '{"data":{"repository":{"issue":{"body":"","id":"I"}}}}' > "$Z_ISSUE_JSON"
  z_wait_auto_close() { return 0; }
}

# ── A1：第二把锁立即失败，第一把不受影响 ─────────
A1="$TDIR/a1"
make_pair "$A1"
cd "$A1/wt"
zero merge
(
  set +e
  if z_merge_lock_acquire; then
    printf 'held\n' > "$A1/held"
    sleep 8
    z_merge_lock_release
  else
    printf 'fail\n' > "$A1/held.fail"
  fi
) &
a1pid=$!
for i in $(seq 1 40); do
  [ -f "$A1/held" ] || [ -f "$A1/held.fail" ] && break
  sleep 0.1
done
expect_true "A1 第一把锁已持有" '[ -f "$A1/held" ]'
a1rc=0
z_merge_lock_acquire || a1rc=$?
expect_eq "A1 第二把立即占用" 2 "$a1rc"
expect_true "A1 第一把仍在" 'kill -0 "$a1pid" 2>/dev/null'
kill "$a1pid" 2>/dev/null || true
wait "$a1pid" 2>/dev/null || true
z_merge_lock_release

# ── A2：持锁后 Review stale / PR head 变 / main 前进 → merge 前停 ─
A2="$TDIR/a2"
make_pair "$A2"
cd "$A2/wt"
git -C "$A2/wt" checkout -qb task-21
setup_z "$A2/wt" task-21
zero merge

a2lock=0
z_merge_lock_acquire || a2lock=$?
expect_eq "A2 拿到锁" 0 "$a2lock"

z_require_passing_review() { err_code z.no_passing_review "Review stale"; return 1; }
z_fetch_origin_main() { return 0; }
z_main_is_current() { return 0; }
a2rc=0
zmerge_reread_before_merge >/dev/null 2>"$A2/stale.err" || a2rc=$?
expect_eq "A2 Review stale 停在 merge 前" 1 "$a2rc"
expect_eq "A2 Review stale 未 merge" 0 "$(got merge)"
expect_true "A2 Review stale 有说明" 'grep -q "Review stale\|没有当前 HEAD\|z.no_passing_review\|通过 Review" "$A2/stale.err"'

z_require_passing_review() { return 0; }
z_require_auto_merge_safe_review() { return 0; }
contract_fetch_main() { return 0; }
contract_main_blob() { printf '%s\n' deadbeef; }
contract_stale() { return 1; }
task_find_matching_pr() { printf '%s\n' '{"number":3}'; }
task_pr_view_json() {
  jq -n --arg h "ffffffffffff" '{title:"feat(meta): x",headRefOid:$h,state:"OPEN",isDraft:false}'
}
task_pr_fields_ok() { return 0; }
task_fetch_issue() { return 0; }
derive_task_state() { printf '%s\n' "$TASK_STATUS_REVIEW"; }
task_read_status_name() { printf '%s\n' "$TASK_STATUS_REVIEW"; }
a2rc=0
zmerge_reread_before_merge >/dev/null 2>"$A2/head.err" || a2rc=$?
expect_eq "A2 PR head 变化停止" 1 "$a2rc"
expect_eq "A2 PR head 变化未 merge" 0 "$(got merge)"

# origin/main 前进：恢复真实 fetch/ancestor，推进 origin。
unset -f z_fetch_origin_main z_main_is_current
# shellcheck source=/dev/null
. "$ROOT/.agents/skills/z-lib.sh"
git clone -q "$A2/origin.git" "$A2/other"
git_cfg "$A2/other"
printf 'moved\n' >> "$A2/other/f.txt"
git -C "$A2/other" add f.txt
git -C "$A2/other" commit -qm moved
git -C "$A2/other" push -q origin main
a2rc=0
zmerge_reread_before_merge >/dev/null 2>"$A2/main.err" || a2rc=$?
expect_eq "A2 main 前进停止" 1 "$a2rc"
if grep -Eq "zsync|main 已前进" "$A2/main.err"; then ok
else
  bad "A2 main 前进提示 zsync"
  sed 's/^/    /' "$A2/main.err" >&2 || true
fi
expect_eq "A2 main 前进未 merge" 0 "$(got merge)"

# Project Status=Backlog，推导 In review：继续，只警告。
git -C "$A2/wt" fetch -q origin main
git -C "$A2/wt" rebase origin/main >/dev/null
Z_HEAD="$(git -C "$A2/wt" rev-parse HEAD)"
z_fetch_origin_main() { return 0; }
z_main_is_current() { return 0; }
z_require_passing_review() { return 0; }
z_require_auto_merge_safe_review() { return 0; }
contract_fetch_main() { return 0; }
contract_main_blob() { printf '%s\n' deadbeef; }
contract_stale() { return 1; }
task_find_matching_pr() { printf '%s\n' '{"number":3}'; }
task_pr_view_json() {
  jq -n --arg h "$Z_HEAD" '{title:"feat(meta): x",headRefOid:$h,state:"OPEN",isDraft:false}'
}
task_pr_fields_ok() { return 0; }
task_fetch_issue() { return 0; }
derive_task_state() { printf '%s\n' "$TASK_STATUS_REVIEW"; }
task_read_status_name() { printf '%s\n' "$TASK_STATUS_BACKLOG"; }
a2out="$(zmerge_reread_before_merge 2>&1)" && a2rc=0 || a2rc=$?
printf '%s\n' "$a2out" > "$A2/drift.out"
expect_eq "A2 漂移仍继续" 0 "$a2rc"
expect_true "A2 漂移警告" 'printf "%s\n" "$a2out" | grep -Fq "Project Status 是 Backlog"'
expect_eq "A2 漂移未 merge" 0 "$(got merge)"
z_merge_lock_release
# 清掉 A2 的函数覆盖，避免污染后续。
unset -f z_require_passing_review z_require_auto_merge_safe_review contract_fetch_main contract_main_blob \
  contract_stale task_find_matching_pr task_pr_view_json task_pr_fields_ok \
  task_fetch_issue derive_task_state task_read_status_name \
  z_fetch_origin_main z_main_is_current
# shellcheck source=/dev/null
. "$ROOT/0-meta/lib/new/core.sh"
# shellcheck source=/dev/null
. "$ROOT/0-meta/lib/new/task.sh"
# shellcheck source=/dev/null
. "$ROOT/.agents/skills/z-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/.agents/skills/zmerge/scripts/squash-body.sh"
# shellcheck source=/dev/null
. "$ROOT/.agents/skills/zmerge/scripts/merge-lib.sh"
z_wait_auto_close() { return 0; }

# ── A3：merge 成功后删分支失败；再跑只 finalize ──
A3="$TDIR/a3"
make_pair "$A3"
cd "$A3/wt"
setup_z "$A3/wt" task-21
zero merge
zero delete
zmerge_delete_remote_branch() { bump delete; return 1; }
a3out="$(zmerge_finalize 1 2>&1)" && a3rc=0 || a3rc=$?
expect_eq "A3 第一次 finalize 失败" 1 "$a3rc"
expect_true "A3 文案" 'printf "%s\n" "$a3out" | grep -Fq "远端已合并;finalize 未完成:删除远端分支"'
expect_eq "A3 第一次未调用 merge" 0 "$(got merge)"
expect_eq "A3 第一次尝试删除" 1 "$(got delete)"

jq -n --arg br task-21 \
  '[{number:9,headRefName:$br,baseRefName:"main",state:"MERGED",title:"feat(meta): x",mergeCommit:{oid:""}}]' \
  > "$GH_MERGED_FIXTURE"
printf '%s\n' '[]' > "$GH_OPEN_FIXTURE"
cat "$GH_MERGED_FIXTURE" > "$GH_ALL_FIXTURE"
zmerge_delete_remote_branch() { bump delete; return 0; }
z_wait_auto_close() { return 0; }
a3out2="$(zmerge_run_locked 2>&1)" && a3rc=0 || a3rc=$?
expect_eq "A3 再次 finalize 成功" 0 "$a3rc"
expect_eq "A3 再次仍不 merge" 0 "$(got merge)"
expect_eq "A3 再次完成删除" 2 "$(got delete)"
expect_true "A3 跳过 merge" 'printf "%s\n" "$a3out2" | grep -Fq "跳过 gh pr merge"'
# 覆盖过的函数要重新加载，unset -f 不会恢复原稿。
# shellcheck source=/dev/null
. "$ROOT/.agents/skills/zmerge/scripts/merge-lib.sh"
z_wait_auto_close() { return 0; }

# ── A4：已 MERGED 连跑三次，merge=0 ──
A4="$TDIR/a4"
make_pair "$A4"
cd "$A4/wt"
setup_z "$A4/wt" task-21
zero merge
jq -n --arg br task-21 \
  '[{number:9,headRefName:$br,baseRefName:"main",state:"MERGED",title:"feat(meta): x",mergeCommit:{oid:""}}]' \
  > "$GH_MERGED_FIXTURE"
cat "$GH_MERGED_FIXTURE" > "$GH_ALL_FIXTURE"
printf '%s\n' '[]' > "$GH_OPEN_FIXTURE"
z_wait_auto_close() { return 0; }
a4n=0
for i in 1 2 3; do
  if zmerge_run_locked >"$A4/run$i.out" 2>&1; then
    a4n=$((a4n + 1))
  else
    printf 'A4 run %s failed:\n' "$i" >&2
    cat "$A4/run$i.out" >&2
  fi
done
expect_eq "A4 三次都退出 0" 3 "$a4n"
expect_eq "A4 merge 次数为 0" 0 "$(got merge)"

# ── A5：ff-only 与拒绝改历史 ──
A5="$TDIR/a5"
make_pair "$A5"
git clone -q "$A5/origin.git" "$A5/other"
git_cfg "$A5/other"
printf 'ahead\n' >> "$A5/other/f.txt"
git -C "$A5/other" add f.txt
git -C "$A5/other" commit -qm ahead
git -C "$A5/other" push -q origin main
# 主工作区：A5/wt 仍在旧 main；任务树另挂。
git -C "$A5/wt" fetch -q origin main
git -C "$A5/wt" worktree add -q -b task-21 "$A5/task" origin/main
git_cfg "$A5/task"
cd "$A5/task"
setup_z "$A5/task" task-21
Z_WT="$A5/task"
before="$(git -C "$A5/wt" rev-parse HEAD)"
want="$(git -C "$A5/wt" rev-parse origin/main)"
a5out="$(zmerge_ff_local_main 2>&1)" && a5rc=0 || a5rc=$?
after="$(git -C "$A5/wt" rev-parse HEAD)"
expect_eq "A5 干净落后 ff 成功" 0 "$a5rc"
if [ "$after" = "$want" ]; then ok
else
  bad "A5 ff 后与 origin/main 一致: 期望 [$want] 实际 [$after]"
  printf '%s\n' "$a5out" | sed 's/^/    /' >&2
  git -C "$A5/task" worktree list --porcelain >&2 || true
fi
expect_true "A5 ff 说明" 'printf "%s\n" "$a5out" | grep -Fq "ff-only"'
[ "$before" != "$after" ] && ok || bad "A5 应真正快进"

# dirty
printf 'dirty\n' > "$A5/wt/dirty.txt"
a5out="$(zmerge_ff_local_main 2>&1)" && a5rc=0 || a5rc=$?
expect_eq "A5 dirty 不失败" 0 "$a5rc"
expect_true "A5 dirty 只报告" 'printf "%s\n" "$a5out" | grep -Fq "本地 main 未同步"'
expect_eq "A5 dirty 不改 HEAD" "$want" "$(git -C "$A5/wt" rev-parse HEAD)"
rm -f "$A5/wt/dirty.txt"

# 分叉
printf 'side\n' > "$A5/wt/side.txt"
git -C "$A5/wt" add side.txt
git -C "$A5/wt" commit -qm side
diverged="$(git -C "$A5/wt" rev-parse HEAD)"
a5out="$(zmerge_ff_local_main 2>&1)" && a5rc=0 || a5rc=$?
expect_eq "A5 分叉不失败" 0 "$a5rc"
expect_true "A5 分叉只报告" 'printf "%s\n" "$a5out" | grep -Fq "本地 main 未同步"'
expect_eq "A5 分叉不改历史" "$diverged" "$(git -C "$A5/wt" rev-parse HEAD)"
git -C "$A5/wt" reset --hard origin/main >/dev/null

# busy
: > "$A5/wt/.git/MERGE_HEAD"
a5out="$(zmerge_ff_local_main 2>&1)" && a5rc=0 || a5rc=$?
expect_eq "A5 busy 不失败" 0 "$a5rc"
expect_true "A5 busy 只报告" 'printf "%s\n" "$a5out" | grep -Fq "本地 main 未同步"'
expect_eq "A5 busy 不改 HEAD" "$(git -C "$A5/wt" rev-parse origin/main)" "$(git -C "$A5/wt" rev-parse HEAD)"
rm -f "$A5/wt/.git/MERGE_HEAD"

# 无法唯一定位：没有 checkout main 的工作树
git -C "$A5/wt" switch -q -c not-main
a5out="$(zmerge_ff_local_main 2>&1)" && a5rc=0 || a5rc=$?
expect_eq "A5 无法定位不失败" 0 "$a5rc"
expect_true "A5 无法定位只报告" 'printf "%s\n" "$a5out" | grep -Fq "本地 main 未同步"'
git -C "$A5/wt" switch -q main

# ── A6：无新 Checkpoint 字段 / 无步骤记录；旧夹具仍过 ──
A6src="$ROOT/.agents/skills/zmerge/scripts"
if grep -ERn -- 'Last successful step|last_successful_step|步骤指针|finalize_step' \
    "$A6src/merge-lib.sh" "$A6src/squash-merge.sh" "$ROOT/.agents/skills/z-lib.sh"; then
  bad "A6 引入了步骤记录字段"
else
  ok
fi
if grep -ERn -- '<!-- new-task-checkpoint-step -->' \
    "$A6src/merge-lib.sh" "$A6src/squash-merge.sh" "$A6src/hold-lock.py"; then
  bad "A6 新增了 Checkpoint 字段标记"
else
  ok
fi
if ( cd "$ROOT" && "$A6src/check-squash-body.sh" >/dev/null ); then
  ok
else
  bad "A6 合入前门禁夹具失败"
fi

# ── #38 A1：merged 成功、all 失败 → fail-closed，不 finalize、不删分支 ──
F1="$TDIR/f1"
make_pair "$F1"
cd "$F1/wt"
setup_z "$F1/wt" task-21
git -C "$F1/wt" push -q origin HEAD:refs/heads/task-21
zero merge
printf '%s\n' '[]' > "$GH_MERGED_FIXTURE"
printf '%s\n' '[]' > "$GH_ALL_FIXTURE"
printf '%s\n' '[]' > "$GH_OPEN_FIXTURE"
export GH_ALL_FAIL=1
METRICS_REASON_CODE=""
ZMERGE_ACTION=""
f1rc=0
zmerge_run_locked >"$F1/out" 2>"$F1/err" || f1rc=$?
unset GH_ALL_FAIL
expect_eq "38-A1 非 0" 1 "$f1rc"
expect_eq "38-A1 reason" z.pr_list_failed "$METRICS_REASON_CODE"
expect_eq "38-A1 未 merge" 0 "$(got merge)"
expect_eq "38-A1 未 finalize" "" "${ZMERGE_ACTION:-}"
expect_true "38-A1 不进 finalize 文案" '! grep -Fq "跳过 gh pr merge" "$F1/out" && ! grep -Fq "只 finalize" "$F1/out"'
expect_true "38-A1 远端分支仍在" \
  'git -C "$F1/wt" ls-remote --exit-code origin refs/heads/task-21 >/dev/null'

# ── #38 A2：远端 tip 被推进 → ancestor 失败或 lease stale，提交仍在 ──
F2="$TDIR/f2"
make_pair "$F2"
git clone -q "$F2/origin.git" "$F2/other"
git_cfg "$F2/other"
cd "$F2/wt"
setup_z "$F2/wt" task-21
git -C "$F2/wt" push -q origin HEAD:refs/heads/task-21
# 别处把任务分支推到不在 main 上的提交。
printf 'moved\n' >> "$F2/other/f.txt"
git -C "$F2/other" add f.txt
git -C "$F2/other" commit -qm moved
git -C "$F2/other" push -q origin HEAD:refs/heads/task-21
moved="$(git -C "$F2/other" rev-parse HEAD)"
METRICS_REASON_CODE=""
f2rc=0
zmerge_delete_remote_branch >"$F2/out" 2>"$F2/err" || f2rc=$?
expect_eq "38-A2 ancestor 拒绝" 1 "$f2rc"
expect_eq "38-A2 reason" z.delete_branch_not_in_main "$METRICS_REASON_CODE"
expect_true "38-A2 新 tip 仍在" \
  'git -C "$F2/wt" ls-remote origin refs/heads/task-21 | grep -q "^${moved}"'
expect_true "38-A2 提交仍在 origin" \
  'git --git-dir="$F2/origin.git" cat-file -e "${moved}^{commit}"'

# lease stale：读到的 tip 仍在 main，但读完后远端被推进。
F2L="$TDIR/f2lease"
make_pair "$F2L"
git clone -q "$F2L/origin.git" "$F2L/other"
git_cfg "$F2L/other"
cd "$F2L/wt"
setup_z "$F2L/wt" task-21
git -C "$F2L/wt" push -q origin HEAD:refs/heads/task-21
REAL_GIT="$(command -v git)"
export REAL_GIT
export F2L_ONCE="$F2L/ls.once"
export F2L_OTHER="$F2L/other"
export F2L_BR=task-21
mkdir -p "$F2L/mockgit"
cat > "$F2L/mockgit/git" <<'EOF'
#!/bin/bash
if printf '%s\n' "$@" | grep -qx ls-remote \
   && printf '%s\n' "$@" | grep -qx "refs/heads/${F2L_BR}"; then
  "$REAL_GIT" "$@"
  rc=$?
  if [ ! -f "$F2L_ONCE" ]; then
    touch "$F2L_ONCE"
    printf 'lease\n' >> "$F2L_OTHER/f.txt"
    "$REAL_GIT" -C "$F2L_OTHER" add f.txt
    "$REAL_GIT" -C "$F2L_OTHER" commit -qm lease-move
    "$REAL_GIT" -C "$F2L_OTHER" push -q origin HEAD:refs/heads/task-21
  fi
  exit "$rc"
fi
exec "$REAL_GIT" "$@"
EOF
chmod +x "$F2L/mockgit/git"
lease_tip="$("$REAL_GIT" -C "$F2L/other" rev-parse HEAD 2>/dev/null || true)"
PATH="$F2L/mockgit:$PATH"
METRICS_REASON_CODE=""
f2lrc=0
zmerge_delete_remote_branch >"$F2L/out" 2>"$F2L/err" || f2lrc=$?
PATH="${PATH#"$F2L/mockgit:"}"
lease_now="$(git -C "$F2L/wt" ls-remote origin refs/heads/task-21 | awk '{print $1; exit}')"
expect_eq "38-A2 lease 拒绝" 1 "$f2lrc"
expect_eq "38-A2 lease reason" z.delete_branch_lease_stale "$METRICS_REASON_CODE"
expect_true "38-A2 lease 后分支仍在" '[ -n "$lease_now" ]'
expect_true "38-A2 lease 新 tip 不是读到的 main tip" '[ "$lease_now" != "$(git -C "$F2L/wt" rev-parse origin/main)" ]'
expect_true "38-A2 lease 提交仍在" \
  'git --git-dir="$F2L/origin.git" cat-file -e "${lease_now}^{commit}"'

# ── #38 A3：tip 已在 main 且 lease 一致 → porcelain=deleted ──
F3="$TDIR/f3"
make_pair "$F3"
cd "$F3/wt"
setup_z "$F3/wt" task-21
git -C "$F3/wt" push -q origin HEAD:refs/heads/task-21
METRICS_REASON_CODE=""
f3rc=0
zmerge_delete_remote_branch >"$F3/out" 2>"$F3/err" || f3rc=$?
expect_eq "38-A3 删除成功" 0 "$f3rc"
expect_true "38-A3 porcelain deleted" 'grep -Fq "porcelain=deleted" "$F3/out"'
expect_true "38-A3 远端已无分支" \
  '! git -C "$F3/wt" ls-remote --exit-code origin refs/heads/task-21 >/dev/null 2>&1'

# ── #40 A1：squash 后 tip 不在 main，但 PR 的 head/merge 等价证明成立 ──
S1="$TDIR/s1"
make_pair "$S1"
cd "$S1/wt"
git -C "$S1/wt" checkout -qb task-40
printf 'task\n' > "$S1/wt/task.txt"
git -C "$S1/wt" add task.txt
git -C "$S1/wt" commit -qm task-tip
s1tip="$(git -C "$S1/wt" rev-parse HEAD)"
git -C "$S1/wt" push -q origin HEAD:refs/heads/task-40
git -C "$S1/wt" switch -q main
printf 'task\n' > "$S1/wt/task.txt"
git -C "$S1/wt" add task.txt
git -C "$S1/wt" commit -qm squash-equivalent
s1merge="$(git -C "$S1/wt" rev-parse HEAD)"
git -C "$S1/wt" push -q origin main
git -C "$S1/wt" switch -q task-40
setup_z "$S1/wt" task-40
ZMERGE_MERGED_PR="$(jq -nc --arg head "$s1tip" --arg merge "$s1merge" \
  '{state:"MERGED",headRefName:"task-40",baseRefName:"main",headRefOid:$head,mergeCommit:{oid:$merge}}')"
METRICS_REASON_CODE=""
s1rc=0
zmerge_delete_remote_branch >"$S1/out" 2>"$S1/err" || s1rc=$?
expect_eq "40-A1 squash 等价证明后删除成功" 0 "$s1rc"
expect_true "40-A1 porcelain deleted" 'grep -Fq "porcelain=deleted" "$S1/out"'
expect_true "40-A1 远端已无分支" \
  '! git -C "$S1/wt" ls-remote --exit-code origin refs/heads/task-40 >/dev/null 2>&1'

# ── #40 A2：证明建立后远端 tip 被推进，headRefOid 不匹配时拒绝 ──
S2="$TDIR/s2"
make_pair "$S2"
cd "$S2/wt"
git -C "$S2/wt" checkout -qb task-40
printf 'task\n' > "$S2/wt/task.txt"
git -C "$S2/wt" add task.txt
git -C "$S2/wt" commit -qm task-tip
s2tip="$(git -C "$S2/wt" rev-parse HEAD)"
git -C "$S2/wt" push -q origin HEAD:refs/heads/task-40
git -C "$S2/wt" switch -q main
printf 'task\n' > "$S2/wt/task.txt"
git -C "$S2/wt" add task.txt
git -C "$S2/wt" commit -qm squash-equivalent
s2merge="$(git -C "$S2/wt" rev-parse HEAD)"
git -C "$S2/wt" push -q origin main
git clone -q "$S2/origin.git" "$S2/other"
git_cfg "$S2/other"
git -C "$S2/other" switch -q -c task-40 --track origin/task-40
printf 'advanced\n' >> "$S2/other/task.txt"
git -C "$S2/other" add task.txt
git -C "$S2/other" commit -qm advanced-tip
git -C "$S2/other" push -q origin task-40
s2advanced="$(git -C "$S2/other" rev-parse HEAD)"
git -C "$S2/wt" switch -q task-40
setup_z "$S2/wt" task-40
ZMERGE_MERGED_PR="$(jq -nc --arg head "$s2tip" --arg merge "$s2merge" \
  '{state:"MERGED",headRefName:"task-40",baseRefName:"main",headRefOid:$head,mergeCommit:{oid:$merge}}')"
METRICS_REASON_CODE=""
s2rc=0
zmerge_delete_remote_branch >"$S2/out" 2>"$S2/err" || s2rc=$?
expect_eq "40-A2 推进后拒绝删除" 1 "$s2rc"
expect_eq "40-A2 reason" z.delete_branch_not_in_main "$METRICS_REASON_CODE"
expect_true "40-A2 新 tip 仍在" \
  'git -C "$S2/wt" ls-remote origin refs/heads/task-40 | grep -q "^${s2advanced}"'
expect_true "40-A2 新提交仍在" \
  'git --git-dir="$S2/origin.git" cat-file -e "${s2advanced}^{commit}"'

# ── #40 A4：MERGED 但 mergeCommit 为空 → unobserved，不删、不二次 merge ──
S4="$TDIR/s4"
make_pair "$S4"
cd "$S4/wt"
git -C "$S4/wt" checkout -qb task-40
printf 'task\n' > "$S4/wt/task.txt"
git -C "$S4/wt" add task.txt
git -C "$S4/wt" commit -qm task-tip
s4tip="$(git -C "$S4/wt" rev-parse HEAD)"
git -C "$S4/wt" push -q origin HEAD:refs/heads/task-40
setup_z "$S4/wt" task-40
ZMERGE_MERGED_PR="$(jq -nc --arg head "$s4tip" \
  '{state:"MERGED",headRefName:"task-40",baseRefName:"main",headRefOid:$head,mergeCommit:null}')"
zero merge
METRICS_REASON_CODE=""
s4rc=0
zmerge_delete_remote_branch >"$S4/out" 2>"$S4/err" || s4rc=$?
expect_eq "40-A4 空 mergeCommit 拒绝删除" 1 "$s4rc"
expect_eq "40-A4 reason" z.merge_commit_unobserved "$METRICS_REASON_CODE"
expect_eq "40-A4 未二次 merge" 0 "$(got merge)"
expect_true "40-A4 远端分支仍在" \
  'git -C "$S4/wt" ls-remote --exit-code origin refs/heads/task-40 >/dev/null'

jq -nc --arg head "$s4tip" \
  '{state:"MERGED",title:"feat(meta): x",headRefOid:$head,mergeCommit:null}' \
  > "$GH_PR_VIEW_FIXTURE"
zero view
export ZMERGE_MERGE_COMMIT_TRIES=2
export ZMERGE_MERGE_COMMIT_SLEEP=0
METRICS_REASON_CODE=""
s4obs=0
zmerge_observe_merge_commit o r 9 >"$S4/obs.out" 2>"$S4/obs.err" || s4obs=$?
unset ZMERGE_MERGE_COMMIT_TRIES ZMERGE_MERGE_COMMIT_SLEEP
expect_eq "40-A4 回读空 mergeCommit 非 0" 1 "$s4obs"
expect_eq "40-A4 回读 reason" z.merge_commit_unobserved "$METRICS_REASON_CODE"
expect_eq "40-A4 回读未 merge" 0 "$(got merge)"
expect_eq "40-A4 有界重试 view" 2 "$(got view)"

# ── #40 查询路径：不设 ZMERGE_MERGED_PR，对齐 ceshi test zmerge ──
S1L="$TDIR/s1l"
make_pair "$S1L"
cd "$S1L/wt"
git -C "$S1L/wt" checkout -qb task-40
printf 'task\n' > "$S1L/wt/task.txt"
git -C "$S1L/wt" add task.txt
git -C "$S1L/wt" commit -qm task-tip
s1ltip="$(git -C "$S1L/wt" rev-parse HEAD)"
git -C "$S1L/wt" push -q origin HEAD:refs/heads/task-40
git -C "$S1L/wt" switch -q main
printf 'task\n' > "$S1L/wt/task.txt"
git -C "$S1L/wt" add task.txt
git -C "$S1L/wt" commit -qm squash-equivalent
s1lmerge="$(git -C "$S1L/wt" rev-parse HEAD)"
git -C "$S1L/wt" push -q origin main
git -C "$S1L/wt" switch -q task-40
setup_z "$S1L/wt" task-40
jq -nc --arg head "$s1ltip" --arg merge "$s1lmerge" \
  '[{state:"MERGED",headRefName:"task-40",baseRefName:"main",headRefOid:$head,mergeCommit:{oid:$merge}}]' \
  > "$GH_MERGED_FIXTURE"
ZMERGE_MERGED_PR=""
METRICS_REASON_CODE=""
s1lrc=0
zmerge_delete_remote_branch >"$S1L/out" 2>"$S1L/err" || s1lrc=$?
expect_eq "40-A1 查询路径删除成功" 0 "$s1lrc"
expect_true "40-A1 查询路径 porcelain deleted" 'grep -Fq "porcelain=deleted" "$S1L/out"'
expect_true "40-A1 查询路径远端已无分支" \
  '! git -C "$S1L/wt" ls-remote --exit-code origin refs/heads/task-40 >/dev/null 2>&1'

S2L="$TDIR/s2l"
make_pair "$S2L"
cd "$S2L/wt"
git -C "$S2L/wt" checkout -qb task-40
printf 'task\n' > "$S2L/wt/task.txt"
git -C "$S2L/wt" add task.txt
git -C "$S2L/wt" commit -qm task-tip
s2ltip="$(git -C "$S2L/wt" rev-parse HEAD)"
git -C "$S2L/wt" push -q origin HEAD:refs/heads/task-40
git -C "$S2L/wt" switch -q main
printf 'task\n' > "$S2L/wt/task.txt"
git -C "$S2L/wt" add task.txt
git -C "$S2L/wt" commit -qm squash-equivalent
s2lmerge="$(git -C "$S2L/wt" rev-parse HEAD)"
git -C "$S2L/wt" push -q origin main
git clone -q "$S2L/origin.git" "$S2L/other"
git_cfg "$S2L/other"
git -C "$S2L/other" switch -q -c task-40 --track origin/task-40
printf 'advanced\n' >> "$S2L/other/task.txt"
git -C "$S2L/other" add task.txt
git -C "$S2L/other" commit -qm advanced-tip
git -C "$S2L/other" push -q origin task-40
s2ladvanced="$(git -C "$S2L/other" rev-parse HEAD)"
git -C "$S2L/wt" switch -q task-40
setup_z "$S2L/wt" task-40
jq -nc --arg head "$s2ltip" --arg merge "$s2lmerge" \
  '[{state:"MERGED",headRefName:"task-40",baseRefName:"main",headRefOid:$head,mergeCommit:{oid:$merge}}]' \
  > "$GH_MERGED_FIXTURE"
ZMERGE_MERGED_PR=""
METRICS_REASON_CODE=""
s2lrc=0
zmerge_delete_remote_branch >"$S2L/out" 2>"$S2L/err" || s2lrc=$?
expect_eq "40-A2 查询路径推进后拒绝" 1 "$s2lrc"
expect_eq "40-A2 查询路径 reason" z.delete_branch_not_in_main "$METRICS_REASON_CODE"
expect_true "40-A2 查询路径新 tip 仍在" \
  'git -C "$S2L/wt" ls-remote origin refs/heads/task-40 | grep -q "^${s2ladvanced}"'

S4L="$TDIR/s4l"
make_pair "$S4L"
cd "$S4L/wt"
git -C "$S4L/wt" checkout -qb task-40
printf 'task\n' > "$S4L/wt/task.txt"
git -C "$S4L/wt" add task.txt
git -C "$S4L/wt" commit -qm task-tip
s4ltip="$(git -C "$S4L/wt" rev-parse HEAD)"
git -C "$S4L/wt" push -q origin HEAD:refs/heads/task-40
setup_z "$S4L/wt" task-40
jq -nc --arg head "$s4ltip" \
  '[{state:"MERGED",headRefName:"task-40",baseRefName:"main",headRefOid:$head,mergeCommit:null}]' \
  > "$GH_MERGED_FIXTURE"
ZMERGE_MERGED_PR=""
zero merge
METRICS_REASON_CODE=""
s4lrc=0
zmerge_delete_remote_branch >"$S4L/out" 2>"$S4L/err" || s4lrc=$?
expect_eq "40-A4 查询路径空 mergeCommit 拒绝" 1 "$s4lrc"
expect_eq "40-A4 查询路径 reason" z.merge_commit_unobserved "$METRICS_REASON_CODE"
expect_eq "40-A4 查询路径未二次 merge" 0 "$(got merge)"
expect_true "40-A4 查询路径远端分支仍在" \
  'git -C "$S4L/wt" ls-remote --exit-code origin refs/heads/task-40 >/dev/null'
printf '%s\n' '[]' > "$GH_MERGED_FIXTURE"

# #40 R1：无论复跑查询还是本轮刚 merge，证明对象都必须携带 headRefOid。
expect_true "40-R1 merged PR 查询携带 headRefOid" \
  'grep -F -- "--json number,url,headRefName,baseRefName,state,title,headRefOid,mergeCommit" "$ROOT/.agents/skills/zmerge/scripts/merge-lib.sh" >/dev/null'
expect_true "40-R1 本轮 merge 回读携带 headRefOid" \
  'grep -F -- "--json state,mergeCommit,title,headRefOid" "$ROOT/.agents/skills/zmerge/scripts/merge-lib.sh" >/dev/null'
expect_true "40-R4 独立 reason code" \
  'grep -Fq "z.merge_commit_unobserved" "$ROOT/.agents/skills/zmerge/scripts/merge-lib.sh"'
expect_true "40-R4 squash 路径不再用 merge_oid_missing" \
  '! grep -Fq "z.merge_oid_missing" "$ROOT/.agents/skills/zmerge/scripts/merge-lib.sh"'

# ── #38 A4：zmerge_run 锁竞争 → z.merge_locked，只一套提示 ──
F4="$TDIR/f4"
make_pair "$F4"
cd "$F4/wt"
setup_z "$F4/wt" task-21
(
  set +e
  if z_merge_lock_acquire; then
    printf 'held\n' > "$F4/held"
    sleep 8
    z_merge_lock_release
  else
    printf 'fail\n' > "$F4/held.fail"
  fi
) &
f4pid=$!
for i in $(seq 1 40); do
  [ -f "$F4/held" ] || [ -f "$F4/held.fail" ] && break
  sleep 0.1
done
expect_true "38-A4 第一把锁已持有" '[ -f "$F4/held" ]'
METRICS_REASON_CODE=""
f4rc=0
zmerge_run >"$F4/out" 2>"$F4/err" || f4rc=$?
expect_eq "38-A4 立即失败" 2 "$f4rc"
expect_eq "38-A4 reason" z.merge_locked "$METRICS_REASON_CODE"
expect_eq "38-A4 提示一套" 1 "$(grep -c '另一个 zmerge 正在运行' "$F4/err" || true)"
expect_true "38-A4 无 lock_failed 文案" '! grep -Fq "无法获取 zmerge 锁" "$F4/err"'
kill "$f4pid" 2>/dev/null || true
wait "$f4pid" 2>/dev/null || true
z_merge_lock_release

# ── #38 A5：07 写明 claim 同寿；diff 无删 claim / 新步骤字段 ──
expect_true "38-A5 07 同寿" \
  'grep -Fq "与任务同寿" "$ROOT/0-meta/docs/07-git-工作流.md"'
expect_true "38-A5 07 finalize 不删 claim" \
  'grep -Fq "finalize 不删除" "$ROOT/0-meta/docs/07-git-工作流.md"'
if grep -ERn -- 'refs/claims/.+delete|delete.*refs/claims|:refs/claims/' \
    "$ROOT/.agents/skills/zmerge/scripts/merge-lib.sh" \
    "$ROOT/.agents/skills/zmerge/scripts/squash-merge.sh"; then
  bad "38-A5 引入了 claim-ref 删除"
else
  ok
fi
if grep -ERn -- 'Last successful step|last_successful_step|步骤指针|finalize_step' \
    "$ROOT/.agents/skills/zmerge/scripts/merge-lib.sh" \
    "$ROOT/.agents/skills/zmerge/scripts/squash-merge.sh"; then
  bad "38-A5 引入了步骤记录字段"
else
  ok
fi
if grep -ERn -- '跨机器互斥|z_load 的 Orca|no-PR fallback 改成按派生状态' \
    "$ROOT/.agents/skills/zmerge/scripts/merge-lib.sh" \
    "$ROOT/.agents/skills/zmerge/scripts/squash-merge.sh"; then
  bad "38-A5 扩到了不做项"
else
  ok
fi

if [ "$fail" -ne 0 ]; then
  echo "✗ zmerge mutex/finalize 未通过（${fail} 失败 / ${pass} 通过）" >&2
  exit 1
fi
echo "✓ zmerge mutex/finalize A1–A6、#38 A1–A5、#40 A1/A2/A4 通过（${pass}）"
