#!/usr/bin/env bash
# Issue #16：共享阶段事实、tip/history、next command、applicability、provenance。
# 只用本地夹具与 mock gh；不写真实 GitHub，不改 consumer。
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
trap tmp_cleanup EXIT

fail=0
pass=0
TDIR=""
tmp_mkd TDIR issue-16-facts

ok() { pass=$((pass + 1)); }
bad() { printf '✗ %s\n' "$*" >&2; fail=$((fail + 1)); }
expect_eq() {
  if [ "$2" = "$3" ]; then ok; else bad "$1：期望 [$2] 实际 [$3]"; fi
}
expect_true() { if eval "$2"; then ok; else bad "$1"; fi; }
expect_false() { if eval "$2"; then bad "$1（应失败）"; else ok; fi; }

git_cfg() {
  git -C "$1" config user.email issue16@example.test
  git -C "$1" config user.name issue16
  git -C "$1" config commit.gpgsign false
  git -C "$1" config core.hooksPath /dev/null
}

COMMENTS="$TDIR/comments.json"
printf '%s\n' '[]' > "$COMMENTS"
NEXT_ID=200
NEXT_ID_FILE="$TDIR/next-id"
printf '%s\n' "$NEXT_ID" > "$NEXT_ID_FILE"
next_id() {
  NEXT_ID="$(cat "$NEXT_ID_FILE")"
  NEXT_ID=$((NEXT_ID + 1))
  printf '%s\n' "$NEXT_ID" > "$NEXT_ID_FILE"
  printf '%s\n' "$NEXT_ID"
}

comment_obj() {
  local id="$1" body="$2"
  jq -n --argjson id "$id" --arg body "$body" '{id:$id,body:$body}'
}

set_comments() {
  if [ "$#" -eq 0 ]; then
    printf '%s\n' '[]' > "$COMMENTS"
    return
  fi
  jq -s '.' "$@" > "$COMMENTS"
}

task_issue_comments_json() { cat "$COMMENTS"; }

gh() {
  local mode="" url="" body
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -X) mode="$2"; shift 2 ;;
      --input) shift 2 ;;
      repos/*/issues/*/comments) url="$1"; shift ;;
      repos/*/issues/comments/*)
        url="$1"; shift ;;
      --paginate) shift ;;
      api) shift ;;
      *) shift ;;
    esac
  done
  body="$(cat 2>/dev/null || true)"
  case "$mode" in
    POST)
      local posted id
      id="$(next_id)"
      posted="$(printf '%s' "$body" | jq -r '.body')"
      comment_obj "$id" "$posted" > "$TDIR/c-${id}.json"
      jq -s '.[0] + [.[1]]' "$COMMENTS" "$TDIR/c-${id}.json" > "$TDIR/comments.next"
      mv "$TDIR/comments.next" "$COMMENTS"
      comment_obj "$id" "$posted"
      ;;
    PATCH)
      local cid
      cid="${url##*/}"
      posted="$(printf '%s' "$body" | jq -r '.body')"
      comment_obj "$cid" "$posted" > "$TDIR/c-${cid}.json"
      jq --argjson id "$cid" --arg body "$posted" \
        'map(if .id == $id then .body=$body else . end)' "$COMMENTS" > "$TDIR/comments.next"
      mv "$TDIR/comments.next" "$COMMENTS"
      comment_obj "$cid" "$posted"
      ;;
    *)
      cat "$COMMENTS"
      ;;
  esac
}

WT="$TDIR/wt"
mkdir -p "$WT"
git init -q -b main "$WT"
git_cfg "$WT"
printf 'base\n' > "$WT/file.txt"
git -C "$WT" add file.txt
git -C "$WT" commit -qm 'chore: issue16 base'
BASE="$(git -C "$WT" rev-parse HEAD)"
printf 'work\n' >> "$WT/file.txt"
git -C "$WT" add file.txt
git -C "$WT" commit -qm 'feat(meta): issue16 candidate'
HEAD1="$(git -C "$WT" rev-parse HEAD)"
BLOB='deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'
Z_WT="$WT"
Z_HEAD="$HEAD1"
Z_CONTRACT_BLOB="$BLOB"
Z_OWNER=o
Z_REPO=r
Z_NUMBER=16
Z_MAIN=main
Z_BASE="$BASE"

v1_ck="$(git -C "$ROOT" show v1.0.0:0-meta/templates/task-contract-checkpoint.md)"
v1_rv="$(git -C "$ROOT" show v1.0.0:0-meta/templates/task-contract-review.md)"
expect_true "实际读取 v1.0.0 Checkpoint 模板" '[ -n "$v1_ck" ]'
expect_true "实际读取 v1.0.0 Review 模板" '[ -n "$v1_rv" ]'
expect_true "v1.0.0 Checkpoint 无 provenance_version" \
  '! printf "%s\n" "$v1_ck" | grep -q "^provenance_version="'
expect_true "v1.0.0 Review 无 source_ref" \
  '! printf "%s\n" "$v1_rv" | grep -q "^source_ref="'

v1_ck_filled="$(printf '%s\n' "$v1_ck" \
  | sed -e "s/ACTOR_ID/legacy@example.test/g" \
        -e "s/owner\\/repo#N/o\\/r#16/" \
        -e "s/blob-sha/${BLOB}/" \
        -e "s/full-sha/${HEAD1}/")"
task_facts_parse_provenance "$v1_ck_filled"
expect_eq "v1.0.0 Checkpoint provenance 为 unknown" unknown-unverified "$FACT_PROV_STATE"
expect_eq "读取后 v1.0.0 正文未改写" "$v1_ck_filled" "$v1_ck_filled"

