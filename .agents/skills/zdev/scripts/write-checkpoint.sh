#!/usr/bin/env bash
# 更新唯一 Checkpoint。参数：正文文件。
set -Eeuo pipefail
export LC_COLLATE=C
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "✗ 不在 git 工作树" >&2; exit 1; }
# shellcheck source=/dev/null
. "$ROOT/.agents/skills/z-lib.sh"
z_load
[ $# -eq 1 ] || { echo "用法：$0 <checkpoint.md>" >&2; exit 2; }

checkpoint_body="$(cat "$1")" || die_code z.checkpoint_read_failed "无法读取 Checkpoint 文件：$1"
contract_checkpoint_validate "$checkpoint_body" "$Z_CONTRACT_JSON" "$Z_CONTRACT_BLOB" \
  || die_code contract.checkpoint_invalid "Checkpoint 未通过当前 Contract 校验"

# 只有显式 completion 状态才进入完成态门禁；claim/进行中的旧格式仍可由
# 该工具更新。门禁后再委托给共享 writer，Reviewer 不会在这里替作者修复状态。
task_checkpoint_completion_gate "$checkpoint_body" "$Z_WT" "${Z_BASE:-}" || exit 1

z_write_checkpoint_file "$1"
echo "已更新同一条 Checkpoint。"
