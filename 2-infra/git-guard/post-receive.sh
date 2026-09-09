#!/usr/bin/env bash
# staging refs 已更新后，--atomic + 每 ref --force-with-lease 转发 GitHub。
set -euo pipefail
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$HOOK_DIR/git-guard-lib.sh"
guard_post_receive
