#!/usr/bin/env bash
# 度量定向测试：事件结构 / 位置 / 失败不阻断 / loaded_bytes 口径 / new metrics 汇总。
# 不调用真实 gh / orca；文件位置用 XDG_STATE_HOME 指到临时目录。
set -Eeuo pipefail
export LC_COLLATE=C
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/0-meta/lib/new/core.sh"
# shellcheck source=/dev/null
. "$ROOT/0-meta/lib/new/task.sh"
# shellcheck source=/dev/null
. "$ROOT/0-meta/lib/new/metrics.sh"
trap tmp_cleanup EXIT

fail=0
pass=0
TDIR=""
tmp_mkd TDIR metrics-test
export XDG_STATE_HOME="$TDIR/state"
FILE="$(metrics_file)"

ok() { pass=$((pass+1)); }
bad() { echo "✗ $*" >&2; fail=$((fail+1)); }
expect_eq() { # name expected actual
  if [ "$2" = "$3" ]; then ok; else bad "$1: 期望 [$2] 实际 [$3]"; fi
}
expect_true() { if eval "$2"; then ok; else bad "$1"; fi; }

# ── T1 位置：不在仓库内，由 XDG_STATE_HOME 决定 ──────────────────────────
expect_eq "T1 文件位置" "$TDIR/state/$(metrics_identity_dir)/metrics.jsonl" "$FILE"
expect_true "T1 身份不是写死的 projects2" '[ "$(metrics_identity_dir)" != projects2 ]'
case "$FILE" in "$ROOT"/*) bad "T1 度量文件落在仓库内：$FILE" ;; *) ok ;; esac

# ── T2 事件结构：ok 与 fail 各一行，字段齐全，fail 的 reason_code 非空 ─────
ROOT_SAVE="$ROOT"
metrics_begin zdev.wip-commit
metrics_set issue "o/r#26"
metrics_set agent codex
metrics_set labels '["meta"]'
metrics_set task_class framework
metrics_emit ok "" >/dev/null
metrics_begin zdev.wip-commit
metrics_set issue "o/r#26"
metrics_set task_class framework
LAST_ERR=$'    \e[31m✗ staged 路径越界：x/y\e[0m'
err_code z.staged_out_of_scope "$LAST_ERR"
metrics_finish 1 >/dev/null
expect_eq "T2 两行" 2 "$(wc -l < "$FILE" | tr -d ' ')"
expect_true "T2 每行都是 JSON" 'jq -e . "$FILE" >/dev/null 2>&1'
keys="$(head -1 "$FILE" | jq -r 'keys_unsorted | join(",")')"
expect_eq "T2 字段集合" "ts,issue,entry,result,reason_code,detail,duration_ms,agent,head,labels,task_class,loaded_bytes" "$keys"
expect_eq "T2 ok 行 reason_code 为空" "" "$(sed -n 1p "$FILE" | jq -r .reason_code)"
expect_eq "T2 ok 行 detail 为空" "" "$(sed -n 1p "$FILE" | jq -r .detail)"
expect_eq "T2 fail 行 reason_code" "z.staged_out_of_scope" "$(sed -n 2p "$FILE" | jq -r .reason_code)"
expect_true "T2 fail 行 reason_code 无空格无中文" 'sed -n 2p "$FILE" | jq -r .reason_code | grep -Eq "^[a-z0-9][a-z0-9._-]*$"'
expect_eq "T2 fail 行 detail 去掉 ANSI 与前缀" "staged 路径越界：x/y" "$(sed -n 2p "$FILE" | jq -r .detail)"
expect_eq "T2 fail 行 result" fail "$(sed -n 2p "$FILE" | jq -r .result)"
expect_eq "T2 labels 数组" '["meta"]' "$(sed -n 1p "$FILE" | jq -c .labels)"
expect_eq "T2 task_class" framework "$(sed -n 1p "$FILE" | jq -r .task_class)"
expect_true "T2 duration_ms 为数字" '[ "$(sed -n 1p "$FILE" | jq -r ".duration_ms|type")" = number ]'
expect_true "T2 ts 为 UTC ISO 8601" 'sed -n 1p "$FILE" | jq -r .ts | grep -Eq "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"'
expect_eq "T2 非 claim 事件 loaded_bytes 为 null" null "$(sed -n 1p "$FILE" | jq -r .loaded_bytes)"

# ── T3 同一入口只写一次；die 消息优先于 c_err ─────────────────────────────
metrics_emit ok "" >/dev/null
expect_eq "T3 重复 emit 不再写" 2 "$(wc -l < "$FILE" | tr -d ' ')"
metrics_begin zsync.sync-main
LAST_ERR="次要"; DIE_MSG="主因"
metrics_finish 1 >/dev/null
expect_eq "T3 die 消息优先" "主因" "$(tail -1 "$FILE" | jq -r .detail)"
expect_eq "T3 未赋码则 action.unclassified" "sync-main.unclassified" "$(tail -1 "$FILE" | jq -r .reason_code)"
DIE_MSG=""; LAST_ERR=""; METRICS_REASON_CODE=""
metrics_begin zsync.sync-main
metrics_finish 7 >/dev/null
expect_eq "T3 无消息时记退出码" "exit=7" "$(tail -1 "$FILE" | jq -r .detail)"
expect_true "T3 unclassified 无空格无中文" 'tail -1 "$FILE" | jq -r .reason_code | grep -Eq "^[a-z0-9][a-z0-9._-]*$"'

# ── T4 失败不阻断：文件只读、目录不可建，都只警告且返回 0 ──────────────────
n_before="$(wc -l < "$FILE" | tr -d ' ')"
chmod a-w "$FILE"
metrics_begin zdev.wip-commit
out="$(metrics_emit ok "" 2>&1)"; rc=$?
chmod u+w "$FILE"
expect_eq "T4 只读文件返回 0" 0 "$rc"
expect_eq "T4 只读文件不新增行" "$n_before" "$(wc -l < "$FILE" | tr -d ' ')"
expect_true "T4 只读文件一行警告" '[ "$(printf "%s\n" "$out" | grep -c "度量写入失败")" = 1 ]'
mkdir -p "$TDIR/ro" && chmod a-w "$TDIR/ro"
out="$(XDG_STATE_HOME="$TDIR/ro/sub" bash -c '
  . "'"$ROOT"'/0-meta/lib/new/core.sh"; . "'"$ROOT"'/0-meta/lib/new/metrics.sh"
  metrics_begin x.y; metrics_emit ok ""; echo "rc=$?"' 2>&1)"
chmod u+w "$TDIR/ro"
expect_true "T4 目录不可建返回 0" 'printf "%s\n" "$out" | grep -q "rc=0"'
expect_true "T4 目录不可建一行警告" '[ "$(printf "%s\n" "$out" | grep -c "度量写入失败")" = 1 ]'

# doctor 对已存在文件也必须检查可追加；目录可写不等于 metrics 文件可写。
chmod a-w "$FILE"
set +e
doctor_out="$(metrics_doctor "$FILE" 2>&1)"; doctor_rc=$?
set -e
chmod u+w "$FILE"
expect_eq "T4 doctor 只读文件失败" 1 "$doctor_rc"
expect_true "T4 doctor 报告文件不可写" 'printf "%s\n" "$doctor_out" | grep -q "metrics 文件不可写"'

# ── T5 loaded_bytes 只量 canonical start card 与强制加载项 ────────────────
WT="$TDIR/wt"; mkdir -p "$WT/0-meta"
printf '%s' "$(head -c 1234 /dev/zero | tr '\0' a)" > "$WT/AGENTS.md"
printf '%s' "$(head -c 4321 /dev/zero | tr '\0' b)" > "$WT/0-meta/policy.yaml"
prompt="$(task_agent_start_prompt C 26 https://x/26 "$WT" "0-meta/lib/new/" "In progress" o r codex)"
card="$(task_start_card_extract <<< "$prompt")"
want="$(printf '%s' "$card" | wc -c | tr -d ' ')"
expect_eq "T5 loaded_bytes 口径" "$want" "$(task_prompt_loaded_bytes "$WT" "$prompt")"
expect_true "T5 prompt 含 start card marker" 'printf "%s" "$prompt" | grep -qF "canonical-start-card"'
expect_true "T5 prompt 不要求先读规则全文" '! printf "%s" "$prompt" | grep -qF "请先读"'
rm "$WT/0-meta/policy.yaml"
expect_eq "T5 后续按需文件不计" "$want" "$(task_prompt_loaded_bytes "$WT" "$prompt")"

# ── T6 claim 事件带 loaded_bytes ─────────────────────────────────────────
metrics_begin new-task.claim
metrics_set agent grok
metrics_set loaded_bytes 91234
metrics_emit ok "" >/dev/null
expect_eq "T6 claim loaded_bytes" 91234 "$(tail -1 "$FILE" | jq -r .loaded_bytes)"

# ── T7 new metrics：≥3 种 entry 的样例 → 汇总含 framework:business 与 reason_code
S="$TDIR/sample.jsonl"
cat > "$S" <<'EOF'
{"ts":"2026-09-06T10:00:00Z","issue":"o/r#26","entry":"new-task.claim","result":"ok","reason_code":"","detail":"","duration_ms":3200,"agent":"codex","head":"abc","labels":["meta"],"task_class":"framework","loaded_bytes":91234}
{"ts":"2026-09-06T11:00:00Z","issue":"o/r#40","entry":"new-task.claim","result":"ok","reason_code":"","detail":"","duration_ms":2800,"agent":"grok","head":"abc","labels":["code"],"task_class":"business","loaded_bytes":88000}
{"ts":"2026-09-06T11:30:00Z","issue":"o/r#41","entry":"new-task.claim","result":"ok","reason_code":"","detail":"","duration_ms":2500,"agent":"grok","head":"abc","labels":["data"],"task_class":"business","loaded_bytes":87000}
{"ts":"2026-09-06T12:00:00Z","issue":"o/r#40","entry":"zdev.wip-commit","result":"fail","reason_code":"z.staged_out_of_scope","detail":"越界","duration_ms":400,"agent":"grok","head":"abc","labels":["code"],"task_class":"business","loaded_bytes":null}
{"ts":"2026-09-06T12:05:00Z","issue":"o/r#40","entry":"zdev.wip-commit","result":"fail","reason_code":"z.staged_out_of_scope","detail":"越界","duration_ms":420,"agent":"grok","head":"abc","labels":["code"],"task_class":"business","loaded_bytes":null}
{"ts":"2026-09-06T12:10:00Z","issue":"o/r#40","entry":"zdev.wip-commit","result":"ok","reason_code":"","detail":"","duration_ms":900,"agent":"grok","head":"abc","labels":["code"],"task_class":"business","loaded_bytes":null}
{"ts":"2026-08-01T12:10:00Z","issue":"o/r#3","entry":"zmerge.squash-merge","result":"ok","reason_code":"","detail":"","duration_ms":9000,"agent":"","head":"abc","labels":["meta"],"task_class":"framework","loaded_bytes":null}
坏行
EOF
rep="$(cmd_metrics --file "$S" 2>&1)"; rc=$?
expect_eq "T7 报告退出 0" 0 "$rc"
expect_true "T7 计数行" 'printf "%s\n" "$rep" | grep -q "zdev.wip-commit	ok=1	fail=2"'
expect_true "T7 p50/p90" 'printf "%s\n" "$rep" | grep -q "new-task.claim	2800	3200"'
expect_true "T7 loaded_bytes 中位数" 'printf "%s\n" "$rep" | grep -q "样本 3	中位数 88000"'
expect_true "T7 framework:business" 'printf "%s\n" "$rep" | grep -q "framework:business = 2:2"'
expect_true "T7 reason_code 计数" 'printf "%s\n" "$rep" | grep -q "^2×	z.staged_out_of_scope"'
expect_true "T7 坏行只警告" 'printf "%s\n" "$rep" | grep -q "无法解析的行"'
expect_true "T7 坏行健康未知" 'printf "%s\n" "$rep" | grep -q "采集健康未知/失败"'
expect_true "T7 坏行不再绿色健康" '! printf "%s\n" "$rep" | grep -q "✓ 采集健康"'
rep7="$(cmd_metrics --file "$S" --since 7d 2>&1)"
expect_true "T7 --since 过滤旧事件" '! printf "%s\n" "$rep7" | grep -q "zmerge.squash-merge"'
: > "$TDIR/empty.jsonl"
rep="$(cmd_metrics --file "$TDIR/empty.jsonl" 2>&1)"; rc=$?
expect_eq "T7 空文件退出 0" 0 "$rc"
expect_true "T7 空文件打印路径" 'printf "%s\n" "$rep" | grep -qF "$TDIR/empty.jsonl"'

# ── T8 入口名派生；度量代码不联网 ───────────────────────────────────────
# shellcheck source=/dev/null
. "$ROOT/.agents/skills/z-lib.sh"
expect_eq "T8 入口名" "zmerge.squash-merge" "$(Z_ENTRY_SCRIPT=/x/.agents/skills/zmerge/scripts/squash-merge.sh z_entry_name)"
expect_true "T8 metrics.sh 无网络调用" '! grep -Eq "(^|[^a-z_])(gh|curl|wget) |git (fetch|push|pull|ls-remote)" "$ROOT/0-meta/lib/new/metrics.sh"'

# ── T9 task_class：按允许范围推导，不按 label ────────────────────────────
expect_eq "T9 0-meta 为 framework" framework "$(metrics_task_class_from_scope "0-meta/lib/new/")"
expect_eq "T9 .agents 为 framework" framework "$(metrics_task_class_from_scope ".agents/skills/z-lib.sh")"
expect_eq "T9 祖先 . 为 framework" framework "$(metrics_task_class_from_scope ".")"
expect_eq "T9 1-code 为 business" business "$(metrics_task_class_from_scope "1-code/foo")"
expect_eq "T9 混有 0-meta 为 framework" framework "$(metrics_task_class_from_scope "1-code/foo 0-meta/docs/")"
expect_eq "T9 空范围留空" "" "$(metrics_task_class_from_scope "")"

# ── T10 control-plane / task-runtime 分类：doctor 与 summary 同一口径 ──────
CLASSIFIED="$TDIR/classified.jsonl"
cat > "$CLASSIFIED" <<'EOF'
{"ts":"2026-09-07T10:00:00Z","issue":"","entry":"new-task.approve","result":"ok","reason_code":"","detail":"","duration_ms":0,"agent":"","head":"abc","labels":[],"task_class":"","loaded_bytes":null}
{"ts":"2026-09-07T10:01:00Z","issue":"","entry":"new-task.bind","result":"ok","reason_code":"","detail":"","duration_ms":0,"agent":"","head":"abc","labels":[],"task_class":"","loaded_bytes":null}
{"ts":"2026-09-07T10:02:00Z","issue":"o/r#control-approve","entry":"new-task.approve","result":"ok","reason_code":"","detail":"","duration_ms":0,"agent":"","head":"abc","labels":[],"task_class":"framework","loaded_bytes":null}
{"ts":"2026-09-07T10:03:00Z","issue":"o/r#control-bind","entry":"new-task.bind","result":"ok","reason_code":"","detail":"","duration_ms":0,"agent":"","head":"abc","labels":[],"task_class":"business","loaded_bytes":null}
{"ts":"2026-09-07T10:04:00Z","issue":"o/r#26","entry":"new-task.claim","result":"ok","reason_code":"","detail":"","duration_ms":0,"agent":"","head":"abc","labels":[],"task_class":"framework","loaded_bytes":null}
{"ts":"2026-09-07T10:05:00Z","issue":"o/r#40","entry":"zdev.wip-commit","result":"ok","reason_code":"","detail":"","duration_ms":0,"agent":"","head":"abc","labels":[],"task_class":"business","loaded_bytes":null}
EOF
set +e
classified_doctor_out="$(metrics_doctor "$CLASSIFIED" 2>&1)"; classified_doctor_rc=$?
set -e
classified_summary_out="$(cmd_metrics --file "$CLASSIFIED" 2>&1)"; classified_summary_rc=$?
expect_eq "T10 approve/bind 空字段 doctor 通过" 0 "$classified_doctor_rc"
expect_eq "T10 doctor / summary 共享健康结论" 0 "$classified_summary_rc"
expect_true "T10 doctor 健康通过" 'printf "%s\n" "$classified_doctor_out" | grep -q "✓ 采集健康"'
expect_true "T10 summary 健康通过" 'printf "%s\n" "$classified_summary_out" | grep -q "✓ 采集健康"'
expect_true "T10 control-plane 不计入 framework:business" 'printf "%s\n" "$classified_summary_out" | grep -q "framework:business = 1:1"'

CONTROL_ONLY="$TDIR/control-only.jsonl"
head -n 2 "$CLASSIFIED" > "$CONTROL_ONLY"
set +e
control_only_out="$(metrics_doctor "$CONTROL_ONLY" 2>&1)"; control_only_rc=$?
set -e
expect_eq "T10 只有 control-plane doctor 通过" 0 "$control_only_rc"
expect_true "T10 只有 control-plane 输出明确" 'printf "%s\n" "$control_only_out" | grep -q "control-plane"'
expect_true "T10 只有 control-plane 不说只有 framework" '! printf "%s\n" "$control_only_out" | grep -q "只有 framework"'

claim_empty_issue="$TDIR/claim-empty-issue.jsonl"
sed 's/"o\/r#26"/""/' "$CLASSIFIED" | sed '/"new-task.claim"/!d' > "$claim_empty_issue"
claim_empty_class="$TDIR/claim-empty-class.jsonl"
sed 's/"framework"/""/' "$CLASSIFIED" | sed '/"new-task.claim"/!d' > "$claim_empty_class"
z_empty_reason="$TDIR/z-empty-reason.jsonl"
sed 's/"result":"ok"/"result":"fail"/' "$CLASSIFIED" \
  | sed '/"zdev.wip-commit"/!d' > "$z_empty_reason"
set +e
metrics_doctor "$claim_empty_issue" >/dev/null 2>&1; claim_empty_issue_rc=$?
metrics_doctor "$claim_empty_class" >/dev/null 2>&1; claim_empty_class_rc=$?
metrics_doctor "$z_empty_reason" >/dev/null 2>&1; z_empty_reason_rc=$?
set -e
expect_eq "T10 claim 空 issue 失败" 1 "$claim_empty_issue_rc"
expect_eq "T10 claim 空 task_class 失败" 1 "$claim_empty_class_rc"
expect_eq "T10 z fail 空 reason_code 失败" 1 "$z_empty_reason_rc"

# ── T11 Agent exec 失败：claim 已成立的 success 事件不可被 reopen 成第二行 ──
AGENT_WT="$TDIR/agent-wt"; mkdir -p "$AGENT_WT"
printf 'fixture\n' > "$AGENT_WT/AGENTS.md"
claim_before="$(jq -s '[.[] | select(.entry == "new-task.claim")] | length' "$FILE")"
set +e
(
  export ROOT XDG_STATE_HOME
  . "$ROOT/0-meta/lib/new/core.sh"
  . "$ROOT/0-meta/lib/new/task.sh"
  . "$ROOT/0-meta/lib/new/metrics.sh"
  trap 'metrics_exit_trap $?' EXIT
  metrics_begin new-task.claim
  metrics_set issue o/r#42
  metrics_set agent codex
  metrics_set labels '["meta"]'
  metrics_set task_class framework
  agent=codex
  wt="$AGENT_WT"
  number=42
  issue_url=https://github.com/o/r/issues/42
  scope=0-meta/lib/new
  owner=o
  repo=r
  agent_bin="$TDIR/no-such-agent"
  TASK_STATUS_PROGRESS="In progress"
  TMPDIRS=""
  task_claim_start_agent >/dev/null 2>&1
); exec_rc=$?
set -e
claim_after="$(jq -s '[.[] | select(.entry == "new-task.claim")] | length' "$FILE")"
expect_true "T11 exec 失败返回非 0" '[ "$exec_rc" -ne 0 ]'
expect_eq "T11 exec 失败只追加一行" "$(( claim_before + 1 ))" "$claim_after"
expect_eq "T11 唯一 claim 事件仍为 success" ok "$(tail -1 "$FILE" | jq -r .result)"
expect_true "T11 exec 失败不 reopen" '! grep -Fq "metrics_reopen" "$ROOT/0-meta/lib/new/claim.sh"'

ROOT="$ROOT_SAVE"
echo "metrics.test.sh: 通过 ${pass}，失败 ${fail}"
[ "$fail" = 0 ]
