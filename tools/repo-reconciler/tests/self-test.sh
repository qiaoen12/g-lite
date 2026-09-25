# Sourced by reconcile.sh self-test after runtime state and modules are initialized.

write_preflight_self_test() (
  local calls="$tmpdir/write-calls" action missing status
  REPO="self-test/fixture"
  BRANCH="main"
  REQUIRED_CHECK="self-test-check"
  load_repository() { :; }
  auditor() { :; }
  print_results() { :; }
  overall_exit() { return 0; }
  run_bootstrap() { printf 'bootstrap\n' >> "$calls"; }
  run_activate() { printf 'activate\n' >> "$calls"; }
  run_apply() { printf 'apply\n' >> "$calls"; }

  for missing in human-authority developer reviewer; do
    for action in bootstrap activate apply; do
      HUMAN_AUTHORITY_VERIFIED=true
      DEVELOPER_APP_VERIFIED=true
      REVIEWER_APP_VERIFIED=true
      case "$missing" in
        human-authority) HUMAN_AUTHORITY_VERIFIED=false ;;
        developer) DEVELOPER_APP_VERIFIED=false ;;
        reviewer) REVIEWER_APP_VERIFIED=false ;;
      esac
      : > "$calls"
      status=0
      run_write_action "run_$action" >/dev/null 2>"$tmpdir/write-preflight.err" || status=$?
      [[ "$status" -eq 3 ]] || {
        echo "self-test failed: $action missing $missing assertion did not fail with exit 3" >&2
        return 1
      }
      [[ ! -s "$calls" ]] || {
        echo "self-test failed: $action missing $missing assertion reached a write" >&2
        return 1
      }
    done
  done
  echo "self-test: bootstrap/activate/apply missing Human Authority -> zero writes / fail before write: PASS"
  echo "self-test: bootstrap/activate/apply missing Developer assertion -> zero writes / fail before write: PASS"
  echo "self-test: bootstrap/activate/apply missing Reviewer assertion -> zero writes / fail before write: PASS"

  for action in bootstrap activate apply; do
    HUMAN_AUTHORITY_VERIFIED=true
    DEVELOPER_APP_VERIFIED=true
    REVIEWER_APP_VERIFIED=true
    : > "$calls"
    status=0
    run_write_action "run_$action" >/dev/null 2>"$tmpdir/write-preflight.err" || status=$?
    [[ "$status" -eq 0 && -s "$calls" ]] || {
      echo "self-test failed: $action with all write assertions did not reach mocked writes" >&2
      return 1
    }
  done
  echo "self-test: bootstrap/activate/apply with all three assertions -> mocked write path: PASS"

  HUMAN_AUTHORITY_VERIFIED=false
  DEVELOPER_APP_VERIFIED=false
  REVIEWER_APP_VERIFIED=false
  : > "$calls"
  status=0
  run_write_action run_apply >/dev/null 2>"$tmpdir/write-preflight.err" || status=$?
  [[ "$status" -eq 3 && ! -s "$calls" ]] || {
    echo "self-test failed: write assertions persisted into the next invocation" >&2
    return 1
  }
  echo "self-test: next invocation without assertions does not inherit prior authorization: PASS"
)

