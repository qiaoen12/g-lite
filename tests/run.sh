#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

required=(
  README.md
  AGENTS.md
  docs/machine-bootstrap.md
  .github/ISSUE_TEMPLATE/task.md
  .github/pull_request_template.md
  .github/workflows/pr-gate.yml
  tools/repo-reconciler/manifest.json
  tools/repo-reconciler/reconcile.sh
  tools/repo-reconciler/lib/apply.sh
  tools/repo-reconciler/lib/audit.sh
  tools/repo-reconciler/lib/github.sh
  tools/repo-reconciler/lib/protocol-sync.sh
  tools/repo-reconciler/tests/self-test.sh
  tools/repo-reconciler/tests/protocol-sync-self-test.sh
  tools/repo-reconciler/templates/minimal-consumer-AGENTS.md
  tools/machine-bootstrap/role-exec
  tools/machine-bootstrap/tests/self-test.py
  tests/run.sh
)
fail=0
for f in "${required[@]}"; do
  if [ ! -f "$f" ]; then
    echo "missing required file: $f"
    fail=1
  fi
done
[ "$fail" = 0 ]

# Protocol text is not asserted word by word; only structure that tools rely on.
python3 - <<'PYTHON'
import json
import re
from pathlib import Path
manifest = json.loads(Path('tools/repo-reconciler/manifest.json').read_text())
payload_path = 'tools/repo-reconciler/templates/minimal-consumer-AGENTS.md'
payload = Path(payload_path).read_text()
lines = payload.splitlines()
assert lines[0] == '<!-- g-lite:managed protocol start -->', 'managed block must start on line 1'
assert re.fullmatch(r'G-lite Protocol-Version: v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', lines[1]), 'version declaration on line 2'
assert payload.count('G-lite Protocol-Version') == 1, 'exactly one version declaration'
assert payload.count('g-lite:managed') == 2 and payload.endswith('<!-- g-lite:managed protocol end -->\n'), 'managed block end'
agents = Path('AGENTS.md').read_text()
assert agents.startswith(payload), 'AGENTS.md must begin with the consumer managed block verbatim'
assert agents.count('G-lite Protocol-Version') == 1 and agents.count('g-lite:managed') == 2, 'AGENTS.md remainder repeats managed markers'
for path in ('AGENTS.md', payload_path):
    text = Path(path).read_text()
    assert '.g-lite-local/' not in text, 'retired credential entry'
    assert 'v3.4' not in text, 'historical Freeze in current protocol'
task_path = '.github/ISSUE_TEMPLATE/task.md'
task = Path(task_path).read_text()
assert re.findall(r'^#{1,6} .+$', task, re.M) == ['## Background', '## Execution'], 'task fields'
markers = next(item['markers'] for item in manifest['protocol']['markers'] if item['path'] == task_path)
assert markers == ['## Background'], 'Execution must not become a required marker'
for item in manifest['protocol']['markers']:
    text = Path(item['path']).read_text()
    assert all(marker in text for marker in item['markers']), item['path']
PYTHON

protocol_files=(AGENTS.md README.md docs/machine-bootstrap.md .github/ISSUE_TEMPLATE/task.md .github/pull_request_template.md tests/run.sh \
  tools/repo-reconciler/templates/minimal-consumer-AGENTS.md)
if grep -En '/(Users|home)/[^[:space:]]+' "${protocol_files[@]}"; then
  echo "machine-specific absolute path found in protocol files"
  exit 1
fi
if find tools -type f \( -iname '*worktree*' -o -iname '*task-state*' -o -iname '*task-registry*' \) -print -quit | grep -q .; then
  echo "task worktree helper/runtime or persistent task state has appeared"
  exit 1
fi
if grep -En 'tests/run\.sh|pr-gate|(^|[^[:alnum:]_])unit([^[:alnum:]_]|$)|pytest|npm test' \
  .github/ISSUE_TEMPLATE/task.md \
  .github/pull_request_template.md; then
  echo "consumer protocol fragment contains a project-specific test/check command"
  exit 1
fi

