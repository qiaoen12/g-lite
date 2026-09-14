#!/usr/bin/env bash
# Issue #14 定向夹具：R1 transport 隔离、R2 v1.0 legacy wiring 恢复、
# R3 staging stale 的 Guard-aware scoped refresh。
set -Eeuo pipefail
export LC_COLLATE=C
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "✗ 不在 git 工作树" >&2; exit 1; }
. "$ROOT/0-meta/lib/new/core.sh"
. "$ROOT/0-meta/lib/new/worktree.sh"
. "$ROOT/0-meta/lib/new/task.sh"
. "$ROOT/0-meta/lib/new/guard.sh"
trap tmp_cleanup EXIT

fail=0
pass=0
ok() { pass=$((pass + 1)); }
bad() { echo "✗ $*" >&2; fail=$((fail + 1)); }
expect_eq() {
  if [ "$2" = "$3" ]; then ok; else bad "$1: 期望 [$2] 实际 [$3]"; fi
}
expect_true() { if eval "$2"; then ok; else bad "$1"; fi; }
run_fail() {
  local __outvar="$1"; shift
  local out rc=0
  out="$("$@" 2>&1)" || rc=$?
  printf -v "$__outvar" '%s' "$out"
  [ "$rc" -ne 0 ]
}

TDIR=""
tmp_mkd TDIR guard-issue14
export HOME="$TDIR/home"
export XDG_STATE_HOME="$TDIR/state"
mkdir -p "$HOME"

git_cfg() {
  git -C "$1" config user.email t@t
  git -C "$1" config user.name t
  git -C "$1" config commit.gpgsign false
  git -C "$1" config core.hooksPath /dev/null
}

# 每次调用建立一个真正的 linked-worktree 仓，返回值放入固定 globals，
# 使后面的 assertions 不依赖目录名或 remote 的偶然顺序。
make_repo() {
  local prefix="$1" root
  root="$TDIR/$prefix"
  R_ORIGIN="$root/origin.git"
  R_MAIN="$root/main"
  R_A="$root/task-a"
  R_B="$root/task-b"
  R_ST="$root/staging.git"
  mkdir -p "$root"
  git init -q --bare -b main "$R_ORIGIN"
  git clone -q "$R_ORIGIN" "$R_MAIN" >/dev/null 2>&1
  git_cfg "$R_MAIN"
  printf 'base\n' > "$R_MAIN/README"
  git -C "$R_MAIN" add README
  git -C "$R_MAIN" commit -qm 'fixture: base'
  git -C "$R_MAIN" push -q origin main
  git -C "$R_MAIN" worktree add -q -b "${prefix}-a" "$R_A" main
  git -C "$R_MAIN" worktree add -q -b "${prefix}-b" "$R_B" main
  git -C "$R_A" push -q origin "${prefix}-a"
  git -C "$R_B" push -q origin "${prefix}-b"
  git init -q --bare -b main "$R_ST"
}

install_stage_remote() {
  local stage="$1" origin="$2"
  guard_install_hooks "$stage" >/dev/null
  git --git-dir="$stage" config receive.denyNonFastForwards false
  git --git-dir="$stage" config receive.denyDeletes false
  git --git-dir="$stage" config git-guard.main main
  git --git-dir="$stage" remote add github "$origin"
  git --git-dir="$stage" fetch -q github '+refs/heads/*:refs/heads/*'
  git --git-dir="$stage" fetch -q github '+refs/heads/*:refs/guard/github/heads/*'
}

TEST_STAGING=""
guard_staging_git() { printf '%s\n' "$TEST_STAGING"; }

# ── R1：main + task A + task B，验证 Git 实际 effective values ─────────────
make_repo r1
TEST_STAGING="$R_ST"
guard_wire_worktree "$R_A"
guard_wire_worktree "$R_B"
COMMON="$(guard_common_config_file "$R_MAIN")"
A_CFG="$(guard_worktree_config_file "$R_A")"
B_CFG="$(guard_worktree_config_file "$R_B")"
expect_true 'R1 common config 存在' '[ -f "$COMMON" ]'
expect_true 'R1 A worktree config 存在' '[ -f "$A_CFG" ]'
expect_true 'R1 B worktree config 存在' '[ -f "$B_CFG" ]'
expect_eq 'R1 common 无 pushurl' '' "$(git config --file "$COMMON" --get-all remote.origin.pushurl 2>/dev/null || true)"
expect_eq 'R1 common 无 receivepack' '' "$(git config --file "$COMMON" --get-all remote.origin.receivepack 2>/dev/null || true)"
expect_eq 'R1 main effective push 仍是 origin' "$R_ORIGIN" "$(git -C "$R_MAIN" remote get-url --push origin)"
expect_eq 'R1 main effective receivepack 为空' '' "$(git -C "$R_MAIN" config --get-all remote.origin.receivepack 2>/dev/null || true)"
expect_eq 'R1 A effective push 是 staging' "$R_ST" "$(git -C "$R_A" remote get-url --push origin)"
expect_eq 'R1 B effective push 是 staging' "$R_ST" "$(git -C "$R_B" remote get-url --push origin)"
expect_eq 'R1 A effective receivepack 是 wrapper' "$R_ST/hooks/guard-receive-pack" \
  "$(git -C "$R_A" config --get-all remote.origin.receivepack)"