bootstrap_target_self_test() (
  # Exercise the real empty-repository PUT under nounset; this guards Bash 3.2's
  # treatment of an empty array expansion without making a GitHub write.
  [[ "$-" == *u* ]] || {
    echo "self-test failed: empty-branch regression must run with nounset enabled" >&2; return 1;
  }
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
  echo "self-test: nounset empty-array first PUT omits branch and succeeds: PASS"

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

existing_behavior_self_test() (
  local fixture="$tmpdir/ruleset.json" mutated="$tmpdir/ruleset-mutated.json"
  local permission_error="$tmpdir/permission.err" platform_error="$tmpdir/platform.err"
  local app_exit=0 drift_exit=0 developer reviewer expected role state
  write_preflight_self_test
  # Both missing, either missing, both present, then absent again: no persistence.
  REPO="self-test/fixture"
  for pair in "false false" "true false" "false true" "true true" "false false"; do
    read -r developer reviewer <<< "$pair"
    DEVELOPER_APP_VERIFIED="$developer"
    REVIEWER_APP_VERIFIED="$reviewer"
    : > "$RESULTS"
    audit_apps
    app_exit=0
    overall_exit || app_exit=$?
    expected=3
    if [[ "$developer" == true && "$reviewer" == true ]]; then expected=0; fi
    [[ "$app_exit" -eq "$expected" ]] || {
      echo "self-test failed: dual App assertions exit status" >&2; return 1;
    }
    for role in developer reviewer; do
      state=UNVERIFIED
      if [[ "$role" == developer && "$developer" == true ]] ||
         [[ "$role" == reviewer && "$reviewer" == true ]]; then state=PASS; fi
      grep -q "^${state}"$'\tlive\t'"${role}_app"$'\t' "$RESULTS" || return 1
    done
  done
  : > "$RESULTS"
  echo "self-test: both App assertions / partial preflight / no persistence: PASS"
  # Role-driven markers accept an unbound consumer, reject missing role semantics.
  (
    local marker_source="$ROOT/tools/repo-reconciler/templates/minimal-consumer-AGENTS.md"
    local omitted="" marker
    contents_get() {
      local source
      source="$(source_file_for "$1")"
      if [[ "$1" == AGENTS.md && -n "$omitted" ]]; then
        sed "/$omitted/d" "$marker_source" > "$tmpdir/consumer-markers.txt"
        source="$tmpdir/consumer-markers.txt"
      else
        source="$ROOT/$source"
      fi
      jq -n --arg content "$(encode_file "$source")" '{type:"file",content:$content}' > "$2"
    }
    : > "$RESULTS"
    marker_audit
    overall_exit
    for marker in "Human Authority" "Local Bootstrap" "Developer" "Reviewer"; do
      omitted="$marker"
      : > "$RESULTS"
      marker_audit
      grep -q $'^DRIFT\tmarkers\tAGENTS.md\t' "$RESULTS" || {
        echo "self-test failed: missing consumer role marker accepted" >&2; exit 1;
      }
    done
  )
  : > "$RESULTS"
  echo "self-test: portable consumer markers / missing role semantics: PASS"
  RULESET_NAME="G-lite main"
  BRANCH="main"
  DEFAULT_BRANCH="main"
  REQUIRED_CHECK="new-check"
  cat > "$fixture" <<'JSON'
{"name":"G-lite main","target":"branch","enforcement":"active","bypass_actors":[],"conditions":{"ref_name":{"include":["refs/heads/main"]}},"rules":[{"type":"deletion"},{"type":"non_fast_forward"},{"type":"pull_request","parameters":{"required_approving_review_count":1,"dismiss_stale_reviews_on_push":true,"require_code_owner_review":false,"require_last_push_approval":false,"required_review_thread_resolution":false,"allowed_merge_methods":["squash"]}},{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"old-check"}]}}]}
JSON
  ruleset_governance_is_desired "$fixture"
  local field mutation
  for field in require_code_owner_review required_review_thread_resolution; do
    for mutation in missing true; do
      jq --arg field "$field" --arg mutation "$mutation" '
        .rules |= map(if .type == "pull_request" then
          if $mutation == "missing" then del(.parameters[$field])
          else .parameters[$field] = true end
        else . end)
      ' "$fixture" > "$mutated"
      if ruleset_governance_is_desired "$mutated"; then
        echo "self-test failed: $field $mutation was accepted" >&2
        return 1
      fi
      make_ruleset_payload "$mutated" "$tmpdir/payload-repaired.json"
      ruleset_governance_is_desired "$tmpdir/payload-repaired.json"
    done
  done
  echo "self-test: required PR parameters missing / true => not desired; repair => PASS"
  local exclusion
  for exclusion in refs/heads/main main '~ALL' '~DEFAULT_BRANCH' 'refs/heads/*' 'refs/heads/m*'; do
    jq --arg exclusion "$exclusion" '.conditions.ref_name.exclude = [$exclusion]' "$fixture" > "$mutated"
    if ruleset_applies_to_branch "$mutated" || ruleset_governance_is_desired "$mutated"; then
      echo "self-test failed: exclusion $exclusion was accepted" >&2
      return 1
    fi
  done
  jq '.conditions.ref_name.exclude = ["refs/heads/develop"]' "$fixture" > "$mutated"
  ruleset_applies_to_branch "$mutated"
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
  local payload
  for payload in "$tmpdir/payload-existing.json" "$tmpdir/payload-new.json" "$tmpdir/payload-repaired.json"; do
    ruleset_governance_is_desired "$payload"
    jq -e '
      [.rules[] | select(.type == "pull_request") | .parameters] == [{
        required_approving_review_count: 1,
        dismiss_stale_reviews_on_push: true,
        require_code_owner_review: false,
        require_last_push_approval: false,
        required_review_thread_resolution: false,
        allowed_merge_methods: ["squash"]
      }]
    ' "$payload" >/dev/null
  done
  echo "self-test: create / update pull_request payload schema: PASS"
  jq '.rules |= map(if .type == "required_status_checks" then .parameters.required_status_checks = [] else . end)' "$fixture" > "$mutated"
  if ruleset_check_is_desired "$mutated"; then
    echo "self-test failed: missing Required Check was accepted" >&2
    return 1
  fi

  jq '.rules |= map(if .type == "required_status_checks" then .parameters.required_status_checks = [{context:"consumer-content"},{context:"stale-check"}] else . end)' "$fixture" > "$mutated"
  REQUIRED_CHECK="consumer-content"
  load_named_ruleset() {
    RULESET_ID=1
    RULESET_FILE="$mutated"
    RULESET_IDS=(1)
    RULESET_FILES=("$mutated")
    RULESET_UNSAFE_IDS=()
    RULESET_UNSAFE_FILES=()
    RULESET_CONFLICT_IDS=() RULESET_CONFLICT_FILES=()
    RULESET_MERGED_FILE="$tmpdir/old-test-extras.json"
    printf '[]\n' > "$RULESET_MERGED_FILE"
    return 0
  }
  : > "$RESULTS"
  audit_ruleset
  drift_exit=0
  overall_exit || drift_exit=$?
  if [[ "$drift_exit" -ne 2 ]] ||
    ! grep -Fq $'DRIFT\tlive\trequired_check\t' "$RESULTS" ||
    ! grep -Fq "Required Check configuration does not exactly match target 'consumer-content'" "$RESULTS"; then
    echo "self-test failed: extra Required Check must keep exact-match DRIFT / exit 2 with precise wording" >&2
    return 1
  fi
  echo "self-test: target Required Check plus extra context => exact-match DRIFT / exit 2 with precise wording: PASS"

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
)
label_self_test() (
  local mock_labels_file="$tmpdir/self-test-labels.json" captured_payload="$tmpdir/self-test-label-payload.json"
  local manifest="$MANIFEST" name color description
  name="$(jq -r '.required_label.name' "$manifest")"
  color="$(jq -r '.required_label.color' "$manifest")"
  description="$(jq -r '.required_label.description' "$manifest")"
  jq -n --arg name "$name" --arg color "$color" --arg description "$description" \
    '[{name:$name,color:$color,description:$description},{name:"bug",color:"ffffff",description:"consumer label"}]' > "$mock_labels_file"
  api_get() { cp "$mock_labels_file" "$2"; }
  : > "$RESULTS"
  audit_label
  grep -q $'^PASS\tlive\tlabel\t' "$RESULTS" || {
    echo "self-test failed: exact label metadata was not accepted" >&2; return 1;
  }
  jq '.[0].color = "abcdef"' "$mock_labels_file" > "$tmpdir/label-drift.json"
  cp "$tmpdir/label-drift.json" "$mock_labels_file"
  : > "$RESULTS"
  audit_label
  grep -q $'^DRIFT\tlive\tlabel\t' "$RESULTS" || {
    echo "self-test failed: label color drift was accepted" >&2; return 1;
  }
  gh() {
    [[ "$3" == PATCH && "$4" == "repos/$REPO/labels/$name" && "$5" == --input ]] || return 99
    cp "$6" "$captured_payload"
  }
  ensure_label >/dev/null
  jq -e --arg color "$color" --arg description "$description" \
    '.color == $color and .description == $description' "$captured_payload" >/dev/null || {
    echo "self-test failed: label repair payload did not match canonical metadata" >&2; return 1;
  }
  local rename_calls="$tmpdir/case-label-calls"
  jq -n --arg color "$color" --arg description "$description" \
    '[{name:"Approved",color:$color,description:"legacy description"},{name:"bug",color:"ffffff",description:"consumer label"}]' \
    > "$mock_labels_file"
  : > "$rename_calls"
  gh() {
    if [[ "$3" == PATCH && "$4" == "repos/$REPO/labels/Approved" && "$5" == --input ]]; then
      cp "$6" "$captured_payload"
      jq --slurpfile patch "$6" '
        map(if .name == "Approved" then
          .name = $patch[0].new_name | .color = $patch[0].color | .description = $patch[0].description
        else . end)
      ' "$mock_labels_file" > "$tmpdir/case-label-next.json"
      cp "$tmpdir/case-label-next.json" "$mock_labels_file"
      printf 'PATCH\n' >> "$rename_calls"
    elif [[ "$3" == POST ]]; then
      printf 'POST\n' >> "$rename_calls"
    else
      return 99
    fi
  }
  ensure_label >/dev/null
  jq -e --arg name "$name" --arg color "$color" --arg description "$description" \
    '.new_name == $name and .color == $color and .description == $description' "$captured_payload" >/dev/null || {
    echo "self-test failed: case-equivalent label was not renamed with exact canonical metadata" >&2; return 1;
  }
  label_metadata_is_desired "$mock_labels_file" &&
    jq -e --arg name "$name" '[.[] | select((.name | ascii_downcase) == ($name | ascii_downcase))] | length == 1' \
      "$mock_labels_file" >/dev/null &&
    jq -e 'any(.[]; .name == "bug" and .description == "consumer label")' "$mock_labels_file" >/dev/null || {
      echo "self-test failed: label rename did not preserve consumer labels or unique canonical name" >&2; return 1;
    }
  ensure_label >/dev/null
  [[ "$(cat "$rename_calls")" == PATCH ]] || {
    echo "self-test failed: case-equivalent label migration was not idempotent or created a label" >&2; return 1;
  }
  jq -n '[{name:"G-lite approved",color:"ffffff",description:"legacy"},
    {name:"consumer-approved",color:"eeeeee",description:"consumer label"}]' > "$mock_labels_file"
  : > "$rename_calls"
  : > "$RESULTS"
  audit_label
  grep -q $'^DRIFT\tlive\tlabel\t' "$RESULTS" || {
    echo "self-test failed: known legacy label was accepted as final PASS" >&2; return 1;
  }
  gh() {
    [[ "$3" == PATCH && "$4" == "repos/$REPO/labels/G-lite%20approved" && "$5" == --input ]] || return 99
    jq --slurpfile patch "$6" 'map(if .name == "G-lite approved" then
      .name = $patch[0].new_name | .color = $patch[0].color | .description = $patch[0].description
    else . end)' "$mock_labels_file" > "$tmpdir/legacy-label-next.json"
    cp "$tmpdir/legacy-label-next.json" "$mock_labels_file"
    printf 'PATCH\n' >> "$rename_calls"
  }
  ensure_label >/dev/null
  ensure_label >/dev/null
  : > "$RESULTS"
  audit_label
  [[ "$(cat "$rename_calls")" == PATCH ]] && label_metadata_is_desired "$mock_labels_file" &&
    grep -q $'^PASS\tlive\tlabel\t' "$RESULTS" &&
    jq -e 'any(.[]; .name == "consumer-approved" and .description == "consumer label")' \
      "$mock_labels_file" >/dev/null || {
        echo "self-test failed: known legacy label did not converge in place or was not idempotent" >&2; return 1;
      }
  jq -n '[{name:"approved",color:"0e8a16",description:"canonical"},
    {name:"G-lite approved",color:"ffffff",description:"legacy"}]' > "$mock_labels_file"
  : > "$rename_calls"
  : > "$WRITE_RESULTS"
  ensure_label >/dev/null 2>&1 && {
    echo "self-test failed: ambiguous owned labels were modified" >&2; return 1;
  }
  [[ ! -s "$rename_calls" ]] && grep -q $'^DRIFT\tlive\tlabel\t' "$WRITE_RESULTS" || return 1
  printf '[{"color":"ffffff"}]\n' > "$mock_labels_file"
  : > "$RESULTS"
  : > "$WRITE_RESULTS"
  audit_label
  ensure_label >/dev/null 2>&1 && return 1
  grep -q $'^UNVERIFIED\tlive\tlabel\t' "$RESULTS" &&
    grep -q $'^UNVERIFIED\tlive\tlabel\t' "$WRITE_RESULTS" || {
      echo "self-test failed: malformed label inventory did not fail closed" >&2; return 1;
    }
  jq -n '[{name:"approved",color:"ffffff",description:"drift"}]' > "$mock_labels_file"
  local message expected
  for expected in PERMISSION_BLOCKER PLATFORM_BLOCKER UNVERIFIED; do
    case "$expected" in
      PERMISSION_BLOCKER) message='HTTP 403 Forbidden' ;;
      PLATFORM_BLOCKER) message='feature is not available for this repository' ;;
      UNVERIFIED) message='HTTP 500 Internal Server Error' ;;
    esac
    gh() { printf '%s\n' "$message" >&2; return 1; }
    : > "$WRITE_RESULTS"
    ensure_label >/dev/null 2>&1 && return 1
    grep -q "^${expected}"$'\twrite\tlabel\t' "$WRITE_RESULTS" || {
      echo "self-test failed: label write error was not classified $expected" >&2; return 1;
    }
  done
  echo "self-test: exact/legacy label convergence, ambiguity, blockers, and idempotency: PASS"
)

