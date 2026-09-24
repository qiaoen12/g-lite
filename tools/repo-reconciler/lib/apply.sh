# Bootstrap, apply, activate, and governance write orchestration.

write_preflight() {
  local missing=()
  [[ "$HUMAN_AUTHORITY_VERIFIED" == true ]] || missing+=("Human Authority")
  [[ "$DEVELOPER_APP_VERIFIED" == true ]] || missing+=("Developer App")
  [[ "$REVIEWER_APP_VERIFIED" == true ]] || missing+=("Reviewer App")
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "UNVERIFIED: write preflight missing assertion(s): ${missing[*]}; no remote governance writes performed" >&2
    return 3
  fi
  echo "WRITE PREFLIGHT: Human Authority, Developer App, and Reviewer App assertions present (invocation-only)" >&2
}

empty_repo_initial_write_allowed() {
  local repository="$tmpdir/initial-repository.json" facts="$tmpdir/initial-empty.json"
  local error="$tmpdir/initial-empty.err"
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
  local write_error="$tmpdir/apply-label-write.err" name path payload current_name equivalent_count
  name="$(jq -r '.required_label.name' "$MANIFEST")"
  if ! api_get "repos/$REPO/labels?per_page=100" "$labels" "$error"; then
    echo "cannot inspect labels: $(cat "$error")" >&2
    return 1
  fi
  if ! label_inventory_is_readable "$labels"; then
    printf 'UNVERIFIED\tlive\tlabel\tGitHub returned an invalid label inventory\n' >> "$WRITE_RESULTS"
    echo "UNVERIFIED: cannot identify existing labels reliably" >&2
    return 1
  fi
  equivalent_count="$(label_candidates "$labels" | jq 'length')"
  if [[ "$equivalent_count" -gt 1 ]]; then
    printf 'DRIFT\tlive\tlabel\tmultiple G-lite-owned equivalent labels; refusing ambiguous migration\n' >> "$WRITE_RESULTS"
    echo "DRIFT: multiple G-lite-owned labels match '$name'; refusing to merge label assignments" >&2
    return 1
  fi
  if label_metadata_is_desired "$labels"; then
    echo "APPLY: label $name already has canonical metadata"
    return 0
  fi
  payload="$tmpdir/label-payload.json"
  if [[ "$equivalent_count" -eq 1 ]]; then
    current_name="$(label_candidates "$labels" | jq -r '.[0].name')"
    path="$(jq -rn --arg name "$current_name" '$name | @uri')"
    if [[ "$current_name" == "$name" ]]; then
      jq '{color:.required_label.color,description:.required_label.description}' "$MANIFEST" > "$payload"
    else
      jq --arg name "$name" '{new_name:$name,color:.required_label.color,description:.required_label.description}' \
        "$MANIFEST" > "$payload"
    fi
    if gh api --method PATCH "repos/$REPO/labels/$path" --input "$payload" >/dev/null 2>"$error"; then
      echo "APPLY: repaired label '$current_name' in place as '$name' with canonical metadata"
      return 0
    fi
  else
    if gh api --method POST "repos/$REPO/labels" \
      -f name="$name" -f color="$(jq -r '.required_label.color' "$MANIFEST")" \
      -f description="$(jq -r '.required_label.description' "$MANIFEST")" >/dev/null 2>"$error"; then
      echo "APPLY: created label $name"
      return 0
    fi
  fi
  cp "$error" "$write_error"
  if api_get "repos/$REPO/labels?per_page=100" "$labels" "$error" &&
    label_metadata_is_desired "$labels"; then
    echo "APPLY: label $name converged concurrently"
    return 0
  fi
  record_write_failure label "$write_error"
  echo "cannot ensure label $name: $(cat "$write_error")" >&2
  return 1
}