bash -n tools/repo-reconciler/reconcile.sh
bash -n tests/run.sh
for file in tools/repo-reconciler/lib/*.sh tools/repo-reconciler/tests/self-test.sh tools/repo-reconciler/tests/protocol-sync-self-test.sh; do
  bash -n "$file"
done
jq -e '
  .schema_version == 4 and
  (has("baseline") | not) and
  (has("required_label") | not) and
  (.governance_lineage | type == "string" and test("^[A-Za-z0-9._/-]+$")) and
  (.bootstrap | length == 3) and
  (.protocol.markers | length == 3) and
  (([.bootstrap[].path, .protocol.markers[].path] | index("README.md")) == null) and
  (.canonical.current_bindings == {developer_app:{id:5017695,slug:"g-lite-developer",actor:"g-lite-developer[bot]"}}) and
  (.canonical.repo == "qiaoen12/g-lite") and
  (.canonical.ref == "main") and
  (.protocol_sync == {
    managed_prefix: {path:"AGENTS.md",payload:"tools/repo-reconciler/templates/minimal-consumer-AGENTS.md"},
    owned_exact: [
      {path:".github/ISSUE_TEMPLATE/task.md",payload:".github/ISSUE_TEMPLATE/task.md"},
      {path:".github/pull_request_template.md",payload:".github/pull_request_template.md"}
    ]
  }) and
  (.ruleset.required_approvals == 1) and
  (.ruleset.dismiss_stale_reviews_on_push == true) and
  (.ruleset.strict_required_status_checks_policy == true) and
  (.ruleset.allowed_merge_methods == ["squash"]) and
  (["PASS", "DRIFT", "PLATFORM_BLOCKER", "PERMISSION_BLOCKER", "UNVERIFIED"] - .states | length == 0)
' tools/repo-reconciler/manifest.json >/dev/null
if grep -Fq 'check_success_for_branch' tools/repo-reconciler/reconcile.sh tools/repo-reconciler/lib/*.sh tools/repo-reconciler/tests/self-test.sh; then
  echo 'activate must not enforce default-branch CI success'
  exit 1
fi
grep -Fq 'record_write_failure' tools/repo-reconciler/lib/github.sh

banned=(
  0-meta
  1-code
  2-infra
  3-data
  4-know
  5-record
  _inbox
  _vendor
  .agents
  .pre-commit-config.yaml
  .claude
  .cursorignore
  .aiignore
  .github/workflows/main-guard.yml
)
fail=0
# Git-ignored local workbench files (e.g. .claude/settings.local.json) are not repository content.
in_git=0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 && in_git=1
for p in "${banned[@]}"; do
  if [ "$in_git" = 1 ]; then
    present="$(git ls-files --cached --others --exclude-standard -- "$p")"
  else
    present="$([ -e "$p" ] && echo "$p" || true)"
  fi
  if [ -n "$present" ]; then
    echo "legacy path reappeared: $p"
    fail=1
  fi
done
[ "$fail" = 0 ]

workflow=".github/workflows/pr-gate.yml"
if ! grep -Eq '^  pr-gate:$' "$workflow"; then
  echo "workflow missing job key pr-gate"
  exit 1
fi
if ! grep -Eq '^    name: pr-gate$' "$workflow"; then
  echo "workflow missing job name pr-gate"
  exit 1
fi
run_count="$(grep -cE '^[[:space:]]*run:' "$workflow" || true)"
if [ "$run_count" -ne 1 ] || ! grep -Eq '^        run: bash tests/run\.sh$' "$workflow"; then
  echo "workflow must invoke exactly: bash tests/run.sh"
  exit 1
fi
entry_count="$(grep -cF 'bash tests/run.sh' "$workflow" || true)"
if [ "$entry_count" -ne 1 ]; then
  echo "workflow must contain exactly one canonical entry"
  exit 1
fi
# Needles are split so this guard is not the only copy of a moved check.
check_moved() {
  local phrase="$1$2"
  if grep -Fq -- "$phrase" "$workflow"; then
    echo "workflow still embeds check: ${phrase}"
    exit 1
  fi
  if ! grep -Fq -- "$phrase" tests/run.sh; then
    echo "runner missing moved check: ${phrase}"
    exit 1
  fi
}
check_moved "missing required " "file:"
check_moved "legacy path " "reappeared:"
check_moved "activate must not enforce " "default-branch CI success"

tools/repo-reconciler/reconcile.sh self-test
PYTHONDONTWRITEBYTECODE=1 python3 tools/machine-bootstrap/tests/self-test.py