paginated_inventory_self_test() (
  local out="$tmpdir/paginated-inventory.json" error="$tmpdir/paginated-inventory.err"
  local calls="$tmpdir/paginated-inventory-calls"
  : > "$calls"
  gh() {
    [[ "$1" == api && "$2" == --paginate && "$3" == --slurp && "$4" == --method && "$5" == GET ]] || return 99
    printf '%s\n' "$6" >> "$calls"
    printf '[[{"id":1}],[{"id":2}]]\n'
  }
  api_get "repos/$REPO/rulesets?includes_parents=true&per_page=100" "$out" "$error"
  jq -e 'map(.id) == [1,2]' "$out" >/dev/null || return 1
  api_get "repos/$REPO/labels?per_page=100" "$out" "$error"
  jq -e 'map(.id) == [1,2]' "$out" >/dev/null || return 1
  [[ "$(wc -l < "$calls" | tr -d ' ')" == 2 ]] || return 1
  gh() { printf '[{"incomplete":true}]\n'; }
  api_get "repos/$REPO/rulesets?includes_parents=true&per_page=100" "$out" "$error" && {
    echo "self-test failed: malformed paginated Ruleset inventory was accepted" >&2; return 1;
  }
  echo "self-test: labels and Rulesets enumerate all pages or fail closed: PASS"
)

repository_settings_self_test() (
  local mock_repo_file="$tmpdir/self-test-repository.json" captured_patch="$tmpdir/self-test-settings-patch.json"
  jq -n --slurpfile manifest "$MANIFEST" \
    '$manifest[0].repository_settings + {default_branch:"main",has_wiki:true}' > "$mock_repo_file"
  api_get() { cp "$mock_repo_file" "$2"; }
  : > "$RESULTS"
  audit_repository_settings
  grep -q $'^PASS\tlive\trepository_settings\t' "$RESULTS" || {
    echo "self-test failed: canonical repository settings were not accepted" >&2; return 1;
  }
  jq '.allow_rebase_merge = true' "$mock_repo_file" > "$tmpdir/repository-drift.json"
  cp "$tmpdir/repository-drift.json" "$mock_repo_file"
  : > "$RESULTS"
  audit_repository_settings
  grep -q $'^DRIFT\tlive\trepository_settings\t' "$RESULTS" || {
    echo "self-test failed: repository merge setting drift was accepted" >&2; return 1;
  }
  gh() {
    [[ "$3" == PATCH && "$4" == "repos/$REPO" && "$5" == --input ]] || return 99
    cp "$6" "$captured_patch"
  }
  ensure_repository_settings >/dev/null
  jq -e --slurpfile manifest "$MANIFEST" '. == $manifest[0].repository_settings' "$captured_patch" >/dev/null || {
    echo "self-test failed: repository repair changed settings outside G-lite ownership" >&2; return 1;
  }
  echo "self-test: exact merge settings audit and scoped repair: PASS"
)

security_self_test() (
  local mock_repo_file="$tmpdir/self-test-security.json"
  jq -n '{security_and_analysis:{secret_scanning:{status:"enabled"},secret_scanning_push_protection:{status:"enabled"}}}' > "$mock_repo_file"
  REPOSITORY_FILE="$mock_repo_file"
  : > "$RESULTS"
  audit_security
  grep -q $'^PASS\tlive\tsecret_scanning\t' "$RESULTS" &&
    grep -q $'^PASS\tlive\tsecret_scanning_push_protection\t' "$RESULTS" || {
      echo "self-test failed: supported enabled security baseline was not accepted" >&2; return 1;
    }
  jq '.security_and_analysis.secret_scanning_push_protection.status = "not_available"' "$mock_repo_file" > "$tmpdir/security-unsupported.json"
  REPOSITORY_FILE="$tmpdir/security-unsupported.json"
  : > "$RESULTS"
  audit_security
  grep -q $'^PLATFORM_BLOCKER\tlive\tsecret_scanning_push_protection\t' "$RESULTS" || {
    echo "self-test failed: unsupported security capability was not a PLATFORM_BLOCKER" >&2; return 1;
  }
  error="$tmpdir/security-permission.err"
  jq '.security_and_analysis.secret_scanning.status = "disabled"' "$mock_repo_file" > "$tmpdir/security-disabled.json"
  api_get() { cp "$tmpdir/security-disabled.json" "$2"; }
  gh() { printf 'HTTP 403 Forbidden\n' >&2; return 1; }
  : > "$WRITE_RESULTS"
  ensure_security_setting secret_scanning >/dev/null 2>&1 && {
    echo "self-test failed: denied security write was accepted" >&2; return 1;
  }
  grep -q $'^PERMISSION_BLOCKER\twrite\tsecret_scanning\t' "$WRITE_RESULTS" || {
    echo "self-test failed: security write permission failure was not explicit" >&2; return 1;
  }
  api_get() { printf 'HTTP 403 Forbidden\n' > "$3"; return 1; }
  REPOSITORY_FILE=""
  : > "$RESULTS"
  audit_repository_settings
  audit_security
  grep -q $'^PERMISSION_BLOCKER\tlive\trepository_settings\t' "$RESULTS" &&
    grep -q $'^PERMISSION_BLOCKER\tlive\tsecurity_and_analysis\t' "$RESULTS" || {
      echo "self-test failed: security read permission failure was not explicit" >&2; return 1;
    }
  if [[ "$(api_error_state 'feature is not available for this repository')" != PLATFORM_BLOCKER ]]; then
    echo "self-test failed: unsupported platform API error was not classified" >&2; return 1
  fi
  echo "self-test: security support and permission blockers are explicit: PASS"
)

