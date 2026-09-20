#!/usr/bin/env bash
set -euo pipefail

# G-lite Thin Repo Reconciler
# Stateless companion tool: inspect and reconcile repository governance only.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)"

stale_checkout_guard() {
  local retired_dir="0-meta"
  local retired_entry="$retired_dir/bin/new"
  local retired_marker="task-contract:v""1"
  local hits=""

  if [[ -e "$WORKTREE_ROOT/$retired_entry" ]]; then
    hits="$WORKTREE_ROOT/$retired_entry"
  fi
  if command -v rg >/dev/null 2>&1; then
    hits+="$(rg -n --hidden --glob '!.git/**' --fixed-strings "$retired_marker" "$WORKTREE_ROOT" 2>/dev/null || true)"
  else
    hits+="$(grep -R -n --exclude-dir=.git --fixed-strings "$retired_marker" "$WORKTREE_ROOT" 2>/dev/null || true)"
  fi
  if [[ -n "$hits" ]]; then
    echo "LEGACY G-LITE RUNTIME DETECTED" >&2
    echo "Retired 0-meta/task-contract route is present in the current checkout; refusing to continue." >&2
    exit 78
  fi
}

stale_checkout_guard

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
  --source-root PATH         Local canonical checkout used for Genesis seed files.
  --reviewer-gh-config PATH  Reviewer gh config used to accept a pending invite during Genesis or permission repair.
  --genesis                  apply only: create/seed a fresh public repo and activate it end-to-end.
  --allow-overwrite          Allow apply to replace drifted Exact files in the local checkout.
  --allow-permission-change  Allow apply to grant reviewer push/write permission.
  --activate                 Allow active-phase apply to create or repair the G-lite Ruleset.
  --wait-timeout SECONDS     Genesis CI wait timeout. Default: 600.

Safety:
  - audit / plan / upgrade are read-only.
  - ordinary apply never commits, pushes, creates repositories, or rewrites consumer CI.
  - --genesis is the explicit end-to-end path: it may create a public repo, seed only missing
    protocol files plus a minimal CI workflow, grant the requested Reviewer permission, and
    create or repair the named G-lite Ruleset after a real check succeeds.
  - existing README / AGENTS and existing consumer workflows are never overwritten.
  - Repository General merge/rebase toggles are not a G-lite gate; squash-only is enforced by
    the Ruleset allowed_merge_methods value.
USAGE
  exit 0
fi
shift || true

case "$ACTION" in
  audit|plan|apply|upgrade) ;;
  *) echo "unknown action: $ACTION" >&2; exit 64 ;;
esac

MANIFEST="$SCRIPT_DIR/manifest.json"
REPO=""
BRANCH=""
REVIEWER=""
REQUIRED_CHECK=""
PHASE="active"
CANONICAL_REF_OVERRIDE=""
SOURCE_ROOT=""
REVIEWER_GH_CONFIG=""
ALLOW_OVERWRITE=0
ALLOW_PERMISSION_CHANGE=0
ACTIVATE=0
GENESIS=0
WAIT_TIMEOUT=600

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="${2:?missing --repo value}"; shift 2 ;;
    --branch) BRANCH="${2:?missing --branch value}"; shift 2 ;;
    --reviewer) REVIEWER="${2:?missing --reviewer value}"; shift 2 ;;
    --check) REQUIRED_CHECK="${2:?missing --check value}"; shift 2 ;;
    --phase) PHASE="${2:?missing --phase value}"; shift 2 ;;
    --manifest) MANIFEST="${2:?missing --manifest value}"; shift 2 ;;
    --canonical-ref) CANONICAL_REF_OVERRIDE="${2:?missing --canonical-ref value}"; shift 2 ;;
    --source-root) SOURCE_ROOT="${2:?missing --source-root value}"; shift 2 ;;
    --reviewer-gh-config) REVIEWER_GH_CONFIG="${2:?missing --reviewer-gh-config value}"; shift 2 ;;
    --allow-overwrite) ALLOW_OVERWRITE=1; shift ;;
    --allow-permission-change) ALLOW_PERMISSION_CHANGE=1; shift ;;
    --activate) ACTIVATE=1; shift ;;
    --genesis) GENESIS=1; ACTIVATE=1; ALLOW_PERMISSION_CHANGE=1; shift ;;
    --wait-timeout) WAIT_TIMEOUT="${2:?missing --wait-timeout value}"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
