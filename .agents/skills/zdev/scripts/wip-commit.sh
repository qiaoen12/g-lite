#!/usr/bin/env bash
# 仅在已暂存且门禁通过时建立本地 wip commit。不 push、不建 PR、不改 Project。
set -Eeuo pipefail
export LC_COLLATE=C
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "✗ 不在 git 工作树" >&2; exit 1; }
# shellcheck source=/dev/null
. "$ROOT/.agents/skills/z-lib.sh"
z_load
z_wip_commit "${1:-}"
