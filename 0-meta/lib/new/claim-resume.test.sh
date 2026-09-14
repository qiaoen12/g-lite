#!/usr/bin/env bash
# 定向测试：refs/claims/<n> / winner resume / derive / review 漂移（A4–A13）。
# 不调用真实 gh / orca；远端用本地 bare 仓。
set -Eeuo pipefail
export LC_COLLATE=C
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/0-meta/lib/new/core.sh"
# shellcheck source=/dev/null
. "$ROOT/0-meta/lib/new/task.sh"
# shellcheck source=/dev/null
. "$ROOT/.agents/skills/z-lib.sh"
trap tmp_cleanup EXIT

fail=0
pass=0
TDIR=""
tmp_mkd TDIR claim-resume-test
export XDG_STATE_HOME="$TDIR/state"
MOCK="$TDIR/mockbin"
mkdir -p "$MOCK"
GH_PR_FIXTURE="$TDIR/prs.json"
printf '%s\n' '[]' > "$GH_PR_FIXTURE"
export GH_PR_FIXTURE
ORCA_LOG="$TDIR/orca.log"
: > "$ORCA_LOG"
export ORCA_LOG
COUNT_DIR="$TDIR/counts"
mkdir -p "$COUNT_DIR"
zero() { printf '0\n' > "$COUNT_DIR/$1"; }
bump() {
  local f="$COUNT_DIR/$1" n
  n="$(cat "$f" 2>/dev/null || echo 0)"
  printf '%s\n' "$((n+1))" > "$f"
}
got() { cat "$COUNT_DIR/$1"; }

cat > "$MOCK/gh" <<'EOF'
#!/bin/bash
if [ "$1" = pr ] && [ "$2" = list ]; then
  if [ -n "${GH_PR_FIXTURE:-}" ] && [ -f "$GH_PR_FIXTURE" ]; then
    cat "$GH_PR_FIXTURE"
  else
    printf '%s\n' '[]'
  fi
  exit 0
fi
echo "unexpected gh $*" >&2
exit 1
EOF
cat > "$MOCK/orca" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${ORCA_LOG:-/dev/null}"
printf '%s\n' '{"ok":true}'
exit 0
EOF
chmod +x "$MOCK/gh" "$MOCK/orca"
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
  mkdir -p "$dest"
  git init --bare -b main "$dest/origin.git" >/dev/null
  git clone "$dest/origin.git" "$dest/wt" >/dev/null 2>&1
  git_cfg "$dest/wt"
  printf 'base\n' > "$dest/wt/f.txt"
  git -C "$dest/wt" add f.txt
  git -C "$dest/wt" commit -m base >/dev/null
  git -C "$dest/wt" push -u origin main >/dev/null 2>&1
}

add_contract() {
  local wt="$1" n="$2"
  mkdir -p "$wt/0-meta/tasks/$n"
  printf '%s\n' '{"schema_version":"task-contract/v1"}' > "$wt/0-meta/tasks/$n/contract.json"
  git -C "$wt" add "0-meta/tasks/$n/contract.json"
  git -C "$wt" commit -m "contract $n" >/dev/null
  git -C "$wt" push origin main >/dev/null 2>&1
}

clone_wt() {
  git clone "$1/origin.git" "$1/$2" >/dev/null 2>&1
  git_cfg "$1/$2"
}

open_pr_json() {
  jq -n --arg br "$1" \
    '[{number:1,headRefName:$br,state:"OPEN",isDraft:false,mergedAt:null}]'
}

merged_pr_json() {
  jq -n --arg br "$1" \
    '[{number:1,headRefName:$br,state:"MERGED",isDraft:false,mergedAt:"2026-01-01T00:00:00Z"}]'
}