ruleset_self_test() (
  local base="$tmpdir/self-test-ruleset-base.json" active="$tmpdir/self-test-ruleset-active.json"
  local damaged="$tmpdir/self-test-ruleset-damaged.json" extras="$tmpdir/self-test-rule-extras.json"
  RULESET_NAME="$(jq -r '.ruleset.name' "$MANIFEST")"
  BRANCH="main"
  DEFAULT_BRANCH="main"
  REQUIRED_CHECK=""
  printf '[]\n' > "$extras"
  RULESET_MERGED_FILE="$extras"
  make_ruleset_payload "" "$base" bootstrap
  ruleset_governance_is_desired "$base" && ruleset_has_no_required_check "$base" || {
    echo "self-test failed: BOOTSTRAPPED Ruleset was not canonical or contained CI" >&2; return 1;
  }
  jq -e '[.rules[] | select(.type == "required_status_checks")] | length == 0' "$base" >/dev/null || return 1

  local mock_ruleset="$base"
  load_named_ruleset() {
    RULESET_ID=80 RULESET_FILE="$mock_ruleset"
    RULESET_IDS=(80) RULESET_FILES=("$mock_ruleset")
    RULESET_UNSAFE_IDS=() RULESET_UNSAFE_FILES=()
    RULESET_CONFLICT_IDS=() RULESET_CONFLICT_FILES=()
    RULESET_MERGED_FILE="$extras"
    return 0
  }
  : > "$RESULTS"
  PHASE="bootstrap"
  audit_ruleset
  grep -q $'^PASS\tlive\trequired_check\tBOOTSTRAPPED defers' "$RESULTS" || {
    echo "self-test failed: BOOTSTRAPPED audit required a CI check" >&2; return 1;
  }
  REQUIRED_CHECK=""
  PHASE="active"
  : > "$RESULTS"
  audit_ruleset
  grep -q $'^UNVERIFIED\tlive\trequired_check\tactive audit requires' "$RESULTS" || {
    echo "self-test failed: active audit inferred a Required Check" >&2; return 1;
  }

  REQUIRED_CHECK="consumer CI / linux"
  make_ruleset_payload "$base" "$active" active
  mock_ruleset="$active"
  ruleset_check_is_desired "$active" || {
    echo "self-test failed: exact supplied Required Check was not bound" >&2; return 1;
  }
  jq -e --arg context "$REQUIRED_CHECK" '
    [.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]?.context] == [$context]
  ' "$active" >/dev/null || return 1
  : > "$RESULTS"
  audit_ruleset
  grep -q $'^PASS\tlive\trequired_check\texact Required Check context' "$RESULTS" || {
    echo "self-test failed: ACTIVE audit did not accept exact Required Check" >&2; return 1;
  }
  audit_foundation() { :; }
  local live_check_api_called=false
  api_get() { live_check_api_called=true; return 99; }
  : > "$RESULTS"
  auditor
  grep -q $'^PASS\tlive\truleset\t' "$RESULTS" &&
    grep -q $'^PASS\tlive\trequired_check\t' "$RESULTS" &&
    [[ "$live_check_api_called" == false ]] || {
      echo "self-test failed: ordinary ACTIVE audit did not verify only exact Ruleset configuration" >&2; return 1;
    }
  jq '.rules |= map(if .type == "required_status_checks" then .parameters.required_status_checks += [{context:"stale-alias"}] else . end)' "$active" > "$damaged"
  if ruleset_check_is_desired "$damaged"; then
    echo "self-test failed: Required Check alias was accepted" >&2; return 1
  fi
  jq '.rules |= map(if .type == "pull_request" then del(.parameters.require_code_owner_review) else . end)' "$active" > "$damaged"
  if ruleset_governance_is_desired "$damaged"; then
    echo "self-test failed: incomplete PR governance was accepted" >&2; return 1
  fi
  make_ruleset_payload "$damaged" "$tmpdir/ruleset-repaired.json" active
  ruleset_governance_is_desired "$tmpdir/ruleset-repaired.json" || return 1
  jq '.conditions.ref_name.include = ["~ALL"]' "$active" > "$damaged"
  if ruleset_governance_is_desired "$damaged"; then
    echo "self-test failed: broad Ruleset scope was accepted as canonical" >&2; return 1
  fi
  echo "self-test: base/active Ruleset exact semantics and explicit Required Check: PASS"
)

ruleset_live_normalization_self_test() (
  local fixture="$SCRIPT_DIR/tests/fixtures/pilot-ruleset-live.json"
  local live="$tmpdir/pilot-live-ruleset.json" calls="$tmpdir/pilot-ruleset-calls"
  local output="$tmpdir/pilot-ruleset-write.json" status=0
  REPO="self-test/fixture" BRANCH="main" DEFAULT_BRANCH="main"
  REQUIRED_CHECK="" PHASE="bootstrap"
  RULESET_NAME="$(jq -r '.ruleset.name' "$MANIFEST")"
  cp "$fixture" "$live"
  : > "$calls"
  api_get() {
    case "$1" in
      "repos/$REPO/rulesets?"*) printf '[{"id":23930344,"source_type":"Repository"}]\n' > "$2" ;;
      "repos/$REPO/rulesets/23930344") cp "$live" "$2" ;;
      *) return 99 ;;
    esac
  }
  gh() {
    [[ "$3" == PUT && "$4" == "repos/$REPO/rulesets/23930344" ]] || return 99
    printf 'PUT\n' >> "$calls"
    cp "$6" "$output"
    jq '. + {id:23930344,source_type:"Repository"} |
      .rules |= map(if .type == "pull_request" then
        .parameters += {require_extra_approval_for_unattributed_changes:true,required_reviewers:[]}
      else . end)' "$output" > "$live"
  }

  : > "$RESULTS"
  audit_ruleset
  grep -q $'^PASS\tlive\truleset\t' "$RESULTS" &&
    grep -q $'^PASS\tlive\trequired_check\t' "$RESULTS" || {
      echo "self-test failed: Pilot live normalized Ruleset did not audit as BOOTSTRAPPED" >&2; return 1;
    }
  ensure_base_ruleset >/dev/null
  ensure_base_ruleset >/dev/null
  [[ ! -s "$calls" ]] || {
    echo "self-test failed: normalized Ruleset caused a redundant PUT on repeated apply" >&2; return 1;
  }

  jq '.rules |= map(if .type == "pull_request" then
    .parameters.required_approving_review_count = 2 else . end)' "$fixture" > "$live"
  : > "$RESULTS"
  audit_ruleset
  grep -q $'^DRIFT\tlive\truleset\t' "$RESULTS" || {
    echo "self-test failed: wrong G-lite-owned PR parameter passed audit" >&2; return 1;
  }
  ensure_base_ruleset >/dev/null
  ensure_base_ruleset >/dev/null
  [[ "$(cat "$calls")" == PUT ]] || {
    echo "self-test failed: owned drift did not converge exactly once after GitHub normalization" >&2; return 1;
  }
  ruleset_governance_is_desired "$live" || return 1

  jq '.rules |= map(if .type == "pull_request" then
    .parameters += {consumer_custom_policy:"keep"} |
    .parameters.required_approving_review_count = 2 else . end)' "$fixture" > "$live"
  : > "$calls"
  : > "$WRITE_RESULTS"
  status=0
  ensure_base_ruleset >/dev/null || status=$?
  [[ "$status" -ne 0 && ! -s "$calls" ]] &&
    grep -q $'^DRIFT\tlive\truleset\tPR parameters outside G-lite ownership' "$WRITE_RESULTS" || {
      echo "self-test failed: unknown nonempty PR parameter was discarded by PUT" >&2; return 1;
    }
  jq '.rules |= map(if .type == "pull_request" then
    .parameters |= del(.consumer_custom_policy) |
    .parameters.required_reviewers = [{reviewer_type:"Team",reviewer_id:1}] else . end)' "$live" > "$output"
  cp "$output" "$live"
  : > "$WRITE_RESULTS"
  status=0
  ensure_base_ruleset >/dev/null || status=$?
  [[ "$status" -ne 0 && ! -s "$calls" ]] || {
    echo "self-test failed: nonempty required_reviewers was discarded by PUT" >&2; return 1;
  }
  echo "self-test: Pilot normalized PR fields audit PASS, repeated apply inert, owned drift exact, extra policy fail closed: PASS"
)

