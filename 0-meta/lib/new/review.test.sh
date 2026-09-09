#!/usr/bin/env bash
# Issue #29 定向测试：结构化 Review / actor provenance / validator / self-review gate。
# 不调用真实 gh、orca 或外部 CI。
set -Eeuo pipefail
export LC_COLLATE=C
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/0-meta/lib/new/core.sh"
# shellcheck source=/dev/null
. "$ROOT/0-meta/lib/new/task.sh"
# shellcheck source=/dev/null
. "$ROOT/0-meta/lib/new/contract.sh"
# shellcheck source=/dev/null
. "$ROOT/0-meta/lib/new/review.sh"
# shellcheck source=/dev/null
. "$ROOT/.agents/skills/z-lib.sh"
trap tmp_cleanup EXIT

fail=0
pass=0
TDIR=""
tmp_mkd TDIR review-test
CONTRACT="$TDIR/contract.json"

jq -n '
  {
    schema_version:"task-contract/v1",
    requirements:[
      {id:"R1",text:"结构化输入"},
      {id:"R2",text:"完整性"}
    ],
    acceptances:[
      {id:"A1",text:"parser",requires:["R1"],applicable_when:null,validators:["contract-test"]},
      {id:"A2",text:"validator",requires:["R2"],applicable_when:null,validators:["contract-test"]},
      {id:"A3",text:"self review",requires:["R1"],applicable_when:null,validators:["bash-syntax"]}
    ],
    scope:["0-meta/lib/new"]
  }
' > "$CONTRACT"
BLOB=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
HEAD=0123456789012345678901234567890123456789

ok() { pass=$((pass + 1)); }
bad() { printf '✗ %s\n' "$*" >&2; fail=$((fail + 1)); }

expect_ok() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then ok; else bad "$name"; fi
}

expect_fail() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then bad "$name（应失败）"; else ok; fi
}

make_input() {
  local file="$1"
  {
    printf '%s\n' \
      'verdict: 通过' \
      'title: feat(meta): review test' \
      'notes: notes mention R1 and ordinary prose' \
      'R1: 满足 | parser evidence mentions R1 as prose' \
      'R2: 满足 | completeness evidence'
    printf '%s\n' \
      'A1: 通过 | parser evidence' \
      'A2: 通过 | validator evidence' \
      'A3: 通过 | actor evidence'
  } > "$file"
}

INPUT="$TDIR/good.input"
PARSED="$TDIR/good.json"
make_input "$INPUT"
expect_ok 'A1 完整结构化输入' review_parse_structured_input "$INPUT" "$CONTRACT" "$PARSED"
expect_ok 'A3 prose 中的 R1 不增加 ID' test "$(jq '.requirements|length' "$PARSED")" = 2
expect_ok 'A3 prose 中的 A1 不增加 ID' test "$(jq '.acceptances|length' "$PARSED")" = 3

missing_verdict="$TDIR/missing-verdict.input"
grep -v '^verdict' "$INPUT" > "$missing_verdict"
expect_fail 'A1 缺 verdict' review_parse_structured_input "$missing_verdict" "$CONTRACT" "$TDIR/missing-verdict.json"

missing_title="$TDIR/missing-title.input"
grep -v '^title' "$INPUT" > "$missing_title"
expect_fail 'A1 缺 title' review_parse_structured_input "$missing_title" "$CONTRACT" "$TDIR/missing-title.json"

invalid_line="$TDIR/invalid-line.input"
{ sed -n '1,3p' "$INPUT"; printf '%s\n' '这不是结构化 Review 行'; sed -n '4,$p' "$INPUT"; } > "$invalid_line"
invalid_err="$TDIR/invalid-line.err"
if review_parse_structured_input "$invalid_line" "$CONTRACT" "$TDIR/invalid-line.json" > /dev/null 2> "$invalid_err"; then
  bad 'A1 非法行应拒绝'
else
  grep -Fq '第 4 行' "$invalid_err" && ok || bad 'A1 非法行指出准确行号'
fi

missing_a="$TDIR/missing-a.input"
grep -v '^A3:' "$INPUT" > "$missing_a"
expect_fail 'A2 缺 A' review_parse_structured_input "$missing_a" "$CONTRACT" "$TDIR/missing-a.json"

