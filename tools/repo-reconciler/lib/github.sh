# GitHub API, repository, and file helpers used by reconcile.sh.

record() {
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$RESULTS"
}

record_write_failure() {
  local key="$1" error="$2" state detail message
  message="$(cat "$error" 2>/dev/null || true)"
  state="$(api_error_state "$message")"
  case "$state" in
    PERMISSION_BLOCKER) detail="write denied by GitHub permissions" ;;
    PLATFORM_BLOCKER) detail="write unsupported by the GitHub platform/plan" ;;
    *) detail="write result could not be verified" ;;
  esac
  printf '%s\twrite\t%s\t%s\n' "$state" "$key" "$detail" >> "$WRITE_RESULTS"
}

api_get() {
  if [[ "$1" == *"/labels?"* || "$1" == *"/rulesets?"* ]]; then
    # A partial first page cannot establish that an owned object is absent.
    gh api --paginate --slurp --method GET "$1" >"$2.pages" 2>"$3" || return 1
    jq -e 'if type == "array" and all(.[]; type == "array") then add else error("invalid paginated response") end' \
      "$2.pages" >"$2" 2>>"$3"
  else
    gh api --method GET "$1" >"$2" 2>"$3"
  fi
}

verify_required_check_success() {
  local encoded checks_pages="$tmpdir/check-runs-pages.json" statuses_pages="$tmpdir/statuses-pages.json"
  local checks="$tmpdir/check-runs.json" statuses="$tmpdir/statuses.json"
  local error="$tmpdir/required-check.err" status_state check_count status_count
  encoded="$(jq -rn --arg name "$REQUIRED_CHECK" '$name | @uri')"

  if ! gh api --paginate --slurp --method GET \
    "repos/$REPO/commits/$CHECK_SHA/check-runs?check_name=$encoded&filter=latest&per_page=100" \
    > "$checks_pages" 2> "$error"; then
    record "$(api_error_state "$(cat "$error")")" live required_check "cannot read Check Runs for $CHECK_SHA"
    return 3
  fi
  if ! jq -e '
    type == "array" and length > 0 and
    all(.[]; type == "object" and (.check_runs | type) == "array" and (.total_count | type) == "number") and
    all(.[].check_runs[]; (.name | type) == "string" and (.head_sha | type) == "string" and
      (.status | type) == "string" and (.conclusion == null or (.conclusion | type) == "string")) and
    (.[0].total_count as $total |
      all(.[]; .total_count == $total) and $total == ([.[].check_runs[]] | length))
  ' "$checks_pages" >/dev/null 2>&1; then
    record UNVERIFIED live required_check "invalid or incomplete Check Runs response for $CHECK_SHA"
    return 3
  fi
  jq '[.[].check_runs[]]' "$checks_pages" > "$checks"
  if ! jq -e --arg sha "$CHECK_SHA" --arg name "$REQUIRED_CHECK" \
    'all(.[] | select(.name == $name); .head_sha == $sha)' "$checks" >/dev/null; then
    record UNVERIFIED live required_check "Check Run SHA differs from supplied $CHECK_SHA"
    return 3
  fi

  if ! gh api --paginate --slurp --method GET \
    "repos/$REPO/commits/$CHECK_SHA/statuses?per_page=100" \
    > "$statuses_pages" 2> "$error"; then
    record "$(api_error_state "$(cat "$error")")" live required_check "cannot read commit statuses for $CHECK_SHA"
    return 3
  fi
  if ! jq -e '
    type == "array" and length > 0 and
    all(.[]; type == "array") and
    all(.[][]; (.context | type) == "string" and
      (.state == "error" or .state == "failure" or .state == "pending" or .state == "success"))
  ' "$statuses_pages" >/dev/null 2>&1; then
    record UNVERIFIED live required_check "invalid commit statuses response for $CHECK_SHA"
    return 3
  fi
  jq '[.[][]]' "$statuses_pages" > "$statuses"

  check_count="$(jq --arg name "$REQUIRED_CHECK" '[.[] | select(.name == $name)] | length' "$checks")"
  status_state="$(jq -r --arg name "$REQUIRED_CHECK" '[.[] | select(.context == $name)][0].state // empty' "$statuses")"
  status_count=0
  [[ -z "$status_state" ]] || status_count=1
  if [[ "$check_count" -eq 0 && "$status_count" -eq 0 ]]; then
    record DRIFT live required_check "exact context '$REQUIRED_CHECK' has no Check Run or commit status on $CHECK_SHA"
    return 2
  fi
  if ! jq -e --arg name "$REQUIRED_CHECK" '
    all(.[] | select(.name == $name); .status == "completed" and .conclusion == "success")
  ' "$checks" >/dev/null || [[ "$status_count" -eq 1 && "$status_state" != success ]]; then
    record DRIFT live required_check "exact context '$REQUIRED_CHECK' is not live SUCCESS on $CHECK_SHA"
    return 2
  fi
  record PASS live required_check "exact context '$REQUIRED_CHECK' is live SUCCESS on $CHECK_SHA"
}

api_error_state() {
  local message
  message="$(tr '[:upper:]' '[:lower:]' <<<"$1")"
  if grep -Eq 'plan does not support|feature is not available|not available for private|not available for this repository|not supported for this repository|requires github advanced security|advanced security is required' <<<"$message"; then
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

  REPOSITORY_FILE="$tmpdir/repository.json"
  if ! api_get "repos/$REPO" "$REPOSITORY_FILE" "$error"; then
    local state
    state="$(api_error_state "$(cat "$error")")"
    record "$state" live repository "cannot read repository settings"
    echo "$state: cannot read repository $REPO: $(cat "$error")" >&2
    exit 3
  fi
  DEFAULT_BRANCH="$(jq -r '.default_branch // empty' "$REPOSITORY_FILE")"
  if [[ -z "$BRANCH" ]]; then
    BRANCH="$DEFAULT_BRANCH"
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
