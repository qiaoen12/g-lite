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
  reconcile.sh bootstrap [--repo OWNER/REPO] [--branch NAME]
  reconcile.sh activate  --required-check NAME [--repo OWNER/REPO] [--branch NAME]
  reconcile.sh apply     [--repo OWNER/REPO] [--branch NAME] [--required-check NAME]
  reconcile.sh upgrade   [--repo OWNER/REPO] [--branch NAME] [--phase bootstrap|active] [--required-check NAME]
  reconcile.sh self-test

All governance commands accept --reviewer-app-verified. Pass it only after
the Agent independently uses existing g-lite-reviewer credentials to prove
App ID 5010632, actor g-lite-reviewer[bot], and installation access to the
target repository. This assertion applies only to this invocation; without
it reviewer_app is UNVERIFIED (exit 3). The tool does not handle App credentials.

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
REVIEWER_APP_VERIFIED=false
PHASE="active"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="${2:?missing --repo value}"; shift 2 ;;
    --branch) BRANCH="${2:?missing --branch value}"; shift 2 ;;
    --phase) PHASE="${2:?missing --phase value}"; shift 2 ;;
    --required-check) REQUIRED_CHECK="${2:?missing --required-check value}"; shift 2 ;;
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
  .schema_version == 2 and
  (.bootstrap | length == 3) and
  (.protocol.markers | length == 3) and
  (([.bootstrap[].path, .protocol.markers[].path] | index("README.md")) == null) and
  (.required_label.name == "approved") and
  (.reviewer_app.slug == "g-lite-reviewer") and
  (.reviewer_app.actor == "g-lite-reviewer[bot]") and
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

record() {
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$RESULTS"
}

record_write_failure() {
  local key="$1" error="$2" state detail message
  message="$(cat "$error" 2>/dev/null || true)"
  state="$(api_error_state "$message")"
  case "$state" in
    PERMISSION_BLOCKER) detail="write denied by GitHub permissions" ;;
    PLATFORM_BLOCKER) detail="write unsupported by the GitHub platform/plan" ;;
    *) detail="write result could not be verified" ;;
  esac
  printf '%s\twrite\t%s\t%s\n' "$state" "$key" "$detail" >> "$WRITE_RESULTS"
}

api_get() {
  gh api --method GET "$1" >"$2" 2>"$3"
}

api_error_state() {
  local message
  message="$(tr '[:upper:]' '[:lower:]' <<<"$1")"
  if grep -Eq 'plan does not support|feature is not available|not available for private' <<<"$message"; then
    printf 'PLATFORM_BLOCKER'
  elif grep -Eq 'http 401|http 403|forbidden|resource not accessible|requires.*permission|insufficient permission' <<<"$message"; then
    printf 'PERMISSION_BLOCKER'
  else
    printf 'UNVERIFIED'
  fi
}

is_missing_error() {
  grep -Eqi 'http 404|not found|git repository is empty|does not exist' "$1"
}

encode_file() {
  base64 < "$1" | tr -d '\n'
}

decode_base64() {
  if base64 -d </dev/null >/dev/null 2>&1; then
    base64 -d
  else
    base64 -D
  fi
}

load_repository() {
  local error="$tmpdir/repository.err"
  if [[ -z "$REPO" ]]; then
    REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>"$error" || true)"
  fi
  [[ "$REPO" =~ ^[^/]+/[^/]+$ ]] || {
    echo "--repo OWNER/REPO is required or the current repository could not be detected" >&2
    if [[ -s "$error" ]]; then
      cat "$error" >&2
    fi
    exit 64
  }

  local repository="$tmpdir/repository.json"
  if ! api_get "repos/$REPO" "$repository" "$error"; then
    echo "cannot read repository $REPO: $(cat "$error")" >&2
    exit 69
  fi
  DEFAULT_BRANCH="$(jq -r '.default_branch // empty' "$repository")"
  if [[ -z "$BRANCH" ]]; then
    BRANCH="$DEFAULT_BRANCH"
    [[ -n "$BRANCH" ]] || BRANCH="main"
  fi
  [[ "$BRANCH" =~ ^[^[:space:]]+$ ]] || { echo "invalid branch name" >&2; exit 64; }
}