ensure_repository_settings() {
  local repository="$tmpdir/apply-repository.json" error="$tmpdir/apply-repository.err"
  local payload="$tmpdir/repository-settings-payload.json" write_error="$tmpdir/repository-settings-write.err"
  if ! api_get "repos/$REPO" "$repository" "$error"; then
    echo "cannot inspect repository settings: $(cat "$error")" >&2
    return 1
  fi
  if repository_settings_are_desired "$repository"; then
    echo "APPLY: repository merge settings already match canonical values"
    return 0
  fi
  jq '.repository_settings' "$MANIFEST" > "$payload"
  if gh api --method PATCH "repos/$REPO" --input "$payload" >/dev/null 2>"$error"; then
    echo "APPLY: repaired G-lite-owned repository merge settings"
    return 0
  fi
  cp "$error" "$write_error"
  record_write_failure repository_settings "$write_error"
  echo "cannot update repository settings: $(cat "$write_error")" >&2
  return 1
}

ensure_security_setting() {
  local key="$1" repository="$tmpdir/security-$1.json" error="$tmpdir/security-$1.err"
  local status payload write_error="$tmpdir/security-$1-write.err"
  if ! api_get "repos/$REPO" "$repository" "$error"; then
    echo "cannot inspect $key: $(cat "$error")" >&2
    return 1
  fi
  status="$(jq -r --arg key "$key" '.security_and_analysis[$key].status // "unavailable_to_read"' "$repository")"
  case "$status" in
    enabled)
      echo "APPLY: $key already enabled"
      return 0
      ;;
    disabled)
      ;;
    not_available|unavailable)
      echo "PLATFORM_BLOCKER: GitHub reports $key is not available" >&2
      return 1
      ;;
    *)
      echo "UNVERIFIED: GitHub did not expose a supported status for $key" >&2
      return 1
      ;;
  esac
  payload="$tmpdir/security-$key-payload.json"
  jq --arg key "$key" '{security_and_analysis:{($key):.security_and_analysis[$key]}}' "$MANIFEST" > "$payload"
  if gh api --method PATCH "repos/$REPO" --input "$payload" >/dev/null 2>"$error"; then
    echo "APPLY: enabled $key"
    return 0
  fi
  cp "$error" "$write_error"
  record_write_failure "$key" "$write_error"
  echo "cannot enable $key: $(cat "$write_error")" >&2
  return 1
}

