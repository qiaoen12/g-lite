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
  gh api --method GET "$1" >"$2" 2>"$3"
}

api_error_state() {
  local message
  message="$(tr '[:upper:]' '[:lower:]' <<<"$1")"
  if grep -Eq 'plan does not support|feature is not available|not available for private' <<<"$message"; then
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

  local repository="$tmpdir/repository.json"
  if ! api_get "repos/$REPO" "$repository" "$error"; then
    echo "cannot read repository $REPO: $(cat "$error")" >&2
    exit 69
  fi
  DEFAULT_BRANCH="$(jq -r '.default_branch // empty' "$repository")"
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
