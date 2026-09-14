#!/usr/bin/env bash
# Task Contract 定向测试：parser / 文件契约门禁 / Review-PR / ablation。
# 不跑全仓库 test，不调用真实 gh / orca。
set -Eeuo pipefail
export LC_COLLATE=C
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/0-meta/lib/new/core.sh"
# shellcheck source=/dev/null
. "$ROOT/0-meta/lib/new/task.sh"
# shellcheck source=/dev/null
. "$ROOT/0-meta/lib/new/contract.sh"
trap tmp_cleanup EXIT

fail=0
pass=0
TDIR=""
tmp_mkd TDIR contract-test

ok() { pass=$((pass+1)); }
bad() { echo "✗ $*" >&2; fail=$((fail+1)); }

expect_ok() {
  local n="$1"; shift
  if "$@"; then ok
  else bad "${n}: expected success"; fi
}

expect_fail() {
  local n="$1"; shift
  if "$@" >/dev/null 2>&1; then bad "${n}: expected failure"
  else ok; fi
}

GOOD_ISSUE="$(cat <<'EOF'
<!-- task-contract:v1 -->

## 背景

这段说明不进 digest。改它不应改变 Contract digest。

## 分支建议

- 分支：`meta/example`
- sparse：`0-meta`

## 目标

建立可校验的 Task Contract。

## 要求 / 实现细节

### [R1] 解析 Contract

必须解析目标、R、A 与允许范围。

### [R2] 计算 digest

digest 覆盖目标、R、A、A→R 与范围。

示例代码块里的伪字段不算：

```
## 目标
假目标
### [R99] 假要求
1. [A99 → R99] 假验收
```

## 验收

1. [A1 → R1] 缺核心字段时拒绝。
2. [A2 → R1,R2] 改目标会改变 digest。
3. [A3 → R2] 仅当本条声明了适用条件且未触发时才可不适用。
适用条件：仅用于演示 not-applicable 的 Contract 条件。

## 允许改动范围

- `0-meta/lib/new/`
- `0-meta/schema/`
EOF
)"

JSON="$TDIR/c.json"
if ! contract_parse_body "$GOOD_ISSUE" "$JSON"; then
  bad "合格 Issue 应能解析"
else
  ok
fi
BLOB='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
CANON="$TDIR/canon.json"
contract_canonical_json "$JSON" > "$CANON" && ok || bad "规范化 json"

validator_body="$(printf '%s\n' "$GOOD_ISSUE" | sed 's/缺核心字段时拒绝/缺核心字段时拒绝；validator:contract-test/')"
validator_json="$TDIR/validator.json"
expect_ok "Contract 解析白名单 validator 引用" contract_parse_body "$validator_body" "$validator_json"
expect_ok "Contract 保存 validator registry 字段" test "$(jq -r '.acceptances[] | select(.id=="A1") | .validators[0]' "$validator_json")" = contract-test
unknown_validator_body="$(printf '%s\n' "$GOOD_ISSUE" | sed 's/缺核心字段时拒绝/缺核心字段时拒绝；validator:not-registered/')"
expect_fail "Contract approve 阶段拒绝未知 validator" contract_parse_body "$unknown_validator_body" "$TDIR/unknown-validator.json"

# A1：缺字段 / 重复 / 假字段
expect_fail "缺 marker" contract_parse_body "$(printf '%s\n' "$GOOD_ISSUE" | grep -v task-contract)" "$TDIR/x.json"
empty_goal="$(printf '%s\n' "$GOOD_ISSUE" | awk '
  /^## 目标/{print; skip=1; next}
  skip && /^## /{skip=0}
  skip{next}
  {print}
')"
expect_fail "空目标" contract_parse_body "$empty_goal" "$TDIR/x.json"

dup_sec="$(printf '%s\n' "$GOOD_ISSUE"; echo; echo '## 目标'; echo; echo '又一个')"
expect_fail "重复 section" contract_parse_body "$dup_sec" "$TDIR/x.json"

dup_r="$(printf '%s\n' "$GOOD_ISSUE" | awk '{print} /\[R2\]/{print "### [R1] 重复"}')"
expect_fail "重复 R ID" contract_parse_body "$dup_r" "$TDIR/x.json"

no_arrow="$(printf '%s\n' "$GOOD_ISSUE" | sed 's/\[A1 → R1\]/[A1]/')"
expect_fail "缺 A→R" contract_parse_body "$no_arrow" "$TDIR/x.json"

bad_alias="$(printf '%s\n' "$GOOD_ISSUE" | sed 's/\[A1 → R1\]/[A1 → 全局]/')"
expect_fail "未定义别名 全局" contract_parse_body "$bad_alias" "$TDIR/x.json"

missing_r="$(printf '%s\n' "$GOOD_ISSUE" | sed 's/\[A1 → R1\]/[A1 → R9]/')"
expect_fail "引用不存在的 R" contract_parse_body "$missing_r" "$TDIR/x.json"

only_fence="$(cat <<'EOF'
<!-- task-contract:v1 -->

## 背景
x

## 目标
y

## 要求 / 实现细节

```
### [R1] 只在围栏里
```

## 验收

```
1. [A1 → R1] 只在围栏里
```

## 允许改动范围

- `0-meta/lib/new/`
EOF
)"
expect_fail "围栏伪字段" contract_parse_body "$only_fence" "$TDIR/x.json"

