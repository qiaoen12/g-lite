#!/usr/bin/env bash
# 只验证。不向 GitHub 写。
set -euo pipefail
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$HOOK_DIR/git-guard-lib.sh"
guard_pre_receive