contents_get() {
  local path="$1" out="$2" error="$3"
  gh api --method GET "repos/$REPO/contents/$path" -f ref="$BRANCH" >"$out" 2>"$error"
}

remote_file_state() {
  local path="$1" out="$tmpdir/file-check-$RANDOM.json" error="$tmpdir/file-check-$RANDOM.err"
  if contents_get "$path" "$out" "$error"; then
    return 0
  fi
  if is_missing_error "$error"; then
    return 1
  fi
  return 2
}

remote_file_text() {
  local json="$1" out="$2"
  jq -e '.content and (.type == "file" or .type == null)' "$json" >/dev/null || return 1
  jq -r '.content' "$json" | tr -d '\n' | decode_base64 > "$out"
}

source_file_for() {
  local path="$1"
  jq -r --arg path "$path" '.bootstrap[] | select(.path == $path) | .source' "$MANIFEST"
}

marker_audit() {
  local entry path target error missing marker
  while IFS= read -r entry; do
    path="$(jq -r '.path' <<<"$entry")"
    target="$tmpdir/markers-$RANDOM.json"
    error="$target.err"
    if ! contents_get "$path" "$target" "$error"; then
      if is_missing_error "$error"; then
        record DRIFT markers "$path" "missing"
      else
        record "$(api_error_state "$(cat "$error")")" markers "$path" "cannot read target file"
      fi
      continue
    fi
    local text="$target.txt"
    if ! remote_file_text "$target" "$text"; then
      record UNVERIFIED markers "$path" "target is not a readable file"
      continue
    fi
    missing=()
    while IFS= read -r marker; do
      if [[ -z "$marker" ]]; then
        continue
      fi
      grep -Fq -- "$marker" "$text" || missing+=("$marker")
    done < <(jq -r '.markers[]' <<<"$entry")
    if [[ ${#missing[@]} -eq 0 ]]; then
      record PASS markers "$path" "required protocol markers present (mechanical baseline only)"
    else
      record DRIFT markers "$path" "missing markers: ${missing[*]}"
    fi
  done < <(jq -c '.protocol.markers[]' "$MANIFEST")
}

audit_label() {
  local labels="$tmpdir/labels.json" error="$tmpdir/labels.err"
  local name
  name="$(jq -r '.required_label.name' "$MANIFEST")"
  if ! api_get "repos/$REPO/labels?per_page=100" "$labels" "$error"; then
    record "$(api_error_state "$(cat "$error")")" live label "cannot read labels"
  elif jq -e --arg name "$name" '.[] | select(.name == $name)' "$labels" >/dev/null; then
    record PASS live label "$name exists"
  else
    record DRIFT live label "$name missing"
  fi
}

audit_reviewer_app() {
  local expected_id expected_actor
  expected_id="$(jq -r '.reviewer_app.id' "$MANIFEST")"
  expected_actor="$(jq -r '.reviewer_app.actor' "$MANIFEST")"
  if [[ "$REVIEWER_APP_VERIFIED" == true ]]; then
    record PASS live reviewer_app "Agent asserted external preflight: App $expected_id, actor $expected_actor, installation access to $REPO (this invocation only)"
  else
    record UNVERIFIED live reviewer_app "Agent must verify App $expected_id, actor $expected_actor, and installation access to $REPO externally, then pass --reviewer-app-verified"
  fi
}

ruleset_applies_to_branch() {
  local file="$1"
  # Only explicit refs and GitHub special selectors are resolved. Unknown
  # exclusion patterns fail closed; this is not a general pattern engine.
  jq -e --arg branch "$BRANCH" --arg default "$DEFAULT_BRANCH" '
    def matches_target:
      . == "~ALL" or (. == "~DEFAULT_BRANCH" and $branch == $default) or
      . == ("refs/heads/" + $branch) or . == $branch;
    def known_literal:
      type == "string" and
      (contains("*") or contains("?") or contains("[") or contains("\\") or startswith("~") | not);
    .target == "branch" and
    ((.conditions.ref_name.include // []) | any(matches_target)) and
    ((.conditions.ref_name.exclude // []) | all(
      (matches_target | not) and
      (known_literal or (. == "~DEFAULT_BRANCH" and $default != ""))
    ))
  ' "$file" >/dev/null
}

ruleset_governance_is_desired() {
  local file="$1"
  ruleset_applies_to_branch "$file" || return 1
  jq -e --arg name "$RULESET_NAME" --arg branch "$BRANCH" '
    .name == $name and
    .target == "branch" and
    .enforcement == "active" and
    ((.bypass_actors // []) | length == 0) and
    any(.rules[]?; .type == "deletion") and
    any(.rules[]?; .type == "non_fast_forward") and
    any(.rules[]?;
      .type == "pull_request" and
      ((.parameters.required_approving_review_count // 0) == 1) and
      (.parameters.dismiss_stale_reviews_on_push == true) and
      ((.parameters.require_last_push_approval // false) == false) and
      ((.parameters.allowed_merge_methods // []) == ["squash"])
    ) and
    ((.conditions.ref_name.include // []) | any(. == ("refs/heads/" + $branch)))
  ' "$file" >/dev/null
}

ruleset_check_is_desired() {
  local file="$1"
  jq -e --arg check "$REQUIRED_CHECK" '
    any(.rules[]?;
      .type == "required_status_checks" and
      ((.parameters.required_status_checks // []) | map(.context) == [$check])
    )
  ' "$file" >/dev/null
}

load_named_ruleset() {
  local list="$tmpdir/rulesets.json" list_error="$tmpdir/rulesets.err"
  local id detail detail_error
  RULESET_ID=""
  RULESET_FILE=""
  if ! api_get "repos/$REPO/rulesets?includes_parents=false" "$list" "$list_error"; then
    RULESET_ERROR="$list_error"
    return 1
  fi
  while IFS= read -r id; do
    if [[ -z "$id" ]]; then
      continue
    fi
    detail="$tmpdir/ruleset-$id.json"
    detail_error="$detail.err"
    if ! api_get "repos/$REPO/rulesets/$id" "$detail" "$detail_error"; then
      RULESET_ERROR="$detail_error"
      return 1
    fi
    if [[ "$(jq -r '.name // empty' "$detail")" == "$RULESET_NAME" ]]; then
      RULESET_ID="$id"
      RULESET_FILE="$detail"
      break
    fi
  done < <(jq -r '.[].id' "$list")
  return 0
}

audit_ruleset() {
  local detail
  if [[ "$PHASE" == "bootstrap" ]]; then
    record PASS live ruleset "bootstrap defers Ruleset activation"
    record PASS live required_check "bootstrap defers Required Check binding"
    return
  fi
  if [[ -z "$REQUIRED_CHECK" ]]; then
    record UNVERIFIED live required_check "active audit requires --required-check NAME"
  fi
  if ! load_named_ruleset; then
    record "$(api_error_state "$(cat "$RULESET_ERROR")")" live ruleset "cannot read Rulesets"
    return
  fi
  if [[ -z "$RULESET_FILE" ]]; then
    record DRIFT live ruleset "named Ruleset '$RULESET_NAME' is missing"
    if [[ -n "$REQUIRED_CHECK" ]]; then
      record DRIFT live required_check "$REQUIRED_CHECK is not bound because the named Ruleset is missing"
    fi
    return
  fi
  detail="$RULESET_FILE"
  if ! ruleset_applies_to_branch "$detail"; then
    record DRIFT live ruleset "named Ruleset '$RULESET_NAME' does not provably cover $BRANCH without exclusion"
  elif ruleset_governance_is_desired "$detail"; then
    record PASS live ruleset "PR, one approval, stale dismissal, squash-only, deletion/non-fast-forward block, and no bypass"
  else
    record DRIFT live ruleset "named Ruleset does not satisfy G-lite governance"
  fi
  if [[ -n "$REQUIRED_CHECK" ]]; then
    if ruleset_check_is_desired "$detail"; then
      record PASS live required_check "$REQUIRED_CHECK is required"
    else
      record DRIFT live required_check "$REQUIRED_CHECK is not required by the named Ruleset"
    fi
  fi
}

auditor() {
  : > "$RESULTS"
  marker_audit
  audit_label
  audit_reviewer_app
  RULESET_NAME="$(jq -r '.ruleset.name' "$MANIFEST")"
  audit_ruleset
  if [[ -s "$WRITE_RESULTS" ]]; then
    cat "$WRITE_RESULTS" >> "$RESULTS"
  fi
}

print_results() {
  printf 'STATE\tCATEGORY\tKEY\tDETAIL\n'
  cat "$RESULTS"
}

overall_exit() {
  if grep -Eq $'^(PLATFORM_BLOCKER|PERMISSION_BLOCKER|UNVERIFIED)\t' "$RESULTS"; then return 3; fi
  if grep -q $'^DRIFT\t' "$RESULTS"; then return 2; fi
  return 0
}

plan_from_results() {
  local state category key detail
  while IFS=$'\t' read -r state category key detail; do
    if [[ "$state" == "PASS" ]]; then
      continue
    fi
    case "$key" in
      AGENTS.md|.github/ISSUE_TEMPLATE/task.md|.github/pull_request_template.md)
        echo "PLAN: seed missing $key only; existing files require Agent-assisted semantic patch." ;;
      label) echo "PLAN: create the missing approved label; preserve other labels." ;;
      reviewer_app) echo "PLAN: have the Agent complete external Reviewer App preflight, then pass --reviewer-app-verified for this invocation; no credential manager is used." ;;
      ruleset) echo "PLAN: safely repair the named Ruleset without changing unrelated Rulesets." ;;
      required_check) echo "PLAN: provide the real successful Required Check name; never infer it from a workflow file." ;;
      *) echo "PLAN: $category/$key -> $detail" ;;
    esac
  done < "$RESULTS"
}

empty_repo_initial_write_allowed() {
  local repository="$tmpdir/initial-repository.json" facts="$tmpdir/initial-empty.json"
  local error="$tmpdir/initial-empty.err"
  # A missing file/branch, 404, or failed probe is not evidence of an empty repo.
  # Refresh before each write; never reuse the initial empty state after a commit.
  api_get "repos/$REPO" "$repository" "$error" || return 1
  jq -e --arg branch "$BRANCH" '.default_branch == $branch' "$repository" >/dev/null || return 1
  gh api graphql -f owner="${REPO%%/*}" -f name="${REPO#*/}" \
    -f query='query($owner:String!,$name:String!){repository(owner:$owner,name:$name){isEmpty}}' \
    >"$facts" 2>"$error" || return 1
  jq -e '(.errors // [] | length == 0) and .data.repository.isEmpty == true' "$facts" >/dev/null
}

bootstrap_file() {
  local path="$1" source source_file state error encoded
  source="$(source_file_for "$path")"
  source_file="$ROOT/$source"
  [[ -f "$source_file" ]] || { echo "bootstrap source missing: $source_file" >&2; return 1; }
  state=0
  if remote_file_state "$path"; then
    echo "BOOTSTRAP: preserved existing $path"
    return 0
  else
    state=$?
  fi
  if [[ "$state" -eq 2 ]]; then
    error="$tmpdir/bootstrap-check-$RANDOM.err"
    contents_get "$path" "$tmpdir/bootstrap-check-$RANDOM.json" "$error" || true
    echo "cannot inspect $REPO:$path: $(cat "$error")" >&2
    return 1
  fi
  encoded="$(encode_file "$source_file")"
  error="$tmpdir/bootstrap-upload-$RANDOM.err"
  local branch_args=(-f "branch=$BRANCH")
  if empty_repo_initial_write_allowed; then
    # Explicit first-commit initialization, never a retry after a PUT failure.
    branch_args=()
  fi
  if gh api --method PUT "repos/$REPO/contents/$path" \
    -f message="chore: bootstrap G-lite protocol baseline" \
    -f content="$encoded" ${branch_args[@]+"${branch_args[@]}"} >/dev/null 2>"$error"; then
    echo "BOOTSTRAP: seeded $path"
    return 0
  fi
  if remote_file_state "$path"; then
    echo "BOOTSTRAP: preserved $path after concurrent creation"
    return 0
  fi
  record_write_failure "$path" "$error"
  echo "cannot seed $REPO:$path: $(cat "$error")" >&2
  return 1
}

ensure_label() {
  local labels="$tmpdir/apply-labels.json" error="$tmpdir/apply-labels.err"
  local write_error="$tmpdir/apply-label-write.err"
  local name color description
  name="$(jq -r '.required_label.name' "$MANIFEST")"
  color="$(jq -r '.required_label.color' "$MANIFEST")"
  description="$(jq -r '.required_label.description' "$MANIFEST")"
  if ! api_get "repos/$REPO/labels?per_page=100" "$labels" "$error"; then
    echo "cannot inspect labels: $(cat "$error")" >&2
    return 1
  fi
  if jq -e --arg name "$name" '.[] | select(.name == $name)' "$labels" >/dev/null; then
    echo "APPLY: label $name already exists"
    return 0
  fi
  if gh api --method POST "repos/$REPO/labels" \
    -f name="$name" -f color="$color" -f description="$description" >/dev/null 2>"$error"; then
    echo "APPLY: created label $name"
    return 0
  fi
  cp "$error" "$write_error"
  if api_get "repos/$REPO/labels?per_page=100" "$labels" "$error" &&
    jq -e --arg name "$name" '.[] | select(.name == $name)' "$labels" >/dev/null; then
    echo "APPLY: label $name already exists"
    return 0
  fi
  record_write_failure label "$write_error"
  echo "cannot ensure label $name: $(cat "$write_error")" >&2
  return 1
}

make_ruleset_payload() {
  local current="$1" out="$2"
  if [[ -n "$current" && -f "$current" ]]; then
    jq --arg name "$RULESET_NAME" --arg branch "$BRANCH" --arg check "$REQUIRED_CHECK" '
      . as $current |
      ($current.rules // []) as $rules |
      ([{context:$check}]) as $checks |
      ([ $rules[]? | select(.type == "pull_request") | .parameters ] | first // {}) as $pr |
      ([ $rules[]? | select(.type == "required_status_checks") | .parameters ] | first // {}) as $status |
      {
        name: $name,
        target: "branch",
        enforcement: "active",
        bypass_actors: [],
        conditions: {ref_name: {include: ["refs/heads/" + $branch], exclude: []}},
        rules: (
          [$rules[]? | select(.type != "deletion" and .type != "non_fast_forward" and .type != "pull_request" and .type != "required_status_checks")]
          + [{type:"deletion"}]
          + [{type:"non_fast_forward"}]
          + [{type:"pull_request",parameters:($pr + {required_approving_review_count:1,dismiss_stale_reviews_on_push:true,require_last_push_approval:false,allowed_merge_methods:["squash"]})}]
          + [{type:"required_status_checks",parameters:($status + {strict_required_status_checks_policy:($status.strict_required_status_checks_policy // false),do_not_enforce_on_create:($status.do_not_enforce_on_create // false),required_status_checks:$checks})}]
        )
      }
    ' "$current" > "$out"
  else
    jq -n --arg name "$RULESET_NAME" --arg branch "$BRANCH" --arg check "$REQUIRED_CHECK" '{
      name:$name,
      target:"branch",
      enforcement:"active",
      bypass_actors:[],
      conditions:{ref_name:{include:["refs/heads/" + $branch],exclude:[]}},
      rules:[
        {type:"deletion"},
        {type:"non_fast_forward"},
        {type:"pull_request",parameters:{required_approving_review_count:1,dismiss_stale_reviews_on_push:true,require_last_push_approval:false,allowed_merge_methods:["squash"]}},
        {type:"required_status_checks",parameters:{strict_required_status_checks_policy:false,do_not_enforce_on_create:false,required_status_checks:[{context:$check}]}}
      ]
    }' > "$out"
  fi
}

ensure_ruleset() {
  RULESET_NAME="$(jq -r '.ruleset.name' "$MANIFEST")"
  if ! load_named_ruleset; then
    echo "cannot inspect Rulesets: $(cat "$RULESET_ERROR")" >&2
    return 1
  fi
  if [[ -n "$RULESET_FILE" ]] && ruleset_governance_is_desired "$RULESET_FILE" && ruleset_check_is_desired "$RULESET_FILE"; then
    echo "APPLY: Ruleset '$RULESET_NAME' already satisfies the target"
    return 0
  fi
  local payload="$tmpdir/ruleset-payload.json" error="$tmpdir/ruleset-write.err"
  make_ruleset_payload "$RULESET_FILE" "$payload"
  if [[ -n "$RULESET_ID" ]]; then
    if gh api --method PUT "repos/$REPO/rulesets/$RULESET_ID" --input "$payload" >/dev/null 2>"$error"; then
      echo "APPLY: repaired Ruleset '$RULESET_NAME' with Required Check '$REQUIRED_CHECK'"
      return 0
    fi
  else
    if gh api --method POST "repos/$REPO/rulesets" --input "$payload" >/dev/null 2>"$error"; then
      echo "APPLY: created Ruleset '$RULESET_NAME' with Required Check '$REQUIRED_CHECK'"
      return 0
    fi
  fi
  record_write_failure ruleset "$error"
  echo "cannot write Ruleset '$RULESET_NAME': $(cat "$error")" >&2
  return 1
}

run_bootstrap() {
  local entry path
  while IFS= read -r entry; do
    path="$(jq -r '.path' <<<"$entry")"
    bootstrap_file "$path" || true
  done < <(jq -c '.bootstrap[]' "$MANIFEST")
  ensure_label || true
  auditor
  print_results
  overall_exit || return $?
}

run_activate() {
  ensure_ruleset || true
  auditor
  print_results
  overall_exit || return $?
}

run_apply() {
  local original_phase="$PHASE"
  PHASE="bootstrap"
  run_bootstrap || true
  PHASE="$original_phase"
  if [[ -n "$REQUIRED_CHECK" ]]; then
    ensure_ruleset || true
  fi
  auditor
  print_results
  overall_exit || return $?
}

run_upgrade() {
  auditor
  print_results
  echo
  echo "UPGRADE REVIEW (read-only)"
  plan_from_results
  echo "No consumer files, labels, Rulesets, workflows, commits, or pull requests were changed."
  overall_exit || return $?
}

bootstrap_target_self_test() (
  # Isolated mock boundary: exercise real bootstrap_file without GitHub writes.
  local scenario mock_empty=true mock_default=main mock_probe=ok mock_write=ok
  local calls="$tmpdir/bootstrap-calls" mock_exists=false mock_concurrent=false
  local mock_metadata=ok
  REPO="self-test/fixture"
  BRANCH="main"
  remote_file_state() { [[ "$mock_exists" == true ]]; }
  api_get() {
    [[ "$mock_metadata" == ok ]] || return 1
    jq -n --arg branch "$mock_default" '{default_branch:$branch}' > "$2"
  }
  gh() {
    if [[ "$1 $2" == "api graphql" ]]; then
      case "$mock_probe" in
        ok) jq -n --argjson empty "$mock_empty" '{data:{repository:{isEmpty:$empty}}}' ;;
        unknown) printf '{"data":{"repository":null}}\n' ;;
        *) printf 'HTTP %s\n' "$mock_probe" >&2; return 1 ;;
      esac
      return
    fi
    [[ "$1 $2 $3" == "api --method PUT" ]] || return 99
    local arg target="<initial-default>"
    for arg in "$@"; do
      case "$arg" in branch=*) target="${arg#branch=}" ;; esac
    done
    printf '%s\n' "$target" >> "$calls"
    if [[ "$mock_write" != ok ]]; then
      [[ "$mock_concurrent" != true ]] || mock_exists=true
      printf 'HTTP 403 Forbidden\n' >&2
      return 1
    fi
    mock_empty=false
  }

  : > "$calls"
  bootstrap_file AGENTS.md >/dev/null
  bootstrap_file .github/ISSUE_TEMPLATE/task.md >/dev/null
  [[ "$(cat "$calls")" == $'<initial-default>\nmain' ]] || {
    echo "self-test failed: only the first proven-empty write may omit branch" >&2; return 1;
  }

  for scenario in nonempty unknown 403 404 different-default metadata-failure; do
    mock_empty=true mock_default=main mock_probe=ok mock_metadata=ok
    case "$scenario" in
      nonempty) mock_empty=false ;;
      unknown|403|404) mock_probe="$scenario" ;;
      different-default) mock_default=develop ;;
      metadata-failure) mock_metadata=failed ;;
    esac
    : > "$calls"
    bootstrap_file AGENTS.md >/dev/null
    [[ "$(cat "$calls")" == main ]] || {
      echo "self-test failed: $scenario must retain the explicit target" >&2; return 1;
    }
  done

  mock_metadata=ok mock_default=main mock_probe=ok mock_write=fail
  for mock_empty in false true; do
    : > "$calls"
    : > "$WRITE_RESULTS"
    if bootstrap_file AGENTS.md > /dev/null 2> "$tmpdir/bootstrap-test.err"; then
      echo "self-test failed: denied bootstrap was accepted" >&2; return 1
    fi
    [[ "$(wc -l < "$calls" | tr -d ' ')" == 1 ]] || {
      echo "self-test failed: failed PUT was retried" >&2; return 1;
    }
    grep -q $'^PERMISSION_BLOCKER\twrite\tAGENTS.md\t' "$WRITE_RESULTS" || return 1
  done
  # An existing file is preserved, including concurrent same-target creation.
  : > "$calls"
  : > "$WRITE_RESULTS"
  mock_empty=false mock_concurrent=true
  bootstrap_file AGENTS.md >/dev/null
  bootstrap_file AGENTS.md >/dev/null
  [[ "$(cat "$calls")" == main && ! -s "$WRITE_RESULTS" ]] || return 1
  echo "self-test: empty-repo-only initial write / same target or fail: PASS"
)

run_self_test() {
  local fixture="$tmpdir/ruleset.json" mutated="$tmpdir/ruleset-mutated.json"
  local permission_error="$tmpdir/permission.err" platform_error="$tmpdir/platform.err"
  local reviewer_exit=0
  # Isolate the assertion from unrelated audit results; never contact GitHub.
  REPO="self-test/fixture"
  REVIEWER_APP_VERIFIED=false
  audit_reviewer_app
  overall_exit || reviewer_exit=$?
  if [[ "$reviewer_exit" -ne 3 ]] || ! grep -q $'^UNVERIFIED\tlive\treviewer_app\t' "$RESULTS"; then
    echo "self-test failed: missing Reviewer App assertion must be UNVERIFIED / exit 3" >&2
    return 1
  fi
  : > "$RESULTS"
  REVIEWER_APP_VERIFIED=true
  audit_reviewer_app
  reviewer_exit=0
  overall_exit || reviewer_exit=$?
  if [[ "$reviewer_exit" -ne 0 ]] || ! grep -q $'^PASS\tlive\treviewer_app\t' "$RESULTS"; then
    echo "self-test failed: Reviewer App assertion must be PASS / exit 0" >&2
    return 1
  fi
  : > "$RESULTS"
  REVIEWER_APP_VERIFIED=false
  audit_reviewer_app
  reviewer_exit=0
  overall_exit || reviewer_exit=$?
  if [[ "$reviewer_exit" -ne 3 ]]; then
    echo "self-test failed: Reviewer App assertion must not persist" >&2
    return 1
  fi
  : > "$RESULTS"
  echo "self-test: Reviewer App assertion absent => UNVERIFIED / exit 3; present => PASS / exit 0"
  RULESET_NAME="G-lite main"
  BRANCH="main"
  DEFAULT_BRANCH="main"
  REQUIRED_CHECK="new-check"
  cat > "$fixture" <<'JSON'
{"name":"G-lite main","target":"branch","enforcement":"active","bypass_actors":[],"conditions":{"ref_name":{"include":["refs/heads/main"]}},"rules":[{"type":"deletion"},{"type":"non_fast_forward"},{"type":"pull_request","parameters":{"required_approving_review_count":1,"dismiss_stale_reviews_on_push":true,"require_last_push_approval":false,"allowed_merge_methods":["squash"]}},{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"old-check"}]}}]}
JSON
  ruleset_governance_is_desired "$fixture"
  local exclusion
  for exclusion in refs/heads/main main '~ALL' '~DEFAULT_BRANCH' 'refs/heads/*' 'refs/heads/m*'; do
    jq --arg exclusion "$exclusion" '.conditions.ref_name.exclude = [$exclusion]' "$fixture" > "$mutated"
    if ruleset_applies_to_branch "$mutated" || ruleset_governance_is_desired "$mutated"; then
      echo "self-test failed: exclusion $exclusion was accepted" >&2
      return 1
    fi
  done
  jq '.conditions.ref_name.exclude = ["refs/heads/develop"]' "$fixture" > "$mutated"
  ruleset_governance_is_desired "$mutated"
  jq '.conditions.ref_name.include = ["~DEFAULT_BRANCH"]' "$fixture" > "$mutated"
  ruleset_applies_to_branch "$mutated"
  DEFAULT_BRANCH="develop"
  if ruleset_applies_to_branch "$mutated"; then
    echo "self-test failed: default-branch selector accepted a non-default target" >&2
    return 1
  fi
  DEFAULT_BRANCH="main"
  echo "self-test: include main + exclude main => not desired; exclude negative tests: PASS"
  bootstrap_target_self_test
  make_ruleset_payload "$fixture" "$tmpdir/payload-existing.json"
  if ! jq -e '
    [.rules[]? | select(.type == "required_status_checks") | .parameters.required_status_checks[]?.context] == ["new-check"]
  ' "$tmpdir/payload-existing.json" >/dev/null; then
    echo "self-test failed: new Required Check was not the sole target" >&2
    return 1
  fi
  if jq -e '.rules[]? | select(.type == "required_status_checks") | .parameters.required_status_checks[]?.context == "old-check"' "$tmpdir/payload-existing.json" >/dev/null; then
    echo "self-test failed: stale Required Check survived replacement" >&2
    return 1
  fi
  ruleset_check_is_desired "$tmpdir/payload-existing.json"
  make_ruleset_payload "" "$tmpdir/payload-new.json"
  ruleset_check_is_desired "$tmpdir/payload-new.json"
  jq '.rules |= map(if .type == "required_status_checks" then .parameters.required_status_checks = [] else . end)' "$fixture" > "$mutated"
  if ruleset_check_is_desired "$mutated"; then
    echo "self-test failed: missing Required Check was accepted" >&2
    return 1
  fi

  printf 'HTTP 403 Forbidden\n' > "$permission_error"
  record_write_failure simulated "$permission_error"
  if ! grep -q $'^PERMISSION_BLOCKER\twrite\tsimulated\t' "$WRITE_RESULTS"; then
    echo "self-test failed: HTTP 403 was not a PERMISSION_BLOCKER" >&2
    return 1
  fi
  printf 'feature is not available for private repositories\n' > "$platform_error"
  record_write_failure simulated-platform "$platform_error"
  if ! grep -q $'^PLATFORM_BLOCKER\twrite\tsimulated-platform\t' "$WRITE_RESULTS"; then
    echo "self-test failed: platform write failure was not a PLATFORM_BLOCKER" >&2
    return 1
  fi
  echo "self-test: PASS"
}

if [[ "$ACTION" == "self-test" ]]; then
  run_self_test
  exit $?
fi

load_repository
case "$ACTION" in
  audit)
    auditor
    print_results
    overall_exit || exit $?
    ;;
  plan)
    auditor
    print_results
    echo
    plan_from_results
    overall_exit || exit $?
    ;;
  bootstrap)
    run_bootstrap
    ;;
  activate)
    run_activate
    ;;
  apply)
    run_apply
    ;;
  upgrade)
    run_upgrade
    ;;
esac
