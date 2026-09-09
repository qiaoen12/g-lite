#!/usr/bin/env bash
# 定向检查：最新 main 门禁、rebase 成功/冲突、--force-with-lease。
# 在临时仓库里跑，不碰当前工作树，不调用 gh / orca，不跑全量 test。
set -Eeuo pipefail
export LC_COLLATE=C
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "✗ 不在 git 工作树" >&2; exit 1; }

lib="$ROOT/.agents/skills/z-lib.sh"
skill="$ROOT/.agents/skills/zsync/SKILL.md"
review_skill="$ROOT/.agents/skills/zreview/SKILL.md"
publish="$ROOT/.agents/skills/zreview/scripts/publish-review.sh"
flow="$ROOT/0-meta/templates/z-workflow.md"
sync="$ROOT/.agents/skills/zsync/scripts/sync-main.sh"
fail=0
tmp=

need() {
  local file="$1" pat="$2"
  if ! grep -Fq -- "$pat" "$file"; then
    echo "✗ $file 缺少：$pat" >&2
    fail=1
  fi
}

cleanup() {
  [ -n "${tmp:-}" ] && [ -d "$tmp" ] && rm -rf "$tmp"
}
trap cleanup EXIT

need "$lib" 'z_require_current_main'
need "$lib" 'z_main_is_current'
need "$lib" 'z_fetch_origin_main'
need "$lib" 'z_rebase_onto_current_main'
need "$lib" 'z_push_rebased_branch'
need "$lib" 'z_remote_branch_sha'
need "$lib" 'merge-base --is-ancestor'
need "$lib" 'z_require_remote_ancestor'
need "$lib" '--force-with-lease'
need "$sync" 'z_require_remote_ancestor'
need "$sync" 'z_require_dev_status'
need "$ROOT/0-meta/lib/new/claim.sh" 'derive_task_state'
need "$ROOT/0-meta/lib/new/claim.sh" 'refs/claims/'
need "$ROOT/0-meta/lib/new/claim.sh" '--porcelain'
need "$ROOT/0-meta/lib/new/claim.sh" '已被领取'
need "$ROOT/0-meta/lib/new/claim.sh" 'task_origin_fetch_url'
need "$ROOT/0-meta/lib/new/task.sh" 'claim.sh'
need "$ROOT/0-meta/lib/new/task.sh" 'task_review_sync_status'
need "$lib" 'main 已前进，请显式执行 zsync'
need "$lib" '如果同步导致 HEAD 改变，旧 Review 将失效，需重新 zreview'
need "$publish" 'z_require_current_main'
need "$review_skill" 'new z review'
if grep -Eq 'git merge-base|latest main|main 已前进|不得隐式调用|zsync' "$review_skill"; then
  echo "✗ zreview Skill 不得复制 latest-main 或 sync 算法" >&2
  fail=1
fi
need "$ROOT/.agents/skills/zpr/scripts/open-pr.sh" 'z_require_current_main'
need "$skill" 'disable-model-invocation: true'
need "$skill" 'user-invocable: true'
need "$skill" 'git rebase origin/main'
need "$skill" '--force-with-lease'
need "$skill" '不自动执行 `zreview` 或 `zmerge`'
need "$flow" '`zsync`'
need "$flow" 'z_require_current_main'
need "$flow" 'main 已前进，请显式执行 `zsync`'
need "$sync" 'z_rebase_onto_current_main'
need "$sync" 'z_push_rebased_branch'

if grep -Eq -- '(^|[[:space:]])--force([[:space:]]|$)' "$lib" "$sync"; then
  echo "✗ 同步实现含裸 --force" >&2
  fail=1
fi
if grep -Eq -- '-X ours|-X theirs' "$lib" "$sync" "$skill"; then
  echo "✗ 同步实现含自动 -X ours/-X theirs" >&2
  fail=1
fi
if grep -q "Merge branch 'main'" "$sync"; then
  echo "✗ sync-main.sh 不应制造 merge commit 文案作为成功路径" >&2
  fail=1
fi

# shellcheck source=/dev/null
. "$ROOT/0-meta/lib/new/core.sh"
# shellcheck source=/dev/null
. "$lib"

tmp="$(mktemp -d -t zsync-check.XXXXXX)"
origin="$tmp/origin.git"
work="$tmp/work"
other="$tmp/other"

