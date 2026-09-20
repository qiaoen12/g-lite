# shellcheck shell=bash

remote_file_exists() {
  local path="$1" out="$tmpdir/remote-file-$RANDOM.json" err="$tmpdir/remote-file-$RANDOM.err"
  if api_get "repos/$REPO/contents/$path?ref=$BRANCH" "$out" "$err"; then
    return 0
  fi
  if grep -q 'HTTP 404' "$err" || grep -qi 'Git Repository is empty' "$err"; then
    return 1
  fi
  echo "cannot inspect $REPO:$path: $(cat "$err")" >&2
  return 2
}

upload_remote_file() {
  local path="$1" source="$2" message="$3"
  local encoded upload_err="$tmpdir/upload-$RANDOM.err"
  encoded="$(base64 < "$source" | tr -d '\n')"

  if gh api --method PUT "repos/$REPO/contents/$path" \
    -f message="$message" -f content="$encoded" -f branch="$BRANCH" \
    >/dev/null 2>"$upload_err"; then
    return 0
  fi

  # An actually empty repository may not have a branch ref yet. Let GitHub use
  # the configured default branch for the first Contents API commit.
  if gh api --method PUT "repos/$REPO/contents/$path" \
    -f message="$message" -f content="$encoded" \
    >/dev/null 2>"$upload_err"; then
    return 0
  fi

  echo "cannot seed $REPO:$path: $(cat "$upload_err")" >&2
  return 1
}

set_default_branch() {
  local err="$tmpdir/default-branch.err"
  if ! gh api --method PATCH "repos/$REPO" -f default_branch="$BRANCH" >/dev/null 2>"$err"; then
    echo "cannot set $REPO default branch to $BRANCH: $(cat "$err")" >&2
    return 1
  fi
}

ensure_required_label() {
  local labels="$tmpdir/genesis-labels.json" err="$tmpdir/genesis-labels.err"
  local color desc
  if ! api_get "repos/$REPO/labels?per_page=100" "$labels" "$err"; then
    echo "cannot inspect labels for $REPO: $(cat "$err")" >&2
    return 1
  fi
  if jq -e --arg n "$label_name" '.[] | select(.name == $n)' "$labels" >/dev/null; then
    echo "GENESIS: label $label_name already exists"
    return 0
  fi

  color="$(jq -r '.required_label.color' "$MANIFEST")"
  desc="$(jq -r '.required_label.description' "$MANIFEST")"
  if ! gh api --method POST "repos/$REPO/labels" -f name="$label_name" -f color="$color" -f description="$desc" >/dev/null 2>"$err"; then
    if ! api_get "repos/$REPO/labels?per_page=100" "$labels" "$err" || ! jq -e --arg n "$label_name" '.[] | select(.name == $n)' "$labels" >/dev/null; then
      echo "cannot create required label $label_name: $(cat "$err")" >&2
      return 1
    fi
  fi
  echo "GENESIS: created label $label_name"
}

accept_pending_reviewer_invitation() {
  [[ -n "$REVIEWER_GH_CONFIG" ]] || return 0
  local reviewer_identity invitations invitation_id err="$tmpdir/reviewer-invite.err"
  reviewer_identity="$(GH_CONFIG_DIR="$REVIEWER_GH_CONFIG" gh api user --jq .login 2>"$err" || true)"
  if [[ "$reviewer_identity" != "$REVIEWER" ]]; then
    echo "cannot accept Reviewer invitation: --reviewer-gh-config is not authenticated as $REVIEWER" >&2
    return 1
  fi
  invitations="$tmpdir/reviewer-invitations.json"
  if ! GH_CONFIG_DIR="$REVIEWER_GH_CONFIG" gh api 'user/repository_invitations?per_page=100' >"$invitations" 2>"$err"; then
    echo "cannot read pending Reviewer invitations: $(cat "$err")" >&2
    return 1
  fi
  invitation_id="$(jq -r --arg repo "$REPO" '.[] | select(.repository.full_name == $repo) | .id' "$invitations" | head -n 1)"
  [[ -n "$invitation_id" ]] || return 0
  if ! GH_CONFIG_DIR="$REVIEWER_GH_CONFIG" gh api --method PATCH "user/repository_invitations/$invitation_id" >/dev/null 2>"$err"; then
    echo "cannot accept Reviewer invitation $invitation_id: $(cat "$err")" >&2
    return 1
  fi
  echo "GENESIS: Reviewer accepted repository invitation $invitation_id via GitHub API"
}

