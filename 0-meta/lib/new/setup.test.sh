#!/usr/bin/env bash
# fresh clone 上 new setup 不要求 Orca / 固定绝对路径；shim 从 PWD 解析工作区。
set -Eeuo pipefail
export LC_COLLATE=C
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/0-meta/lib/new/core.sh"
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

TDIR=""
tmp_mkd TDIR setup-runtime
export XDG_STATE_HOME="$TDIR/state"
SEED=""
rt_cleanup() {
  local p
  [ -n "${SEED:-}" ] && [ -d "$SEED/clone" ] || return 0
  git -C "$SEED/clone" worktree list --porcelain 2>/dev/null \
    | awk '/^worktree /{print $2}' | while read -r p; do
      [ "$p" = "$SEED/clone" ] && continue
      git -C "$SEED/clone" worktree remove --force "$p" >/dev/null 2>&1 || true
    done
}

git_cfg() {
  git -C "$1" config user.email t@t
  git -C "$1" config user.name t
  git -C "$1" config commit.gpgsign false
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

# ── 静态 ──────────────────────────────────────────────────────────────
expect_true "shim 不把 \$HOME/Projects2 当默认 fallback" \
  '! grep -Fq "PROJECTS2_ROOT:-\$HOME/Projects2" "$ROOT/0-meta/templates/new-shim.sh"'
expect_true "shim 不写死 /Users/qiaoen/Projects2" \
  '! grep -Fq "/Users/qiaoen/Projects2" "$ROOT/0-meta/templates/new-shim.sh"'
expect_true "setup 核心不要求 orca" \
  '! grep -E "^[[:space:]]*for t in .* orca" "$ROOT/0-meta/lib/new/setup.sh"'
expect_true "setup 缺 2-infra 不 fail" \
  '! grep -Fq "缺 install-unattended-password.sh" "$ROOT/0-meta/lib/new/setup.sh"'
expect_true "setup 声明不要求 Orca" \
  'grep -Fq "不要求 Orca" "$ROOT/0-meta/lib/new/setup.sh"'
expect_true "setup 缺 .aiignore/.claude 不 fail=1" \
  '! grep -A8 "for f in .aiignore .claude/settings.json" "$ROOT/0-meta/lib/new/setup.sh" | grep -q fail=1'
expect_true "入口不再提供 new task" \
  '! grep -Eq "^[[:space:]]+task\\)" "$ROOT/0-meta/bin/new"'
expect_true "入口不再提供 new z" \
  '! grep -Eq "^[[:space:]]+z\\)" "$ROOT/0-meta/bin/new"'

# ── 夹具：另一路径的 fresh clone，无 2-infra，无 orca ────────────────
SEED="$TDIR/fresh"
mkdir -p "$SEED"
git init --bare -b main "$SEED/origin.git" >/dev/null
git clone "$SEED/origin.git" "$SEED/clone" >/dev/null 2>&1
git_cfg "$SEED/clone"
mkdir -p "$SEED/clone/0-meta/bin" "$SEED/clone/0-meta/lib" "$SEED/clone/0-meta/templates"
cp "$ROOT/0-meta/policy.yaml" "$SEED/clone/0-meta/"
cp "$ROOT/0-meta/derived.lock" "$SEED/clone/0-meta/"
cp "$ROOT/0-meta/bin/new" "$SEED/clone/0-meta/bin/"
chmod +x "$SEED/clone/0-meta/bin/new"
cp -R "$ROOT/0-meta/lib/new" "$SEED/clone/0-meta/lib/"
cp "$ROOT/0-meta/templates/new-shim.sh" "$SEED/clone/0-meta/templates/"
cp "$ROOT/.pre-commit-config.yaml" "$SEED/clone/"
printf 'base\n' > "$SEED/clone/README.md"
git -C "$SEED/clone" add -A
git -C "$SEED/clone" commit -m seed >/dev/null
git -C "$SEED/clone" push -u origin main >/dev/null 2>&1

expect_true "夹具路径不是 /Users/qiaoen/Projects2" \
  '[[ "$SEED/clone" != /Users/qiaoen/Projects2 ]]'
expect_true "夹具没有 2-infra" '[ ! -e "$SEED/clone/2-infra" ]'
expect_true "夹具没有 .aiignore" '[ ! -e "$SEED/clone/.aiignore" ]'
expect_true "夹具没有 .claude/settings.json" '[ ! -e "$SEED/clone/.claude/settings.json" ]'

MOCK="$TDIR/mockbin"
mkdir -p "$MOCK" "$TDIR/home"
cat > "$MOCK/gh" <<'EOF'
#!/bin/bash
echo "unexpected gh $*" >&2
exit 1
EOF
cat > "$MOCK/pre-commit" <<'EOF'
#!/bin/bash
if [ "$1" = install ]; then
  gd="$(git rev-parse --git-common-dir)"
  mkdir -p "$gd/hooks"
  printf '#!/bin/sh\nexit 0\n' > "$gd/hooks/pre-commit"
  printf '#!/bin/sh\nexit 0\n' > "$gd/hooks/commit-msg"
  chmod +x "$gd/hooks/pre-commit" "$gd/hooks/commit-msg"
  exit 0
fi
exit 0
EOF
cat > "$MOCK/gitleaks" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$MOCK/gh" "$MOCK/pre-commit" "$MOCK/gitleaks"
CLEAN_PATH="$MOCK:$(path_without_orca)"
expect_true "PATH 看不到 orca" '! env PATH="$CLEAN_PATH" command -v orca >/dev/null'

run_new() {
  local wt="$1"; shift
  env -u NEW_WORKSPACE_ROOT -u PROJECTS2_ROOT \
    PATH="$CLEAN_PATH" HOME="$TDIR/home" XDG_STATE_HOME="$TDIR/state" \
    GIT_TERMINAL_PROMPT=0 \
    "$wt/0-meta/bin/new" "$@"
}

run_shim() {
  env -u NEW_WORKSPACE_ROOT -u PROJECTS2_ROOT \
    PATH="$CLEAN_PATH" HOME="$TDIR/home" XDG_STATE_HOME="$TDIR/state" \
    GIT_TERMINAL_PROMPT=0 \
    "$TDIR/home/.local/bin/new" "$@"
}

set +e
setup_out="$(cd "$SEED/clone" && run_new "$SEED/clone" setup 2>&1)"
setup_rc=$?
set -e
expect_eq "fresh clone new setup 退出 0" 0 "$setup_rc"
if [ "$setup_rc" != 0 ]; then printf '%s\n' "$setup_out" >&2; fi
expect_true "setup 不要求 orca" \
  'printf "%s\n" "$setup_out" | grep -Fq "不要求"'
expect_true "setup 装了 shim" '[ -x "$TDIR/home/.local/bin/new" ]'
expect_true "shim 来自模板" \
  'cmp -s "$SEED/clone/0-meta/templates/new-shim.sh" "$TDIR/home/.local/bin/new"'
expect_true "无 2-infra 时 setup 仍成功" \
  'printf "%s\n" "$setup_out" | grep -Fq "无冷备脚本" || printf "%s\n" "$setup_out" | grep -Fq "跳过 launchd"'
expect_true "setup 缺 .aiignore 只 warning" \
  'printf "%s\n" "$setup_out" | grep -Fq "缺 .aiignore"'
expect_true "setup 缺 .claude/settings.json 只 warning" \
  'printf "%s\n" "$setup_out" | grep -Fq "缺 .claude/settings.json"'

mkdir -p "$TDIR/home/Projects2/0-meta/bin" "$TDIR/outside"
cat > "$TDIR/home/Projects2/0-meta/bin/new" <<'EOF'
#!/bin/bash
echo DECOY_PROJECTS2
exit 0
EOF
chmod +x "$TDIR/home/Projects2/0-meta/bin/new"

git -C "$SEED/clone" worktree add -b meta/setup-full "$SEED/wt" >/dev/null 2>&1
set +e
help_out="$(cd "$SEED/wt" && run_shim help 2>&1)"
help_rc=$?
task_out="$(cd "$SEED/wt" && run_shim task 2>&1)"
task_rc=$?
z_out="$(cd "$SEED/wt" && run_shim z 2>&1)"
z_rc=$?
outside_out="$(cd "$TDIR/outside" && run_shim help 2>&1)"
outside_rc=$?
set -e
expect_eq "安装后 shim help 退出 0" 0 "$help_rc"
if [ "$help_rc" != 0 ]; then printf '%s\n' "$help_out" >&2; fi
expect_true "shim help 不含 new task" \
  '! printf "%s\n" "$help_out" | grep -Fq "new task"'
expect_true "shim help 不含 new z" \
  '! printf "%s\n" "$help_out" | grep -Fq "new z"'
expect_true "new task 已移除" \
  'printf "%s\n" "$task_out" | grep -Fq "未知类型"'
expect_true "new z 已移除" \
  'printf "%s\n" "$z_out" | grep -Fq "未知类型"'
expect_eq "未知类型退出 1" 1 "$task_rc"
expect_eq "未知类型 z 退出 1" 1 "$z_rc"
expect_true "worktree 里 shim 不落到 ~/Projects2" \
  '! printf "%s\n" "$help_out$task_out$z_out" | grep -Fq "DECOY_PROJECTS2"'
expect_eq "非 clone 目录 shim 退出 127" 127 "$outside_rc"
expect_true "非 clone 不落到 ~/Projects2" \
  '! printf "%s\n" "$outside_out" | grep -Fq "DECOY_PROJECTS2"'
expect_true "非 clone 提示不属于工作区" \
  'printf "%s\n" "$outside_out" | grep -Fq "不属于任何工作区"'

echo "setup.test.sh: 通过 ${pass}，失败 ${fail}"
[ "$fail" = 0 ]