git init --bare -b main "$origin" >/dev/null
git clone "$origin" "$work" >/dev/null 2>&1
git -C "$work" config user.email t@t
git -C "$work" config user.name t
git -C "$work" config commit.gpgsign false
git -C "$work" config core.hooksPath /dev/null

echo base > "$work/f.txt"
git -C "$work" add f.txt
git -C "$work" commit -m 'base' >/dev/null
git -C "$work" push -u origin main >/dev/null 2>&1
base="$(git -C "$work" rev-parse HEAD)"

git -C "$work" checkout -b task >/dev/null 2>&1
echo task > "$work/task.txt"
git -C "$work" add task.txt
git -C "$work" commit -m 'task' >/dev/null
task1="$(git -C "$work" rev-parse HEAD)"
git -C "$work" fetch origin >/dev/null 2>&1

# 相对 main 仍有提交，且 origin/main 是祖先 → 已最新
if ! z_main_is_current "$work" origin/main HEAD; then
  echo "✗ 领先 main 时应视为已包含最新 main" >&2
  fail=1
fi

# 推进 origin/main，与 task 仍有共同祖先，但不是 HEAD 祖先
git clone "$origin" "$other" >/dev/null 2>&1
git -C "$other" config user.email t@t
git -C "$other" config user.name t
git -C "$other" config commit.gpgsign false
git -C "$other" config core.hooksPath /dev/null
echo main2 > "$other/g.txt"
git -C "$other" add g.txt
git -C "$other" commit -m 'main2' >/dev/null
git -C "$other" push origin main >/dev/null 2>&1
git -C "$work" fetch origin >/dev/null 2>&1

if git -C "$work" merge-base HEAD origin/main >/dev/null \
   && z_main_is_current "$work" origin/main HEAD; then
  echo "✗ 有共同祖先但 main 已前进时不得视为已最新" >&2
  fail=1
fi
if z_main_is_current "$work" origin/main HEAD; then
  echo "✗ main 前进后 is-ancestor 应失败" >&2
  fail=1
fi

Z_WT="$work"
Z_MAIN=main
if ( z_require_current_main "$work" main ) >/dev/null 2>&1; then
  echo "✗ 落后 main 时 z_require_current_main 应硬失败" >&2
  fail=1
else
  err="$( ( z_require_current_main "$work" main ) 2>&1 || true)"
  case "$err" in
    *'main 已前进，请显式执行 zsync'*) ;;
    *) echo "✗ 落后提示不符：$err" >&2; fail=1 ;;
  esac
  now="$(git -C "$work" rev-parse HEAD)"
  [ "$now" = "$task1" ] || { echo "✗ 门禁失败后不得改 HEAD" >&2; fail=1; }
fi

# rebase 成功，不产生 merge commit
z_rebase_onto_current_main "$work" origin/main
if ! z_main_is_current "$work" origin/main HEAD; then
  echo "✗ rebase 后应包含最新 main" >&2
  fail=1
fi
if git -C "$work" rev-parse -q --verify MERGE_HEAD >/dev/null; then
  echo "✗ rebase 成功后不应留下 MERGE_HEAD" >&2
  fail=1
fi
parents="$(git -C "$work" rev-list --parents -n 1 HEAD | awk '{print NF-1}')"
if [ "$parents" -ne 1 ]; then
  echo "✗ rebase 不得制造 merge commit" >&2
  fail=1
fi

# 已最新：rebase 无副作用（HEAD 不变）
synced="$(git -C "$work" rev-parse HEAD)"
if ! z_main_is_current "$work" origin/main HEAD; then
  echo "✗ 同步后应已最新" >&2
  fail=1
fi
# 再 rebase 到同一点
z_rebase_onto_current_main "$work" origin/main
[ "$(git -C "$work" rev-parse HEAD)" = "$synced" ] \
  || { echo "✗ 已最新时 rebase 不应改变 HEAD" >&2; fail=1; }

