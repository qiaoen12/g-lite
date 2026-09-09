#!/usr/bin/env bash
# 41a/41b：PATH 无 orca 的 vanilla/sparse worktree、bind 收成 sparse、只读预检、
# canonical `new z` 加载、未 bind / 未 approve。不写真实 Project。
set -Eeuo pipefail
export LC_COLLATE=C
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/0-meta/lib/new/core.sh"
# shellcheck source=/dev/null
. "$ROOT/0-meta/lib/new/task.sh"
trap 'rt_cleanup; tmp_cleanup' EXIT

fail=0
pass=0
ok() { pass=$((pass+1)); }
bad() { echo "✗ $*" >&2; fail=$((fail+1)); }
expect_eq() {
  if [ "$2" = "$3" ]; then ok
  else bad "$1: 期望 [$2] 实际 [$3]"; fi
}
expect_true() { if eval "$2"; then ok; else bad "$1"; fi; }
last_line() { printf '%s\n' "$1" | awk 'NF{last=$0} END{print last}'; }

TDIR=""
tmp_mkd TDIR portable-runtime
export XDG_STATE_HOME="$TDIR/state"
SEED=""
rt_cleanup() {
  local p
  [ -n "${SEED:-}" ] && [ -d "$SEED/wt" ] || return 0
  git -C "$SEED/wt" worktree list --porcelain 2>/dev/null \
    | awk '/^worktree /{print $2}' | while read -r p; do
      [ "$p" = "$SEED/wt" ] && continue
      git -C "$SEED/wt" worktree remove --force "$p" >/dev/null 2>&1 || true
    done
}

git_cfg() {
  git -C "$1" config user.email t@t
  git -C "$1" config user.name t
  git -C "$1" config commit.gpgsign false
  git -C "$1" config core.hooksPath /dev/null
}

path_without_orca() {
  local p out="" IFS=:
  for p in $PATH; do
    [ -n "$p" ] || continue
    [ -x "$p/orca" ] && continue
    out="${out:+$out:}$p"
  done
  printf '%s' "$out"
}

# ── G 静态：policy/derived/源码 ────────────────────────────────────────
expect_true "G policy.root 不是本机绝对路径" \
  '! grep -Eq "^root:[[:space:]]*/Users/qiaoen/Projects2" "$ROOT/0-meta/policy.yaml"'
expect_true "G lock.root 不是本机绝对路径" \
  '[ "$(policy_get root)" != "/Users/qiaoen/Projects2" ]'
expect_true "G 无 tracked workspace.id" \
  '! grep -Eq "^[[:space:]]*workspace\.id:" "$ROOT/0-meta/policy.yaml"'
expect_true "G Project number 来自 lock" \
  '[ -n "$(policy_get github.project.number)" ]'
expect_true "G Project title 不是 Projects2 专属" \
  '[ "$(policy_get github.project.title)" != "Projects2 Tasks" ]'
expect_true "G worktree.root 不是 Projects2-worktrees" \
  '! grep -Fq "Projects2-worktrees" "$ROOT/0-meta/policy.yaml"'
expect_eq "G Status ready 来自 lock" "Ready" "$(policy_get github.status.ready)"
expect_eq "G Status progress 来自 lock" "In progress" "$(policy_get github.status.progress)"
expect_true "G task.sh 不再写死 Project #2" \
  '! grep -Fq "TASK_PROJECT_NUMBER=2" "$ROOT/0-meta/lib/new/task.sh"'
expect_eq "G TASK_PROJECT_NUMBER 已从 lock 加载" "$(policy_get github.project.number)" "$TASK_PROJECT_NUMBER"
tmpd=""
atomic_tmp tmpd "$TDIR/derived.out"
"$ROOT/0-meta/audit/scripts/derive-paths.sh" > "$tmpd"
if diff -q "$ROOT/0-meta/derived.lock" "$tmpd" >/dev/null; then ok
else bad "G new plan 后 derived.lock 仍有漂移"; diff -u "$ROOT/0-meta/derived.lock" "$tmpd" | head -40 >&2
fi
atomic_abort "$tmpd"

# ── F PR 查询 ──────────────────────────────────────────────────────────
expect_true "F list_prs 使用 --head" \
  'grep -Fq -- "--head" "$ROOT/0-meta/lib/new/claim.sh"'
