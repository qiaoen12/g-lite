#!/usr/bin/env bash
# 仅在通过 Review 且无 human-merge 时 squash merge。
# 同机 git common dir 互斥；已合并 PR 只 finalize；本地 main 只 ff-only。
# In progress / In review：调用 new task review（推导状态，不读 Project Status 放行）。
# 不删工作树/本地分支，不用 --delete-branch / --admin，不关 Issue，不写 Done。
set -Eeuo pipefail
export LC_COLLATE=C
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "✗ 不在 git 工作树" >&2; exit 1; }
# shellcheck source=/dev/null
. "$ROOT/.agents/skills/z-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/.agents/skills/zmerge/scripts/squash-body.sh"
# shellcheck source=/dev/null
. "$ROOT/.agents/skills/zmerge/scripts/merge-lib.sh"
z_load
z_require_clean
task_branch_pushable "$Z_GIT_BR" "$Z_MAIN" || die_code task.branch_not_pushable "当前分支不可交付：${Z_GIT_BR}"
zmerge_run
