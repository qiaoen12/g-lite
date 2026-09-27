# Deterministic local protocol sync. No GitHub writes, commits, or pull requests.
set -euo pipefail

PS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PS_START='<!-- g-lite:managed protocol start -->'
PS_END='<!-- g-lite:managed protocol end -->'

ps_die_unverified() {
  echo "protocol-sync: unverified: $1" >&2
  if [[ -n "${PS_REF:-}" ]]; then
    printf 'BASELINE\ttarget\t%s\t%s\t-\n' "$PS_REF" "${PS_SHA:-unrecorded}"
  fi
  printf 'SYNC\tunverified\n'
  exit 3
}

ps_bytes_equal() { cmp -s -- "$1" "$2"; }

ps_decode_base64() {
  if base64 -d </dev/null >/dev/null 2>&1; then base64 -d; else base64 -D; fi
}

# This is a fixed ownership contract, not a general file-sync manifest.
ps_manifest_ok() {
  jq -e '
    .schema_version == 3 and
    (.baseline | type == "string" and test("^[A-Za-z0-9._/-]+$")) and
    .protocol_sync == {
      managed_prefix: {path:"AGENTS.md", payload:"tools/repo-reconciler/templates/minimal-consumer-AGENTS.md"},
      owned_exact: [
        {path:".github/ISSUE_TEMPLATE/task.md", payload:".github/ISSUE_TEMPLATE/task.md"},
        {path:".github/pull_request_template.md", payload:".github/pull_request_template.md"}
      ]
    }
  ' "$1" >/dev/null
}

# Reject symlinks and non-directory ancestors, including in local snapshots.
ps_ancestor_safe() {
  local dir path root="${2:-$PS_CHECKOUT}"
  dir="$(dirname "$1")"
  while [[ "$dir" != "." ]]; do
    path="$root/$dir"
    if [[ -e "$path" || -L "$path" ]]; then
      [[ -d "$path" && ! -L "$path" ]] || return 1
    fi
    dir="$(dirname "$dir")"
  done
}

# A block must start at byte zero and have exactly two complete marker lines.
# The reserved marker stem also catches partial, inline, and CRLF markers.
ps_prefix_end() {
  local file="$1" count line offset
  [[ "$(head -n 1 "$file")" == "$PS_START" ]] || return 1
  count="$(grep -aoF 'g-lite:managed' "$file" | wc -l | tr -d '[:space:]')"
  [[ "$count" == 2 ]] || return 1
  [[ "$(grep -acxF "$PS_START" "$file")" == 1 ]] || return 1
  [[ "$(grep -acxF "$PS_END" "$file")" == 1 ]] || return 1
  line="$(grep -anxF "$PS_END" "$file")"
  # Require a terminating LF, including when the end marker is the last line.
  offset="$(grep -abxF "$PS_END" "$file")"
  [[ "$(dd if="$file" bs=1 skip=$((${offset%%:*} + ${#PS_END})) count=1 2>/dev/null | od -An -tu1 | tr -d '[:space:]')" == 10 ]] || return 1
  printf '%s\n' "${line%%:*}"
}

