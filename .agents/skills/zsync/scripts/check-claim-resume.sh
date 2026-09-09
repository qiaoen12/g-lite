#!/usr/bin/env bash
# 定向检查：claim remote / derive / resume / review 漂移（A4–A13）。
set -Eeuo pipefail
export LC_COLLATE=C
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "✗ 不在 git 工作树" >&2; exit 1; }
exec bash "$ROOT/0-meta/lib/new/claim-resume.test.sh"
