#!/usr/bin/env bash
# Permanent protocol-sync coverage. Fixtures only; no live GitHub writes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
RECONCILE="$ROOT/tools/repo-reconciler/reconcile.sh"
LIB="$ROOT/tools/repo-reconciler/lib/protocol-sync.sh"
# shellcheck source=../lib/protocol-sync.sh
source "$LIB"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CASE=""
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
  local dir="$1"
  mkdir -p "$dir/tools/repo-reconciler/templates" "$dir/.github/ISSUE_TEMPLATE"
  cp "$ROOT/tools/repo-reconciler/manifest.json" "$dir/tools/repo-reconciler/manifest.json"
  # Exercise the real canonical files, not a second ownership fixture schema.
  jq '.governance_lineage = "fixture-lineage"' "$dir/tools/repo-reconciler/manifest.json" > "$dir/manifest.next"
  mv "$dir/manifest.next" "$dir/tools/repo-reconciler/manifest.json"
  cp "$ROOT/tools/repo-reconciler/templates/minimal-consumer-AGENTS.md" "$dir/tools/repo-reconciler/templates/"
  cp "$ROOT/.github/ISSUE_TEMPLATE/task.md" "$dir/.github/ISSUE_TEMPLATE/"
  cp "$ROOT/.github/pull_request_template.md" "$dir/.github/"
}
install_exact() {
  mkdir -p "$2/.github/ISSUE_TEMPLATE"
  cp "$1/tools/repo-reconciler/templates/minimal-consumer-AGENTS.md" "$2/AGENTS.md"
  cp "$1/.github/ISSUE_TEMPLATE/task.md" "$2/.github/ISSUE_TEMPLATE/task.md"
  cp "$1/.github/pull_request_template.md" "$2/.github/pull_request_template.md"
}
write_consumer() {
  printf 'readme-consumer\n' > "$1/README.md"
  mkdir -p "$1/.github/workflows"
  printf 'workflow-consumer\n' > "$1/.github/workflows/ci.yml"
  printf 'business bytes\000without newline' > "$1/business.txt"
}
sync_source() {
  local dest="$1"; shift
  run_sync "$ERR" "$RECONCILE" protocol-sync --checkout "$dest" --source "$SRC" "$@"
}
plan_source() {
  PS_WORK="$1" PS_CHECKOUT="$2" PS_SOURCE="$SRC" PS_REF=source PS_SHA=local
  mkdir -p "$PS_WORK/staged"
  PS_ROWS="$PS_WORK/rows" PS_WRITES="$PS_WORK/writes"
  ps_plan
}
write_source "$TMP/src"
SRC="$TMP/src"
VERSION="$(sed -n '2s/^G-lite Protocol-Version: //p' "$SRC/tools/repo-reconciler/templates/minimal-consumer-AGENTS.md")"

CASE=initialize-prepend-exact-restore-idempotent
co="$TMP/consumer"; mkdir -p "$co/.github/ISSUE_TEMPLATE"
write_consumer "$co"
printf 'consumer\r\n\000binary\377no-final-newline' > "$TMP/remainder"
cp "$TMP/remainder" "$co/AGENTS.md"
printf 'custom task drift' > "$co/.github/ISSUE_TEMPLATE/task.md"
printf 'custom PR drift' > "$co/.github/pull_request_template.md"
printf 'old consumer template' > "$co/.github/ISSUE_TEMPLATE/contract.md"
seal "$co" "$TMP/before"
sync_source "$co"; assert_code 2; assert_line $'SYNC\tpending'
seal "$co" "$TMP/after"; assert_unchanged "$TMP/before" "$TMP/after"
sync_source "$co" --write; assert_code 0
{ cat "$SRC/tools/repo-reconciler/templates/minimal-consumer-AGENTS.md"; printf '\n'; cat "$TMP/remainder"; } > "$TMP/expect"
cmp "$TMP/expect" "$co/AGENTS.md" || fail 'prepend bytes'
cmp "$SRC/.github/ISSUE_TEMPLATE/task.md" "$co/.github/ISSUE_TEMPLATE/task.md" || fail 'task exact'
cmp "$SRC/.github/pull_request_template.md" "$co/.github/pull_request_template.md" || fail 'PR exact'
[[ "$(cat "$co/.github/ISSUE_TEMPLATE/contract.md")" == 'old consumer template' ]] || fail 'legacy alias touched'
cmp "$co/README.md" <(printf 'readme-consumer\n') || fail README
cmp "$co/.github/workflows/ci.yml" <(printf 'workflow-consumer\n') || fail workflow
cmp "$co/business.txt" <(printf 'business bytes\000without newline') || fail business
seal "$co" "$TMP/once"
sync_source "$co" --write; assert_code 0; assert_line $'FILE\tunchanged\tAGENTS.md'
seal "$co" "$TMP/twice"; assert_unchanged "$TMP/once" "$TMP/twice"

