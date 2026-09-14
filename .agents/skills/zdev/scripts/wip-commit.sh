#!/usr/bin/env bash
# 仅在已暂存且门禁通过时建立本地 wip commit。不 push、不建 PR、不改 Project。
set -Eeuo pipefail
export LC_COLLATE=C
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "✗ 不在 git 工作树" >&2; exit 1; }
# shellcheck source=/dev/null
. "$ROOT/.agents/skills/z-lib.sh"
z_load

# z_wip_commit 的历史实现把 status 读取失败当成空改动；先用 canonical
# 只读分类把宿主/index 权限故障挡住。zfix 复用这条提交入口。
if ! task_worktree_status_counts "$Z_WT"; then
  err_code z.completion_status_unreadable \
    "未完成 / BLOCKED：无法读取工作树状态，不能把持久化失败解释为 no-change"
  exit 1
fi
before_dirty="$TASK_WORKTREE_DIRTY"

# z_wip_commit 的 die_code 会在其子 shell 中退出；父层补充统一 BLOCKED 归因，
# 让 git commit / index 等失败不会只留下「提交失败」而被上层误当完成。
if ( trap - EXIT; z_wip_commit "${1:-}" ); then
  commit_rc=0
else
  commit_rc=$?
fi
if [ "$commit_rc" -ne 0 ]; then
  err_code z.completion_blocked \
    "未完成 / BLOCKED：wip commit 未完成（退出码 ${commit_rc}）；不产生完成态 Checkpoint"
  exit "$commit_rc"
fi

if [ "$before_dirty" -eq 0 ]; then
  task_completion_gate "$Z_WT" "${Z_BASE:-}" no-change
else
  task_completion_gate "$Z_WT" "${Z_BASE:-}" changed
fi