# 冲突：同一文件两边改，abort 回原 HEAD
git -C "$work" checkout main >/dev/null 2>&1
git -C "$work" pull --ff-only origin main >/dev/null 2>&1
echo conflict-main > "$work/f.txt"
git -C "$work" add f.txt
git -C "$work" commit -m 'conflict-main' >/dev/null
git -C "$work" push origin main >/dev/null 2>&1
git -C "$work" checkout task >/dev/null 2>&1
echo conflict-task > "$work/f.txt"
git -C "$work" add f.txt
git -C "$work" commit -m 'conflict-task' >/dev/null
before_conflict="$(git -C "$work" rev-parse HEAD)"
git -C "$work" fetch origin >/dev/null 2>&1
if ( z_rebase_onto_current_main "$work" origin/main ) >/dev/null 2>&1; then
  echo "✗ 冲突 rebase 应失败" >&2
  fail=1
fi
[ "$(git -C "$work" rev-parse HEAD)" = "$before_conflict" ] \
  || { echo "✗ 冲突后 HEAD 应恢复" >&2; fail=1; }
if git -C "$work" rev-parse -q --verify REBASE_HEAD >/dev/null \
   || [ -d "$(git -C "$work" rev-parse --git-dir)/rebase-merge" ] \
   || [ -d "$(git -C "$work" rev-parse --git-dir)/rebase-apply" ]; then
  echo "✗ 冲突后仍处于 rebase 状态" >&2
  fail=1
fi

# --force-with-lease：必须用 rebase 前记下的 SHA。远端未变可推；远端已变则拒绝。
lease="$tmp/lease"
git clone "$origin" "$lease" >/dev/null 2>&1
git -C "$lease" config user.email t@t
git -C "$lease" config user.name t
git -C "$lease" config commit.gpgsign false
git -C "$lease" config core.hooksPath /dev/null
git -C "$lease" checkout -b lease-task >/dev/null 2>&1
echo lease > "$lease/lease.txt"
git -C "$lease" add lease.txt
git -C "$lease" commit -m 'lease-task' >/dev/null
git -C "$lease" push -u origin lease-task >/dev/null 2>&1
old_remote="$(z_remote_branch_sha "$lease" lease-task)"
echo lease2 >> "$lease/lease.txt"
git -C "$lease" add lease.txt
git -C "$lease" commit -m 'lease-local' >/dev/null
z_push_rebased_branch "$lease" lease-task "$old_remote"
after_ok="$(z_remote_branch_sha "$lease" lease-task)"
[ "$after_ok" = "$(git -C "$lease" rev-parse HEAD)" ] \
  || { echo "✗ 远端未变时 --force-with-lease 应能更新" >&2; fail=1; }

stale="$after_ok"
git clone "$origin" "$tmp/thief" >/dev/null 2>&1
git -C "$tmp/thief" config user.email t@t
git -C "$tmp/thief" config user.name t
git -C "$tmp/thief" config commit.gpgsign false
git -C "$tmp/thief" config core.hooksPath /dev/null
git -C "$tmp/thief" checkout lease-task >/dev/null 2>&1
echo stolen >> "$tmp/thief/lease.txt"
git -C "$tmp/thief" add lease.txt
git -C "$tmp/thief" commit -m 'stolen' >/dev/null
git -C "$tmp/thief" push origin lease-task >/dev/null 2>&1
echo lease3 >> "$lease/lease.txt"
git -C "$lease" add lease.txt
git -C "$lease" commit -m 'lease-again' >/dev/null
if ( z_push_rebased_branch "$lease" lease-task "$stale" ) >/dev/null 2>&1; then
  echo "✗ 远端已变时 --force-with-lease 应失败" >&2
  fail=1
fi
remote_now="$(git -C "$origin" rev-parse refs/heads/lease-task)"
stolen="$(git -C "$tmp/thief" rev-parse HEAD)"
[ "$remote_now" = "$stolen" ] || { echo "✗ 远端被 lease 拒绝后不应被覆盖" >&2; fail=1; }

# 无远端任务分支：不 push、不失败
git -C "$lease" checkout -b local-only >/dev/null 2>&1
z_push_rebased_branch "$lease" local-only "" >/dev/null
if git -C "$origin" show-ref --verify --quiet refs/heads/local-only; then
  echo "✗ 无远端分支时不应新建远端分支" >&2
  fail=1
fi