ruleset_migration_self_test() (
  local legacy="$tmpdir/legacy-ruleset.json" duplicate="$tmpdir/duplicate-ruleset.json"
  local canonical="$tmpdir/migrated-ruleset.json" extras="$tmpdir/migration-extras.json"
  local calls="$tmpdir/ruleset-migration-calls" state="legacy"
  RULESET_NAME="$(jq -r '.ruleset.name' "$MANIFEST")"
  BRANCH="main"
  DEFAULT_BRANCH="main"
  REQUIRED_CHECK=""
  make_ruleset_payload "" "$tmpdir/migration-base.json" bootstrap
  jq '.name = "G-lite main legacy" | .rules[2].parameters.required_approving_review_count = 2' \
    "$tmpdir/migration-base.json" > "$legacy"
  jq '.name = "G-lite main v3" ' "$legacy" > "$duplicate"
  printf '[{"type":"required_linear_history"}]\n' > "$extras"
  : > "$calls"
  load_named_ruleset() {
    RULESET_UNSAFE_IDS=() RULESET_UNSAFE_FILES=()
    RULESET_CONFLICT_IDS=() RULESET_CONFLICT_FILES=()
    RULESET_MERGED_FILE="$extras"
    if [[ "$state" == legacy ]]; then
      RULESET_ID=41 RULESET_FILE="$legacy"
      RULESET_IDS=(41 42) RULESET_FILES=("$legacy" "$duplicate")
    else
      RULESET_ID=41 RULESET_FILE="$canonical"
      RULESET_IDS=(41) RULESET_FILES=("$canonical")
      RULESET_MERGED_FILE="$tmpdir/empty-rule-extras.json"
      printf '[]\n' > "$RULESET_MERGED_FILE"
    fi
    return 0
  }
  gh() {
    case "$3" in
      PUT)
        printf 'PUT:%s\n' "$4" >> "$calls"
        cp "$6" "$canonical"
        state="canonical"
        ;;
      DELETE)
        printf 'DELETE:%s\n' "$4" >> "$calls"
        ;;
      POST)
        printf 'POST:%s\n' "$4" >> "$calls"
        ;;
      *) return 99 ;;
    esac
  }
  ensure_base_ruleset >/dev/null
  [[ "$(cat "$calls")" == $'PUT:repos/'"$REPO"$'/rulesets/41\nDELETE:repos/'"$REPO"$'/rulesets/42' ]] || {
    echo "self-test failed: legacy Rulesets were not migrated/consolidated without creating another" >&2; return 1;
  }
  jq -e '
    .name == "G-lite main" and
    ([.rules[] | select(.type == "required_status_checks")] | length == 0) and
    any(.rules[]; .type == "required_linear_history")
  ' "$canonical" >/dev/null || {
    echo "self-test failed: migration did not preserve unrelated Ruleset rules or omit CI" >&2; return 1;
  }
  local first_count
  first_count="$(wc -l < "$calls" | tr -d ' ')"
  ensure_base_ruleset >/dev/null
  [[ "$(wc -l < "$calls" | tr -d ' ')" == "$first_count" ]] || {
    echo "self-test failed: second base reconcile was not idempotent" >&2; return 1;
  }
  echo "self-test: legacy Ruleset migration, duplicate cleanup, and retry idempotency: PASS"
)

ruleset_overlap_self_test() (
  local fixture_list="$tmpdir/overlap-list.json" canonical="$tmpdir/overlap-canonical.json"
  local legacy="$tmpdir/overlap-legacy.json" unknown="$tmpdir/overlap-unknown.json"
  local unrelated="$tmpdir/overlap-unrelated.json" calls="$tmpdir/overlap-calls"
  local rule11="$tmpdir/overlap-rule-11.json" rule22="$tmpdir/overlap-rule-22.json"
  local rule33="$tmpdir/overlap-rule-33.json"
  REPO="self-test/fixture"
  BRANCH="main" DEFAULT_BRANCH="main" REQUIRED_CHECK="" PHASE="bootstrap"
  RULESET_NAME="$(jq -r '.ruleset.name' "$MANIFEST")"
  make_ruleset_payload "" "$canonical" bootstrap
  jq '. + {id:11}' "$canonical" > "$rule11"
  jq '. + {id:11,name:"G-lite main legacy"}' "$canonical" > "$legacy"
  jq '. + {id:22,name:"consumer protection"}' "$canonical" > "$unknown"
  jq '. + {id:22,name:"consumer dev",source_type:"Organization"} |
    .conditions.ref_name.include = ["refs/heads/dev"]' \
    "$canonical" > "$unrelated"
  : > "$calls"
  api_get() {
    case "$1" in
      "repos/$REPO/rulesets?"*) cp "$fixture_list" "$2" ;;
      "repos/$REPO/rulesets/11") cp "$rule11" "$2" ;;
      "repos/$REPO/rulesets/22") cp "$rule22" "$2" ;;
      "repos/$REPO/rulesets/33") cp "$rule33" "$2" ;;
      *) printf 'unexpected Ruleset GET: %s\n' "$1" >&2; return 99 ;;
    esac
  }
  gh() {
    case "$3" in
      PUT)
        printf 'PUT:%s\n' "$4" >> "$calls"
        jq '. + {id:11}' "$6" > "$rule11"
        ;;
      POST)
        printf 'POST:%s\n' "$4" >> "$calls"
        jq '. + {id:33}' "$6" > "$rule33"
        jq '. + [{id:33}]' "$fixture_list" > "$tmpdir/overlap-list-next.json"
        cp "$tmpdir/overlap-list-next.json" "$fixture_list"
        ;;
      *) return 99 ;;
    esac
  }

  # Exact canonical Ruleset is reused without a write.
  printf '[{"id":11}]\n' > "$fixture_list"
  ensure_base_ruleset >/dev/null
  [[ ! -s "$calls" ]] || return 1

  # A known legacy name migrates at the same id and a second apply is inert.
  cp "$legacy" "$rule11"
  ensure_base_ruleset >/dev/null
  ensure_base_ruleset >/dev/null
  [[ "$(cat "$calls")" == "PUT:repos/$REPO/rulesets/11" ]] &&
    ruleset_governance_is_desired "$rule11" || {
      echo "self-test failed: known legacy Ruleset did not migrate in place exactly once" >&2; return 1;
    }

  # Unknown ownership on the target branch blocks even a present canonical rule.
  cp "$unknown" "$rule22"
  printf '[{"id":11},{"id":22}]\n' > "$fixture_list"
  : > "$calls"
  : > "$WRITE_RESULTS"
  ensure_base_ruleset >/dev/null 2>&1 && return 1
  : > "$RESULTS"
  audit_ruleset
  [[ ! -s "$calls" ]] && grep -q $'^DRIFT\tlive\truleset\t' "$RESULTS" &&
    ! grep -q $'^PASS\tlive\truleset\t' "$RESULTS" || {
      echo "self-test failed: unknown overlapping Ruleset was accepted or modified" >&2; return 1;
    }
  jq '.conditions.ref_name.include = ["refs/heads/*"]' "$unknown" > "$rule22"
  : > "$calls"
  ensure_base_ruleset >/dev/null 2>&1 && return 1
  [[ ! -s "$calls" ]] || {
    echo "self-test failed: unknown wildcard Ruleset overlap was ignored" >&2; return 1;
  }
  jq '.name = "G-lite main" | del(.source_type)' "$unknown" > "$rule22"
  printf '[{"id":11},{"id":22,"source_type":"Organization"}]\n' > "$fixture_list"
  : > "$calls"
  ensure_base_ruleset >/dev/null 2>&1 && return 1
  [[ ! -s "$calls" ]] || {
    echo "self-test failed: organization Ruleset was treated as repository-owned" >&2; return 1;
  }

  # A provably disjoint consumer Ruleset is preserved while canonical is created once.
  cp "$unrelated" "$rule22"
  printf '[{"id":22}]\n' > "$fixture_list"
  : > "$calls"
  : > "$WRITE_RESULTS"
  ensure_base_ruleset >/dev/null
  ensure_base_ruleset >/dev/null
  [[ "$(cat "$calls")" == "POST:repos/$REPO/rulesets" ]] &&
    jq -e '.name == "consumer dev" and .conditions.ref_name.include == ["refs/heads/dev"]' \
      "$rule22" >/dev/null &&
    ruleset_governance_is_desired "$rule33" || {
      echo "self-test failed: disjoint consumer Ruleset blocked canonical creation or retry duplicated it" >&2; return 1;
    }
  echo "self-test: canonical reuse, known legacy migration, unknown overlap block, disjoint preservation: PASS"
)