ps_plan() {
  local manifest="$PS_SOURCE/tools/repo-reconciler/manifest.json" rel payload dest expected staged status end
  ps_ancestor_safe tools/repo-reconciler/manifest.json "$PS_SOURCE" || ps_die_unverified "snapshot path"
  [[ -f "$manifest" && ! -L "$manifest" ]] && ps_manifest_ok "$manifest" || ps_die_unverified "snapshot manifest"
  PS_LABEL="$(jq -r '.baseline' "$manifest")"
  : > "$PS_ROWS"; : > "$PS_WRITES"
  PS_GUARDS="$PS_WORK/guards"; : > "$PS_GUARDS"
  PS_CONFLICT=0 PS_CHANGE=0 PS_PRESENT=0
  while IFS=$'\t' read -r rel payload; do
    ps_ancestor_safe "$payload" "$PS_SOURCE" || ps_die_unverified "snapshot path"
    [[ -f "$PS_SOURCE/$payload" && ! -L "$PS_SOURCE/$payload" ]] || ps_die_unverified "payload"
    staged="$PS_WORK/staged/$(basename "$rel")"
    cp -- "$PS_SOURCE/$payload" "$staged" || ps_die_unverified "snapshot copy"
    if [[ "$rel" == AGENTS.md ]]; then
      end="$(ps_prefix_end "$staged")" || ps_die_unverified "canonical prefix"
      [[ "$(sed -n '2p' "$staged")" == 'G-lite Protocol-Version: v3.7.3' ]] || ps_die_unverified "protocol version"
      [[ "$(tail -n +$((end + 1)) "$staged" | wc -c | tr -d '[:space:]')" == 0 ]] || ps_die_unverified "canonical remainder"
    fi
    dest="$PS_CHECKOUT/$rel" expected=- status=changed
    [[ ! -e "$dest" && ! -L "$dest" ]] || PS_PRESENT=1
    if ! ps_ancestor_safe "$rel" || [[ -L "$dest" || ( -e "$dest" && ! -f "$dest" ) ]]; then
      status=conflict
    elif [[ -f "$dest" ]]; then
      expected="$staged.before"
      cp -p -- "$dest" "$expected" || ps_die_unverified "destination snapshot"
      if [[ "$rel" == AGENTS.md ]]; then
        if ! grep -aqF 'g-lite:managed' "$expected"; then
          printf '\n' >> "$staged"
          cat -- "$expected" >> "$staged"
        elif end="$(ps_prefix_end "$expected")"; then
          tail -n +$((end + 1)) "$expected" >> "$staged"
        else
          status=conflict
        fi
      fi
      if [[ "$status" != conflict ]] && ps_bytes_equal "$staged" "$expected"; then status=unchanged; fi
    fi
    printf 'FILE\t%s\t%s\n' "$status" "$rel" >> "$PS_ROWS"
    printf '%s\t%s\n' "$rel" "$expected" >> "$PS_GUARDS"
    case "$status" in
      conflict) PS_CONFLICT=1 ;;
      changed) PS_CHANGE=1; printf '%s\t%s\t%s\n' "$rel" "$staged" "$expected" >> "$PS_WRITES" ;;
    esac
  done < <(jq -r '.protocol_sync.owned_exact[], .protocol_sync.managed_prefix | [.path,.payload] | @tsv' "$manifest")
}

ps_class() {
  if [[ "$PS_CONFLICT" == 1 ]]; then printf 'conflict'
  elif [[ "$PS_CHANGE" == 1 && "$PS_PRESENT" == 1 ]]; then printf 'drift'
  elif [[ "$PS_CHANGE" == 1 ]]; then printf 'absent'
  else printf 'exact'; fi
}

ps_preflight_apply() {
  local path expected dest rows="$PS_WORK/rows.next"
  while IFS=$'\t' read -r path expected; do
    dest="$PS_CHECKOUT/$path"
    if ps_ancestor_safe "$path" && [[ ! -L "$dest" ]] && {
      [[ "$expected" == - && ! -e "$dest" ]] ||
      { [[ "$expected" != - && -f "$dest" ]] && ps_bytes_equal "$dest" "$expected"; }
    }; then continue; fi
    awk -F '\t' -v path="$path" '$3 != path' "$PS_ROWS" > "$rows"
    mv -- "$rows" "$PS_ROWS"
    printf 'FILE\tconflict\t%s\n' "$path" >> "$PS_ROWS"
    PS_CONFLICT=1
  done < "$PS_GUARDS"
  [[ "$PS_CONFLICT" == 0 ]] || return 2
}

# Same-directory rename avoids exposing a partially copied file. Existing mode
# is retained; new protocol files use 0644. The directory must remain exclusive
# to this invocation while applying (no cross-process transaction/locking).
ps_replace() {
  local path="$1" source="$2" mode_source="$3" tmp
  tmp="$(mktemp "$PS_CHECKOUT/$(dirname "$path")/.g-lite-sync.XXXXXX")" || return 1
  if { [[ "$mode_source" == - ]] && chmod 644 "$tmp" || cp -p -- "$mode_source" "$tmp"; } &&
      cat -- "$source" > "$tmp" && mv -- "$tmp" "$PS_CHECKOUT/$path"; then return 0; fi
  rm -f -- "$tmp"
  return 1
}