# A1 / A2 / A3：祖先检查 + lease 仍用同步前 SHA。
anc="$tmp/anc"
git clone "$origin" "$anc" >/dev/null 2>&1
git -C "$anc" config user.email t@t
git -C "$anc" config user.name t
git -C "$anc" config commit.gpgsign false
git -C "$anc" config core.hooksPath /dev/null
git -C "$anc" checkout -b anc-task >/dev/null 2>&1
echo a > "$anc/a.txt"
git -C "$anc" add a.txt
git -C "$anc" commit -m A >/dev/null
git -C "$anc" push -u origin anc-task >/dev/null 2>&1
echo b >> "$anc/a.txt"
git -C "$anc" add a.txt
git -C "$anc" commit -m B >/dev/null
git -C "$anc" push origin anc-task >/dev/null 2>&1
sha_b="$(git -C "$anc" rev-parse HEAD)"
echo c >> "$anc/a.txt"
git -C "$anc" add a.txt
git -C "$anc" commit -m C >/dev/null
before_c="$(git -C "$anc" rev-parse HEAD)"
# A1：远端 B 是本地 C 的祖先
if ! z_require_remote_ancestor "$anc" "$sha_b" "$before_c"; then
  echo "✗ A1 祖先关系成立时应放行 rebase" >&2
  fail=1
fi
z_push_rebased_branch "$anc" anc-task "$sha_b"
[ "$(z_remote_branch_sha "$anc" anc-task)" = "$before_c" ] \
  || { echo "✗ A1 祖先通过后应用同步前 SHA 的 lease 推送" >&2; fail=1; }

# A2：local=A-B-C，remote=A-B-X
thief="$tmp/anc-thief"
git clone "$origin" "$thief" >/dev/null 2>&1
git -C "$thief" config user.email t@t
git -C "$thief" config user.name t
git -C "$thief" config commit.gpgsign false
git -C "$thief" config core.hooksPath /dev/null
git -C "$thief" checkout anc-task >/dev/null 2>&1
# 回到 B：从 C 的 parent。当前 origin 已是 C。另开 diverged。
git -C "$thief" reset --hard "$sha_b" >/dev/null
echo x >> "$thief/a.txt"
git -C "$thief" add a.txt
git -C "$thief" commit -m X >/dev/null
git -C "$thief" push --force origin anc-task >/dev/null 2>&1
sha_x="$(git -C "$thief" rev-parse HEAD)"
git -C "$anc" fetch origin >/dev/null 2>&1
if ( z_require_remote_ancestor "$anc" "$sha_x" "$before_c" ) >/dev/null 2>&1; then
  echo "✗ A2 远端分叉时应 hard stop" >&2
  fail=1
fi
[ "$(git -C "$origin" rev-parse refs/heads/anc-task)" = "$sha_x" ] \
  || { echo "✗ A2 远端 X 应保持不变" >&2; fail=1; }

# A3：祖先通过后再改远端，lease 拒绝
git -C "$origin" update-ref refs/heads/anc-task "$before_c"
git -C "$anc" fetch origin >/dev/null 2>&1
lease_sha="$(z_remote_branch_sha "$anc" anc-task)"
[ "$lease_sha" = "$before_c" ] || lease_sha="$before_c"
echo d >> "$anc/a.txt"
git -C "$anc" add a.txt
git -C "$anc" commit -m D >/dev/null
if ! z_require_remote_ancestor "$anc" "$lease_sha" "$(git -C "$anc" rev-parse HEAD^)"; then
  echo "✗ A3 祖先检查应仍通过" >&2
  fail=1
fi
git -C "$thief" fetch origin >/dev/null 2>&1
git -C "$thief" reset --hard "$before_c" >/dev/null
echo stolen >> "$thief/a.txt"
git -C "$thief" add a.txt
git -C "$thief" commit -m stolen2 >/dev/null
git -C "$thief" push --force origin anc-task >/dev/null 2>&1
stolen2="$(git -C "$thief" rev-parse HEAD)"
if ( z_push_rebased_branch "$anc" anc-task "$lease_sha" ) >/dev/null 2>&1; then
  echo "✗ A3 祖先通过后远端再变，lease 应拒绝" >&2
  fail=1
fi
[ "$(git -C "$origin" rev-parse refs/heads/anc-task)" = "$stolen2" ] \
  || { echo "✗ A3 远端不应被覆盖" >&2; fail=1; }

if [ "$fail" -ne 0 ]; then
  echo "✗ 最新 main / zsync 契约未通过" >&2
  exit 1
fi
echo "✓ 最新 main / zsync 契约通过"
