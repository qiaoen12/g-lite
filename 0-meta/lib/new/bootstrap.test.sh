#!/usr/bin/env bash
# Issue #15：task-aware bootstrap / exact sparse / launch handoff / completion。
# 关键判定调用 production 函数与 0-meta/bin/new；只 mock GitHub、宿主 Agent。
set -Eeuo pipefail
export LC_COLLATE=C
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

# shellcheck source=/dev/null
. "$ROOT/0-meta/lib/new/core.sh"
# shellcheck source=/dev/null
. "$ROOT/0-meta/lib/new/worktree.sh"
# shellcheck source=/dev/null
. "$ROOT/0-meta/lib/new/task.sh"
# shellcheck source=/dev/null
. "$ROOT/0-meta/lib/new/contract.sh"
# shellcheck source=/dev/null
. "$ROOT/0-meta/lib/new/check.sh"
trap tmp_cleanup EXIT

fail=0
pass=0
TDIR=""
tmp_mkd TDIR issue-15-bootstrap
export XDG_STATE_HOME="$TDIR/state"
export NEW_TASK_ACTOR=issue15-dev

ok() { pass=$((pass + 1)); }
bad() { printf '✗ %s\n' "$*" >&2; fail=$((fail + 1)); }
expect_eq() {
  if [ "$2" = "$3" ]; then ok; else bad "$1：期望 [$2] 实际 [$3]"; fi
}
expect_true() { if eval "$2"; then ok; else bad "$1"; fi; }
expect_contains() {
  if printf '%s\n' "$2" | grep -Fq -- "$3"; then ok; else bad "$1：缺少 [$3]"; fi
}
last_line() {
  printf '%s\n' "$1" | sed $'s/\x1b\\[[0-9;]*m//g' | awk 'NF{last=$0} END{print last}'
}

git_cfg() {
  git -C "$1" config user.email issue15@example.test
  git -C "$1" config user.name issue15
  git -C "$1" config commit.gpgsign false
  git -C "$1" config core.hooksPath /dev/null
}

write_contract() {
  local dest="$1" n="$2"
  mkdir -p "$(dirname "$dest")"
  cat > "$dest" <<JSON
{
  "schema_version": "task-contract/v1",
  "issue": "#${n}",
  "title": "bootstrap fixture",
  "goal": "task-aware bootstrap",
  "requirements": [{"id": "R1", "text": "implement fixture note"}],
  "acceptances": [{"id": "A1", "text": "note exists", "requires": ["R1"], "applicable_when": null}],
  "scope": [
    "1-code/fixture-app/note.txt",
    "2-infra/ops-control/policy/logging.yml",
    "2-infra/ops-control/newdir"
  ]
}
JSON
}

# ── 静态：production 入口仍在，且未用 fixture 重定义同名判定 ────────
expect_true "production task_bootstrap_worktree" \
  '[ "$(type -t task_bootstrap_worktree)" = function ]'
expect_true "production task_bind_ensure_sparse" \
  '[ "$(type -t task_bind_ensure_sparse)" = function ]'
expect_true "production task_next_canonical_command" \
  '[ "$(type -t task_next_canonical_command)" = function ]'
expect_true "production task_claim_create_lock" \
  '[ "$(type -t task_claim_create_lock)" = function ]'
expect_true "production task_completion_gate" \
  '[ "$(type -t task_completion_gate)" = function ]'
expect_true "manual --path 仍要求基点存在" \
  'grep -Fq "路径必须在基点里真实存在" "$ROOT/0-meta/lib/new/worktree.sh"'
expect_true "manual worktree 不用 skip-checks 绕过" \
  '! grep -Fq "sparse-checkout set --skip-checks" "$ROOT/0-meta/lib/new/worktree.sh"'
expect_true "z_cli_dev_summary 不再写死 Review" \
  '! grep -Fq "new z review <review-input>" "$ROOT/0-meta/lib/new/z-cli.sh"'

