#!/usr/bin/env bash
# thin adapter：状态门禁的 canonical 入口是 `new z fix`；canonical z_require_dev_status 负责状态判定。
set -Eeuo pipefail
export LC_COLLATE=C
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "✗ 不在 git 工作树" >&2; exit 1; }
exec "$ROOT/0-meta/bin/new" z fix
