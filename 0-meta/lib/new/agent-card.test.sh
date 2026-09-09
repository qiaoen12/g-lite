#!/usr/bin/env bash
# #28 定向测试：start card / budget / 拒绝路径的 canonical 下一步。
# 只用本地 git 夹具，不调用真实 GitHub、Orca 或候选 runtime。
set -Eeuo pipefail
export LC_COLLATE=C
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
. "$ROOT/0-meta/lib/new/core.sh"
. "$ROOT/0-meta/lib/new/task.sh"
. "$ROOT/0-meta/lib/new/contract.sh"
. "$ROOT/0-meta/lib/new/metrics.sh"
. "$ROOT/0-meta/lib/new/check.sh"
. "$ROOT/.agents/skills/z-lib.sh"
. "$ROOT/.agents/skills/zmerge/scripts/merge-lib.sh"
trap tmp_cleanup EXIT

fail=0
pass=0
TDIR=""
tmp_mkd TDIR agent-card-test

ok() { pass=$((pass+1)); }
bad() { echo "✗ $*" >&2; fail=$((fail+1)); }
expect_eq() {
  if [ "$2" = "$3" ]; then ok; else bad "$1：期望 [$2] 实际 [$3]"; fi
}
expect_true() { if eval "$2"; then ok; else bad "$1"; fi; }

# ── start card identity / loaded_bytes ───────────────────────────────────
GROK="$(task_agent_start_prompt C 28 https://example.test/28 "$TDIR/wt" \
  '0-meta/lib/new/' 'In progress' owner repo grok)"
CODEX="$(task_agent_start_prompt C 28 https://example.test/28 "$TDIR/wt" \
  '0-meta/lib/new/' 'In progress' owner repo codex)"
GCARD="$(task_start_card_extract <<< "$GROK")"
CCARD="$(task_start_card_extract <<< "$CODEX")"
expect_eq "start card Grok/Codex identity" "$GCARD" "$CCARD"
expect_true "start card 有 Issue/Contract/worktree/branch/state/scope/next" \
  'printf "%s\n" "$GCARD" | grep -Fq "Issue | owner/repo#28" &&
   printf "%s\n" "$GCARD" | grep -Fq "Contract | \`origin/main:0-meta/tasks/28/contract.json\`" &&
   printf "%s\n" "$GCARD" | grep -Fq "Worktree | \`$TDIR/wt\`" &&
   printf "%s\n" "$GCARD" | grep -Fq "Branch | unknown（git: unknown）" &&
   printf "%s\n" "$GCARD" | grep -Fq "Derived state | In progress" &&
   printf "%s\n" "$GCARD" | grep -Fq "Allowed scope | 0-meta/lib/new/" &&
   printf "%s\n" "$GCARD" | grep -Fq "Next canonical command | new z dev"'
expect_true "start card 不要求先读 07/08" \
  '! printf "%s\n" "$GCARD" | grep -Eq "请先读|07/08|0-meta/policy\.yaml"'
expect_eq "TASK_PROMPT_READS 为空" "" "$TASK_PROMPT_READS"
card_bytes="$(printf '%s' "$GCARD" | wc -c | tr -d ' ')"
expect_true "start card 在 2048 bytes 内" '[ "$card_bytes" -le 2048 ]'
expect_eq "loaded_bytes 只量 card" "$card_bytes" \
  "$(task_prompt_loaded_bytes "$TDIR/wt" "$GROK")"
expect_true "真实短 scope start card 通过动态 budget" '[ -n "$GCARD" ]'

mkdir -p "$TDIR/wt/0-meta"
printf '%s' "$(head -c 9000 /dev/zero | tr '\0' x)" > "$TDIR/wt/AGENTS.md"
printf '%s' "$(head -c 9000 /dev/zero | tr '\0' y)" > "$TDIR/wt/0-meta/policy.yaml"
expect_eq "按需文件不进 loaded_bytes" "$card_bytes" \
  "$(task_prompt_loaded_bytes "$TDIR/wt" "$GROK")"

# ── budget 正常与人为超预算 ─────────────────────────────────────────────
budget_out="$(prompt_budget_check "$ROOT" "$ROOT/0-meta/derived.lock" 2>&1)" || {
  bad "当前 budget 应通过：$budget_out"
}
if [ -n "$budget_out" ]; then ok; fi
fake_lock="$TDIR/over-budget.lock"
awk -F' = ' '{ if ($1 == "prompt_budget.root_agents_bytes") print $1 " = 1"; else print }' \
  "$ROOT/0-meta/derived.lock" > "$fake_lock"
over_out="$(prompt_budget_check "$ROOT" "$fake_lock" 2>&1)" || true
expect_true "人为超预算失败并指出对象" \
  'printf "%s\n" "$over_out" | grep -Fq "prompt budget 超限：AGENTS.md"'

long_scope=""
for n in $(seq 1 180); do
  long_scope="${long_scope}0-meta/lib/new/generated-${n}/"$'\n'