expect_eq 'R1 B effective receivepack 是 wrapper' "$R_ST/hooks/guard-receive-pack" \
  "$(git -C "$R_B" config --get-all remote.origin.receivepack)"
expect_true 'R1 A show-origin 指向 config.worktree' \
  'git -C "$R_A" config --show-origin --worktree --get remote.origin.pushurl | grep -Fq "$A_CFG"'
expect_true 'R1 B show-origin 指向 config.worktree' \
  'git -C "$R_B" config --show-origin --worktree --get remote.origin.receivepack | grep -Fq "$B_CFG"'
expect_true 'R1 claim remote 也在 A worktree-local' \
  'git -C "$R_A" config --show-origin --worktree --get remote.claim.url | grep -Fq "$A_CFG"'
expect_true 'R1 main guard require 是 no-op' 'guard_require_wired "$R_MAIN"'
expect_eq 'R1 main 未绑定 task' '' "$(task_bind_read "$R_MAIN")"
expect_true 'R1 main wire 是 no-op' 'guard_wire_worktree "$R_MAIN"'

A_PUSH_BEFORE="$(git -C "$R_A" remote get-url --push origin)"
B_PUSH_BEFORE="$(git -C "$R_B" remote get-url --push origin)"
B_RP_BEFORE="$(git -C "$R_B" config --get-all remote.origin.receivepack)"
git -C "$R_MAIN" worktree remove "$R_A"
git -C "$R_MAIN" worktree prune
expect_eq 'R1 删除/prune A 不改 main effective push' "$R_ORIGIN" "$(git -C "$R_MAIN" remote get-url --push origin)"
expect_eq 'R1 删除/prune A 不改 B push' "$B_PUSH_BEFORE" "$(git -C "$R_B" remote get-url --push origin)"
expect_eq 'R1 删除/prune A 不改 B receivepack' "$B_RP_BEFORE" "$(git -C "$R_B" config --get-all remote.origin.receivepack)"
expect_eq 'R1 A 删除前 push 确为 staging' "$R_ST" "$A_PUSH_BEFORE"
expect_true 'R1 删除/prune 后 main common 仍无 pushurl' \
  '! git config --file "$COMMON" --get-all remote.origin.pushurl >/dev/null 2>&1'

# finalize/清理剩余 task worktree 后，main 仍不依赖任何偶然 cleanup。
git -C "$R_MAIN" worktree remove "$R_B"
git -C "$R_MAIN" worktree prune
expect_eq 'R1 finalize 清理 B 后 main effective push 仍是 origin' "$R_ORIGIN" \
  "$(git -C "$R_MAIN" remote get-url --push origin)"
expect_true 'R1 finalize 清理 B 后 shared 仍无 Guard receivepack' \
  '! git config --file "$COMMON" --get-all remote.origin.receivepack >/dev/null 2>&1'

# 未绑定 task 的真正 Guard push 必须在 receive-pack 入口拒绝，不能因 transport
# 接线本身成功而变成可写路径。
make_repo r1-unbound
TEST_STAGING="$R_ST"
install_stage_remote "$R_ST" "$R_ORIGIN"
guard_wire_worktree "$R_A"
printf 'unbound\n' >> "$R_A/README"
git -C "$R_A" add README
git -C "$R_A" commit -qm 'fixture: unbound push'
set +e
UNBOUND_OUT="$(git -C "$R_A" push origin "HEAD:refs/heads/unbound" 2>&1)"
UNBOUND_RC=$?
set -e
expect_true 'R1 unbound Guard push 非 0' '[ "$UNBOUND_RC" -ne 0 ]'
expect_true 'R1 unbound 明确提示 binding' 'printf "%s\n" "$UNBOUND_OUT" | grep -Fq "缺少显式 Task Binding"'
expect_true 'R1 unbound 不写 GitHub ref' '! git --git-dir="$R_ORIGIN" show-ref --verify --quiet refs/heads/unbound'
expect_true 'R1 unbound 不写 staging ref' '! git --git-dir="$R_ST" show-ref --verify --quiet refs/heads/unbound'