wait_for_reviewer_write() {
  local attempt permission_json="$tmpdir/genesis-permission-final.json" err="$tmpdir/genesis-permission-final.err"
  for attempt in {1..12}; do
    if api_get "repos/$REPO/collaborators/$REVIEWER/permission" "$permission_json" "$err"; then
      if jq -e '.permission as $p | ["push","write","maintain","admin"] | index($p)' "$permission_json" >/dev/null; then
        echo "GENESIS: $REVIEWER permission=$(jq -r '.permission' "$permission_json")"
        return 0
      fi
    fi
    sleep 5
  done
  echo "Reviewer $REVIEWER does not have write permission after invitation handling" >&2
  return 1
}

ensure_reviewer_permission() {
  local permission_json="$tmpdir/genesis-permission.json" err="$tmpdir/genesis-permission.err"
  local permission=""
  if api_get "repos/$REPO/collaborators/$REVIEWER/permission" "$permission_json" "$err"; then
    permission="$(jq -r '.permission // "unknown"' "$permission_json")"
    if jq -e --arg p "$permission" '.reviewer.minimum_permissions | index($p)' "$MANIFEST" >/dev/null; then
      echo "GENESIS: $REVIEWER permission=$permission"
      return 0
    fi
  fi

  if [[ "$GENESIS" -ne 1 && "$ALLOW_PERMISSION_CHANGE" -ne 1 ]]; then
    echo "SKIP: reviewer permission change requires --allow-permission-change"
    return 0
  fi
  if ! gh api --method PUT "repos/$REPO/collaborators/$REVIEWER" -f permission=push >/dev/null 2>"$err"; then
    echo "cannot grant $REVIEWER write permission: $(cat "$err")" >&2
    return 1
  fi
  echo "APPLY: granted $REVIEWER write permission"
  if [[ "$GENESIS" -eq 1 || -n "$REVIEWER_GH_CONFIG" ]]; then
    if ! accept_pending_reviewer_invitation; then
      return 1
    fi
    wait_for_reviewer_write
  fi
}

make_genesis_workflow() {
  local out="$1" check_json branch_json
  check_json="$(jq -Rn --arg value "$REQUIRED_CHECK" '$value')"
  branch_json="$(jq -Rn --arg value "$BRANCH" '$value')"
  {
    printf '%s\n' 'name: Genesis CI'
    printf '%s\n' 'on:'
    printf '%s\n' '  push:'
    printf '    branches: [%s]\n' "$branch_json"
    printf '%s\n' '  pull_request:'
    printf '    branches: [%s]\n' "$branch_json"
    printf '%s\n' 'permissions:'
    printf '%s\n' '  contents: read'
    printf '%s\n' 'jobs:'
    printf '%s\n' '  genesis:'
    printf '    name: %s\n' "$check_json"
    printf '%s\n' '    runs-on: ubuntu-latest'
    printf '%s\n' '    steps:'
    printf '%s\n' '      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4'
    printf '%s\n' '      - name: Protocol smoke'
    printf '%s\n' '        shell: bash'
    printf '%s\n' '        run: |'
    printf '%s\n' '          set -euo pipefail'
    printf '%s\n' '          test -f README.md'
    printf '%s\n' '          test -f AGENTS.md'
    printf '%s\n' '          test -f .github/ISSUE_TEMPLATE/task.md'
    printf '%s\n' '          test -f .github/pull_request_template.md'
  } > "$out"
}