unknown_r="$TDIR/unknown-r.input"
{ cat "$INPUT"; printf '%s\n' 'R9: 满足 | unknown'; } > "$unknown_r"
expect_fail 'A2 未知 R' review_parse_structured_input "$unknown_r" "$CONTRACT" "$TDIR/unknown-r.json"

unknown_a="$TDIR/unknown-a.input"
{ cat "$INPUT"; printf '%s\n' 'A9: 通过 | unknown'; } > "$unknown_a"
expect_fail 'A2 未知 A' review_parse_structured_input "$unknown_a" "$CONTRACT" "$TDIR/unknown-a.json"

duplicate_r="$TDIR/duplicate-r.input"
{ cat "$INPUT"; printf '%s\n' 'R1: 满足 | duplicate'; } > "$duplicate_r"
expect_fail 'A2 重复 R' review_parse_structured_input "$duplicate_r" "$CONTRACT" "$TDIR/duplicate-r.json"

empty_evidence="$TDIR/empty-evidence.input"
sed 's/^A1: 通过 |.*/A1: 通过 |/' "$INPUT" > "$empty_evidence"
expect_fail 'A2 空证据' review_parse_structured_input "$empty_evidence" "$CONTRACT" "$TDIR/empty-evidence.json"

status_only="$TDIR/status-only.input"
sed 's/^A1: 通过 |.*/A1: 通过 | 通过/' "$INPUT" > "$status_only"
expect_fail 'A2 纯状态词证据' review_parse_structured_input "$status_only" "$CONTRACT" "$TDIR/status-only.json"

unknown_validator="$TDIR/unknown-validator.json"
jq '.acceptances[0].validators=["not-registered"]' "$CONTRACT" > "$unknown_validator"
expect_fail 'A6 未知 validator' validator_contract_validate "$unknown_validator"

command_contract="$TDIR/command-contract.json"
jq '.command="echo unsafe"' "$CONTRACT" > "$command_contract"
expect_fail 'A6 Contract 命令字段' validator_contract_validate "$command_contract"

null_validator="$TDIR/null-validator.json"
jq '.acceptances[0].validators=null' "$CONTRACT" > "$null_validator"
expect_fail 'A6 validators 非数组' validator_contract_validate "$null_validator"

WTDIR="$TDIR/wt"
mkdir -p "$WTDIR"
git -C "$WTDIR" init -q -b main
git -C "$WTDIR" config user.email git@example.test
expect_ok 'A4 git email fallback' test "$(task_actor_resolve '' "$WTDIR" 0)" = git@example.test
NEW_TASK_ACTOR=env@example.test expect_ok 'A4 env 覆盖 email' test "$(NEW_TASK_ACTOR=env@example.test task_actor_resolve '' "$WTDIR" 0)" = env@example.test
expect_ok 'A4 explicit 覆盖 env' test "$(NEW_TASK_ACTOR=env@example.test task_actor_resolve explicit@example.test "$WTDIR" 1)" = explicit@example.test
git -C "$WTDIR" config --unset-all user.email || true
empty_actor() {
  GIT_CONFIG_GLOBAL="$TDIR/empty-global" GIT_CONFIG_SYSTEM=/dev/null \
    NEW_TASK_ACTOR= task_actor_resolve '' "$WTDIR" 0
}
: > "$TDIR/empty-global"
expect_fail 'A4 全空 fail-closed' empty_actor

owner=o
repo=r
number=29
git_br=meta/review-test-29
logical_br=meta/review-test-29
wt="$WTDIR"
TASK_CLAIM_ACTOR=claim@example.test
lock_sha="$(task_claim_make_lock "$WTDIR" 29 "$git_br")"
lock_message="$(git -C "$WTDIR" cat-file -p "$lock_sha")"
grep -Fq 'claim_actor: claim@example.test' <<< "$lock_message" \
  && ok || bad 'A4 claim lock 写 claim_actor'
contract_json="$CONTRACT"
contract_blob="$BLOB"
head="$HEAD"
ws_status=干净
scope='0-meta/lib/new/'
evidence=''
agent=''
agent_bin=''
TASK_CLAIM_LAUNCH=0
checkpoint_capture="$TDIR/claim-checkpoint.md"
task_write_checkpoint() { printf '%s' "$4" > "$checkpoint_capture"; }
checkpoint_rc=0
task_claim_write_checkpoint || checkpoint_rc=$?
expect_ok 'A4 Checkpoint 写 claim_actor' test "$checkpoint_rc" = 0
expect_ok 'A4 Checkpoint machine field 唯一' test "$(grep -c '^claim_actor=' "$checkpoint_capture")" = 1
expect_ok 'A4 Checkpoint 表格 actor' grep -Fq '| claim_actor | `claim@example.test` |' "$checkpoint_capture"
unset -f task_write_checkpoint

