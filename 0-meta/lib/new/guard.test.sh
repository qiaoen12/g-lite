#!/usr/bin/env bash
# 30：A3/A6 陈旧 staging / CAS 失败夹具，然后才测正常 lease 转发。
# GitHub 用本地 bare 仓代替。不写真实 Project，不改 claim/zmerge 语义。
set -Eeuo pipefail
export LC_COLLATE=C
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/0-meta/lib/new/core.sh"
. "$ROOT/0-meta/lib/new/worktree.sh"
# shellcheck source=/dev/null
. "$ROOT/0-meta/lib/new/task.sh"
# shellcheck source=/dev/null
. "$ROOT/0-meta/lib/new/guard.sh"
trap tmp_cleanup EXIT

fail=0
pass=0
ok() { pass=$((pass+1)); }
bad() { echo "✗ $*" >&2; fail=$((fail+1)); }
expect_eq() {
  if [ "$2" = "$3" ]; then ok
  else bad "$1: 期望 [$2] 实际 [$3]"; fi
}
expect_true() { if eval "$2"; then ok; else bad "$1"; fi; }

TDIR=""
tmp_mkd TDIR guard-cas
export XDG_STATE_HOME="$TDIR/state"
export HOME="$TDIR/home"
mkdir -p "$HOME"

git_cfg() {
  git -C "$1" config user.email t@t
  git -C "$1" config user.name t
  git -C "$1" config commit.gpgsign false
}

SRC="$ROOT/2-infra/git-guard"
GUARD_ZERO='0000000000000000000000000000000000000000'

# ── 静态：事实模型 ──────────────────────────────────────────
expect_true "snapshot 进 refs/guard/github" \
  'grep -Fq "refs/guard/github" "$SRC/lib.sh"'
expect_true "wrapper 在 receive-pack 前 snapshot" \
  'grep -Fq "guard_snapshot_github" "$SRC/receive-pack.sh" || grep -Fq "guard_snapshot_github" "$SRC/lib.sh"'
expect_true "pre-receive.sh 不 push GitHub" \
  '! grep -q "git push" "$SRC/pre-receive.sh" && grep -Fq "guard_pre_receive" "$SRC/pre-receive.sh"'
expect_true "post-receive 走 atomic 转发" \
  'grep -Fq "guard_post_receive" "$SRC/post-receive.sh" && grep -Fq -- "--atomic" "$SRC/lib.sh"'
expect_true "转发使用 --force-with-lease" \
  'grep -Fq -- "--force-with-lease" "$SRC/lib.sh"'
expect_true "转发不用裸 --force" \
  '! grep -E "(^|[[:space:]])--force([^=-]|$)" "$SRC/lib.sh"'
expect_true "判定不在 hook 里 ls-remote" \
  '! grep -q "ls-remote" "$SRC/lib.sh"'
expect_true "claim 仍推 claim remote" \
  'grep -Fq "claim \"\${lock}:" "$ROOT/0-meta/lib/new/claim.sh"'
expect_true "claim 仍 force-with-lease refs/claims" \
  'grep -Fq "force-with-lease=\"\$(task_claim_ref" "$ROOT/0-meta/lib/new/claim.sh"'
expect_true "origin fetch 不用 --push" \
  'grep -Fq "不得用 --push" "$ROOT/0-meta/lib/new/claim.sh"'

install_hooks() {
  local staging="$1"
  guard_install_hooks "$staging"
  git --git-dir="$staging" config receive.denyNonFastForwards false
  git --git-dir="$staging" config receive.denyDeletes false
  git --git-dir="$staging" config git-guard.main main
}

# 构造一对 GitHub / staging，都停在 OLD。返回 github、staging、wt 路径。
seed_old() {
  local prefix="$1"
  local github="$TDIR/${prefix}-github.git"
  local staging="$TDIR/${prefix}-staging.git"
  local seed="$TDIR/${prefix}-seed"
  local wt="$TDIR/${prefix}-wt"
  rm -rf "$github" "$staging" "$seed" "$wt"
  git init --bare -b main "$github" >/dev/null 2>&1
  git init --bare -b main "$staging" >/dev/null 2>&1
  git clone -q "$github" "$seed" >/dev/null 2>&1
  git_cfg "$seed"
  mkdir -p "$seed/0-meta/tasks/30"
  cp "$ROOT/0-meta/derived.lock" "$seed/0-meta/derived.lock"
  jq -n '{schema_version:"task-contract/v1",issue:"#30",requirements:[{id:"R1"}],
    acceptances:[{id:"A1"}],scope:["task.txt","0-meta","1-code/app"]}' \
    > "$seed/0-meta/tasks/30/contract.json"
  printf 'm\n' > "$seed/README"
  git -C "$seed" add README 0-meta >/dev/null
  git -C "$seed" commit -qm 'docs(repo): fixture main'
  git -C "$seed" switch -qc task-30 >/dev/null
  printf 't\n' > "$seed/task.txt"
  git -C "$seed" add task.txt >/dev/null
  git -C "$seed" commit -qm 'docs(repo): fixture task'
  git -C "$seed" push -q origin main >/dev/null 2>&1
  git -C "$seed" push -q origin task-30 >/dev/null 2>&1
  git --git-dir="$staging" remote add github "$github"
  install_hooks "$staging"
  GIT_TERMINAL_PROMPT=0 git --git-dir="$staging" fetch -q github '+refs/heads/*:refs/heads/*' >/dev/null 2>&1
  git clone -q "$github" "$wt" >/dev/null 2>&1
  git_cfg "$wt"
  printf '30\n' > "$(git -C "$wt" rev-parse --absolute-git-dir)/new.task.issue"
  git -C "$wt" remote set-url --push origin "$staging"
  git -C "$wt" config remote.origin.receivepack "$staging/hooks/guard-receive-pack"
  git -C "$wt" switch -q task-30 >/dev/null
  printf '%s' "$github"
  printf '\t%s' "$staging"
  printf '\t%s\n' "$wt"
}

