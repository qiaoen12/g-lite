#!/usr/bin/env bash
# 定向检查：审查 adapter 委托 canonical CLI，共用同一份最小充分审查规则，发布门禁要求报告段。
# 不跑全量 test/lint，不调用 gh / orca。
set -Eeuo pipefail
export LC_COLLATE=C
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "✗ 不在 git 工作树" >&2; exit 1; }

skill="$ROOT/.agents/skills/zreview/SKILL.md"
rules="$ROOT/.agents/skills/zreview/verification.md"
flow="$ROOT/0-meta/templates/z-workflow.md"
lib="$ROOT/.agents/skills/z-lib.sh"
fail=0

need() {
  local file="$1" pat="$2"
  if ! grep -Fq "$pat" "$file"; then
    echo "✗ $file 缺少：$pat" >&2
    fail=1
  fi
}

[ -f "$skill" ] && [ -f "$rules" ] && [ -f "$flow" ] && [ -f "$lib" ] \
  || { echo "✗ 规则文件缺失" >&2; exit 1; }

need "$skill" 'verification.md'
need "$skill" '当前任务需要审查当前 HEAD'
need "$skill" 'new z review'
if grep -Eq 'git merge-base|latest main|main 已前进|zsync|zmerge' "$skill"; then
  echo "✗ zreview Skill 不得复制 latest-main 或 merge 算法" >&2
  fail=1
fi
need "$lib" 'z_require_current_main'

need "$rules" '最小充分审查'
need "$rules" '当前 Issue 验收要求'
need "$rules" '当前 HEAD 相对基线的实际 diff'
need "$rules" '直接受影响的函数、脚本和调用点'
need "$rules" '有状态远端流程'
need "$rules" '成功路径'
need "$rules" '共享 helper'
need "$rules" '调用点'
need "$rules" 'Checkpoint 中 `zdev` / `zfix`'
need "$rules" '同一代码状态'
need "$rules" '全仓库 test'
need "$rules" 'Verdict 不得写“通过”'
need "$rules" '不修改工作树、不 commit、不修代码'
need "$rules" '不改变 `zmerge` 的机械合并门禁'
need "$rules" '审查代码与调用点'
need "$rules" '复用证据'
need "$rules" '新增验证'
need "$rules" '覆盖范围'
need "$rules" '未执行的大范围验证'
need "$rules" '剩余风险'

need "$flow" '.agents/skills/zreview/verification.md'
need "$flow" '### 最小充分审查'
need "$flow" '### Contract 对照'
need "$flow" 'task-contract:v1'
need "$flow" '| Contract |'
need "$ROOT/0-meta/lib/new/contract.sh" 'contract_load_main'
need "$ROOT/0-meta/schema/task-contract.v1.yaml" 'task-contract/v1'
need "$flow" '审查代码与调用点'
need "$flow" '复用证据'
need "$flow" '新增验证'
need "$flow" '覆盖范围'
need "$flow" '未执行的大范围验证'
need "$flow" '剩余风险'
need "$flow" 'zmerge 合并前检查'
need "$flow" '所有 GitHub required checks 成功'
need "$flow" '有 `human-merge` 标签时 `zmerge` 拒绝'

need "$lib" 'z_require_review_min_report'
need "$lib" 'z_require_review_min_report "$body"'

# shellcheck source=/dev/null
. "$ROOT/0-meta/lib/new/core.sh"
# shellcheck source=/dev/null
. "$lib"

good="$(cat <<'EOF'
<!-- new-task-review -->
## Review

### 最小充分审查

- 审查代码与调用点：zreview/SKILL.md
- 复用证据：无既有定向检查
- 新增验证：check-min-review.sh
- 覆盖范围：规则入口与发布校验
- 未执行的大范围验证：全量 test/lint
- 剩余风险：规则靠 Agent 执行，脚本只核字段名
EOF
)"
z_require_review_min_report "$good"

bad_heading="$(cat <<'EOF'
<!-- new-task-review -->
## Review
- 审查代码与调用点：x
- 复用证据：x
- 新增验证：x
- 覆盖范围：x
- 未执行的大范围验证：x
- 剩余风险：x
EOF
)"
if ( z_require_review_min_report "$bad_heading" ) >/dev/null 2>&1; then
  echo "✗ 缺标题的 Review 应被拒绝" >&2
  fail=1
fi

bad_field="$(cat <<'EOF'
<!-- new-task-review -->
## Review

### 最小充分审查

- 审查代码与调用点：x
- 复用证据：x
- 新增验证：x
- 覆盖范围：x
- 剩余风险：x
EOF
)"
if ( z_require_review_min_report "$bad_field" ) >/dev/null 2>&1; then
  echo "✗ 缺「未执行的大范围验证」应被拒绝" >&2
  fail=1
fi

empty_val="$(cat <<'EOF'
<!-- new-task-review -->
## Review

### 最小充分审查

- 审查代码与调用点：
- 复用证据：x
- 新增验证：x
- 覆盖范围：x
- 未执行的大范围验证：x
- 剩余风险：x
EOF
)"
if ( z_require_review_min_report "$empty_val" ) >/dev/null 2>&1; then
  echo "✗ 字段值为空应被拒绝" >&2
  fail=1
fi

outside_sec="$(cat <<'EOF'
<!-- new-task-review -->
## Review

- 审查代码与调用点：只写在段外
- 复用证据：x
- 新增验证：x
- 覆盖范围：x
- 未执行的大范围验证：x
- 剩余风险：x

### 最小充分审查

- 复用证据：x
- 新增验证：x
- 覆盖范围：x
- 未执行的大范围验证：x
- 剩余风险：x
EOF
)"
if ( z_require_review_min_report "$outside_sec" ) >/dev/null 2>&1; then
  echo "✗ 字段只出现在段外应被拒绝" >&2
  fail=1
fi

need "$lib" 'z_require_dev_status'
if [ "$fail" -ne 0 ]; then
  echo "✗ 最小充分审查契约未通过" >&2
  exit 1
fi
echo "✓ 最小充分审查契约通过"