no_scope="$(printf '%s\n' "$GOOD_ISSUE" | awk '/^## 允许改动范围/{print;print "";print "没有路径";next}1')"
# 上面仍可能留下原路径。直接删段内反引号路径：
no_scope2="$(printf '%s\n' "$GOOD_ISSUE" | awk '
  /^## 允许改动范围/{s=1;print;next}
  s && /^## /{s=0}
  s{print "说明文字"; next}
  {print}
')"
expect_fail "无法解析的 scope" contract_parse_body "$no_scope2" "$TDIR/x.json"

# 背景/分支建议不进契约 json；改目标/R/范围会变
canon0="$(jq -cS 'del(.issue,.title)' "$CANON")"
bg2="$(printf '%s\n' "$GOOD_ISSUE" | sed 's/这段说明不进 digest/背景改了/')"
JSON2="$TDIR/c2.json"
contract_parse_body "$bg2" "$JSON2"
c2="$(contract_canonical_json "$JSON2" | jq -cS 'del(.issue,.title)')"
[ "$c2" = "$canon0" ] && ok || bad "改背景不应改变契约 json"

br2="$(printf '%s\n' "$GOOD_ISSUE" | sed 's/meta\/example/meta\/other/')"
contract_parse_body "$br2" "$JSON2"
c2="$(contract_canonical_json "$JSON2" | jq -cS 'del(.issue,.title)')"
[ "$c2" = "$canon0" ] && ok || bad "改分支建议不应改变契约 json"

goal2="$(printf '%s\n' "$GOOD_ISSUE" | sed 's/建立可校验的 Task Contract/目标改了/')"
contract_parse_body "$goal2" "$JSON2"
c2="$(contract_canonical_json "$JSON2" | jq -cS 'del(.issue,.title)')"
[ "$c2" != "$canon0" ] && ok || bad "改目标必须改变契约 json"

r2="$(printf '%s\n' "$GOOD_ISSUE" | sed 's/必须解析目标/R1 换义了/')"
contract_parse_body "$r2" "$JSON2"
c2="$(contract_canonical_json "$JSON2" | jq -cS 'del(.issue,.title)')"
[ "$c2" != "$canon0" ] && ok || bad "改 R 必须改变契约 json"

scope2="$(printf '%s\n' "$GOOD_ISSUE" | sed 's|0-meta/schema/|0-meta/docs/|')"
contract_parse_body "$scope2" "$JSON2"
c2="$(contract_canonical_json "$JSON2" | jq -cS 'del(.issue,.title)')"
[ "$c2" != "$canon0" ] && ok || bad "改范围必须改变契约 json"

# A6/A7 Checkpoint
CK="$TDIR/ck.md"
cat > "$CK" <<EOF
${TASK_CHECKPOINT_MARK}
claim_actor=alpha
## Checkpoint

| 项 | 值 |
| --- | --- |
| Issue | o/r#1 |
| Contract | ${BLOB} |
| Agent | grok |
| claim_actor | alpha |
| 分支 | meta/example |
| 工作树 | /tmp/wt |
| HEAD | abc |
| 工作区状态 | 干净 |
| 允许范围 | 0-meta/lib/new/ 0-meta/schema/ |
| Project | Tasks #1 Status=In progress |
| PR | 无 |
| 下一步 | 开发 |

### R 进度

| ID | 状态 | 证据 |
| --- | --- | --- |
| R1 | pending | 尚未验证 |
| R2 | pending | 尚未验证 |

### A 执行

| ID | 状态 | 证据 |
| --- | --- | --- |
| A1 | pending | 尚未验证 |
| A2 | pending | 尚未验证 |
| A3 | pending | 尚未验证 |

### 验证证据