setup_claim_locals() {
  wt="$1"
  git_br="$2"
  logical_br="$2"
  number=99
  owner=o
  repo=r
  main=main
  item_json='{"id":"1"}'
  project_status="${3:-$TASK_STATUS_READY}"
  contract_json=""
  contract_blob="deadbeef"
  agent=grok
  agent_bin=/bin/true
  scope="0-meta/lib/new/"
  head="$(git -C "$wt" rev-parse HEAD)"
  ws_status=干净
  evidence=""
  issue_url="https://example.test/99"
  issue_json=""
  TASK_CLAIM_ACTOR=""
  TASK_CLAIM_ACTOR_EXPLICIT=0
  Z_WT="$wt"
  Z_MAIN=main
  Z_OWNER=o
  Z_REPO=r
  Z_NUMBER=99
}

stub_claim_writes() {
  zero status; zero ck; zero agent; zero push
  task_claim_try_status_progress() { bump status; project_status="$TASK_STATUS_PROGRESS"; return 0; }
  task_claim_write_checkpoint() { bump ck; return 0; }
  task_claim_start_agent() { bump agent; printf '%s\n' "CLAIM_EXEC stub"; return 0; }
  task_checkpoint_body() { printf '%s' "${CK_BODY:-}"; }
}

# ── A4：五种耐久事实；claim 存在时其它 -<n> 不得干扰 ─────────
expect_eq "A4 decide 无契约" "$TASK_STATUS_BACKLOG" "$(derive_task_state_decide 0 0 none)"
expect_eq "A4 decide Ready" "$TASK_STATUS_READY" "$(derive_task_state_decide 1 0 none)"
expect_eq "A4 decide In progress" "$TASK_STATUS_PROGRESS" "$(derive_task_state_decide 1 1 none)"
expect_eq "A4 decide In review" "$TASK_STATUS_REVIEW" "$(derive_task_state_decide 1 1 open)"
expect_eq "A4 decide Done" "$TASK_STATUS_DONE" "$(derive_task_state_decide 1 1 merged)"

A4="$TDIR/a4"
make_pair "$A4"
Z_WT="$A4/wt"
Z_MAIN=main
Z_OWNER=o
Z_REPO=r
Z_NUMBER=99
owner=o
repo=r
printf '%s\n' '[]' > "$GH_PR_FIXTURE"

expect_eq "A4 无契约 → Backlog" "$TASK_STATUS_BACKLOG" "$(derive_task_state 99)"
Z_STATUS="$TASK_STATUS_DONE"
if ( z_require_dev_status ) >/dev/null 2>&1; then
  bad "A4 Backlog + Status=Done 应 hard fail"
else ok; fi
out="$( ( z_require_dev_status ) 2>&1 || true)"
expect_true "A4 Backlog 漂移警告" 'printf "%s\n" "$out" | grep -q "推导状态是 Backlog"'

add_contract "$Z_WT" 99
expect_eq "A4 有契约无 claim → Ready" "$TASK_STATUS_READY" "$(derive_task_state 99)"
Z_STATUS="$TASK_STATUS_PROGRESS"
if ( z_require_dev_status ) >/dev/null 2>&1; then
  bad "A4 Ready 应 hard fail"
else ok; fi

git -C "$Z_WT" checkout -b "meta/win-99" >/dev/null 2>&1
task_claim_create_lock "$Z_WT" 99 "meta/win-99" >/dev/null
expect_eq "A4 有 claim 无 PR → In progress" "$TASK_STATUS_PROGRESS" "$(derive_task_state 99)"
Z_STATUS="$TASK_STATUS_BACKLOG"
out="$( ( z_require_dev_status ) 2>&1 )" || true
expect_true "A4 In progress 可执行" '( z_require_dev_status ) >/dev/null 2>&1'
expect_true "A4 In progress 漂移只警告" 'printf "%s\n" "$out" | grep -q "推导状态是 In progress"'

git -C "$Z_WT" checkout -b "meta/other-99" >/dev/null 2>&1
git -C "$Z_WT" push origin "meta/other-99" >/dev/null 2>&1
open_pr_json "meta/other-99" > "$GH_PR_FIXTURE"
expect_eq "A4 其它 -<n> PR 不改变 winner" "$TASK_STATUS_PROGRESS" "$(derive_task_state 99)"