# ── 夹具 consumer ────────────────────────────────────────────────────
CONS="$TDIR/cons"
mkdir -p "$CONS"
git init --bare -q -b main "$CONS/origin.git"
git clone -q "$CONS/origin.git" "$CONS/main"
git_cfg "$CONS/main"
MAIN="$CONS/main"

mkdir -p "$MAIN/0-meta/bin" "$MAIN/0-meta/lib" "$MAIN/0-meta/schema" \
  "$MAIN/0-meta/templates" "$MAIN/0-meta/tasks/7" \
  "$MAIN/.agents/skills" \
  "$MAIN/1-code/fixture-app" \
  "$MAIN/2-infra/ops-control/policy" \
  "$MAIN/1-code/secret-tree"
cp "$ROOT/0-meta/policy.yaml" "$MAIN/0-meta/"
cp "$ROOT/0-meta/derived.lock" "$MAIN/0-meta/"
cp "$ROOT/0-meta/bin/new" "$MAIN/0-meta/bin/"
chmod +x "$MAIN/0-meta/bin/new"
cp -R "$ROOT/0-meta/lib/new" "$MAIN/0-meta/lib/"
cp -R "$ROOT/0-meta/schema/." "$MAIN/0-meta/schema/"
cp "$ROOT/0-meta/AGENTS.md" "$MAIN/0-meta/"
cp "$ROOT/0-meta/templates/z-workflow.md" "$MAIN/0-meta/templates/"
cp "$ROOT/AGENTS.md" "$MAIN/AGENTS.md"
cp "$ROOT/.agents/skills/z-lib.sh" "$MAIN/.agents/skills/"
for sk in zdev zfix zreview zsync zmerge zpr; do
  mkdir -p "$MAIN/.agents/skills/$sk"
  cp "$ROOT/.agents/skills/$sk/SKILL.md" "$MAIN/.agents/skills/$sk/"
done
printf 'keep\n' > "$MAIN/.agents/.keep"
printf 'pending\n' > "$MAIN/1-code/fixture-app/note.txt"
printf 'log\n' > "$MAIN/2-infra/ops-control/policy/logging.yml"
printf 'secret\n' > "$MAIN/1-code/secret-tree/hidden.txt"
write_contract "$MAIN/0-meta/tasks/7/contract.json" 7
git -C "$MAIN" add -A
git -C "$MAIN" commit -qm 'chore: issue 15 consumer fixture'
git -C "$MAIN" push -q -u origin main
BARE="$(cd "$CONS/origin.git" && pwd)"
git -C "$MAIN" remote set-url origin https://github.com/o/r.git
git -C "$MAIN" config "url.${BARE}.insteadOf" https://github.com/o/r.git

MOCK="$TDIR/mockbin"
mkdir -p "$MOCK"
GH_ISSUE="$TDIR/issue.json"
GH_PR="$TDIR/prs.json"
GH_LOG="$TDIR/gh.log"
LAUNCH_LOG="$TDIR/launch.log"
: > "$GH_LOG"
: > "$LAUNCH_LOG"
printf '%s\n' '[]' > "$GH_PR"
cat > "$GH_ISSUE" <<'JSON'
{
  "data": {
    "repository": {
      "issue": {
        "id": "I7",
        "title": "bootstrap fixture",
        "url": "https://github.com/o/r/issues/7",
        "body": "",
        "labels": {"nodes": []},
        "projectItems": {
          "nodes": [{
            "id": "it1",
            "project": {"id": "p1", "number": 1, "title": "Tasks"},
            "fieldValueByName": {
              "name": "Ready",
              "optionId": "opt-r",
              "field": {
                "id": "f1",
                "options": [
                  {"id": "opt-b", "name": "Backlog"},
                  {"id": "opt-r", "name": "Ready"},
                  {"id": "opt-p", "name": "In progress"},
                  {"id": "opt-v", "name": "In review"},
                  {"id": "opt-d", "name": "Done"}
                ]
              }
            }
          }]
        }
      }
    }
  }
}
JSON
cat > "$MOCK/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$GH_LOG"
if [ "\$1" = pr ] && [ "\$2" = list ]; then
  cat "$GH_PR"
  exit 0
