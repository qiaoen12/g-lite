# Read-only repository, label, App, and Ruleset audits.

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

audit_apps() {
  local role verified
  for role in developer reviewer; do
    case "$role" in
      developer) verified="$DEVELOPER_APP_VERIFIED" ;;
      reviewer) verified="$REVIEWER_APP_VERIFIED" ;;
    esac
    if [[ "$verified" == true ]]; then
      record PASS live "${role}_app" "Agent asserted external $role App identity, independence, and installation access to $REPO (this invocation only; consumer binding)"
    else
      record UNVERIFIED live "${role}_app" "Agent must verify the consumer $role App identity, independence, and installation access to $REPO externally, then pass --${role}-app-verified"
    fi
  done
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
      (.parameters.require_code_owner_review == false) and
      ((.parameters.require_last_push_approval // false) == false) and
      (.parameters.required_review_thread_resolution == false) and
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
      record DRIFT live required_check "Required Check configuration does not exactly match target '$REQUIRED_CHECK'"
    fi
  fi
}

auditor() {
  : > "$RESULTS"
  marker_audit
  audit_label
  audit_apps
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
      developer_app|reviewer_app) echo "PLAN: complete external consumer ${key%_app} App identity, independence, and installation preflight, then pass --${key%_app}-app-verified for this invocation; no credential manager is used." ;;
      ruleset) echo "PLAN: safely repair the named Ruleset without changing unrelated Rulesets." ;;
      required_check) echo "PLAN: provide the real successful Required Check name; never infer it from a workflow file." ;;
      *) echo "PLAN: $category/$key -> $detail" ;;
    esac
  done < "$RESULTS"
}
