# Read-only repository, label, App, Ruleset, and security audits.

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
      [[ -z "$marker" ]] && continue
      grep -Fq -- "$marker" "$text" || missing+=("$marker")
    done < <(jq -r '.markers[]' <<<"$entry")
    if [[ ${#missing[@]} -eq 0 ]]; then
      record PASS markers "$path" "required protocol markers present (mechanical baseline only)"
    else
      record DRIFT markers "$path" "missing markers: ${missing[*]}"
    fi
  done < <(jq -c '.protocol.markers[]' "$MANIFEST")
}

label_inventory_is_readable() {
  jq -e 'type == "array" and all(.[]; (.name | type) == "string")' "$1" >/dev/null 2>&1
}

label_candidates() {
  jq --slurpfile manifest "$MANIFEST" '
    ($manifest[0].required_label) as $desired |
    [.[] | select(.name as $actual |
      (($actual | ascii_downcase) == ($desired.name | ascii_downcase)) or
      any($desired.legacy_names[]?; . == $actual))]
  ' "$1"
}

label_metadata_is_desired() {
  local labels="$1"
  label_candidates "$labels" | jq -e --arg name "$(jq -r '.required_label.name' "$MANIFEST")" \
    --arg color "$(jq -r '.required_label.color' "$MANIFEST")" \
    --arg description "$(jq -r '.required_label.description' "$MANIFEST")" '
      length == 1 and
      .[0].name == $name and
      .[0].color == $color and
      .[0].description == $description
    ' >/dev/null
}

audit_label() {
  local labels="$tmpdir/labels.json" error="$tmpdir/labels.err"
  local name
  name="$(jq -r '.required_label.name' "$MANIFEST")"
  if ! api_get "repos/$REPO/labels?per_page=100" "$labels" "$error"; then
    record "$(api_error_state "$(cat "$error")")" live label "cannot read labels"
  elif ! label_inventory_is_readable "$labels"; then
    record UNVERIFIED live label "GitHub returned an invalid label inventory"
  elif label_metadata_is_desired "$labels"; then
    record PASS live label "$name name/color/description match canonical metadata"
  elif [[ "$(label_candidates "$labels" | jq 'length')" -gt 1 ]]; then
    record DRIFT live label "multiple G-lite-owned equivalent labels; refusing ambiguous migration"
  elif [[ "$(label_candidates "$labels" | jq 'length')" -eq 1 ]]; then
    record DRIFT live label "G-lite-owned label must converge to exact '$name' name/color/description"
  else
    record DRIFT live label "$name missing"
  fi
}

repository_settings_are_desired() {
  local repository="$1"
  jq -e --slurpfile manifest "$MANIFEST" '
    . as $repository |
    ($manifest[0].repository_settings | to_entries) as $desired |
    all($desired[]; $repository[.key] == .value)
  ' "$repository" >/dev/null
}

audit_repository_settings() {
  local error="$tmpdir/repository-audit.err"
  REPOSITORY_FILE="$tmpdir/repository-audit.json"
  if ! api_get "repos/$REPO" "$REPOSITORY_FILE" "$error"; then
    record "$(api_error_state "$(cat "$error")")" live repository_settings "cannot read repository settings"
    REPOSITORY_FILE=""
    return
  fi
  if repository_settings_are_desired "$REPOSITORY_FILE"; then
    record PASS live repository_settings "G-lite-owned merge settings match canonical values"
  else
    record DRIFT live repository_settings "G-lite-owned merge settings differ from canonical values"
  fi
}

audit_security() {
  local key status error
  if [[ -z "${REPOSITORY_FILE:-}" || ! -f "$REPOSITORY_FILE" ]]; then
    error="$tmpdir/security-audit.err"
    REPOSITORY_FILE="$tmpdir/security-audit.json"
    if ! api_get "repos/$REPO" "$REPOSITORY_FILE" "$error"; then
      record "$(api_error_state "$(cat "$error")")" live security_and_analysis "cannot read security settings"
      return
    fi
  fi
  for key in secret_scanning secret_scanning_push_protection; do
    status="$(jq -r --arg key "$key" '.security_and_analysis[$key].status // "unavailable_to_read"' "$REPOSITORY_FILE")"
    case "$status" in
      enabled)
        record PASS live "$key" "enabled"
        ;;
      disabled)
        record DRIFT live "$key" "disabled; canonical state is enabled"
        ;;
      not_available|unavailable)
        record PLATFORM_BLOCKER live "$key" "GitHub reports this security capability is not available"
        ;;
      *)
        record UNVERIFIED live "$key" "GitHub did not expose a supported status"
        ;;
    esac
  done
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