fi
if [ "\$1" = project ] && [ "\$2" = item-edit ]; then
  python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["data"]["repository"]["issue"]["projectItems"]["nodes"][0]["fieldValueByName"]["name"]="In progress"; json.dump(d, open(p,"w"))' "$GH_ISSUE"
  printf '%s\n' '{"id":"it1"}'
  exit 0
fi
if [ "\$1" = api ] && [ "\$2" = graphql ]; then
  cat "$GH_ISSUE"
  exit 0
fi
if [ "\$1" = api ]; then
  printf '%s\n' '[]'
  exit 0
fi
echo "unexpected gh \$*" >&2
exit 1
EOF
chmod +x "$MOCK/gh"

cat > "$MOCK/codex" <<EOF
#!/bin/bash
printf 'LAUNCH codex %s\n' "\$(pwd)" >> "$LAUNCH_LOG"
printf '%s\n' "\$1" > "$TDIR/last-prompt.txt"
if [ "\${ISSUE15_AGENT_MODE:-implement}" = fail ]; then
  echo "mock launch failure" >&2
  exit 1
fi
if [ "\${ISSUE15_AGENT_MODE:-implement}" = noop ]; then
  exit 0
fi
git show "origin/main:0-meta/tasks/7/contract.json" > "$TDIR/agent-read-contract.json"
mkdir -p 2-infra/ops-control/newdir
blob="\$(git rev-parse origin/main:0-meta/tasks/7/contract.json)"
printf 'implemented %s\n' "\$blob" > 2-infra/ops-control/newdir/hello.txt
git add 2-infra/ops-control/newdir/hello.txt
git commit -qm "feat(infra.ops-control): fixture hello"
exit 0
EOF
chmod +x "$MOCK/codex"
cp "$MOCK/codex" "$MOCK/grok"
chmod +x "$MOCK/grok"

CLEAN_PATH="$MOCK:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
export PATH="$CLEAN_PATH"

run_new() {
  local wt="$1"; shift
  PATH="$CLEAN_PATH" XDG_STATE_HOME="$TDIR/state" \
    NEW_TASK_ACTOR=issue15-dev GIT_TERMINAL_PROMPT=0 \
    ISSUE15_AGENT_MODE="${ISSUE15_AGENT_MODE:-implement}" \
    "$wt/0-meta/bin/new" "$@"
}

WTROOT="$(cd "$MAIN/.." && pwd)/worktrees"
DEST="$WTROOT/task-7"

# ── A1 happy bootstrap：只要任务号 ──────────────────────────────
set +e
boot1="$(cd "$MAIN" && run_new "$MAIN" task worktree 7 2>&1)"
boot1_rc=$?
set -e
expect_eq "A1 bootstrap 退出 0" 0 "$boot1_rc"
if [ "$boot1_rc" != 0 ]; then printf '%s\n' "$boot1" >&2; fi
expect_true "A1 未要求 --path" '! printf "%s\n" "$boot1" | grep -Fq -- "--path"'
expect_true "A1 clean/bound/unclaimed" \
  'printf "%s\n" "$boot1" | grep -Fq "clean / bound / unclaimed"'
DEST="$(cd "$DEST" && pwd)"
expect_eq "A1 dest 存在" 1 "$( [ -d "$DEST" ] && echo 1 || echo 0 )"
expect_eq "A1 bind=7" 7 "$(task_bind_read "$DEST")"
expect_eq "A1 branch" "code/task-7" "$(git -C "$DEST" branch --show-current)"
expect_true "A1 不跟踪 origin/main" \
  '! git -C "$DEST" rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1'
expect_eq "A1 secret 不可见" 0 "$( [ -e "$DEST/1-code/secret-tree/hidden.txt" ] && echo 1 || echo 0 )"
expect_eq "A1 精确文件可见" 1 "$( [ -f "$DEST/2-infra/ops-control/policy/logging.yml" ] && echo 1 || echo 0 )"
expect_eq "A1 精确文件 note 可见" 1 "$( [ -f "$DEST/1-code/fixture-app/note.txt" ] && echo 1 || echo 0 )"
expect_true "A1 sparse 不含父目录 1-code" \
  '! git -C "$DEST" sparse-checkout list | grep -qx "1-code"'
