#!/usr/bin/env bash
# Permanent protocol-sync coverage. Fixtures only; no live GitHub writes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
RECONCILE="$ROOT/tools/repo-reconciler/reconcile.sh"
LIB="$ROOT/tools/repo-reconciler/lib/protocol-sync.sh"
# shellcheck source=../lib/protocol-sync.sh
source "$LIB"

eval "$(declare -f ps_guard_record | sed '1s/ps_guard_record/ps_guard_record_saved/')"
ps_guard_record() {
  [[ "${PLAN_RACE_PATH:-}" != "$2" ]] || printf '%s\n' "${PLAN_RACE_BYTES:-malformed late managed file}" > "$PS_CHECKOUT/$2"
  ps_guard_record_saved "$@"
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CASE=""; unset PLAN_RACE_PATH PLAN_RACE_BYTES
ERR="$TMP/err"
PS_OUT=""
PS_CODE=0

fail() {
  echo "protocol-sync self-test failed: ${CASE}: $*" >&2
  exit 1
}

run_sync() {
  local err="$1"
  shift
  set +e
  PS_OUT=$("$@" 2>"$err")
  PS_CODE=$?
  set -e
  return 0
}

assert_code() {
  [[ "$PS_CODE" == "$1" ]] || fail "exit $PS_CODE want $1; err=$(cat "$ERR"); out=[$PS_OUT]"
}

assert_line() {
  grep -x -F -- "$1" <<<"$PS_OUT" >/dev/null || fail "missing [$1]; out=[$PS_OUT]"
}

assert_no_line() {
  if grep -x -F -- "$1" <<<"$PS_OUT" >/dev/null; then
    fail "unexpected [$1]"
  fi
}

seal() {
  local root="$1" out="$2" p rel sum
  {
    find "$root" \( -type d -o -type f -o -type l \) -print | LC_ALL=C sort | while IFS= read -r p; do
      [[ "$p" == "$root" ]] && continue
      rel="${p#"$root"/}"
      if [[ -L "$p" ]]; then
        printf 'link %s -> %s\n' "$rel" "$(readlink "$p")"
      elif [[ -d "$p" ]]; then
        printf 'dir %s\n' "$rel"
      else
        sum="$(cksum "$p" | awk '{print $1 "-" $2}')"
        printf 'file %s %s\n' "$sum" "$rel"
      fi
    done
  } > "$out"
}

assert_unchanged() {
  local before="$1" after="$2"
  cmp -s "$before" "$after" || fail "checkout changed"
}

write_source() {
  local dir="$1" owned="${2:-[]}"
  mkdir -p "$dir/tools/repo-reconciler/templates" "$dir/.github/ISSUE_TEMPLATE" "$dir/payloads"
  printf 'agents-payload\n' > "$dir/tools/repo-reconciler/templates/minimal-consumer-AGENTS.md"
  printf 'task-payload\n' > "$dir/tools/repo-reconciler/templates/consumer-task-protocol.md"
  printf 'pr-payload\n' > "$dir/tools/repo-reconciler/templates/consumer-pr-protocol.md"
  printf 'owned-payload\n' > "$dir/payloads/owned.txt"
  jq -n --argjson owned "$owned" '{
    schema_version: 3,
    baseline: "fixture-baseline",
    protocol_sync: {
      markers: {
        start: "<!-- g-lite:managed protocol start -->",
        end: "<!-- g-lite:managed protocol end -->"
      },
      managed: [
        {path: "AGENTS.md", payload: "tools/repo-reconciler/templates/minimal-consumer-AGENTS.md"},
        {path: ".github/ISSUE_TEMPLATE/task.md", payload: "tools/repo-reconciler/templates/consumer-task-protocol.md"},
        {path: ".github/pull_request_template.md", payload: "tools/repo-reconciler/templates/consumer-pr-protocol.md"}
      ],
      legacy: [
        {path: ".github/ISSUE_TEMPLATE/contract.md", canonical: ".github/ISSUE_TEMPLATE/task.md"}
      ],
      owned_exact: $owned
    }
  }' > "$dir/tools/repo-reconciler/manifest.json"
}

wrap_file() {
  local payload="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  {
    if [[ -n "${3:-}" ]]; then printf '%s' "$3"; fi
    printf '%s\n' "$PS_START"
    cat -- "$payload"
    printf '%s\n' "$PS_END"
    if [[ -n "${4:-}" ]]; then printf '%s' "$4"; fi
  } > "$dest"
}

write_marked_file() {
  local prefix="$1" payload="$2" suffix="$3" dest="$4"
  mkdir -p "$(dirname "$dest")"
  {
    cat -- "$prefix"
    printf '%s\n' "$PS_START"
    cat -- "$payload"
    printf '%s\n' "$PS_END"
    cat -- "$suffix"
  } > "$dest"
}

install_exact() {
  local src="$1" dest="$2"
  wrap_file "$src/tools/repo-reconciler/templates/minimal-consumer-AGENTS.md" "$dest/AGENTS.md"
  wrap_file "$src/tools/repo-reconciler/templates/consumer-task-protocol.md" "$dest/.github/ISSUE_TEMPLATE/task.md"
  wrap_file "$src/tools/repo-reconciler/templates/consumer-pr-protocol.md" "$dest/.github/pull_request_template.md"
}

write_consumer() {
  local dir="$1"
  printf 'readme-consumer\n' > "$dir/README.md"
  mkdir -p "$dir/.github/workflows"
  printf 'workflow-consumer\n' > "$dir/.github/workflows/ci.yml"
}