advance_github() {
  local github="$1" br="$2" thief="$3"
  rm -rf "$thief"
  git clone -q "$github" "$thief" >/dev/null 2>&1
  git_cfg "$thief"
  git -C "$thief" switch -q "$br"
  printf 'new\n' >> "$thief/task.txt"
  git -C "$thief" add task.txt
  git -C "$thief" commit -qm 'docs(repo): fixture new'
  git -C "$thief" push -q origin "$br" >/dev/null
  git --git-dir="$github" rev-parse "refs/heads/${br}"
}

# ── A6 update：GitHub=NEW，staging=OLD，基于 OLD 的更新必须失败 ──
IFS=$'\t' read -r GH ST WT < <(seed_old a6u)
OLD="$(git --git-dir="$ST" rev-parse refs/heads/task-30)"
NEW="$(advance_github "$GH" task-30 "$TDIR/a6u-thief")"
expect_true "A6 构造：GitHub NEW != staging OLD" '[ "$NEW" != "$OLD" ]'
expect_eq "A6 构造：staging 仍是 OLD" "$OLD" "$(git --git-dir="$ST" rev-parse refs/heads/task-30)"
expect_eq "A6 构造：GitHub 是 NEW" "$NEW" "$(git --git-dir="$GH" rev-parse refs/heads/task-30)"

printf 'local\n' >> "$WT/task.txt"
git -C "$WT" add task.txt
git -C "$WT" commit -qm 'docs(repo): fixture local'
set +e
a6u_out="$(git -C "$WT" push --porcelain --force-with-lease="refs/heads/task-30:${OLD}" \
  origin "HEAD:refs/heads/task-30" 2>&1)"
a6u_rc=$?
set -e
expect_true "A6 update 必须非 0" '[ "$a6u_rc" != 0 ]'
expect_eq "A6 update 后 GitHub 仍是 NEW" "$NEW" "$(git --git-dir="$GH" rev-parse refs/heads/task-30)"
expect_eq "A6 update 后 staging 仍是 OLD" "$OLD" "$(git --git-dir="$ST" rev-parse refs/heads/task-30)"
expect_true "A6 update 提示 tip 已变" \
  'printf "%s\n" "$a6u_out" | grep -Fq "tip 已变"'

# ── A6 delete ──────────────────────────────────────────────
IFS=$'\t' read -r GH ST WT < <(seed_old a6d)
OLD="$(git --git-dir="$ST" rev-parse refs/heads/task-30)"
NEW="$(advance_github "$GH" task-30 "$TDIR/a6d-thief")"
set +e
a6d_out="$(git -C "$WT" push --porcelain --force-with-lease="refs/heads/task-30:${OLD}" \
  origin ":refs/heads/task-30" 2>&1)"
a6d_rc=$?
set -e
expect_true "A6 delete 必须非 0" '[ "$a6d_rc" != 0 ]'
expect_eq "A6 delete 后 GitHub NEW 仍在" "$NEW" "$(git --git-dir="$GH" rev-parse refs/heads/task-30)"
expect_true "A6 delete 后 GitHub 仍有 task-30" \
  'git --git-dir="$GH" show-ref --verify --quiet refs/heads/task-30'
expect_true "A6 delete 提示 tip 已变" \
  'printf "%s\n" "$a6d_out" | grep -Eq "tip 已变|拒绝基于陈旧"'

# ── A3：GitHub main 前进，staging 未同步，任务分支更新也拒绝 ──
IFS=$'\t' read -r GH ST WT < <(seed_old a3)
OLD_MAIN="$(git --git-dir="$ST" rev-parse refs/heads/main)"
THIEF="$TDIR/a3-thief"
rm -rf "$THIEF"
git clone -q "$GH" "$THIEF" >/dev/null 2>&1
git_cfg "$THIEF"
git -C "$THIEF" switch -q main
printf 'main-new\n' >> "$THIEF/README"
git -C "$THIEF" add README
git -C "$THIEF" commit -qm 'docs(repo): fixture main new'
git -C "$THIEF" push -q origin main >/dev/null
NEW_MAIN="$(git --git-dir="$GH" rev-parse refs/heads/main)"
expect_true "A3 构造：GitHub main != staging main" '[ "$NEW_MAIN" != "$OLD_MAIN" ]'
TASK_OLD="$(git --git-dir="$ST" rev-parse refs/heads/task-30)"
printf 'x\n' >> "$WT/task.txt"
git -C "$WT" add task.txt
git -C "$WT" commit -qm 'docs(repo): fixture task while main stale'
set +e
a3_out="$(git -C "$WT" push --porcelain --force-with-lease="refs/heads/task-30:${TASK_OLD}" \
  origin "HEAD:refs/heads/task-30" 2>&1)"
a3_rc=$?
set -e
expect_true "A3 必须非 0" '[ "$a3_rc" != 0 ]'
expect_eq "A3 后 GitHub main 仍是 NEW" "$NEW_MAIN" "$(git --git-dir="$GH" rev-parse refs/heads/main)"
expect_eq "A3 后 staging main 仍是 OLD" "$OLD_MAIN" "$(git --git-dir="$ST" rev-parse refs/heads/main)"
expect_eq "A3 后 GitHub task-30 未变" "$TASK_OLD" "$(git --git-dir="$GH" rev-parse refs/heads/task-30)"
expect_true "A3 提示 main 未同步/陈旧 contract" \
  'printf "%s\n" "$a3_out" | grep -Fq "陈旧 contract"'

