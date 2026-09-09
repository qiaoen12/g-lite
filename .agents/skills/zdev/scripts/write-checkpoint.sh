#!/usr/bin/env bash
# 更新唯一 Checkpoint。参数：正文文件。
set -Eeuo pipefail
export LC_COLLATE=C
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "✗ 不在 git 工作树" >&2; exit 1; }
# shellcheck source=/dev/null
. "$ROOT/.agents/skills/z-lib.sh"
z_load
[ $# -eq 1 ] || { echo "用法：$0 <checkpoint.md>" >&2; exit 2; }
z_write_checkpoint_file "$1"
echo "已更新同一条 Checkpoint。"