done
if out="$(task_start_card owner repo 28 https://example.test/28 main \
    0000000000000000000000000000000000000000 "$TDIR/wt" meta/issue-28 \
    meta/issue-28 'In progress' "$long_scope" 'new z dev' \
    0000000000000000000000000000000000000000 2>&1)"; then
  bad "真实超长 scope start card 应被动态 budget 拒绝"
else
  expect_true "真实超长 scope 失败并指出 canonical start card" \
    'printf "%s\n" "$out" | grep -Fq "canonical start card" &&
     printf "%s\n" "$out" | grep -Fq "prompt budget"'
fi

# ── 拒绝路径：未 bind / 未 approve / 未 claim / scope / stale / main / lock ─
last_clean() {
  printf '%s\n' "$1" | sed $'s/\x1b\\[[0-9;]*m//g' | awk 'NF{last=$0} END{print last}'
}
expect_next() {
  local name="$1" expected="$2" output="$3" last
  last="$(last_clean "$output")"
  expect_eq "$name 最后一行" "$expected" "$last"
  if printf '%s\n' "$output" | grep -Eiq 'grok|codex|orca'; then
    bad "$name 输出不应依赖产品专属命令"
  else
    ok
  fi
}

out="$(task_hint_bind 28 2>&1)"
expect_next "未 bind" "new task bind 28" "$out"

PAIR="$TDIR/unapproved"
ORIGIN="$PAIR/origin.git"
WORK="$PAIR/work"
mkdir -p "$PAIR"
git init -q --bare -b main "$ORIGIN"
git init -q -b main "$WORK"
git -C "$WORK" config user.email t@example.com
git -C "$WORK" config user.name t
printf 'main\n' > "$WORK/README.md"
git -C "$WORK" add README.md
git -C "$WORK" commit -qm init
git -C "$WORK" remote add origin "$ORIGIN"
git -C "$WORK" push -q -u origin main
mkdir -p "$WORK/0-meta"
missing_json="$TDIR/missing.json"
if out="$(contract_load_main "$WORK" 28 "$missing_json" main 2>&1)"; then
  bad "未 approve 应失败"
else
  expect_next "未 approve" "new task approve 28" "$out"
fi

derive_task_state() { printf '%s\n' "$TASK_STATUS_READY"; }
Z_NUMBER=28
Z_STATUS="$TASK_STATUS_READY"
if out="$(z_require_dev_status 2>&1)"; then
  bad "未 claim 应失败"
else
  expect_next "未 claim" "下一步：new task claim" "$out"
fi

Z_SCOPE='0-meta/lib/new/'
task_path_hard_denied() { return 1; }
task_path_in_scope() { return 1; }
if out="$(z_require_staged_in_scope '1-code/outside.txt' 2>&1)"; then
  bad "scope 越界应失败"
else
  expect_next "scope 越界" "下一步：new task approve 28" "$out"
fi

task_passing_squash_title() { printf '%s\n' 'refactor(meta): card'; }
task_unique_marked_comment() { printf '%s\n' '| Contract | old-blob |'; }
contract_stale() { return 0; }
Z_OWNER=owner
Z_REPO=repo
Z_CONTRACT_BLOB=new-blob
Z_CONTRACT_JSON="$TDIR/contract.json"
Z_HEAD=head
Z_BASE=origin/main
if out="$(z_require_passing_review 2>&1)"; then
  bad "Review stale 应失败"
else
  expect_next "Review stale" "下一步：new z review <review-input>" "$out"
fi

Z_WT="$WORK"
Z_MAIN=main
z_fetch_origin_main() { return 0; }
z_main_is_current() { return 1; }
if out="$(z_require_current_main 2>&1)"; then
  bad "main ahead 应失败"
else
  expect_next "main ahead" "下一步：new z sync" "$out"
fi

LOCK_REPO="$TDIR/lock-repo"
git init -q -b main "$LOCK_REPO"
git -C "$LOCK_REPO" config user.email t@example.com
git -C "$LOCK_REPO" config user.name t
printf 'lock\n' > "$LOCK_REPO/file"
git -C "$LOCK_REPO" add file
git -C "$LOCK_REPO" commit -qm init
LOCK_PATH="$LOCK_REPO/.git/zmerge.lock"
python3 -c 'import fcntl,sys,time; f=open(sys.argv[1],"w"); fcntl.flock(f,fcntl.LOCK_EX); time.sleep(5)' \
  "$LOCK_PATH" &
holder=$!
sleep 0.2
if out="$(cd "$LOCK_REPO" && ZMERGE_LOCK_HOLDER="$ROOT/.agents/skills/zmerge/scripts/hold-lock.py" z_merge_lock_acquire 2>&1)"; then
  bad "merge lock busy 应失败"
else
  expect_next "merge lock busy" "下一步：new z merge" "$out"
fi
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true

echo "agent-card.test.sh: 通过 ${pass}，失败 ${fail}"
[ "$fail" = 0 ]