install_mutation_probe() {
  PROBE_CHECKOUT="$1" PROBE_LOG="$2"
  : > "$PROBE_LOG"
  export PROBE_CHECKOUT PROBE_LOG
  probe_checkout_write() {
    case "$1" in "$PROBE_CHECKOUT"|"$PROBE_CHECKOUT"/*) printf '%s %s\n' "$2" "$1" >> "$PROBE_LOG" ;; esac
  }
  mkdir() { local target; for target; do :; done; probe_checkout_write "$target" mkdir; command mkdir "$@"; }
  cp() { local target; for target; do :; done; probe_checkout_write "$target" cp; command cp "$@"; }
  rm() { local target; for target; do [[ "$target" != -* ]] && probe_checkout_write "$target" rm; done; command rm "$@"; }
  export -f probe_checkout_write mkdir cp rm
}

clear_mutation_probe() {
  unset -f probe_checkout_write mkdir cp rm
  unset PROBE_CHECKOUT PROBE_LOG
}

expect_prewrite_conflict() {
  local log="$1" message="$2" status
  set +e; ps_apply; status=$?; set -e
  clear_mutation_probe
  [[ "$status" == 2 && "$PS_CONFLICT" == 1 ]] || fail "$message"
  [[ ! -s "$log" ]] || fail "checkout mutation attempted before conflict"
}

l1_reset() {
  rm -rf "$TMP/l1"
  PS_WORK="$TMP/l1"
  PS_CHECKOUT="$PS_WORK/checkout"
  mkdir -p "$PS_CHECKOUT" "$PS_WORK/staged"
  printf '\n' > "$PS_WORK/nl-byte"
}

CASE="ancestor-filesystem-types"; l1_reset; mkdir -p "$PS_CHECKOUT/.github" "$TMP/ancestor-target"
ps_ancestor_safe ".github/ISSUE_TEMPLATE/task.md" || fail "real directory ancestor rejected"
rmdir "$PS_CHECKOUT/.github"; printf 'file\n' > "$PS_CHECKOUT/.github"
if ps_ancestor_safe ".github/ISSUE_TEMPLATE/task.md"; then fail "ordinary-file ancestor accepted"; fi
rm "$PS_CHECKOUT/.github"; ln -s "$TMP/ancestor-target" "$PS_CHECKOUT/.github"
if ps_ancestor_safe ".github/ISSUE_TEMPLATE/task.md"; then fail "symlink ancestor accepted"; fi

CASE="l1-interior"
l1_reset
payload="$PS_WORK/payload"
printf 'agents-payload\n' > "$payload"
{
  printf 'BEFORE-CONSUMER\n'
  printf '%s\n' "$PS_START"
  printf 'STALE\n'
  printf '%s\n' "$PS_END"
  printf 'AFTER-CONSUMER\n'
} > "$PS_CHECKOUT/AGENTS.md"
status="$(ps_classify_managed "AGENTS.md" "$payload" "$PS_WORK/staged/out")"
[[ "$status" == changed ]] || fail "status $status"
{
  printf 'BEFORE-CONSUMER\n'
  printf '%s\n' "$PS_START"
  cat -- "$payload"
  printf '%s\n' "$PS_END"
  printf 'AFTER-CONSUMER\n'
} > "$PS_WORK/expect"
cmp -s "$PS_WORK/expect" "$PS_WORK/staged/out" || fail "exterior or interior bytes"
printf 'BEFORE-CONSUMER\n' > "$PS_WORK/pre"
printf 'AFTER-CONSUMER\n' > "$PS_WORK/post"
pre_len="$(ps_size "$PS_WORK/pre")"
post_len="$(ps_size "$PS_WORK/post")"
head -c "$pre_len" "$PS_WORK/staged/out" > "$PS_WORK/got-pre"
tail -c "$post_len" "$PS_WORK/staged/out" > "$PS_WORK/got-post"
cmp -s "$PS_WORK/pre" "$PS_WORK/got-pre" || fail "exterior prefix"
cmp -s "$PS_WORK/post" "$PS_WORK/got-post" || fail "exterior suffix"

CASE="l1-wrap-template"
l1_reset
printf 'agents-payload\n' > "$PS_WORK/payload"
payload="$PS_WORK/payload"
cp -- "$payload" "$PS_CHECKOUT/AGENTS.md"
status="$(ps_classify_managed "AGENTS.md" "$payload" "$PS_WORK/staged/out")"
[[ "$status" == changed ]] || fail "status $status"
wrap_file "$payload" "$PS_WORK/expect"
cmp -s "$PS_WORK/expect" "$PS_WORK/staged/out" || fail "unwrap was not wrapped"

CASE="l1-malformed"
l1_reset
printf 'agents-payload\n' > "$PS_WORK/payload"
payload="$PS_WORK/payload"
printf 'consumer text\n' > "$PS_CHECKOUT/AGENTS.md"
[[ "$(ps_classify_managed "AGENTS.md" "$payload" "$PS_WORK/staged/missing")" == conflict ]] || fail "missing markers"
{
  printf '%s\n' "$PS_START"
  printf '%s\n' "$PS_START"
  printf 'STALE\n'
  printf '%s\n' "$PS_END"
} > "$PS_CHECKOUT/AGENTS.md"
[[ "$(ps_classify_managed "AGENTS.md" "$payload" "$PS_WORK/staged/dup")" == conflict ]] || fail "duplicate markers"
{
  printf '%s\n' "$PS_END"
  printf 'STALE\n'
  printf '%s\n' "$PS_START"
} > "$PS_CHECKOUT/AGENTS.md"
[[ "$(ps_classify_managed "AGENTS.md" "$payload" "$PS_WORK/staged/order")" == conflict ]] || fail "reordered markers"

CASE="l1-legacy-equality"
printf 'task-payload\n' > "$PS_WORK/a"
cp -- "$PS_WORK/a" "$PS_WORK/b"
printf 'task-payload-x\n' > "$PS_WORK/c"
ps_bytes_equal "$PS_WORK/a" "$PS_WORK/b" || fail "equal bytes were rejected"
if ps_bytes_equal "$PS_WORK/a" "$PS_WORK/c"; then
  fail "divergent bytes compared equal"
fi

write_source "$TMP/src"
SRC="$TMP/src"

sync_from() {
  local source="$1" dest="$2"
  shift 2
  run_sync "$ERR" "$RECONCILE" protocol-sync --checkout "$dest" --source "$source" "$@"
}

sync_source() {
  local dest="$1"
  shift
  sync_from "$SRC" "$dest" "$@"
}

plan_source() {
  PS_WORK="$1"; PS_CHECKOUT="$2"; PS_SOURCE="${3:-$SRC}"; PS_REF=source; PS_SHA=local
  mkdir -p "$PS_WORK/staged"; printf '\n' > "$PS_WORK/nl-byte"
  PS_ROWS="$PS_WORK/rows"; PS_WRITES="$PS_WORK/writes"; PS_REMOVALS="$PS_WORK/removals"
  ps_plan
}

CASE="non-directory-ancestor-zero-write"
co="$TMP/non-directory-ancestor"
mkdir -p "$co"
printf '%s\nSTALE\n%s\n' "$PS_START" "$PS_END" > "$co/AGENTS.md"
printf 'ordinary file\n' > "$co/.github"
seal "$co" "$TMP/non-directory.before"
install_mutation_probe "$co" "$TMP/non-directory.writes"
run_sync "$ERR" "$RECONCILE" protocol-sync --checkout "$co" --source "$SRC" --write
clear_mutation_probe
assert_code 2
assert_line $'FILE\tchanged\tAGENTS.md'
assert_line $'FILE\tconflict\t.github/ISSUE_TEMPLATE/task.md'
assert_line $'SYNC\tconflict'
[[ ! -s "$TMP/non-directory.writes" ]] || fail "checkout mutation attempted before ancestor conflict"
cmp -s <(printf 'ordinary file\n') "$co/.github" || fail ".github file changed"
[[ ! -e "$co/.github/ISSUE_TEMPLATE/task.md" ]] || fail "nested task path created"
seal "$co" "$TMP/non-directory.after"
assert_unchanged "$TMP/non-directory.before" "$TMP/non-directory.after"

CASE="legacy-changed-after-plan-zero-write"
co="$TMP/legacy-race"
mkdir -p "$co"
install_exact "$SRC" "$co"
printf '%s\nSTALE\n%s\n' "$PS_START" "$PS_END" > "$co/AGENTS.md"
cp -- "$SRC/tools/repo-reconciler/templates/consumer-task-protocol.md" "$co/.github/ISSUE_TEMPLATE/contract.md"
cp -- "$co/AGENTS.md" "$TMP/legacy-race.agents.before"
PLAN_RACE_PATH=.github/ISSUE_TEMPLATE/contract.md; PLAN_RACE_BYTES='legacy changed during plan'
plan_source "$TMP/legacy-race-work" "$co"
unset PLAN_RACE_PATH PLAN_RACE_BYTES
[[ "$PS_CONFLICT" == 0 && "$PS_CHANGE" == 1 && "$PS_LEGACY" == 1 ]] && cmp -s <(printf 'legacy changed during plan\n') "$co/.github/ISSUE_TEMPLATE/contract.md" || fail "race fixture did not plan a write and legacy removal"
[[ -s "$PS_WRITES" && -s "$PS_REMOVALS" ]] || fail "race plan omitted a transaction path"
grep -F $'legacy\t.github/ISSUE_TEMPLATE/contract.md\tremoval\t' "$PS_GUARDS" >/dev/null || fail "legacy removal guard was not recorded"
printf 'legacy changed after plan\n' > "$co/.github/ISSUE_TEMPLATE/contract.md"
install_mutation_probe "$co" "$TMP/legacy-race.writes"
expect_prewrite_conflict "$TMP/legacy-race.writes" "legacy race was not a pre-write conflict"
cmp -s "$TMP/legacy-race.agents.before" "$co/AGENTS.md" || fail "managed file was mutated before conflict"
cmp -s <(printf 'legacy changed after plan\n') "$co/.github/ISSUE_TEMPLATE/contract.md" || fail "changed legacy alias was removed or rewritten"

CASE="legacy-absent-appears-divergent-zero-write"
co="$TMP/legacy-absent-race"
mkdir -p "$co"
install_exact "$SRC" "$co"
printf '%s\nSTALE\n%s\n' "$PS_START" "$PS_END" > "$co/AGENTS.md"
rm -- "$co/.github/ISSUE_TEMPLATE/task.md"
cp -- "$co/AGENTS.md" "$TMP/legacy-absent.agents.before"
plan_source "$TMP/legacy-absent-work" "$co"
[[ "$PS_CONFLICT" == 0 && "$PS_CHANGE" == 1 ]] || fail "absent-alias fixture did not plan managed writes"
grep -F $'legacy\t.github/ISSUE_TEMPLATE/contract.md\tabsent\t-' "$PS_GUARDS" >/dev/null || fail "absent legacy guard was not recorded"
install_mutation_probe "$co" "$TMP/legacy-absent.writes"
cp() {
  local target
  for target; do :; done
  probe_checkout_write "$target" cp
  if [[ "$target" == "$PS_WORK/backup/files/AGENTS.md" ]]; then printf 'divergent late alias\n' > "$co/.github/ISSUE_TEMPLATE/contract.md"; fi
  command cp "$@"
}
expect_prewrite_conflict "$TMP/legacy-absent.writes" "appeared divergent legacy alias was not a pre-write conflict"
cmp -s "$TMP/legacy-absent.agents.before" "$co/AGENTS.md" || fail "AGENTS changed before absent-alias conflict"
[[ ! -e "$co/.github/ISSUE_TEMPLATE/task.md" ]] || fail "task.md created before absent-alias conflict"
cmp -s <(printf 'divergent late alias\n') "$co/.github/ISSUE_TEMPLATE/contract.md" || fail "late divergent alias changed"

CASE="managed-unchanged-malformed-after-plan-zero-write"
co="$TMP/managed-unchanged-race"
mkdir -p "$co"
install_exact "$SRC" "$co"
printf '%s\nSTALE\n%s\n' "$PS_START" "$PS_END" > "$co/AGENTS.md"
cp -- "$co/AGENTS.md" "$TMP/managed-unchanged.agents.before"
PLAN_RACE_PATH=.github/ISSUE_TEMPLATE/task.md
plan_source "$TMP/managed-unchanged-work" "$co"
unset PLAN_RACE_PATH
grep -F $'managed\t.github/ISSUE_TEMPLATE/task.md\tunchanged\t' "$PS_GUARDS" >/dev/null || fail "unchanged managed guard was not recorded"
printf 'malformed late managed file\n' > "$co/.github/ISSUE_TEMPLATE/task.md"
install_mutation_probe "$co" "$TMP/managed-unchanged.writes"
expect_prewrite_conflict "$TMP/managed-unchanged.writes" "malformed unchanged managed file was not a pre-write conflict"
cmp -s "$TMP/managed-unchanged.agents.before" "$co/AGENTS.md" || fail "AGENTS changed before unchanged-path conflict"
cmp -s <(printf 'malformed late managed file\n') "$co/.github/ISSUE_TEMPLATE/task.md" || fail "malformed managed file changed"

CASE="managed-changed-after-plan-zero-write"
co="$TMP/managed-changed-race"
mkdir -p "$co"
install_exact "$SRC" "$co"
printf '%s\nSTALE\n%s\n' "$PS_START" "$PS_END" > "$co/AGENTS.md"
plan_source "$TMP/managed-changed-work" "$co"
grep -F $'managed\tAGENTS.md\tchanged\t' "$PS_GUARDS" >/dev/null || fail "changed managed guard was not recorded"
printf '%s\nLATE\n%s\n' "$PS_START" "$PS_END" > "$co/AGENTS.md"
install_mutation_probe "$co" "$TMP/managed-changed.writes"
expect_prewrite_conflict "$TMP/managed-changed.writes" "changed managed source was not a pre-write conflict"
cmp -s <(printf '%s\nLATE\n%s\n' "$PS_START" "$PS_END") "$co/AGENTS.md" || fail "late managed source was overwritten"

CASE="exact-report"
co="$TMP/exact"
mkdir -p "$co"
install_exact "$SRC" "$co"
write_consumer "$co"
seal "$co" "$TMP/exact.before"
sync_source "$co"
assert_code 0
assert_line $'BASELINE\tcurrent\texact\tlocal\tfixture-baseline'
assert_line $'BASELINE\ttarget\tsource\tlocal\tfixture-baseline'
assert_line $'FILE\tunchanged\tAGENTS.md'
assert_line $'FILE\tunchanged\t.github/ISSUE_TEMPLATE/task.md'
assert_line $'FILE\tunchanged\t.github/pull_request_template.md'
assert_line $'FILE\tpreserved\tREADME.md'
assert_line $'FILE\tpreserved\t.github/workflows/ci.yml'
assert_line $'SYNC\texact'
assert_no_line $'FILE\tchanged\tAGENTS.md'
seal "$co" "$TMP/exact.after"
assert_unchanged "$TMP/exact.before" "$TMP/exact.after"

CASE="drift-report"
co="$TMP/drift"
mkdir -p "$co"
install_exact "$SRC" "$co"
{
  printf 'BEFORE-CONSUMER\n'
  printf '%s\n' "$PS_START"
  printf 'STALE\n'
  printf '%s\n' "$PS_END"
  printf 'AFTER-CONSUMER\n'
} > "$co/AGENTS.md"
write_consumer "$co"
seal "$co" "$TMP/drift.before"
sync_source "$co"
assert_code 2
assert_line $'BASELINE\tcurrent\tdrift\tunrecorded\t-'
assert_line $'BASELINE\ttarget\tsource\tlocal\tfixture-baseline'
assert_line $'FILE\tchanged\tAGENTS.md'
assert_line $'FILE\tunchanged\t.github/ISSUE_TEMPLATE/task.md'
assert_line $'SYNC\tpending'
seal "$co" "$TMP/drift.after"
assert_unchanged "$TMP/drift.before" "$TMP/drift.after"
sync_source "$co" --write
assert_code 0
assert_line $'BASELINE\tcurrent\texact\tlocal\tfixture-baseline'
assert_line $'SYNC\texact'
{
  printf 'BEFORE-CONSUMER\n'
  printf '%s\n' "$PS_START"
  cat -- "$SRC/tools/repo-reconciler/templates/minimal-consumer-AGENTS.md"
  printf '%s\n' "$PS_END"
  printf 'AFTER-CONSUMER\n'
} > "$TMP/drift.expect"
cmp -s "$TMP/drift.expect" "$co/AGENTS.md" || fail "managed interior did not converge"
cmp -s "$co/README.md" <(printf 'readme-consumer\n') || fail "README changed"
cmp -s "$co/.github/workflows/ci.yml" <(printf 'workflow-consumer\n') || fail "workflow changed"
seal "$co" "$TMP/drift.written"
sync_source "$co" --write
assert_code 0
assert_line $'SYNC\texact'
assert_no_line $'FILE\tchanged\tAGENTS.md'
seal "$co" "$TMP/drift.second"
assert_unchanged "$TMP/drift.written" "$TMP/drift.second"

CASE="real-template-payload"
co="$TMP/real"
mkdir -p "$co"
cp -- "$ROOT/tools/repo-reconciler/templates/minimal-consumer-AGENTS.md" \
  "$SRC/tools/repo-reconciler/templates/minimal-consumer-AGENTS.md"
install_exact "$SRC" "$co"
{
  printf 'KEEP-OUTSIDE\n'
  printf '%s\n' "$PS_START"
  printf 'OLD\n'
  printf '%s\n' "$PS_END"
  printf 'KEEP-AFTER\n'
} > "$co/AGENTS.md"
sync_source "$co" --write
assert_code 0
{
  printf 'KEEP-OUTSIDE\n'
  printf '%s\n' "$PS_START"
  cat -- "$ROOT/tools/repo-reconciler/templates/minimal-consumer-AGENTS.md"
  printf '%s\n' "$PS_END"
  printf 'KEEP-AFTER\n'
} > "$TMP/real.expect"
cmp -s "$TMP/real.expect" "$co/AGENTS.md" || fail "canonical template was not the interior"
if cmp -s "$ROOT/AGENTS.md" "$co/AGENTS.md"; then
  fail "root AGENTS.md was used as the consumer payload"
fi
printf 'agents-payload\n' > "$SRC/tools/repo-reconciler/templates/minimal-consumer-AGENTS.md"

CASE="consumer-fragments-preserve-exterior"
pilot_src="$TMP/consumer-source"
mkdir -p "$pilot_src/tools/repo-reconciler/templates"
cp -- "$ROOT/tools/repo-reconciler/manifest.json" "$pilot_src/tools/repo-reconciler/manifest.json"
cp -- "$ROOT/tools/repo-reconciler/templates/minimal-consumer-AGENTS.md" \
  "$pilot_src/tools/repo-reconciler/templates/minimal-consumer-AGENTS.md"
cp -- "$ROOT/tools/repo-reconciler/templates/consumer-task-protocol.md" \
  "$pilot_src/tools/repo-reconciler/templates/consumer-task-protocol.md"
cp -- "$ROOT/tools/repo-reconciler/templates/consumer-pr-protocol.md" \
  "$pilot_src/tools/repo-reconciler/templates/consumer-pr-protocol.md"
co="$TMP/ops-consumer"
mkdir -p "$co/.github/ISSUE_TEMPLATE" "$co/.github/workflows" "$co/docs" "$co/tools"
write_consumer "$co"
printf 'consumer docs\n' > "$co/docs/consumer.md"
printf 'consumer tool\n' > "$co/tools/consumer-tool.sh"
cat > "$TMP/ops-task.prefix" <<'EOF'
---
name: OPS Task
---
## Scope
## Safety and public boundary
EOF
printf '%s\n' '## OPS acceptance' > "$TMP/ops-task.suffix"
cat > "$TMP/ops-pr.prefix" <<'EOF'
## Why
## Test
python3 -m unittest discover -s tests -p 'test_*.py'
## Knowledge migrated
## Deleted legacy architecture
## Public-safety review
EOF
printf '%s\n' '## OPS release notes' > "$TMP/ops-pr.suffix"
printf 'stale task interior\n' > "$TMP/stale-task"
printf 'stale PR interior\n' > "$TMP/stale-pr"
write_marked_file "$TMP/ops-task.prefix" "$TMP/stale-task" "$TMP/ops-task.suffix" \
  "$co/.github/ISSUE_TEMPLATE/task.md"
write_marked_file "$TMP/ops-pr.prefix" "$TMP/stale-pr" "$TMP/ops-pr.suffix" \
  "$co/.github/pull_request_template.md"
cp -a "$co" "$TMP/ops-consumer.before"
sync_from "$pilot_src" "$co" --write
assert_code 0
assert_line $'FILE\tchanged\t.github/ISSUE_TEMPLATE/task.md'
assert_line $'FILE\tchanged\t.github/pull_request_template.md'
assert_line $'FILE\tpreserved\tREADME.md'
assert_line $'FILE\tpreserved\t.github/workflows/ci.yml'
assert_line $'SYNC\texact'
write_marked_file "$TMP/ops-task.prefix" \
  "$pilot_src/tools/repo-reconciler/templates/consumer-task-protocol.md" \
  "$TMP/ops-task.suffix" "$TMP/ops-task.expected"
write_marked_file "$TMP/ops-pr.prefix" \
  "$pilot_src/tools/repo-reconciler/templates/consumer-pr-protocol.md" \
  "$TMP/ops-pr.suffix" "$TMP/ops-pr.expected"
cmp -s "$TMP/ops-task.expected" "$co/.github/ISSUE_TEMPLATE/task.md" || fail "task fragment or exterior bytes"
cmp -s "$TMP/ops-pr.expected" "$co/.github/pull_request_template.md" || fail "PR fragment or exterior bytes"
for path in README.md .github/workflows/ci.yml docs/consumer.md tools/consumer-tool.sh; do
  cmp -s "$TMP/ops-consumer.before/$path" "$co/$path" || fail "consumer-owned path changed: $path"
done
grep -Fq "python3 -m unittest discover -s tests -p 'test_*.py'" \
  "$co/.github/pull_request_template.md" || fail "consumer Test command was lost"
if grep -Fq 'tests/run.sh' "$co/.github/ISSUE_TEMPLATE/task.md" "$co/.github/pull_request_template.md"; then
  fail "canonical tests/run.sh entered the consumer"
fi
seal "$co" "$TMP/ops-consumer.once"
sync_from "$pilot_src" "$co" --write
assert_code 0
assert_line $'SYNC\texact'
seal "$co" "$TMP/ops-consumer.twice"
assert_unchanged "$TMP/ops-consumer.once" "$TMP/ops-consumer.twice"

CASE="absent"
co="$TMP/absent"
mkdir -p "$co"
sync_source "$co"
assert_code 2
assert_line $'BASELINE\tcurrent\tabsent\tunrecorded\t-'
assert_line $'SYNC\tpending'
[[ ! -e "$co/AGENTS.md" ]] || fail "dry run created a file"
sync_source "$co" --write
assert_code 0
assert_line $'SYNC\texact'
wrap_file "$SRC/tools/repo-reconciler/templates/minimal-consumer-AGENTS.md" "$TMP/absent.agents"
wrap_file "$SRC/tools/repo-reconciler/templates/consumer-task-protocol.md" "$TMP/absent.task"
wrap_file "$SRC/tools/repo-reconciler/templates/consumer-pr-protocol.md" "$TMP/absent.pr"
cmp -s "$TMP/absent.agents" "$co/AGENTS.md" || fail "absent AGENTS"
cmp -s "$TMP/absent.task" "$co/.github/ISSUE_TEMPLATE/task.md" || fail "absent task"
cmp -s "$TMP/absent.pr" "$co/.github/pull_request_template.md" || fail "absent pr"

CASE="legacy-migration"
co="$TMP/legacy-ok"
mkdir -p "$co"
wrap_file "$SRC/tools/repo-reconciler/templates/minimal-consumer-AGENTS.md" "$co/AGENTS.md"
wrap_file "$SRC/tools/repo-reconciler/templates/consumer-pr-protocol.md" "$co/.github/pull_request_template.md"
mkdir -p "$co/.github/ISSUE_TEMPLATE"
cp -- "$SRC/tools/repo-reconciler/templates/consumer-task-protocol.md" "$co/.github/ISSUE_TEMPLATE/contract.md"
seal "$co" "$TMP/legacy-ok.before"
sync_source "$co"
assert_code 2
assert_line $'BASELINE\tcurrent\tlegacy\tunrecorded\t-'
assert_line $'FILE\tremoved\t.github/ISSUE_TEMPLATE/contract.md'
assert_line $'FILE\tchanged\t.github/ISSUE_TEMPLATE/task.md'
assert_line $'SYNC\tpending'
[[ ! -e "$co/.github/ISSUE_TEMPLATE/task.md" ]] || fail "dry run created task.md"
seal "$co" "$TMP/legacy-ok.after"
assert_unchanged "$TMP/legacy-ok.before" "$TMP/legacy-ok.after"
sync_source "$co" --write
assert_code 0
[[ ! -e "$co/.github/ISSUE_TEMPLATE/contract.md" ]] || fail "legacy path remained"
wrap_file "$SRC/tools/repo-reconciler/templates/consumer-task-protocol.md" "$TMP/legacy-ok.task"
cmp -s "$TMP/legacy-ok.task" "$co/.github/ISSUE_TEMPLATE/task.md" || fail "legacy did not become managed task.md"

CASE="legacy-divergent"
co="$TMP/legacy-bad"
mkdir -p "$co/.github/ISSUE_TEMPLATE"
printf 'not-the-payload\n' > "$co/.github/ISSUE_TEMPLATE/contract.md"
{
  printf '%s\n' "$PS_START"
  printf 'STALE\n'
  printf '%s\n' "$PS_END"
} > "$co/AGENTS.md"
seal "$co" "$TMP/legacy-bad.before"
sync_source "$co" --write
assert_code 2
assert_line $'FILE\tconflict\t.github/ISSUE_TEMPLATE/contract.md'
assert_line $'SYNC\tconflict'
[[ ! -e "$co/.github/ISSUE_TEMPLATE/task.md" ]] || fail "divergent legacy created task.md"
seal "$co" "$TMP/legacy-bad.after"
assert_unchanged "$TMP/legacy-bad.before" "$TMP/legacy-bad.after"

CASE="duplicate-removed"
co="$TMP/dup-ok"
mkdir -p "$co"
install_exact "$SRC" "$co"
cp -- "$SRC/tools/repo-reconciler/templates/consumer-task-protocol.md" "$co/.github/ISSUE_TEMPLATE/contract.md"
sync_source "$co" --write
assert_code 0
assert_line $'FILE\tremoved\t.github/ISSUE_TEMPLATE/contract.md'
assert_line $'FILE\tunchanged\t.github/ISSUE_TEMPLATE/task.md'
[[ ! -e "$co/.github/ISSUE_TEMPLATE/contract.md" ]] || fail "identical duplicate remained"
wrap_file "$SRC/tools/repo-reconciler/templates/consumer-task-protocol.md" "$TMP/dup-ok.task"
cmp -s "$TMP/dup-ok.task" "$co/.github/ISSUE_TEMPLATE/task.md" || fail "canonical task changed"

CASE="duplicate-divergent"
co="$TMP/dup-bad"
mkdir -p "$co"
install_exact "$SRC" "$co"
printf 'different-duplicate\n' > "$co/.github/ISSUE_TEMPLATE/contract.md"
task_sum="$(cksum "$co/.github/ISSUE_TEMPLATE/task.md")"
sync_source "$co" --write
assert_code 2
assert_line $'FILE\tconflict\t.github/ISSUE_TEMPLATE/contract.md'
assert_line $'SYNC\tconflict'
[[ -f "$co/.github/ISSUE_TEMPLATE/contract.md" ]] || fail "divergent duplicate was removed"
cmp -s <(printf 'different-duplicate\n') "$co/.github/ISSUE_TEMPLATE/contract.md" || fail "divergent duplicate bytes changed"
[[ "$task_sum" == "$(cksum "$co/.github/ISSUE_TEMPLATE/task.md")" ]] || fail "task.md changed during conflict"

CASE="wrap-untouched-template"
co="$TMP/wrap"
mkdir -p "$co"
cp -- "$SRC/tools/repo-reconciler/templates/minimal-consumer-AGENTS.md" "$co/AGENTS.md"
wrap_file "$SRC/tools/repo-reconciler/templates/consumer-task-protocol.md" "$co/.github/ISSUE_TEMPLATE/task.md"
wrap_file "$SRC/tools/repo-reconciler/templates/consumer-pr-protocol.md" "$co/.github/pull_request_template.md"
sync_source "$co" --write
assert_code 0
wrap_file "$SRC/tools/repo-reconciler/templates/minimal-consumer-AGENTS.md" "$TMP/wrap.expect"
cmp -s "$TMP/wrap.expect" "$co/AGENTS.md" || fail "untouched template was not wrapped"
seal "$co" "$TMP/wrap.once"
sync_source "$co" --write
assert_code 0
assert_line $'SYNC\texact'
assert_no_line $'FILE\tchanged\tAGENTS.md'
seal "$co" "$TMP/wrap.twice"
assert_unchanged "$TMP/wrap.once" "$TMP/wrap.twice"

CASE="missing-markers-fail-closed"
co="$TMP/missing"
mkdir -p "$co/.github/ISSUE_TEMPLATE"
printf 'NO MARKERS\n' > "$co/AGENTS.md"
cp -- "$SRC/tools/repo-reconciler/templates/consumer-task-protocol.md" "$co/.github/ISSUE_TEMPLATE/task.md"
seal "$co" "$TMP/missing.before"
sync_source "$co" --write
assert_code 2
assert_line $'FILE\tconflict\tAGENTS.md'
assert_line $'SYNC\tconflict'
seal "$co" "$TMP/missing.after"
assert_unchanged "$TMP/missing.before" "$TMP/missing.after"
cmp -s "$SRC/tools/repo-reconciler/templates/consumer-task-protocol.md" "$co/.github/ISSUE_TEMPLATE/task.md" || fail "unwrapped task was written during conflict"

CASE="duplicate-markers-fail-closed"
co="$TMP/markers"
mkdir -p "$co"
{
  printf '%s\n' "$PS_START"
  printf '%s\n' "$PS_START"
  printf 'STALE\n'
  printf '%s\n' "$PS_END"
} > "$co/AGENTS.md"
mkdir -p "$co/.github"
cp -- "$SRC/tools/repo-reconciler/templates/consumer-pr-protocol.md" "$co/.github/pull_request_template.md"
seal "$co" "$TMP/markers.before"
sync_source "$co" --write
assert_code 2
assert_line $'FILE\tconflict\tAGENTS.md'
assert_line $'SYNC\tconflict'
seal "$co" "$TMP/markers.after"
assert_unchanged "$TMP/markers.before" "$TMP/markers.after"

CASE="owned-exact"
write_source "$TMP/src-owned" '[{"path":"owned/exact.txt","payload":"payloads/owned.txt"}]'
OWN="$TMP/src-owned"
co="$TMP/owned"
mkdir -p "$co/owned"
install_exact "$OWN" "$co"
write_consumer "$co"
printf 'nope\n' > "$co/owned/exact.txt"
run_sync "$ERR" "$RECONCILE" protocol-sync --checkout "$co" --source "$OWN" --write
assert_code 0
cmp -s "$OWN/payloads/owned.txt" "$co/owned/exact.txt" || fail "owned file was not replaced exactly"
if grep -F -q "$PS_START" "$co/owned/exact.txt"; then
  fail "owned exact file was wrapped"
fi
cmp -s <(printf 'readme-consumer\n') "$co/README.md" || fail "owned sync changed README"
seal "$co" "$TMP/owned.once"
run_sync "$ERR" "$RECONCILE" protocol-sync --checkout "$co" --source "$OWN" --write
assert_code 0
assert_line $'FILE\tunchanged\towned/exact.txt'
assert_line $'SYNC\texact'
seal "$co" "$TMP/owned.twice"
assert_unchanged "$TMP/owned.once" "$TMP/owned.twice"

CASE="owned-exact-changed-after-plan-zero-write"
co="$TMP/owned-race"
mkdir -p "$co"
install_exact "$OWN" "$co"
printf '%s\nSTALE\n%s\n' "$PS_START" "$PS_END" > "$co/AGENTS.md"
mkdir -p "$co/owned"
printf 'planned owned bytes\n' > "$co/owned/exact.txt"
cp -- "$co/AGENTS.md" "$TMP/owned-race.agents.before"
plan_source "$TMP/owned-race-work" "$co" "$OWN"
grep -F $'owned_exact\towned/exact.txt\tchanged\t' "$PS_GUARDS" >/dev/null || fail "changed owned_exact guard was not recorded"
printf 'late owned bytes\n' > "$co/owned/exact.txt"
install_mutation_probe "$co" "$TMP/owned-race.writes"
set +e
ps_apply
apply_result=$?
set -e
clear_mutation_probe
[[ "$apply_result" == 2 && "$PS_CONFLICT" == 1 ]] || fail "changed owned_exact source was not a pre-write conflict"
[[ ! -s "$TMP/owned-race.writes" ]] || fail "pending write occurred before owned_exact conflict"
cmp -s "$TMP/owned-race.agents.before" "$co/AGENTS.md" || fail "AGENTS changed before owned_exact conflict"
cmp -s <(printf 'late owned bytes\n') "$co/owned/exact.txt" || fail "late owned_exact source was overwritten"

CASE="forbid-readme"
bad="$TMP/bad-src"
mkdir -p "$bad/tools/repo-reconciler" "$bad/payloads"
printf 'x\n' > "$bad/payloads/readme.txt"
jq -n --arg start "$PS_START" --arg end "$PS_END" '{
  schema_version: 3,
  baseline: "fixture-baseline",
  protocol_sync: {
    markers: {start: $start, end: $end},
    managed: [{path: "README.md", payload: "payloads/readme.txt"}],
    legacy: [],
    owned_exact: []
  }
}' > "$bad/tools/repo-reconciler/manifest.json"
co="$TMP/forbid"
mkdir -p "$co"
printf 'keep-readme\n' > "$co/README.md"
seal "$co" "$TMP/forbid.before"
run_sync "$ERR" "$RECONCILE" protocol-sync --checkout "$co" --source "$bad" --write
assert_code 3
assert_line $'SYNC\tunverified'
seal "$co" "$TMP/forbid.after"
assert_unchanged "$TMP/forbid.before" "$TMP/forbid.after"
cmp -s <(printf 'keep-readme\n') "$co/README.md" || fail "forbidden README write"

CASE="usage"
run_sync "$ERR" "$RECONCILE" protocol-sync
assert_code 64
run_sync "$ERR" "$RECONCILE" protocol-sync --checkout "$TMP/exact" --source "$SRC" --target-ref main
assert_code 64
run_sync "$ERR" "$RECONCILE" protocol-sync --nope
assert_code 64
run_sync "$ERR" "$RECONCILE" protocol-sync --checkout "$TMP/missing-dir" --source "$SRC"
assert_code 3
assert_line $'SYNC\tunverified'

install_gh() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/gh" <<'STUB'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "${PS_GH_LOG:?}"
if [[ "${PS_GH_FAIL_ALL:-}" == 1 ]]; then
  echo "gh failed" >&2
  exit 1
fi
args="$*"
if [[ "$args" == *"/commits/"* ]]; then
  if [[ -n "${PS_GH_RETURN:-}" ]]; then
    printf '%s\n' "$PS_GH_RETURN"
  else
    printf '%s\n' "${PS_GH_SHA:?}"
  fi
  exit 0
fi
if [[ "$args" == *"/contents/"* ]]; then
  if [[ "${PS_GH_FAIL_CONTENTS:-}" == 1 ]]; then
    echo "contents failed" >&2
    exit 1
  fi
  [[ "$args" == *"ref=${PS_GH_SHA}"* ]] || { echo "contents ref mismatch" >&2; exit 1; }
  token=""
  for part in $args; do
    case "$part" in
      */contents/*) token="$part" ;;
    esac
  done
  uri="${token#*/contents/}"
  path="${uri//%2F//}"
  file="${PS_GH_TREE:?}/$path"
  [[ -f "$file" ]] || { echo "missing fixture $path" >&2; exit 1; }
  content="$(base64 < "$file" | tr -d '\n')"
  printf '{"type":"file","content":"%s"}\n' "$content"
  exit 0
fi
echo "unexpected gh" >&2
exit 1
STUB
  chmod +x "$dir/gh"
}

SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
OTHER="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
install_gh "$TMP/ghbin"
export PS_GH_LOG="$TMP/gh.log"
export PS_GH_TREE="$SRC"
export PS_GH_SHA="$SHA"
unset PS_GH_RETURN PS_GH_FAIL_ALL PS_GH_FAIL_CONTENTS || true

CASE="source-does-not-call-gh"
: > "$PS_GH_LOG"
co="$TMP/no-gh"
mkdir -p "$co"
install_exact "$SRC" "$co"
run_sync "$ERR" env PATH="$TMP/ghbin:$PATH" PS_GH_FAIL_ALL=1 "$RECONCILE" protocol-sync --checkout "$co" --source "$SRC"
assert_code 0
[[ ! -s "$PS_GH_LOG" ]] || fail "source mode called gh: $(cat "$PS_GH_LOG")"

CASE="gh-fail"
co="$TMP/gh-fail"
mkdir -p "$co"
printf 'keep\n' > "$co/README.md"
seal "$co" "$TMP/gh-fail.before"
: > "$PS_GH_LOG"
run_sync "$ERR" env PATH="$TMP/ghbin:$PATH" PS_GH_FAIL_ALL=1 "$RECONCILE" protocol-sync \
  --checkout "$co" --target-ref latest --write
assert_code 3
assert_line $'SYNC\tunverified'
assert_line $'BASELINE\ttarget\tlatest\tunrecorded\t-'
[[ "$(grep -c '/contents/' "$PS_GH_LOG" || true)" == 0 ]] || fail "fetch followed a failed resolve"
seal "$co" "$TMP/gh-fail.after"
assert_unchanged "$TMP/gh-fail.before" "$TMP/gh-fail.after"

