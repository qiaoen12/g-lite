#!/usr/bin/env bash
# thin adapter：canonical 协议实现是 `new z review`。
# canonical CLI 负责 z_load、最新 main 与 task worktree 门禁；共享 z_require_current_main；这里不复制实现。
set -Eeuo pipefail
export LC_COLLATE=C
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "✗ 不在 git 工作树" >&2; exit 1; }
exec "$ROOT/0-meta/bin/new" z review "$@"
