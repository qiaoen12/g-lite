#!/usr/bin/env bash
# launchd 入口。不读 rc 文件，所以 PATH 必须自给。
set -Eeuo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"
mkdir -p "${HOME}/Library/Logs/g-lite-backup"
exec "$ROOT/2-infra/backup/scripts/backup-cold.sh" --apply
