#!/usr/bin/env bash
set -euo pipefail

# G-lite Thin Repo Reconciler
# Stateless companion tool: inspect and reconcile repository governance only.

ACTION="${1:-}"
if [[ -z "$ACTION" || "$ACTION" == "-h" || "$ACTION" == "--help" ]]; then
  cat <<'USAGE'
Usage:
  reconcile.sh audit   [options]
  reconcile.sh plan    [options]
  reconcile.sh apply   [options]
  reconcile.sh upgrade [options]

Options:
  --repo OWNER/REPO          Target repository. Defaults to current gh repo.
  --branch NAME              Protected/default branch. Defaults to repo default branch.
  --reviewer USER            Reviewer Actor. Defaults to manifest reviewer.default.
  --check NAME               Consumer Required Check name. Required for active phase.
  --phase bootstrap|active   bootstrap skips Ruleset/Required Check activation. Default: active.
  --manifest PATH            Manifest path. Defaults beside this script.
  --canonical-ref REF        Override manifest canonical ref.
  --allow-overwrite          Allow apply to replace drifted Exact files in the local checkout.
  --allow-permission-change  Allow apply to grant reviewer push/write permission.
  --activate                 Allow active-phase apply to create a new G-lite Ruleset.

Safety:
  - audit / plan / upgrade are read-only.
  - apply never deletes labels, never rewrites consumer CI, never commits or pushes.
  - existing README / AGENTS are never overwritten.
  - existing Rulesets are never modified automatically; if one exists but drifts, fix it manually.
USAGE
  exit 0
fi
shift || true

case "$ACTION" in
  audit|plan|apply|upgrade) ;;
  *) echo "unknown action: $ACTION" >&2; exit 64 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$SCRIPT_DIR/manifest.json"
REPO=""
BRANCH=""
REVIEWER=""
REQUIRED_CHECK=""
PHASE="active"
CANONICAL_REF_OVERRIDE=""
ALLOW_OVERWRITE=0
ALLOW_PERMISSION_CHANGE=0
ACTIVATE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="${2:?missing --repo value}"; shift 2 ;;
    --branch) BRANCH="${2:?missing --branch value}"; shift 2 ;;
    --reviewer) REVIEWER="${2:?missing --reviewer value}"; shift 2 ;;
    --check) REQUIRED_CHECK="${2:?missing --check value}"; shift 2 ;;
    --phase) PHASE="${2:?missing --phase value}"; shift 2 ;;
    --manifest) MANIFEST="${2:?missing --manifest value}"; shift 2 ;;
    --canonical-ref) CANONICAL_REF_OVERRIDE="${2:?missing --canonical-ref value}"; shift 2 ;;
    --allow-overwrite) ALLOW_OVERWRITE=1; shift ;;
    --allow-permission-change) ALLOW_PERMISSION_CHANGE=1; shift ;;
    --activate) ACTIVATE=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
done

[[ "$PHASE" == "bootstrap" || "$PHASE" == "active" ]] || { echo "--phase must be bootstrap or active" >&2; exit 64; }

for dep in gh jq git; do
  command -v "$dep" >/dev/null 2>&1 || { echo "missing dependency: $dep" >&2; exit 69; }
done
[[ -f "$MANIFEST" ]] || { echo "manifest not found: $MANIFEST" >&2; exit 66; }
jq -e '.schema_version == 1 and (.states | index("PASS")) and (.states | index("DRIFT"))' "$MANIFEST" >/dev/null

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# Results are ephemeral stdout only; no runtime state is written.
RESULTS="$tmpdir/results.tsv"
: > "$RESULTS"

record() {
  local state="$1" category="$2" key="$3" detail="$4"
  printf '%s\t%s\t%s\t%s\n' "$state" "$category" "$key" "$detail" >> "$RESULTS"
}

api_error_state() {
  local msg="$1"
  if grep -Eqi 'upgrade to github pro|not available.*private repositor|not available for private repositor|plan does not support|feature is not available' <<<"$msg"; then
    printf 'PLATFORM_BLOCKER'
  elif grep -Eqi 'HTTP 401|HTTP 403|resource not accessible|must have admin|forbidden|requires.*permission|insufficient permission' <<<"$msg"; then
    printf 'PERMISSION_BLOCKER'
  else
    printf 'UNVERIFIED'
  fi
}

ruleset_error_state() {
  local msg="$1"
  local private admin
  private="$(jq -r '.private // false' "$repo_json" 2>/dev/null || echo false)"
  admin="$(jq -r '.permissions.admin // false' "$repo_json" 2>/dev/null || echo false)"
  if [[ "$private" == "true" && "$admin" == "true" ]] && grep -Eqi 'HTTP 403|HTTP 404|not found' <<<"$msg"; then
    printf 'PLATFORM_BLOCKER'
  else
    api_error_state "$msg"
  fi
}

api_get() {
  local endpoint="$1" outfile="$2" errfile="$3"
  if gh api --method GET "$endpoint" >"$outfile" 2>"$errfile"; then
    return 0
  fi
  return 1
}

repo_json="$tmpdir/repo.json"
repo_err="$tmpdir/repo.err"
if [[ -z "$REPO" ]]; then
  if ! REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>"$repo_err")"; then
    echo "cannot determine repository: $(cat "$repo_err")" >&2
    exit 69
  fi
fi

if ! api_get "repos/$REPO" "$repo_json" "$repo_err"; then
  echo "cannot read repository $REPO: $(cat "$repo_err")" >&2
  exit 69
fi

if [[ -z "$BRANCH" ]]; then
  BRANCH="$(jq -r '.default_branch' "$repo_json")"
fi

CANONICAL_REPO="$(jq -r '.canonical.repo' "$MANIFEST")"
CANONICAL_REF="$(jq -r '.canonical.ref' "$MANIFEST")"
[[ -n "$CANONICAL_REF_OVERRIDE" ]] && CANONICAL_REF="$CANONICAL_REF_OVERRIDE"
[[ -n "$REVIEWER" ]] || REVIEWER="$(jq -r '.reviewer.default' "$MANIFEST")"

fetch_raw_file() {
  local repo="$1" ref="$2" path="$3" out="$4" err="$5"
  if gh api --method GET "repos/$repo/contents/$path" -f ref="$ref" -H 'Accept: application/vnd.github.raw+json' >"$out" 2>"$err"; then
    return 0
  fi
  return 1
}

local_root=""
local_matches_target=0
if local_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  local_name="$(cd "$local_root" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  [[ "$local_name" == "$REPO" ]] && local_matches_target=1
else
  local_root=""
fi

source "$SCRIPT_DIR/lib/audit.sh"
source "$SCRIPT_DIR/lib/apply.sh"

collect_audit

case "$ACTION" in
  audit)
    print_results
    overall_exit || exit $?
    ;;
  plan)
    print_results
    echo
    plan_from_results
    overall_exit || exit $?
    ;;
  upgrade)
    run_upgrade
    overall_exit || exit $?
    ;;
  apply)
    run_apply
    ;;
esac