expect_true "A1 sparse 含获准缺失目录" \
  'git -C "$DEST" sparse-checkout list | grep -q "2-infra/ops-control/newdir"'
expect_true "A1 未 claim" \
  '[ -z "$(GIT_TERMINAL_PROMPT=0 git -C "$DEST" ls-remote origin refs/claims/7 2>/dev/null || true)" ]'
expect_eq "A1 worktree clean" "" "$(git -C "$DEST" status --porcelain)"

# ── A1 重复 / 幂等 ──────────────────────────────────────────────
set +e
boot2="$(cd "$MAIN" && run_new "$MAIN" task worktree 7 2>&1)"
boot2_rc=$?
set -e
expect_eq "A1 重复调用退出 0" 0 "$boot2_rc"
if [ "$boot2_rc" != 0 ]; then printf '%s\n' "$boot2" >&2; fi
expect_eq "A1 重复后仍 bind 7" 7 "$(task_bind_read "$DEST")"
expect_eq "A1 重复后仍干净" "" "$(git -C "$DEST" status --porcelain)"
expect_eq "A1 重复后 HEAD 不变" \
  "$(git -C "$DEST" rev-parse HEAD)" "$(git -C "$MAIN" rev-parse origin/main)"

# ── A2 根 AGENTS.md 自动可见且不可写 ───────────────────────────
expect_eq "A2 AGENTS.md 可见" 1 "$( [ -f "$DEST/AGENTS.md" ] && echo 1 || echo 0 )"
set +e
pre="$(cd "$DEST" && run_new "$DEST" task 2>&1)"
pre_rc=$?
set -e
expect_eq "A2 new task 预检 0" 0 "$pre_rc"
if [ "$pre_rc" != 0 ]; then printf '%s\n' "$pre" >&2; fi
set +e
chk="$(cd "$DEST" && run_new "$DEST" check --tier commit 2>&1)"
chk_rc=$?
set -e
expect_eq "A2 commit gate 0" 0 "$chk_rc"
if [ "$chk_rc" != 0 ]; then printf '%s\n' "$chk" >&2; fi
printf '\nextra\n' >> "$DEST/AGENTS.md"
git -C "$DEST" add AGENTS.md
set +e
scope_out="$(contract_paths_in_scope "AGENTS.md" "$(printf '%s\n' '1-code/fixture-app/note.txt' '2-infra/ops-control/policy/logging.yml' '2-infra/ops-control/newdir')" 2>&1)"
scope_rc=$?
set -e
expect_true "A2 改 scope 外 AGENTS.md BLOCK" '[ "$scope_rc" != 0 ]'
expect_contains "A2 越界标记" "$scope_out" "outside"
git -C "$DEST" restore --staged --worktree -- AGENTS.md >/dev/null 2>&1 \
  || git -C "$DEST" checkout -q -- AGENTS.md

# ── 负向：dirty / staged / unstaged / untracked / unique / busy / bind ─
printf 'dirty\n' >> "$DEST/1-code/fixture-app/note.txt"
set +e
neg_dirty="$(cd "$MAIN" && run_new "$MAIN" task worktree 7 2>&1)"
neg_dirty_rc=$?
set -e
expect_true "dirty BLOCK" '[ "$neg_dirty_rc" != 0 ]'
expect_contains "dirty 不覆盖" "$neg_dirty" "不干净"
git -C "$DEST" checkout -q -- 1-code/fixture-app/note.txt