# ── R2：从 v1.0.0 的历史 guard_wire 生成固定 legacy fixture ─────────────
make_repo r2
TEST_STAGING="$R_ST"
git show v1.0.0:0-meta/lib/new/guard.sh > "$TDIR/v1-guard.sh"
git show v1.0.0:0-meta/lib/new/claim.sh > "$TDIR/v1-claim.sh"
expect_true 'R2 fixture 来源是固定 v1.0.0' 'grep -Fq "git remote set-url --push origin" "$TDIR/v1-guard.sh"'
(
  . "$TDIR/v1-claim.sh"
  . "$TDIR/v1-guard.sh"
  guard_staging_git() { printf '%s\n' "$TEST_STAGING"; }
  guard_wire_worktree "$R_A"
)
COMMON="$(guard_common_config_file "$R_MAIN")"
expect_eq 'R2 legacy shared pushurl 已生成' "$R_ST" "$(git config --file "$COMMON" --get-all remote.origin.pushurl)"
expect_eq 'R2 legacy shared receivepack 已生成' "$R_ST/hooks/guard-receive-pack" \
  "$(git config --file "$COMMON" --get-all remote.origin.receivepack)"
expect_eq 'R2 legacy shared claim 已生成' "$R_ORIGIN" "$(git config --file "$COMMON" --get-all remote.claim.url)"
LEGACY_PUSH_BEFORE="$(git config --file "$COMMON" --get-all remote.origin.pushurl)"
set +e
R2_PREVIEW_OUT="$(guard_recover_legacy_wiring "$R_MAIN" preview 2>&1)"
R2_PREVIEW_RC=$?
set -e
expect_eq 'R2 preview 成功' 0 "$R2_PREVIEW_RC"
expect_true 'R2 preview 含 classification' 'printf "%s\n" "$R2_PREVIEW_OUT" | grep -Fq "classification   legacy"'
expect_eq 'R2 preview 不改 shared pushurl' "$LEGACY_PUSH_BEFORE" "$(git config --file "$COMMON" --get-all remote.origin.pushurl)"
guard_recover_legacy_wiring "$R_MAIN" apply >/dev/null
expect_true 'R2 apply 后 shared pushurl 消失' '! git config --file "$COMMON" --get-all remote.origin.pushurl >/dev/null 2>&1'
expect_true 'R2 apply 后 shared receivepack 消失' '! git config --file "$COMMON" --get-all remote.origin.receivepack >/dev/null 2>&1'
expect_true 'R2 apply 后 shared claim 消失' '! git config --file "$COMMON" --get-all remote.claim.url >/dev/null 2>&1'
expect_eq 'R2 apply 后 main effective push 回 origin' "$R_ORIGIN" "$(git -C "$R_MAIN" remote get-url --push origin)"
expect_eq 'R2 apply 后 main effective receivepack 为空' '' "$(git -C "$R_MAIN" config --get-all remote.origin.receivepack 2>/dev/null || true)"
R2_SECOND_OUT="$(guard_recover_legacy_wiring "$R_MAIN" apply 2>&1)"
expect_true 'R2 第二次 apply 是 no-op' 'printf "%s\n" "$R2_SECOND_OUT" | grep -Fq "no-op"'

CUSTOM_PUSH="$TDIR/custom-push.git"
git config --file "$COMMON" remote.origin.pushurl "$CUSTOM_PUSH"
CUSTOM_BEFORE="$(git config --file "$COMMON" --get-all remote.origin.pushurl)"
run_fail R2_CUSTOM_OUT guard_recover_legacy_wiring "$R_MAIN" apply
expect_true 'R2 custom transport fail-closed' 'printf "%s\n" "$R2_CUSTOM_OUT" | grep -Fq "用户自定义"'
expect_eq 'R2 custom transport 不被覆盖' "$CUSTOM_BEFORE" "$(git config --file "$COMMON" --get-all remote.origin.pushurl)"
git config --file "$COMMON" --add remote.origin.pushurl "$R_ST"
run_fail R2_AMBIG_OUT guard_recover_legacy_wiring "$R_MAIN" preview
expect_true 'R2 ambiguous config fail-closed' 'printf "%s\n" "$R2_AMBIG_OUT" | grep -Eq "混合|多值|ambiguous"'
expect_eq 'R2 ambiguous 两个值都保留' 2 "$(git config --file "$COMMON" --get-all remote.origin.pushurl | wc -l | tr -d ' ')"
git config --file "$COMMON" --unset-all remote.origin.pushurl

