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
REQUIRED_CHECK=""
PHASE="active"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="${2:?missing --repo value}"; shift 2 ;;
    --branch) BRANCH="${2:?missing --branch value}"; shift 2 ;;
    --phase) PHASE="${2:?missing --phase value}"; shift 2 ;;
    --required-check) REQUIRED_CHECK="${2:?missing --required-check value}"; shift 2 ;;
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
  (.protocol.semantic | length == 3) and
  (([.bootstrap[].path, .protocol.semantic[].path] | index("README.md")) == null) and
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
: > "$RESULTS"

record() {
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$RESULTS"
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
  if [[ -z "$BRANCH" ]]; then
    BRANCH="$(jq -r '.default_branch // empty' "$repository")"
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

semantic_audit() {
  local entry path target error missing marker
  while IFS= read -r entry; do
    path="$(jq -r '.path' <<<"$entry")"
    target="$tmpdir/semantic-$RANDOM.json"
    error="$target.err"
    if ! contents_get "$path" "$target" "$error"; then
      if is_missing_error "$error"; then
        record DRIFT semantic "$path" "missing"
      else
        record "$(api_error_state "$(cat "$error")")" semantic "$path" "cannot read target file"
      fi
      continue
    fi
    local text="$target.txt"
    if ! remote_file_text "$target" "$text"; then
      record UNVERIFIED semantic "$path" "target is not a readable file"
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
      record PASS semantic "$path" "required protocol semantics present"
    else
      record DRIFT semantic "$path" "missing markers: ${missing[*]}"
    fi
  done < <(jq -c '.protocol.semantic[]' "$MANIFEST")
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
  local installation="$tmpdir/installation.json" error="$tmpdir/installation.err"
  local expected_slug expected_id expected_actor actual_slug actual_id
  expected_slug="$(jq -r '.reviewer_app.slug' "$MANIFEST")"
  expected_id="$(jq -r '.reviewer_app.id' "$MANIFEST")"
  expected_actor="$(jq -r '.reviewer_app.actor' "$MANIFEST")"
  if api_get "repos/$REPO/installation" "$installation" "$error"; then
    actual_slug="$(jq -r '.app_slug // empty' "$installation")"
    actual_id="$(jq -r '.app_id // empty' "$installation")"
    if [[ "$actual_slug" == "$expected_slug" && "$actual_id" == "$expected_id" ]]; then
      record PASS live reviewer_app "installation exposes expected actor $expected_actor"
    else
      record DRIFT live reviewer_app "expected $expected_slug/$expected_id, found ${actual_slug:-unknown}/${actual_id:-unknown}"
    fi
  else
    record UNVERIFIED live reviewer_app "cannot verify $expected_actor installation with current GitHub visibility"
  fi
}

ruleset_applies_to_branch() {
  local file="$1"
  jq -e --arg branch "$BRANCH" '
    .target == "branch" and
    ((.conditions.ref_name.include // []) | any(
      . == "~ALL" or . == "~DEFAULT_BRANCH" or
      . == ("refs/heads/" + $branch) or . == $branch
    ))
  ' "$file" >/dev/null
}

ruleset_governance_is_desired() {
  local file="$1"
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
      any(.parameters.required_status_checks[]?; .context == $check)
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
    record DRIFT live ruleset "named Ruleset '$RULESET_NAME' does not apply to $BRANCH"
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
  semantic_audit
  audit_label
  audit_reviewer_app
  RULESET_NAME="$(jq -r '.ruleset.name' "$MANIFEST")"
  audit_ruleset
}

print_results() {
  printf 'STATE\tCATEGORY\tKEY\tDETAIL\n'
  cat "$RESULTS"
}

overall_exit() {
  if grep -q $'^DRIFT\t' "$RESULTS"; then return 2; fi
  if grep -Eq $'^(PLATFORM_BLOCKER|PERMISSION_BLOCKER|UNVERIFIED)\t' "$RESULTS"; then return 3; fi
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
      reviewer_app) echo "PLAN: have the Agent verify the expected Reviewer App installation; no credential manager is used." ;;
      ruleset) echo "PLAN: safely repair the named Ruleset without changing unrelated Rulesets." ;;
      required_check) echo "PLAN: provide the real successful Required Check name; never infer it from a workflow file." ;;
      *) echo "PLAN: $category/$key -> $detail" ;;
    esac
  done < "$RESULTS"
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
  if gh api --method PUT "repos/$REPO/contents/$path" \
    -f message="chore: bootstrap G-lite protocol baseline" \
    -f content="$encoded" -f branch="$BRANCH" >/dev/null 2>"$error"; then
    echo "BOOTSTRAP: seeded $path"
    return 0
  fi
  if gh api --method PUT "repos/$REPO/contents/$path" \
    -f message="chore: bootstrap G-lite protocol baseline" \
    -f content="$encoded" >/dev/null 2>"$error"; then
    echo "BOOTSTRAP: seeded $path"
    return 0
  fi
  if remote_file_state "$path"; then
    echo "BOOTSTRAP: preserved $path after concurrent creation"
    return 0
  fi
  echo "cannot seed $REPO:$path: $(cat "$error")" >&2
  return 1
}