printf 'staged\n' >> "$DEST/1-code/fixture-app/note.txt"
git -C "$DEST" add 1-code/fixture-app/note.txt
set +e
neg_st="$(cd "$MAIN" && run_new "$MAIN" task worktree 7 2>&1)"
neg_st_rc=$?
set -e
expect_true "staged BLOCK" '[ "$neg_st_rc" != 0 ]'
git -C "$DEST" restore --staged --worktree -- 1-code/fixture-app/note.txt >/dev/null 2>&1 \
  || { git -C "$DEST" reset -q HEAD -- 1-code/fixture-app/note.txt; git -C "$DEST" checkout -q -- 1-code/fixture-app/note.txt; }

printf 'untracked\n' > "$DEST/1-code/fixture-app/tmp-untracked.txt"
set +e
neg_ut="$(cd "$MAIN" && run_new "$MAIN" task worktree 7 2>&1)"
neg_ut_rc=$?
set -e
expect_true "untracked BLOCK" '[ "$neg_ut_rc" != 0 ]'
rm -f "$DEST/1-code/fixture-app/tmp-untracked.txt"

printf 'unique\n' >> "$DEST/1-code/fixture-app/note.txt"
git -C "$DEST" add 1-code/fixture-app/note.txt
git -C "$DEST" commit -qm 'wip: unique'
set +e
neg_u="$(cd "$MAIN" && run_new "$MAIN" task worktree 7 2>&1)"
neg_u_rc=$?
set -e
expect_true "unique commit BLOCK" '[ "$neg_u_rc" != 0 ]'
expect_contains "unique 诊断" "$neg_u" "独有提交"
git -C "$DEST" reset -q --hard origin/main

gd="$(git -C "$DEST" rev-parse --path-format=absolute --git-dir)"
touch "$gd/index.lock"
set +e
neg_busy="$(cd "$MAIN" && run_new "$MAIN" task worktree 7 2>&1)"
neg_busy_rc=$?
set -e
expect_true "git busy BLOCK" '[ "$neg_busy_rc" != 0 ]'
rm -f "$gd/index.lock"

printf '99\n' > "$(task_bind_path "$DEST")"
set +e
neg_bind="$(cd "$MAIN" && run_new "$MAIN" task worktree 7 2>&1)"
neg_bind_rc=$?
set -e
expect_true "binding conflict BLOCK" '[ "$neg_bind_rc" != 0 ]'
printf '7\n' > "$(task_bind_path "$DEST")"

# ── 过宽 sparse：干净可收窄；有独有提交则 BLOCK ───────────────
git -C "$DEST" sparse-checkout set --skip-checks 0-meta .agents 1-code >/dev/null
expect_true "过宽 sparse 已写入" \
  'git -C "$DEST" sparse-checkout list | grep -q "1-code"'
set +e
narrow="$(cd "$DEST" && run_new "$DEST" task bind 7 2>&1)"
narrow_rc=$?
set -e
expect_eq "过宽且干净时 bind 收窄" 0 "$narrow_rc"
expect_true "收窄后无 1-code 整树" \
  '! git -C "$DEST" sparse-checkout list | grep -qx "1-code"'
expect_eq "收窄后 secret 仍不可见" 0 "$( [ -e "$DEST/1-code/secret-tree/hidden.txt" ] && echo 1 || echo 0 )"

git -C "$DEST" sparse-checkout set --skip-checks 0-meta .agents 1-code >/dev/null
printf 'x\n' >> "$DEST/1-code/fixture-app/note.txt"
git -C "$DEST" add 1-code/fixture-app/note.txt
git -C "$DEST" commit -qm 'wip: hide-me'
set +e
narrow_block="$(cd "$DEST" && run_new "$DEST" task bind 7 2>&1)"
narrow_block_rc=$?
set -e
expect_true "过宽+独有提交 BLOCK" '[ "$narrow_block_rc" != 0 ]'
if [ "$narrow_block_rc" = 0 ]; then printf '%s\n' "$narrow_block" >&2; fi
git -C "$DEST" reset -q --hard origin/main
git -C "$DEST" sparse-checkout set --skip-checks \
  0-meta .agents 1-code/fixture-app/note.txt \
  2-infra/ops-control/policy/logging.yml \
  2-infra/ops-control/newdir >/dev/null

