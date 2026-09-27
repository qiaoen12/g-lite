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

fail=0
need() {
  local file="$1"
  local pattern="$2"
  if ! grep -Fq -- "$pattern" "$file"; then
    echo "missing in ${file}: ${pattern}"
    fail=1
  fi
}
need README.md "核心闭环"
need README.md "Issue Contract"
need README.md "approved"
need README.md '缺少 `approved` 只阻止 Developer'
need README.md "不阻止 Main 协调"
need README.md "pr-gate"
need README.md "squash"
need AGENTS.md "## 开工"
need AGENTS.md "## Reviewer protocol"
need AGENTS.md "lastEditedAt"
need AGENTS.md "Fresh authorization:"
need .github/pull_request_template.md "## Why"
need .github/pull_request_template.md "Issue Contract:"
need .github/pull_request_template.md "## What"
need .github/pull_request_template.md "## Test"
need .github/pull_request_template.md "## Unverified / Risks"
need .github/pull_request_template.md "Fixes #"
for file in README.md AGENTS.md tools/repo-reconciler/templates/minimal-consumer-AGENTS.md; do
  need "$file" "Human Authority"
  need "$file" "Local Bootstrap"
  need "$file" "Genesis"
  need "$file" "ACTIVE"
  need "$file" "Squash merge"
done
need AGENTS.md "g-lite-developer[bot]"
need AGENTS.md "g-lite-reviewer[bot]"
need AGENTS.md '## Main 连续交付 SOP'
need AGENTS.md 'CI 失败交 Developer'
need AGENTS.md 'Main 不写 PR branch'
need AGENTS.md 'B` 是 `H` 祖先'
need AGENTS.md 'merge-authorized'
need AGENTS.md 'gh pr merge --squash --match-head-commit H'
need AGENTS.md 'configured role entry'
need AGENTS.md '缺少 `approved` 只挡 Developer'
need docs/machine-bootstrap.md 'Machine Bootstrap'
need docs/machine-bootstrap.md 'role-exec developer check'
need tools/repo-reconciler/templates/minimal-consumer-AGENTS.md '## Main delivery SOP'
need tools/repo-reconciler/templates/minimal-consumer-AGENTS.md 'Failed CI or REQUEST_CHANGES'
need tools/repo-reconciler/templates/minimal-consumer-AGENTS.md "must not write the Developer's PR branch"
need tools/repo-reconciler/templates/minimal-consumer-AGENTS.md 'B is an ancestor of H'
need tools/repo-reconciler/templates/minimal-consumer-AGENTS.md 'merge-authorized'
need tools/repo-reconciler/templates/minimal-consumer-AGENTS.md 'gh pr merge --squash --match-head-commit H'
consumer_agents=tools/repo-reconciler/templates/minimal-consumer-AGENTS.md
# Check stable role-interface identifiers here; behavior and fail-closed paths
# are exercised by the machine-bootstrap self-test below.
for file in AGENTS.md "$consumer_agents" docs/machine-bootstrap.md; do
  need "$file" 'tools/machine-bootstrap/role-exec'
  need "$file" '.config/g-lite/bin/app-env.sh'
  need "$file" 'G_LITE_APP_ENV'
done
need tools/repo-reconciler/reconcile.sh "reconcile.sh audit"
need tools/repo-reconciler/reconcile.sh "reconcile.sh plan"
need tools/repo-reconciler/reconcile.sh "reconcile.sh bootstrap"
need tools/repo-reconciler/reconcile.sh "reconcile.sh activate"
need tools/repo-reconciler/reconcile.sh "reconcile.sh apply"
need tools/repo-reconciler/reconcile.sh "reconcile.sh upgrade"
need tools/repo-reconciler/reconcile.sh "reconcile.sh protocol-sync"
need tools/repo-reconciler/reconcile.sh "--human-authority-verified"
need tools/repo-reconciler/lib/apply.sh "write_preflight"
need AGENTS.md "L0 Static"
need AGENTS.md "L1 Unit"
need AGENTS.md "L2 Integration"
need AGENTS.md "L3 Acceptance / Contract"
need AGENTS.md "L4 E2E / Pilot"
need AGENTS.md "Permanent"
need AGENTS.md "Stage"
need AGENTS.md "Pilot"
need AGENTS.md "PROMOTE"
need AGENTS.md "KEEP MANUAL"
need AGENTS.md "DELETE"
need AGENTS.md "tests/run.sh"
need AGENTS.md "LOCAL GREEN"
need AGENTS.md "CI GREEN"
need AGENTS.md "REVIEW-READY"
need AGENTS.md "## Primary checkout 与 native Git worktree"
need AGENTS.md "永远停留在 repository default branch"
need AGENTS.md "git worktree add -b <task-branch> <task-worktree> origin/main"
need AGENTS.md "git worktree list --porcelain"
need AGENTS.md "git worktree remove <task-worktree>"
need AGENTS.md "git branch -d <task-branch>"
need AGENTS.md "git branch -D <task-branch>"
need AGENTS.md "primary main + clean"
need README.md "primary checkout stays on default/main"
need README.md "one dedicated native Git task worktree"
need README.md "temporary detached-HEAD worktree"
protocol_files=(AGENTS.md README.md .github/ISSUE_TEMPLATE/task.md .github/pull_request_template.md tests/run.sh \
  tools/repo-reconciler/templates/minimal-consumer-AGENTS.md)