expect_true "F 不再全仓 --limit 100" \
  '! grep -Fq -- "--limit 100" "$ROOT/0-meta/lib/new/claim.sh"'
expect_true "41b bin/new 有 z 入口" \
  'grep -Eq "^[[:space:]]*z\)" "$ROOT/0-meta/bin/new"'
expect_true "41b cmd_task 有 claim 模式" \
  'grep -Fq "mode=\"claim\"" "$ROOT/0-meta/lib/new/task.sh"'
expect_true "41b grok 仍走同一 claim 核心" \
  'grep -Eq "^[[:space:]]+task_claim_or_resume$" "$ROOT/0-meta/lib/new/task.sh"'
expect_true "41b zdev SKILL 调用 new z dev" \
  'grep -Fq "new z dev" "$ROOT/.agents/skills/zdev/SKILL.md"'
expect_true "41b zdev SKILL 不以 Orca 为身份源" \
  '! grep -Fq "Orca 绑定" "$ROOT/.agents/skills/zdev/SKILL.md"'
expect_true "41b zdev SKILL 以 bind+Contract 为身份" \
  'grep -Fq "binding + origin/main Contract" "$ROOT/.agents/skills/zdev/SKILL.md"'
expect_true "41b zpr SKILL 调用 new z pr" \
  'grep -Fq "new z pr" "$ROOT/.agents/skills/zpr/SKILL.md"'
expect_true "41b zmerge SKILL 调用 new z merge" \
  'grep -Fq "new z merge" "$ROOT/.agents/skills/zmerge/SKILL.md"'
expect_true "41b require-active 是 new z adapter" \
  'grep -Fq "new z fix" "$ROOT/.agents/skills/zdev/scripts/require-active.sh"'

# override 优先于 origin
cp "$ROOT/0-meta/derived.lock" "$TDIR/over.lock"
awk '{
  if ($0 ~ /^github.repo_override =/) print "github.repo_override = other/fork"
  else print
}' "$ROOT/0-meta/derived.lock" > "$TDIR/over.lock"
over="$(LOCK="$TDIR/over.lock" task_repo_nwo "$ROOT")"
expect_eq "G repo_override 覆盖 origin" "other/fork" "$over"

# ── 夹具仓库 ──────────────────────────────────────────────────────────
SEED="$TDIR/rt"
mkdir -p "$SEED"
git init --bare -b main "$SEED/origin.git" >/dev/null
git clone "$SEED/origin.git" "$SEED/wt" >/dev/null 2>&1
git_cfg "$SEED/wt"
mkdir -p "$SEED/wt/0-meta/tasks/99" "$SEED/wt/.agents" \
  "$SEED/wt/0-meta/bin" "$SEED/wt/0-meta/lib" "$SEED/wt/0-meta/schema"
cp "$ROOT/0-meta/policy.yaml" "$SEED/wt/0-meta/"
cp "$ROOT/0-meta/derived.lock" "$SEED/wt/0-meta/"
cp "$ROOT/0-meta/bin/new" "$SEED/wt/0-meta/bin/"
chmod +x "$SEED/wt/0-meta/bin/new"
cp -R "$ROOT/0-meta/lib/new" "$SEED/wt/0-meta/lib/"
cp -R "$ROOT/0-meta/schema/." "$SEED/wt/0-meta/schema/"
printf 'keep\n' > "$SEED/wt/.agents/.keep"
mkdir -p "$SEED/wt/.agents/skills"
cp "$ROOT/.agents/skills/z-lib.sh" "$SEED/wt/.agents/skills/"
mkdir -p "$SEED/wt/1-code"
printf 'secret\n' > "$SEED/wt/1-code/out-of-scope.txt"
cat > "$SEED/wt/0-meta/tasks/99/contract.json" <<'JSON'
{
  "schema_version": "task-contract/v1",
  "issue": "#99",
  "title": "portable",
  "goal": "g",
  "requirements": [{"id": "R1", "text": "x"}],
  "acceptances": [{"id": "A1", "text": "y", "requires": ["R1"], "applicable_when": null}],
  "scope": ["0-meta/lib/new"]
}
JSON
printf 'base\n' > "$SEED/wt/README.md"
git -C "$SEED/wt" add -A
git -C "$SEED/wt" commit -m seed >/dev/null
git -C "$SEED/wt" push -u origin main >/dev/null 2>&1
bare="$(cd "$SEED/origin.git" && pwd)"
git -C "$SEED/wt" remote set-url origin https://github.com/o/r.git
git -C "$SEED/wt" config "url.${bare}.insteadOf" https://github.com/o/r.git