seed_protocol_file() {
  local path="$1" source="$tmpdir/source-$RANDOM"
  local err="$source.err"
  if remote_file_exists "$path"; then
    echo "GENESIS: preserved existing $path"
    return 0
  else
    local remote_state=$?
    if [[ "$remote_state" -eq 2 ]]; then
      return 1
    fi
  fi
  if ! source_protocol_file "$path" "$source"; then
    echo "cannot read canonical seed file $path: $(cat "$err" 2>/dev/null || true)" >&2
    return 1
  fi
  if ! upload_remote_file "$path" "$source" "chore: seed G-lite protocol baseline"; then
    return 1
  fi
  echo "GENESIS: seeded $path"
}

seed_genesis_baseline() {
  local path workflow="$tmpdir/genesis-ci.yml" workflow_path
  local protocol_files=(
    "README.md"
    "AGENTS.md"
    ".github/ISSUE_TEMPLATE/task.md"
    ".github/pull_request_template.md"
  )

  for path in "${protocol_files[@]}"; do
    if ! seed_protocol_file "$path"; then
      return 1
    fi
  done

  make_genesis_workflow "$workflow"
  workflow_path="$(jq -r '.genesis.workflow' "$MANIFEST")"
  if remote_file_exists "$workflow_path"; then
    echo "GENESIS: preserved existing $workflow_path"
  else
    local remote_state=$?
    if [[ "$remote_state" -eq 2 ]]; then
      return 1
    fi
    if ! push_missing_file_via_git "$workflow_path" "$workflow" "ci: add minimal Genesis check"; then
      return 1
    fi
    echo "GENESIS: seeded $workflow_path via git push"
  fi

  set_default_branch
}

push_missing_file_via_git() {
  local path="$1" source="$2" message="$3"
  local work="$tmpdir/genesis-git-$RANDOM" err="$tmpdir/genesis-git-$RANDOM.err"
  local git_name git_email
  mkdir -p "$work"
  git -C "$work" init -q
  git -C "$work" remote add origin "git@github.com:$REPO.git"
  if ! git -C "$work" fetch -q origin "$BRANCH" 2>"$err"; then
    git -C "$work" checkout -q --orphan "$BRANCH"
  else
    git -C "$work" checkout -q -B "$BRANCH" FETCH_HEAD
  fi
  if [[ -e "$work/$path" ]]; then
    return 0
  fi
  mkdir -p "$(dirname "$work/$path")"
  cp "$source" "$work/$path"
  git_name="$(git config --get user.name 2>/dev/null || true)"
  git_email="$(git config --get user.email 2>/dev/null || true)"
  [[ -n "$git_name" ]] || git_name="qiaoen12"
  [[ -n "$git_email" ]] || git_email="qiaoenluo@gmail.com"
  git -C "$work" config user.name "$git_name"
  git -C "$work" config user.email "$git_email"
  git -C "$work" add -- "$path"
  if git -C "$work" diff --cached --quiet; then
    return 0
  fi
  git -C "$work" commit -q -m "$message"
  if ! git -C "$work" push -q origin "HEAD:refs/heads/$BRANCH" 2>"$err"; then
    echo "cannot push Genesis seed $path: $(cat "$err")" >&2
    return 1
  fi
}

check_success_for_sha() {
  local sha="$1" checks="$tmpdir/checks-$RANDOM.json"
  local err="$checks.err"
  if api_get "repos/$REPO/commits/$sha/check-runs?per_page=100" "$checks" "$err"; then
    if jq -e --arg c "$REQUIRED_CHECK" '.check_runs[]? | select(.name == $c and .conclusion == "success")' "$checks" >/dev/null; then
      return 0
    fi
  fi
  local status="$tmpdir/status-$RANDOM.json"
  local status_err="$status.err"
  if api_get "repos/$REPO/commits/$sha/status" "$status" "$status_err"; then
    if jq -e --arg c "$REQUIRED_CHECK" '.statuses[]? | select(.context == $c and .state == "success")' "$status" >/dev/null; then
      return 0
    fi
  fi
  return 1
}