open_pr_json "meta/win-99" > "$GH_PR_FIXTURE"
expect_eq "A4 winner 开放 PR → In review" "$TASK_STATUS_REVIEW" "$(derive_task_state 99)"
Z_STATUS="$TASK_STATUS_READY"
expect_true "A4 In review 可执行" '( z_require_dev_status ) >/dev/null 2>&1'

merged_pr_json "meta/win-99" > "$GH_PR_FIXTURE"
expect_eq "A4 winner 已合并 → Done" "$TASK_STATUS_DONE" "$(derive_task_state 99)"
Z_STATUS="$TASK_STATUS_REVIEW"
if ( z_require_dev_status ) >/dev/null 2>&1; then
  bad "A4 Done 应 hard fail"
else ok; fi
printf '%s\n' '[]' > "$GH_PR_FIXTURE"

# ── A5：生产入口 + 不同 basename + 纯竞态 ────────────────────
A5="$TDIR/a5"
make_pair "$A5"
add_contract "$A5/wt" 99
clone_wt "$A5" wt2
git -C "$A5/wt" checkout -b "meta/foo-99" >/dev/null 2>&1
git -C "$A5/wt2" fetch origin >/dev/null 2>&1
git -C "$A5/wt2" checkout -b "meta/bar-99" origin/main >/dev/null 2>&1
git init --bare -b main "$A5/not-github.git" >/dev/null
git -C "$A5/wt" remote set-url --push origin "$A5/not-github.git"
git -C "$A5/wt2" remote set-url --push origin "$A5/not-github.git"

task_ensure_claim_remote "$A5/wt"
expect_eq "A11 自动创建 claim=fetch" "$(git -C "$A5/wt" remote get-url origin)" \
  "$(git -C "$A5/wt" remote get-url claim)"
git -C "$A5/wt" remote set-url claim /tmp/wrong-claim-url
task_ensure_claim_remote "$A5/wt"
expect_eq "A11 指错后改回 fetch" "$(git -C "$A5/wt" remote get-url origin)" \
  "$(git -C "$A5/wt" remote get-url claim)"
git -C "$A5/wt" remote remove claim
task_ensure_claim_remote "$A5/wt"
expect_eq "A11 删除后重建" "$(git -C "$A5/wt" remote get-url origin)" \
  "$(git -C "$A5/wt" remote get-url claim)"

stub_claim_writes
CK_BODY=""
setup_claim_locals "$A5/wt" "meta/foo-99" "$TASK_STATUS_READY"
out="$(task_claim_or_resume 2>&1)" || true
expect_true "A5 第一棵领取成立" 'printf "%s\n" "$out" | grep -q "领取成立"'
expect_eq "A5 第一棵写 Status" 1 "$(got status)"
expect_eq "A5 第一棵写 Checkpoint" 1 "$(got ck)"
expect_true "A5 远端只有 claim ref" \
  'git -C "$A5/origin.git" show-ref --verify --quiet refs/claims/99'
expect_true "A5 未把领取锁建成任务分支" \
  '! git -C "$A5/origin.git" show-ref --verify --quiet refs/heads/meta/foo-99'
expect_true "A5 origin push URL 未接到锁" \
  '! git -C "$A5/not-github.git" show-ref --verify --quiet refs/claims/99'

stub_claim_writes
CK_BODY=""
setup_claim_locals "$A5/wt2" "meta/bar-99" "$TASK_STATUS_READY"
out="$(task_claim_or_resume 2>&1)" || true
expect_true "A5 第二棵输出已被领取" 'printf "%s\n" "$out" | grep -q "已被领取"'
expect_eq "A5 第二棵不写 Status" 0 "$(got status)"
expect_eq "A5 第二棵不写 Checkpoint" 0 "$(got ck)"
expect_eq "A5 仍只有一个 claim ref" 1 \
  "$(git -C "$A5/origin.git" show-ref | grep -c 'refs/claims/99')"