# ── 远端同名分支 / 已有 upstream ───────────────────────────────
git -C "$MAIN" branch code/task-8 "$(git -C "$MAIN" rev-parse origin/main)"
git -C "$MAIN" push -q origin code/task-8
git -C "$MAIN" branch -D code/task-8 >/dev/null
write_contract "$MAIN/0-meta/tasks/8/contract.json" 8
git -C "$MAIN" add 0-meta/tasks/8/contract.json
git -C "$MAIN" commit -qm 'contract 8'
git -C "$MAIN" push -q origin main
# 8 的派生分支是 code/task-8，远端已有
set +e
neg_remote="$(cd "$MAIN" && run_new "$MAIN" task worktree 8 2>&1)"
neg_remote_rc=$?
set -e
expect_true "远端同名分支 BLOCK" '[ "$neg_remote_rc" != 0 ]'
expect_contains "远端同名诊断" "$neg_remote" "远端已有同名分支"

# 用 origin/main 挂一棵树，证明已有 upstream 不被自动抹掉
UP="$TDIR/upstream-wt"
git -C "$MAIN" worktree add --no-checkout -q -b code/task-upstream "$UP" origin/main
git -C "$UP" sparse-checkout init --cone >/dev/null
git -C "$UP" sparse-checkout set 0-meta .agents 1-code/fixture-app >/dev/null
git -C "$UP" checkout -q
expect_eq "对照：origin/main 起点会设 upstream" \
  origin/main "$(git -C "$UP" rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || true)"

# ── A3 fresh branch 已可进 claim（无需 unset-upstream）──────────
set +e
pre3="$(cd "$DEST" && run_new "$DEST" task 2>&1)"
pre3_rc=$?
set -e
expect_eq "A3 预检 0" 0 "$pre3_rc"
expect_true "A3 分支已带 Issue 后缀" \
  '[ "$(git -C "$DEST" branch --show-current)" = "code/task-7" ]'

# ── A4 launcher：winner 启动、loser 不启动、main 不被污染 ─────
MAIN_CFG_BEFORE="$(git -C "$MAIN" config --local --list | grep -E 'remote\.(origin|claim)|receivepack' | LC_ALL=C sort || true)"
BEFORE_LAUNCH="$(git -C "$DEST" rev-parse HEAD)"
: > "$LAUNCH_LOG"
set +e
ISSUE15_AGENT_MODE=implement
win="$(cd "$DEST" && run_new "$DEST" task codex 2>&1)"
win_rc=$?
set -e
expect_eq "A5/A4 winner launch 0" 0 "$win_rc"
if [ "$win_rc" != 0 ]; then printf '%s\n' "$win" >&2; fi
expect_eq "A4 只启动一次" 1 "$(wc -l < "$LAUNCH_LOG" | tr -d ' ')"
expect_true "A4 claim ref 存在" \
  '[ -n "$(GIT_TERMINAL_PROMPT=0 git -C "$DEST" ls-remote origin refs/claims/7)" ]'
expect_true "A5 Agent 读了 Contract" '[ -s "$TDIR/agent-read-contract.json" ]'
expect_true "A5 真实实现进 HEAD" \
  '[ -f "$DEST/2-infra/ops-control/newdir/hello.txt" ]'
expect_true "A5 实现引用 contract blob" \
  'grep -q "$(git -C "$DEST" rev-parse origin/main:0-meta/tasks/7/contract.json)" "$DEST/2-infra/ops-control/newdir/hello.txt"'
expect_eq "A5 实现后干净" "" "$(git -C "$DEST" status --porcelain)"
set +e
comp="$(task_completion_gate "$DEST" "$BEFORE_LAUNCH" changed 2>&1)"
comp_rc=$?
set -e
expect_eq "A5 #13 completion changed" 0 "$comp_rc"
if [ "$comp_rc" != 0 ]; then printf '%s\n' "$comp" >&2; git -C "$DEST" status --short >&2; git -C "$DEST" log --oneline -3 >&2; fi
expect_contains "A5 completion 输出" "$comp" "completion=changed"
expect_contains "A5 start card 不是立即 Review" \
  "$(cat "$TDIR/last-prompt.txt")" "continue development"