if grep -En '/(Users|home)/[^[:space:]]+' "${protocol_files[@]}"; then
  echo "machine-specific absolute path found in protocol files"
  exit 1
fi
if find tools -type f \( -iname '*worktree*' -o -iname '*task-state*' -o -iname '*task-registry*' \) -print -quit | grep -q .; then
  echo "task worktree helper/runtime or persistent task state has appeared"
  exit 1
fi
need README.md "LOCAL GREEN"
need README.md "CI GREEN"
need README.md "REVIEW-READY"
need README.md "tests/run.sh"
need README.md "bash tests/run.sh"
need README.md "Permanent"
need README.md "Stage"
need README.md "Pilot"
# Task facts use one body. Explanation text is deliberately not asserted.
python3 - <<'PYTHON'
import json
import re
from pathlib import Path
manifest = json.loads(Path('tools/repo-reconciler/manifest.json').read_text())
task_path = '.github/ISSUE_TEMPLATE/task.md'
task = Path(task_path).read_text()
assert re.findall(r'^#{1,6} .+$', task, re.M) == ['## Background', '## Execution'], 'task fields'
markers = next(item['markers'] for item in manifest['protocol']['markers'] if item['path'] == task_path)
assert markers == ['## Background'], 'Execution must not become a required marker'
for item in manifest['protocol']['markers']:
    text = Path(item['path']).read_text()
    assert all(marker in text for marker in item['markers']), item['path']
versions = []
for path in ('AGENTS.md', 'tools/repo-reconciler/templates/minimal-consumer-AGENTS.md'):
    text = Path(path).read_text()
    declarations = re.findall(r'^G-lite Protocol-Version: (.+)$', text, re.M)
    assert len(declarations) == 1 and re.fullmatch(r'v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', declarations[0]), path
    versions += declarations
    assert '.g-lite-local/' not in text, 'retired credential entry'
    assert 'v3.4' not in text, 'historical Freeze in current protocol'
    assert 'Background' in text and 'Execution' in text, 'task structure missing'
assert versions[0] == versions[1], 'canonical and consumer protocol versions differ'
PYTHON
need .github/pull_request_template.md "approved Issue Contract reference"
need .github/pull_request_template.md "LOCAL GREEN evidence"
need .github/pull_request_template.md "PR HEAD"
need .github/pull_request_template.md "CI GREEN evidence for the current PR HEAD"
need .github/pull_request_template.md "Unverified / Risks"
if grep -En 'tests/run\.sh|pr-gate|(^|[^[:alnum:]_])unit([^[:alnum:]_]|$)|pytest|npm test' \
  .github/ISSUE_TEMPLATE/task.md \
  .github/pull_request_template.md; then
  echo "consumer protocol fragment contains a project-specific test/check command"
  exit 1
fi
[ "$fail" = 0 ]

bash -n tools/repo-reconciler/reconcile.sh
bash -n tests/run.sh
for file in tools/repo-reconciler/lib/*.sh tools/repo-reconciler/tests/self-test.sh tools/repo-reconciler/tests/protocol-sync-self-test.sh; do
  bash -n "$file"
done
jq -e '
  .schema_version == 4 and
  (has("baseline") | not) and
  (.governance_lineage | type == "string" and test("^[A-Za-z0-9._/-]+$")) and
  (.bootstrap | length == 3) and
  (.protocol.markers | length == 3) and
  (([.bootstrap[].path, .protocol.markers[].path] | index("README.md")) == null) and
  (.required_label.name == "approved") and
  (.canonical.current_bindings.developer_app == {id:5017695,slug:"g-lite-developer",actor:"g-lite-developer[bot]"}) and
  (.canonical.current_bindings.reviewer_app == {id:5010632,slug:"g-lite-reviewer",actor:"g-lite-reviewer[bot]"}) and
  (.canonical.repo == "qiaoen12/g-lite") and
  (.canonical.ref == "main") and
  (.protocol_sync == {
    managed_prefix: {path:"AGENTS.md",payload:"tools/repo-reconciler/templates/minimal-consumer-AGENTS.md"},
    owned_exact: [
      {path:".github/ISSUE_TEMPLATE/task.md",payload:".github/ISSUE_TEMPLATE/task.md"},
      {path:".github/pull_request_template.md",payload:".github/pull_request_template.md"}
    ]
  }) and
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
for p in "${banned[@]}"; do
  if [ -e "$p" ]; then
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
