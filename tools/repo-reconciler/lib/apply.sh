# shellcheck shell=bash

run_apply() {
  if grep -q $'DRIFT\tlive\tlabel\t' "$RESULTS"; then
    color="$(jq -r '.required_label.color' "$MANIFEST")"
    desc="$(jq -r '.required_label.description' "$MANIFEST")"
    gh api --method POST "repos/$REPO/labels" -f name="$label_name" -f color="$color" -f description="$desc" >/dev/null
    echo "APPLY: created label $label_name"
  fi

  if grep -q $'DRIFT\tlive\tmerge_policy\t' "$RESULTS"; then
    gh api --method PATCH "repos/$REPO" -F allow_squash_merge=true -F allow_merge_commit=false -F allow_rebase_merge=false >/dev/null
    echo "APPLY: set squash-only repository merge policy"
  fi

  if grep -q $'DRIFT\tlive\treviewer\t' "$RESULTS"; then
    if [[ $ALLOW_PERMISSION_CHANGE -eq 1 ]]; then
      gh api --method PUT "repos/$REPO/collaborators/$REVIEWER" -f permission=push >/dev/null
      echo "APPLY: granted $REVIEWER write permission"
    else
      echo "SKIP: reviewer permission change requires --allow-permission-change"
    fi
  fi

  if grep -Eq $'DRIFT\t(exact|semantic)\t' "$RESULTS"; then
    if [[ $local_matches_target -ne 1 ]]; then
      echo "SKIP: protocol file reconciliation requires a local checkout of $REPO"
    else
      while IFS= read -r entry; do
        path="$(jq -r '.path' <<<"$entry")"; source="$(jq -r '.source' <<<"$entry")"
        canon="$tmpdir/apply-canon-$RANDOM"; err="$canon.err"
        fetch_raw_file "$CANONICAL_REPO" "$CANONICAL_REF" "$source" "$canon" "$err" || continue
        full="$local_root/$path"
        if [[ ! -e "$full" ]]; then
          mkdir -p "$(dirname "$full")"
          cp "$canon" "$full"
          echo "APPLY: added missing Exact file $path to working tree"
        elif ! cmp -s "$full" "$canon"; then
          if [[ $ALLOW_OVERWRITE -eq 1 ]]; then
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
          if fetch_raw_file "$CANONICAL_REPO" "$CANONICAL_REF" "$path" "$canon" "$err"; then
            mkdir -p "$(dirname "$full")"; cp "$canon" "$full"
            echo "APPLY: added missing Semantic file $path to working tree"
          fi
        else
          missing=0
          while IFS= read -r marker; do
            [[ -z "$marker" ]] && continue
            grep -Fq "$marker" "$full" || missing=1
          done < <(jq -r '.markers[]' <<<"$entry")
          if [[ $missing -eq 1 ]]; then
            echo "SKIP: $path exists but lacks protocol semantics; merge manually. It is never overwritten."
          fi
        fi
      done < <(jq -c '.protocol.semantic[]' "$MANIFEST")
    fi
  fi

  if [[ "$PHASE" == "active" && -n "$REQUIRED_CHECK" && $ACTIVATE -eq 1 ]]; then
    if [[ "$ruleset_read_state" == PASS && ! -s "$applicable_details" ]]; then
      check_seen=0
      pulls="$tmpdir/pulls.json"; perr="$tmpdir/pulls.err"
      if api_get "repos/$REPO/pulls?state=closed&base=$BRANCH&sort=updated&direction=desc&per_page=10" "$pulls" "$perr"; then
        while IFS= read -r sha; do
          [[ -z "$sha" || "$sha" == null ]] && continue
          checks="$tmpdir/checks-$sha.json"; cerr="$checks.err"
          if api_get "repos/$REPO/commits/$sha/check-runs?per_page=100" "$checks" "$cerr"; then
            if jq -e --arg c "$REQUIRED_CHECK" '.check_runs[]? | select(.name == $c and .conclusion == "success")' "$checks" >/dev/null; then check_seen=1; break; fi
          fi
          status="$tmpdir/status-$sha.json"; serr="$status.err"
          if api_get "repos/$REPO/commits/$sha/status" "$status" "$serr"; then
            if jq -e --arg c "$REQUIRED_CHECK" '.statuses[]? | select(.context == $c and .state == "success")' "$status" >/dev/null; then check_seen=1; break; fi
          fi
        done < <(jq -r '.[].head.sha' "$pulls")
      fi
      if [[ $check_seen -ne 1 ]]; then
        echo "SKIP: '$REQUIRED_CHECK' has no verified successful recent PR check; Phase B activation is blocked"
      else
        body="$tmpdir/ruleset-create.json"
        jq -n --arg check "$REQUIRED_CHECK" --arg branch "$BRANCH" '{
          name:"G-lite main",
          target:"branch",
          enforcement:"active",
          bypass_actors:[],
          conditions:{ref_name:{include:["~DEFAULT_BRANCH"],exclude:[]}},
          rules:[
            {type:"deletion"},
            {type:"non_fast_forward"},
            {type:"pull_request",parameters:{required_approving_review_count:1,dismiss_stale_reviews_on_push:true,require_code_owner_review:false,require_last_push_approval:false,required_review_thread_resolution:false,allowed_merge_methods:["squash"]}},
            {type:"required_status_checks",parameters:{strict_required_status_checks_policy:false,required_status_checks:[{context:$check}]}}
          ]
        }' > "$body"
        if gh api --method POST "repos/$REPO/rulesets" --input "$body" >/dev/null 2>"$tmpdir/ruleset-create.err"; then
          echo "APPLY: created active G-lite Ruleset for $BRANCH with Required Check '$REQUIRED_CHECK'"
        else
          state="$(api_error_state "$(cat "$tmpdir/ruleset-create.err")")"
          echo "SKIP: Ruleset creation failed [$state]: $(cat "$tmpdir/ruleset-create.err")"
        fi
      fi
    elif [[ -s "$applicable_details" ]]; then
      echo "SKIP: an applicable Ruleset already exists; apply never mutates existing project Rulesets automatically"
    fi
  elif [[ "$PHASE" == "active" && $ACTIVATE -eq 0 ]]; then
    echo "SKIP: active Ruleset creation requires --activate"
  fi

  echo
  echo "POST-APPLY: re-run 'audit' after committing/pushing any working-tree file changes."
}