done

[[ "$PHASE" == "bootstrap" || "$PHASE" == "active" ]] || { echo "--phase must be bootstrap or active" >&2; exit 64; }
[[ "$WAIT_TIMEOUT" =~ ^[0-9]+$ ]] || { echo "--wait-timeout must be a non-negative integer" >&2; exit 64; }
if [[ "$GENESIS" -eq 1 && -z "$REPO" ]]; then
  echo "--genesis requires --repo OWNER/REPO" >&2
  exit 64
fi

for dep in gh jq git base64; do
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

ensure_genesis_repository() {
  repo_json="$tmpdir/repo.json"
  repo_err="$tmpdir/repo.err"
  if [[ -z "$REPO" ]]; then
    if ! REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>"$repo_err")"; then
      echo "cannot determine current repository: $(cat "$repo_err")" >&2
      exit 69
    fi
  fi
  if api_get "repos/$REPO" "$repo_json" "$repo_err"; then
    return 0
  fi
  if [[ "$GENESIS" -ne 1 ]]; then
    echo "cannot read repository $REPO: $(cat "$repo_err")" >&2
    exit 69
  fi
  echo "GENESIS: creating public repository $REPO with gh repo create"
  if ! gh repo create "$REPO" --public --description "G-lite Genesis E2E consumer" >/dev/null; then
    echo "cannot create repository $REPO" >&2
    exit 69
  fi
  if ! api_get "repos/$REPO" "$repo_json" "$repo_err"; then
    echo "repository $REPO was created but cannot be read: $(cat "$repo_err")" >&2
    exit 69
  fi
}

ensure_genesis_repository

CANONICAL_REPO="$(jq -r '.canonical.repo' "$MANIFEST")"
CANONICAL_REF="$(jq -r '.canonical.ref' "$MANIFEST")"
[[ -n "$CANONICAL_REF_OVERRIDE" ]] && CANONICAL_REF="$CANONICAL_REF_OVERRIDE"
[[ -n "$REVIEWER" ]] || REVIEWER="$(jq -r '.reviewer.default' "$MANIFEST")"
if [[ -z "$REQUIRED_CHECK" && "$GENESIS" -eq 1 ]]; then
  REQUIRED_CHECK="$(jq -r '.genesis.required_check // "genesis-ci"' "$MANIFEST")"
fi
RULESET_NAME="$(jq -r '.ruleset.name // "G-lite main"' "$MANIFEST")"

if [[ -z "$BRANCH" ]]; then
  BRANCH="$(jq -r '.default_branch // empty' "$repo_json")"
  [[ -n "$BRANCH" ]] || BRANCH="$(jq -r '.ruleset.branch // "main"' "$MANIFEST")"
fi

if [[ -n "$SOURCE_ROOT" ]]; then
  [[ -d "$SOURCE_ROOT" ]] || { echo "source root not found: $SOURCE_ROOT" >&2; exit 66; }
else
  SOURCE_ROOT="$WORKTREE_ROOT"
fi

local_root=""
local_matches_target=0
local_is_canonical=0
if local_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  local_name="$(cd "$local_root" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  [[ "$local_name" == "$REPO" ]] && local_matches_target=1
  [[ "$local_name" == "$CANONICAL_REPO" ]] && local_is_canonical=1
else
  local_root=""
fi

fetch_raw_file() {
  local repo="$1" ref="$2" path="$3" out="$4" err="$5"
  if gh api --method GET "repos/$repo/contents/$path" -f ref="$ref" -H 'Accept: application/vnd.github.raw+json' >"$out" 2>"$err"; then
    return 0
  fi
  return 1
}

source_protocol_file() {
  local path="$1" out="$2"
  local err="$out.err"
  if [[ -f "$SOURCE_ROOT/$path" && "$local_is_canonical" -eq 1 ]]; then
    cp "$SOURCE_ROOT/$path" "$out"
    return 0
  fi
  fetch_raw_file "$CANONICAL_REPO" "$CANONICAL_REF" "$path" "$out" "$err"
}

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