expect_fail 'A4 alpha→alpha 默认拒绝' review_actor_policy alpha alpha 0 1
expect_ok 'A4 alpha→beta 独立通过' test "$(review_actor_policy beta alpha 0 0)" = no
expect_ok 'A4 allow-self 返回 yes' test "$(review_actor_policy alpha alpha 1 1)" = yes
expect_fail 'A4 allow-self 无 human-merge 拒绝' review_actor_policy alpha alpha 1 0

EFFECTIVE="$TDIR/effective.json"
RESULTS="$TDIR/results.json"
printf '%s\n' '[]' > "$RESULTS"
review_apply_validator_results "$PARSED" "$RESULTS" "$EFFECTIVE"
Z_HEAD="$HEAD"
Z_OWNER=o
Z_REPO=r
Z_NUMBER=29
Z_CONTRACT_BLOB="$BLOB"
RENDERED="$TDIR/rendered.md"
review_render "$EFFECTIVE" "$RESULTS" "$RENDERED" beta alpha no $'0-meta/lib/new/review.sh\n0-meta/lib/new/task.sh'
expect_ok 'A1 工具渲染可被 Review validator 接受' contract_review_validate "$(cat "$RENDERED")" "$CONTRACT" "$BLOB" "$HEAD"
grep -Fq 'review_actor=beta' "$RENDERED" && ok || bad 'A4 Review 写 review_actor'
grep -Fq 'Self-review=no' "$RENDERED" && ok || bad 'A4 独立 Review 写 Self-review=no'

SUCCESS_RESULTS="$TDIR/success-results.json"
jq -n '[{acceptance:"A1",validator:"contract-test",exit_code:0,output:"validator success output"}]' > "$SUCCESS_RESULTS"
SUCCESS_EFFECTIVE="$TDIR/success-effective.json"
review_apply_validator_results "$PARSED" "$SUCCESS_RESULTS" "$SUCCESS_EFFECTIVE"
expect_ok 'A1 reviewer 通过 + validator success 仍通过' test "$(jq -r '.acceptances[] | select(.id == "A1") | .status' "$SUCCESS_EFFECTIVE")" = 通过
expect_ok 'A3 validator success 不改变总 Verdict' test "$(jq -r '.verdict' "$SUCCESS_EFFECTIVE")" = 通过
SUCCESS_RENDER="$TDIR/success-rendered.md"
review_render "$SUCCESS_EFFECTIVE" "$SUCCESS_RESULTS" "$SUCCESS_RENDER" beta alpha no $'0-meta/lib/new/review.sh\n0-meta/lib/new/task.sh'
grep -Fq 'validator:contract-test / exit_code=0' "$SUCCESS_RENDER" && ok || bad 'A4 Review 渲染 validator exit code'
grep -Fq 'output: validator success output' "$SUCCESS_RENDER" && ok || bad 'A4 Review 渲染 validator 输出'

MANUAL_FAILED_PARSED="$TDIR/manual-failed-parsed.json"
jq '(.acceptances[] | select(.id == "A1") | .status) = "不通过" |
    (.acceptances[] | select(.id == "A1") | .evidence) = "reviewer semantic failure"' \
  "$PARSED" > "$MANUAL_FAILED_PARSED"
MANUAL_FAILED_EFFECTIVE="$TDIR/manual-failed-effective.json"
review_apply_validator_results "$MANUAL_FAILED_PARSED" "$SUCCESS_RESULTS" "$MANUAL_FAILED_EFFECTIVE"
expect_ok 'A1 reviewer 不通过 + validator success 仍不通过' test "$(jq -r '.acceptances[] | select(.id == "A1") | .status' "$MANUAL_FAILED_EFFECTIVE")" = 不通过
expect_ok 'A2 人工失败保持总 Verdict 不通过' test "$(jq -r '.verdict' "$MANUAL_FAILED_EFFECTIVE")" = 不通过
expect_ok 'A2 人工失败清空 Squash-Title' test "$(jq -r '.title' "$MANUAL_FAILED_EFFECTIVE")" = '（无）'
grep -Fq 'validator:contract-test exit_code=0' "$MANUAL_FAILED_EFFECTIVE" && ok || bad 'A6 validator success 仍追加 evidence'

