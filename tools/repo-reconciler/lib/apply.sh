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
          + [{type:"pull_request",parameters:{required_approving_review_count:1,dismiss_stale_reviews_on_push:true,require_code_owner_review:false,require_last_push_approval:false,required_review_thread_resolution:false,allowed_merge_methods:["squash"]}}]
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
        {type:"pull_request",parameters:{required_approving_review_count:1,dismiss_stale_reviews_on_push:true,require_code_owner_review:false,require_last_push_approval:false,required_review_thread_resolution:false,allowed_merge_methods:["squash"]}},
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
  run_bootstrap || return $?
  PHASE="$original_phase"
  if [[ -n "$REQUIRED_CHECK" ]]; then
    ensure_ruleset || true
  fi
  auditor
  print_results
  overall_exit || return $?
}

run_write_action() {
  local entrypoint="$1"
  write_preflight || return $?
  load_repository
  "$entrypoint"
}