wait_for_genesis_check() {
  local sha="$1" deadline now runs run_id jobs jobs_err run_conclusion
  deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
  echo "GENESIS: waiting for real '$REQUIRED_CHECK' success on $sha"
  while true; do
    runs="$tmpdir/genesis-runs.json"; jobs_err="$tmpdir/genesis-jobs.err"
    if api_get "repos/$REPO/actions/runs?branch=$BRANCH&per_page=100" "$runs" "$jobs_err"; then
      while IFS= read -r run_id; do
        [[ -z "$run_id" ]] && continue
        jobs="$tmpdir/genesis-jobs-$run_id.json"
        if api_get "repos/$REPO/actions/runs/$run_id/jobs?per_page=100" "$jobs" "$jobs_err"; then
          if jq -e --arg c "$REQUIRED_CHECK" '.jobs[]? | select(.name == $c and .conclusion == "success")' "$jobs" >/dev/null; then
            echo "GENESIS: real '$REQUIRED_CHECK' SUCCESS (run $run_id)"
            return 0
          fi
          run_conclusion="$(jq -r --arg c "$REQUIRED_CHECK" '.jobs[]? | select(.name == $c) | .conclusion // empty' "$jobs" | tail -n 1)"
          if [[ "$run_conclusion" == "failure" || "$run_conclusion" == "cancelled" || "$run_conclusion" == "timed_out" ]]; then
            echo "GENESIS: '$REQUIRED_CHECK' failed on run $run_id" >&2
            return 1
          fi
        fi
      done < <(jq -r --arg sha "$sha" '.workflow_runs[]? | select(.head_sha == $sha) | .id' "$runs")
    fi
    now="$(date +%s)"
    if (( now >= deadline )); then
      echo "GENESIS: timed out waiting for '$REQUIRED_CHECK' success on $sha" >&2
      return 1
    fi
    sleep 5
  done
}

recent_successful_check() {
  local sha=""
  if sha="$(gh api "repos/$REPO/commits/$BRANCH" --jq .sha 2>/dev/null)" && check_success_for_sha "$sha"; then
    return 0
  fi

  local pulls="$tmpdir/recent-pulls.json"
  local pulls_err="$pulls.err"
  if api_get "repos/$REPO/pulls?state=all&base=$BRANCH&sort=updated&direction=desc&per_page=20" "$pulls" "$pulls_err"; then
    while IFS= read -r sha; do
      [[ -z "$sha" || "$sha" == null ]] && continue
      if check_success_for_sha "$sha"; then
        return 0
      fi
    done < <(jq -r '.[].head.sha' "$pulls")
  fi
  return 1
}

load_named_ruleset() {
  local list="$tmpdir/apply-rulesets.json" id detail detail_err
  local list_err="$list.err"
  RULESET_LIVE_ID=""
  RULESET_LIVE_FILE=""
  if ! api_get "repos/$REPO/rulesets?includes_parents=false" "$list" "$list_err"; then
    echo "cannot inspect Rulesets for $REPO: $(cat "$list_err")" >&2
    return 1
  fi
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    detail="$tmpdir/apply-ruleset-$id.json"; detail_err="$detail.err"
    if ! api_get "repos/$REPO/rulesets/$id" "$detail" "$detail_err"; then
      echo "cannot inspect Ruleset $id for $REPO: $(cat "$detail_err")" >&2
      return 1
    fi
    if [[ "$(jq -r '.name // empty' "$detail")" == "$RULESET_NAME" ]]; then
      RULESET_LIVE_ID="$id"
      RULESET_LIVE_FILE="$detail"
      return 0
    fi
  done < <(jq -r '.[].id' "$list")
  return 0
}