CASE="gh-contents-fail"
: > "$PS_GH_LOG"
run_sync "$ERR" env PATH="$TMP/ghbin:$PATH" PS_GH_FAIL_CONTENTS=1 "$RECONCILE" protocol-sync \
  --checkout "$co" --target-ref latest --write
assert_code 3
assert_line $'SYNC\tunverified'
[[ "$(grep -c '/commits/' "$PS_GH_LOG" || true)" == 1 ]] || fail "resolve count"
seal "$co" "$TMP/gh-fail.contents"
assert_unchanged "$TMP/gh-fail.before" "$TMP/gh-fail.contents"

CASE="sha-mismatch"
: > "$PS_GH_LOG"
run_sync "$ERR" env PATH="$TMP/ghbin:$PATH" PS_GH_RETURN="$OTHER" "$RECONCILE" protocol-sync \
  --checkout "$co" --target-ref "$SHA" --write
assert_code 3
assert_line $'SYNC\tunverified'
[[ "$(grep -c '/contents/' "$PS_GH_LOG" || true)" == 0 ]] || fail "mismatch still fetched files"
seal "$co" "$TMP/gh-fail.mismatch"
assert_unchanged "$TMP/gh-fail.before" "$TMP/gh-fail.mismatch"

CASE="latest-sha"
unset PS_GH_RETURN || true
co="$TMP/latest"
mkdir -p "$co"
write_consumer "$co"
seal "$co" "$TMP/latest.before"
: > "$PS_GH_LOG"
run_sync "$ERR" env PATH="$TMP/ghbin:$PATH" "$RECONCILE" protocol-sync --checkout "$co" --target-ref latest
assert_code 2
assert_line "$(printf 'BASELINE\ttarget\tlatest\t%s\tfixture-baseline' "$SHA")"
assert_line $'BASELINE\tcurrent\tabsent\tunrecorded\t-'
assert_line $'SYNC\tpending'
[[ "$(grep -c '/commits/' "$PS_GH_LOG" || true)" == 1 ]] || fail "latest resolved more than once"
grep -q 'commits/main' "$PS_GH_LOG" || fail "latest did not use canonical main"
if grep -q 'commits/latest' "$PS_GH_LOG"; then
  fail "latest was sent to GitHub as a branch"