git -C "$SEED/wt" worktree add -b meta/portable-full "$SEED/full" >/dev/null 2>&1
git -C "$SEED/wt" worktree add --no-checkout -b meta/portable-sparse "$SEED/sparse" >/dev/null 2>&1
git -C "$SEED/sparse" sparse-checkout init --cone >/dev/null
git -C "$SEED/sparse" sparse-checkout set 0-meta .agents >/dev/null
git -C "$SEED/sparse" checkout -q
git -C "$SEED/wt" worktree add -b meta/portable-unbound "$SEED/unbound" >/dev/null 2>&1
git -C "$SEED/wt" worktree add -b meta/has-41 "$SEED/guess" >/dev/null 2>&1
git -C "$SEED/wt" worktree add -b meta/portable-off "$SEED/off" >/dev/null 2>&1

MOCK="$TDIR/mockbin"
mkdir -p "$MOCK"
GH_ISSUE="$TDIR/issue.json"
GH_PR="$TDIR/prs.json"
GH_LOG="$TDIR/gh.log"
: > "$GH_LOG"
printf '%s\n' '[]' > "$GH_PR"
cat > "$GH_ISSUE" <<'JSON'
{
  "data": {
    "repository": {
      "issue": {
        "id": "I99",
        "title": "portable",
        "url": "https://github.com/o/r/issues/99",
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
if [ "\$1" = api ] && [ "\$2" = graphql ]; then
  cat "$GH_ISSUE"
  exit 0
fi
echo "unexpected gh \$*" >&2
exit 1
EOF
chmod +x "$MOCK/gh"
CLEAN_PATH="$MOCK:$(path_without_orca)"
expect_true "A PATH 看不到 orca" '! env PATH="$CLEAN_PATH" command -v orca >/dev/null'

run_new() {
  local wt="$1"; shift
  env PATH="$CLEAN_PATH" XDG_STATE_HOME="$TDIR/state" \
    GIT_TERMINAL_PROMPT=0 \
    "$wt/0-meta/bin/new" "$@"
}

# ── A vanilla full ────────────────────────────────────────────────────
set +e
a_bind="$(cd "$SEED/full" && run_new "$SEED/full" task bind 99 2>&1)"
a_bind_rc=$?
set -e
expect_eq "A bind 退出 0" 0 "$a_bind_rc"
if [ "$a_bind_rc" != 0 ]; then printf '%s\n' "$a_bind" >&2; fi
expect_eq "A bind 写入 local config" "99" "$(task_bind_read "$SEED/full")"
expect_true "A bind 提到 o/r#99" 'printf "%s\n" "$a_bind" | grep -Fq "o/r#99"'
expect_eq "A bind 后 core.sparseCheckout" "true" \
  "$(git -C "$SEED/full" config --bool core.sparseCheckout 2>/dev/null || true)"
expect_true "A bind 后越界目录不可见" '[ ! -e "$SEED/full/1-code/out-of-scope.txt" ]'
expect_true "A bind 后 0-meta 仍可见" '[ -d "$SEED/full/0-meta" ]'
set +e
a_out="$(cd "$SEED/full" && run_new "$SEED/full" task 2>&1)"
a_rc=$?
set -e
expect_eq "A new task 预检退出 0" 0 "$a_rc"
expect_true "A 预检通过且未领取" 'printf "%s\n" "$a_out" | grep -Fq "预检通过。未领取、未改 GitHub、未启动 Agent。"'
expect_true "A 预检走 sparse 可见范围" 'printf "%s\n" "$a_out" | grep -Fq "可见"'
expect_true "A 不再把完整检出当合法" '! printf "%s\n" "$a_out" | grep -Fq "完整检出"'
expect_true "A 加载契约 blob" 'printf "%s\n" "$a_out" | grep -q "契约 origin/main:0-meta/tasks/99/contract.json blob"'
expect_true "A 身份是 o/r#99" 'printf "%s\n" "$a_out" | grep -Fq "o/r#99"'
expect_true "A 未调用 orca" '! env PATH="$CLEAN_PATH" command -v orca >/dev/null'

set +e
a_z="$(
  cd "$SEED/full" || exit 1
  export PATH="$CLEAN_PATH" XDG_STATE_HOME="$TDIR/state"
  # shellcheck source=/dev/null
  . "$ROOT/.agents/skills/z-lib.sh"
  z_load >/dev/null
  printf '%s %s/%s %s\n' "${Z_NUMBER:-}" "${Z_OWNER:-}" "${Z_REPO:-}" "${Z_LOGICAL_BR:-}"
)"
a_z_rc=$?
set -e
expect_eq "A z_load 退出 0" 0 "$a_z_rc"
expect_eq "A z_load 身份" "99 o/r meta/portable-full" "$a_z"

set +e
a_zcli="$(cd "$SEED/full" && run_new "$SEED/full" z 2>&1)"
a_zcli_rc=$?
a_zdev="$(cd "$SEED/full" && run_new "$SEED/full" z dev 2>&1)"
a_zdev_rc=$?
a_zbad="$(cd "$SEED/full" && run_new "$SEED/full" z nosuch 2>&1)"
a_zbad_rc=$?
a_claim_help="$(cd "$SEED/full" && run_new "$SEED/full" task -h 2>&1)"
a_claim_bad="$(cd "$SEED/full" && run_new "$SEED/full" task claim extra 2>&1)"
a_claim_bad_rc=$?
a_unknown="$(cd "$SEED/full" && run_new "$SEED/full" task not-an-agent 2>&1)"
a_unknown_rc=$?
set -e
expect_eq "A new z 用法退出 0" 0 "$a_zcli_rc"
expect_true "A new z 列出 dev/fix/sync/review/pr/merge" \
  'printf "%s\n" "$a_zcli" | grep -Fq "new z dev" && printf "%s\n" "$a_zcli" | grep -Fq "merge"'
expect_true "A new z dev 在 Ready 非 0" '[ "$a_zdev_rc" != 0 ]'
expect_true "A new z dev 已加载契约后拒绝" \
  'printf "%s\n" "$a_zdev" | grep -Fq "须先 new task claim"'
expect_true "A new z dev 已推导 Ready" \
  'printf "%s\n" "$a_zdev" | grep -Fq "当前：Ready"'
expect_true "A 未知 z 入口非 0" '[ "$a_zbad_rc" != 0 ]'
expect_true "A task -h 含 claim" 'printf "%s\n" "$a_claim_help" | grep -Fq "new task claim"'
expect_true "A claim 多余参数非 0" '[ "$a_claim_bad_rc" != 0 ]'
expect_true "A 未登记名字仍拒绝" '[ "$a_unknown_rc" != 0 ]'
expect_true "A 未登记提示 claim" \
  'printf "%s\n" "$a_unknown" | grep -Fq "new task claim"'

# ── B sparse，同一加载结果 ────────────────────────────────────────────
set +e
b_bind="$(cd "$SEED/sparse" && run_new "$SEED/sparse" task bind 99 2>&1)"
b_bind_rc=$?
set -e
expect_eq "B sparse bind 退出 0" 0 "$b_bind_rc"
expect_eq "B bind 后仍 sparse" "true" \
  "$(git -C "$SEED/sparse" config --bool core.sparseCheckout 2>/dev/null || true)"
expect_true "B 越界目录不可见" '[ ! -e "$SEED/sparse/1-code/out-of-scope.txt" ]'
set +e
b_out="$(cd "$SEED/sparse" && run_new "$SEED/sparse" task 2>&1)"
b_rc=$?
set -e
expect_eq "B sparse 预检退出 0" 0 "$b_rc"
expect_true "B 与 A 同一 Issue" \
  '[ "$(printf "%s\n" "$a_out" | grep "o/r#99" | head -1)" = "$(printf "%s\n" "$b_out" | grep "o/r#99" | head -1)" ]'
a_blob="$(printf '%s\n' "$a_out" | awk '/契约 origin\/main:/{print; exit}')"
b_blob="$(printf '%s\n' "$b_out" | awk '/契约 origin\/main:/{print; exit}')"
expect_eq "B 与 A 同一契约 blob" "$a_blob" "$b_blob"
expect_true "B 是 sparse" 'printf "%s\n" "$b_out" | grep -Fq "可见"'

# ── 已 bind 后再关闭 sparse：z_load / new task 都必须拒绝 ────────────
set +e
off_bind="$(cd "$SEED/off" && run_new "$SEED/off" task bind 99 2>&1)"
off_bind_rc=$?
set -e
expect_eq "off bind 退出 0" 0 "$off_bind_rc"
git -C "$SEED/off" sparse-checkout disable >/dev/null 2>&1 \
  || git -C "$SEED/off" config core.sparseCheckout false
expect_true "off 关闭后不是 sparse" \
  '[ "$(git -C "$SEED/off" config --bool core.sparseCheckout 2>/dev/null || true)" != true ]'
set +e
off_z="$(
  cd "$SEED/off" || exit 1
  export PATH="$CLEAN_PATH" XDG_STATE_HOME="$TDIR/state"
  # shellcheck source=/dev/null
  . "$ROOT/.agents/skills/z-lib.sh"
  z_load 2>&1
)"
off_z_rc=$?
set -e
expect_true "关闭 sparse 后 z_load 非 0" '[ "$off_z_rc" != 0 ]'
expect_true "关闭 sparse 后 z_load 报 not_sparse" \
  'printf "%s\n" "$off_z" | grep -Fq "可见性边界"'
set +e
off_task="$(cd "$SEED/off" && run_new "$SEED/off" task 2>&1)"
off_task_rc=$?
set -e
expect_true "关闭 sparse 后 new task 非 0" '[ "$off_task_rc" != 0 ]'
expect_true "关闭 sparse 后 new task 报 not_sparse" \
  'printf "%s\n" "$off_task" | grep -Fq "sparse-checkout"'

# ── C 未 bind ─────────────────────────────────────────────────────────
set +e
c_out="$(cd "$SEED/unbound" && run_new "$SEED/unbound" task 2>&1)"
c_rc=$?
set -e
expect_true "C 未 bind 非 0" '[ "$c_rc" != 0 ]'
expect_eq "C 末行是 bind 命令" "new task bind <n>" "$(last_line "$c_out")"
expect_true "C 不从分支猜号" '! printf "%s\n" "$c_out" | grep -Eq "bind 99|o/r#99"'

# ── D 分支带 -41 不猜 Issue ───────────────────────────────────────────
set +e
d_out="$(cd "$SEED/guess" && run_new "$SEED/guess" task 2>&1)"
d_rc=$?
set -e
expect_true "D 未 bind 非 0" '[ "$d_rc" != 0 ]'
expect_eq "D 末行不是 bind 41" "new task bind <n>" "$(last_line "$d_out")"
expect_true "D 不把 -41 当 Issue" '! printf "%s\n" "$d_out" | grep -Eq "#41|bind 41"'
expect_eq "D 未写入 bind" "" "$(task_bind_read "$SEED/guess")"

# ── E 契约不存在 ──────────────────────────────────────────────────────
set +e
e_out="$(cd "$SEED/full" && run_new "$SEED/full" task bind 98 2>&1)"
e_rc=$?
set -e
expect_true "E 无契约 bind 非 0" '[ "$e_rc" != 0 ]'
expect_eq "E 末行是稳定 main 的 approve" "new task approve 98" "$(last_line "$e_out")"
expect_true "E 提示稳定主工作区" 'printf "%s\n" "$e_out" | grep -Fq "稳定主工作区"'
expect_eq "E 失败不覆盖已有 bind" "99" "$(task_bind_read "$SEED/full")"

# F：预检若走到 list_prs，参数必须带 --head
if grep -q 'pr list' "$GH_LOG"; then
  expect_true "F 实际 gh pr list 带 --head" 'grep -q "pr list" "$GH_LOG" && grep -q -- "--head" "$GH_LOG"'
  expect_true "F 实际调用无 --limit 100" '! grep -q -- "--limit 100" "$GH_LOG"'
else
  ok
fi

echo "portable-runtime.test.sh: 通过 ${pass}，失败 ${fail}"
[ "$fail" -eq 0 ]