CASE=replace-old-prefix-preserve-remainder-mode
{ printf '%s\nold v1\n%s\n' "$PS_START" "$PS_END"; cat "$TMP/remainder"; } > "$co/AGENTS.md"
chmod 640 "$co/AGENTS.md"
sync_source "$co" --write; assert_code 0
{ cat "$SRC/tools/repo-reconciler/templates/minimal-consumer-AGENTS.md"; cat "$TMP/remainder"; } > "$TMP/expect"
cmp "$TMP/expect" "$co/AGENTS.md" || fail 'remainder changed'
# Portable mode inspection.
[[ "$(ls -l "$co/AGENTS.md" | cut -c1-10)" == '-rw-r-----' ]] || fail 'mode changed'

CASE=large-remainder
{ printf '%s\nold\n%s\n' "$PS_START" "$PS_END"; head -c 1048576 /dev/zero; } > "$co/AGENTS.md"
sync_source "$co" --write; assert_code 0
{ cat "$SRC/tools/repo-reconciler/templates/minimal-consumer-AGENTS.md"; head -c 1048576 /dev/zero; } > "$TMP/expect"
cmp "$TMP/expect" "$co/AGENTS.md" || fail 'large remainder'

CASE=malformed-zero-write
for content in \
  "$PS_START" \
  "$PS_END" \
  "$(printf 'prefix\n%s\nold\n%s\n' "$PS_START" "$PS_END")" \
  "$(printf '%s\n%s\nold\n%s\n' "$PS_START" "$PS_START" "$PS_END")" \
  "$(printf '%s\nold\n%s\n' "$PS_END" "$PS_START")" \
  "inline $PS_START" \
  '<!-- g-lite:managed protocol star -->' \
  "$(printf '%s\r\nold\r\n%s\r' "$PS_START" "$PS_END")"; do
  printf '%s\n' "$content" > "$co/AGENTS.md"
  printf drift > "$co/.github/ISSUE_TEMPLATE/task.md"
  seal "$co" "$TMP/before"
  sync_source "$co" --write; assert_code 2; assert_line $'SYNC\tconflict'
  seal "$co" "$TMP/after"; assert_unchanged "$TMP/before" "$TMP/after"
done
printf '%s\nold\n%s' "$PS_START" "$PS_END" > "$co/AGENTS.md"
sync_source "$co" --write; assert_code 2

CASE=unsafe-targets
for kind in symlink-parent file-parent symlink-file directory-file fifo-file; do
  co="$TMP/$kind"; mkdir -p "$co" "$TMP/outside"
  case "$kind" in
    symlink-parent) ln -s "$TMP/outside" "$co/.github" ;;
    file-parent) printf keep > "$co/.github" ;;
    symlink-file) ln -s "$TMP/outside/file" "$co/AGENTS.md" ;;
    directory-file) mkdir "$co/AGENTS.md" ;;
    fifo-file) mkfifo "$co/AGENTS.md" ;;
  esac
  seal "$co" "$TMP/before"
  sync_source "$co" --write; assert_code 2; assert_line $'SYNC\tconflict'
  seal "$co" "$TMP/after"; assert_unchanged "$TMP/before" "$TMP/after"
  [[ -z "$(ls -A "$TMP/outside")" ]] || fail 'escaped checkout'
done

CASE=changed-unchanged-absent-guards
for state in changed unchanged absent; do
  co="$TMP/race-$state"; mkdir -p "$co"; install_exact "$SRC" "$co"
  printf '%s\nold\n%s\n' "$PS_START" "$PS_END" > "$co/AGENTS.md"
  case "$state" in
    changed) printf drift > "$co/.github/ISSUE_TEMPLATE/task.md" ;;
    absent) rm "$co/.github/ISSUE_TEMPLATE/task.md" ;;
  esac
  plan_source "$TMP/plan-$state" "$co"
  printf 'late edit' > "$co/.github/ISSUE_TEMPLATE/task.md"
  seal "$co" "$TMP/before"
  run_sync "$ERR" ps_apply; assert_code 2
  seal "$co" "$TMP/after"; assert_unchanged "$TMP/before" "$TMP/after"