fi
[[ "$(grep -c '/contents/' "$PS_GH_LOG" || true)" == 4 ]] || fail "payload fetch count $(grep -c '/contents/' "$PS_GH_LOG" || true)"
if grep -q 'ref=main' "$PS_GH_LOG"; then
  fail "file read used a moving ref"
fi
grep -q "ref=$SHA" "$PS_GH_LOG" || fail "file read did not use the resolved SHA"
seal "$co" "$TMP/latest.after"
assert_unchanged "$TMP/latest.before" "$TMP/latest.after"
: > "$PS_GH_LOG"
run_sync "$ERR" env PATH="$TMP/ghbin:$PATH" "$RECONCILE" protocol-sync --checkout "$co" --target-ref latest --write
assert_code 0
assert_line "$(printf 'BASELINE\tcurrent\texact\t%s\tfixture-baseline' "$SHA")"
assert_line "$(printf 'BASELINE\ttarget\tlatest\t%s\tfixture-baseline' "$SHA")"
wrap_file "$SRC/tools/repo-reconciler/templates/minimal-consumer-AGENTS.md" "$TMP/latest.agents"
cmp -s "$TMP/latest.agents" "$co/AGENTS.md" || fail "resolved snapshot bytes were not written"
cmp -s <(printf 'readme-consumer\n') "$co/README.md" || fail "latest sync changed README"
cmp -s <(printf 'workflow-consumer\n') "$co/.github/workflows/ci.yml" || fail "latest sync changed workflow"
[[ "$(grep -c '/commits/' "$PS_GH_LOG" || true)" == 1 ]] || fail "write resolved more than once"