apply_required_check_rejection_self_test() (
  local calls="$tmpdir/apply-check-calls" output="$tmpdir/apply-check-cli.err" status=0
  : > "$calls"
  REQUIRED_CHECK="consumer / linux"
  PHASE="active"
  run_bootstrap() { printf 'bootstrap\n' >> "$calls"; }
  run_activate() { printf 'activate\n' >> "$calls"; }
  run_apply || status=$?
  [[ "$status" -eq 64 && ! -s "$calls" ]] || {
    echo "self-test failed: run_apply accepted --required-check or started governance writes" >&2; return 1;
  }

  REQUIRED_CHECK=""
  PHASE="active"
  : > "$calls"
  run_bootstrap() {
    [[ "$PHASE" == bootstrap ]] || return 99
    printf 'bootstrap\n' >> "$calls"
  }
  status=0
  run_apply || status=$?
  [[ "$status" -eq 0 && "$PHASE" == bootstrap && "$(cat "$calls")" == bootstrap ]] || {
    echo "self-test failed: run_apply did not enter bootstrap reconciliation" >&2; return 1;
  }

  status=0
  "$SCRIPT_DIR/reconcile.sh" apply --repo self-test/fixture --required-check "consumer / linux" \
    > "$output" 2>&1 || status=$?
  [[ "$status" -eq 64 ]] && grep -Fq 'apply does not accept --required-check' "$output" || {
    echo "self-test failed: apply CLI did not reject --required-check before write preflight" >&2; return 1;
  }
  echo "self-test: apply rejects --required-check and enters bootstrap reconciliation: PASS"
)

activate_live_check_self_test() (
  local scenario calls="$tmpdir/activate-live-writes" output="$tmpdir/activate-no-sha.err"
  local check_mode status_mode status=0
  REPO="self-test/fixture"
  BRANCH="main"
  CHECK_SHA="$(printf 'a%.0s' {1..40})"
  REQUIRED_CHECK="consumer CI / linux"
  RULESET_NAME="$(jq -r '.ruleset.name' "$MANIFEST")"
  audit_foundation() { :; }
  load_named_ruleset() {
    RULESET_IDS=(80) RULESET_FILE="$tmpdir/activate-base-ruleset.json"
    RULESET_CONFLICT_IDS=() RULESET_UNSAFE_IDS=()
  }
  ruleset_governance_semantics_are_desired() { return 0; }
  ensure_ruleset() { printf 'ruleset-write\n' >> "$calls"; }
  auditor() { : > "$RESULTS"; record PASS live ruleset "mock active Ruleset"; }
  print_results() { :; }
  gh() {
    [[ "$1 $2 $3 $4 $5" == "api --paginate --slurp --method GET" ]] || return 99
    case "$6" in
      *'/check-runs?'*)
        [[ "$6" == "repos/$REPO/commits/$CHECK_SHA/check-runs?check_name=consumer%20CI%20%2F%20linux&filter=latest&per_page=100" ]] || return 99
        if [[ "$check_mode" == api_error ]]; then
          printf 'HTTP 403 Forbidden\n' >&2
          return 1
        fi
        case "$check_mode" in
          success|wrong_sha)
            jq -n --arg sha "$CHECK_SHA" --arg name "$REQUIRED_CHECK" --arg mode "$check_mode" '
              [{total_count:1,check_runs:[{name:$name,head_sha:(if $mode == "wrong_sha" then ("b" * 40) else $sha end),status:"completed",conclusion:"success"}]}]
            ' ;;
          wrong_name)
            jq -n --arg sha "$CHECK_SHA" '[{total_count:1,check_runs:[{name:"different check",head_sha:$sha,status:"completed",conclusion:"success"}]}]' ;;
          pending|failure)
            jq -n --arg sha "$CHECK_SHA" --arg name "$REQUIRED_CHECK" --arg mode "$check_mode" '
              [{total_count:1,check_runs:[{name:$name,head_sha:$sha,status:(if $mode == "pending" then "in_progress" else "completed" end),conclusion:(if $mode == "pending" then null else "failure" end)}]}]
            ' ;;
          none) printf '[{"total_count":0,"check_runs":[]}]\n' ;;
        esac
        ;;
      *'/statuses?'*)
        [[ "$6" == "repos/$REPO/commits/$CHECK_SHA/statuses?per_page=100" ]] || return 99
        case "$status_mode" in
          none) printf '[[]]\n' ;;
          api_error) printf 'HTTP 403 Forbidden\n' >&2; return 1 ;;
          success|pending)
            jq -n --arg name "$REQUIRED_CHECK" --arg state "$status_mode" '[[{context:$name,state:$state}]]' ;;
          stale_success)
            jq -n --arg name "$REQUIRED_CHECK" '[[{context:$name,state:"pending"},{context:$name,state:"success"}]]' ;;
        esac
        ;;
      *) return 99 ;;
    esac
  }

  for scenario in check_success status_success wrong_name pending failure stale_success collision api_error status_api_error wrong_sha; do
    case "$scenario" in
      check_success) check_mode=success status_mode=none ;;
      status_success) check_mode=none status_mode=success ;;
      wrong_name) check_mode=wrong_name status_mode=none ;;
      pending) check_mode=pending status_mode=none ;;
      failure) check_mode=failure status_mode=none ;;
      stale_success) check_mode=none status_mode=stale_success ;;
      collision) check_mode=success status_mode=pending ;;
      api_error) check_mode=api_error status_mode=none ;;
      status_api_error) check_mode=success status_mode=api_error ;;
      wrong_sha) check_mode=wrong_sha status_mode=none ;;
    esac
    : > "$calls"
    : > "$RESULTS"
    status=0
    run_activate || status=$?
    if [[ "$scenario" == check_success || "$scenario" == status_success ]]; then
      [[ "$status" -eq 0 && "$(cat "$calls")" == ruleset-write ]] || {
        echo "self-test failed: activate rejected live $scenario or skipped Ruleset write" >&2; return 1;
      }
    elif [[ "$scenario" == api_error || "$scenario" == status_api_error || "$scenario" == wrong_sha ]]; then
      [[ "$status" -eq 3 && ! -s "$calls" ]] || {
        echo "self-test failed: activate did not block $scenario before governance write" >&2; return 1;
      }
    else
      [[ "$status" -eq 2 && ! -s "$calls" ]] || {
        echo "self-test failed: activate did not reject $scenario before governance write" >&2; return 1;
      }
    fi
  done
  status=0
  "$SCRIPT_DIR/reconcile.sh" activate --repo "$REPO" --required-check "$REQUIRED_CHECK" \
    > "$output" 2>&1 || status=$?
  [[ "$status" -eq 64 ]] && grep -Fq 'activate requires --check-sha' "$output" || {
    echo "self-test failed: activate CLI accepted an implicit commit SHA" >&2; return 1;
  }
  echo "self-test: activate exact live SUCCESS on explicit SHA; wrong/missing/pending/failed/API-error checks block writes: PASS"
)