done

CASE=atomic-replacement-and-write-failure-rollback
co="$TMP/rollback"; mkdir -p "$co"; install_exact "$SRC" "$co"
printf task-drift > "$co/.github/ISSUE_TEMPLATE/task.md"
printf pr-drift > "$co/.github/pull_request_template.md"
# A hard link retains the old inode: rename must not truncate it.
ln "$co/.github/ISSUE_TEMPLATE/task.md" "$TMP/old-inode"
plan_source "$TMP/plan-rollback" "$co"
seal "$co" "$TMP/before"
mv() {
  local arg last=''
  for arg; do last="$arg"; done
  [[ "$last" != "$co/.github/pull_request_template.md" ]] || return 1
  command mv "$@"
}
run_sync "$ERR" ps_apply; unset -f mv; assert_code 1
seal "$co" "$TMP/after"; assert_unchanged "$TMP/before" "$TMP/after"
[[ "$(cat "$TMP/old-inode")" == task-drift ]] || fail 'old inode truncated'
sync_source "$co" --write; assert_code 0
[[ "$(cat "$TMP/old-inode")" == task-drift ]] || fail 'not an atomic rename'

CASE=snapshot-fail-closed
for kind in manifest prefix symlink-parent symlink-file; do
  src="$TMP/bad-$kind"; write_source "$src"
  case "$kind" in
    manifest) jq '.protocol_sync.owned_exact[0].path="README.md"' "$src/tools/repo-reconciler/manifest.json" > "$src/next"; mv "$src/next" "$src/tools/repo-reconciler/manifest.json" ;;
    prefix) printf bad > "$src/tools/repo-reconciler/templates/minimal-consumer-AGENTS.md" ;;
    symlink-parent) mv "$src/.github" "$src/elsewhere"; ln -s elsewhere "$src/.github" ;;
    symlink-file) rm "$src/.github/pull_request_template.md"; ln -s "$SRC/.github/pull_request_template.md" "$src/.github/pull_request_template.md" ;;
  esac
  seal "$co" "$TMP/before"
  run_sync "$ERR" "$RECONCILE" protocol-sync --checkout "$co" --source "$src" --write
  assert_code 3; assert_line $'SYNC\tunverified'
  seal "$co" "$TMP/after"; assert_unchanged "$TMP/before" "$TMP/after"
done

# All cases use this same engine and prove preflight rejection leaves every
# target byte/path unchanged, even with earlier exact-template drift pending.
CASE=payload-version-independent
for version in v0.0.0 v3.7.4 v3.8.0 v12.34.567; do
  src="$TMP/version-$version"; write_source "$src"
  payload="$src/tools/repo-reconciler/templates/minimal-consumer-AGENTS.md"
  sed "2s/.*/G-lite Protocol-Version: $version/" "$payload" > "$src/next"
  mv "$src/next" "$payload"
  run_sync "$ERR" "$RECONCILE" protocol-sync --checkout "$co" --source "$src" --write
  assert_code 0
  assert_line "$(printf 'PROTOCOL\ttarget\tsource\tlocal\t%s' "$version")"
  assert_line $'GOVERNANCE_LINEAGE\ttarget\tfixture-lineage'
  cmp "$payload" "$co/AGENTS.md" || fail 'snapshot version not used'
  seal "$co" "$TMP/once"
  run_sync "$ERR" "$RECONCILE" protocol-sync --checkout "$co" --source "$src" --write
  assert_code 0
  seal "$co" "$TMP/twice"; assert_unchanged "$TMP/once" "$TMP/twice"
done

CASE=invalid-version-zero-write
for kind in missing invalid duplicate misplaced leading-zero suffix inline-duplicate nul crlf; do
  src="$TMP/version-$kind"; write_source "$src"
  payload="$src/tools/repo-reconciler/templates/minimal-consumer-AGENTS.md"
  case "$kind" in
    nul|crlf)
      { head -n 1 "$payload"
        if [[ "$kind" == nul ]]; then printf 'G-lite Protocol-Version: v3.7.4\000\n'
        else printf 'G-lite Protocol-Version: v3.7.4\r\n'; fi
        tail -n +3 "$payload"
      } > "$src/next" ;;
    missing) sed '2d' "$payload" > "$src/next" ;;
    invalid) sed '2s/.*/G-lite Protocol-Version: latest/' "$payload" > "$src/next" ;;
    duplicate) sed '2p' "$payload" > "$src/next" ;;
    misplaced) sed '2i\