# ── R3：staging main 单向 stale，仅允许 scoped refresh ───────────────────
make_repo r3
TEST_STAGING="$R_ST"
install_stage_remote "$R_ST" "$R_ORIGIN"
R3_OLD="$(git --git-dir="$R_ST" rev-parse refs/heads/main)"
printf 'r3-new\n' >> "$R_MAIN/README"
git -C "$R_MAIN" add README
git -C "$R_MAIN" commit -qm 'fixture: advance main'
git -C "$R_MAIN" push -q origin main
R3_NEW="$(git --git-dir="$R_ORIGIN" rev-parse refs/heads/main)"
R3_TASK_BEFORE="$(git --git-dir="$R_ST" rev-parse refs/heads/r3-a)"
R3_RESULT="$(guard_refresh_staging_for_merge "$R_A" main)"
expect_eq 'R3 stale main scoped refresh' refreshed "$R3_RESULT"
expect_eq 'R3 refresh 后 staging main 是 snapshot' "$R3_NEW" "$(git --git-dir="$R_ST" rev-parse refs/heads/main)"
expect_eq 'R3 refresh 不改 task ref' "$R3_TASK_BEFORE" "$(git --git-dir="$R_ST" rev-parse refs/heads/r3-a)"
expect_eq 'R3 第二次 refresh no-op' noop "$(guard_refresh_staging_for_merge "$R_A" main)"

git --git-dir="$R_ST" update-ref refs/heads/main "$R3_OLD" "$R3_NEW"
TX_ROOT="$R_ST/git-guard/transactions"
mkdir -p "$TX_ROOT/pending"
printf 'pending\n' > "$TX_ROOT/pending/receive-status"
run_fail R3_PENDING_OUT guard_refresh_staging_for_merge "$R_A" main
expect_true 'R3 pending transaction fail-closed' 'printf "%s\n" "$R3_PENDING_OUT" | grep -Fq "transaction/lease"'
expect_eq 'R3 pending 不偷偷 refresh' "$R3_OLD" "$(git --git-dir="$R_ST" rev-parse refs/heads/main)"
rm -rf "$TX_ROOT/pending"

mkdir -p "$TX_ROOT/failed"
printf 'accepted\n' > "$TX_ROOT/failed/receive-status"
printf 'fail\n' > "$TX_ROOT/failed/forward-status"
run_fail R3_FAILED_OUT guard_refresh_staging_for_merge "$R_A" main
expect_true 'R3 failed transaction 不自动 replay' 'printf "%s\n" "$R3_FAILED_OUT" | grep -Fq "transaction/lease"'
rm -rf "$TX_ROOT/failed"

mkdir -p "$TX_ROOT/unknown"
run_fail R3_UNKNOWN_OUT guard_refresh_staging_for_merge "$R_A" main
expect_true 'R3 unknown transaction fail-closed' 'printf "%s\n" "$R3_UNKNOWN_OUT" | grep -Fq "transaction/lease"'
rm -rf "$TX_ROOT/unknown"

mkdir -p "$TX_ROOT/lease-ambiguous"
printf 'rejected\n' > "$TX_ROOT/lease-ambiguous/receive-status"
printf 'ambiguous\n' > "$TX_ROOT/lease-ambiguous/lease-status"
run_fail R3_LEASE_OUT guard_refresh_staging_for_merge "$R_A" main
expect_true 'R3 lease ambiguity fail-closed' 'printf "%s\n" "$R3_LEASE_OUT" | grep -Fq "transaction/lease"'
rm -rf "$TX_ROOT/lease-ambiguous"

git --git-dir="$R_ST" update-ref refs/heads/unrelated "$R3_OLD"
run_fail R3_UNRELATED_OUT guard_refresh_staging_for_merge "$R_A" main
expect_true 'R3 unrelated write 不 replay' 'printf "%s\n" "$R3_UNRELATED_OUT" | grep -Fq "unrelated staging refs"'
expect_eq 'R3 unrelated block 后 main 仍 stale' "$R3_OLD" "$(git --git-dir="$R_ST" rev-parse refs/heads/main)"
git --git-dir="$R_ST" update-ref -d refs/heads/unrelated

expect_eq 'R2 failure domain non-fast-forward' non-fast-forward \
  "$(guard_classify_push_failure "$R_MAIN" '! [rejected] (non-fast-forward)' 1)"
expect_eq 'R2 failure domain authentication' authentication \
  "$(guard_classify_push_failure "$R_MAIN" 'remote: Authentication failed' 1)"
expect_eq 'R2 failure domain network' network \
  "$(guard_classify_push_failure "$R_MAIN" 'Could not resolve host: github.com' 1)"
git config --file "$COMMON" remote.origin.pushurl "$R_ST"
expect_eq 'R2 failure domain Guard route' guard-route \
  "$(guard_classify_push_failure "$R_MAIN" 'git-guard: wrapper route failed' 1)"
expect_eq 'R2 failure domain staging stale' guard-staging \
  "$(guard_classify_push_failure "$R_MAIN" 'GitHub main 已前进，staging 未同步，拒绝使用陈旧 contract' 1)"
git config --file "$COMMON" --unset-all remote.origin.pushurl

echo "guard-issue14.test.sh: 通过 ${pass}，失败 ${fail}"
[ "$fail" = 0 ]
