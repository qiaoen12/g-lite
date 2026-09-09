#!/usr/bin/env bash
# 定向检查：提交范围门禁、顶层目录 sparse 覆盖、授权名单、领取后自动 zdev。
# 不跑全量 test，不调用 gh / orca。
set -Eeuo pipefail
export LC_COLLATE=C
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "✗ 不在 git 工作树" >&2; exit 1; }

lib="$ROOT/.agents/skills/z-lib.sh"
task="$ROOT/0-meta/lib/new/task.sh"
flow="$ROOT/0-meta/templates/z-workflow.md"
agents="$ROOT/0-meta/AGENTS.md"
gitdoc="$ROOT/0-meta/docs/07-git-工作流.md"
zdev="$ROOT/.agents/skills/zdev/SKILL.md"
wip="$ROOT/.agents/skills/zdev/scripts/wip-commit.sh"
active="$ROOT/.agents/skills/zdev/scripts/require-active.sh"
openpr="$ROOT/.agents/skills/zpr/scripts/open-pr.sh"
fail=0

need() {
  local file="$1" pat="$2"
  if ! grep -Fq -- "$pat" "$file"; then
    echo "✗ $file 缺少：$pat" >&2
    fail=1
  fi
}

[ -f "$lib" ] && [ -f "$task" ] && [ -f "$flow" ] && [ -f "$zdev" ] \
  || { echo "✗ 规则文件缺失" >&2; exit 1; }

need "$lib" 'z_require_staged_in_scope'
need "$lib" 'core.quotePath=false'
need "$lib" 'z_contract_load'
need "$lib" 'z_require_dev_status'
need "$task" 'task_path_in_scope'
need "$ROOT/0-meta/lib/new/contract.sh" 'contract_parse_body'
need "$ROOT/0-meta/lib/new/contract.sh" 'contract_load_main'
need "$ROOT/0-meta/lib/new/task.sh" 'contract.sh'
need "$task" 'task_repo_path_ascii_ok'
need "$task" 'task_is_cone_root_file'
need "$task" 'task_path_hard_denied'
need "$task" '0-meta/tasks'
need "$task" '不新建第二个 PR'
need "$task" '保持 In review'
need "$task" 'task_agent_start_prompt'
need "$task" 'TASK_START_PROMPT_VARIANT=C'
need "$zdev" '开工摘要'
need "$zdev" 'new task approve'
need "$active" 'z_require_dev_status'
need "$openpr" 'z_require_current_main'
need "$wip" 'z_wip_commit'
need "$agents" 'zdev` `zfix` `zreview` `zsync` `zmerge` `zpr'
need "$flow" 'zdev` `zfix` `zreview` `zsync` `zmerge` `zpr'
need "$gitdoc" 'zdev` `zfix` `zreview` `zsync` `zmerge` `zpr'
need "$flow" '先输出开工摘要'
need "$gitdoc" '自动执行 /zdev'
need "$task" '默认合并由 zmerge'
need "$task" 'human-merge'

# shellcheck source=/dev/null
. "$ROOT/0-meta/lib/new/core.sh"
# shellcheck source=/dev/null
. "$task"
# shellcheck source=/dev/null
. "$lib"

body="$(cat <<'EOF'
## 允许改动范围

- `.agents/skills/z-lib.sh`
- `.agents/skills/zdev/`
- `0-meta/AGENTS.md`
- `0-meta/docs/07-git-工作流.md`
- `1-code`
- 与本任务直接相关的最小测试/契约检查

不得借本任务修改其它治理规则。
EOF
)"
scope="$(task_parse_scope "$body")" || { echo "✗ 含中文路径的范围应能解析" >&2; fail=1; scope=""; }
printf '%s\n' "$scope" | grep -Fq '0-meta/docs/07-git-工作流.md' \
  || { echo "✗ 未解析到中文文件名路径：$scope" >&2; fail=1; }
printf '%s\n' "$scope" | grep -Fq '1-code' \
  || { echo "✗ 未解析到顶层目录 1-code：$scope" >&2; fail=1; }
if printf '%s\n' "$scope" | grep -Fq '与本任务直接相关的最小测试/契约检查'; then
  echo "✗ 无反引号的说明句不应被收成路径：$scope" >&2
  fail=1
fi

task_path_in_scope '.agents/skills/zdev/SKILL.md' "$scope" \
  || { echo "✗ 目录范围内的文件应算在范围内" >&2; fail=1; }
task_path_in_scope '.agents/skills/z-lib.sh' "$scope" \
  || { echo "✗ 精确文件应算在范围内" >&2; fail=1; }
if task_path_in_scope '0-meta/lib/new/core.sh' "$scope"; then
  echo "✗ 未授权文件不应算在范围内" >&2
  fail=1
fi
task_path_hard_denied '5-record/secret.pdf' \
  || { echo "✗ 5-record 应为绝对禁止" >&2; fail=1; }
if task_path_hard_denied '.agents/skills/zdev/SKILL.md'; then
  echo "✗ 允许路径不应被标成绝对禁止" >&2
  fail=1
fi

added="$(task_append_scope_to_body "$body" '0-meta/templates/z-workflow.md')" \
  || { echo "✗ 追加范围失败" >&2; fail=1; added=""; }
printf '%s\n' "$added" | grep -Fq '0-meta/templates/z-workflow.md' \
  || { echo "✗ 追加后正文应含新路径" >&2; fail=1; }
if task_append_scope_to_body "$body" '5-record/x' >/dev/null 2>&1; then
  echo "✗ 绝对禁止路径不得加入范围" >&2
  fail=1
fi

tmp="$(mktemp -d -t z-scope.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
git init -q -b main "$tmp"
git -C "$tmp" config user.email t@example.com
git -C "$tmp" config user.name t
git -C "$tmp" config core.hooksPath /dev/null
mkdir -p "$tmp/1-code" "$tmp/0-meta"
printf 'a\n' > "$tmp/AGENTS.md"
printf 'b\n' > "$tmp/1-code/x"
printf 'c\n' > "$tmp/0-meta/y"
git -C "$tmp" add AGENTS.md 1-code 0-meta
git -C "$tmp" commit -qm 'init'

if ! task_is_cone_root_file "$tmp" AGENTS.md; then
  echo "✗ AGENTS.md 应为 cone 根层文件" >&2
  fail=1
fi
if task_is_cone_root_file "$tmp" 1-code; then
  echo "✗ 1-code 不得被当成 cone 根层文件" >&2
  fail=1
fi
if task_is_cone_root_file "$tmp" 0-meta/y; then
  echo "✗ 带 / 的路径不是根层文件" >&2
  fail=1
fi

empty_rev="$(cat <<'EOF'
<!-- new-task-review -->
## Review

### 最小充分审查

- 审查代码与调用点：
- 复用证据：有
- 新增验证：有
- 覆盖范围：有
- 未执行的大范围验证：有
- 剩余风险：有
EOF
)"
if ( z_require_review_min_report "$empty_rev" ) >/dev/null 2>&1; then
  echo "✗ 空字段的最小充分审查应失败" >&2
  fail=1
fi

if grep -Fq '合并由人在 GitHub PR 页面决定' "$task"; then
  echo "✗ task.sh 仍含过期合并说明" >&2
  fail=1
fi
if grep -Fq '等待用户显式执行 zdev' "$task"; then
  echo "✗ 领取成功后仍要求再等一次 zdev" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "✗ 范围门禁 / 重交付契约未通过" >&2
  exit 1
fi
echo "✓ 范围门禁 / 重交付契约通过"