expect_contains "A5 handoff 文本" \
  "$(cat "$TDIR/last-prompt.txt")" "不表示开发完成"

# loser：另一棵独立 clone，worktree 根目录不同，但共享 origin claim。
git clone -q "$CONS/origin.git" "$TDIR/loser-main"
git_cfg "$TDIR/loser-main"
git -C "$TDIR/loser-main" remote set-url origin https://github.com/o/r.git
git -C "$TDIR/loser-main" config "url.${BARE}.insteadOf" https://github.com/o/r.git
cp "$ROOT/0-meta/bin/new" "$TDIR/loser-main/0-meta/bin/"
chmod +x "$TDIR/loser-main/0-meta/bin/new"
rm -rf "$TDIR/loser-main/0-meta/lib/new"
cp -R "$ROOT/0-meta/lib/new" "$TDIR/loser-main/0-meta/lib/"
set +e
lose_boot="$(cd "$TDIR/loser-main" && run_new "$TDIR/loser-main" task worktree 7 2>&1)"
lose_boot_rc=$?
set -e
LOSER_DEST="$TDIR/worktrees/task-7"
if [ "$lose_boot_rc" = 0 ] && [ -d "$LOSER_DEST" ]; then
  set +e
  lose="$(cd "$LOSER_DEST" && run_new "$LOSER_DEST" task codex 2>&1)"
  lose_rc=$?
  set -e
  expect_true "A4 loser 非 0" '[ "$lose_rc" != 0 ]'
  expect_contains "A4 loser 已被领取" "$lose" "已被领取"
  expect_eq "A4 loser 不增加 launch" 1 "$(wc -l < "$LAUNCH_LOG" | tr -d ' ')"
else
  bad "loser bootstrap 未建立 dest rc=${lose_boot_rc}"
  printf '%s\n' "$lose_boot" >&2
fi

MAIN_CFG_AFTER="$(git -C "$MAIN" config --local --list | grep -E 'remote\.(origin|claim)|receivepack' | LC_ALL=C sort || true)"
expect_eq "A4 main origin/claim/receivepack 未变" "$MAIN_CFG_BEFORE" "$MAIN_CFG_AFTER"
expect_true "A4 task worktree 启用 worktreeConfig" \
  '[ "$(git -C "$DEST" config --bool extensions.worktreeConfig 2>/dev/null || true)" = true ]'
expect_eq "A4 claim fetch = origin fetch" \
  "$(git -C "$DEST" remote get-url origin)" \
  "$(git -C "$DEST" remote get-url claim 2>/dev/null || true)"
expect_eq "A4 main 无 claim remote" \
  "" "$(git -C "$MAIN" remote get-url claim 2>/dev/null || true)"
expect_eq "A4 main 无 origin receivepack" \
  "" "$(git -C "$MAIN" config --get remote.origin.receivepack 2>/dev/null || true)"

# ── Agent rc=0 但未实现：不是 completion ────────────────────────
# 另开 issue 9，避免 7 已被 claim。
write_contract "$MAIN/0-meta/tasks/9/contract.json" 9
git -C "$MAIN" add 0-meta/tasks/9/contract.json
git -C "$MAIN" commit -qm 'contract 9'
git -C "$MAIN" push -q origin main
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["data"]["repository"]["issue"]["id"]="I9"; json.dump(d, open(p,"w"))' "$GH_ISSUE"
set +e
boot9="$(cd "$MAIN" && run_new "$MAIN" task worktree 9 2>&1)"
boot9_rc=$?
set -e
DEST9="$(cd "$MAIN/.." && pwd)/worktrees/task-9"
expect_eq "issue9 bootstrap 0" 0 "$boot9_rc"
: > "$LAUNCH_LOG"
set +e
ISSUE15_AGENT_MODE=noop
noop="$(cd "$DEST9" && run_new "$DEST9" task grok 2>&1)"
noop_rc=$?
set -e
expect_eq "noop agent rc=0" 0 "$noop_rc"
set +e
comp_noop="$(task_completion_gate "$DEST9" origin/main changed 2>&1)"
comp_noop_rc=$?
set -e
expect_true "rc=0 但无实现 ≠ completion" '[ "$comp_noop_rc" != 0 ]'
next9="$(task_next_canonical_command "$DEST9" origin/main)"
expect_eq "未完成下一步是 continue development" \
  "continue development" "$next9"