ensure_label() {
  local labels="$tmpdir/apply-labels.json" error="$tmpdir/apply-labels.err"
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
  if api_get "repos/$REPO/labels?per_page=100" "$labels" "$error" &&
    jq -e --arg name "$name" '.[] | select(.name == $name)' "$labels" >/dev/null; then
    echo "APPLY: label $name already exists"
    return 0
  fi
  echo "cannot ensure label $name: $(cat "$error")" >&2
  return 1
}

check_success_for_branch() {
  local sha="$tmpdir/branch-sha" sha_error="$tmpdir/branch-sha.err"
  local checks="$tmpdir/checks.json" checks_error="$tmpdir/checks.err"
  local status="$tmpdir/status.json" status_error="$tmpdir/status.err"
  if ! api_get "repos/$REPO/commits/$BRANCH" "$sha" "$sha_error"; then
    echo "UNVERIFIED: cannot resolve $REPO/$BRANCH" >&2
    return 1
  fi
  sha="$(jq -r '.sha // empty' "$sha")"
  [[ -n "$sha" ]] || { echo "UNVERIFIED: branch has no commit SHA" >&2; return 1; }
  if api_get "repos/$REPO/commits/$sha/check-runs?per_page=100" "$checks" "$checks_error" &&
    jq -e --arg check "$REQUIRED_CHECK" '.check_runs[]? | select(.name == $check and .conclusion == "success")' "$checks" >/dev/null; then
    return 0
  fi
  if api_get "repos/$REPO/commits/$sha/status" "$status" "$status_error" &&
    jq -e --arg check "$REQUIRED_CHECK" '.statuses[]? | select(.context == $check and .state == "success")' "$status" >/dev/null; then
    return 0
  fi
  echo "UNVERIFIED: no real SUCCESS for '$REQUIRED_CHECK' on $REPO/$BRANCH" >&2
  return 1
}

make_ruleset_payload() {
  local current="$1" out="$2"
  if [[ -n "$current" && -f "$current" ]]; then
    jq --arg name "$RULESET_NAME" --arg branch "$BRANCH" --arg check "$REQUIRED_CHECK" '
      . as $current |
      ($current.rules // []) as $rules |
      ([ $rules[]? | select(.type == "required_status_checks") | .parameters.required_status_checks[]? ] + [{context:$check}])
      | unique_by(.context) as $checks |
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
  if ! check_success_for_branch; then
    return 1
  fi
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

run_self_test() {
  local fixture="$tmpdir/ruleset.json" mutated="$tmpdir/ruleset-mutated.json"
  RULESET_NAME="G-lite main"
  BRANCH="main"
  REQUIRED_CHECK="stable-check"
  cat > "$fixture" <<'JSON'
{"name":"G-lite main","target":"branch","enforcement":"active","bypass_actors":[],"conditions":{"ref_name":{"include":["refs/heads/main"]}},"rules":[{"type":"deletion"},{"type":"non_fast_forward"},{"type":"pull_request","parameters":{"required_approving_review_count":1,"dismiss_stale_reviews_on_push":true,"require_last_push_approval":false,"allowed_merge_methods":["squash"]}},{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"stable-check"}]}}]}
JSON
  ruleset_governance_is_desired "$fixture"
  ruleset_check_is_desired "$fixture"
  make_ruleset_payload "$fixture" "$tmpdir/payload-existing.json"
  jq -e '.rules | any(.[]; .type == "required_status_checks" and any(.parameters.required_status_checks[]; .context == "stable-check"))' "$tmpdir/payload-existing.json" >/dev/null
  make_ruleset_payload "" "$tmpdir/payload-new.json"
  jq -e '.rules | any(.[]; .type == "required_status_checks")' "$tmpdir/payload-new.json" >/dev/null
  jq '.rules |= map(if .type == "required_status_checks" then .parameters.required_status_checks = [] else . end)' "$fixture" > "$mutated"
  if ruleset_check_is_desired "$mutated"; then
    echo "self-test failed: missing Required Check was accepted" >&2
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
