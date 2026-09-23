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
  bootstrap_file() { printf 'bootstrap_file\n' >> "$calls"; }
  ensure_label() { printf 'ensure_label\n' >> "$calls"; }
  ensure_ruleset() { printf 'ensure_ruleset\n' >> "$calls"; }

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
    RULESET_FILE="$mutated"
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
}
