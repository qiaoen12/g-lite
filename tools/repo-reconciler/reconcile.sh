#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || { cd "$SCRIPT_DIR/../.."; pwd; })"
MANIFEST="$SCRIPT_DIR/manifest.json"
ACTION="${1:-}"

usage() {
  cat <<'USAGE'
Usage:
  reconcile.sh audit     [--repo OWNER/REPO] [--branch NAME] [--phase bootstrap|active] [--required-check NAME]
  reconcile.sh plan      [--repo OWNER/REPO] [--branch NAME] [--phase bootstrap|active] [--required-check NAME]
  reconcile.sh bootstrap [--repo OWNER/REPO] [--branch NAME] --human-authority-verified --developer-app-verified --reviewer-app-verified
  reconcile.sh activate  --required-check NAME [--repo OWNER/REPO] [--branch NAME] --human-authority-verified --developer-app-verified --reviewer-app-verified
  reconcile.sh apply     [--repo OWNER/REPO] [--branch NAME] [--required-check NAME] --human-authority-verified --developer-app-verified --reviewer-app-verified
  reconcile.sh upgrade   [--repo OWNER/REPO] [--branch NAME] [--phase bootstrap|active] [--required-check NAME]
  reconcile.sh self-test

Read-only audit, plan, upgrade, and self-test do not require Human Authority
authorization. Write actions bootstrap, activate, and apply require all three
invocation-only assertions: --human-authority-verified, --developer-app-verified,
and --reviewer-app-verified. The Human Authority assertion means the caller
externally confirmed explicit governance-write authorization and appropriate
identity for this invocation. App assertions are external identity / installation
preflights for the Developer and Reviewer roles. A unified write preflight runs
before any remote governance write; a missing assertion is UNVERIFIED (exit 3)
and stops before bootstrap_file, ensure_label, or ensure_ruleset. The tool does
not read private keys, generate JWTs/tokens, save credentials, or persist any
assertion; none of these assertions grants Developer / Reviewer governance powers.

The tool reads GitHub facts with gh, writes only the bootstrap baseline and
G-lite-owned label/ruleset facts, and keeps all intermediate data ephemeral.
It never selects, generates, or edits consumer CI.
USAGE
}

if [[ -z "$ACTION" || "$ACTION" == "-h" || "$ACTION" == "--help" ]]; then
  usage
  exit 0
fi
shift || true

case "$ACTION" in
  audit|plan|bootstrap|activate|apply|upgrade|self-test) ;;
  *) echo "unknown action: $ACTION" >&2; usage >&2; exit 64 ;;
esac

REPO=""
BRANCH=""
DEFAULT_BRANCH=""
REQUIRED_CHECK=""
HUMAN_AUTHORITY_VERIFIED=false
DEVELOPER_APP_VERIFIED=false
REVIEWER_APP_VERIFIED=false
PHASE="active"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="${2:?missing --repo value}"; shift 2 ;;
    --branch) BRANCH="${2:?missing --branch value}"; shift 2 ;;
    --phase) PHASE="${2:?missing --phase value}"; shift 2 ;;
    --required-check) REQUIRED_CHECK="${2:?missing --required-check value}"; shift 2 ;;
    --human-authority-verified) HUMAN_AUTHORITY_VERIFIED=true; shift ;;
    --developer-app-verified) DEVELOPER_APP_VERIFIED=true; shift ;;
    --reviewer-app-verified) REVIEWER_APP_VERIFIED=true; shift ;;
    --manifest) MANIFEST="${2:?missing --manifest value}"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
done

if [[ "$ACTION" == "bootstrap" ]]; then
  PHASE="bootstrap"
fi
if [[ "$ACTION" == "activate" ]]; then
  PHASE="active"
fi
if [[ "$ACTION" == "activate" && -z "$REQUIRED_CHECK" ]]; then
  echo "activate requires --required-check NAME" >&2
  exit 64
fi
[[ "$PHASE" == "bootstrap" || "$PHASE" == "active" ]] || {
  echo "--phase must be bootstrap or active" >&2
  exit 64
}
[[ -f "$MANIFEST" ]] || { echo "manifest not found: $MANIFEST" >&2; exit 66; }

for dep in gh jq git base64; do
  command -v "$dep" >/dev/null 2>&1 || { echo "missing dependency: $dep" >&2; exit 69; }
done

jq -e '
  .schema_version == 3 and
  (.bootstrap | length == 3) and
  (.protocol.markers | length == 3) and
  (([.bootstrap[].path, .protocol.markers[].path] | index("README.md")) == null) and
  (.required_label.name == "approved") and
  (.ruleset.required_approvals == 1) and
  (.ruleset.allowed_merge_methods == ["squash"]) and
  (["PASS", "DRIFT", "PLATFORM_BLOCKER", "PERMISSION_BLOCKER", "UNVERIFIED"] - .states | length == 0)
' "$MANIFEST" >/dev/null || { echo "invalid reconciler manifest: $MANIFEST" >&2; exit 65; }

stale_checkout_guard() {
  local hit="" retired_marker="task-contract:v""1"
  if [[ -e "$ROOT/0-meta/bin/new" ]]; then
    hit="$ROOT/0-meta/bin/new"
  else
    hit="$(grep -R -l --exclude-dir=.git --fixed-strings "$retired_marker" "$ROOT" 2>/dev/null | head -n 1 || true)"
  fi
  if [[ -n "$hit" ]]; then
    echo "STALE_CHECKOUT: retired task runtime detected; use a current G-lite checkout" >&2
    exit 78
  fi
}

stale_checkout_guard

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
RESULTS="$tmpdir/results.tsv"
WRITE_RESULTS="$tmpdir/write-results.tsv"
: > "$RESULTS"
: > "$WRITE_RESULTS"

source "$SCRIPT_DIR/lib/github.sh"

source "$SCRIPT_DIR/lib/audit.sh"

source "$SCRIPT_DIR/lib/apply.sh"

run_upgrade() {
  auditor
  print_results
  echo
  echo "UPGRADE REVIEW (read-only)"
  plan_from_results
  echo "No consumer files, labels, Rulesets, workflows, commits, or pull requests were changed."
  overall_exit || return $?
}

if [[ "$ACTION" == "self-test" ]]; then
  source "$SCRIPT_DIR/tests/self-test.sh"
  run_self_test
  exit $?
fi

case "$ACTION" in
  audit)
    load_repository
    auditor
    print_results
    overall_exit || exit $?
    ;;
  plan)
    load_repository
    auditor
    print_results
    echo
    plan_from_results
    overall_exit || exit $?
    ;;
  bootstrap)
    run_write_action run_bootstrap
    ;;
  activate)
    run_write_action run_activate
    ;;
  apply)
    run_write_action run_apply
    ;;
  upgrade)
    load_repository
    run_upgrade
    ;;
esac