# ── 镜像失败 fail-closed ──────────────────────────────────
IFS=$'\t' read -r GH ST WT < <(seed_old mf)
git --git-dir="$ST" remote set-url github "$TDIR/missing-github.git"
TASK_OLD="$(git --git-dir="$ST" rev-parse refs/heads/task-30)"
GH_TASK="$(git --git-dir="$GH" rev-parse refs/heads/task-30)"
printf 'y\n' >> "$WT/task.txt"
git -C "$WT" add task.txt
git -C "$WT" commit -qm 'docs(repo): fixture while mirror dead'
set +e
mf_out="$(git -C "$WT" push --porcelain --force-with-lease="refs/heads/task-30:${TASK_OLD}" \
  origin "HEAD:refs/heads/task-30" 2>&1)"
mf_rc=$?
set -e
expect_true "镜像失败必须非 0" '[ "$mf_rc" != 0 ]'
expect_eq "镜像失败后 GitHub task-30 不变" "$GH_TASK" "$(git --git-dir="$GH" rev-parse refs/heads/task-30)"
expect_true "镜像失败提示 fail-closed" \
  'printf "%s\n" "$mf_out" | grep -Eq "镜像|fail-closed"'

# ── 夹具稳定后：正常更新 + 删除经 staging 带 lease 转发 ──
IFS=$'\t' read -r GH ST WT < <(seed_old ok)
TASK_OLD="$(git --git-dir="$ST" rev-parse refs/heads/task-30)"
printf 'ok\n' >> "$WT/task.txt"
git -C "$WT" add task.txt
git -C "$WT" commit -qm 'docs(repo): fixture ok'
WANT="$(git -C "$WT" rev-parse HEAD)"
set +e
ok_out="$(git -C "$WT" push --porcelain --force-with-lease="refs/heads/task-30:${TASK_OLD}" \
  origin "HEAD:refs/heads/task-30" 2>&1)"
ok_rc=$?
set -e
expect_eq "同步时 update 退出 0" 0 "$ok_rc"
if [ "$ok_rc" != 0 ]; then printf '%s\n' "$ok_out" >&2; fi
expect_eq "同步时 GitHub 收到新 tip" "$WANT" "$(git --git-dir="$GH" rev-parse refs/heads/task-30)"
expect_eq "同步时 staging 收到新 tip" "$WANT" "$(git --git-dir="$ST" rev-parse refs/heads/task-30)"

set +e
del_out="$(git -C "$WT" push --porcelain --force-with-lease="refs/heads/task-30:${WANT}" \
  origin ":refs/heads/task-30" 2>&1)"
del_rc=$?
set -e
expect_eq "同步时 delete 退出 0" 0 "$del_rc"
if [ "$del_rc" != 0 ]; then printf '%s\n' "$del_out" >&2; fi
expect_true "同步时 GitHub 上 task-30 已删除" \
  '! git --git-dir="$GH" show-ref --verify --quiet refs/heads/task-30'

# ── 接线：fetch=GitHub，push=staging，claim=fetch ──────────
IFS=$'\t' read -r GH ST WT < <(seed_old wire)
# 把 staging 放到 identity 目录，让 guard_wire 找得到。
IDENT="$(metrics_identity_dir)"
DEST="$XDG_STATE_HOME/${IDENT}/git-guard/staging.git"
mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST"
mv "$ST" "$DEST"
ST="$DEST"
git -C "$WT" remote set-url --push origin "$GH"
git -C "$WT" remote remove claim 2>/dev/null || true
# 主工作区（.git 目录）不接线
expect_eq "主工作区 guard_wire no-op" 0 "$(task_is_main_worktree "$WT"; echo $?)"
# seed clone 的 .git 是文件（worktree? no - git clone creates .git dir).
# git clone creates a directory .git, so task_is_main_worktree is true!
# Need a linked worktree for wire test.
git -C "$WT" worktree add -q -b wire-task "$TDIR/wire-linked" task-30 >/dev/null
LINK="$TDIR/wire-linked"
git -C "$LINK" remote set-url origin "$(git -C "$WT" remote get-url origin)"
git -C "$LINK" remote set-url --push origin "$GH"
set +e
wire_rc=0
guard_wire_worktree "$LINK" || wire_rc=$?
set -e
expect_eq "linked worktree wire 退出 0" 0 "$wire_rc"
expect_eq "wire 后 fetch 仍是 GitHub" "$(git -C "$LINK" remote get-url origin)" "$(git -C "$WT" remote get-url origin)"
expect_eq "wire 后 push 是 staging" "$ST" "$(git -C "$LINK" remote get-url --push origin)"
expect_eq "wire 后 claim 等于 fetch" "$(git -C "$LINK" remote get-url origin)" "$(git -C "$LINK" remote get-url claim)"

# 把 push 改回 GitHub 后 require_wired 失败
git -C "$LINK" remote set-url --push origin "$(git -C "$LINK" remote get-url origin)"
set +e
req_rc=0
guard_require_wired "$LINK" >/dev/null 2>&1 || req_rc=$?
set -e
expect_true "push 改回 GitHub 后 require_wired 非 0" '[ "$req_rc" != 0 ]'