\`\`\`
尚未验证
\`\`\`
EOF
expect_ok "首次 Checkpoint 尚未验证" contract_checkpoint_validate "$(cat "$CK")" "$JSON" "$BLOB"

ck_ready="$(printf '%s\n' "$(cat "$CK")" | awk '
  {print}
  /\| 工作区状态 \|/ {
    print "| 交接状态 | review-ready |"
    print "| HEAD 持久化 | committed + clean HEAD |"
    print "| 工作树分类 | untracked=0 / unstaged=0 / staged=0 |"
  }
')"
expect_ok "completion 字段完整且 clean" contract_checkpoint_validate "$ck_ready" "$JSON" "$BLOB"

ck_completion_missing="$(printf '%s\n' "$ck_ready" | grep -v '工作树分类')"
expect_fail "completion 字段不完整" contract_checkpoint_validate "$ck_completion_missing" "$JSON" "$BLOB"

ck_completion_dirty="$(printf '%s\n' "$ck_ready" | sed 's/untracked=0 \/ unstaged=0 \/ staged=0/untracked=1 \/ unstaged=0 \/ staged=0/')"
expect_fail "review-ready dirty 分类" contract_checkpoint_validate "$ck_completion_dirty" "$JSON" "$BLOB"

ck_completion_bad_state="$(printf '%s\n' "$ck_ready" | sed 's/| 交接状态 | review-ready |/| 交接状态 | finished |/')"
expect_fail "completion 状态非法" contract_checkpoint_validate "$ck_completion_bad_state" "$JSON" "$BLOB"

ck_bad="$(printf '%s\n' "$(cat "$CK")" | awk '!/\| Contract \|/')"
expect_fail "删 Contract" contract_checkpoint_validate "$ck_bad" "$JSON" "$BLOB"

ck_na="$(printf '%s\n' "$(cat "$CK")" | sed 's/| A1 | pending | 尚未验证 |/| A1 | not-applicable | 空 |/')"
expect_fail "无适用条件标 N/A" contract_checkpoint_validate "$ck_na" "$JSON" "$BLOB"

ck_a3="$(printf '%s\n' "$(cat "$CK")" | sed 's/| A3 | pending | 尚未验证 |/| A3 | not-applicable | 条件未触发：演示 |/')"
expect_ok "有适用条件的 N/A" contract_checkpoint_validate "$ck_a3" "$JSON" "$BLOB"

# 同步不得覆盖开发验证
oldck="$(cat "$CK")"
newck="$(printf '%s\n' "$oldck" | awk '
  $0=="### 验证证据"{p=1}
  p && /尚未验证/{print "push origin meta/example @ abc"; print "PR https://github.com/o/r/pull/9"; next}
  {print}
')"
merged="$(contract_checkpoint_preserve_evidence "$oldck" "$newck")"
printf '%s\n' "$merged" | grep -Fq '尚未验证' && ok || bad "同步覆盖了开发验证"
ev="$(printf '%s\n' "$merged" | awk '$0=="### 验证证据"{s=1;next} s&&/^### /{exit} s')"
printf '%s\n' "$ev" | grep -q 'push origin' && bad "保留证据后仍留下 push 日志" || ok

# A8/A9 Review
min_ok="$(cat <<'EOF'
### 最小充分审查

- 审查代码与调用点：contract.sh 与调用点
- 复用证据：contract.test.sh
- 新增验证：定向 ablation
- 覆盖范围：parser、ledger、trusted extract，而非复制授权范围
- 未执行的大范围验证：全仓库 test
- 剩余风险：v1 不宣称抵御同权限主体
EOF
)"
REV="$TDIR/rev.md"
cat > "$REV" <<EOF
${TASK_REVIEW_MARK}
review_actor=beta
claim_actor=alpha
Self-review=no
## Review

| 项 | 值 |
| --- | --- |
| Verdict | 通过 |
| reviewed HEAD | \`deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\` |
| 范围 | 0-meta/lib/new/ 0-meta/schema/ |
| Squash-Title | \`feat(meta): 建立 Task Contract\` |
| Issue | o/r#1 |
| Contract | ${BLOB} |
| review_actor | beta |
| claim_actor | alpha |
| Self-review | no |

### 通过理由

实现了 parser 与 ledger。

### 证据

\`\`\`
0-meta/lib/new/contract.test.sh
\`\`\`

${min_ok}

### Contract 对照

- R1：满足。实现 contract_parse_body。
- R2：满足。规范化契约字段覆盖目标、R、A 与范围。
- A1：通过。缺字段测试。
- A2：通过。背景不变 digest。
- A3：通过。digest 覆盖范围。
EOF
expect_ok "完整 Review" contract_review_validate "$(cat "$REV")" "$JSON" "$BLOB" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

rev_miss="$(printf '%s\n' "$(cat "$REV")" | grep -v 'A2：')"
expect_fail "少一个 A" contract_review_validate "$rev_miss" "$JSON" "$BLOB" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

rev_dup="$(printf '%s\n' "$(cat "$REV")"; echo '- A1：通过。重复')"
expect_fail "重复 A 结论" contract_review_validate "$rev_dup" "$JSON" "$BLOB" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

rev_fail="$(printf '%s\n' "$(cat "$REV")" | sed 's/A1：通过/A1：不通过/')"
expect_fail "必要验收不通过仍 Verdict=通过" contract_review_validate "$rev_fail" "$JSON" "$BLOB" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

rev_risk="$(printf '%s\n' "$(cat "$REV")" | sed 's/剩余风险：v1 不宣称抵御同权限主体/剩余风险：A1 失败但接受风险/')"
# 对照仍写通过，不应因剩余风险放行失败项——对照仍是通过，本条保持成功；
# 真正失败靠对照。把对照改失败再写剩余风险：
rev_risk2="$(printf '%s\n' "$rev_fail" | sed 's/剩余风险：v1 不宣称抵御同权限主体/剩余风险：接受 A1 失败/')"
expect_fail "失败写进剩余风险" contract_review_validate "$rev_risk2" "$JSON" "$BLOB" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

for drop in '覆盖范围' '未执行的大范围验证' '剩余风险'; do
  dropped="$(printf '%s\n' "$(cat "$REV")" | grep -v "$drop")"
  expect_fail "删除 $drop" contract_review_validate "$dropped" "$JSON" "$BLOB" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
done
rev_nocontract="$(printf '%s\n' "$(cat "$REV")" | awk '!/^\| Contract \|/')"
expect_fail "删除 Contract" contract_review_validate "$rev_nocontract" "$JSON" "$BLOB" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

# 覆盖范围复制授权范围
rev_copy="$(printf '%s\n' "$(cat "$REV")" | sed 's/覆盖范围：parser、ledger、trusted extract，而非复制授权范围/覆盖范围：0-meta\/lib\/new\/ 0-meta\/schema\//')"
expect_fail "覆盖范围复制授权范围" contract_review_validate "$rev_copy" "$JSON" "$BLOB" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

# A10 真实 diff
repo="$TDIR/repo"
mkdir -p "$repo/0-meta/lib/new" "$repo/secret"
git init -q -b main "$repo"
git -C "$repo" config user.email t@example.com
git -C "$repo" config user.name t
git -C "$repo" config core.hooksPath /dev/null
printf 'a\n' > "$repo/0-meta/lib/new/ok.sh"
printf 's\n' > "$repo/secret/x"
git -C "$repo" add 0-meta secret
git -C "$repo" commit -qm init
git -C "$repo" checkout -qb task
printf 'b\n' >> "$repo/0-meta/lib/new/ok.sh"
printf 't\n' >> "$repo/secret/x"
git -C "$repo" add -A
git -C "$repo" commit -qm task
expect_fail "越界 diff" contract_require_diff_in_scope "$repo" main HEAD "0-meta/lib/new/"
git -C "$repo" reset -q HEAD~1
printf 'b\n' >> "$repo/0-meta/lib/new/ok.sh"
git -C "$repo" add 0-meta/lib/new/ok.sh
git -C "$repo" commit -qm 'in scope'
expect_ok "范围内 diff" contract_require_diff_in_scope "$repo" main HEAD "0-meta/lib/new/"

# A12 PR
PR="$TDIR/pr.md"
cat > "$PR" <<EOF
${TASK_PR_MARK_BEGIN}
## 任务身份

| 项 | 值 |
| --- | --- |
| Issue | o/r#1 |
| Contract | ${BLOB} |
| reviewed HEAD | deadbeefdeadbeefdeadbeefdeadbeefdeadbeef |

## 变更摘要

parser 与 ledger。

## 验证摘要

contract.test.sh

Fixes #1
${TASK_PR_MARK_END}
EOF
expect_ok "完整 PR" contract_pr_validate "$(cat "$PR")" 1 "$BLOB" deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
expect_fail "PR 缺 Fixes" contract_pr_validate "$(printf '%s\n' "$(cat "$PR")" | grep -v Fixes)" 1 "$BLOB" deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
expect_fail "PR Contract 不一致" contract_pr_validate "$(cat "$PR")" 1 deadbeef deadbeefdeadbeefdeadbeefdeadbeefdeadbeef

# A20 历史夹具 + 字段漂移
hist_issue="$TDIR/hist-issue.md"
hist_ck="$TDIR/hist-ck.md"
hist_rv="$TDIR/hist-rv.md"
hist_pr="$TDIR/hist-pr.md"
printf '%s\n' "$GOOD_ISSUE" > "$hist_issue"
printf '%s\n' "$(cat "$CK")" > "$hist_ck"
printf '%s\n' "$(cat "$REV")" > "$hist_rv"
printf '%s\n' "$(cat "$PR")" > "$hist_pr"
contract_parse_body "$(cat "$hist_issue")" "$TDIR/hist.json" && ok || bad "历史 Issue 夹具"
contract_checkpoint_validate "$(cat "$hist_ck")" "$JSON" "$BLOB" && ok || bad "历史 Checkpoint 夹具"
contract_review_validate "$(cat "$hist_rv")" "$JSON" "$BLOB" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" && ok || bad "历史 Review 夹具"
contract_pr_validate "$(cat "$hist_pr")" 1 "$BLOB" deadbeefdeadbeefdeadbeefdeadbeefdeadbeef && ok || bad "历史 PR 夹具"

# 故意删字段：模板 / parser / 调用点
need() {
  local file="$1" pat="$2"
  if ! grep -Fq -- "$pat" "$file"; then
    echo "✗ $file 缺少：$pat" >&2
    fail=$((fail+1))
  else
    ok
  fi
}
need "$ROOT/0-meta/schema/task-contract.v1.yaml" 'task-contract/v1'
need "$ROOT/0-meta/lib/new/contract.sh" 'contract_parse_body'
need "$ROOT/0-meta/lib/new/contract.sh" 'contract_canonical_json'
need "$ROOT/0-meta/lib/new/contract.sh" 'contract_main_blob'
need "$ROOT/0-meta/lib/new/contract.sh" 'contract_stale'
need "$ROOT/0-meta/lib/new/contract.sh" 'contract_warn_if_issue_differs'
need "$ROOT/0-meta/lib/new/contract.sh" 'contract_require_diff_in_scope'
need "$ROOT/0-meta/lib/new/contract.sh" 'not-applicable'
need "$ROOT/0-meta/docs/08-task-contract.md" '已由契约进 main(#27)取代'

# 无 R/A 证据：现行 Checkpoint 门禁
ck_noev="$(printf '%s\n' "$(cat "$CK")" | sed 's/尚未验证 |$/ |/')"
expect_fail "无 R/A 证据" contract_checkpoint_validate "$ck_noev" "$JSON" "$BLOB"

# A23 / R14：canonical start card 结构与产品 adapter identity。只测构造，不启动 Agent。
prompt_has_required() {
  local p="$1" token="$2"
  local card
  card="$(task_start_card_extract <<< "$p")" || return 1
  printf '%s\n' "$card" | grep -Fq 'Issue | o/r#23' || return 1
  printf '%s\n' "$card" | grep -Fq 'https://github.com/o/r/issues/23' || return 1
  printf '%s\n' "$card" | grep -Fq 'Worktree | `/tmp/wt`' || return 1
  printf '%s\n' "$card" | grep -Fq '0-meta/lib/new/' || return 1
  printf '%s\n' "$card" | grep -Fq 'Derived state | In progress' || return 1
  printf '%s\n' "$card" | grep -Fq 'origin/main:0-meta/tasks/23/contract.json' || return 1
  printf '%s\n' "$card" | grep -Fq 'Next canonical command | new z dev' || return 1
  printf '%s\n' "$card" | grep -Fq 'HEAD | `unknown`' || return 1
  printf '%s\n' "$card" | grep -Eq 'canonical-start-card' || return 1
  printf '%s\n' "$p" | grep -Eq '请先读|07/08|0-meta/policy\.yaml' && return 1 || true
  [ "$(printf '%s\n' "$p" | awk 'NF{last=$0} END{print last}')" = "$token" ] || return 1
  local ntok
  ntok="$(printf '%s\n' "$p" | grep -cxF "$token")"
  [ "$ntok" = 1 ] || return 1
}

count_zdev_mentions() {
  printf '%s\n' "$1" | grep -oE '/zdev|\$zdev|\bzdev\b' | grep -c . || true
}

PA="$(task_agent_start_prompt A 23 'https://github.com/o/r/issues/23' /tmp/wt '0-meta/lib/new/' 'In progress' o r grok)"
PB="$(task_agent_start_prompt B 23 'https://github.com/o/r/issues/23' /tmp/wt '0-meta/lib/new/' 'In progress' o r grok)"
PC="$(task_agent_start_prompt C 23 'https://github.com/o/r/issues/23' /tmp/wt '0-meta/lib/new/' 'In progress' o r grok)"
PCodex="$(task_agent_start_prompt C 23 'https://github.com/o/r/issues/23' /tmp/wt '0-meta/lib/new/' 'In progress' o r codex)"
expect_ok "prompt A 必要字段" prompt_has_required "$PA" '/zdev'
expect_ok "prompt B 必要字段" prompt_has_required "$PB" '/zdev'
expect_ok "prompt C 必要字段" prompt_has_required "$PC" '/zdev'
expect_ok "prompt C Codex token" prompt_has_required "$PCodex" '$zdev'

card_a="$(task_start_card_extract <<< "$PA")"
card_b="$(task_start_card_extract <<< "$PB")"
card_c="$(task_start_card_extract <<< "$PC")"
card_codex="$(task_start_card_extract <<< "$PCodex")"
[ "$card_a" = "$card_b" ] && [ "$card_b" = "$card_c" ] && [ "$card_c" = "$card_codex" ] \
  && ok || bad "Grok/Codex 与 A/B/C 必须使用同一张 start card"
card_bytes="$(printf '%s' "$card_c" | wc -c | tr -d ' ')"
[ "$card_bytes" -le 2048 ] && ok || bad "start card 超出 2048 bytes：$card_bytes"
[ -z "$TASK_PROMPT_READS" ] && ok || bad "生产 prompt 不应强制加载额外文件"

# 产品差异只存在于末行机械 trigger（Grok /zdev、Codex \$zdev）。
[ "$TASK_START_PROMPT_VARIANT" = C ] && ok || bad "生产应变体 C"
need "$ROOT/0-meta/lib/new/claim.sh" 'task_agent_start_prompt "${TASK_START_PROMPT_VARIANT}"'
need "$ROOT/0-meta/lib/new/claim.sh" 'exec "$agent_bin" "$prompt"'

# 消融不得改领取/Checkpoint/Status 语义（领取入口在 claim.sh）
need "$ROOT/0-meta/lib/new/claim.sh" '"$TASK_STATUS_READY")'
need "$ROOT/.agents/skills/zdev/SKILL.md" '不领取任务、不改 Project 状态'

# A22 既有门禁未被放宽
need "$ROOT/.agents/skills/z-lib.sh" 'z_require_current_main'
need "$ROOT/.agents/skills/z-lib.sh" 'force-with-lease'
need "$ROOT/.agents/skills/zmerge/scripts/merge-lib.sh" '--match-head-commit'
need "$ROOT/.agents/skills/zmerge/scripts/squash-merge.sh" 'human-merge'
need "$ROOT/.agents/skills/zmerge/SKILL.md" '删除工作树或本地分支'
need "$ROOT/.agents/skills/zmerge/scripts/merge-lib.sh" 'z_required_contexts'
need "$ROOT/0-meta/templates/z-workflow.md" 'Squash-Title'

# ── #27：契约进 main（A1–A10）──────────────────────────

git_fixture() {
  local dest="$1"
  mkdir -p "$dest"
  git init -q -b main "$dest"
  git -C "$dest" config user.email t@example.com
  git -C "$dest" config user.name t
  git -C "$dest" config core.hooksPath /dev/null
}

# A9 → R5 B1：说明句反引号不算路径
b1="$(printf '%s\n' "$GOOD_ISSUE" | awk '
  /^## 允许改动范围/{print; print ""; print "参考 `a/b` 的写法，不要当路径。"; next}
  {print}
')"
contract_parse_body "$b1" "$TDIR/b1.json" && ok || bad "A9 含说明句反引号应仍能解析"
b1scope="$(contract_scope_from_json "$TDIR/b1.json")"
printf '%s\n' "$b1scope" | grep -Fxq '0-meta/lib/new' && ok || bad "A9 列表项路径应保留"
if printf '%s\n' "$b1scope" | grep -Fxq 'a/b'; then
  bad "A9 说明句反引号不应解析为路径"
else
  ok
fi

# A1 / A2：approve 成功 / no-op / 缺 A→R 无提交
a1bare="$TDIR/a1.origin.git"
a1ws="$TDIR/a1.ws"
git init -q --bare "$a1bare"
git_fixture "$a1ws"
printf 'init\n' > "$a1ws/README"
git -C "$a1ws" add README
git -C "$a1ws" commit -qm init
git -C "$a1ws" remote add origin "$a1bare"
git -C "$a1ws" push -q -u origin main
git -C "$a1ws" config "url.${a1bare}.insteadOf" 'https://github.com/o/r.git'
git -C "$a1ws" remote set-url origin 'https://github.com/o/r.git'
a1head="$(git -C "$a1ws" rev-parse HEAD)"
blob1="$(contract_approve "$a1ws" 1 "$GOOD_ISSUE" "feat(meta): t" "https://github.com/o/r/issues/1" main)" \
  && [[ "$blob1" =~ ^[a-f0-9]{40}$ ]] && ok || bad "A1 approve 应写出 blob"
[ -f "$a1ws/0-meta/tasks/1/contract.md" ] && [ -f "$a1ws/0-meta/tasks/1/contract.json" ] \
  && ok || bad "A1 应写入两个契约文件"
a1head2="$(git -C "$a1ws" rev-parse HEAD)"
[ "$a1head2" != "$a1head" ] && ok || bad "A1 应新增提交"
git -C "$a1ws" diff-tree --no-commit-id --name-only -r HEAD | grep -Fxq '0-meta/tasks/1/contract.md' \
  && git -C "$a1ws" diff-tree --no-commit-id --name-only -r HEAD | grep -Fxq '0-meta/tasks/1/contract.json' \
  && ok || bad "A1 提交应只含两个契约文件（或至少含这两个）"
blob1b="$(contract_approve "$a1ws" 1 "$GOOD_ISSUE" "feat(meta): t" "https://github.com/o/r/issues/1" main)"
[ "$blob1b" = "$blob1" ] && [ "$(git -C "$a1ws" rev-parse HEAD)" = "$a1head2" ] \
  && ok || bad "A1 再次 approve 应 no-op"

# A1 Status：ROOT 临时切到夹具，gh stub
mkdir -p "$TDIR/bin"
GH_ISSUE_JSON="$TDIR/gh-issue.json"
GH_STATUS_LOG="$TDIR/gh-status.log"
: > "$GH_STATUS_LOG"
jq -n --arg b "$GOOD_ISSUE" --arg title "feat(meta): t" '{
  data: { repository: { issue: {
    id: "I1", title: $title, url: "https://github.com/o/r/issues/1", body: $b,
    labels: { nodes: [] },
    projectItems: { nodes: [{
      id: "item1",
      project: { id: "p1", number: 1, title: "Tasks" },
      fieldValueByName: {
        name: "Backlog", optionId: "opt-b",
        field: { id: "f1", options: [
          {id:"opt-b", name:"Backlog"},
          {id:"opt-r", name:"Ready"}
        ]}
      }
    }]}
  }}}
}' > "$GH_ISSUE_JSON"
cat > "$TDIR/bin/gh" <<'EOF'
#!/bin/bash
if [ "$1" = api ] && [ "$2" = graphql ]; then
  cat "$GH_ISSUE_JSON"
  exit 0
fi
if [ "$1" = project ] && [ "$2" = item-edit ]; then
  printf '%s\n' "$*" >> "$GH_STATUS_LOG"
  echo '{}'
  exit 0
fi
echo "unexpected gh: $*" >&2
exit 1
EOF
chmod +x "$TDIR/bin/gh"
old_root="$ROOT"
old_path="$PATH"
ROOT="$a1ws"
PATH="$TDIR/bin:$PATH"
export GH_ISSUE_JSON GH_STATUS_LOG
if ( task_approve 1 >/dev/null ); then
  grep -q 'opt-r' "$GH_STATUS_LOG" && ok || bad "A1 Status 应写成 Ready"
else
  bad "A1 task_approve 应成功（契约已在 main）"
fi
: > "$GH_STATUS_LOG"
jq -n --arg b "$GOOD_ISSUE" --arg title "feat(meta): t" '{
  data: { repository: { issue: {
    id: "I1", title: $title, url: "https://github.com/o/r/issues/1", body: $b,
    labels: { nodes: [] },
    projectItems: { nodes: [{
      id: "item1",
      project: { id: "p1", number: 1, title: "Tasks" },
      fieldValueByName: {
        name: "In progress", optionId: "opt-p",
        field: { id: "f1", options: [
          {id:"opt-b", name:"Backlog"},
          {id:"opt-r", name:"Ready"},
          {id:"opt-p", name:"In progress"}
        ]}
      }
    }]}
  }}}
}' > "$GH_ISSUE_JSON"
if ( task_approve 1 >/dev/null ); then
  [ ! -s "$GH_STATUS_LOG" ] && ok || bad "A1 In progress 不应写 Status（GH_STATUS_LOG 应空）"
else
  bad "A1 In progress 时 task_approve 应返回 0"
fi
ROOT="$old_root"
PATH="$old_path"

# A2 缺 A→R：无提交
a2ws="$TDIR/a2.ws"
git_fixture "$a2ws"
printf 'init\n' > "$a2ws/README"
git -C "$a2ws" add README
git -C "$a2ws" commit -qm init
git -C "$a2ws" remote add origin "$a1bare"
git -C "$a2ws" fetch -q origin
git -C "$a2ws" reset -q --hard origin/main
a2head="$(git -C "$a2ws" rev-parse HEAD)"
if contract_approve "$a2ws" 2 "$no_arrow" "t" "u" main >/dev/null 2>"$TDIR/a2.err"; then
  bad "A2 缺 A→R 应拒绝"
else
  ok
fi
printf '%s\n' "$(cat "$TDIR/a2.err")" | grep -q 'A→R' && ok || bad "A2 应指出缺 A→R"
[ "$(git -C "$a2ws" rev-parse HEAD)" = "$a2head" ] && ok || bad "A2 不得产生提交"
[ ! -e "$a2ws/0-meta/tasks/2/contract.json" ] && ok || bad "A2 不得写契约文件"

# A3 缺契约：load 拒绝且末行为 approve 命令
a3ws="$TDIR/a3.ws"
git clone -q "$a1bare" "$a3ws"
git -C "$a3ws" config user.email t@example.com
git -C "$a3ws" config user.name t
git -C "$a3ws" config core.hooksPath /dev/null
a3out="$TDIR/a3.err"
if contract_load_main "$a3ws" 99 "$TDIR/a3.json" main 2>"$a3out"; then
  bad "A3 缺契约应拒绝"
else
  ok
fi
[ "$(tail -n 1 "$a3out")" = "new task approve 99" ] && ok || bad "A3 末行应为 new task approve 99（实际：$(tail -n 1 "$a3out")）"

# A4 新 blob → stale
goal_new="$(printf '%s\n' "$GOOD_ISSUE" | sed 's/建立可校验的 Task Contract/目标改了一次/')"
blob2="$(contract_approve "$a1ws" 1 "$goal_new" "feat(meta): t2" "https://github.com/o/r/issues/1" main)" \
  && [ "$blob2" != "$blob1" ] && ok || bad "A4 修订应产生新 blob"
if contract_stale "$blob1" "$blob2" "Review"; then ok; else bad "A4 旧 blob 应为 stale"; fi
if contract_stale "$blob2" "$blob2" "Review"; then bad "A4 当前 blob 不应 stale"; else ok; fi

# A5 生产路径旧协议残留为 0；现行门禁仍在
a5_hits="$(
  {
    find "$ROOT/0-meta/lib/new" "$ROOT/0-meta/bin" "$ROOT/.agents/skills" \
      "$ROOT/0-meta/templates" "$ROOT/0-meta/schema" \
      \( -name '*.sh' -o -name '*.md' -o -name '*.yaml' \) -type f
    printf '%s\n' "$ROOT/0-meta/AGENTS.md"
  } | while IFS= read -r f; do
    case "$f" in
      *.test.sh) continue ;;
    esac
    grep -E 'contract_ledger_|contract_ruleset_|contract_official|contract_bootstrap|contract_is_bootstrap_sha|expand-scope|TASK_REVISION_MARK|task-contract-revision|revision_marker|in_digest|trusted_ruleset' "$f" \
      && printf 'FILE %s\n' "$f"
    true
  done
)"
if [ -z "$a5_hits" ]; then ok
else bad "A5 生产路径仍有旧协议残留：$a5_hits"; fi
if [ ! -e "$ROOT/.agents/skills/zdev/scripts/expand-scope.sh" ]; then ok
else bad "A5 expand-scope.sh 应已删除"; fi
need "$ROOT/0-meta/lib/new/contract.sh" 'contract_main_blob'
need "$ROOT/0-meta/lib/new/contract.sh" 'contract_stale'
need "$ROOT/0-meta/lib/new/contract.sh" 'contract_warn_if_issue_differs'

# 五处门禁读源
need "$ROOT/0-meta/lib/new/task.sh" 'contract_load_main'
need "$ROOT/.agents/skills/z-lib.sh" 'z_contract_load'
need "$ROOT/.agents/skills/z-lib.sh" 'contract_load_main'
need "$ROOT/.agents/skills/zdev/scripts/wip-commit.sh" 'z_load'
need "$ROOT/.agents/skills/zreview/scripts/publish-review.sh" 'z_load'
need "$ROOT/.agents/skills/zmerge/scripts/merge-lib.sh" 'contract_stale'
need "$ROOT/.agents/skills/zmerge/scripts/merge-lib.sh" 'contract_fetch_main'

# A6 fetch 不可达 → hard stop，不用本地陈旧副本
a6ws="$TDIR/a6.ws"
git clone -q "$a1bare" "$a6ws"
git -C "$a6ws" config user.email t@example.com
git -C "$a6ws" config user.name t
# 此时本地已有 origin/main 与契约；把 origin 指到不可达地址
git -C "$a6ws" remote set-url origin 'https://127.0.0.1:1/unreachable.git'
if contract_fetch_main "$a6ws" main 2>/dev/null; then
  bad "A6 fetch 不可达应 hard stop"
else
  ok
fi
if contract_load_main "$a6ws" 1 "$TDIR/a6.json" main 2>/dev/null; then
  bad "A6 load 不可达不得用本地陈旧契约"
else
  ok
fi

# A7 范围写 0-meta/ 时 0-meta/tasks/x 仍拒
a7scope=$'0-meta/\n'
if contract_paths_in_scope $'0-meta/tasks/x\n' "$a7scope" >/dev/null; then
  bad "A7 0-meta/tasks/x 应被拒绝"
else
  ok
fi
if task_path_hard_denied '0-meta/tasks/x'; then ok; else bad "A7 hard-deny 应命中 0-meta/tasks/x"; fi

# A8 含空格、重命名两端、type change
a8="$TDIR/a8.repo"
git_fixture "$a8"
mkdir -p "$a8/0-meta/lib/new" "$a8/extra"
printf 'a\n' > "$a8/0-meta/lib/new/ok.sh"
printf 'b\n' > "$a8/extra/old name.sh"
printf 'c\n' > "$a8/extra/file with space.txt"
printf 'd\n' > "$a8/extra/typed"
git -C "$a8" add .
git -C "$a8" commit -qm init
git -C "$a8" mv "extra/old name.sh" "extra/renamed.sh"
printf 'c2\n' > "$a8/extra/file with space.txt"
rm "$a8/extra/typed"
ln -s "../0-meta/lib/new/ok.sh" "$a8/extra/typed"
printf 'a2\n' > "$a8/0-meta/lib/new/ok.sh"
git -C "$a8" add -A
a8paths="$(contract_staged_paths "$a8")"
printf '%s\n' "$a8paths" | grep -Fxq 'extra/old name.sh' && ok || bad "A8 应含重命名旧路径"
printf '%s\n' "$a8paths" | grep -Fxq 'extra/renamed.sh' && ok || bad "A8 应含重命名新路径"
printf '%s\n' "$a8paths" | grep -Fxq 'extra/file with space.txt' && ok || bad "A8 含空格路径应是单条"
printf '%s\n' "$a8paths" | grep -Fxq 'extra/typed' && ok || bad "A8 应含 type change"
printf '%s\n' "$a8paths" | grep -Fxq '0-meta/lib/new/ok.sh' && ok || bad "A8 应含范围内修改"
if contract_paths_in_scope "$a8paths" $'0-meta/lib/new/\n' >/dev/null; then
  bad "A8 越界路径应 hard fail"
else
  ok
fi

# A10 三类文档只剩 Contract 字段；squash-body 校验通过
for f in \
  "$ROOT/0-meta/templates/task-contract-checkpoint.md" \
  "$ROOT/0-meta/templates/task-contract-review.md" \
  "$ROOT/0-meta/templates/z-workflow.md"
do
  grep -Fq '| Contract |' "$f" && ok || bad "A10 $f 应有 Contract 字段"
  if grep -Eq 'Contract revision|Contract digest|\| Ruleset \||in_digest|revision_marker|trusted_ruleset' "$f"; then
    bad "A10 $f 仍有旧协议字段"
  else
    ok
  fi
done
# shellcheck source=/dev/null
. "$ROOT/.agents/skills/zmerge/scripts/squash-body.sh"
a10issue="$TDIR/a10-issue.md"
a10ck="$TDIR/a10-ck.md"
a10rv="$TDIR/a10-rv.md"
a10pr="$TDIR/a10-pr.md"
printf '%s\n' "$GOOD_ISSUE" > "$a10issue"
printf '%s\n' "$(cat "$CK")" > "$a10ck"
printf '%s\n' "$(cat "$REV")" > "$a10rv"
printf '%s\n' "$(cat "$PR")" > "$a10pr"
Z_CONTRACT_BLOB="$BLOB"
Z_SQUASH_STRICT=1
if z_compose_squash_body "$a10issue" "$a10ck" "$a10rv" "$a10pr" 1 9 > "$TDIR/a10-body.txt" \
   && z_validate_squash_body "$(cat "$TDIR/a10-body.txt")" 1 9; then
  ok
else
  bad "A10 squash-body 校验应通过"
fi
printf '%s\n' "$(cat "$TDIR/a10-body.txt")" | grep -Fq "Contract: ${BLOB}" && ok || bad "A10 squash body 应含 Contract blob"
Z_CONTRACT_JSON="$JSON"
if z_compose_squash_body "$a10issue" "$a10ck" "$a10rv" "$a10pr" 1 9 > "$TDIR/a10-body-json.txt" \
   && z_validate_squash_body "$(cat "$TDIR/a10-body-json.txt")" 1 9; then
  ok
else
  bad "A10 设 Z_CONTRACT_JSON 后 squash-body 应通过"
fi
while IFS= read -r p; do
  [ -n "$p" ] || continue
  printf '%s\n' "$(cat "$TDIR/a10-body-json.txt")" | grep -Fxq -- "- ${p}" \
    && ok || bad "A10 body 范围 bullet 应含 ${p}"
done < <(jq -r '.scope[]' "$JSON")
unset Z_CONTRACT_JSON

# 警告路径不得污染 reason_code / detail
METRICS_REASON_CODE='x.y'
LAST_ERR='keep'
contract_warn_if_issue_differs '这段不是合法契约' "$JSON" 1 >/dev/null 2>&1 || true
[ "$METRICS_REASON_CODE" = 'x.y' ] && [ "$LAST_ERR" = 'keep' ] \
  && ok || bad "warn_if_issue_differs 不得改 METRICS_REASON_CODE/LAST_ERR（code=${METRICS_REASON_CODE} err=${LAST_ERR}）"
METRICS_REASON_CODE=""
LAST_ERR=""

if [ "$fail" -ne 0 ]; then
  echo "✗ contract 定向测试失败：${fail} 项（通过 ${pass}）" >&2
  exit 1
fi
echo "✓ contract 定向测试通过（${pass}）"
