#!/usr/bin/env bash
# 定向检查：squash body 汇编与最新 main helper。不跑全量 test，不调用 gh / orca。
set -Eeuo pipefail
export LC_COLLATE=C
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "✗ 不在 git 工作树" >&2; exit 1; }

lib="$ROOT/.agents/skills/z-lib.sh"
merge="$ROOT/.agents/skills/zmerge/scripts/squash-merge.sh"
merge_lib="$ROOT/.agents/skills/zmerge/scripts/merge-lib.sh"
body_lib="$ROOT/.agents/skills/zmerge/scripts/squash-body.sh"
flow="$ROOT/0-meta/templates/z-workflow.md"
fail=0

need() {
  local file="$1" pat="$2"
  if ! grep -Fq -- "$pat" "$file"; then
    echo "✗ $file 缺少：$pat" >&2
    fail=1
  fi
}

[ -f "$lib" ] && [ -f "$merge" ] && [ -f "$merge_lib" ] && [ -f "$body_lib" ] && [ -f "$flow" ] \
  || { echo "✗ 规则文件缺失" >&2; exit 1; }

need "$lib" 'z_require_current_main'
need "$lib" 'z_fetch_origin_main'
need "$lib" 'z_main_is_current'
need "$lib" 'merge-base --is-ancestor'
need "$lib" '请显式执行 zsync'
need "$lib" '如果同步导致 HEAD 改变，旧 Review 将失效，需重新 zreview'
need "$merge_lib" 'TASK_STATUS_REVIEW'
if grep -Fq '不重复调用 new task review' "$merge" \
   || grep -Fq '不重复调用 new task review' "$merge_lib"; then
  echo "✗ zmerge 不应在 In review 时跳过 new task review" >&2
  fail=1
fi

need "$merge_lib" 'z_require_current_main'
need "$merge_lib" 'z_compose_squash_body'
need "$merge_lib" '--body-file'
need "$merge_lib" 'z_validate_squash_body'
need "$merge_lib" '结构化 body'

need "$flow" '背景'
need "$flow" '改动'
need "$flow" '验证'
need "$flow" '备注'
need "$flow" 'z_require_current_main'
need "$flow" 'Fixes #Issue号'
need "$flow" 'PR #号'

# shellcheck source=/dev/null
. "$ROOT/0-meta/lib/new/core.sh"
# shellcheck source=/dev/null
. "$ROOT/0-meta/lib/new/task.sh"
# shellcheck source=/dev/null
. "$body_lib"
# shellcheck source=/dev/null
. "$lib"

tmp="$(mktemp -d -t z-squash-body.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

issue="$tmp/issue.md"
ck="$tmp/ck.md"
review="$tmp/review.md"
pr="$tmp/pr.md"

cat > "$issue" <<'EOF'
## 背景

当前 squash merge 进入 main 的 commit body 信息过少，通常只剩 WIP 标题。

## 目标

把已有事实汇编成长期可读的主线提交说明。

## 允许改动范围

- `.agents/skills/zmerge/`
- `.agents/skills/z-lib.sh`

不得借此修改 `zreview` 审查标准。
EOF

cat > "$ck" <<'EOF'
<!-- new-task-checkpoint -->
## Checkpoint

| 项 | 值 |
| --- | --- |
| 工作树 | `/tmp/worktrees/meta-zmerge-commit-body` |
| HEAD | `abc123` |
| 下一步 | 等待 zreview |

### 验证证据

```
工作树 /tmp/worktrees/meta-zmerge-commit-body（sparse、非主工作区）
push origin meta/zmerge-commit-body @ abc123
HEAD abc123；工作区 干净
```
EOF

cat > "$review" <<'EOF'
<!-- new-task-review -->
## Review

| 项 | 值 |
| --- | --- |
| Verdict | 通过 |
| reviewed HEAD | `abc123abc123abc123abc123abc123abc123abc1` |
| 范围 | `.agents/skills/zmerge/` `.agents/skills/z-lib.sh` |
| Squash-Title | `feat(meta): 生成可追溯的 squash commit body` |

### 通过理由

squash-merge.sh 在 gh pr merge 前汇编背景/改动/验证/备注，并显式 --body-file。
不再把 WIP 标题当作主线说明。

### 证据

```
.agents/skills/zmerge/scripts/check-squash-body.sh
RC=0
git status --porcelain
```

### 最小充分审查