# ── post-receive GitHub CAS 失败 → 客户端非 0 ──────────────
IFS=$'\t' read -r GH ST WT < <(seed_old casf)
TASK_OLD="$(git --git-dir="$ST" rev-parse refs/heads/task-30)"
THIEF_DIR="$TDIR/casf-thief"
rm -rf "$THIEF_DIR"
git clone -q "$GH" "$THIEF_DIR" >/dev/null 2>&1
git_cfg "$THIEF_DIR"
git -C "$THIEF_DIR" switch -q task-30
printf 'thief\n' >> "$THIEF_DIR/task.txt"
git -C "$THIEF_DIR" add task.txt
git -C "$THIEF_DIR" commit -qm 'docs(repo): fixture thief'
git -C "$THIEF_DIR" push -q origin "HEAD:refs/heads/thief-30" >/dev/null
THIEF_SHA="$(git --git-dir="$GH" rev-parse refs/heads/thief-30)"
printf '%s\n' "$THIEF_SHA" > "$TDIR/casf.thief"
cat > "$TDIR/casf-gh-rp" <<EOF
#!/usr/bin/env bash
dir="\${!#}"
git --git-dir="\$dir" update-ref refs/heads/task-30 "\$(cat "$TDIR/casf.thief")"
exec git receive-pack "\$@"
EOF
chmod 755 "$TDIR/casf-gh-rp"
git --git-dir="$ST" config remote.github.receivepack "$TDIR/casf-gh-rp"
printf 'mine\n' >> "$WT/task.txt"
git -C "$WT" add task.txt
git -C "$WT" commit -qm 'docs(repo): fixture mine'
WANT="$(git -C "$WT" rev-parse HEAD)"
set +e
casf_out="$(git -C "$WT" push --porcelain --force-with-lease="refs/heads/task-30:${TASK_OLD}" \
  origin "HEAD:refs/heads/task-30" 2>&1)"
casf_rc=$?
set -e
expect_true "post-receive CAS 失败客户端非 0" '[ "$casf_rc" != 0 ]'
expect_true "post-receive CAS 失败后客户端 tip 未进 GitHub" \
  '[ "$(git --git-dir="$GH" rev-parse refs/heads/task-30)" != "$WANT" ]'
expect_eq "post-receive CAS 失败后 staging 已收下" "$WANT" \
  "$(git --git-dir="$ST" rev-parse refs/heads/task-30)"

# ── 两 ref 一次 push，其中一个 stale → 客户端两个 tip 都不进 GitHub ──
IFS=$'\t' read -r GH ST WT < <(seed_old atom)
OLD_A="$(git --git-dir="$ST" rev-parse refs/heads/task-30)"
git --git-dir="$GH" update-ref refs/heads/task-31 "$OLD_A"
GIT_TERMINAL_PROMPT=0 git --git-dir="$ST" fetch -q github '+refs/heads/*:refs/heads/*' >/dev/null 2>&1
git -C "$WT" fetch -q origin >/dev/null 2>&1
THIEF_DIR="$TDIR/atom-thief"
rm -rf "$THIEF_DIR"
git clone -q "$GH" "$THIEF_DIR" >/dev/null 2>&1
git_cfg "$THIEF_DIR"
git -C "$THIEF_DIR" switch -q task-31
printf 'thief31\n' >> "$THIEF_DIR/task.txt"
git -C "$THIEF_DIR" add task.txt
git -C "$THIEF_DIR" commit -qm 'docs(repo): fixture thief31'
git -C "$THIEF_DIR" push -q origin "HEAD:refs/heads/thief-31" >/dev/null
printf '%s\n' "$(git --git-dir="$GH" rev-parse refs/heads/thief-31)" > "$TDIR/atom.thief"
cat > "$TDIR/atom-gh-rp" <<EOF
#!/usr/bin/env bash
dir="\${!#}"
git --git-dir="\$dir" update-ref refs/heads/task-31 "\$(cat "$TDIR/atom.thief")"
exec git receive-pack "\$@"
EOF
chmod 755 "$TDIR/atom-gh-rp"
git --git-dir="$ST" config remote.github.receivepack "$TDIR/atom-gh-rp"
git -C "$WT" switch -q task-30
printf 'A2\n' >> "$WT/task.txt"
git -C "$WT" add task.txt
git -C "$WT" commit -qm 'docs(repo): fixture A2'
WANT_A="$(git -C "$WT" rev-parse HEAD)"
git -C "$WT" switch -qc task-31 origin/task-31 >/dev/null
printf 'B2\n' >> "$WT/task.txt"
git -C "$WT" add task.txt
git -C "$WT" commit -qm 'docs(repo): fixture B2'
WANT_B="$(git -C "$WT" rev-parse HEAD)"
set +e
atom_out="$(git -C "$WT" push --porcelain \
  --force-with-lease="refs/heads/task-30:${OLD_A}" \
  --force-with-lease="refs/heads/task-31:${OLD_A}" \
  origin "task-30:refs/heads/task-30" "task-31:refs/heads/task-31" 2>&1)"
atom_rc=$?
set -e
expect_true "两 ref 中一个 stale 客户端非 0" '[ "$atom_rc" != 0 ]'
expect_eq "atomic：GitHub task-30 仍是 OLD" "$OLD_A" \
  "$(git --git-dir="$GH" rev-parse refs/heads/task-30)"
expect_true "atomic：GitHub task-31 不是客户端 B2" \
  '[ "$(git --git-dir="$GH" rev-parse refs/heads/task-31)" != "$WANT_B" ]'
expect_true "atomic：GitHub 未收下 A2" \
  '[ "$(git --git-dir="$GH" rev-parse refs/heads/task-30)" != "$WANT_A" ]'
if [ "$atom_rc" = 0 ]; then printf '%s\n' "$atom_out" >&2; fi