bootstrap_idempotency_self_test() (
  local mock_labels_file="$tmpdir/idempotent-labels.json" mock_repo_file="$tmpdir/idempotent-repository.json"
  local ruleset="$tmpdir/idempotent-ruleset.json" extras="$tmpdir/idempotent-extras.json"
  local calls="$tmpdir/idempotent-calls" ruleset_exists=false
  REPO="self-test/fixture"
  BRANCH="main"
  DEFAULT_BRANCH="main"
  REQUIRED_CHECK=""
  RULESET_NAME="$(jq -r '.ruleset.name' "$MANIFEST")"
  printf '[]\n' > "$extras"
  jq -n --slurpfile manifest "$MANIFEST" '
    [{name:$manifest[0].required_label.name,color:"ffffff",description:"old metadata"}]
  ' > "$mock_labels_file"
  jq -n --slurpfile manifest "$MANIFEST" '
    {
      default_branch:"main",
      has_wiki:true,
      allow_merge_commit:true,
      allow_squash_merge:false,
      allow_rebase_merge:true,
      allow_auto_merge:true,
      delete_branch_on_merge:false,
      security_and_analysis:{
        secret_scanning:{status:"disabled"},
        secret_scanning_push_protection:{status:"disabled"}
      }
    }
  ' > "$mock_repo_file"
  : > "$calls"
  : > "$WRITE_RESULTS"
  api_get() {
    case "$1" in
      */labels?per_page=100) cp "$mock_labels_file" "$2" ;;
      "repos/$REPO") cp "$mock_repo_file" "$2" ;;
      *) printf 'unexpected mocked GET: %s\n' "$1" >&2; return 99 ;;
    esac
  }
  contents_get() {
    local source_file
    source_file="$ROOT/$(source_file_for "$1")"
    jq -n --arg content "$(encode_file "$source_file")" '{type:"file",content:$content}' > "$2"
  }
  load_named_ruleset() {
    RULESET_UNSAFE_IDS=() RULESET_UNSAFE_FILES=()
    RULESET_CONFLICT_IDS=() RULESET_CONFLICT_FILES=()
    RULESET_MERGED_FILE="$extras"
    if [[ "$ruleset_exists" == true ]]; then
      RULESET_ID=90 RULESET_FILE="$ruleset"
      RULESET_IDS=(90) RULESET_FILES=("$ruleset")
    else
      RULESET_ID="" RULESET_FILE=""
      RULESET_IDS=() RULESET_FILES=()
    fi
    return 0
  }
  gh() {
    local input="$6"
    case "$3" in
      PATCH)
        if [[ "$4" == "repos/$REPO/labels/approved" ]]; then
          printf 'write:label\n' >> "$calls"
          jq --slurpfile patch "$input" 'map(if .name == "approved" then . + $patch[0] else . end)' "$mock_labels_file" > "$tmpdir/labels-next.json"
          cp "$tmpdir/labels-next.json" "$mock_labels_file"
        elif [[ "$4" == "repos/$REPO" ]]; then
          if jq -e 'has("security_and_analysis")' "$input" >/dev/null; then
            local key
            key="$(jq -r '.security_and_analysis | keys[0]' "$input")"
            printf 'write:security:%s\n' "$key" >> "$calls"
            jq --arg key "$key" --slurpfile patch "$input" '
              .security_and_analysis[$key] = $patch[0].security_and_analysis[$key]
            ' "$mock_repo_file" > "$tmpdir/repository-next.json"
          else
            printf 'write:repository\n' >> "$calls"
            jq --slurpfile patch "$input" '. + $patch[0]' "$mock_repo_file" > "$tmpdir/repository-next.json"
          fi
          cp "$tmpdir/repository-next.json" "$mock_repo_file"
        else
          return 99
        fi
        ;;
      POST)
        [[ "$4" == "repos/$REPO/rulesets" ]] || return 99
        printf 'write:ruleset\n' >> "$calls"
        cp "$input" "$ruleset"
        ruleset_exists=true
        ;;
      PUT)
        [[ "$4" == "repos/$REPO/rulesets/90" ]] || return 99
        printf 'write:ruleset\n' >> "$calls"
        cp "$input" "$ruleset"
        ;;
      *) return 99 ;;
    esac
  }
  bootstrap_file() { printf 'protocol:%s\n' "$1" >> "$calls"; }
  DEVELOPER_APP_VERIFIED=true
  REVIEWER_APP_VERIFIED=true
  run_apply >/dev/null
  local first_count first_log
  local audit_status=0 audit_report="$tmpdir/idempotent-audit-1.tsv"
  : > "$RESULTS"
  auditor
  overall_exit || audit_status=$?
  print_results > "$audit_report"
  [[ "$audit_status" -eq 0 ]] && grep -q $'^SUMMARY\tBOOTSTRAPPED$' "$audit_report" &&
    ! grep -Eq '^(DRIFT|PLATFORM_BLOCKER|PERMISSION_BLOCKER|UNVERIFIED)\t' "$audit_report" || {
      echo "self-test failed: first apply did not audit as BOOTSTRAPPED" >&2; return 1;
    }
  first_count="$(grep -c '^write:' "$calls")"
  first_log="$(cat "$calls")"
  [[ "$first_count" -eq 5 ]] || {
    echo "self-test failed: Genesis did not apply label/settings/base Ruleset/security in order" >&2; return 1;
  }
  [[ "$(sed -n '1,3p' "$calls" | sed 's/:.*//')" == $'protocol\nprotocol\nprotocol' ]] || return 1
  [[ "$(sed -n '4,8p' "$calls" | cut -d: -f2 | tr '\n' ' ')" == "label repository ruleset security security " ]] || {
    echo "self-test failed: Genesis write order differs from canonical sequence" >&2; return 1;
  }
  run_apply >/dev/null
  audit_status=0
  : > "$RESULTS"
  auditor
  overall_exit || audit_status=$?
  print_results > "$tmpdir/idempotent-audit-2.tsv"
  [[ "$audit_status" -eq 0 ]] && grep -q $'^SUMMARY\tBOOTSTRAPPED$' "$tmpdir/idempotent-audit-2.tsv" &&
    ! grep -Eq '^(DRIFT|PLATFORM_BLOCKER|PERMISSION_BLOCKER|UNVERIFIED)\t' "$tmpdir/idempotent-audit-2.tsv" || {
      echo "self-test failed: second apply did not audit as BOOTSTRAPPED" >&2; return 1;
    }
  [[ "$(grep -c '^write:' "$calls")" == "$first_count" && "$(head -n 8 "$calls")" == "$first_log" ]] || {
    echo "self-test failed: second apply issued duplicate governance writes" >&2; return 1;
  }
  jq -e --argjson desired "$(jq -c '.repository_settings' "$MANIFEST")" '
    .allow_merge_commit == $desired.allow_merge_commit and
    .allow_squash_merge == $desired.allow_squash_merge and
    .allow_rebase_merge == $desired.allow_rebase_merge and
    .allow_auto_merge == true and
    .delete_branch_on_merge == false and
    .has_wiki == true
  ' "$mock_repo_file" >/dev/null || return 1
  label_metadata_is_desired "$mock_labels_file" || return 1
  echo "self-test: Genesis order, preservation, and second apply idempotency: PASS"

  REQUIRED_CHECK="consumer CI / linux"
  CHECK_SHA="0123456789abcdef0123456789abcdef01234567"
  verify_required_check_success() { :; }
  run_activate > "$tmpdir/activated-report.tsv"
  grep -q $'^SUMMARY\tACTIVE$' "$tmpdir/activated-report.tsv" || {
    echo "self-test failed: activate did not report ACTIVE" >&2; return 1;
  }
  local active_count
  active_count="$(grep -c '^write:' "$calls")"
  [[ "$active_count" -eq $((first_count + 1)) ]] &&
    jq -e --arg context "$REQUIRED_CHECK" '
      [.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]?.context] == [$context]
    ' "$ruleset" >/dev/null || {
      echo "self-test failed: activate did not bind one exact Required Check" >&2; return 1;
    }
  REQUIRED_CHECK=""
  run_apply > "$tmpdir/active-apply-report.tsv"
  run_bootstrap > "$tmpdir/active-bootstrap-report.tsv"
  [[ "$(grep -c '^write:' "$calls")" -eq "$active_count" ]] &&
    grep -q $'^SUMMARY\tACTIVE$' "$tmpdir/active-apply-report.tsv" &&
    grep -q $'^SUMMARY\tACTIVE$' "$tmpdir/active-bootstrap-report.tsv" &&
    jq -e '
      [.rules[] | select(.type == "required_status_checks")] as $rules |
      ($rules | length) == 1 and
      ($rules[0].parameters.required_status_checks | length) == 1 and
      $rules[0].parameters.required_status_checks[0].context == "consumer CI / linux"
    ' "$ruleset" >/dev/null || {
      echo "self-test failed: apply/bootstrap removed or duplicated the ACTIVE Required Check" >&2; return 1;
    }
  echo "self-test: BOOTSTRAPPED -> activate -> apply/bootstrap preserves ACTIVE without writes: PASS"

  jq '.rules |= map(if .type == "pull_request" then
    .parameters.required_approving_review_count = 2
    elif .type == "required_status_checks" then
    .parameters.required_status_checks[0].integration_id = 42
    else . end)' "$ruleset" > "$tmpdir/active-drift.json"
  cp "$tmpdir/active-drift.json" "$ruleset"
  REQUIRED_CHECK=""
  run_apply > "$tmpdir/active-repair-report.tsv"
  [[ "$(grep -c '^write:' "$calls")" -eq $((active_count + 1)) ]] &&
    grep -q $'^SUMMARY\tACTIVE$' "$tmpdir/active-repair-report.tsv" &&
    jq -e '
      [.rules[] | select(.type == "required_status_checks")] as $rules |
      ($rules | length) == 1 and
      $rules[0].parameters.required_status_checks == [{context:"consumer CI / linux",integration_id:42}]
    ' "$ruleset" >/dev/null &&
    ruleset_governance_is_desired "$ruleset" || {
      echo "self-test failed: ACTIVE drift repair did not preserve the exact CI gate" >&2; return 1;
    }
  echo "self-test: ACTIVE governance repair preserves exact context and integration binding: PASS"

  jq '.rules |= map(if .type == "required_status_checks" then
    .parameters.required_status_checks += [{context:"parallel-alias"}] else . end)' \
    "$ruleset" > "$tmpdir/active-ambiguous.json"
  cp "$tmpdir/active-ambiguous.json" "$ruleset"
  active_count="$(grep -c '^write:' "$calls")"
  local status=0
  REQUIRED_CHECK=""
  run_apply > "$tmpdir/active-ambiguous-report.tsv" || status=$?
  [[ "$status" -eq 2 && "$(grep -c '^write:' "$calls")" -eq "$active_count" ]] &&
    grep -q $'^DRIFT\tlive\trequired_check\tACTIVE Required Check is ambiguous' "$tmpdir/active-ambiguous-report.tsv" &&
    ! grep -q $'^SUMMARY\t' "$tmpdir/active-ambiguous-report.tsv" || {
      echo "self-test failed: ambiguous ACTIVE check was not blocked before Ruleset write" >&2; return 1;
    }
  echo "self-test: ambiguous ACTIVE check fails closed without a Ruleset write: PASS"
)

