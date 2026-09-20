# shellcheck shell=bash

ruleset_applies_to_branch() {
  local detail="$1"
  jq -e --arg branch "$BRANCH" '
    .enforcement == "active" and
    .target == "branch" and
    ((.conditions.ref_name.include // []) | any(
      . == "~DEFAULT_BRANCH" or
      . == "~ALL" or
      . == ("refs/heads/" + $branch) or
      . == $branch
    ))
  ' "$detail" >/dev/null
}

collect_audit() {
  while IFS= read -r entry; do
    path="$(jq -r '.path' <<<"$entry")"
    source="$(jq -r '.source' <<<"$entry")"
    applies_to="$(jq -r '.applies_to // "all"' <<<"$entry")"
    if [[ "$applies_to" == "canonical" && "$REPO" != "$CANONICAL_REPO" ]]; then
      record PASS exact "$path" "not applicable outside canonical repo"
      continue
    fi
    target="$tmpdir/target.exact.$RANDOM"
    canon="$tmpdir/canon.exact.$RANDOM"
    target_err="$target.err"; canon_err="$canon.err"

    if ! fetch_raw_file "$REPO" "$BRANCH" "$path" "$target" "$target_err"; then
      if grep -q 'HTTP 404' "$target_err"; then
        record DRIFT exact "$path" "missing"
      else
        record "$(api_error_state "$(cat "$target_err")")" exact "$path" "cannot read target file"
      fi
      continue
    fi
    if ! fetch_raw_file "$CANONICAL_REPO" "$CANONICAL_REF" "$source" "$canon" "$canon_err"; then
      record "$(api_error_state "$(cat "$canon_err")")" exact "$path" "cannot read canonical source $CANONICAL_REPO@$CANONICAL_REF:$source"
      continue
    fi
    if cmp -s "$target" "$canon"; then
      record PASS exact "$path" "matches canonical"
    else
      record DRIFT exact "$path" "content differs from canonical"
    fi
  done < <(jq -c '.protocol.exact[]' "$MANIFEST")

  while IFS= read -r entry; do
    path="$(jq -r '.path' <<<"$entry")"
    target="$tmpdir/target.semantic.$RANDOM"
    target_err="$target.err"
    if ! fetch_raw_file "$REPO" "$BRANCH" "$path" "$target" "$target_err"; then
      if grep -q 'HTTP 404' "$target_err"; then
        record DRIFT semantic "$path" "missing"
      else
        record "$(api_error_state "$(cat "$target_err")")" semantic "$path" "cannot read target file"
      fi
      continue
    fi
    missing=()
    while IFS= read -r marker; do
      [[ -z "$marker" ]] && continue
      if ! grep -Fq "$marker" "$target"; then
        missing+=("$marker")
      fi
    done < <(jq -r '.markers[]' <<<"$entry")
    if [[ ${#missing[@]} -eq 0 ]]; then
      record PASS semantic "$path" "required protocol semantics present"
    else
      record DRIFT semantic "$path" "missing markers: ${missing[*]}"
    fi
  done < <(jq -c '.protocol.semantic[]' "$MANIFEST")

  label_name="$(jq -r '.required_label.name' "$MANIFEST")"
  labels_json="$tmpdir/labels.json"; labels_err="$tmpdir/labels.err"
  if api_get "repos/$REPO/labels?per_page=100" "$labels_json" "$labels_err"; then
    if jq -e --arg n "$label_name" '.[] | select(.name == $n)' "$labels_json" >/dev/null; then
      record PASS live label "$label_name exists"
    else
      record DRIFT live label "$label_name missing"
    fi
  else
    record "$(api_error_state "$(cat "$labels_err")")" live label "cannot read labels"
  fi

  perm_json="$tmpdir/perm.json"; perm_err="$tmpdir/perm.err"
  if api_get "repos/$REPO/collaborators/$REVIEWER/permission" "$perm_json" "$perm_err"; then
    permission="$(jq -r '.permission // "unknown"' "$perm_json")"
    if jq -e --arg p "$permission" '.reviewer.minimum_permissions | index($p)' "$MANIFEST" >/dev/null; then
      record PASS live reviewer "$REVIEWER permission=$permission"
    else
      record DRIFT live reviewer "$REVIEWER permission=$permission; need push(write)/maintain/admin"
    fi
  else
    if grep -q 'HTTP 404' "$perm_err"; then
      record DRIFT live reviewer "$REVIEWER is not a collaborator with visible permission"
    else
      record "$(api_error_state "$(cat "$perm_err")")" live reviewer "cannot verify $REVIEWER permission"
    fi
  fi

  ruleset_json="$tmpdir/rulesets.json"; ruleset_err="$tmpdir/rulesets.err"
  applicable_details="$tmpdir/applicable-rulesets.jsonl"
  target_ruleset_file=""
  target_ruleset_id=""
  : > "$applicable_details"
  ruleset_read_state=PASS
  if api_get "repos/$REPO/rulesets?includes_parents=false" "$ruleset_json" "$ruleset_err"; then
    while IFS= read -r id; do
      detail="$tmpdir/ruleset-$id.json"; err="$detail.err"
      if api_get "repos/$REPO/rulesets/$id" "$detail" "$err"; then
        if [[ "$(jq -r '.name // empty' "$detail")" == "$RULESET_NAME" ]]; then
          target_ruleset_id="$id"
          target_ruleset_file="$detail"
        fi
        if ruleset_applies_to_branch "$detail"; then
          jq -c . "$detail" >> "$applicable_details"
        fi
      else
        ruleset_read_state="$(ruleset_error_state "$(cat "$err")")"
      fi
    done < <(jq -r '.[].id' "$ruleset_json")
  else
    ruleset_read_state="$(ruleset_error_state "$(cat "$ruleset_err")")"
  fi

  if [[ "$PHASE" == "bootstrap" ]]; then
    record PASS live ruleset "bootstrap phase: Ruleset activation intentionally deferred until a real CI check succeeds"
    record PASS live required_check "bootstrap phase: Required Check intentionally deferred"
  else
    if [[ -z "$REQUIRED_CHECK" ]]; then
      record UNVERIFIED live required_check "active phase requires --check NAME"
    fi

    if [[ "$ruleset_read_state" != PASS ]]; then
      record "$ruleset_read_state" live ruleset "cannot independently read repository Rulesets"
    elif [[ -z "$target_ruleset_file" ]]; then
      record DRIFT live ruleset "named Ruleset '$RULESET_NAME' is missing for $BRANCH"
      if [[ -n "$REQUIRED_CHECK" ]]; then
        record DRIFT live required_check "$REQUIRED_CHECK is not required because the named Ruleset is missing"
      fi
    elif ! ruleset_applies_to_branch "$target_ruleset_file"; then
      record DRIFT live ruleset "named Ruleset '$RULESET_NAME' is inactive or does not apply to $BRANCH"
      if [[ -n "$REQUIRED_CHECK" ]]; then
        record DRIFT live required_check "$REQUIRED_CHECK is not required by an applicable named Ruleset"
      fi
    else
      has_pr=0; has_delete=0; has_nff=0; has_bypass=1; review_ok=0; check_ok=0
      if jq -e '.rules[]? | select(.type == "pull_request")' "$target_ruleset_file" >/dev/null; then has_pr=1; fi
      if jq -e '.rules[]? | select(.type == "deletion")' "$target_ruleset_file" >/dev/null; then has_delete=1; fi
      if jq -e '.rules[]? | select(.type == "non_fast_forward")' "$target_ruleset_file" >/dev/null; then has_nff=1; fi
      if [[ "$(jq -r '(.bypass_actors // []) | length' "$target_ruleset_file")" != "0" ]]; then has_bypass=0; fi
      if jq -e '.rules[]? | select(.type == "pull_request") | .parameters | select((.required_approving_review_count // 0) >= 1 and .dismiss_stale_reviews_on_push == true and (.require_last_push_approval // false) == false and (.allowed_merge_methods // []) == ["squash"])' "$target_ruleset_file" >/dev/null; then
        review_ok=1
      fi
      if [[ -n "$REQUIRED_CHECK" ]] && jq -e --arg c "$REQUIRED_CHECK" '.rules[]? | select(.type == "required_status_checks") | .parameters.required_status_checks[]? | select(.context == $c)' "$target_ruleset_file" >/dev/null; then
        check_ok=1
      fi

      if [[ $has_pr -eq 1 && $has_delete -eq 1 && $has_nff -eq 1 && $has_bypass -eq 1 && $review_ok -eq 1 ]]; then
        record PASS live ruleset "PR required; approvals>=1; stale dismissal on; last-push off; squash-only; deletion/non-fast-forward blocked; bypass none"
      else
        record DRIFT live ruleset "Ruleset does not satisfy G-lite governance requirements"
      fi

      if [[ -n "$REQUIRED_CHECK" ]]; then
        if [[ $check_ok -eq 1 ]]; then
          record PASS live required_check "$REQUIRED_CHECK is required"
        else
          record DRIFT live required_check "$REQUIRED_CHECK is not required by the named Ruleset"
        fi
      fi
    fi
  fi

  if [[ "$PHASE" == "active" && -n "$REQUIRED_CHECK" ]] && ! grep -Eq $'^(DRIFT|PLATFORM_BLOCKER|PERMISSION_BLOCKER|UNVERIFIED)\t' "$RESULTS"; then
    record PASS live status "G-lite ACTIVE"
  fi
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
  while IFS=$'\t' read -r state category key detail; do
    [[ "$state" == PASS ]] && continue
    case "$key" in
      label) echo "PLAN: create missing '$label_name' label; never delete existing project labels." ;;
      reviewer) echo "PLAN: ensure $REVIEWER has at least write permission. apply requires --allow-permission-change." ;;
      ruleset) echo "PLAN: satisfy the named main Ruleset. Existing Rulesets are repaired only with --activate; unrelated Rulesets are not modified." ;;
      required_check) [[ -n "$REQUIRED_CHECK" ]] && echo "PLAN: bind Required Check '$REQUIRED_CHECK' after a real successful run exists." || echo "PLAN: provide --check NAME for active-phase verification." ;;
      *.md|README.md|AGENTS.md) echo "PLAN: reconcile $key with canonical protocol without overwriting consumer-owned README/AGENTS." ;;
      *) echo "PLAN: $category/$key -> $detail" ;;
    esac
  done < "$RESULTS"
}

run_upgrade() {
  print_results
  echo
  echo "UPGRADE REVIEW (read-only)"
  while IFS= read -r entry; do
    path="$(jq -r '.path' <<<"$entry")"; source="$(jq -r '.source' <<<"$entry")"
    target="$tmpdir/up-target-$RANDOM"; canon="$tmpdir/up-canon-$RANDOM"; err1="$target.err"; err2="$canon.err"
    fetch_raw_file "$REPO" "$BRANCH" "$path" "$target" "$err1" || true
    fetch_raw_file "$CANONICAL_REPO" "$CANONICAL_REF" "$source" "$canon" "$err2" || true
    if [[ -s "$canon" ]]; then
      if [[ -s "$target" ]]; then
        if ! cmp -s "$target" "$canon"; then
          echo "--- exact drift: $path"
          diff -u "$target" "$canon" || true
        fi
      else
        echo "--- exact missing: $path (canonical source $CANONICAL_REPO@$CANONICAL_REF:$source)"
      fi
    fi
  done < <(jq -c '.protocol.exact[]' "$MANIFEST")
  echo "Semantic files are never overwritten by upgrade; missing markers are listed in the audit above."
  echo "No files, GitHub settings, labels, permissions, Rulesets, commits, or PRs were changed."
}