make_ruleset_payload() {
  local current="$1" out="$2" phase="${3:-active}" preserved_check="${4:-null}"
  local extras="${RULESET_MERGED_FILE:-}" name branch check
  name="$RULESET_NAME"
  branch="$BRANCH"
  check="$REQUIRED_CHECK"
  if [[ -z "$extras" || ! -f "$extras" ]]; then
    extras="$tmpdir/ruleset-extras-fallback.json"
    if [[ -n "$current" && -f "$current" ]]; then
      jq '[.rules[]? | select(.type != "deletion" and .type != "non_fast_forward" and .type != "pull_request" and .type != "required_status_checks")] | unique' "$current" > "$extras"
    else
      printf '[]\n' > "$extras"
    fi
  fi
  jq -n --arg name "$name" --arg branch "$branch" --arg check "$check" --arg phase "$phase" \
    --argjson preserved_check "$preserved_check" \
    --argjson desired "$(jq -c '.ruleset' "$MANIFEST")" --slurpfile extras "$extras" '
    ($extras[0] // []) as $extra |
    [
      if $desired.block_deletions then {type:"deletion"} else empty end,
      if $desired.block_non_fast_forward then {type:"non_fast_forward"} else empty end,
      {type:"pull_request",parameters:{
        required_approving_review_count:$desired.required_approvals,
        dismiss_stale_reviews_on_push:$desired.dismiss_stale_reviews_on_push,
        require_code_owner_review:$desired.require_code_owner_review,
        require_last_push_approval:$desired.require_last_push_approval,
        required_review_thread_resolution:$desired.required_review_thread_resolution,
        allowed_merge_methods:$desired.allowed_merge_methods
      }}
    ] as $base |
    {
      name:$name,
      target:"branch",
      enforcement:"active",
      bypass_actors:[],
      conditions:{ref_name:{include:["refs/heads/" + $branch],exclude:[]}},
      rules:($extra + $base + (
        if $phase == "active" then
          [{type:"required_status_checks",parameters:{
            strict_required_status_checks_policy:$desired.strict_required_status_checks_policy,
            do_not_enforce_on_create:$desired.do_not_enforce_on_create,
            required_status_checks:(if $preserved_check == null then [{context:$check}] else [$preserved_check] end)
          }}]
        else [] end
      ))
    }
  ' > "$out"
}

live_single_required_check() {
  local file="$1"
  jq -er '
    [.rules[]? | select(.type == "required_status_checks")] as $rules |
    if ($rules | length) == 1 and
       ($rules[0].parameters | type) == "object" and
       (($rules[0].parameters | keys) - ["required_status_checks", "strict_required_status_checks_policy", "do_not_enforce_on_create"] | length) == 0 and
       ($rules[0].parameters.required_status_checks | type) == "array" and
       ($rules[0].parameters.required_status_checks | length) == 1 and
       ($rules[0].parameters.required_status_checks[0] | type) == "object" and
       (($rules[0].parameters.required_status_checks[0] | keys) - ["context", "integration_id"] | length) == 0 and
       ($rules[0].parameters.required_status_checks[0].context | type) == "string" and
       ($rules[0].parameters.required_status_checks[0].context | length) > 0 and
       (($rules[0].parameters.required_status_checks[0].integration_id // 0) | type) == "number"
    then $rules[0].parameters.required_status_checks[0] else empty end
  ' "$file"
}

ruleset_phase_is_desired() {
  local file="$1" phase="$2"
  ruleset_governance_is_desired "$file" || return 1
  if [[ "$phase" == bootstrap ]]; then
    ruleset_has_no_required_check "$file"
  else
    ruleset_check_is_desired "$file"
  fi
}

ensure_ruleset_state() {
  local phase="$1" payload="$tmpdir/ruleset-payload.json" error="$tmpdir/ruleset-write.err"
  local write_error="$tmpdir/ruleset-write-copy.err" id file preserved_check=null live_context
  RULESET_NAME="$(jq -r '.ruleset.name' "$MANIFEST")"
  if ! load_named_ruleset; then
    record_write_failure ruleset "$RULESET_ERROR"
    echo "cannot inspect Rulesets: $(cat "$RULESET_ERROR")" >&2
    return 1
  fi
  if [[ ${#RULESET_UNSAFE_IDS[@]} -gt 0 ]]; then
    printf 'DRIFT\tlive\truleset\tG-lite Ruleset also governs other refs; refusing to narrow it\n' >> "$WRITE_RESULTS"
    return 1
  fi
  if [[ ${#RULESET_CONFLICT_IDS[@]} -gt 0 ]]; then
    printf 'DRIFT\tlive\truleset\tUnrecognized Ruleset may overlap target branch; refusing to create a second Ruleset\n' >> "$WRITE_RESULTS"
    return 1
  fi
  if [[ "$phase" == bootstrap ]]; then
    for file in "${RULESET_FILES[@]}"; do
      if ! ruleset_has_no_required_check "$file"; then
        if [[ ${#RULESET_IDS[@]} -ne 1 ]] ||
          [[ "$(jq -r '.name // empty' "$file")" != "$RULESET_NAME" ]] ||
          ! preserved_check="$(live_single_required_check "$file")"; then
          printf 'DRIFT\tlive\trequired_check\tACTIVE Required Check is ambiguous; refusing Ruleset write\n' >> "$WRITE_RESULTS"
          return 1
        fi
        live_context="$(jq -r '.context' <<<"$preserved_check")"
        if ! jq -e --arg context "$live_context" '.context == $context' <<<"$preserved_check" >/dev/null; then
          printf 'DRIFT\tlive\trequired_check\tACTIVE Required Check context cannot be preserved exactly\n' >> "$WRITE_RESULTS"
          return 1
        fi
        REQUIRED_CHECK="$live_context"
        PHASE="active"
        phase="active"
        break
      fi
    done
  fi
  if [[ ${#RULESET_IDS[@]} -eq 1 ]] &&
    [[ "$(jq -r '.name // empty' "$RULESET_FILE")" == "$RULESET_NAME" ]] &&
    ruleset_phase_is_desired "$RULESET_FILE" "$phase"; then
    echo "APPLY: Ruleset '$RULESET_NAME' already satisfies $phase"
    return 0
  fi
  for file in "${RULESET_FILES[@]}"; do
    if ! ruleset_pr_parameters_safe_for_write "$file"; then
      printf 'DRIFT\tlive\truleset\tPR parameters outside G-lite ownership may be lost by Ruleset migration; refusing write\n' >> "$WRITE_RESULTS"
      return 1
    fi
  done
  make_ruleset_payload "$RULESET_FILE" "$payload" "$phase" "$preserved_check"
  if [[ ${#RULESET_IDS[@]} -gt 0 ]]; then
    if ! gh api --method PUT "repos/$REPO/rulesets/$RULESET_ID" --input "$payload" >/dev/null 2>"$error"; then
      record_write_failure ruleset "$error"
      echo "cannot migrate Ruleset '$RULESET_NAME': $(cat "$error")" >&2
      return 1
    fi
    echo "APPLY: migrated Ruleset id $RULESET_ID to canonical '$RULESET_NAME' ($phase)"
    for id in "${RULESET_IDS[@]}"; do
      [[ "$id" == "$RULESET_ID" ]] && continue
      if ! gh api --method DELETE "repos/$REPO/rulesets/$id" >/dev/null 2>"$error"; then
        cp "$error" "$write_error"
        record_write_failure "ruleset-duplicate-$id" "$write_error"
        echo "cannot remove duplicate G-lite Ruleset $id: $(cat "$write_error")" >&2
        return 1
      fi
      echo "APPLY: removed duplicate G-lite Ruleset id $id"
    done
    return 0
  fi
  if ! gh api --method POST "repos/$REPO/rulesets" --input "$payload" >/dev/null 2>"$error"; then
    record_write_failure ruleset "$error"
    echo "cannot create Ruleset '$RULESET_NAME': $(cat "$error")" >&2
    return 1
  fi
  echo "APPLY: created Ruleset '$RULESET_NAME' ($phase)"
}

ensure_base_ruleset() {
  ensure_ruleset_state bootstrap
}

ensure_ruleset() {
  ensure_ruleset_state active
}

run_bootstrap() {
  local entry path
  PHASE="bootstrap"
  REQUIRED_CHECK=""
  while IFS= read -r entry; do
    path="$(jq -r '.path' <<<"$entry")"
    bootstrap_file "$path" || true
  done < <(jq -c '.bootstrap[]' "$MANIFEST")
  ensure_label || true
  ensure_repository_settings || true
  ensure_base_ruleset || true
  ensure_security_setting secret_scanning || true
  ensure_security_setting secret_scanning_push_protection || true
  auditor
  print_results
  overall_exit || return $?
}

run_activate() {
  local status=0 check_status=0
  PHASE="activation-preflight"
  : > "$RESULTS"
  audit_foundation
  RULESET_NAME="$(jq -r '.ruleset.name' "$MANIFEST")"
  if ! load_named_ruleset; then
    record "$(api_error_state "$(cat "$RULESET_ERROR")")" live ruleset "cannot read Rulesets"
  elif [[ ${#RULESET_CONFLICT_IDS[@]} -gt 0 ]]; then
    record DRIFT live ruleset "an unrecognized Ruleset may overlap $BRANCH; activation is blocked"
  elif [[ ${#RULESET_UNSAFE_IDS[@]} -gt 0 ]]; then
    record DRIFT live ruleset "G-lite Ruleset also governs other refs and cannot be narrowed safely"
  elif [[ ${#RULESET_IDS[@]} -ne 1 ]] || ! ruleset_governance_semantics_are_desired "$RULESET_FILE"; then
    record DRIFT live ruleset "activate requires the Genesis base Ruleset to exist with canonical governance"
  fi
  verify_required_check_success || check_status=$?
  overall_exit || status=$?
  if [[ "$check_status" -gt "$status" ]]; then status="$check_status"; fi
  if [[ "$status" -ne 0 ]]; then
    print_results
    return "$status"
  fi
  : > "$RESULTS"
  ensure_ruleset || true
  PHASE="active"
  auditor
  print_results
  overall_exit || return $?
}

run_apply() {
  if [[ -n "$REQUIRED_CHECK" ]]; then
    echo "apply does not accept --required-check; use activate to bind an exact Required Check" >&2
    return 64
  fi
  PHASE="bootstrap"
  run_bootstrap || return $?
}

run_write_action() {
  local entrypoint="$1"
  write_preflight || return $?
  load_repository
  "$entrypoint"
}