# 纯竞态：两边都先处于 Ready，再各自 push 不同 lock。
A5R="$TDIR/a5race"
make_pair "$A5R"
add_contract "$A5R/wt" 99
clone_wt "$A5R" wt2
git -C "$A5R/wt" checkout -b "meta/a-99" >/dev/null 2>&1
git -C "$A5R/wt2" fetch origin >/dev/null 2>&1
git -C "$A5R/wt2" checkout -b "meta/b-99" origin/main >/dev/null 2>&1
owner=o; repo=r
rc1=0; rc2=0
task_claim_create_lock "$A5R/wt" 99 "meta/a-99" || rc1=$?
task_claim_create_lock "$A5R/wt2" 99 "meta/b-99" || rc2=$?
expect_true "A5 竞态恰一个 winner" \
  '{ [ "$rc1" = 0 ] && [ "$rc2" = 2 ]; } || { [ "$rc1" = 2 ] && [ "$rc2" = 0 ]; }'
expect_eq "A5 竞态远端一个锁" 1 \
  "$(git -C "$A5R/origin.git" show-ref | grep -c 'refs/claims/99')"

# ── A6：winner 故障窗口可恢复；loser 空 Checkpoint 也拒绝 ───
A6="$TDIR/a6"
make_pair "$A6"
add_contract "$A6/wt" 99
clone_wt "$A6" wt2
git -C "$A6/wt" checkout -b "meta/win-99" >/dev/null 2>&1
git -C "$A6/wt2" fetch origin >/dev/null 2>&1
git -C "$A6/wt2" checkout -b "meta/lose-99" origin/main >/dev/null 2>&1
stub_claim_writes
task_claim_try_status_progress() { bump status; return 1; }
CK_BODY=""
setup_claim_locals "$A6/wt" "meta/win-99" "$TASK_STATUS_READY"
out="$(task_claim_or_resume 2>&1)" || true
expect_true "A6 报告领取成立" 'printf "%s\n" "$out" | grep -q "领取成立"'
expect_true "A6 锁仍在" 'git -C "$A6/origin.git" show-ref --verify --quiet refs/claims/99'
expect_eq "A6 失败后未写 Checkpoint" 0 "$(got ck)"

stub_claim_writes
CK_BODY=""
setup_claim_locals "$A6/wt2" "meta/lose-99" "$TASK_STATUS_READY"
out="$(task_claim_or_resume 2>&1)" || true
expect_true "A6 loser 空 CK 也被拒绝" 'printf "%s\n" "$out" | grep -q "已被领取"'
expect_eq "A6 loser 不写 Status" 0 "$(got status)"
expect_eq "A6 loser 不写 Checkpoint" 0 "$(got ck)"

stub_claim_writes
CK_BODY=""
setup_claim_locals "$A6/wt" "meta/win-99" "$TASK_STATUS_READY"
out="$(task_claim_or_resume 2>&1)" || true
expect_eq "A6 winner resume 补齐 Status" 1 "$(got status)"
expect_eq "A6 winner resume 补齐 Checkpoint" 1 "$(got ck)"
expect_eq "A6 winner resume 启动 Agent" 1 "$(got agent)"

# ── A14：resume 固定耐久 claim_actor；Checkpoint actor 不一致拒绝 ──
A14="$TDIR/a14"
make_pair "$A14"
add_contract "$A14/wt" 99
git -C "$A14/wt" checkout -b "meta/actor-resume-99" >/dev/null 2>&1
owner=o
repo=r
TASK_CLAIM_ACTOR=alpha
TASK_CLAIM_ACTOR_EXPLICIT=1
task_claim_create_lock "$A14/wt" 99 "meta/actor-resume-99" >/dev/null

stub_claim_writes
CK_BODY=""
setup_claim_locals "$A14/wt" "meta/actor-resume-99" "$TASK_STATUS_PROGRESS"
resume_actor_capture="$A14/resume-actor"
task_claim_write_checkpoint() {
  bump ck
  printf '%s\n' "$TASK_CLAIM_ACTOR" > "$resume_actor_capture"
  return 0
}
NEW_TASK_ACTOR=beta
out="$(task_claim_or_resume 2>&1)" || true
expect_eq "A14 beta resume 保留 lock actor" alpha "$(cat "$resume_actor_capture")"
expect_eq "A14 beta resume 写一次 Checkpoint" 1 "$(got ck)"
unset NEW_TASK_ACTOR