- 审查代码与调用点：squash-merge.sh、squash-body.sh、z-lib.sh
- 复用证据：无
- 新增验证：check-squash-body.sh
- 覆盖范围：body 汇编与 latest-main helper
- 未执行的大范围验证：全量 test/lint
- 剩余风险：规则靠已有评论文本，缺字段则写未记录
EOF

cat > "$pr" <<'EOF'
人工说明请保留。

<!-- new-task-pr -->
## 变更摘要

- wip: 解析 gh 失败时的 GraphQL 正文
- wip: 保留 required checks 失败原因

 .agents/skills/z-lib.sh | 64 +++++
 2 files changed, 53 insertions(+), 16 deletions(-)

## 验证证据

```
工作树 /tmp/worktrees/meta-z-required-checks-error
push origin meta/z-required-checks-error @ d38597d
```

Fixes #14
<!-- /new-task-pr -->
EOF

out="$tmp/body.txt"
z_compose_squash_body "$issue" "$ck" "$review" "$pr" 14 22 > "$out"
if ! z_validate_squash_body "$(cat "$out")" 14 22; then
  echo "✗ 合格夹具未通过 z_validate_squash_body" >&2
  fail=1
fi

if ! grep -qx '背景' "$out" || ! grep -qx '改动' "$out" \
   || ! grep -qx '验证' "$out" || ! grep -qx '备注' "$out"; then
  echo "✗ 缺少四段标题" >&2
  fail=1
fi
if ! grep -Fq 'commit body 信息过少' "$out"; then
  echo "✗ 背景未取自 Issue" >&2
  fail=1
fi
if ! grep -Fq '汇编背景/改动/验证/备注' "$out"; then
  echo "✗ 改动未取自 Review 通过理由" >&2
  fail=1
fi
if grep -Fq 'wip: 解析 gh 失败时的 GraphQL 正文' "$out"; then
  echo "✗ 改动段复制了 WIP 标题" >&2
  fail=1
fi
if grep -Eq '/Users/|/tmp/|push origin ' "$out"; then
  echo "✗ body 含临时路径或 push 日志" >&2
  echo "$out" >&2
  fail=1
fi
if ! grep -Fq -- '- 实际运行：' "$out" || ! grep -Fq 'check-squash-body.sh' "$out"; then
  echo "✗ 验证段缺少实际运行" >&2
  fail=1
fi
if ! grep -Fq '全量 test/lint' "$out"; then
  echo "✗ 验证段未记录未执行的大范围验证" >&2
  fail=1
fi
if ! grep -Fq -- '- Fixes #14' "$out" || ! grep -Fq -- '- PR #22' "$out"; then
  echo "✗ 备注缺少 Fixes/PR" >&2
  fail=1
fi
if grep -Fq '。- 剩余风险' "$out"; then
  echo "✗ 备注把剩余风险拼到上一行了" >&2
  fail=1
fi
if ! grep -Eq '不得借此修改' "$out"; then
  echo "✗ 备注未保留允许范围中的边界说明" >&2
  fail=1
fi
if ! awk '$0=="备注"{p=1;next} p && /^- 剩余风险：/{found=1} END{exit found?0:1}' "$out"; then
  echo "✗ 备注应将剩余风险写成独立条目" >&2
  fail=1
fi

empty_review="$tmp/review-empty.md"
cat > "$empty_review" <<'EOF'
<!-- new-task-review -->
## Review

| 项 | 值 |
| --- | --- |
| Verdict | 通过 |
| reviewed HEAD | `abc` |
| 范围 | `.agents/skills/zmerge/` |
| Squash-Title | `feat(meta): x` |
EOF
empty_ck="$tmp/ck-empty.md"
: > "$empty_ck"
empty_pr="$tmp/pr-wip.md"
cat > "$empty_pr" <<'EOF'
<!-- new-task-pr -->
## 变更摘要

- wip: 只剩这条

 1 file changed, 1 insertion(+)
<!-- /new-task-pr -->
EOF
out2="$tmp/body-missing.txt"
if z_compose_squash_body "$issue" "$empty_ck" "$empty_review" "$empty_pr" 14 22 > "$out2"; then
  echo "✗ 缺必要上游时不得成功汇编 squash body" >&2
  fail=1
else
  :
fi
Z_SQUASH_STRICT=0
z_compose_squash_body "$issue" "$empty_ck" "$empty_review" "$empty_pr" 14 22 > "$out2" || true
if ! grep -Fq -- '- 未记录' "$out2"; then
  echo "✗ 非严格模式缺事实时应写未记录" >&2
  fail=1