for forbidden in '实际审查' '逐项核对' 'Skill adapter' 'zmerge 读取门禁'; do
  if grep -Fq "$forbidden" "$SUCCESS_RENDER"; then
    bad "A4 Review 不生成不可证明声明：$forbidden"
  else
    ok
  fi
done

SELF_RENDER="$TDIR/self-rendered.md"
review_render "$EFFECTIVE" "$RESULTS" "$SELF_RENDER" alpha alpha yes $'0-meta/lib/new/review.sh'
grep -Fq 'Self-review=yes' "$SELF_RENDER" && ok || bad 'A4 allow-self 写 Self-review=yes'
expect_ok 'A4 Self-review Review 结构有效' contract_review_validate "$(cat "$SELF_RENDER")" "$CONTRACT" "$BLOB" "$HEAD"

manual_bad_status="$TDIR/manual-bad-status.md"
sed 's/^- A1：通过。/- A1：其它。/' "$RENDERED" > "$manual_bad_status"
expect_fail 'R2 消费侧非法 A 状态' contract_review_validate "$(cat "$manual_bad_status")" "$CONTRACT" "$BLOB" "$HEAD"

machine_mismatch="$TDIR/machine-mismatch.md"
sed 's/^review_actor=beta$/review_actor=gamma/' "$RENDERED" > "$machine_mismatch"
expect_fail 'R3 actor machine field 与表格不一致' contract_review_validate "$(cat "$machine_mismatch")" "$CONTRACT" "$BLOB" "$HEAD"

same_actor_no="$TDIR/same-actor-no.md"
sed -e 's/^Self-review=yes$/Self-review=no/' \
  -e 's/| Self-review | yes |/| Self-review | no |/' \
  "$SELF_RENDER" > "$same_actor_no"
expect_fail 'A4 alpha/alpha/no 拒绝' contract_review_validate "$(cat "$same_actor_no")" "$CONTRACT" "$BLOB" "$HEAD"

different_actor_yes="$TDIR/different-actor-yes.md"
sed -e 's/^claim_actor=alpha$/claim_actor=beta/' \
  -e 's/| claim_actor | `alpha` |/| claim_actor | `beta` |/' \
  "$SELF_RENDER" > "$different_actor_yes"
expect_fail 'A4 alpha/beta/yes 拒绝' contract_review_validate "$(cat "$different_actor_yes")" "$CONTRACT" "$BLOB" "$HEAD"

missing_claim_actor="$TDIR/missing-claim-actor.md"
grep -v '^claim_actor=' "$SELF_RENDER" > "$missing_claim_actor"
expect_fail 'A4 缺 claim_actor machine field' contract_review_validate "$(cat "$missing_claim_actor")" "$CONTRACT" "$BLOB" "$HEAD"

duplicate_claim_actor="$TDIR/duplicate-claim-actor.md"
{ cat "$SELF_RENDER"; printf '%s\n' 'claim_actor=alpha'; } > "$duplicate_claim_actor"
expect_fail 'A4 重复 claim_actor machine field' contract_review_validate "$(cat "$duplicate_claim_actor")" "$CONTRACT" "$BLOB" "$HEAD"

claim_table_mismatch="$TDIR/claim-table-mismatch.md"
sed 's/| claim_actor | `alpha` |/| claim_actor | `beta` |/' \
  "$SELF_RENDER" > "$claim_table_mismatch"
expect_fail 'A4 claim_actor 表格与 machine field 不一致' contract_review_validate "$(cat "$claim_table_mismatch")" "$CONTRACT" "$BLOB" "$HEAD"