CASE="default-ref"
co="$TMP/default-ref"
mkdir -p "$co"
: > "$PS_GH_LOG"
run_sync "$ERR" env PATH="$TMP/ghbin:$PATH" "$RECONCILE" protocol-sync --checkout "$co"
assert_code 2
assert_line "$(printf 'BASELINE\ttarget\tmain\t%s\tfixture-baseline' "$SHA")"
grep -q 'commits/main' "$PS_GH_LOG" || fail "default ref was not main"
[[ "$(grep -c '/commits/' "$PS_GH_LOG" || true)" == 1 ]] || fail "default ref resolved more than once"

CASE="explicit-sha"
co="$TMP/explicit"
mkdir -p "$co"
: > "$PS_GH_LOG"
run_sync "$ERR" env PATH="$TMP/ghbin:$PATH" "$RECONCILE" protocol-sync --checkout "$co" --target-ref "$SHA"
assert_code 2
assert_line "$(printf 'BASELINE\ttarget\t%s\t%s\tfixture-baseline' "$SHA" "$SHA")"
grep -q "commits/$SHA" "$PS_GH_LOG" || fail "explicit SHA was not resolved"
if grep -q 'commits/main' "$PS_GH_LOG"; then
  fail "explicit SHA fell back to main"
fi

CASE="short-ref"
co="$TMP/short"
mkdir -p "$co"
seal "$co" "$TMP/short.before"
: > "$PS_GH_LOG"
run_sync "$ERR" env PATH="$TMP/ghbin:$PATH" "$RECONCILE" protocol-sync --checkout "$co" --target-ref abcdef --write
assert_code 3
assert_line $'SYNC\tunverified'
[[ ! -s "$PS_GH_LOG" ]] || fail "short ref called gh"
seal "$co" "$TMP/short.after"
assert_unchanged "$TMP/short.before" "$TMP/short.after"

CASE="no-model"
if grep -Eiq 'fuzzy|similarity|openai|anthropic|embedding|llm' "$LIB" "$RECONCILE"; then
  fail "sync path contains a model or fuzzy decision"
fi
if grep -Eq 'GH_TOKEN=|GITHUB_TOKEN=|Authorization: *Bearer|role-exec|jwt_sign|installation_token_cache' "$LIB"; then
  fail "sync path contains credential handling"
fi

echo "protocol-sync self-test: PASS"