# ── claim 成功 + launch 失败：锁保留，不退回 Ready ─────────────
write_contract "$MAIN/0-meta/tasks/10/contract.json" 10
git -C "$MAIN" add 0-meta/tasks/10/contract.json
git -C "$MAIN" commit -qm 'contract 10'
git -C "$MAIN" push -q origin main
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["data"]["repository"]["issue"]["id"]="I10"; json.dump(d, open(p,"w"))' "$GH_ISSUE"
set +e
boot10="$(cd "$MAIN" && run_new "$MAIN" task worktree 10 2>&1)"
boot10_rc=$?
set -e
DEST10="$(cd "$MAIN/.." && pwd)/worktrees/task-10"
expect_eq "issue10 bootstrap 0" 0 "$boot10_rc"
set +e
ISSUE15_AGENT_MODE=fail
fail_launch="$(cd "$DEST10" && run_new "$DEST10" task codex 2>&1)"
fail_launch_rc=$?
set -e
expect_true "launch 失败非 0" '[ "$fail_launch_rc" != 0 ]'
expect_true "claim 仍在" \
  '[ -n "$(GIT_TERMINAL_PROMPT=0 git -C "$DEST10" ls-remote origin refs/claims/10)" ]'
Z_WT="$DEST10" Z_MAIN=main Z_OWNER=o Z_REPO=r
derived10="$(derive_task_state 10)"
expect_eq "launch 失败不退回 Ready" "In progress" "$derived10"

# ── 手工 --path 安全检查仍在 ───────────────────────────────────
set +e
manual="$(cd "$MAIN" && run_new "$MAIN" worktree badpath --path 2-infra/does-not-exist 2>&1)"
manual_rc=$?
set -e
expect_true "manual --path 缺失仍失败" '[ "$manual_rc" != 0 ]'
expect_contains "manual 提示基点不存在" "$manual" "不存在"

# ── next command：完成后才是 Review ────────────────────────────
next7="$(task_next_canonical_command "$DEST" "$BEFORE_LAUNCH")"
expect_eq "完成后下一步 Review" "new z review <review-input>" "$next7"
next_up="$(task_next_canonical_command "$UP" origin/main)"
expect_eq "无实现下一步 continue" "continue development" "$next_up"

# ── 函数级：framework readable / expected sparse ───────────────
expect_true "AGENTS.md 框架可读" 'task_framework_readable_path AGENTS.md'
expect_true "0-meta 框架可读" 'task_framework_readable_path 0-meta'
expect_true "业务文件不是框架可读" '! task_framework_readable_path 1-code/secret-tree'
exp="$(task_sparse_expected_paths "$MAIN" "$(printf '%s\n' '1-code/fixture-app/note.txt' '2-infra/ops-control/policy/logging.yml' '2-infra/ops-control/newdir')" HEAD)"
expect_true "expected 含精确文件" \
  'printf "%s\n" "$exp" | grep -Fxq "1-code/fixture-app/note.txt"'
expect_true "expected 含缺失目录" \
  'printf "%s\n" "$exp" | grep -Fxq "2-infra/ops-control/newdir"'
expect_true "expected 不含 1-code 父目录" \
  '! printf "%s\n" "$exp" | grep -Fxq "1-code"'
expect_true "expected 不含 AGENTS.md set 项" \
  '! printf "%s\n" "$exp" | grep -Fxq "AGENTS.md"'

echo "bootstrap.test.sh: 通过 ${pass}，失败 ${fail}"
[ "$fail" -eq 0 ]