# ── A2：普通 shell 的 message / scope / snapshot 门禁 ────────
push_rejected() {
  local label="$1" reason="$2" ref="${3:-refs/heads/task-30}" out rc=0 before_gh before_st
  before_gh="$(git --git-dir="$GH" rev-parse "$ref")"
  before_st="$(git --git-dir="$ST" rev-parse "$ref")"
  out="$(git -C "$WT" push --porcelain origin "HEAD:$ref" 2>&1)" || rc=$?
  expect_true "$label 客户端非 0" '[ "$rc" != 0 ]'
  expect_true "$label 原因正确" 'printf "%s\n" "$out" | grep -Fq "$reason"'
  expect_eq "$label GitHub 不变" "$before_gh" "$(git --git-dir="$GH" rev-parse "$ref")"
  expect_eq "$label staging 不变" "$before_st" "$(git --git-dir="$ST" rev-parse "$ref")"
  if [ "$rc" = 0 ] || ! printf '%s\n' "$out" | grep -Fq "$reason"; then
    printf '%s\n' "$out" >&2
  fi
}

IFS=$'\t' read -r GH ST WT < <(seed_old a2main)
push_rejected 'HEAD:main' '不得 push main' refs/heads/main

IFS=$'\t' read -r GH ST WT < <(seed_old a2msg)
printf 'bad\n' >> "$WT/task.txt"
git -C "$WT" add task.txt
git -C "$WT" commit -qm 'bad message'
printf 'good\n' >> "$WT/task.txt"
git -C "$WT" add task.txt
git -C "$WT" commit -qm 'docs(repo): 后补合法标题'
push_rejected '历史 bad message' '非法提交信息'

IFS=$'\t' read -r GH ST WT < <(seed_old a2revert)
printf 'outside\n' > "$WT/outside.txt"
git -C "$WT" add outside.txt
git -C "$WT" commit -qm 'docs(repo): 新增越界文件'
git -C "$WT" revert --no-edit HEAD >/dev/null
push_rejected '越界后 revert' '越界 diff'

IFS=$'\t' read -r GH ST WT < <(seed_old a2rename)
git -C "$WT" mv task.txt outside.txt
git -C "$WT" commit -qm 'docs(repo): 重命名到范围外'
push_rejected 'rename 两端' '越界 diff'

IFS=$'\t' read -r GH ST WT < <(seed_old a2deny)
printf '\n' >> "$WT/0-meta/tasks/30/contract.json"
git -C "$WT" add 0-meta/tasks/30/contract.json
git -C "$WT" commit -qm 'docs(meta): 分支试图改契约'
push_rejected 'scope 包含 0-meta 仍禁契约' 'hard-deny'

IFS=$'\t' read -r GH ST WT < <(seed_old a2secret)
mkdir -p "$WT/1-code/app"
printf 'fixture placeholder\n' > "$WT/1-code/app/.env"
git -C "$WT" add 1-code/app/.env
git -C "$WT" commit -qm 'docs(code): 范围内敏感路径'
push_rejected 'scope 内 .env' 'hard-deny'

IFS=$'\t' read -r GH ST WT < <(seed_old a2policy)
# 分支自己允许 feat(repo)；判据必须仍读 snapshot 的 docs-only。
sed 's/git.commit.types.repo = docs/git.commit.types.repo = docs feat/' \
  "$WT/0-meta/derived.lock" > "$TDIR/a2policy.lock"
cp "$TDIR/a2policy.lock" "$WT/0-meta/derived.lock"
printf 'policy\n' >> "$WT/task.txt"
git -C "$WT" add task.txt 0-meta/derived.lock
git -C "$WT" commit -qm 'feat(repo): 分支扩大合法类型'
push_rejected '策略只读 snapshot' 'type 与 domain 不匹配'

IFS=$'\t' read -r GH ST WT < <(seed_old a2missing)
printf '999\n' > "$(git -C "$WT" rev-parse --absolute-git-dir)/new.task.issue"
printf 'missing\n' >> "$WT/task.txt"
git -C "$WT" add task.txt
git -C "$WT" commit -qm 'docs(repo): 未批准任务提交'
push_rejected 'snapshot 缺 contract' 'snapshot 没有已批准契约 #999'
printf 'invalid\n' > "$(git -C "$WT" rev-parse --absolute-git-dir)/new.task.issue"
push_rejected '无效 Binding' '缺少显式 Task Binding'

IFS=$'\t' read -r GH ST WT < <(seed_old a2unit)
mkdir -p "$WT/1-code/app"
printf 'unit\n' > "$WT/1-code/app/hello world.txt"
git -C "$WT" add 1-code/app
git -C "$WT" commit -qm 'feat(code.app): 合法新增单元'
WANT="$(git -C "$WT" rev-parse HEAD)"
unit_rc=0
unit_out="$(git -C "$WT" push --porcelain origin HEAD:refs/heads/code/arbitrary 2>&1)" || unit_rc=$?
expect_eq '显式 bind #30 无需分支名带号' 0 "$unit_rc"
expect_eq '合法新 unit 与空格路径转发 GitHub' "$WANT" \
  "$(git --git-dir="$GH" rev-parse refs/heads/code/arbitrary)"
if [ "$unit_rc" != 0 ]; then printf '%s\n' "$unit_out" >&2; fi
printf 'wip\n' >> "$WT/task.txt"
git -C "$WT" add task.txt
git -C "$WT" commit -qm 'wip: 合法阶段提交'
unit_rc=0
git -C "$WT" push --porcelain origin HEAD:refs/heads/code/arbitrary > "$TDIR/a2wip.out" 2>&1 || unit_rc=$?
expect_eq '短分支保留 policy 的 wip 例外' 0 "$unit_rc"
if [ "$unit_rc" != 0 ]; then cat "$TDIR/a2wip.out" >&2; fi