fi
Z_SQUASH_STRICT=1
if grep -Fq 'wip: 只剩这条' "$out2"; then
  echo "✗ 只有 WIP 标题时仍写入了改动段" >&2
  fail=1
fi
chg="$(awk '$0=="改动"{p=1;next} p&&($0=="验证"||$0=="备注"){exit} p' "$out2")"
if ! printf '%s\n' "$chg" | grep -Fq '未记录'; then
  echo "✗ 改动段在只有 WIP 时应为未记录" >&2
  fail=1
fi
if ! grep -Fq -- '- 未执行的大范围验证：未记录' "$out2"; then
  echo "✗ 缺「未执行的大范围验证」时应写未记录，不得猜测" >&2
  fail=1
fi
if ! grep -Fq -- '- 剩余风险：未记录' "$out2"; then
  echo "✗ 缺剩余风险时应写未记录，不得猜测" >&2
  fail=1
fi
if z_validate_squash_body "$(cat "$out2")" 14 22; then
  echo "✗ 含未记录的 body 在严格模式下不得放行" >&2
  fail=1
fi
Z_SQUASH_STRICT=0
if ! z_validate_squash_body "$(cat "$out2")" 14 22; then
  echo "✗ 非严格模式显式未记录仍应能过结构校验" >&2
  fail=1
fi
Z_SQUASH_STRICT=1

bad="$tmp/bad.txt"
printf '%s\n' "背景" "- x" "" "改动" "- wip: only" "" "验证" "- y" "" "备注" "- Fixes #14" "- PR #22" > "$bad"
if z_validate_squash_body "$(cat "$bad")" 14 22; then
  echo "✗ 改动段只有 WIP 标题应拒绝" >&2
  fail=1
fi

noisy="$tmp/noisy.txt"
printf '%s\n' "背景" "- x" "" "改动" "- did thing" "" "验证" "- y" "" "备注" "- Fixes #14" "- PR #22" "- /Users/qiaoen/wt" > "$noisy"
if z_validate_squash_body "$(cat "$noisy")" 14 22; then
  echo "✗ 含 worktree 路径的 body 应拒绝" >&2
  fail=1
fi

# 最新 main helper：祖先则过，main 前进则停且不改 HEAD。
origin="$tmp/origin.git"
wt="$tmp/wt"
other="$tmp/other"
mkdir "$wt"
git init -q -b main "$wt"
git -C "$wt" config user.email t@example.com
git -C "$wt" config user.name t
git -C "$wt" config core.hooksPath /dev/null
printf 'a\n' > "$wt/f"
git -C "$wt" add f
git -C "$wt" commit -qm 'init'
git init --bare -q "$origin"
git --git-dir="$origin" symbolic-ref HEAD refs/heads/main >/dev/null
git -C "$wt" remote add origin "$origin"
git -C "$wt" push -q origin main
git -C "$wt" checkout -qb task
printf 'b\n' >> "$wt/f"
git -C "$wt" add f
git -C "$wt" commit -qm 'task'
Z_WT="$wt"
Z_MAIN=main
Z_HEAD="$(git -C "$wt" rev-parse HEAD)"
head_before="$Z_HEAD"
if ! z_require_current_main; then
  echo "✗ 已包含 origin/main 时应通过" >&2
  fail=1
fi
[ "$(git -C "$wt" rev-parse HEAD)" = "$head_before" ] \
  || { echo "✗ helper 通过时改了 HEAD" >&2; fail=1; }

git clone -q "$origin" "$other"
git -C "$other" config user.email t@example.com
git -C "$other" config user.name t
git -C "$other" config core.hooksPath /dev/null
printf 'c\n' >> "$other/f"
git -C "$other" add f
git -C "$other" commit -qm 'main moved'
git -C "$other" push -q origin main
if err="$(z_require_current_main 2>&1)"; then
  echo "✗ main 前进时应硬停" >&2
  fail=1
else
  printf '%s' "$err" | grep -Fq '请显式执行 zsync' \
    || { echo "✗ 落后时应提示 zsync：$err" >&2; fail=1; }
fi
[ "$(git -C "$wt" rev-parse HEAD)" = "$head_before" ] \
  || { echo "✗ helper 失败时改了 HEAD" >&2; fail=1; }
if git -C "$wt" merge-base --is-ancestor origin/main "$head_before"; then
  echo "✗ 测试夹具未让 main 前进" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "✗ squash body / latest-main 契约未通过" >&2
  exit 1
fi
echo "✓ squash body / latest-main 契约通过"