ps_rollback() {
  local path staged expected
  while IFS=$'\t' read -r path staged expected; do
    if [[ "$expected" == - ]]; then rm -f -- "$PS_CHECKOUT/$path"
    else ps_replace "$path" "$expected" "$expected" || return 1; fi
  done < "$PS_WORK/applied"
}

ps_apply() {
  local path staged expected
  [[ "$PS_CONFLICT" == 0 ]] || return 2
  ps_preflight_apply || return $?
  : > "$PS_WORK/applied"
  while IFS=$'\t' read -r path staged expected; do
    if ! mkdir -p -- "$PS_CHECKOUT/$(dirname "$path")" || ! ps_replace "$path" "$staged" "$expected"; then
      ps_rollback || return 1
      return 1
    fi
    printf '%s\t%s\t%s\n' "$path" "$staged" "$expected" >> "$PS_WORK/applied"
  done < "$PS_WRITES"
}

ps_emit() {
  local class="$1" sync="$2" cur_sha="unrecorded" cur_label="-"
  if [[ "$class" == exact ]]; then cur_sha="$PS_SHA"; cur_label="$PS_LABEL"; fi
  printf 'BASELINE\tcurrent\t%s\t%s\t%s\n' "$class" "$cur_sha" "$cur_label"
  printf 'BASELINE\ttarget\t%s\t%s\t%s\n' "$PS_REF" "$PS_SHA" "$PS_LABEL"
  LC_ALL=C sort -t $'\t' -k3,3 "$PS_ROWS"
  printf 'SYNC\t%s\n' "$sync"
}

ps_ref_ok() {
  local ref="$1"
  [[ "$ref" =~ ^[A-Za-z0-9._/-]+$ && "$ref" != *".."* && "$ref" != *"//"* ]]
}

ps_load_canonical() {
  local manifest="$PS_LIB_DIR/../manifest.json" repo ref
  [[ -f "$manifest" ]] || ps_die_unverified "tool manifest"
  repo="$(jq -r '.canonical.repo // empty' "$manifest")" || ps_die_unverified "tool manifest"
  ref="$(jq -r '.canonical.ref // empty' "$manifest")" || ps_die_unverified "tool manifest"
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || ps_die_unverified "canonical repo"
  ps_ref_ok "$ref" || ps_die_unverified "canonical ref"
  PS_REPO="$repo"
  PS_DEFAULT_REF="$ref"
}

ps_resolve_sha() {
  local ref="$1" out
  if [[ "$ref" == latest ]]; then ref="$PS_DEFAULT_REF"; fi
  ps_ref_ok "$ref" || ps_die_unverified "ref"
  if [[ "$ref" =~ ^[0-9A-Fa-f]{1,39}$ ]]; then ps_die_unverified "short ref"; fi
  if [[ "$ref" =~ ^[0-9A-Fa-f]{40}$ ]]; then ref="$(printf '%s' "$ref" | tr '[:upper:]' '[:lower:]')"; fi
  if ! out="$(gh api --method GET "repos/${PS_REPO}/commits/${ref}" --jq .sha 2>"$PS_WORK/gh.err")"; then
    ps_die_unverified "resolve"
  fi
  [[ "$out" =~ ^[0-9a-f]{40}$ ]] || ps_die_unverified "sha"
  if [[ "$ref" =~ ^[0-9a-f]{40}$ && "$out" != "$ref" ]]; then ps_die_unverified "sha mismatch"; fi
  PS_SHA="$out"
}