stub_claim_writes
CK_BODY="$(cat <<EOF
claim_actor=beta
| 项 | 值 |
| --- | --- |
| 工作树 | $A14/wt |
| 分支 | meta/actor-resume-99（git: meta/actor-resume-99） |
EOF
)"
setup_claim_locals "$A14/wt" "meta/actor-resume-99" "$TASK_STATUS_PROGRESS"
out="$(task_claim_or_resume 2>&1)" || true
expect_true "A14 Checkpoint actor 与 lock 不一致拒绝" 'printf "%s\n" "$out" | grep -q "claim_actor"'
expect_eq "A14 Checkpoint actor 冲突不写" 0 "$(got ck)"

# ── A7：分支加 -<n>；不同 basename 仍争同一 claim ───────────
A7="$TDIR/a7"
make_pair "$A7"
git -C "$A7/wt" checkout -b "meta/claim-and-resume" >/dev/null 2>&1
: > "$ORCA_LOG"
new_br="$(task_ensure_issue_branch_suffix "$A7/wt" "meta/claim-and-resume" 99)"
expect_eq "A7 新分支名" "meta/claim-and-resume-99" "$new_br"
expect_eq "A7 git HEAD" "meta/claim-and-resume-99" "$(git -C "$A7/wt" symbolic-ref --short HEAD)"
expect_true "A7 调用 orca displayName" 'grep -q "display-name meta/claim-and-resume-99" "$ORCA_LOG"'
same="$(task_ensure_issue_branch_suffix "$A7/wt" "meta/claim-and-resume-99" 99)"
expect_eq "A7 已有后缀不改" "meta/claim-and-resume-99" "$same"

A7b="$TDIR/a7b"
make_pair "$A7b"
git -C "$A7b/wt" checkout -b "meta/no-orca" >/dev/null 2>&1
mv "$MOCK/orca" "$MOCK/orca.off"
: > "$ORCA_LOG"
set +e
new_br="$(task_ensure_issue_branch_suffix "$A7b/wt" "meta/no-orca" 99)"
a7b_rc=$?
set -e
mv "$MOCK/orca.off" "$MOCK/orca"
expect_eq "41b 无 orca 后缀退出 0" 0 "$a7b_rc"
expect_eq "41b 无 orca 仍加后缀" "meta/no-orca-99" "$new_br"
expect_eq "41b 无 orca 时 git HEAD" "meta/no-orca-99" \
  "$(git -C "$A7b/wt" symbolic-ref --short HEAD)"
expect_eq "41b 无 orca 不调 orca" "" "$(cat "$ORCA_LOG")"

