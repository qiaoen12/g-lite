#!/usr/bin/env bash
# 先把 GitHub 镜像进 refs/guard/github/，再调真正的 git-receive-pack。
# 转发失败由本 wrapper 变成客户端非 0。
set -euo pipefail
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$HOOK_DIR/git-guard-lib.sh"
guard_receive_pack "$@"
