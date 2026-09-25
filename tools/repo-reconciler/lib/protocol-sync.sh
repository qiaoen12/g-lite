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
ps_size() { wc -c < "$1" | tr -d '[:space:]'; }

ps_require_rel_path() {
  local p="$1"
  [[ -n "$p" && "$p" != /* && "$p" != *".."* && "$p" != *"//"* && "$p" != *$'\n'* && "$p" != *$'\t'* ]] || return 1
  [[ "$p" =~ ^[A-Za-z0-9._/-]+$ ]]
}

ps_forbidden_write() {
  case "$1" in
    README.md|docs|docs/*|tools|tools/*|.github/workflows|.github/workflows/*) return 0 ;;
  esac
  return 1
}

ps_decode_base64() {
  if base64 -d </dev/null >/dev/null 2>&1; then base64 -d; else base64 -D; fi
}

ps_copy_range() {
  local file="$1" start="$2" len="$3" dest="$4" got
  if (( len == 0 )); then : > "$dest"; return 0; fi
  tail -c +$((start + 1)) "$file" > "$dest.range"
  head -c "$len" "$dest.range" > "$dest"
  rm -f "$dest.range"
  got="$(ps_size "$dest")"
  [[ "$got" == "$len" ]]
}

ps_count_marker() {
  local n
  n="$(grep -c -x -F -- "$2" "$1" || true)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%s\n' "$n"
}

ps_marker_offset() {
  local line off
  line="$(grep -b -x -F -- "$2" "$1" | head -n 1)" || return 1
  off="${line%%:*}"
  [[ "$off" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$off"
}

ps_newline_at() {
  ps_copy_range "$1" "$2" 1 "$PS_WORK/nl-got"
  ps_bytes_equal "$PS_WORK/nl-got" "$PS_WORK/nl-byte"
}

ps_wrap_payload() {
  { printf '%s\n' "$PS_START"; cat -- "$1"; printf '%s\n' "$PS_END"; } > "$2"
}

ps_render_managed() {
  local file="$1" payload="$2" so="$3" eo="$4" staged="$5"
  local slen=${#PS_START} elen=${#PS_END} size after_start
  size="$(ps_size "$file")"
  ps_copy_range "$file" "$so" "$slen" "$PS_WORK/marker-got" || return 1
  [[ "$(cat "$PS_WORK/marker-got")" == "$PS_START" ]] || return 1
  (( so + slen < size )) || return 1
  ps_newline_at "$file" $((so + slen)) || return 1
  (( eo + elen < size )) || return 1
  ps_copy_range "$file" "$eo" "$elen" "$PS_WORK/marker-got" || return 1
  [[ "$(cat "$PS_WORK/marker-got")" == "$PS_END" ]] || return 1
  ps_newline_at "$file" $((eo + elen)) || return 1
  (( eo > so )) || return 1
  (( so + slen + 1 <= eo )) || return 1
  after_start=$((eo + elen + 1))
  (( after_start <= size )) || return 1
  ps_copy_range "$file" 0 "$so" "$PS_WORK/before"
  ps_copy_range "$file" "$after_start" $((size - after_start)) "$PS_WORK/after"
  {
    cat -- "$PS_WORK/before"
    printf '%s\n' "$PS_START"
    cat -- "$payload"
    printf '%s\n' "$PS_END"
    cat -- "$PS_WORK/after"
  } > "$staged"
}

# Print unchanged, changed, or conflict. A changed file is written to $3.
ps_classify_managed() {
  local rel="$1" payload="$2" staged="$3" dest sc ec so eo
  dest="$PS_CHECKOUT/$rel"
  if [[ -L "$dest" || -d "$dest" || ( -e "$dest" && ! -f "$dest" ) ]]; then
    printf 'conflict'
    return 0
  fi
  if [[ ! -e "$dest" ]]; then
    ps_wrap_payload "$payload" "$staged"
    printf 'changed'
    return 0
  fi
  sc="$(ps_count_marker "$dest" "$PS_START")"
  ec="$(ps_count_marker "$dest" "$PS_END")"
  if [[ "$sc" == 0 && "$ec" == 0 ]]; then
    if ps_bytes_equal "$dest" "$payload"; then
      ps_wrap_payload "$payload" "$staged"
      printf 'changed'
    else
      printf 'conflict'
    fi
    return 0
  fi
  if [[ "$sc" != 1 || "$ec" != 1 ]]; then
    printf 'conflict'
    return 0
  fi
  so="$(ps_marker_offset "$dest" "$PS_START")" || { printf 'conflict'; return 0; }
  eo="$(ps_marker_offset "$dest" "$PS_END")" || { printf 'conflict'; return 0; }
  if ! ps_render_managed "$dest" "$payload" "$so" "$eo" "$staged"; then
    printf 'conflict'
    return 0
  fi
  if ps_bytes_equal "$dest" "$staged"; then
    rm -f -- "$staged"
    printf 'unchanged'
  else
    printf 'changed'
  fi
}

ps_classify_exact() {
  local rel="$1" payload="$2" staged="$3" dest
  dest="$PS_CHECKOUT/$rel"
  if [[ -L "$dest" || -d "$dest" || ( -e "$dest" && ! -f "$dest" ) ]]; then
    printf 'conflict'
    return 0
  fi
  if [[ ! -e "$dest" ]] || ! ps_bytes_equal "$dest" "$payload"; then
    cp -- "$payload" "$staged"
    printf 'changed'
    return 0
  fi
  printf 'unchanged'
}

ps_ancestor_safe() {
  local dir
  dir="$(dirname "$1")"
  while [[ "$dir" != "." ]]; do
    [[ -L "$PS_CHECKOUT/$dir" ]] && return 1
    dir="$(dirname "$dir")"
  done
}

ps_note() {
  local status="$1" rel="$2" staged="${3:-}"
  printf 'FILE\t%s\t%s\n' "$status" "$rel" >> "$PS_ROWS"
  case "$status" in
    changed)
      PS_CHANGE=1
      printf '%s\t%s\n' "$rel" "$staged" >> "$PS_WRITES"
      ;;
    removed)
      PS_LEGACY=1
      PS_CHANGE=1
      printf '%s\t%s\n' "$rel" "$staged" >> "$PS_REMOVALS"
      ;;
    conflict) PS_CONFLICT=1 ;;
  esac
}

ps_mark_present() {
  [[ -e "$PS_CHECKOUT/$1" || -L "$PS_CHECKOUT/$1" ]] && PS_PRESENT=1
  return 0
}

ps_manifest_ok() {
  jq -e '
    .schema_version == 3 and
    (.baseline | type == "string" and length > 0 and test("^[A-Za-z0-9._/-]+$")) and
    .protocol_sync.markers.start == "<!-- g-lite:managed protocol start -->" and
    .protocol_sync.markers.end == "<!-- g-lite:managed protocol end -->" and
    (.protocol_sync.managed | type == "array") and
    (.protocol_sync.legacy | type == "array") and
    (.protocol_sync.owned_exact | type == "array") and
    all(.protocol_sync.managed[]; (.path | type == "string") and (.payload | type == "string")) and
    all(.protocol_sync.legacy[]; (.path | type == "string") and (.canonical | type == "string")) and
    all(.protocol_sync.owned_exact[]; (.path | type == "string") and (.payload | type == "string")) and
    (([.protocol_sync.managed[].path, .protocol_sync.owned_exact[].path, .protocol_sync.legacy[].path] | length)
      == ([.protocol_sync.managed[].path, .protocol_sync.owned_exact[].path, .protocol_sync.legacy[].path] | unique | length)) and
    ((.protocol_sync.managed | map(.path)) as $managed
      | all(.protocol_sync.legacy[]; .canonical as $c | $managed | index($c) != null))
  ' "$1" >/dev/null
}

ps_check_declared_path() {
  ps_require_rel_path "$1" || ps_die_unverified "declared path"
  if ps_forbidden_write "$1"; then ps_die_unverified "consumer-owned path declared"; fi
}

ps_payload_file() {
  local rel="$1" file="$PS_SOURCE/$1"
  ps_require_rel_path "$rel" || return 1
  [[ -f "$file" && ! -L "$file" ]] || return 1
  if grep -q -x -F -e "$PS_START" -e "$PS_END" "$file"; then return 1; fi
  printf '%s\n' "$file"
}

ps_plan_entries() {
  local kind="$1" manifest="$2" entry path payload_rel payload staged status
  while IFS= read -r entry; do
    path="$(jq -r '.path' <<<"$entry")"
    payload_rel="$(jq -r '.payload' <<<"$entry")"
    ps_check_declared_path "$path"
    ps_mark_present "$path"
    ps_ancestor_safe "$path" || { ps_note conflict "$path"; continue; }
    payload="$(ps_payload_file "$payload_rel")" || ps_die_unverified "payload"
    staged="$PS_WORK/staged/$((PS_N++))"
    if [[ "$kind" == owned_exact ]]; then
      status="$(ps_classify_exact "$path" "$payload" "$staged")" || ps_die_unverified "classify"
    else
      status="$(ps_classify_managed "$path" "$payload" "$staged")" || ps_die_unverified "classify"
    fi
    if [[ "$status" == changed ]]; then ps_note changed "$path" "$staged"; else ps_note "$status" "$path"; fi
  done < <(jq -c --arg kind "$kind" '.protocol_sync[$kind][]' "$manifest")
}

ps_plan() {
  local manifest="$PS_SOURCE/tools/repo-reconciler/manifest.json"
  local entry path canonical payload_rel payload
  [[ -f "$manifest" && ! -L "$manifest" ]] || ps_die_unverified "snapshot manifest"
  ps_manifest_ok "$manifest" || ps_die_unverified "snapshot manifest"
  PS_LABEL="$(jq -r '.baseline' "$manifest")"
  : > "$PS_ROWS"
  : > "$PS_WRITES"
  : > "$PS_REMOVALS"
  PS_CONFLICT=0
  PS_LEGACY=0
  PS_CHANGE=0
  PS_PRESENT=0
  PS_N=0
  ps_plan_entries managed "$manifest"
  ps_plan_entries owned_exact "$manifest"
  while IFS= read -r entry; do
    path="$(jq -r '.path' <<<"$entry")"
    canonical="$(jq -r '.canonical' <<<"$entry")"
    ps_check_declared_path "$path"
    payload_rel="$(jq -r --arg c "$canonical" '.protocol_sync.managed[] | select(.path == $c) | .payload' "$manifest")"
    payload="$(ps_payload_file "$payload_rel")" || ps_die_unverified "payload"
    if [[ -e "$PS_CHECKOUT/$path" || -L "$PS_CHECKOUT/$path" ]]; then
      if [[ -f "$PS_CHECKOUT/$path" && ! -L "$PS_CHECKOUT/$path" ]] && ps_bytes_equal "$PS_CHECKOUT/$path" "$payload"; then
        ps_note removed "$path" "$payload"
      else
        ps_note conflict "$path"
      fi
    fi
  done < <(jq -c '.protocol_sync.legacy[]' "$manifest")
  if [[ -f "$PS_CHECKOUT/README.md" && ! -L "$PS_CHECKOUT/README.md" ]]; then
    ps_note preserved "README.md"
  fi
  if [[ -d "$PS_CHECKOUT/.github/workflows" && ! -L "$PS_CHECKOUT/.github/workflows" ]]; then
    while IFS= read -r path; do
      ps_note preserved "${path#"$PS_CHECKOUT"/}"
    done < <(find -P "$PS_CHECKOUT/.github/workflows" -type f -print | LC_ALL=C sort)
  fi
}

ps_class() {
  if [[ "$PS_CONFLICT" == 1 ]]; then printf 'conflict'
  elif [[ "$PS_LEGACY" == 1 ]]; then printf 'legacy'
  elif [[ "$PS_CHANGE" == 1 && "$PS_PRESENT" == 1 ]]; then printf 'drift'
  elif [[ "$PS_CHANGE" == 1 ]]; then printf 'absent'
  else printf 'exact'
  fi
}

ps_restore_list() {
  local list="$1" only_missing="$2" path
  [[ -f "$PS_WORK/backup/$list" ]] || return 0
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    if [[ "$only_missing" == 1 && ( -e "$PS_CHECKOUT/$path" || -L "$PS_CHECKOUT/$path" ) ]]; then
      continue
    fi
    mkdir -p -- "$PS_CHECKOUT/$(dirname "$path")"
    cp -p -- "$PS_WORK/backup/files/$path" "$PS_CHECKOUT/$path"
  done < "$PS_WORK/backup/$list"
}

ps_rollback() {
  ps_restore_list restore 0
  local path
  if [[ -f "$PS_WORK/backup/created" ]]; then
    while IFS= read -r path; do
      [[ -n "$path" ]] || continue
      rm -f -- "$PS_CHECKOUT/$path"
    done < "$PS_WORK/backup/created"
  fi
  ps_restore_list removed 1
}

ps_backup_file() {
  local path="$1" list="$2"
  mkdir -p -- "$PS_WORK/backup/files/$(dirname "$path")" || return 1
  cp -p -- "$PS_CHECKOUT/$path" "$PS_WORK/backup/files/$path" || return 1
  printf '%s\n' "$path" >> "$PS_WORK/backup/$list"
}

ps_apply() {
  local path staged payload
  [[ "$PS_CONFLICT" == 0 ]] || return 1
  mkdir -p -- "$PS_WORK/backup/files" || return 1
  : > "$PS_WORK/backup/restore"
  : > "$PS_WORK/backup/created"
  : > "$PS_WORK/backup/removed"
  while IFS=$'\t' read -r path staged; do
    [[ -n "$path" ]] || continue
    [[ -L "$PS_CHECKOUT/$path" ]] && return 1
    if [[ -e "$PS_CHECKOUT/$path" ]]; then
      ps_backup_file "$path" restore || return 1
    else
      printf '%s\n' "$path" >> "$PS_WORK/backup/created"
    fi
  done < "$PS_WRITES"
  while IFS=$'\t' read -r path payload; do
    [[ -n "$path" ]] || continue
    [[ -f "$PS_CHECKOUT/$path" && ! -L "$PS_CHECKOUT/$path" ]] || return 1
    ps_backup_file "$path" removed || return 1
  done < "$PS_REMOVALS"
  while IFS=$'\t' read -r path staged; do
    [[ -n "$path" ]] || continue
    mkdir -p -- "$PS_CHECKOUT/$(dirname "$path")" || { ps_rollback; return 1; }
    cp -- "$staged" "$PS_CHECKOUT/$path" || { ps_rollback; return 1; }
  done < "$PS_WRITES"
  while IFS=$'\t' read -r path payload; do
    [[ -n "$path" ]] || continue
    if ! ps_bytes_equal "$PS_CHECKOUT/$path" "$payload"; then ps_rollback; return 1; fi
    rm -f -- "$PS_CHECKOUT/$path" || { ps_rollback; return 1; }
  done < "$PS_REMOVALS"
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
    ps_require_rel_path "$rel" || ps_die_unverified "payload path"
    [[ -f "$PS_SOURCE/$rel" ]] || ps_fetch_file "$rel"
  done < <(jq -r '.protocol_sync.managed[].payload, .protocol_sync.owned_exact[].payload' "$manifest")
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
  printf '\n' > "$PS_WORK/nl-byte"
  PS_ROWS="$PS_WORK/rows"
  PS_WRITES="$PS_WORK/writes"
  PS_REMOVALS="$PS_WORK/removals"
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
    [[ "$apply_status" == 0 ]] || ps_die_unverified "apply"
  fi
  ps_emit exact exact
  exit 0
}