# ── R4：forwarding fail-closed、sync recovery 与安全 no-op ─────────
IFS=$'\t' read -r GH ST WT < <(seed_old recovery)
TASK_OLD="$(git --git-dir="$ST" rev-parse refs/heads/task-30)"
cat > "$TDIR/recovery-fail-rp" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod 755 "$TDIR/recovery-fail-rp"
git --git-dir="$ST" config remote.github.receivepack "$TDIR/recovery-fail-rp"
printf 'recovery\n' >> "$WT/task.txt"
git -C "$WT" add task.txt
git -C "$WT" commit -qm 'docs(repo): fixture recovery'
WANT="$(git -C "$WT" rev-parse HEAD)"
set +e
recovery_first_out="$(git -C "$WT" push --porcelain origin \
  'HEAD:refs/heads/task-30' 2>&1)"
recovery_first_rc=$?
set -e
expect_true 'forwarding 失败的第一次 push 非 0' '[ "$recovery_first_rc" != 0 ]'
expect_eq 'forwarding 失败后 staging 已更新' "$WANT" \
  "$(git --git-dir="$ST" rev-parse refs/heads/task-30)"
expect_eq 'forwarding 失败后 GitHub 仍为旧 tip' "$TASK_OLD" \
  "$(git --git-dir="$GH" rev-parse refs/heads/task-30)"

# 原样重复 push 不带客户端 lease；若 wrapper 把 Everything up-to-date 当成功，
# 这里会错误返回 0。必须等 guard sync 按原 plan/lease 恢复后才放行安全 no-op。
set +e
recovery_retry_out="$(git -C "$WT" push --porcelain origin \
  'HEAD:refs/heads/task-30' 2>&1)"
recovery_retry_rc=$?
set -e
expect_true 'forwarding 失败后原样重复 push 仍非 0' '[ "$recovery_retry_rc" != 0 ]'
expect_true '重复 push 提示 forwarding 状态未安全收敛' \
  'printf "%s\n" "$recovery_retry_out" | grep -Eq "forwarding status|forwarding 失败"'

# 将这个 fixture 放到 new guard sync 依据 origin 身份寻找的 state 路径，
# 用真实 cmd_guard_sync 验证失败 transaction 的原 lease recovery。
RECOVERY_DEST="$XDG_STATE_HOME/$(metrics_identity_dir)/git-guard/staging.git"
rm -rf "$RECOVERY_DEST"
mkdir -p "$(dirname "$RECOVERY_DEST")"
mv "$ST" "$RECOVERY_DEST"
ST="$RECOVERY_DEST"
git -C "$WT" remote set-url --push origin "$ST"
git -C "$WT" config remote.origin.receivepack "$ST/hooks/guard-receive-pack"
git --git-dir="$ST" config --unset remote.github.receivepack 2>/dev/null || true
set +e
recovery_sync_out="$(cmd_guard_sync 2>&1)"
recovery_sync_rc=$?
set -e
expect_eq 'new guard sync 恢复 forwarding' 0 "$recovery_sync_rc"
if [ "$recovery_sync_rc" != 0 ]; then printf '%s\n' "$recovery_sync_out" >&2; fi
expect_eq 'sync 后 GitHub 收到原 tip' "$WANT" \
  "$(git --git-dir="$GH" rev-parse refs/heads/task-30)"
set +e
recovery_after_sync_out="$(git -C "$WT" push --porcelain origin \
  'HEAD:refs/heads/task-30' 2>&1)"
recovery_after_sync_rc=$?
set -e
expect_eq 'sync 后干净重复 no-op 退出 0' 0 "$recovery_after_sync_rc"

# post-receive 被调用但未写 forward-status：不能被“没有 fail 文件”掩盖。
IFS=$'\t' read -r GH ST WT < <(seed_old nostatus)
cat > "$ST/hooks/post-receive" <<EOF
#!/usr/bin/env bash
printf '%s\\n' invoked > "$TDIR/nostatus.hook"
cat >/dev/null
exit 0
EOF
chmod 755 "$ST/hooks/post-receive"
printf 'nostatus\n' >> "$WT/task.txt"
git -C "$WT" add task.txt
git -C "$WT" commit -qm 'docs(repo): fixture missing forward status'
set +e
nostatus_out="$(git -C "$WT" push --porcelain origin \
  'HEAD:refs/heads/task-30' 2>&1)"
nostatus_rc=$?
set -e
expect_true 'post-receive 未写 forward-status 时客户端非 0' '[ "$nostatus_rc" != 0 ]'
expect_true 'post-receive 未写 status 的夹具确实执行' '[ -f "$TDIR/nostatus.hook" ]'
expect_true 'missing status 提示 fail-closed' \
  'printf "%s\n" "$nostatus_out" | grep -Fq "forwarding status"'

# ── A6：snapshot 后并发创建同名新 ref，zero-oid lease 必须拒绝 ──
IFS=$'\t' read -r GH ST WT < <(seed_old create-race)
RACE_OLD="$(git --git-dir="$ST" rev-parse refs/heads/task-30)"
printf 'race\n' >> "$WT/task.txt"
git -C "$WT" add task.txt
git -C "$WT" commit -qm 'docs(repo): fixture create race'
RACE_NEW="$(git -C "$WT" rev-parse HEAD)"
cat > "$ST/hooks/pre-receive" <<EOF
#!/usr/bin/env bash
set -euo pipefail
env -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES \
  -u GIT_QUARANTINE_PATH git --git-dir="$GH" update-ref refs/heads/race-30 "$RACE_OLD"
. "$ST/hooks/git-guard-lib.sh"
guard_pre_receive
EOF
chmod 755 "$ST/hooks/pre-receive"
set +e
create_race_out="$(git -C "$WT" push --porcelain origin \
  'HEAD:refs/heads/race-30' 2>&1)"