ruleset_may_overlap_branch() {
  local file="$1"
  jq -e --arg branch "$BRANCH" --arg default "$DEFAULT_BRANCH" '
    def target_ref:
      . == "~ALL" or (. == "~DEFAULT_BRANCH" and $branch == $default) or
      . == ("refs/heads/" + $branch) or . == $branch;
    def clearly_other_ref:
      if type != "string" then false
      elif . == "~DEFAULT_BRANCH" and $branch != $default then true
      else (target_ref | not) and
        ((contains("*") or contains("?") or contains("[") or contains("\\") or startswith("~")) | not)
      end;
    if .target == "branch" then
      (.conditions.ref_name.include // []) as $include |
      (.conditions.ref_name.exclude // []) as $exclude |
      if ($include | type) != "array" or ($exclude | type) != "array" then true
      else (($include | length) == 0 or any($include[]; clearly_other_ref | not)) and
        (any($exclude[]; target_ref) | not) end
    elif .target == "tag" or .target == "push" then false
    else true end
  ' "$file" >/dev/null
}

ruleset_scope_is_migratable() {
  local file="$1"
  jq -e --arg branch "$BRANCH" --arg default "$DEFAULT_BRANCH" '
    (.conditions.ref_name.include // []) as $include |
    ($include == ["refs/heads/" + $branch]) or
    ($include == [$branch]) or
    ($branch == $default and $include == ["~DEFAULT_BRANCH"])
  ' "$file" >/dev/null
}

ruleset_is_g_lite_owned() {
  local file="$1"
  jq -e --slurpfile manifest "$MANIFEST" '
    .name as $actual | $manifest[0].ruleset as $desired |
    (.source_type == null or .source_type == "Repository") and
    ($actual == $desired.name or any($desired.legacy_names[]?; . == $actual))
  ' "$file" >/dev/null
}

ruleset_governance_semantics_are_desired() {
  local file="$1"
  jq -e --arg branch "$BRANCH" --slurpfile manifest "$MANIFEST" '
    . as $actual |
    $manifest[0].ruleset as $desired |
    ($actual.conditions.ref_name.include // []) == ["refs/heads/" + $branch] and
    ($actual.conditions.ref_name.exclude // []) == [] and
    $actual.target == "branch" and
    $actual.enforcement == "active" and
    (($actual.bypass_actors // []) == []) and
    ([ $actual.rules[]? | select(.type == "deletion") ] | length) == (if $desired.block_deletions then 1 else 0 end) and
    ([ $actual.rules[]? | select(.type == "non_fast_forward") ] | length) == (if $desired.block_non_fast_forward then 1 else 0 end) and
    ([ $actual.rules[]? | select(.type == "pull_request") ] | length) == 1 and
    ([ $actual.rules[]? | select(.type == "pull_request") | .parameters ][0]) as $parameters |
    {
      required_approving_review_count: $desired.required_approvals,
      dismiss_stale_reviews_on_push: $desired.dismiss_stale_reviews_on_push,
      require_code_owner_review: $desired.require_code_owner_review,
      require_last_push_approval: $desired.require_last_push_approval,
      required_review_thread_resolution: $desired.required_review_thread_resolution,
      allowed_merge_methods: $desired.allowed_merge_methods
    } as $owned |
    ($parameters | type) == "object" and
    ($parameters | with_entries(select(.key as $key | $owned | has($key)))) == $owned
  ' "$file" >/dev/null
}

ruleset_pr_parameters_safe_for_write() {
  local file="$1"
  # A PUT rebuilds the PR rule; only these GitHub-normalized additions can be dropped safely.
  jq -e '
    ["required_approving_review_count", "dismiss_stale_reviews_on_push",
     "require_code_owner_review", "require_last_push_approval",
     "required_review_thread_resolution", "allowed_merge_methods"] as $owned |
    all(.rules[]? | select(.type == "pull_request") | .parameters;
      type == "object" and all(to_entries[];
        .key as $key | .value as $value |
        if ($owned | index($key)) != null then true
        elif $key == "require_extra_approval_for_unattributed_changes" then $value == true
        elif $key == "required_reviewers" then $value == []
        else false end))
  ' "$file" >/dev/null
}

ruleset_governance_is_desired() {
  local file="$1"
  ruleset_governance_semantics_are_desired "$file" || return 1
  jq -e --arg name "$RULESET_NAME" '.name == $name' "$file" >/dev/null
}

ruleset_has_no_required_check() {
  local file="$1"
  jq -e '[.rules[]? | select(.type == "required_status_checks")] | length == 0' "$file" >/dev/null
}

ruleset_check_is_desired() {
  local file="$1"
  [[ -n "$REQUIRED_CHECK" ]] || return 1
  jq -e --arg check "$REQUIRED_CHECK" --slurpfile manifest "$MANIFEST" '
    [ .rules[]? | select(.type == "required_status_checks") ] as $rules |
    ($manifest[0].ruleset) as $desired |
    ($rules | length) == 1 and
    (($rules[0].parameters.required_status_checks // []) | map(.context) == [$check]) and
    ($rules[0].parameters.strict_required_status_checks_policy == $desired.strict_required_status_checks_policy) and
    ($rules[0].parameters.do_not_enforce_on_create == $desired.do_not_enforce_on_create)
  ' "$file" >/dev/null
}

load_named_ruleset() {
  local list="$tmpdir/rulesets.json" list_error="$tmpdir/rulesets.err"
  local id detail detail_error index source_type
  RULESET_ID=""
  RULESET_FILE=""
  RULESET_ERROR=""
  RULESET_IDS=()
  RULESET_FILES=()
  RULESET_UNSAFE_IDS=()
  RULESET_UNSAFE_FILES=()
  RULESET_CONFLICT_IDS=()
  RULESET_CONFLICT_FILES=()
  RULESET_MERGED_FILE="$tmpdir/ruleset-extras.json"
  if ! api_get "repos/$REPO/rulesets?includes_parents=true&per_page=100" "$list" "$list_error"; then
    RULESET_ERROR="$list_error"
    return 1
  fi
  if ! jq -e 'type == "array" and all(.[]; (.id | type) == "number") and
      ((map(.id) | unique | length) == length)' "$list" >/dev/null 2>&1; then
    printf 'invalid Ruleset enumeration\n' > "$list_error"
    RULESET_ERROR="$list_error"
    return 1
  fi
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    detail="$tmpdir/ruleset-$id.json"
    detail_error="$detail.err"
    if ! api_get "repos/$REPO/rulesets/$id" "$detail" "$detail_error"; then
      RULESET_ERROR="$detail_error"
      return 1
    fi
    if ! jq -e --arg id "$id" 'type == "object" and (.id | tostring) == $id and
        (.name | type) == "string" and (.target | type) == "string"' "$detail" >/dev/null 2>&1; then
      printf 'invalid Ruleset detail for id %s\n' "$id" > "$detail_error"
      RULESET_ERROR="$detail_error"
      return 1
    fi
    if ! ruleset_may_overlap_branch "$detail"; then
      continue
    fi
    source_type="$(jq -r --argjson id "$id" '.[] | select(.id == $id) | .source_type // empty' "$list")"
    if [[ -n "$source_type" && "$source_type" != Repository ]] || ! ruleset_is_g_lite_owned "$detail"; then
      RULESET_CONFLICT_IDS+=("$id")
      RULESET_CONFLICT_FILES+=("$detail")
      continue
    fi
    if ruleset_scope_is_migratable "$detail"; then
      RULESET_IDS+=("$id")
      RULESET_FILES+=("$detail")
    else
      RULESET_UNSAFE_IDS+=("$id")
      RULESET_UNSAFE_FILES+=("$detail")
    fi
  done < <(jq -r 'sort_by(.id) | .[].id' "$list")

  for index in "${!RULESET_IDS[@]}"; do
    if [[ "$(jq -r '.name // empty' "${RULESET_FILES[$index]}")" == "$RULESET_NAME" ]]; then
      RULESET_ID="${RULESET_IDS[$index]}"
      RULESET_FILE="${RULESET_FILES[$index]}"
      break
    fi
  done
  if [[ -z "$RULESET_FILE" && ${#RULESET_IDS[@]} -gt 0 ]]; then
    RULESET_ID="${RULESET_IDS[0]}"
    RULESET_FILE="${RULESET_FILES[0]}"
  fi
  if [[ ${#RULESET_FILES[@]} -gt 0 ]]; then
    jq -s '
      [ .[] | .rules[]? |
        select(.type != "deletion" and .type != "non_fast_forward" and
          .type != "pull_request" and .type != "required_status_checks")
      ] | unique
    ' "${RULESET_FILES[@]}" > "$RULESET_MERGED_FILE"
  else
    printf '[]\n' > "$RULESET_MERGED_FILE"
  fi
  return 0
}

audit_ruleset() {
  local blocked=false
  RULESET_NAME="$(jq -r '.ruleset.name' "$MANIFEST")"
  if ! load_named_ruleset; then
    record "$(api_error_state "$(cat "$RULESET_ERROR")")" live ruleset "cannot read Rulesets"
    return
  fi
  if [[ ${#RULESET_UNSAFE_IDS[@]} -gt 0 ]]; then
    record DRIFT live ruleset "a G-lite Ruleset also governs other refs and cannot be narrowed safely"
    blocked=true
  fi
  if [[ ${#RULESET_CONFLICT_IDS[@]} -gt 0 ]]; then
    record DRIFT live ruleset "an unrecognized Ruleset may overlap $BRANCH; ownership is unclear and migration is blocked"
    blocked=true
  fi
  if [[ ${#RULESET_IDS[@]} -eq 0 ]]; then
    record DRIFT live ruleset "canonical G-lite Ruleset '$RULESET_NAME' is missing"
    if [[ "$PHASE" != bootstrap ]]; then
      if [[ -n "$REQUIRED_CHECK" ]]; then
        record DRIFT live required_check "$REQUIRED_CHECK is not bound because the G-lite Ruleset is missing"
      else
        record UNVERIFIED live required_check "active audit requires --required-check NAME"
      fi
    fi
    return
  fi
  if [[ ${#RULESET_IDS[@]} -gt 1 ]]; then
    record DRIFT live ruleset "multiple G-lite-owned Rulesets govern $BRANCH; apply must consolidate them"
    blocked=true
  fi
  if [[ "$blocked" == false ]] && ruleset_governance_is_desired "$RULESET_FILE"; then
    record PASS live ruleset "canonical PR, approval, stale dismissal, squash, branch scope, and no-bypass semantics"
  else
    record DRIFT live ruleset "Ruleset name, target, or G-lite governance semantics differ from canonical"
  fi
  if [[ "$PHASE" == bootstrap ]]; then
    if ruleset_has_no_required_check "$RULESET_FILE"; then
      record PASS live required_check "BOOTSTRAPPED defers Required Check binding"
    else
      record DRIFT live required_check "BOOTSTRAPPED Ruleset must not contain a Required Check"
    fi
    return
  fi
  if [[ -z "$REQUIRED_CHECK" ]]; then
    record UNVERIFIED live required_check "active audit requires --required-check NAME"
  elif ruleset_check_is_desired "$RULESET_FILE"; then
    record PASS live required_check "exact Required Check context '$REQUIRED_CHECK' is required"
  else
    record DRIFT live required_check "Required Check configuration does not exactly match target '$REQUIRED_CHECK'"
  fi
}

audit_foundation() {
  marker_audit
  audit_label
  audit_repository_settings
  audit_security
  audit_apps
}

auditor() {
  : > "$RESULTS"
  audit_foundation
  RULESET_NAME="$(jq -r '.ruleset.name' "$MANIFEST")"
  audit_ruleset
  if [[ -s "$WRITE_RESULTS" ]]; then
    cat "$WRITE_RESULTS" >> "$RESULTS"
  fi
}

overall_exit() {
  if grep -Eq $'^(PLATFORM_BLOCKER|PERMISSION_BLOCKER|UNVERIFIED)\t' "$RESULTS"; then return 3; fi
  if grep -q $'^DRIFT\t' "$RESULTS"; then return 2; fi
  return 0
}

print_results() {
  printf 'STATE\tCATEGORY\tKEY\tDETAIL\n'
  cat "$RESULTS"
  if overall_exit; then
    if [[ "$PHASE" == bootstrap ]]; then
      printf 'SUMMARY\tBOOTSTRAPPED\n'
    else
      printf 'SUMMARY\tACTIVE\n'
    fi
  fi
}

plan_from_results() {
  local state category key detail
  while IFS=$'\t' read -r state category key detail; do
    [[ "$state" == PASS ]] && continue
    case "$key" in
      AGENTS.md|.github/ISSUE_TEMPLATE/task.md|.github/pull_request_template.md)
        echo "PLAN: seed missing $key only; existing files require Agent-assisted semantic patch." ;;
      label) echo "PLAN: create or update exact approved label metadata; preserve other labels." ;;
      repository_settings) echo "PLAN: patch only manifest-owned repository merge settings." ;;
      secret_scanning|secret_scanning_push_protection)
        echo "PLAN: enable the supported security setting or report its platform/permission blocker." ;;
      developer_app|reviewer_app) echo "PLAN: complete external consumer ${key%_app} App identity, independence, and installation preflight, then pass --${key%_app}-app-verified for this invocation; no credential manager is used." ;;
      ruleset) echo "PLAN: safely migrate/consolidate only G-lite-owned Rulesets for the target branch." ;;
      required_check) echo "PLAN: provide the exact real Required Check context; never infer it from a workflow file." ;;
      *) echo "PLAN: $category/$key -> $detail" ;;
    esac
  done < "$RESULTS"
}