run_self_test() {
  local manifest_file="$MANIFEST"
  existing_behavior_self_test
  write_preflight_self_test
  bootstrap_target_self_test
  REPO="self-test/fixture"
  DEVELOPER_APP_VERIFIED=true
  REVIEWER_APP_VERIFIED=true
  HUMAN_AUTHORITY_VERIFIED=true
  : > "$RESULTS"
  audit_apps
  overall_exit
  grep -q $'^PASS\tlive\tdeveloper_app\t' "$RESULTS" &&
    grep -q $'^PASS\tlive\treviewer_app\t' "$RESULTS" || {
      echo "self-test failed: invocation-only App assertions were not reflected in audit" >&2; return 1;
    }
  echo "self-test: independent App assertions remain invocation-only: PASS"

  paginated_inventory_self_test
  label_self_test
  repository_settings_self_test
  security_self_test
  ruleset_self_test
  ruleset_live_normalization_self_test
  ruleset_migration_self_test
  ruleset_overlap_self_test
  apply_required_check_rejection_self_test
  activate_live_check_self_test
  bootstrap_idempotency_self_test

  if ! jq -e '
    all(.bootstrap[]; (.path | startswith(".github/workflows/") | not))
  ' "$manifest_file" >/dev/null; then
    echo "self-test failed: manifest contains consumer workflow generation" >&2; return 1
  fi
  if grep -Eq 'GH_TOKEN=|GITHUB_TOKEN=|Authorization: *Bearer|role-exec|jwt_sign|installation_token_cache|contents/\.github/workflows' \
    "$SCRIPT_DIR/reconcile.sh" "$SCRIPT_DIR/lib/"*.sh; then
    echo "self-test failed: reconciler contains credential or consumer CI generation logic" >&2
    return 1
  fi
  echo "self-test: no credential handling or consumer CI generation: PASS"
  bash "$SCRIPT_DIR/tests/protocol-sync-self-test.sh"
  echo "self-test: PASS"
}