# ── A8 / A9：winner 重入 vs 锁/Checkpoint 冲突 ──────────────
CK_HERE="$(cat <<EOF
claim_actor=t@t
| 项 | 值 |
| --- | --- |
| claim_actor | t@t |
| 工作树 | \`$A6/wt\` |
| 分支 | meta/win-99（git: meta/win-99） |
EOF
)"
CK_OTHER="$(cat <<EOF
claim_actor=t@t
| 项 | 值 |
| --- | --- |
| claim_actor | t@t |
| 工作树 | \`/other/tree\` |
| 分支 | meta/win-99（git: meta/win-99） |
EOF
)"
zero push
_orig_create="$(declare -f task_claim_create_lock)"
task_claim_create_lock() { bump push; return 0; }
stub_claim_writes
CK_BODY="$CK_HERE"
setup_claim_locals "$A6/wt" "meta/win-99" "$TASK_STATUS_PROGRESS"
out="$(task_claim_or_resume 2>&1)" || true
expect_eq "A8 无新 claim push" 0 "$(got push)"
expect_eq "A8 无不必要 Status 写入" 0 "$(got status)"
expect_eq "A8 Checkpoint 已有则保持" 0 "$(got ck)"
expect_eq "A8 Agent 启动" 1 "$(got agent)"

stub_claim_writes
CK_BODY="$CK_HERE"
setup_claim_locals "$A6/wt" "meta/win-99" "$TASK_STATUS_PROGRESS"
TASK_CLAIM_LAUNCH=0
out="$(task_claim_or_resume 2>&1)" || true
expect_eq "41b claim 不启动 Agent" 0 "$(got agent)"
expect_true "41b claim 提示 new z dev" \
  'printf "%s\n" "$out" | grep -Fq "下一步：new z dev"'
TASK_CLAIM_LAUNCH=1

stub_claim_writes
CK_BODY="$CK_OTHER"
setup_claim_locals "$A6/wt" "meta/win-99" "$TASK_STATUS_PROGRESS"
out="$(task_claim_or_resume 2>&1)" || true
expect_true "A9 Checkpoint 冲突拒绝" 'printf "%s\n" "$out" | grep -q "已被领取"'
expect_eq "A9 CK 冲突不写 Status" 0 "$(got status)"
expect_eq "A9 CK 冲突不写 Checkpoint" 0 "$(got ck)"
expect_eq "A9 CK 冲突不启动 Agent" 0 "$(got agent)"

eval "$_orig_create"
stub_claim_writes
CK_BODY=""
setup_claim_locals "$A6/wt2" "meta/lose-99" "$TASK_STATUS_READY"
out="$(task_claim_or_resume 2>&1)" || true
expect_true "A9 锁身份不符拒绝" 'printf "%s\n" "$out" | grep -q "已被领取"'
expect_eq "A9 空 CK 不放宽" 0 "$(got ck)"

# ── A10：无 mkdir 锁 / Execution / DB；07 有边界 ────────────
A10_FILES=(
  "$ROOT/.agents/skills/z-lib.sh"
  "$ROOT/.agents/skills/zsync/scripts/sync-main.sh"
  "$ROOT/0-meta/lib/new/claim.sh"
  "$ROOT/0-meta/lib/new/task.sh"
  "$ROOT/0-meta/lib/new/z-cli.sh"
)
if grep -EIq 'mkdir[[:space:]].*lock|execution[_-]?id|Execution ID|sqlite3?://|ownership rollback' \
    "${A10_FILES[@]}" 2>/dev/null; then
  bad "A10 实现含 mkdir 锁 / Execution / DB"
else ok; fi
expect_true "A10 07 写明 refs/claims 互斥" \
  'grep -Fq "refs/claims/<n>" "$ROOT/0-meta/docs/07-git-工作流.md"'
expect_true "A10 07 写明 winner 身份" \
  'grep -Fq "host" "$ROOT/0-meta/docs/07-git-工作流.md" && grep -Fq "winner" "$ROOT/0-meta/docs/07-git-工作流.md"'
expect_true "A10 07 写明只拒绝不回退" \
  'grep -Fq "只拒绝接管，不回退、不删锁" "$ROOT/0-meta/docs/07-git-工作流.md"'
expect_true "A10 07 写明 Status 是视图" \
  'grep -Fq "Status 是视图" "$ROOT/0-meta/docs/07-git-工作流.md"'

# ── A11：删掉 claim 后仍能领取（用新仓库） ──────────────────
A11="$TDIR/a11"
make_pair "$A11"
add_contract "$A11/wt" 99
git -C "$A11/wt" checkout -b "meta/a11-99" >/dev/null 2>&1
git -C "$A11/wt" remote remove claim 2>/dev/null || true
stub_claim_writes
CK_BODY=""
setup_claim_locals "$A11/wt" "meta/a11-99" "$TASK_STATUS_READY"
out="$(task_claim_or_resume 2>&1)" || true
expect_true "A11 删除 claim 后仍领取" 'printf "%s\n" "$out" | grep -q "领取成立"'
expect_eq "A11 claim 恢复为 fetch" \
  "$(git -C "$A11/wt" remote get-url origin)" "$(git -C "$A11/wt" remote get-url claim)"

# ── A12：review Status 漂移只警告、不写回、退出 0 ───────────
task_fetch_issue() { return 0; }
task_project_item() { printf '%s' "${item_json:-{}}"; }
task_read_status_name() { printf '%s\n' "$FAKE_STATUS"; }
task_set_status() { bump status; return 0; }
owner=o; repo=r; number=99; pr_url="https://example.test/pr/1"
issue_json="$TDIR/issue.json"; printf '{}\n' > "$issue_json"
derived_status="$TASK_STATUS_PROGRESS"
redeliver=0
item_json='{}'
item_id=; project_id=; field_id=; from_id=; to_id=
for drift in Backlog Ready Done; do
  FAKE_STATUS="$drift"
  project_status="$drift"
  zero status
  rc=0
  out="$(task_review_sync_status 2>&1)" || rc=$?
  expect_eq "A12 ${drift} 退出 0" 0 "$rc"
  expect_eq "A12 ${drift} 不写 Status" 0 "$(got status)"
  expect_true "A12 ${drift} 漂移警告" 'printf "%s\n" "$out" | grep -q "推导状态是 In progress"'
done
redeliver=1
derived_status="$TASK_STATUS_REVIEW"
FAKE_STATUS=Ready
project_status=Ready
zero status
rc=0
out="$(task_review_sync_status 2>&1)" || rc=$?
expect_eq "A12 重交付漂移退出 0" 0 "$rc"
expect_eq "A12 重交付不写回" 0 "$(got status)"
expect_true "A12 重交付漂移警告" 'printf "%s\n" "$out" | grep -q "推导状态是 In review"'

# ── A13：从 task_review_deliver 入口打四格 Project 故障 ─────
A13="$TDIR/a13"
make_pair "$A13"
git -C "$A13/wt" checkout -b "meta/a13-99" >/dev/null 2>&1
printf '%s\n' a13 > "$A13/wt/a13.txt"
git -C "$A13/wt" add a13.txt
git -C "$A13/wt" commit -qm 'feat(meta): a13 delivery fixture'
git -C "$A13/wt" remote set-url origin "https://github.com/o/r.git"
A13_ITEM='{"id":"I1","project":{"id":"P1"},"fieldValueByName":{"field":{"id":"F1","options":[{"id":"opt-p","name":"In progress"},{"id":"opt-r","name":"In review"}]},"name":"In progress"}}'
A13_HAVE_ITEM=1
A13_SET_RC=0
A13_FETCH_RC=0

setup_a13_deliver() {
  local have_item="${1:-1}"
  wt="$A13/wt"
  git_br="meta/a13-99"
  logical_br="meta/a13-99"
  number=99
  owner=o
  repo=r
  main=main
  head="$(git -C "$wt" rev-parse HEAD)"
  base_git=main
  issue_title=a13
  contract_blob=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
  contract_json="$TDIR/a13-contract.json"
  printf '%s\n' '{"schema_version":"task-contract/v1"}' > "$contract_json"
  ws_status=干净
  scope="0-meta/lib/new/"
  evidence=""
  issue_json="$TDIR/a13-issue.json"
  printf '{}\n' > "$issue_json"
  derived_status="$TASK_STATUS_PROGRESS"
  A13_HAVE_ITEM="$have_item"
  if [ "$have_item" = 1 ]; then
    item_json="$A13_ITEM"
    project_status="$TASK_STATUS_PROGRESS"
  else
    item_json=""
    project_status=""
  fi
  zero status; zero pr; zero ck
  task_checkpoint_body() { printf '%s' 'claim_actor=alpha'; }
  task_confirm_gh_access() { return 0; }
  task_resolve_pr_title() {
    TASK_PR_TITLE="feat(meta): a13"
    TASK_PR_TITLE_SRC=review
    return 0
  }
  task_unique_marked_comment() {
    if [ "${4:-}" = "$TASK_CHECKPOINT_MARK" ]; then
      printf '%s\n' '{"body":"claim_actor=alpha"}'
    else
      printf '%s\n' '{"body":"review"}'
    fi
  }
  contract_stale() { return 1; }
  contract_review_validate() { return 0; }
  task_push_task_branch() { printf '%s\n' "$head"; }
  task_change_summary() { printf '%s\n' "summary"; }
  contract_pr_validate() { return 0; }
  task_ensure_pr() { bump pr; printf '%s\n' "1 https://example.test/pr/1"; }
  task_write_checkpoint() { bump ck; return 0; }
  task_project_item() {
    if [ "${A13_HAVE_ITEM:-1}" = 1 ]; then printf '%s' "$A13_ITEM"; fi
  }
  task_read_status_name() { printf '%s\n' "$FAKE_STATUS"; }
  task_set_status() { bump status; return "${A13_SET_RC:-0}"; }
  task_fetch_issue() { return "${A13_FETCH_RC:-0}"; }
}

assert_a13() {
  local name="$1" out="$2" rc="$3" writes="$4"
  expect_eq "$name 退出 0" 0 "$rc"
  expect_eq "$name PR 一次" 1 "$(got pr)"
  expect_eq "$name Checkpoint 一次" 1 "$(got ck)"
  expect_eq "$name Status 写计数" "$writes" "$(got status)"
  expect_true "$name 无退回" '! printf "%s\n" "$out" | grep -q 退回'
}

FAKE_STATUS="$TASK_STATUS_PROGRESS"
A13_SET_RC=1
A13_FETCH_RC=0
setup_a13_deliver 1
rc=0
out="$(task_review_deliver 2>&1)" || rc=$?
assert_a13 "A13 写 Status 恒失败" "$out" "$rc" 1

A13_SET_RC=0
FAKE_STATUS="$TASK_STATUS_PROGRESS"
setup_a13_deliver 1
rc=0
out="$(task_review_deliver 2>&1)" || rc=$?
assert_a13 "A13 写成功回读仍 In progress" "$out" "$rc" 1

A13_SET_RC=0
setup_a13_deliver 1
task_fetch_issue() {
  if [ "$(got pr)" -ge 1 ]; then return 1; fi
  return 0
}
rc=0
out="$(task_review_deliver 2>&1)" || rc=$?
assert_a13 "A13 PR 后 fetch 失败" "$out" "$rc" 1

A13_SET_RC=0
FAKE_STATUS=""
setup_a13_deliver 0
rc=0
out="$(task_review_deliver 2>&1)" || rc=$?
assert_a13 "A13 Project item 缺失" "$out" "$rc" 0

# 41a：bind 末行 + PR 查询必须带 --head
expect_true "41a list_prs 使用 --head" \
  'grep -Fq -- "--head" "$ROOT/0-meta/lib/new/claim.sh"'
expect_true "41a 不再全仓 --limit 100" \
  '! grep -Fq -- "--limit 100" "$ROOT/0-meta/lib/new/claim.sh"'
B1="$TDIR/bind1"
make_pair "$B1"
git -C "$B1/wt" worktree add -b meta/bind-99 "$B1/linked" >/dev/null 2>&1
err="$(task_bind_read "$B1/linked")"
expect_eq "未 bind 读空" "" "$err"
rc=0
( ROOT="$B1/wt" && task_bind 99 >/dev/null ) || rc=$?
expect_eq "主工作区拒绝 bind" 1 "$rc"
out="$( ( cd "$B1/linked" && z_load ) 2>&1 )" || true
expect_true "未 bind z_load 末行是 bind" \
  '[ "$(printf "%s\n" "$out" | awk "NF{last=\$0} END{print last}")" = "new task bind <n>" ]'

echo "claim-resume.test.sh: 通过 ${pass}，失败 ${fail}"
[ "$fail" -eq 0 ] || exit 1
bash "$ROOT/0-meta/lib/new/portable-runtime.test.sh"
bash "$ROOT/0-meta/lib/new/setup.test.sh"