ruleset_is_desired() {
  local detail="$1"
  jq -e --arg name "$RULESET_NAME" --arg branch "$BRANCH" --arg check "$REQUIRED_CHECK" '
    .name == $name and
    .target == "branch" and
    .enforcement == "active" and
    ((.conditions.ref_name.include // []) | any(. == ("refs/heads/" + $branch))) and
    ((.bypass_actors // []) | length == 0) and
    any(.rules[]?; .type == "deletion") and
    any(.rules[]?; .type == "non_fast_forward") and
    any(.rules[]?;
      .type == "pull_request" and
      ((.parameters.required_approving_review_count // 0) >= 1) and
      (.parameters.dismiss_stale_reviews_on_push == true) and
      ((.parameters.require_last_push_approval // false) == false) and
      ((.parameters.allowed_merge_methods // []) == ["squash"])
    ) and
    any(.rules[]?;
      .type == "required_status_checks" and
      any(.parameters.required_status_checks[]?; .context == $check)
    )
  ' "$detail" >/dev/null
}

make_ruleset_payload() {
  local current="${1:-}" out="$2"
  if [[ -n "$current" && -f "$current" ]]; then
    jq --arg name "$RULESET_NAME" --arg branch "$BRANCH" --arg check "$REQUIRED_CHECK" '
      . as $current |
      ($current.rules // []) as $rules |
      ([ $rules[]? | select(.type == "required_status_checks") | .parameters.required_status_checks[]? ] + [{context:$check}])
      | unique_by(.context) as $checks |
      ([ $rules[]? | select(.type == "pull_request") | .parameters ] | first // {}) as $pr_parameters |
      ([ $rules[]? | select(.type == "required_status_checks") | .parameters ] | first // {}) as $check_parameters |
      {
        name: $name,
        target: "branch",
        enforcement: "active",
        bypass_actors: [],
        conditions: {ref_name: {include: ["refs/heads/" + $branch], exclude: []}},
        rules: (
          [ $rules[]? | select(.type != "deletion" and .type != "non_fast_forward" and .type != "pull_request" and .type != "required_status_checks") ]
          + [{type:"deletion"}]
          + [{type:"non_fast_forward"}]
          + [{type:"pull_request",parameters:($pr_parameters + {required_approving_review_count:1,dismiss_stale_reviews_on_push:true,require_code_owner_review:false,require_last_push_approval:false,required_review_thread_resolution:false,allowed_merge_methods:["squash"]})}]
          + [{type:"required_status_checks",parameters:($check_parameters + {strict_required_status_checks_policy:($check_parameters.strict_required_status_checks_policy // false),do_not_enforce_on_create:($check_parameters.do_not_enforce_on_create // false),required_status_checks:$checks})}]
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
  if ! recent_successful_check; then
    echo "SKIP: '$REQUIRED_CHECK' has no verified successful real check; Ruleset activation is blocked" >&2
    return 1
  fi
  load_named_ruleset
  if [[ -n "$RULESET_LIVE_FILE" ]] && ruleset_is_desired "$RULESET_LIVE_FILE"; then
    echo "APPLY: named Ruleset '$RULESET_NAME' already satisfies G-lite governance"
    return 0
  fi

  local payload="$tmpdir/ruleset-payload.json" err="$tmpdir/ruleset-write.err"
  make_ruleset_payload "$RULESET_LIVE_FILE" "$payload"
  if [[ -n "$RULESET_LIVE_ID" ]]; then
    if ! gh api --method PUT "repos/$REPO/rulesets/$RULESET_LIVE_ID" --input "$payload" >/dev/null 2>"$err"; then
      echo "cannot repair Ruleset '$RULESET_NAME': $(cat "$err")" >&2
      return 1
    fi
    echo "APPLY: repaired Ruleset '$RULESET_NAME' for $BRANCH with Required Check '$REQUIRED_CHECK'"
  else
    if ! gh api --method POST "repos/$REPO/rulesets" --input "$payload" >/dev/null 2>"$err"; then
      echo "cannot create Ruleset '$RULESET_NAME': $(cat "$err")" >&2
      return 1
    fi
    echo "APPLY: created active Ruleset '$RULESET_NAME' for $BRANCH with Required Check '$REQUIRED_CHECK'"
  fi
}

run_genesis() {
  echo "GENESIS: Phase A bootstrap baseline"
  seed_genesis_baseline
  ensure_required_label
  ensure_reviewer_permission

  # The workflow was seeded last, so this is the first real CI candidate.
  GENESIS_EXPECTED_SHA="$(gh api "repos/$REPO/commits/$BRANCH" --jq .sha 2>/dev/null || true)"
  if [[ -z "$GENESIS_EXPECTED_SHA" ]]; then
    echo "cannot resolve $REPO/$BRANCH after Genesis bootstrap" >&2
    return 1
  fi
  if ! wait_for_genesis_check "$GENESIS_EXPECTED_SHA"; then
    return 1
  fi

  echo "GENESIS: Phase B activate durable gates"
  if ! ensure_ruleset; then
    return 1
  fi

  # Re-read live facts after all writes. This is the only durable completion claim.
  if ! api_get "repos/$REPO" "$repo_json" "$repo_err"; then
    echo "cannot re-read $REPO for final audit: $(cat "$repo_err")" >&2
    return 1
  fi
  : > "$RESULTS"
  collect_audit
  print_results
  overall_exit || return $?
  return 0
}

run_apply() {
  if [[ "$GENESIS" -eq 1 ]]; then
    run_genesis
    return $?
  fi

  if grep -q $'DRIFT\tlive\tlabel\t' "$RESULTS"; then
    color="$(jq -r '.required_label.color' "$MANIFEST")"
    desc="$(jq -r '.required_label.description' "$MANIFEST")"
    if ! gh api --method POST "repos/$REPO/labels" -f name="$label_name" -f color="$color" -f description="$desc" >/dev/null; then
      echo "SKIP: could not create missing label $label_name" >&2
    else
      echo "APPLY: created label $label_name"
    fi
  fi

  if grep -q $'DRIFT\tlive\treviewer\t' "$RESULTS"; then
    ensure_reviewer_permission
  fi

  if grep -Eq $'DRIFT\t(exact|semantic)\t' "$RESULTS"; then
    if [[ "$local_matches_target" -ne 1 ]]; then
      echo "SKIP: protocol file reconciliation requires a local checkout of $REPO"
    else
      while IFS= read -r entry; do
        path="$(jq -r '.path' <<<"$entry")"; source="$(jq -r '.source' <<<"$entry")"
        canon="$tmpdir/apply-canon-$RANDOM"; err="$canon.err"
        source_protocol_file "$source" "$canon" || continue
        full="$local_root/$path"
        if [[ ! -e "$full" ]]; then
          mkdir -p "$(dirname "$full")"
          cp "$canon" "$full"
          echo "APPLY: added missing Exact file $path to working tree"
        elif ! cmp -s "$full" "$canon"; then
          if [[ "$ALLOW_OVERWRITE" -eq 1 ]]; then
            cp "$canon" "$full"
            echo "APPLY: replaced drifted Exact file $path in working tree (--allow-overwrite)"
          else
            echo "SKIP: Exact file $path differs; review upgrade diff, then use --allow-overwrite if intended"
          fi
        fi
      done < <(jq -c '.protocol.exact[]' "$MANIFEST")

      while IFS= read -r entry; do
        path="$(jq -r '.path' <<<"$entry")"
        full="$local_root/$path"
        if [[ ! -e "$full" ]]; then
          canon="$tmpdir/apply-sem-$RANDOM"; err="$canon.err"
          if source_protocol_file "$path" "$canon"; then
            mkdir -p "$(dirname "$full")"; cp "$canon" "$full"
            echo "APPLY: added missing Semantic file $path to working tree"
          fi
        else
          missing=0
          while IFS= read -r marker; do
            [[ -z "$marker" ]] && continue
            grep -Fq "$marker" "$full" || missing=1
          done < <(jq -r '.markers[]' <<<"$entry")
          if [[ "$missing" -eq 1 ]]; then
            echo "SKIP: $path exists but lacks protocol semantics; merge manually. It is never overwritten."
          fi
        fi
      done < <(jq -c '.protocol.semantic[]' "$MANIFEST")
    fi
  fi

  if [[ "$PHASE" == "active" && -n "$REQUIRED_CHECK" && "$ACTIVATE" -eq 1 ]]; then
    ensure_ruleset || echo "SKIP: Ruleset was not activated; inspect the blocker above" >&2
  elif [[ "$PHASE" == "active" && "$ACTIVATE" -eq 0 ]]; then
    echo "SKIP: active Ruleset creation or repair requires --activate"
  fi

  echo
  echo "POST-APPLY: re-run 'audit --phase $PHASE${REQUIRED_CHECK:+ --check $REQUIRED_CHECK}' to verify live facts."
}