' "$payload" > "$src/next" ;;
    leading-zero) sed '2s/.*/G-lite Protocol-Version: v03.7.4/' "$payload" > "$src/next" ;;
    suffix) sed '2s/.*/G-lite Protocol-Version: v3.7.4-rc.1/' "$payload" > "$src/next" ;;
    inline-duplicate) sed '3s/.*/also G-lite Protocol-Version: v1.2.3/' "$payload" > "$src/next" ;;
  esac
  mv "$src/next" "$payload"
  printf drift > "$co/.github/ISSUE_TEMPLATE/task.md"
  seal "$co" "$TMP/before"
  run_sync "$ERR" "$RECONCILE" protocol-sync --checkout "$co" --source "$src" --write
  assert_code 3; assert_line $'SYNC\tunverified'
  seal "$co" "$TMP/after"; assert_unchanged "$TMP/before" "$TMP/after"
done

CASE=manifest-lineage-boundary
for kind in old-schema unknown-schema ambiguous-field missing-lineage invalid-lineage; do
  src="$TMP/lineage-$kind"; write_source "$src"
  manifest="$src/tools/repo-reconciler/manifest.json"
  case "$kind" in
    old-schema) filter='.schema_version=3 | .baseline=.governance_lineage | del(.governance_lineage)' ;;
    unknown-schema) filter='.schema_version=999' ;;
    ambiguous-field) filter='.baseline="legacy"' ;;
    missing-lineage) filter='del(.governance_lineage)' ;;
    invalid-lineage) filter='.governance_lineage=""' ;;
  esac
  jq "$filter" "$manifest" > "$src/next"; mv "$src/next" "$manifest"
  seal "$co" "$TMP/before"
  run_sync "$ERR" "$RECONCILE" protocol-sync --checkout "$co" --source "$src" --write
  assert_code 3; assert_line $'SYNC\tunverified'
  seal "$co" "$TMP/after"; assert_unchanged "$TMP/before" "$TMP/after"
done

CASE=usage
run_sync "$ERR" "$RECONCILE" protocol-sync; assert_code 64
run_sync "$ERR" "$RECONCILE" protocol-sync --checkout "$co" --source "$SRC" --target-ref main; assert_code 64
run_sync "$ERR" "$RECONCILE" protocol-sync --nope; assert_code 64
run_sync "$ERR" "$RECONCILE" protocol-sync --checkout "$TMP/missing" --source "$SRC"; assert_code 3

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
assert_line $'PROTOCOL\ttarget\tlatest\tunrecorded\t-'
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
assert_line "$(printf 'PROTOCOL\ttarget\tlatest\t%s\t%s' "$SHA" "$VERSION")"
assert_line $'PROTOCOL\tcurrent\tabsent\tunrecorded\t-'
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
assert_line "$(printf 'PROTOCOL\tcurrent\texact\t%s\t%s' "$SHA" "$VERSION")"
assert_line "$(printf 'PROTOCOL\ttarget\tlatest\t%s\t%s' "$SHA" "$VERSION")"
cp "$SRC/tools/repo-reconciler/templates/minimal-consumer-AGENTS.md" "$TMP/latest.agents"
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
assert_line "$(printf 'PROTOCOL\ttarget\tmain\t%s\t%s' "$SHA" "$VERSION")"
grep -q 'commits/main' "$PS_GH_LOG" || fail "default ref was not main"
[[ "$(grep -c '/commits/' "$PS_GH_LOG" || true)" == 1 ]] || fail "default ref resolved more than once"

CASE="explicit-sha"
co="$TMP/explicit"
mkdir -p "$co"
: > "$PS_GH_LOG"
run_sync "$ERR" env PATH="$TMP/ghbin:$PATH" "$RECONCILE" protocol-sync --checkout "$co" --target-ref "$SHA"
assert_code 2
assert_line "$(printf 'PROTOCOL\ttarget\t%s\t%s\t%s' "$SHA" "$SHA" "$VERSION")"
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