ps_fetch_file() {
  local rel="$1" enc json dest content
  [[ "$PS_SHA" =~ ^[0-9a-f]{40}$ ]] || ps_die_unverified "sha"
  enc="$(jq -rn --arg p "$rel" '$p | split("/") | map(@uri) | join("/")')"
  json="$PS_WORK/contents.json"
  dest="$PS_SOURCE/$rel"
  if ! gh api --method GET "repos/${PS_REPO}/contents/${enc}" -f ref="$PS_SHA" >"$json" 2>"$PS_WORK/gh.err"; then
    ps_die_unverified "fetch"
  fi
  jq -e '(.type == "file") and (.content | type == "string")' "$json" >/dev/null || ps_die_unverified "fetch"
  mkdir -p -- "$(dirname "$dest")"
  content="$(jq -r '.content' "$json")"
  if [[ -z "$content" ]]; then
    : > "$dest"
  elif ! printf '%s' "$content" | tr -d '\n' | ps_decode_base64 > "$dest"; then
    ps_die_unverified "fetch"
  fi
}

ps_materialize_remote() {
  local manifest rel
  PS_SOURCE="$PS_WORK/snapshot"
  mkdir -p -- "$PS_SOURCE"
  ps_fetch_file "tools/repo-reconciler/manifest.json"
  manifest="$PS_SOURCE/tools/repo-reconciler/manifest.json"
  ps_manifest_ok "$manifest" || ps_die_unverified "snapshot manifest"
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    [[ -f "$PS_SOURCE/$rel" ]] || ps_fetch_file "$rel"
  done < <(jq -r '.protocol_sync.managed_prefix.payload, .protocol_sync.owned_exact[].payload' "$manifest")
}

ps_usage() {
  cat <<'USAGE'
Usage:
  reconcile.sh protocol-sync --checkout DIR [--target-ref REF] [--source DIR] [--write]
USAGE
}

protocol_sync_main() {
  local checkout="" source_dir="" target_ref="" do_write=false class apply_status
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --checkout) checkout="${2:?missing --checkout value}"; shift 2 ;;
      --source) source_dir="${2:?missing --source value}"; shift 2 ;;
      --target-ref) target_ref="${2:?missing --target-ref value}"; shift 2 ;;
      --write) do_write=true; shift ;;
      -h|--help) ps_usage; exit 0 ;;
      *) echo "unknown option: $1" >&2; ps_usage >&2; exit 64 ;;
    esac
  done
  [[ -n "$checkout" ]] || { echo "protocol-sync requires --checkout DIR" >&2; ps_usage >&2; exit 64; }
  if [[ -n "$source_dir" && -n "$target_ref" ]]; then
    echo "protocol-sync does not combine --source with --target-ref" >&2
    exit 64
  fi
  [[ -d "$checkout" && -r "$checkout" ]] || ps_die_unverified "checkout"
  PS_CHECKOUT="$(cd "$checkout" && pwd -P)"
  PS_WORK="$(mktemp -d)"
  trap '[[ -n "${PS_WORK:-}" ]] && rm -rf -- "$PS_WORK"' EXIT
  PS_ROWS="$PS_WORK/rows"
  PS_WRITES="$PS_WORK/writes"
  mkdir -p -- "$PS_WORK/staged"
  PS_REF=""
  PS_SHA=""
  if [[ -n "$source_dir" ]]; then
    [[ -d "$source_dir" && -r "$source_dir" ]] || ps_die_unverified "source"
    PS_SOURCE="$(cd "$source_dir" && pwd -P)"
    PS_REF="source"
    PS_SHA="local"
  else
    ps_load_canonical
    if [[ -n "$target_ref" ]]; then PS_REF="$target_ref"; else PS_REF="$PS_DEFAULT_REF"; fi
    ps_resolve_sha "$PS_REF"
    ps_materialize_remote
  fi
  ps_plan
  class="$(ps_class)"
  if [[ "$PS_CONFLICT" == 1 ]]; then ps_emit "$class" conflict; exit 2; fi
  if [[ "$PS_CHANGE" == 1 && "$do_write" != true ]]; then ps_emit "$class" pending; exit 2; fi
  if [[ "$PS_CHANGE" == 1 ]]; then
    set +e
    ps_apply
    apply_status=$?
    set -e
    if [[ "$apply_status" == 2 ]]; then ps_emit "$(ps_class)" conflict; exit 2; fi
    [[ "$apply_status" == 0 ]] || ps_die_unverified "apply"
  fi
  ps_emit exact exact
  exit 0
}