create_race_rc=$?
set -e
expect_true 'snapshot 后并发创建同名 ref 时客户端非 0' '[ "$create_race_rc" != 0 ]'
expect_eq 'zero-oid race 后 GitHub 保留新建者 tip' "$RACE_OLD" \
  "$(git --git-dir="$GH" rev-parse refs/heads/race-30)"
expect_eq 'zero-oid race 后 staging 已收下客户端 tip' "$RACE_NEW" \
  "$(git --git-dir="$ST" rev-parse refs/heads/race-30)"
RACE_TX=""
for tx in "$ST/git-guard/transactions"/*; do
  [ -d "$tx" ] || continue
  if [ -f "$tx/forward-plan" ] && grep -Fq 'refs/heads/race-30' "$tx/forward-plan"; then
    RACE_TX="$tx"
    break
  fi
done
expect_true 'zero-oid race 固化 forward plan' '[ -n "$RACE_TX" ]'
if [ -n "$RACE_TX" ]; then
  expect_true 'zero-oid race plan 保留显式不存在 lease' \
    'grep -Fq "$GUARD_ZERO" "$RACE_TX/forward-plan"'
fi

# ── 并发 receive：全局 receive.lock 串行，transaction/status 不串线 ──
IFS=$'\t' read -r GH ST WT < <(seed_old concurrent)
CONC_OLD="$(git --git-dir="$ST" rev-parse refs/heads/task-30)"
git --git-dir="$GH" update-ref refs/heads/task-a "$CONC_OLD"
git --git-dir="$GH" update-ref refs/heads/task-b "$CONC_OLD"
GIT_TERMINAL_PROMPT=0 git --git-dir="$ST" fetch -q github \
  '+refs/heads/*:refs/heads/*' >/dev/null 2>&1
CONC_A="$TDIR/concurrent-a"
CONC_B="$TDIR/concurrent-b"
git clone -q "$GH" "$CONC_A" >/dev/null 2>&1
git clone -q "$GH" "$CONC_B" >/dev/null 2>&1
git_cfg "$CONC_A"
git_cfg "$CONC_B"
git -C "$CONC_A" switch -q task-a
git -C "$CONC_B" switch -q task-b
printf '30\n' > "$(git -C "$CONC_A" rev-parse --absolute-git-dir)/new.task.issue"
printf '30\n' > "$(git -C "$CONC_B" rev-parse --absolute-git-dir)/new.task.issue"
git -C "$CONC_A" remote set-url --push origin "$ST"
git -C "$CONC_B" remote set-url --push origin "$ST"
git -C "$CONC_A" config remote.origin.receivepack "$ST/hooks/guard-receive-pack"
git -C "$CONC_B" config remote.origin.receivepack "$ST/hooks/guard-receive-pack"
printf 'A\n' >> "$CONC_A/task.txt"
git -C "$CONC_A" add task.txt
git -C "$CONC_A" commit -qm 'docs(repo): fixture concurrent A'
CONC_WANT_A="$(git -C "$CONC_A" rev-parse HEAD)"
printf 'B\n' >> "$CONC_B/task.txt"
git -C "$CONC_B" add task.txt
git -C "$CONC_B" commit -qm 'docs(repo): fixture concurrent B'
CONC_WANT_B="$(git -C "$CONC_B" rev-parse HEAD)"
CONC_LOG="$TDIR/concurrent.log"
cat > "$TDIR/concurrent-gh-rp" <<EOF
#!/usr/bin/env bash
printf 'start %s\\n' "\$\$" >> "$CONC_LOG"
sleep 1
printf 'end %s\\n' "\$\$" >> "$CONC_LOG"
exec git receive-pack "\$@"
EOF
chmod 755 "$TDIR/concurrent-gh-rp"
git --git-dir="$ST" config remote.github.receivepack "$TDIR/concurrent-gh-rp"
set +e
git -C "$CONC_A" push --porcelain origin 'HEAD:refs/heads/task-a' >"$TDIR/concurrent-a.out" 2>&1 &
CONC_PID_A=$!
git -C "$CONC_B" push --porcelain origin 'HEAD:refs/heads/task-b' >"$TDIR/concurrent-b.out" 2>&1 &
CONC_PID_B=$!
wait "$CONC_PID_A"
CONC_RC_A=$?
wait "$CONC_PID_B"
CONC_RC_B=$?
set -e
expect_eq '并发 receive A 退出 0' 0 "$CONC_RC_A"
expect_eq '并发 receive B 退出 0' 0 "$CONC_RC_B"
expect_eq '并发 receive A 到达 GitHub' "$CONC_WANT_A" \
  "$(git --git-dir="$GH" rev-parse refs/heads/task-a)"
expect_eq '并发 receive B 到达 GitHub' "$CONC_WANT_B" \
  "$(git --git-dir="$GH" rev-parse refs/heads/task-b)"
expect_eq '并发 receive A 到达 staging' "$CONC_WANT_A" \
  "$(git --git-dir="$ST" rev-parse refs/heads/task-a)"
expect_eq '并发 receive B 到达 staging' "$CONC_WANT_B" \
  "$(git --git-dir="$ST" rev-parse refs/heads/task-b)"
mapfile -t CONC_LOG_LINES < "$CONC_LOG"
expect_eq '并发 forwarding 日志恰有两个 transaction' 4 "${#CONC_LOG_LINES[@]}"
if [ "${#CONC_LOG_LINES[@]}" -eq 4 ]; then
  CONC_START_A="${CONC_LOG_LINES[0]#start }"
  CONC_END_A="${CONC_LOG_LINES[1]#end }"
  CONC_START_B="${CONC_LOG_LINES[2]#start }"
  CONC_END_B="${CONC_LOG_LINES[3]#end }"
  expect_eq '并发 forwarding 第一个 transaction 成对' "$CONC_START_A" "$CONC_END_A"
  expect_eq '并发 forwarding 第二个 transaction 成对' "$CONC_START_B" "$CONC_END_B"
  expect_true '并发 forwarding 是两个 transaction' '[ "$CONC_START_A" != "$CONC_START_B" ]'
fi
CONC_TX_A=""
CONC_TX_B=""
for tx in "$ST/git-guard/transactions"/*; do
  [ -d "$tx" ] || continue
  if [ -f "$tx/incoming" ] && grep -Fq 'refs/heads/task-a' "$tx/incoming"; then CONC_TX_A="$tx"; fi
  if [ -f "$tx/incoming" ] && grep -Fq 'refs/heads/task-b' "$tx/incoming"; then CONC_TX_B="$tx"; fi
done
expect_true '并发 transaction A 有独立 incoming/status' \
  '[ -n "$CONC_TX_A" ] && [ "$(cat "$CONC_TX_A/forward-status")" = ok ]'
expect_true '并发 transaction B 有独立 incoming/status' \
  '[ -n "$CONC_TX_B" ] && [ "$(cat "$CONC_TX_B/forward-status")" = ok ]'
if [ -n "$CONC_TX_A" ] && [ -n "$CONC_TX_B" ]; then
  expect_true '并发 transaction A 未串入 B' \
    '! grep -Fq "refs/heads/task-b" "$CONC_TX_A/incoming"'
  expect_true '并发 transaction B 未串入 A' \
    '! grep -Fq "refs/heads/task-a" "$CONC_TX_B/incoming"'
fi

# ── A4/A5：new worktree 与纯 git worktree add + bind 接线矩阵 ──
IFS=$'\t' read -r GH ST WT < <(seed_old matrix)
MROOT="$WT"
MSEED="$TDIR/matrix-main"
git clone -q "$GH" "$MSEED" >/dev/null 2>&1
git_cfg "$MSEED"
git -C "$MSEED" switch -q main
mkdir -p "$MSEED/.agents"
printf 'fixture\n' > "$MSEED/.agents/README"
git -C "$MSEED" add .agents
git -C "$MSEED" commit -qm 'docs(repo): fixture worktree marker'
git -C "$MSEED" push -q origin main
git -C "$MROOT" fetch -q origin main
git -C "$MROOT" branch -f main "$(git --git-dir="$GH" rev-parse refs/heads/main)"
GIT_TERMINAL_PROMPT=0 git --git-dir="$ST" fetch -q github \
  '+refs/heads/*:refs/heads/*' >/dev/null 2>&1
MDEST="$XDG_STATE_HOME/$(metrics_identity_dir)/git-guard/staging.git"
rm -rf "$MDEST"
mkdir -p "$(dirname "$MDEST")"
mv "$ST" "$MDEST"
ST="$MDEST"
git -C "$MROOT" remote set-url --push origin "$GH"
git -C "$MROOT" config remote.origin.receivepack "$ST/hooks/guard-receive-pack"
MLOCK="$TDIR/matrix-derived.lock"
# Override equals this clone's origin nwo so metrics identity matches the
# staging dir computed above. Do not hardcode a host repo name.
override_nwo="$(task_repo_nwo "$ROOT")"
sed "s|^github\\.repo_override = *$|github.repo_override = ${override_nwo}|" \
  "$ROOT/0-meta/derived.lock" > "$MLOCK"
ROOT_SAVE="$ROOT"
LOCK_SAVE="$LOCK"
ROOT="$MROOT"
LOCK="$MLOCK"
MATRIX_WT_ROOT="$(worktree_root)"
cmd_worktree matrix-new --path 0-meta --from main >/dev/null
MNEW="$MATRIX_WT_ROOT/matrix-new"
ROOT="$MNEW"
LOCK="$MLOCK"
task_bind 30 >/dev/null
PURE="$TDIR/matrix-pure"
ROOT="$MROOT"
LOCK="$MLOCK"
git -C "$MROOT" worktree add -q -b matrix-pure "$PURE" main
ROOT="$PURE"
LOCK="$MLOCK"
task_bind 30 >/dev/null
for matrix_wt in "$MNEW" "$PURE"; do
  expect_eq "A4 fetch URL $(basename "$matrix_wt")" "$GH" \
    "$(git -C "$matrix_wt" remote get-url origin)"
  expect_eq "A4 push URL $(basename "$matrix_wt")" "$ST" \
    "$(git -C "$matrix_wt" remote get-url --push origin)"
  expect_eq "A4 claim URL $(basename "$matrix_wt")" "$GH" \
    "$(git -C "$matrix_wt" remote get-url claim)"
  expect_eq "A4 receivepack $(basename "$matrix_wt")" \
    "$ST/hooks/guard-receive-pack" \
    "$(git -C "$matrix_wt" config --get remote.origin.receivepack)"
  git -C "$matrix_wt" remote set-url --push origin "$GH"
  set +e
  matrix_req_rc=0
  guard_require_wired "$matrix_wt" >/dev/null 2>&1 || matrix_req_rc=$?
  set -e
  expect_true "A5 push 改回 GitHub 后 $(basename "$matrix_wt") fail-closed" \
    '[ "$matrix_req_rc" != 0 ]'
  git -C "$matrix_wt" remote set-url --push origin "$ST"
done
ROOT="$ROOT_SAVE"
LOCK="$LOCK_SAVE"

echo "guard.test.sh: 通过 ${pass}，失败 ${fail}"
[ "$fail" = 0 ]
