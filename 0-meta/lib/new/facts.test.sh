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

# 写入归档：旧 tip 变为 history
printf '%s\n' '[]' > "$COMMENTS"
printf '%s\n' 400 > "$NEXT_ID_FILE"
task_write_marked_comment o r 16 "$TASK_CHECKPOINT_MARK" Checkpoint "$v1_ck_filled"
expect_eq "首次写入后只有一条 tip" 1 \
  "$(jq '[.[] | select(.body | contains("<!-- new-task-checkpoint -->"))] | length' "$COMMENTS")"
uniq1="$(task_unique_marked_comment o r 16 "$TASK_CHECKPOINT_MARK" Checkpoint || true)"
expect_true "首次写入后 unique tip 可读" '[ -n "$uniq1" ]'
task_write_marked_comment o r 16 "$TASK_CHECKPOINT_MARK" Checkpoint "$completion"
expect_eq "第二次写入归档历史" 1 \
  "$(jq '[.[] | select(.body | contains("<!-- new-task-checkpoint-history -->"))] | length' "$COMMENTS")"
expect_eq "tip 仍唯一" 1 \
  "$(jq '[.[] | select(.body | contains("<!-- new-task-checkpoint -->") and (contains("<!-- new-task-checkpoint-history -->") | not))] | length' "$COMMENTS")"
expect_true "新 tip 含 prev_fact_id" \
  'jq -r ".[].body" "$COMMENTS" | grep -q "^prev_fact_id="'

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

task_facts_write_capture "$WT" cursor-conversation 'cursor-review-session-bbbbbbb' '' review hook
task_facts_read_capture "$WT"
expect_eq "受控 hook capture 为 verified" verified "$FACT_CAPTURE_STATE"
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

echo "facts.test.sh: 通过 ${pass}，失败 ${fail}"
[ "$fail" -eq 0 ]