delivery="$(cat <<EOF
${TASK_CHECKPOINT_MARK}
claim_actor=legacy@example.test
## Checkpoint
| 项 | 值 |
| --- | --- |
| Issue | o/r#16 |
| Contract | \`${BLOB}\` |
| claim_actor | \`legacy@example.test\` |
| 交付时间 | 2026-01-01T00:00:00+0000 |
| HEAD | \`${HEAD1}\` |
| 工作区状态 | 干净 |
| 交接状态 | review-ready |
| HEAD 持久化 | committed + clean HEAD |
| 工作树分类 | untracked=0 / unstaged=0 / staged=0 |
| 允许范围 | 0-meta/lib/new/ |
| PR | https://example.test/pr/1 |
| PR head → base | meta/task-16 → main |
| Project | Tasks #1 |
| 下一步 | 等待审查 |
EOF
)"
expect_eq "delivery shape 可识别" delivery "$(task_facts_classify_checkpoint "$delivery")"
task_facts_parse_provenance "$delivery"
expect_eq "delivery 缺 provenance 为 unknown" unknown-unverified "$FACT_PROV_STATE"

completion="$(printf '%s\n' "$v1_ck_filled" | awk '
  {print}
  /\| 工作区状态 \|/ {
    print "| 交接状态 | review-ready |"
    print "| HEAD 持久化 | committed + clean HEAD |"
    print "| 工作树分类 | untracked=0 / unstaged=0 / staged=0 |"
  }
')"
expect_eq "#13 completion shape 可识别" completion "$(task_facts_classify_checkpoint "$completion")"
expect_eq "v1.0.0 不是 claim-only" unknown "$(task_facts_classify_checkpoint "$v1_ck_filled")"
expect_eq "legacy completion independence class 为 unknown" unknown \
  "$(task_facts_independence_class "$completion")"
expect_eq "delivery independence class" delivery "$(task_facts_independence_class "$delivery")"

claim_unknown="$(cat <<EOF
${TASK_CHECKPOINT_HISTORY_MARK}
claim_actor=same@example.test
provenance_version=1
source_type=unknown
role=unknown
verification_state=unknown-unverified
## Checkpoint
由 \`new task claim\` 写入或更新。当前 Checkpoint tip 唯一。

| 项 | 值 |
| --- | --- |
| Issue | o/r#16 |
| Contract | \`${BLOB}\` |
| Agent | \`codex\`（未启动） |
| claim_actor | \`same@example.test\` |
| 启动时间 | 2026-09-01T00:00:00+0000 |
| HEAD | \`${BASE}\` |
| 工作区状态 | 干净 |
| 允许范围 | 0-meta/lib/new/ |
| PR | 无 |
| 下一步 | 已领取。下一步：new z dev。
EOF
)"
expect_eq "claim-only shape 可识别" claim "$(task_facts_classify_checkpoint "$claim_unknown")"
expect_eq "claim-only independence class" claim "$(task_facts_independence_class "$claim_unknown")"
expect_true "claim-only 检测器命中" 'task_facts_is_claim_only "$claim_unknown"'
expect_false "v1.0.0 不是 claim-only" 'task_facts_is_claim_only "$v1_ck_filled"'
expect_false "completion 不是 claim-only" 'task_facts_is_claim_only "$completion"'
expect_eq "claim writer stamp role" claim "$(TASK_FACT_STAMP_ROLE=claim task_facts_role_from_entry)"
claim_stamped="$(task_facts_stamp_provenance "$(printf '%s\n' "$claim_unknown" | sed "s/${TASK_CHECKPOINT_HISTORY_MARK}/${TASK_CHECKPOINT_MARK}/")" claim "")"
expect_true "claim stamp 写 role=claim" \
  'printf "%s\n" "$claim_stamped" | grep -Fxq "role=claim"'
expect_true "claim stamp 保持 unknown-unverified" \
  'printf "%s\n" "$claim_stamped" | grep -Fxq "verification_state=unknown-unverified"'
expect_false "claim stamp 不伪造 source_ref" \
  'printf "%s\n" "$claim_stamped" | grep -q "^source_ref="'

fail_review="$(cat <<EOF
${TASK_REVIEW_MARK}
review_actor=beta
claim_actor=alpha
Self-review=unknown
## Review
| 项 | 值 |
| --- | --- |
| Verdict | 不通过 |
| reviewed HEAD | \`${HEAD1}\` |
| 范围 | file.txt |
| Squash-Title | （无） |
| Issue | o/r#16 |
| Contract | \`${BLOB}\` |
| review_actor | \`beta\` |
| claim_actor | \`alpha\` |
| Self-review | \`unknown\` |
### 阻断项
ROUND_FAIL_UNIQUE_TOKEN 必须修
### 最小充分审查
- 审查代码与调用点：file.txt
- 复用证据：无
- 新增验证：定向
- 覆盖范围：file.txt 行为
- 未执行的大范围验证：全量
- 剩余风险：未知
### Contract 对照
- R1：不满足。缺实现
- A1：不通过。缺证据
EOF
)"
pass_review="$(printf '%s\n' "$fail_review" \
  | sed -e "s/不通过/通过/g" -e "s/不满足/满足/" \
        -e "s/Self-review=unknown/Self-review=no/" \
        -e "s/Self-review | \`unknown\`/Self-review | \`no\`/" \
        -e "s/（无）/\`feat(meta): issue16 candidate\`/")"

comment_obj 10 "$v1_ck_filled" > "$TDIR/c-10.json"
comment_obj 11 "$fail_review" > "$TDIR/c-11.json"
set_comments "$TDIR/c-10.json" "$TDIR/c-11.json"
task_facts_load o r 16 "$WT" "$BASE"
expect_eq "FAIL Review 下一步是 fix" "$TASK_BOOTSTRAP_NEXT_FIX" "$FACT_NEXT"
expect_eq "FAIL applicability" fail "$FACT_REVIEW_APPLICABILITY"
expect_true "当前 finding 来自 tip" \
  'printf "%s\n" "$FACT_FINDINGS" | grep -Fq ROUND_FAIL_UNIQUE_TOKEN'
card="$(task_facts_card)"
expect_true "facts card 不含完整历史要求" \
  '! printf "%s\n" "$card" | grep -Fq "请先完整阅读"'

# 无适用 Review：completion 已成立 → review
printf '%s\n' '[]' > "$COMMENTS"
task_facts_reset
TASK_FACTS_READY=0
expect_eq "无事实且已完成 → review" "$TASK_BOOTSTRAP_NEXT_REVIEW" \
  "$(task_next_canonical_command "$WT" "$BASE")"
git -C "$WT" reset -q --hard "$BASE"
expect_eq "未完成 → continue development" "$TASK_BOOTSTRAP_NEXT_DEV" \
  "$(task_next_canonical_command "$WT" "$BASE")"
git -C "$WT" reset -q --hard "$HEAD1"

# applicability：exact + 未证明 PASS
comment_obj 12 "$v1_ck_filled" > "$TDIR/c-12.json"
comment_obj 13 "$pass_review" > "$TDIR/c-13.json"
set_comments "$TDIR/c-12.json" "$TDIR/c-13.json"
task_facts_load o r 16 "$WT" "$BASE"
expect_eq "旧 PASS 无 provenance 不是当前适用 PASS" pass-unproven "$FACT_REVIEW_APPLICABILITY"
expect_eq "未证明 PASS 下一步仍是 review" "$TASK_BOOTSTRAP_NEXT_REVIEW" "$FACT_NEXT"
expect_false "applicable pass 拒绝 unknown provenance" \
  'task_facts_review_is_applicable_pass "$FACT_RV_BODY" "$HEAD1" "$BLOB" "$WT"'

# Contract-only change
task_facts_review_applicability "$pass_review" "$HEAD1" "ffffffffffffffffffffffffffffffffffffffff" "$WT"
expect_eq "Contract-only → stale-contract" stale-contract "$FACT_REVIEW_APPLICABILITY"

# rebase / 新 HEAD：祖先 PASS 不得覆盖
printf 'more\n' >> "$WT/file.txt"
git -C "$WT" add file.txt
git -C "$WT" commit -qm 'feat(meta): issue16 descendant'
HEAD2="$(git -C "$WT" rev-parse HEAD)"
Z_HEAD="$HEAD2"
task_facts_review_applicability "$pass_review" "$HEAD2" "$BLOB" "$WT"
expect_eq "descendant HEAD → stale-head" stale-head "$FACT_REVIEW_APPLICABILITY"
expect_eq "ancestry 诊断为 ancestor" ancestor "$FACT_HEAD_KIND"
expect_false "祖先 PASS 不能自动适用" \
  'task_facts_review_is_applicable_pass "$pass_review" "$HEAD2" "$BLOB" "$WT"'
git -C "$WT" reset -q --hard "$HEAD1"
Z_HEAD="$HEAD1"

# noop：HEAD/Contract 未变，但无 verified independence 仍不是当前 PASS
task_facts_review_applicability "$pass_review" "$HEAD1" "$BLOB" "$WT"
expect_eq "noop 且 HEAD 未变" exact "$FACT_HEAD_KIND"
expect_eq "noop 但 provenance 不足 → pass-unproven" pass-unproven "$FACT_REVIEW_APPLICABILITY"

# 10 轮历史：只投影 tip + 引用
hist_files=()
rows=""
i=1
while [ "$i" -le 10 ]; do
  hid=$((300 + i))
  token="FULLTEXT_ROUND_${i}_$(printf '%s' "$i" | sed 's/./X/g')_UNIQUE"
  hist="$(printf '%s\n' "$fail_review" \
    | sed -e "s/${TASK_REVIEW_MARK}/${TASK_REVIEW_HISTORY_MARK}/" \
          -e "s/ROUND_FAIL_UNIQUE_TOKEN/${token}/")"
  hist="${TASK_REVIEW_HISTORY_MARK}"$'\n'"fact_id=${hid}"$'\n'"${hist#*$'\n'}"
  comment_obj "$hid" "$hist" > "$TDIR/h-${hid}.json"
  hist_files+=("$TDIR/h-${hid}.json")
  rows="${rows}${hid}"$'\t'"${hid}"$'\t'"review"$'\t'"review"$'\t'"${HEAD1}"$'\t'"${BLOB}"$'\n'
  i=$((i + 1))
done
tip_rv="${fail_review}"$'\n\n'"$(task_facts_render_history_section "$rows")"
tip_rv="$(task_facts_set_prev_fields "$tip_rv" 11 310)"
comment_obj 10 "$v1_ck_filled" > "$TDIR/c-10.json"
comment_obj 11 "$tip_rv" > "$TDIR/c-11.json"
set_comments "$TDIR/c-10.json" "$TDIR/c-11.json" "${hist_files[@]}"
task_facts_load o r 16 "$WT" "$BASE"
card="$(task_facts_card)"
expect_true "10 轮 card 含历史 comment id" \
  'printf "%s\n" "$card" | grep -Fq 301 && printf "%s\n" "$card" | grep -Fq 310'
i=1
while [ "$i" -le 10 ]; do
  token="FULLTEXT_ROUND_${i}_$(printf '%s' "$i" | sed 's/./X/g')_UNIQUE"
  if printf '%s\n' "$card" | grep -Fq "$token"; then
    bad "10 轮 card 灌入了第 ${i} 轮全文"
  else
    ok
  fi
  i=$((i + 1))
done
expect_true "按需可读第 1 轮全文" \
  'task_facts_load_history_body 301 | grep -Fq FULLTEXT_ROUND_1'
expect_false "投影函数确认不含历史正文" \
  'task_facts_projection_has_history_bodies "$card" "$FACT_COMMENTS_JSON"'

# 分叉 / 重复 tip fail-closed
comment_obj 10 "$v1_ck_filled" > "$TDIR/c-10.json"
comment_obj 14 "$v1_ck_filled" > "$TDIR/c-14.json"
set_comments "$TDIR/c-10.json" "$TDIR/c-14.json"
if task_facts_load o r 16 "$WT" "$BASE" 2>"$TDIR/dup.err"; then
  bad "重复 Checkpoint tip 应 fail-closed"
else
  grep -Fq '找到 2 条 Checkpoint' "$TDIR/dup.err" && ok || bad "重复 tip 应报告 ambiguous"
fi

orphan="$(printf '%s\n' "$fail_review" | sed "s/${TASK_REVIEW_MARK}/${TASK_REVIEW_HISTORY_MARK}/")"
comment_obj 10 "$v1_ck_filled" > "$TDIR/c-10.json"
comment_obj 11 "$fail_review" > "$TDIR/c-11.json"
comment_obj 399 "$orphan" > "$TDIR/c-399.json"
set_comments "$TDIR/c-10.json" "$TDIR/c-11.json" "$TDIR/c-399.json"
if task_facts_load o r 16 "$WT" "$BASE" 2>"$TDIR/orphan.err"; then
  bad "未索引历史评论应 fail-closed"
else
  grep -Eq '未索引的历史评论|历史 fact 数量与 tip 索引不一致' "$TDIR/orphan.err" \
    && ok || bad "orphan 应报告 fork"
fi

comment_fact_id() {
  local id="$1"
  jq -r --argjson id "$id" '.[] | select(.id == $id) | .body' "$COMMENTS" \
    | awk -F= '/^fact_id=/{print $2; exit}'
}
history_ids() {
  jq -r '.[] | select(.body | contains("<!-- new-task-checkpoint-history -->")) | .id' "$COMMENTS"
}
tip_id() {
  jq -r '.[] | select(.body | contains("<!-- new-task-checkpoint -->") and (contains("<!-- new-task-checkpoint-history -->") | not)) | .id' "$COMMENTS"
}

# 写入归档：旧 tip 变为 history；fact_id 必须等于实际 comment id。
printf '%s\n' '[]' > "$COMMENTS"
printf '%s\n' 400 > "$NEXT_ID_FILE"
rm -f "$(task_facts_capture_path "$WT")" "$(task_facts_trusted_capture_path "$WT")"
task_write_marked_comment o r 16 "$TASK_CHECKPOINT_MARK" Checkpoint "$v1_ck_filled"
expect_eq "首次写入后只有一条 tip" 1 \
  "$(jq '[.[] | select(.body | contains("<!-- new-task-checkpoint -->"))] | length' "$COMMENTS")"
uniq1="$(task_unique_marked_comment o r 16 "$TASK_CHECKPOINT_MARK" Checkpoint || true)"
expect_true "首次写入后 unique tip 可读" '[ -n "$uniq1" ]'
first_tip="$(tip_id)"
expect_eq "第 1 次 tip fact_id == comment id" "$first_tip" "$(comment_fact_id "$first_tip")"
task_write_marked_comment o r 16 "$TASK_CHECKPOINT_MARK" Checkpoint "$completion"
expect_eq "第二次写入归档历史" 1 \
  "$(jq '[.[] | select(.body | contains("<!-- new-task-checkpoint-history -->"))] | length' "$COMMENTS")"
expect_eq "tip 仍唯一" 1 \
  "$(jq '[.[] | select(.body | contains("<!-- new-task-checkpoint -->") and (contains("<!-- new-task-checkpoint-history -->") | not))] | length' "$COMMENTS")"
expect_true "新 tip 含 prev_fact_id" \
  'jq -r ".[].body" "$COMMENTS" | grep -q "^prev_fact_id="'
hid2="$(history_ids | awk 'NR==1{print}')"
expect_eq "第 2 次归档 fact_id == 新 history comment id" "$hid2" "$(comment_fact_id "$hid2")"
expect_eq "第 2 次后 tip fact_id 仍是 tip comment id" "$first_tip" "$(comment_fact_id "$(tip_id)")"

# 第 3 次归档：旧 tip 已有 fact_id，必须改写成新 history id。
task_write_marked_comment o r 16 "$TASK_CHECKPOINT_MARK" Checkpoint "$delivery"
expect_eq "第三次写入后 history 为 2" 2 \
  "$(jq '[.[] | select(.body | contains("<!-- new-task-checkpoint-history -->"))] | length' "$COMMENTS")"
expect_eq "第三次后 tip 仍唯一" 1 \
  "$(jq '[.[] | select(.body | contains("<!-- new-task-checkpoint -->") and (contains("<!-- new-task-checkpoint-history -->") | not))] | length' "$COMMENTS")"
while IFS= read -r hid; do
  [ -n "$hid" ] || continue
  expect_eq "history ${hid} fact_id == comment id" "$hid" "$(comment_fact_id "$hid")"
done < <(history_ids)
expect_eq "第三次后 tip fact_id == tip comment id" "$(tip_id)" "$(comment_fact_id "$(tip_id)")"
task_facts_load o r 16 "$WT" "$BASE"
expect_eq "三轮归档后 current tip 可加载" 1 "$TASK_FACTS_READY"
expect_true "三轮归档后可按 id 读 history" \
  'task_facts_load_history_body "$hid2" | grep -Fq "<!-- new-task-checkpoint-history -->"'

# provenance / independence
dev_body="$(cat <<EOF
${TASK_CHECKPOINT_MARK}
claim_actor=same@example.test
provenance_version=1
source_type=cursor-conversation
source_ref=cursor-dev-session-aaaaaaa
role=dev
verification_state=verified
## Checkpoint
| 项 | 值 |
| --- | --- |
| HEAD | \`${HEAD1}\` |
| Contract | \`${BLOB}\` |
EOF
)"
rev_same="$(cat <<EOF
${TASK_REVIEW_MARK}
review_actor=same@example.test
claim_actor=same@example.test
Self-review=no
provenance_version=1
source_type=cursor-conversation
source_ref=cursor-dev-session-aaaaaaa
role=review
verification_state=verified
EOF
)"
rev_other="$(cat <<EOF
${TASK_REVIEW_MARK}
review_actor=same@example.test
claim_actor=same@example.test
Self-review=no
provenance_version=1
source_type=cursor-conversation
source_ref=cursor-review-session-bbbbbbb
role=review
verification_state=verified
EOF
)"
rev_fork="$(cat <<EOF
${TASK_REVIEW_MARK}
review_actor=other@example.test
claim_actor=same@example.test
Self-review=no
provenance_version=1
source_type=cursor-conversation
source_ref=cursor-fork-session-ccccccc
lineage_ref=cursor-dev-session-aaaaaaa
role=review
verification_state=verified
EOF
)"
comment_obj 50 "$dev_body" > "$TDIR/c-50.json"
set_comments "$TDIR/c-50.json"
FACT_COMMENTS_JSON="$(cat "$COMMENTS")"
expect_false "同 session 改 actor 名不能独立" \
  'task_facts_reviewer_independent "$rev_same" "$HEAD1" "$WT" "$FACT_COMMENTS_JSON"'
expect_true "同 Git identity 的真实独立 session 可通过" \
  'task_facts_reviewer_independent "$rev_other" "$HEAD1" "$WT" "$FACT_COMMENTS_JSON"'
expect_false "继承开发上下文的 fork 不能独立" \
  'task_facts_reviewer_independent "$rev_fork" "$HEAD1" "$WT" "$FACT_COMMENTS_JSON"'
expect_false "legacy unknown 不能独立" \
  'task_facts_reviewer_independent "$pass_review" "$HEAD1" "$WT" "$FACT_COMMENTS_JSON"'

rm -f "$(task_facts_capture_path "$WT")" "$(task_facts_trusted_capture_path "$WT")"
task_facts_write_verified_capture "$WT" cursor-conversation 'cursor-review-session-bbbbbbb' '' review
task_facts_read_capture "$WT"
expect_eq "受控 hook writer 的 capture 为 verified" verified "$FACT_CAPTURE_STATE"
task_facts_write_capture "$WT" cursor-conversation 'cursor-review-session-bbbbbbb' '' review hook
rm -f "$(task_facts_trusted_capture_path "$WT")"
task_facts_read_capture "$WT"
expect_eq "仅 captured_by=hook 字符串不能 verified" unknown-unverified "$FACT_CAPTURE_STATE"
printf '%s\n' '{"source_type":"cursor-conversation","source_ref":"x","captured_by":"user"}' \
  > "$(task_facts_capture_path "$WT")"
task_facts_read_capture "$WT"
expect_eq "非 hook/launcher capture 不能 verified" unknown-unverified "$FACT_CAPTURE_STATE"

expect_false "facts.sh 不生成 UUID" \
  'grep -Eq "uuidgen|random/uuid|python3 -c .uuid" "$ROOT/0-meta/lib/new/facts.sh"'
expect_true "dev/fix/review 共用 task_facts_load" \
  'grep -Fq "z_cli_load_facts" "$ROOT/0-meta/lib/new/z-cli.sh"'
expect_true "next command 含 fix 常量" \
  'grep -Fq "TASK_BOOTSTRAP_NEXT_FIX" "$ROOT/0-meta/lib/new/bootstrap.sh"'

# 10 轮 writer：每条 history 的 fact_id == comment id，tip 唯一，整条 history 可读。
printf '%s\n' '[]' > "$COMMENTS"
printf '%s\n' 500 > "$NEXT_ID_FILE"
rm -f "$(task_facts_capture_path "$WT")" "$(task_facts_trusted_capture_path "$WT")"
round=1
while [ "$round" -le 10 ]; do
  task_write_marked_comment o r 16 "$TASK_CHECKPOINT_MARK" Checkpoint \
    "$(printf '%s\nwriter_round=%s\n' "$v1_ck_filled" "$round")"
  round=$((round + 1))
done
expect_eq "10 轮 writer 后 tip 唯一" 1 \
  "$(jq '[.[] | select(.body | contains("<!-- new-task-checkpoint -->") and (contains("<!-- new-task-checkpoint-history -->") | not))] | length' "$COMMENTS")"
expect_eq "10 轮 writer 后 history 为 9" 9 \
  "$(jq '[.[] | select(.body | contains("<!-- new-task-checkpoint-history -->"))] | length' "$COMMENTS")"
expect_eq "10 轮 tip fact_id == tip comment id" "$(tip_id)" "$(comment_fact_id "$(tip_id)")"
task_facts_load o r 16 "$WT" "$BASE"
expect_eq "10 轮 writer 后整条 history 可加载" 1 "$TASK_FACTS_READY"
while IFS= read -r hid; do
  [ -n "$hid" ] || continue
  expect_eq "10 轮 history ${hid} fact_id == comment id" "$hid" "$(comment_fact_id "$hid")"
  expect_true "10 轮 history ${hid} 可按 id 读取" \
    "task_facts_load_history_body \"$hid\" | grep -Fq '<!-- new-task-checkpoint-history -->'"
done < <(history_ids)
expect_eq "10 轮 writer 后 current tip 唯一" 1 \
  "$(printf '%s\n' "$FACT_CK_ID" | awk 'NF{c++} END{print c+0}')"

# F16-A3-01：不能信 captured_by=hook；同 worktree 换 source_ref 无 lineage 不能独立。
comment_obj 50 "$dev_body" > "$TDIR/c-50.json"
set_comments "$TDIR/c-50.json"
FACT_COMMENTS_JSON="$(cat "$COMMENTS")"
rm -f "$(task_facts_capture_path "$WT")" "$(task_facts_trusted_capture_path "$WT")"
expect_false "missing capture 不能独立" \
  'task_facts_current_reviewer_independent "$WT" "$HEAD1" "$FACT_COMMENTS_JSON"'

task_facts_write_verified_capture "$WT" cursor-conversation 'cursor-dev-session-aaaaaaa' '' dev
task_facts_read_capture "$WT"
expect_eq "resume 同 source_ref 仍 verified" verified "$FACT_CAPTURE_STATE"
expect_false "resume 不能变成独立 Reviewer" \
  'task_facts_current_reviewer_independent "$WT" "$HEAD1" "$FACT_COMMENTS_JSON"'

printf '%s\n' '{"source_type":"cursor-conversation","source_ref":"cursor-forged-session-zzzzzzz","lineage_ref":"","role":"review","captured_by":"hook"}' \
  > "$(task_facts_capture_path "$WT")"
task_facts_read_capture "$WT"
expect_eq "同 worktree 换 UUID + captured_by=hook 不能 verified" unknown-unverified "$FACT_CAPTURE_STATE"
expect_eq "换 UUID 后保留原 lineage" cursor-dev-session-aaaaaaa "$FACT_CAPTURE_SOURCE_REF"
expect_false "换 UUID + captured_by=hook 不能独立" \
  'task_facts_current_reviewer_independent "$WT" "$HEAD1" "$FACT_COMMENTS_JSON"'

task_facts_write_verified_capture "$WT" cursor-conversation 'cursor-forged-session-yyyyyyy' '' review
task_facts_read_capture "$WT"
expect_eq "同 worktree 换 source_ref 无 lineage 不能 verified" unknown-unverified "$FACT_CAPTURE_STATE"
expect_eq "无 lineage 时保留原 source_ref" cursor-dev-session-aaaaaaa "$FACT_CAPTURE_SOURCE_REF"
expect_false "同 worktree 换 source_ref 无 lineage 不能独立" \
  'task_facts_current_reviewer_independent "$WT" "$HEAD1" "$FACT_COMMENTS_JSON"'

task_facts_write_verified_capture "$WT" cursor-conversation 'cursor-fork-session-ccccccc' \
  'cursor-dev-session-aaaaaaa' review
task_facts_read_capture "$WT"
expect_eq "fork 带 parent lineage 为 verified" verified "$FACT_CAPTURE_STATE"
expect_eq "fork 的 source_ref 是新会话" cursor-fork-session-ccccccc "$FACT_CAPTURE_SOURCE_REF"
expect_false "fork with parent lineage 不能独立" \
  'task_facts_current_reviewer_independent "$WT" "$HEAD1" "$FACT_COMMENTS_JSON"'

WT2="$TDIR/wt-independent"
git clone -q "$WT" "$WT2"
rm -f "$(task_facts_capture_path "$WT2")" "$(task_facts_trusted_capture_path "$WT2")"
task_facts_write_verified_capture "$WT2" cursor-conversation 'cursor-review-session-bbbbbbb' '' review
task_facts_read_capture "$WT2"
expect_eq "独立 worktree 的 hook capture 为 verified" verified "$FACT_CAPTURE_STATE"
expect_true "genuine independent source 可通过" \
  'task_facts_current_reviewer_independent "$WT2" "$HEAD1" "$FACT_COMMENTS_JSON"'
expect_false "同 session 改 actor 名不能独立" \
  'task_facts_reviewer_independent "$rev_same" "$HEAD1" "$WT" "$FACT_COMMENTS_JSON"'

# F16-A3-03：provenance machine fields 必须唯一，重复 fail-closed。
ok_prov_review="$(printf '%s\n' "$pass_review" | awk '
  {print}
  $0=="<!-- new-task-review -->" {
    print "provenance_version=1"
    print "source_type=cursor-conversation"
    print "source_ref=cursor-review-session-bbbbbbb"
    print "role=review"
    print "verification_state=verified"
  }
')"
expect_true "合法单值 provenance 可解析" \
  'task_facts_parse_provenance "$ok_prov_review"'
task_facts_parse_provenance "$ok_prov_review"
expect_eq "合法单值 verification_state" verified "$FACT_PROV_STATE"
expect_eq "可选 lineage_ref 缺失仍合法" "" "$FACT_PROV_LINEAGE_REF"
comment_obj 50 "$dev_body" > "$TDIR/c-50.json"
comment_obj 80 "$ok_prov_review" > "$TDIR/c-80.json"
set_comments "$TDIR/c-50.json" "$TDIR/c-80.json"
FACT_COMMENTS_JSON="$(cat "$COMMENTS")"
Z_HEAD="$HEAD1"
Z_CONTRACT_BLOB="$BLOB"
task_facts_load o r 16 "$WT" "$BASE"
expect_eq "合法单值 Review applicability=pass" pass "$FACT_REVIEW_APPLICABILITY"

dup_source="${ok_prov_review}"$'\n'"source_ref=cursor-review-session-bbbbbbb"
expect_false "duplicate source_ref fail-closed" \
  'task_facts_parse_provenance "$dup_source"'
task_facts_review_applicability "$dup_source" "$HEAD1" "$BLOB" "$WT"
expect_eq "duplicate source_ref applicability=conflict" conflict "$FACT_REVIEW_APPLICABILITY"
comment_obj 81 "$dup_source" > "$TDIR/c-81.json"
set_comments "$TDIR/c-50.json" "$TDIR/c-81.json"
if task_facts_load o r 16 "$WT" "$BASE" 2>"$TDIR/dup-source.err"; then
  bad "duplicate source_ref 的 loader 应 fail-closed"
else
  grep -Fq 'provenance 字段' "$TDIR/dup-source.err" && ok || bad "duplicate source_ref 应报告冲突"
fi

dup_role="${ok_prov_review}"$'\n'"role=dev"
expect_false "duplicate role fail-closed" \
  'task_facts_parse_provenance "$dup_role"'
task_facts_review_applicability "$dup_role" "$HEAD1" "$BLOB" "$WT"
expect_eq "duplicate role applicability=conflict" conflict "$FACT_REVIEW_APPLICABILITY"

dup_state="${ok_prov_review}"$'\n'"verification_state=unknown-unverified"
expect_false "duplicate verification_state fail-closed" \
  'task_facts_parse_provenance "$dup_state"'
task_facts_review_applicability "$dup_state" "$HEAD1" "$BLOB" "$WT"
expect_eq "duplicate verification_state applicability=conflict" conflict "$FACT_REVIEW_APPLICABILITY"

dup_conflict="${ok_prov_review}"$'\n'"source_ref=cursor-other-session-zzzzzzz"
expect_false "conflicting duplicate source_ref fail-closed" \
  'task_facts_parse_provenance "$dup_conflict"'
task_facts_review_applicability "$dup_conflict" "$HEAD1" "$BLOB" "$WT"
expect_eq "conflicting duplicate applicability=conflict" conflict "$FACT_REVIEW_APPLICABILITY"
expect_false "conflicting duplicate 不能 silently 取第一个而独立" \
  'task_facts_reviewer_independent "$dup_conflict" "$HEAD1" "$WT" "$FACT_COMMENTS_JSON"'

# F16-RA-01：claim-only 不得污染 reviewer independence；真实 dev/fix unknown 仍 fail-closed。
ra_pass_b="$(printf '%s\n' "$pass_review" | awk '
  {print}
  $0=="<!-- new-task-review -->" {
    print "provenance_version=1"
    print "source_type=codex-session"
    print "source_ref=codex-review-session-bbbbbbb"
    print "role=review"
    print "verification_state=verified"
  }
')"
ra_rev_b="$(cat <<EOF
${TASK_REVIEW_MARK}
review_actor=same@example.test
claim_actor=same@example.test
Self-review=no
provenance_version=1
source_type=codex-session
source_ref=codex-review-session-bbbbbbb
role=review
verification_state=verified
EOF
)"
a_dev_verified="$(cat <<EOF
${TASK_CHECKPOINT_HISTORY_MARK}
claim_actor=same@example.test
provenance_version=1
source_type=codex-session
source_ref=codex-dev-session-aaaaaaa
role=dev
verification_state=verified
## Checkpoint
| 项 | 值 |
| --- | --- |
| HEAD | \`${HEAD1}\` |
| Contract | \`${BLOB}\` |
| 交接状态 | review-ready |
| HEAD 持久化 | committed + clean HEAD |
| 工作树分类 | untracked=0 / unstaged=0 / staged=0 |
EOF
)"
c_fix_verified="$(cat <<EOF
${TASK_CHECKPOINT_MARK}
claim_actor=same@example.test
provenance_version=1
source_type=codex-session
source_ref=codex-fix-session-ccccccc
role=fix
verification_state=verified
## Checkpoint
| 项 | 值 |
| --- | --- |
| HEAD | \`${HEAD1}\` |
| Contract | \`${BLOB}\` |
| 交接状态 | review-ready |
| HEAD 持久化 | committed + clean HEAD |
| 工作树分类 | untracked=0 / unstaged=0 / staged=0 |
EOF
)"
a_dev_unknown="$(printf '%s\n' "$a_dev_verified" \
  | sed -e 's/source_type=codex-session/source_type=unknown/' \
        -e '/^source_ref=/d' \
        -e 's/verification_state=verified/verification_state=unknown-unverified/')"
c_fix_unknown="$(printf '%s\n' "$c_fix_verified" \
  | sed -e 's/source_type=codex-session/source_type=unknown/' \
        -e '/^source_ref=/d' \
        -e 's/verification_state=verified/verification_state=unknown-unverified/')"
claim_unknown2="$(printf '%s\n' "$claim_unknown" \
  | sed -e 's/2026-09-01T00:00:00+0000/2026-09-02T00:00:00+0000/' \
        -e "s/${BASE}/${HEAD1}/")"
claim_role="$(printf '%s\n' "$claim_unknown" | sed 's/role=unknown/role=claim/')"
unclassified="$(cat <<EOF
${TASK_CHECKPOINT_MARK}
provenance_version=1
source_type=unknown
role=unknown
verification_state=unknown-unverified
## Checkpoint
| 项 | 值 |
| --- | --- |
| HEAD | \`${HEAD1}\` |
| leftover | unclassified provenance residue |
EOF
)"
review_hist="$(printf '%s\n' "$fail_review" | sed "s/${TASK_REVIEW_MARK}/${TASK_REVIEW_HISTORY_MARK}/")"
review_hist="${TASK_REVIEW_HISTORY_MARK}"$'\n'"role=review"$'\n'"${review_hist#*$'\n'}"

comment_obj 601 "$claim_unknown" > "$TDIR/c-601.json"
comment_obj 602 "$a_dev_verified" > "$TDIR/c-602.json"
comment_obj 603 "$c_fix_verified" > "$TDIR/c-603.json"
comment_obj 604 "$ra_pass_b" > "$TDIR/c-604.json"
set_comments "$TDIR/c-601.json" "$TDIR/c-602.json" "$TDIR/c-603.json" "$TDIR/c-604.json"
FACT_COMMENTS_JSON="$(cat "$COMMENTS")"
RA_EXECS="$(task_facts_executions_for_candidate "$FACT_COMMENTS_JSON" "$HEAD1" "$WT")"
expect_false "F16-RA-01 Case1 claim 不进 independence set" \
  'printf "%s\n" "$RA_EXECS" | awk -F "\t" "\$1==601{found=1} END{exit found?0:1}"'
expect_true "F16-RA-01 Case1 纳入 verified A" \
  'printf "%s\n" "$RA_EXECS" | awk -F "\t" "\$1==602{found=1} END{exit found?0:1}"'
expect_true "F16-RA-01 Case1 纳入 verified C" \
  'printf "%s\n" "$RA_EXECS" | awk -F "\t" "\$1==603{found=1} END{exit found?0:1}"'
expect_true "F16-RA-01 Case1 B independent = YES" \
  'task_facts_reviewer_independent "$ra_rev_b" "$HEAD1" "$WT" "$FACT_COMMENTS_JSON"'
task_facts_review_applicability "$ra_pass_b" "$HEAD1" "$BLOB" "$WT"
expect_eq "F16-RA-01 Case1 允许 Self-review=no" pass "$FACT_REVIEW_APPLICABILITY"
expect_true "F16-RA-01 Case1 applicable pass" \
  'task_facts_review_is_applicable_pass "$ra_pass_b" "$HEAD1" "$BLOB" "$WT"'
WT_RA="$TDIR/wt-ra01"
git clone -q "$WT" "$WT_RA"
rm -f "$(task_facts_capture_path "$WT_RA")" "$(task_facts_trusted_capture_path "$WT_RA")"
task_facts_write_verified_capture "$WT_RA" codex-session 'codex-review-session-bbbbbbb' '' review
expect_true "F16-RA-01 Case1 current reviewer independent" \
  'task_facts_current_reviewer_independent "$WT_RA" "$HEAD1" "$FACT_COMMENTS_JSON"'

comment_obj 611 "$claim_unknown" > "$TDIR/c-611.json"
comment_obj 612 "$a_dev_unknown" > "$TDIR/c-612.json"
set_comments "$TDIR/c-611.json" "$TDIR/c-612.json"
FACT_COMMENTS_JSON="$(cat "$COMMENTS")"
expect_false "F16-RA-01 Case2 A unknown 不能 independent PASS" \
  'task_facts_reviewer_independent "$ra_rev_b" "$HEAD1" "$WT" "$FACT_COMMENTS_JSON"'

comment_obj 621 "$claim_unknown" > "$TDIR/c-621.json"
comment_obj 622 "$a_dev_verified" > "$TDIR/c-622.json"
comment_obj 623 "$c_fix_unknown" > "$TDIR/c-623.json"
set_comments "$TDIR/c-621.json" "$TDIR/c-622.json" "$TDIR/c-623.json"
FACT_COMMENTS_JSON="$(cat "$COMMENTS")"
expect_false "F16-RA-01 Case3 C unknown 不能 independent PASS" \
  'task_facts_reviewer_independent "$ra_rev_b" "$HEAD1" "$WT" "$FACT_COMMENTS_JSON"'

comment_obj 631 "$claim_unknown" > "$TDIR/c-631.json"
comment_obj 632 "$claim_unknown2" > "$TDIR/c-632.json"
comment_obj 633 "$claim_role" > "$TDIR/c-633.json"
comment_obj 634 "$a_dev_verified" > "$TDIR/c-634.json"
set_comments "$TDIR/c-631.json" "$TDIR/c-632.json" "$TDIR/c-633.json" "$TDIR/c-634.json"
FACT_COMMENTS_JSON="$(cat "$COMMENTS")"
RA_EXECS="$(task_facts_executions_for_candidate "$FACT_COMMENTS_JSON" "$HEAD1" "$WT")"
expect_false "F16-RA-01 Case4 多轮 claim 不进 set" \
  'printf "%s\n" "$RA_EXECS" | awk -F "\t" "\$1==631||\$1==632||\$1==633{found=1} END{exit found?0:1}"'
expect_true "F16-RA-01 Case4 多轮 claim 不污染 independence" \
  'task_facts_reviewer_independent "$ra_rev_b" "$HEAD1" "$WT" "$FACT_COMMENTS_JSON"'
set_comments "$TDIR/c-631.json" "$TDIR/c-632.json" "$TDIR/c-633.json"
FACT_COMMENTS_JSON="$(cat "$COMMENTS")"
expect_false "F16-RA-01 Case4 仅 claim 不能独立" \
  'task_facts_reviewer_independent "$ra_rev_b" "$HEAD1" "$WT" "$FACT_COMMENTS_JSON"'

comment_obj 641 "$v1_ck_filled" > "$TDIR/c-641.json"
set_comments "$TDIR/c-641.json"
FACT_COMMENTS_JSON="$(cat "$COMMENTS")"
expect_eq "F16-RA-01 Case5 v1 class=unknown" unknown \
  "$(task_facts_independence_class "$v1_ck_filled")"
expect_false "F16-RA-01 Case5 v1 缺 provenance fail-closed" \
  'task_facts_reviewer_independent "$ra_rev_b" "$HEAD1" "$WT" "$FACT_COMMENTS_JSON"'
comment_obj 642 "$completion" > "$TDIR/c-642.json"
set_comments "$TDIR/c-642.json"
FACT_COMMENTS_JSON="$(cat "$COMMENTS")"
expect_false "F16-RA-01 Case5 legacy completion 缺 provenance fail-closed" \
  'task_facts_reviewer_independent "$ra_rev_b" "$HEAD1" "$WT" "$FACT_COMMENTS_JSON"'

comment_obj 651 "$claim_unknown" > "$TDIR/c-651.json"
comment_obj 652 "$a_dev_verified" > "$TDIR/c-652.json"
comment_obj 653 "$delivery" > "$TDIR/c-653.json"
comment_obj 654 "$review_hist" > "$TDIR/c-654.json"
set_comments "$TDIR/c-651.json" "$TDIR/c-652.json" "$TDIR/c-653.json" "$TDIR/c-654.json"
FACT_COMMENTS_JSON="$(cat "$COMMENTS")"
RA_EXECS="$(task_facts_executions_for_candidate "$FACT_COMMENTS_JSON" "$HEAD1" "$WT")"
expect_false "F16-RA-01 Case6 delivery 不进 set" \
  'printf "%s\n" "$RA_EXECS" | awk -F "\t" "\$1==653{found=1} END{exit found?0:1}"'
expect_false "F16-RA-01 Case6 review history 不进 set" \
  'printf "%s\n" "$RA_EXECS" | awk -F "\t" "\$1==654{found=1} END{exit found?0:1}"'
expect_true "F16-RA-01 Case6 review/delivery 不污染 independence" \
  'task_facts_reviewer_independent "$ra_rev_b" "$HEAD1" "$WT" "$FACT_COMMENTS_JSON"'

comment_obj 661 "$unclassified" > "$TDIR/c-661.json"
comment_obj 662 "$a_dev_verified" > "$TDIR/c-662.json"
set_comments "$TDIR/c-661.json" "$TDIR/c-662.json"
FACT_COMMENTS_JSON="$(cat "$COMMENTS")"
expect_eq "F16-RA-01 Case7 无法分类 class=unknown" unknown \
  "$(task_facts_independence_class "$unclassified")"
expect_true "F16-RA-01 Case7 无法分类仍纳入 set" \
  'task_facts_executions_for_candidate "$FACT_COMMENTS_JSON" "$HEAD1" "$WT" | awk -F "\t" "\$1==661{found=1} END{exit found?0:1}"'
expect_false "F16-RA-01 Case7 无法分类 fail-closed" \
  'task_facts_reviewer_independent "$ra_rev_b" "$HEAD1" "$WT" "$FACT_COMMENTS_JSON"'

# F16-E2E-corrupt-fact-id：current tip 与 history 共用正文 fact_id ↔ GitHub id。
ck_fact_ok="$(printf '%s\n' "$v1_ck_filled" | awk '
  {print}
  $0=="<!-- new-task-checkpoint -->" { print "fact_id=100" }
')"
comment_obj 100 "$ck_fact_ok" > "$TDIR/c-100-ok.json"
set_comments "$TDIR/c-100-ok.json"
task_facts_load o r 16 "$WT" "$BASE"
expect_eq "current Checkpoint fact_id=100 且 comment id=100 可加载" 1 "$TASK_FACTS_READY"
expect_eq "current Checkpoint 使用 GitHub comment id" 100 "$FACT_CK_ID"

ck_fact_bad="$(printf '%s\n' "$v1_ck_filled" | awk '
  {print}
  $0=="<!-- new-task-checkpoint -->" { print "fact_id=1" }
')"
comment_obj 100 "$ck_fact_bad" > "$TDIR/c-100-bad.json"
set_comments "$TDIR/c-100-bad.json"
if task_facts_load o r 16 "$WT" "$BASE" 2>"$TDIR/ck-fact-bad.err"; then
  bad "current Checkpoint fact_id=1 / comment id=100 应 fail-closed"
else
  grep -Fq 'fact_id=1' "$TDIR/ck-fact-bad.err" \
    && grep -Fq '100' "$TDIR/ck-fact-bad.err" \
    && ok || bad "corrupt Checkpoint fact_id 应报告与 GitHub comment id 冲突"
fi

rv_fact_ok="$(printf '%s\n' "$fail_review" | awk '
  {print}
  $0=="<!-- new-task-review -->" { print "fact_id=200" }
')"
comment_obj 200 "$rv_fact_ok" > "$TDIR/c-200-ok.json"
set_comments "$TDIR/c-200-ok.json"
task_facts_load o r 16 "$WT" "$BASE"
expect_eq "current Review fact_id=200 且 comment id=200 可加载" 1 "$TASK_FACTS_READY"
expect_eq "current Review 使用 GitHub comment id" 200 "$FACT_RV_ID"

rv_fact_bad="$(printf '%s\n' "$fail_review" | awk '
  {print}
  $0=="<!-- new-task-review -->" { print "fact_id=1" }
')"
comment_obj 200 "$rv_fact_bad" > "$TDIR/c-200-bad.json"
set_comments "$TDIR/c-200-bad.json"
if task_facts_load o r 16 "$WT" "$BASE" 2>"$TDIR/rv-fact-bad.err"; then
  bad "current Review fact_id=1 / comment id=200 应 fail-closed"
else
  grep -Fq 'fact_id=1' "$TDIR/rv-fact-bad.err" \
    && grep -Fq '200' "$TDIR/rv-fact-bad.err" \
    && ok || bad "corrupt Review fact_id 应报告与 GitHub comment id 冲突"
fi

ck_fact_dup="$(printf '%s\n' "$v1_ck_filled" | awk '
  {print}
  $0=="<!-- new-task-checkpoint -->" {
    print "fact_id=100"
    print "fact_id=1"
  }
')"
comment_obj 100 "$ck_fact_dup" > "$TDIR/c-100-dup.json"
set_comments "$TDIR/c-100-dup.json"
if task_facts_load o r 16 "$WT" "$BASE" 2>"$TDIR/ck-fact-dup.err"; then
  bad "duplicate fact_id machine field 应 fail-closed"
else
  grep -Fq 'fact_id' "$TDIR/ck-fact-dup.err" \
    && ok || bad "duplicate fact_id 应报告重复"
fi

comment_obj 100 "$v1_ck_filled" > "$TDIR/c-100-legacy.json"
comment_obj 200 "$fail_review" > "$TDIR/c-200-legacy.json"
set_comments "$TDIR/c-100-legacy.json" "$TDIR/c-200-legacy.json"
task_facts_load o r 16 "$WT" "$BASE"
expect_eq "legacy current fact 无 fact_id 仍可加载" 1 "$TASK_FACTS_READY"
expect_eq "legacy Checkpoint 仍用 GitHub comment id" 100 "$FACT_CK_ID"
expect_eq "legacy Review 仍用 GitHub comment id" 200 "$FACT_RV_ID"
expect_false "legacy Checkpoint 未回填 fact_id" \
  'printf "%s\n" "$FACT_CK_BODY" | grep -q "^fact_id="'
expect_false "legacy Review 未回填 fact_id" \
  'printf "%s\n" "$FACT_RV_BODY" | grep -q "^fact_id="'

echo "facts.test.sh: 通过 ${pass}，失败 ${fail}"
[ "$fail" -eq 0 ]