VALIDATOR_CALLS="$TDIR/validator-calls"
: > "$VALIDATOR_CALLS"
validator_run() {
  printf '%s\n' "$1" >> "$VALIDATOR_CALLS"
  printf '%s\n' 'validator failure output'
  return 17
}
Z_WT="$ROOT"
Z_SCOPE='0-meta/lib/new'
FAILED_RESULTS="$TDIR/failed-results.json"
FAILED_EFFECTIVE="$TDIR/failed-effective.json"
review_run_validators "$PARSED" "$FAILED_RESULTS"
review_apply_validator_results "$PARSED" "$FAILED_RESULTS" "$FAILED_EFFECTIVE"
expect_ok 'A6 validator exit code 已记录' test "$(jq -r '.[0].exit_code' "$FAILED_RESULTS")" = 17
expect_ok 'A6 validator 结果覆盖 A' test "$(jq -r '.acceptances[1].status' "$FAILED_EFFECTIVE")" = 不通过
expect_ok 'A6 validator failed 阻止 Verdict' test "$(jq -r '.verdict' "$FAILED_EFFECTIVE")" = 不通过
grep -Fq 'validator:contract-test exit_code=17' "$FAILED_EFFECTIVE" && ok || bad 'A6 A 机器证据含 validator id/exit code'
expect_ok 'A6 contract-test 每轮只执行一次' test "$(awk '$1=="contract-test" {n++} END{print n+0}' "$VALIDATOR_CALLS")" = 1
expect_ok 'A6 bash-syntax 每轮只执行一次' test "$(awk '$1=="bash-syntax" {n++} END{print n+0}' "$VALIDATOR_CALLS")" = 1
expect_ok 'A6 validator 结果按 A 展开' test "$(jq 'length' "$FAILED_RESULTS")" = 3

SELF_OUT="$TDIR/self.err"
set +e
( Z_SELF_REVIEW=yes; z_require_auto_merge_safe_review ) > /dev/null 2> "$SELF_OUT"
self_rc=$?
set -e
expect_ok 'A5 zmerge 拒绝 self-review' test "$self_rc" = 1
grep -Fq 'z.self_review_forbidden' "$SELF_OUT" && ok || bad 'A5 self-review reason code 稳定非空'
expect_ok 'A5 zmerge 接受独立 Review' env Z_SELF_REVIEW=no bash -c 'source "$1"; z_require_auto_merge_safe_review' _ "$ROOT/.agents/skills/z-lib.sh"

# A5：现有 zmerge 两条自动 squash 路径都必须读取同一门禁。
# 只让它们走到 Self-review gate，避免触发真实 gh / merge。
# shellcheck source=/dev/null
. "$ROOT/.agents/skills/zmerge/scripts/merge-lib.sh"
Z_WT="$ROOT"
Z_MAIN=main
Z_OWNER=o
Z_REPO=r
Z_NUMBER=29
z_require_passing_review() { Z_SELF_REVIEW=yes; return 0; }
z_fetch_origin_main() { return 0; }
z_main_is_current() { return 0; }
z_require_current_main() { return 0; }
for zmerge_entry in zmerge_reread_before_merge zmerge_do_merge; do
  zmerge_err="$TDIR/${zmerge_entry}.err"
  if ( "$zmerge_entry" ) > /dev/null 2> "$zmerge_err"; then
    bad "A5 ${zmerge_entry} 应拒绝 self-review"
  else
    zmerge_rc=$?
    [ "$zmerge_rc" = 1 ] && ok || bad "A5 ${zmerge_entry} 返回码"
    grep -Fq 'z.self_review_forbidden' "$zmerge_err" && ok \
      || bad "A5 ${zmerge_entry} reason code"
  fi
done

cmp_render="$TDIR/rendered-2.md"
review_render "$EFFECTIVE" "$RESULTS" "$cmp_render" beta alpha no $'0-meta/lib/new/review.sh\n0-meta/lib/new/task.sh'
cmp -s "$RENDERED" "$cmp_render" && ok || bad 'A7 canonical render identity stable'
grep -Fq 'exec "$ROOT/0-meta/bin/new" z review' "$ROOT/.agents/skills/zreview/scripts/publish-review.sh" \
  && ok || bad 'A7 Skill 是 canonical thin adapter'
grep -Fq 'z_cli_review' "$ROOT/0-meta/lib/new/z-cli.sh" \
  && ok || bad 'A7 canonical CLI 不依赖 Skill 实现'

if [ "$fail" -ne 0 ]; then
  printf '✗ Review 定向测试失败：%s 项（通过 %s）\n' "$fail" "$pass" >&2
  exit 1
fi
printf '✓ Review 定向测试通过（%s）\n' "$pass"
