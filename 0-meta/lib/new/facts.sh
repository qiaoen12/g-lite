# 共享且有界的阶段事实：dev / fix / review 共用。
# 由 task.sh 加载，不要单独执行。不引入新数据库或完整 event sourcing。
# 当前 tip 由唯一 marker 标识；历史全文按需读取，不按 created_at 猜最新。

TASK_CHECKPOINT_HISTORY_MARK='<!-- new-task-checkpoint-history -->'
TASK_REVIEW_HISTORY_MARK='<!-- new-task-review-history -->'
TASK_FACTS_CARD_BEGIN='<!-- stage-facts -->'
TASK_FACTS_CARD_END='<!-- /stage-facts -->'
TASK_FACT_PROVENANCE_VERSION=1
TASK_FACTS_READY=0

: "${TASK_BOOTSTRAP_NEXT_FIX:=new z fix}"
: "${TASK_BOOTSTRAP_NEXT_PASS_HUMAN:=new z pr}"
: "${TASK_BOOTSTRAP_NEXT_PASS_AUTO:=new z merge}"

task_facts_reset() {
  TASK_FACTS_READY=0
  FACT_COMMENTS_JSON=
  FACT_CK_JSON=
  FACT_CK_BODY=
  FACT_CK_ID=
  FACT_CK_HEAD=
  FACT_CK_BLOB=
  FACT_CK_SHAPE=
  FACT_CK_COMPLETION=
  FACT_CK_PR=
  FACT_CK_NEXT=
  FACT_RV_JSON=
  FACT_RV_BODY=
  FACT_RV_ID=
  FACT_RV_VERDICT=
  FACT_RV_HEAD=
  FACT_RV_BLOB=
  FACT_RV_SELF=
  FACT_REVIEW_APPLICABILITY=
  FACT_HEAD_KIND=
  FACT_FINDINGS=
  FACT_DIFF_SUMMARY=
  FACT_PROVENANCE_SUMMARY=
  FACT_HIST_REFS=
  FACT_NEXT=
  FACT_BIND=
  FACT_LABELS=
}

task_facts_trim() {
  local s="${1:-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

task_facts_history_mark_for() {
  case "$1" in
    "$TASK_CHECKPOINT_MARK") printf '%s\n' "$TASK_CHECKPOINT_HISTORY_MARK" ;;
    "$TASK_REVIEW_MARK") printf '%s\n' "$TASK_REVIEW_HISTORY_MARK" ;;
    *) return 1 ;;
  esac
}

task_facts_kind_for_mark() {
  case "$1" in
    "$TASK_CHECKPOINT_MARK"|"$TASK_CHECKPOINT_HISTORY_MARK") printf '%s\n' checkpoint ;;
    "$TASK_REVIEW_MARK"|"$TASK_REVIEW_HISTORY_MARK") printf '%s\n' review ;;
    *) return 1 ;;
  esac
}

task_facts_role_from_entry() {
  local script="${Z_ENTRY_SCRIPT:-}"
  case "$script" in
    *'/zdev/'*) printf '%s\n' dev ;;
    *'/zfix/'*) printf '%s\n' fix ;;
    *'/zreview/'*) printf '%s\n' review ;;
    *)
      case "${TASK_FACT_STAMP_ROLE:-}" in
        claim|dev|fix|review) printf '%s\n' "$TASK_FACT_STAMP_ROLE" ;;
        *) printf '%s\n' unknown ;;
      esac
      ;;
  esac
}

task_facts_unique_from_json() {
  local js="$1" mark="$2" label="$3"
  local matches n
  if ! matches="$(task_comments_matching "$js" "$mark")"; then
    return 1
  fi
  n="$(printf '%s' "$matches" | jq 'length')"
  if ! [[ "$n" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  if [ "$n" -gt 1 ]; then
    err_code task.comment_ambiguous "    ✗ 找到 ${n} 条 ${label} 评论，拒绝猜测哪一条"
    return 1
  fi
  if [ "$n" = 0 ]; then
    printf '\n'
    return 0
  fi
  printf '%s' "$matches" | jq -c '.[0]'
}

task_facts_source_ref_valid() {
  local ref="${1:-}"
  case "$ref" in
    ''|*[[:space:]]*|*'|'*|*'`'*|*'='*|*@*) return 1 ;;
  esac
  [ "${#ref}" -ge 8 ] || return 1
  [[ "$ref" =~ ^[0-9]+$ ]] && return 1
  return 0
}

task_facts_capture_path() {
  local wt="$1" gd
  [ -n "$wt" ] || return 1
  gd="$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  printf '%s\n' "$gd/g-lite/execution.json"
}

# 受控 hook/launcher 的 receipt。任务 Agent 改 execution.json 或
# captured_by=hook 字符串本身不能把它变成新的 verified identity。
task_facts_trusted_capture_path() {
  local wt="$1" gd
  [ -n "$wt" ] || return 1
  gd="$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  printf '%s\n' "$gd/g-lite/execution.trusted.json"
}

task_facts_capture_json_get() {
  local js="$1" key="$2"
  printf '%s' "$js" | jq -r --arg k "$key" '.[$k] // empty'
}

task_facts_capture_lineage_connects() {
  local lineage_ref="$1" old_ref="$2" old_lin="$3"
  [ -n "$lineage_ref" ] || return 1
  [ "$lineage_ref" = "$old_ref" ] && return 0
  [ -n "$old_lin" ] && [ "$lineage_ref" = "$old_lin" ] && return 0
  return 1
}

# 不信任文件自报的 captured_by。verified 只来自受控 writer 的 trusted
# receipt，且必须与当前 capture 的 type/ref/lineage 一致。
# 同 worktree 已有 trusted identity 时，换 source_ref 且无 parent
# lineage → unknown-unverified，并保留原 identity。
task_facts_read_capture() {
  local wt="$1" path trusted_path js trusted t_type t_ref t_lin t_role
  FACT_CAPTURE_SOURCE_TYPE=
  FACT_CAPTURE_SOURCE_REF=
  FACT_CAPTURE_LINEAGE_REF=
  FACT_CAPTURE_ROLE=
  FACT_CAPTURE_BY=
  FACT_CAPTURE_STATE=unknown-unverified
  path="$(task_facts_capture_path "$wt" 2>/dev/null)" || return 0
  [ -f "$path" ] || return 0
  js="$(cat "$path" 2>/dev/null || true)"
  [ -n "$js" ] || return 0
  printf '%s' "$js" | jq -e . >/dev/null 2>&1 || {
    err_code facts.capture_invalid "execution capture 不是合法 JSON，拒绝猜测"
    return 1
  }
  FACT_CAPTURE_SOURCE_TYPE="$(task_facts_capture_json_get "$js" source_type)"
  FACT_CAPTURE_SOURCE_REF="$(task_facts_capture_json_get "$js" source_ref)"
  FACT_CAPTURE_LINEAGE_REF="$(task_facts_capture_json_get "$js" lineage_ref)"
  FACT_CAPTURE_ROLE="$(task_facts_capture_json_get "$js" role)"
  FACT_CAPTURE_BY="$(task_facts_capture_json_get "$js" captured_by)"
  trusted_path="$(task_facts_trusted_capture_path "$wt" 2>/dev/null)" || return 0
  [ -f "$trusted_path" ] || return 0
  trusted="$(cat "$trusted_path" 2>/dev/null || true)"
  [ -n "$trusted" ] || return 0
  printf '%s' "$trusted" | jq -e . >/dev/null 2>&1 || {
    err_code facts.capture_invalid "trusted execution receipt 不是合法 JSON，拒绝猜测"
    return 1
  }
  t_type="$(task_facts_capture_json_get "$trusted" source_type)"
  t_ref="$(task_facts_capture_json_get "$trusted" source_ref)"
  t_lin="$(task_facts_capture_json_get "$trusted" lineage_ref)"
  t_role="$(task_facts_capture_json_get "$trusted" role)"
  if [ "$FACT_CAPTURE_SOURCE_TYPE" != "$t_type" ] \
     || [ "$FACT_CAPTURE_SOURCE_REF" != "$t_ref" ] \
     || [ "$FACT_CAPTURE_LINEAGE_REF" != "$t_lin" ]; then
    if ! task_facts_capture_lineage_connects \
         "$FACT_CAPTURE_LINEAGE_REF" "$t_ref" "$t_lin"; then
      FACT_CAPTURE_SOURCE_TYPE="$t_type"
      FACT_CAPTURE_SOURCE_REF="$t_ref"
      FACT_CAPTURE_LINEAGE_REF="$t_lin"
      [ -n "$t_role" ] && FACT_CAPTURE_ROLE="$t_role"
    fi
    FACT_CAPTURE_STATE=unknown-unverified
    return 0
  fi
  case "$FACT_CAPTURE_SOURCE_TYPE" in
    cursor-conversation|codex-session) ;;
    *)
      FACT_CAPTURE_STATE=unknown-unverified
      return 0
      ;;
  esac
  task_facts_source_ref_valid "$FACT_CAPTURE_SOURCE_REF" || {
    FACT_CAPTURE_STATE=unknown-unverified
    return 0
  }
  if [ -n "$FACT_CAPTURE_LINEAGE_REF" ] && ! task_facts_source_ref_valid "$FACT_CAPTURE_LINEAGE_REF"; then
    err_code facts.capture_lineage_invalid "execution capture 的 lineage_ref 非法"
    return 1
  fi
  FACT_CAPTURE_STATE=verified
  return 0
}

# 普通 task runtime / 测试夹具写入。无论 captured_by 填什么，
# 都不能单独产生 verified receipt。
task_facts_write_capture() {
  local wt="$1" source_type="$2" source_ref="$3" lineage_ref="$4" role="$5" captured_by="$6"
  local path dest
  path="$(task_facts_capture_path "$wt")" || return 1
  dest="$(dirname "$path")"
  mkdir -p "$dest" || return 1
  [ -n "$captured_by" ] || captured_by=runtime
  jq -n \
    --arg provenance_version "$TASK_FACT_PROVENANCE_VERSION" \
    --arg source_type "$source_type" \
    --arg source_ref "$source_ref" \
    --arg lineage_ref "$lineage_ref" \
    --arg role "$role" \
    --arg captured_by "$captured_by" \
    '{
      provenance_version:$provenance_version,
      source_type:$source_type,
      source_ref:$source_ref,
      lineage_ref:$lineage_ref,
      role:$role,
      captured_by:$captured_by
    }' > "$path"
}

# 仅受控 hook/launcher（及模拟它们的测试）可写 verified receipt。
# 同 worktree 已有 trusted identity 时，更换 source_ref 必须显式带
# parent/continuation lineage；否则只写 unverified 文件，保留原 receipt。
task_facts_write_verified_capture() {
  local wt="$1" source_type="$2" source_ref="$3" lineage_ref="$4" role="$5"
  local trusted_path old old_ref old_lin allow=1
  task_facts_write_capture "$wt" "$source_type" "$source_ref" "$lineage_ref" "$role" hook \
    || return 1
  trusted_path="$(task_facts_trusted_capture_path "$wt")" || return 1
  if [ -f "$trusted_path" ]; then
    old="$(cat "$trusted_path" 2>/dev/null || true)"
    old_ref="$(task_facts_capture_json_get "$old" source_ref)"
    old_lin="$(task_facts_capture_json_get "$old" lineage_ref)"
    if [ -n "$old_ref" ] && [ "$source_ref" != "$old_ref" ]; then
      if ! task_facts_capture_lineage_connects "$lineage_ref" "$old_ref" "$old_lin"; then
        allow=0
      fi
    fi
  fi
  [ "$allow" = 1 ] || return 0
  mkdir -p "$(dirname "$trusted_path")" || return 1
  cp "$(task_facts_capture_path "$wt")" "$trusted_path"
}

# 必填字段出现时必须恰好 1 个；可选字段最多 1 个。重复/冲突 fail-closed，
# 不 silently 取第一个。legacy 正文完全没有这些字段时保持 unknown。
task_facts_check_provenance_fields() {
  local body="$1"
  local key n any=0
  local required="provenance_version source_type role verification_state"
  local optional="source_ref lineage_ref repository task issue contract contract_blob head candidate_head"
  for key in $required $optional; do
    n="$(task_machine_field_count "$body" "$key")"
    if [ "$n" -gt 1 ]; then
      return 1
    fi
  done
  for key in provenance_version source_type source_ref lineage_ref role verification_state; do
    n="$(task_machine_field_count "$body" "$key")"
    if [ "$n" -ge 1 ]; then
      any=1
      break
    fi
  done
  [ "$any" = 1 ] || return 0
  for key in $required; do
    n="$(task_machine_field_count "$body" "$key")"
    if [ "$n" != 1 ]; then
      return 1
    fi
  done
  return 0
}

task_facts_parse_provenance() {
  local body="$1"
  FACT_PROV_VERSION=
  FACT_PROV_SOURCE_TYPE=
  FACT_PROV_SOURCE_REF=
  FACT_PROV_LINEAGE_REF=
  FACT_PROV_ROLE=
  FACT_PROV_STATE=
  if ! task_facts_check_provenance_fields "$body"; then
    FACT_PROV_STATE=conflict
    return 1
  fi
  FACT_PROV_VERSION="$(task_machine_field "$body" provenance_version)"
  FACT_PROV_SOURCE_TYPE="$(task_machine_field "$body" source_type)"
  FACT_PROV_SOURCE_REF="$(task_machine_field "$body" source_ref)"
  FACT_PROV_LINEAGE_REF="$(task_machine_field "$body" lineage_ref)"
  FACT_PROV_ROLE="$(task_machine_field "$body" role)"
  FACT_PROV_STATE="$(task_machine_field "$body" verification_state)"
  if [ -z "$FACT_PROV_VERSION" ] && [ -z "$FACT_PROV_SOURCE_TYPE" ] \
     && [ -z "$FACT_PROV_SOURCE_REF" ] && [ -z "$FACT_PROV_STATE" ]; then
    FACT_PROV_STATE=unknown-unverified
    [ -n "$FACT_PROV_ROLE" ] || FACT_PROV_ROLE=unknown
    return 0
  fi
  case "$FACT_PROV_STATE" in
    verified)
      case "$FACT_PROV_SOURCE_TYPE" in
        cursor-conversation|codex-session)
          if task_facts_source_ref_valid "$FACT_PROV_SOURCE_REF"; then
            return 0
          fi
          ;;
      esac
      FACT_PROV_STATE=unknown-unverified
      ;;
    unknown-unverified|'') FACT_PROV_STATE=unknown-unverified ;;
    *) FACT_PROV_STATE=unknown-unverified ;;
  esac
  return 0
}

task_facts_strip_machine_keys() {
  local body="$1"
  shift
  local key
  printf '%s\n' "$body" | awk -v keys=" $* " '
    {
      line=$0
      sub(/\r$/, "", line)
      split(line, a, "=")
      if (index(line, "=")==0) { print line; next }
      key=a[1]
      if (index(keys, " " key " ")) next
      print line
    }
  '
}

task_facts_stamp_provenance() {
  local body="$1" role="$2" wt="${3:-}"
  local stamped type="unknown" ref="" lineage="" state="unknown-unverified"
  body="$(task_facts_strip_machine_keys "$body" \
    provenance_version source_type source_ref lineage_ref role verification_state)"
  if [ -n "$wt" ]; then
    task_facts_read_capture "$wt" || return 1
    if [ "$FACT_CAPTURE_STATE" = verified ]; then
      type="$FACT_CAPTURE_SOURCE_TYPE"
      ref="$FACT_CAPTURE_SOURCE_REF"
      lineage="$FACT_CAPTURE_LINEAGE_REF"
      state=verified
      if [ -n "$FACT_CAPTURE_ROLE" ]; then
        role="$FACT_CAPTURE_ROLE"
      fi
    fi
  fi
  [ -n "$role" ] || role=unknown
  stamped="$(printf '%s\n' "$body" | awk -v mark_ck="$TASK_CHECKPOINT_MARK" \
    -v mark_rv="$TASK_REVIEW_MARK" \
    -v ver="$TASK_FACT_PROVENANCE_VERSION" \
    -v type="$type" -v ref="$ref" -v lineage="$lineage" \
    -v role="$role" -v state="$state" '
    {
      print
      if ($0==mark_ck || $0==mark_rv) {
        print "provenance_version=" ver
        print "source_type=" type
        if (ref != "") print "source_ref=" ref
        if (lineage != "") print "lineage_ref=" lineage
        print "role=" role
        print "verification_state=" state
      }
    }
  ')"
  printf '%s\n' "$stamped"
}

task_facts_classify_checkpoint() {
  local body="$1" agent delivery completion start
  agent="$(task_review_table_field "$body" Agent)"
  delivery="$(task_review_table_field "$body" "交付时间")"
  completion="$(task_review_table_field "$body" "交接状态")"
  start="$(task_review_table_field "$body" "启动时间")"
  if [ -n "$delivery" ] && [ -z "$agent" ]; then
    printf '%s\n' delivery
    return 0
  fi
  if [ -n "$completion" ]; then
    printf '%s\n' completion
    return 0
  fi
  if [ -n "$start" ]; then
    printf '%s\n' claim
    return 0
  fi
  printf '%s\n' unknown
}

# claim-only：领取记录，不是形成 candidate 的 dev/fix execution。
# 不能把「没有 role」当成 claim；v1.0.0 / #13 completion 仍可能没有新 role。
task_facts_is_claim_only() {
  local body="$1" role start completion delivery
  role="$(task_machine_field "$body" role)"
  case "$role" in
    dev|fix|review) return 1 ;;
    claim) return 0 ;;
  esac
  completion="$(task_review_table_field "$body" "交接状态")"
  delivery="$(task_review_table_field "$body" "交付时间")"
  [ -n "$completion" ] && return 1
  [ -n "$delivery" ] && return 1
  start="$(task_review_table_field "$body" "启动时间")"
  [ -n "$start" ] && return 0
  case "$body" in
    *'由 `new task claim`'*|*'由 `new task grok`'*|*'由 `new task codex`'*)
      return 0 ;;
  esac
  return 1
}

# Reviewer independence 只覆盖形成当前 candidate 的 dev/fix execution。
# 打印：dev | fix | claim | review | delivery | unknown
# unknown = recognized legacy 或无法分类；调用方必须纳入并 fail-closed。
task_facts_independence_class() {
  local body="$1" shape
  task_facts_parse_provenance "$body" || return 1
  case "$FACT_PROV_ROLE" in
    dev) printf '%s\n' dev; return 0 ;;
    fix) printf '%s\n' fix; return 0 ;;
    review) printf '%s\n' review; return 0 ;;
    claim)
      shape="$(task_facts_classify_checkpoint "$body")"
      case "$shape" in
        completion) printf '%s\n' unknown; return 0 ;;
        delivery) printf '%s\n' delivery; return 0 ;;
      esac
      printf '%s\n' claim
      return 0
      ;;
  esac
  case "$body" in
    *"$TASK_REVIEW_MARK"*|*"$TASK_REVIEW_HISTORY_MARK"*)
      printf '%s\n' review
      return 0
      ;;
  esac
  shape="$(task_facts_classify_checkpoint "$body")"
  case "$shape" in
    delivery) printf '%s\n' delivery; return 0 ;;
    completion)
      printf '%s\n' unknown
      return 0
      ;;
  esac
  if task_facts_is_claim_only "$body"; then
    printf '%s\n' claim
    return 0
  fi
  printf '%s\n' unknown
}

task_facts_strip_section() {
  local body="$1" heading="$2"
  printf '%s\n' "$body" | awk -v h="$heading" '
    BEGIN { skip=0 }
    $0 == "### " h { skip=1; next }
    skip && /^### / { skip=0 }
    skip { next }
    { print }
  '
}

task_facts_history_rows() {
  local body="$1"
  printf '%s\n' "$body" | tr -d '\r' | awk '
    BEGIN { s=0 }
    $0 == "### Historical facts" { s=1; next }
    s && /^### / { exit }
    s && /^\|/ {
      line=$0
      n=split(line, a, "|")
      if (n<6) next
      id=a[2]; cid=a[3]; kind=a[4]; role=a[5]; head=a[6]; blob=a[7]
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", id)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", cid)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", kind)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", role)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", head)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", blob)
      if (id=="fact_id" || id=="---" || id ~ /^-+$/) next
      if (head ~ /^`.*`$/) { sub(/^`/, "", head); sub(/`$/, "", head) }
      if (blob ~ /^`.*`$/) { sub(/^`/, "", blob); sub(/`$/, "", blob) }
      if (id=="" || cid=="") next
      print id "\t" cid "\t" kind "\t" role "\t" head "\t" blob
    }
  '
}

task_facts_render_history_section() {
  local rows="$1" line id cid kind role head blob
  printf '%s\n' '### Historical facts'
  printf '%s\n' ''
  printf '%s\n' '| fact_id | comment_id | kind | role | HEAD | Contract |'
  printf '%s\n' '| --- | --- | --- | --- | --- | --- |'
  while IFS=$'\t' read -r id cid kind role head blob; do
    [ -n "$id" ] || continue
    printf '| %s | %s | %s | %s | `%s` | `%s` |\n' \
      "$id" "$cid" "$kind" "$role" "$head" "$blob"
  done <<< "$rows"
}

task_facts_attach_history_row() {
  local body="$1" id="$2" cid="$3" kind="$4" role="$5" head="$6" blob="$7"
  local old new_row
  body="$(task_facts_strip_section "$body" "Historical facts")"
  body="${body%"$'\n'"}"
  old="$(task_facts_history_rows "$1")"
  new_row="$(printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$cid" "$kind" "$role" "$head" "$blob")"
  if [ -n "$old" ]; then
    old="$(printf '%s\n%s\n' "$new_row" "$old")"
  else
    old="$new_row"
  fi
  printf '%s\n\n%s\n' "$body" "$(task_facts_render_history_section "$old")"
}

task_facts_set_prev_fields() {
  local body="$1" tip_id="$2" prev_id="$3"
  body="$(task_facts_strip_machine_keys "$body" fact_id prev_fact_id)"
  printf '%s\n' "$body" | awk -v mark_ck="$TASK_CHECKPOINT_MARK" \
    -v mark_rv="$TASK_REVIEW_MARK" \
    -v tip="$tip_id" -v prev="$prev_id" '
    { print }
    ($0==mark_ck || $0==mark_rv) {
      if (tip != "") print "fact_id=" tip
      if (prev != "") print "prev_fact_id=" prev
    }
  '
}

# 归档或首次 POST 后，fact_id 必须等于实际 GitHub comment id。
task_facts_stamp_fact_id() {
  local body="$1" mark="$2" id="$3"
  body="$(task_facts_strip_machine_keys "$body" fact_id)"
  printf '%s\n' "$body" | awk -v m="$mark" -v id="$id" '
    { print }
    $0==m { print "fact_id=" id }
  '
}

# current tip 与 history 共用：正文 fact_id 若存在，必须唯一且等于
# GitHub comment id。缺省视为 recognized legacy，不回填。
task_facts_check_fact_id() {
  local body="$1" comment_id="$2" label="$3"
  local n fact_id
  n="$(task_machine_field_count "$body" fact_id)"
  if [ "$n" -gt 1 ]; then
    err_code facts.fact_id_duplicate "${label} 的 fact_id 重复，拒绝猜测"
    return 1
  fi
  [ "$n" = 0 ] && return 0
  fact_id="$(task_machine_field "$body" fact_id)"
  if [ -z "$fact_id" ] || [ "$fact_id" != "$comment_id" ]; then
    err_code facts.fact_id_mismatch \
      "${label} 的 fact_id=${fact_id:-empty} 与 GitHub comment id ${comment_id:-empty} 冲突"
    return 1
  fi
  return 0
}

task_facts_replace_mark() {
  local body="$1" from="$2" to="$3"
  printf '%s\n' "$body" | awk -v from="$from" -v to="$to" '
    index($0, from) { gsub(from, to) }
    { print }
  '
}

task_facts_comment_ids_with_mark() {
  local js="$1" mark="$2"
  printf '%s' "$js" | jq -r --arg m "$mark" '
    map(select(.body != null and (.body | contains($m))) | .id)
    | map(tostring) | .[]
  '
}

task_facts_comment_by_id() {
  local js="$1" id="$2"
  printf '%s' "$js" | jq -c --argjson id "$id" 'map(select(.id == $id)) | .[0] // empty'
}

# 重复 tip、分叉、损坏引用、重复或错误 fact_id 一律 fail-closed。不看 created_at。
task_facts_validate_history() {
  local js="$1" tip_body="$2" tip_mark="$3" history_mark="$4" label="$5" tip_id="${6:-}"
  local rows orphans seen=" " line id cid kind body prev n_hist n_rows
  if [ -n "$tip_id" ]; then
    task_facts_check_fact_id "$tip_body" "$tip_id" "${label}" || return 1
  fi
  prev="$(task_machine_field "$tip_body" prev_fact_id)"
  rows="$(task_facts_history_rows "$tip_body")"
  n_hist="$(task_facts_comment_ids_with_mark "$js" "$history_mark" | awk 'NF{c++} END{print c+0}')"
  n_rows="$(printf '%s\n' "$rows" | awk 'NF{c++} END{print c+0}')"
  if [ -n "$prev" ] && [ "$n_rows" = 0 ]; then
    err_code facts.history_missing_index \
      "${label} 声明了 prev_fact_id=${prev} 但没有 Historical facts 索引"
    return 1
  fi
  if [ "$n_hist" != "$n_rows" ]; then
    err_code facts.history_fork \
      "${label} 历史 fact 数量与 tip 索引不一致（comments=${n_hist} index=${n_rows}），拒绝猜测当前 tip"
    return 1
  fi
  if [ -n "$prev" ]; then
    printf '%s\n' "$rows" | awk -F '\t' -v p="$prev" '$1==p || $2==p {found=1} END{exit found?0:1}' \
      || {
        err_code facts.history_prev_missing \
          "${label} 的 prev_fact_id=${prev} 不在 Historical facts 索引中"
        return 1
      }
  fi
  while IFS=$'\t' read -r id cid kind; do
    [ -n "$id" ] || continue
    case "$seen" in *" $id "*|*" #$cid "*)
      err_code facts.history_duplicate "${label} 历史 fact 重复：${id}/${cid}"
      return 1
      ;;
    esac
    seen="${seen}${id} #${cid} "
    [[ "$cid" =~ ^[1-9][0-9]*$ ]] || {
      err_code facts.history_id_invalid "${label} 历史 comment_id 非法：${cid}"
      return 1
    }
    body="$(task_facts_comment_by_id "$js" "$cid" | jq -r '.body // empty')"
    [ -n "$body" ] || {
      err_code facts.history_comment_missing "${label} 历史引用 ${cid} 不存在"
      return 1
    }
    case "$body" in
      *"$history_mark"*) ;;
      *)
        err_code facts.history_marker_missing "${label} 历史评论 ${cid} 缺少 ${history_mark}"
        return 1
        ;;
    esac
    case "$body" in
      *"$tip_mark"*)
        err_code facts.history_tip_conflict "${label} 历史评论 ${cid} 仍含当前 tip 标记"
        return 1
        ;;
    esac
    task_facts_check_fact_id "$body" "$cid" "${label} 历史" || return 1
  done <<< "$rows"
  orphans="$(task_facts_comment_ids_with_mark "$js" "$history_mark")"
  while IFS= read -r cid; do
    [ -n "$cid" ] || continue
    printf '%s\n' "$rows" | awk -F '\t' -v c="$cid" '$2==c{found=1} END{exit found?0:1}' \
      || {
        err_code facts.history_orphan "${label} 存在未索引的历史评论 ${cid}，视为分叉"
        return 1
      }
  done <<< "$orphans"
  return 0
}

task_facts_post_comment() {
  local owner="$1" repo="$2" number="$3" body="$4" payload resp id
  payload="$(jq -n --arg body "$body" '{body: $body}')"
  resp="$(printf '%s\n' "$payload" \
    | GH_PAGER=cat gh api -X POST "repos/${owner}/${repo}/issues/${number}/comments" --input -)" \
    || return 1
  id="$(printf '%s' "$resp" | jq -r '.id // empty')"
  [[ "$id" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s\n' "$id"
}

task_facts_archive_tip() {
  local owner="$1" repo="$2" number="$3" tip_mark="$4" label="$5" tip_json="$6"
  local history_mark old_body archived hid kind role head blob
  history_mark="$(task_facts_history_mark_for "$tip_mark")" || return 0
  old_body="$(printf '%s' "$tip_json" | jq -r '.body // empty')"
  [ -n "$old_body" ] || return 1
  case "$old_body" in
    *"$tip_mark"*) ;;
    *)
      err_code facts.archive_marker_missing "当前 ${label} tip 缺少标记，拒绝归档"
      return 1
      ;;
  esac
  archived="$(task_facts_replace_mark "$old_body" "$tip_mark" "$history_mark")"
  case "$archived" in
    *"$history_mark"*) ;;
    *)
      err_code facts.archive_marker_missing "归档 ${label} 后缺少历史标记，拒绝覆盖当前 tip"
      return 1
      ;;
  esac
  case "$archived" in
    *"$tip_mark"*)
      err_code facts.archive_tip_residual "归档 ${label} 后仍含当前 tip 标记，拒绝覆盖"
      return 1
      ;;
  esac
  archived="$(task_facts_strip_machine_keys "$archived" fact_id)"
  hid="$(task_facts_post_comment "$owner" "$repo" "$number" "$archived")" || {
    err_code facts.archive_failed "无法归档上一轮 ${label}，拒绝覆盖当前 tip"
    return 1
  }
  archived="$(task_facts_stamp_fact_id "$archived" "$history_mark" "$hid")"
  payload="$(jq -n --arg body "$archived" '{body: $body}')"
  printf '%s\n' "$payload" \
    | GH_PAGER=cat gh api -X PATCH "repos/${owner}/${repo}/issues/comments/${hid}" --input - >/dev/null \
    || {
      err_code facts.archive_stamp_failed "历史 ${label} ${hid} 无法写入 fact_id=${hid}"
      return 1
    }
  task_facts_parse_provenance "$old_body" || true
  kind="$(task_facts_kind_for_mark "$tip_mark")"
  role="${FACT_PROV_ROLE:-unknown}"
  if [ "$kind" = review ]; then
    head="$(task_review_table_field "$old_body" "reviewed HEAD")"
  else
    head="$(task_review_table_field "$old_body" HEAD)"
  fi
  blob="$(task_review_table_field "$old_body" Contract)"
  FACT_ARCHIVE_ID="$hid"
  FACT_ARCHIVE_KIND="$kind"
  FACT_ARCHIVE_ROLE="$role"
  FACT_ARCHIVE_HEAD="$head"
  FACT_ARCHIVE_BLOB="$blob"
  printf '%s\n' "$hid"
}

task_facts_prepare_tip_body() {
  local body="$1" tip_mark="$2" tip_id="$3" prev_id="$4" kind="$5" role="$6" head="$7" blob="$8" old_body="$9"
  if [ -n "$prev_id" ]; then
    body="$(task_facts_attach_history_row "$body" "$prev_id" "$prev_id" "$kind" "$role" "$head" "$blob")"
    if [ -n "$old_body" ]; then
      local old_rows
      old_rows="$(task_facts_history_rows "$old_body")"
      if [ -n "$old_rows" ]; then
        local merged
        merged="$(printf '%s\n%s\n' "$(task_facts_history_rows "$body")" "$old_rows")"
        body="$(task_facts_strip_section "$body" "Historical facts")"
        body="${body%"$'\n'"}"
        body="$(printf '%s\n\n%s\n' "$body" "$(task_facts_render_history_section "$merged")")"
      fi
    fi
    body="$(task_facts_set_prev_fields "$body" "$tip_id" "$prev_id")"
  fi
  printf '%s\n' "$body"
}

task_facts_head_kind() {
  local wt="$1" reviewed="$2" current="$3"
  [ -n "$reviewed" ] && [ -n "$current" ] || { printf '%s\n' unknown; return 0; }
  [ "$reviewed" = "$current" ] && { printf '%s\n' exact; return 0; }
  [ -n "$wt" ] || { printf '%s\n' other; return 0; }
  if git -C "$wt" rev-parse --verify -q "$reviewed^{commit}" >/dev/null 2>&1 \
     && git -C "$wt" rev-parse --verify -q "$current^{commit}" >/dev/null 2>&1; then
    if git -C "$wt" merge-base --is-ancestor "$reviewed" "$current" 2>/dev/null; then
      printf '%s\n' ancestor
      return 0
    fi
    if git -C "$wt" merge-base --is-ancestor "$current" "$reviewed" 2>/dev/null; then
      printf '%s\n' descendant
      return 0
    fi
  fi
  printf '%s\n' other
}

task_facts_lineage_tokens() {
  local source_ref="$1" lineage_ref="$2"
  [ -n "$source_ref" ] && printf '%s\n' "$source_ref"
  [ -n "$lineage_ref" ] && printf '%s\n' "$lineage_ref"
}

task_facts_tokens_overlap() {
  local a="$1" b="$2" t
  [ -n "$a" ] && [ -n "$b" ] || return 1
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    printf '%s\n' "$b" | grep -Fxq -- "$t" && return 0
  done <<< "$a"
  return 1
}

task_facts_executions_for_candidate() {
  local js="$1" current_head="$2" wt="$3"
  local ids id c body class role head tokens state kind
  ids="$(task_facts_comment_ids_with_mark "$js" "$TASK_CHECKPOINT_MARK")"
  ids="$(printf '%s\n%s\n' "$ids" "$(task_facts_comment_ids_with_mark "$js" "$TASK_CHECKPOINT_HISTORY_MARK")")"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    c="$(task_facts_comment_by_id "$js" "$id")"
    [ -n "$c" ] || continue
    body="$(printf '%s' "$c" | jq -r '.body // empty')"
    # 必须在当前 shell 解析：$(class) 子进程里的 FACT_PROV_* 不能带回来。
    task_facts_parse_provenance "$body" || return 1
    class="$(task_facts_independence_class "$body")" || return 1
    case "$class" in
      claim|review|delivery) continue ;;
      dev|fix|unknown) ;;
      *) return 1 ;;
    esac
    role="$class"
    [ "$role" = unknown ] && role="${FACT_PROV_ROLE:-unknown}"
    head="$(task_review_table_field "$body" HEAD)"
    [ -n "$head" ] || continue
    kind="$(task_facts_head_kind "$wt" "$head" "$current_head")"
    case "$kind" in
      exact|ancestor) ;;
      *) continue ;;
    esac
    state="${FACT_PROV_STATE:-unknown-unverified}"
    tokens="$(task_facts_lineage_tokens "${FACT_PROV_SOURCE_REF:-}" "${FACT_PROV_LINEAGE_REF:-}")"
    printf '%s\t%s\t%s\t%s\n' "$id" "$role" "$state" "$(printf '%s' "$tokens" | tr '\n' ' ')"
  done <<< "$ids"
}

# 只有 reviewer 为 verified，且其 execution/lineage 不属于形成当前
# candidate 的任何 dev/fix execution 或其 continuation/fork，才算独立。
task_facts_reviewer_independent() {
  local review_body="$1" current_head="$2" wt="$3" js="${4:-$FACT_COMMENTS_JSON}"
  local rev_tokens execs id role state tokens unknown=0
  task_facts_parse_provenance "$review_body" || return 1
  if [ "$FACT_PROV_STATE" != verified ]; then
    return 1
  fi
  rev_tokens="$(task_facts_lineage_tokens "$FACT_PROV_SOURCE_REF" "$FACT_PROV_LINEAGE_REF")"
  [ -n "$rev_tokens" ] || return 1
  execs="$(task_facts_executions_for_candidate "$js" "$current_head" "$wt")" || return 1
  if [ -z "$execs" ]; then
    return 1
  fi
  while IFS=$'\t' read -r id role state tokens; do
    [ -n "$id" ] || continue
    if [ "$state" != verified ]; then
      unknown=1
      continue
    fi
    if task_facts_tokens_overlap "$rev_tokens" "$(printf '%s' "$tokens" | tr ' ' '\n')"; then
      return 1
    fi
  done <<< "$execs"
  [ "$unknown" = 0 ] || return 1
  return 0
}

task_facts_current_reviewer_independent() {
  local wt="${1:-${Z_WT:-}}" head="${2:-${Z_HEAD:-}}" js="${3:-$FACT_COMMENTS_JSON}"
  local type="unknown" ref="" lineage="" body
  [ -n "$wt" ] && [ -n "$head" ] && [ -n "$js" ] || return 1
  task_facts_read_capture "$wt" || return 1
  [ "$FACT_CAPTURE_STATE" = verified ] || return 1
  type="$FACT_CAPTURE_SOURCE_TYPE"
  ref="$FACT_CAPTURE_SOURCE_REF"
  lineage="$FACT_CAPTURE_LINEAGE_REF"
  body="${TASK_REVIEW_MARK}"$'\n'
  body+="provenance_version=${TASK_FACT_PROVENANCE_VERSION}"$'\n'
  body+="source_type=${type}"$'\n'
  body+="source_ref=${ref}"$'\n'
  [ -n "$lineage" ] && body+="lineage_ref=${lineage}"$'\n'
  body+="role=review"$'\n'
  body+="verification_state=verified"
  task_facts_reviewer_independent "$body" "$head" "$wt" "$js"
}

task_facts_review_is_applicable_pass() {
  local body="$1" head="$2" blob="$3" wt="${4:-}"
  local verdict rhead rblob self
  [ -n "$body" ] && [ -n "$head" ] && [ -n "$blob" ] || return 1
  verdict="$(task_review_table_field "$body" "Verdict")"
  rhead="$(task_review_table_field "$body" "reviewed HEAD")"
  rblob="$(task_review_table_field "$body" "Contract")"
  self="$(task_machine_field "$body" Self-review)"
  [ "$verdict" = "${TASK_VERDICT_PASS:-通过}" ] || return 1
  [ "$rhead" = "$head" ] || return 1
  [ "$rblob" = "$blob" ] || return 1
  [ "$self" = no ] || return 1
  task_facts_reviewer_independent "$body" "$head" "$wt" "${FACT_COMMENTS_JSON:-}"
}

task_facts_review_applicability() {
  local body="$1" head="$2" blob="$3" wt="${4:-}"
  local verdict rhead rblob self kind
  FACT_REVIEW_APPLICABILITY=missing
  FACT_HEAD_KIND=unknown
  [ -n "$body" ] || return 0
  verdict="$(task_review_table_field "$body" "Verdict")"
  rhead="$(task_review_table_field "$body" "reviewed HEAD")"
  rblob="$(task_review_table_field "$body" "Contract")"
  self="$(task_machine_field "$body" Self-review)"
  kind="$(task_facts_head_kind "$wt" "$rhead" "$head")"
  FACT_HEAD_KIND="$kind"
  if [ "$(task_machine_field_count "$body" review_actor)" != 1 ] \
     || [ "$(task_machine_field_count "$body" claim_actor)" != 1 ] \
     || [ "$(task_machine_field_count "$body" Self-review)" != 1 ]; then
    FACT_REVIEW_APPLICABILITY=conflict
    return 0
  fi
  if ! task_facts_parse_provenance "$body"; then
    FACT_REVIEW_APPLICABILITY=conflict
    return 0
  fi
  case "$verdict" in
    通过|不通过) ;;
    *) FACT_REVIEW_APPLICABILITY=conflict; return 0 ;;
  esac
  if [ -n "$blob" ] && [ -n "$rblob" ] && [ "$rblob" != "$blob" ]; then
    FACT_REVIEW_APPLICABILITY=stale-contract
    return 0
  fi
  if [ "$kind" != exact ]; then
    FACT_REVIEW_APPLICABILITY=stale-head
    return 0
  fi
  if [ "$verdict" = 不通过 ]; then
    FACT_REVIEW_APPLICABILITY=fail
    return 0
  fi
  if [ "$self" = no ] && task_facts_reviewer_independent "$body" "$head" "$wt" "${FACT_COMMENTS_JSON:-}"; then
    FACT_REVIEW_APPLICABILITY=pass
    return 0
  fi
  FACT_REVIEW_APPLICABILITY=pass-unproven
}

task_facts_findings_from_review() {
  local body="$1" sec
  [ -n "$body" ] || return 0
  [ "$(task_review_table_field "$body" "Verdict")" = 不通过 ] || return 0
  sec="$(printf '%s\n' "$body" | awk '
    BEGIN { s=0 }
    $0 == "### 阻断项" { s=1; next }
    s && /^### / { exit }
    s { print }
  ')"
  printf '%s\n' "$sec" | awk 'NF{n++; if(n<=8) print} END{}'
}

task_facts_bounded_diff() {
  local wt="$1" base="$2" ahead stat files
  [ -n "$wt" ] && [ -n "$base" ] || return 0
  ahead="$(git -C "$wt" rev-list --count "${base}..HEAD" 2>/dev/null || true)"
  stat="$(git -C "$wt" diff --stat "${base}...HEAD" 2>/dev/null | tail -n 1 || true)"
  files="$(git -C "$wt" diff --name-only "${base}...HEAD" 2>/dev/null | awk 'NF{c++} END{print c+0}')"
  printf 'ahead=%s files=%s %s' "${ahead:-?}" "${files:-0}" "$(task_facts_trim "$stat")"
}

task_facts_next_after_pass() {
  local labels="${1:-$FACT_LABELS}"
  case "$labels" in
    *human-merge*) printf '%s\n' "$TASK_BOOTSTRAP_NEXT_PASS_HUMAN" ;;
    *) printf '%s\n' "$TASK_BOOTSTRAP_NEXT_PASS_AUTO" ;;
  esac
}

task_facts_derive_next() {
  local wt="$1" base="$2"
  if [ -z "$wt" ] || [ -z "$base" ] \
     || ! task_completion_gate "$wt" "$base" changed >/dev/null 2>&1; then
    printf '%s\n' "$TASK_BOOTSTRAP_NEXT_DEV"
    return 0
  fi
  case "${FACT_REVIEW_APPLICABILITY:-}" in
    fail) printf '%s\n' "$TASK_BOOTSTRAP_NEXT_FIX" ;;
    pass) task_facts_next_after_pass ;;
    *) printf '%s\n' "$TASK_BOOTSTRAP_NEXT_REVIEW" ;;
  esac
}

task_facts_hist_ref_summary() {
  local ck rv
  ck="$(task_facts_history_rows "${FACT_CK_BODY:-}" | awk -F '\t' 'NF{printf "%s%s", (n++?", ":""), $2}')"
  rv="$(task_facts_history_rows "${FACT_RV_BODY:-}" | awk -F '\t' 'NF{printf "%s%s", (n++?", ":""), $2}')"
  printf 'checkpoint=[%s] review=[%s]' "$ck" "$rv"
}

task_facts_load() {
  local owner="$1" repo="$2" number="$3" wt="$4" base="$5"
  local js ck rv
  task_facts_reset
  [ -n "$owner" ] && [ -n "$repo" ] && [ -n "$number" ] || {
    err_code facts.args "stage facts 缺少 owner/repo/issue"
    return 1
  }
  if ! js="$(task_issue_comments_json "$owner" "$repo" "$number")"; then
    err_code facts.comments_unreadable "无法读取 Issue 评论，拒绝恢复阶段事实"
    return 1
  fi
  FACT_COMMENTS_JSON="$js"
  if ! ck="$(task_facts_unique_from_json "$js" "$TASK_CHECKPOINT_MARK" "Checkpoint")"; then
    return 1
  fi
  if ! rv="$(task_facts_unique_from_json "$js" "$TASK_REVIEW_MARK" "Review")"; then
    return 1
  fi
  FACT_CK_JSON="$ck"
  FACT_RV_JSON="$rv"
  if [ -n "$ck" ]; then
    FACT_CK_BODY="$(printf '%s' "$ck" | jq -r '.body // empty')"
    FACT_CK_ID="$(printf '%s' "$ck" | jq -r '.id // empty')"
    if [ "$(task_machine_field_count "$FACT_CK_BODY" claim_actor)" != 1 ]; then
      err_code facts.checkpoint_conflict "Checkpoint tip 的 claim_actor 缺失或重复"
      return 1
    fi
    if ! task_facts_check_provenance_fields "$FACT_CK_BODY"; then
      err_code facts.checkpoint_conflict "Checkpoint tip 的 provenance 字段缺失、重复或冲突"
      return 1
    fi
    task_facts_validate_history "$js" "$FACT_CK_BODY" \
      "$TASK_CHECKPOINT_MARK" "$TASK_CHECKPOINT_HISTORY_MARK" "Checkpoint" \
      "$FACT_CK_ID" \
      || return 1
    FACT_CK_HEAD="$(task_review_table_field "$FACT_CK_BODY" HEAD)"
    FACT_CK_BLOB="$(task_review_table_field "$FACT_CK_BODY" Contract)"
    FACT_CK_SHAPE="$(task_facts_classify_checkpoint "$FACT_CK_BODY")"
    FACT_CK_COMPLETION="$(task_review_table_field "$FACT_CK_BODY" "交接状态")"
    FACT_CK_PR="$(task_review_table_field "$FACT_CK_BODY" PR)"
    FACT_CK_NEXT="$(task_review_table_field "$FACT_CK_BODY" "下一步")"
  fi
  if [ -n "$rv" ]; then
    FACT_RV_BODY="$(printf '%s' "$rv" | jq -r '.body // empty')"
    FACT_RV_ID="$(printf '%s' "$rv" | jq -r '.id // empty')"
    if [ "$(task_machine_field_count "$FACT_RV_BODY" review_actor)" != 1 ] \
       || [ "$(task_machine_field_count "$FACT_RV_BODY" claim_actor)" != 1 ] \
       || [ "$(task_machine_field_count "$FACT_RV_BODY" Self-review)" != 1 ]; then
      err_code facts.review_conflict "Review tip 的 actor / Self-review 缺失或重复"
      return 1
    fi
    if ! task_facts_check_provenance_fields "$FACT_RV_BODY"; then
      err_code facts.review_conflict "Review tip 的 provenance 字段缺失、重复或冲突"
      return 1
    fi
    task_facts_validate_history "$js" "$FACT_RV_BODY" \
      "$TASK_REVIEW_MARK" "$TASK_REVIEW_HISTORY_MARK" "Review" \
      "$FACT_RV_ID" \
      || return 1
    FACT_RV_VERDICT="$(task_review_table_field "$FACT_RV_BODY" "Verdict")"
    FACT_RV_HEAD="$(task_review_table_field "$FACT_RV_BODY" "reviewed HEAD")"
    FACT_RV_BLOB="$(task_review_table_field "$FACT_RV_BODY" Contract)"
    FACT_RV_SELF="$(task_machine_field "$FACT_RV_BODY" Self-review)"
  fi
  FACT_BIND="$(task_bind_read "$wt" 2>/dev/null || true)"
  FACT_DIFF_SUMMARY="$(task_facts_bounded_diff "$wt" "$base")"
  task_facts_review_applicability "$FACT_RV_BODY" \
    "${Z_HEAD:-$(git -C "$wt" rev-parse HEAD 2>/dev/null || true)}" \
    "${Z_CONTRACT_BLOB:-}" "$wt"
  FACT_FINDINGS="$(task_facts_findings_from_review "$FACT_RV_BODY")"
  if [ -n "$FACT_CK_BODY" ]; then
    task_facts_parse_provenance "$FACT_CK_BODY"
    FACT_PROVENANCE_SUMMARY="checkpoint role=${FACT_PROV_ROLE:-unknown} state=${FACT_PROV_STATE}"
  else
    FACT_PROVENANCE_SUMMARY='checkpoint missing'
  fi
  if [ -n "$FACT_RV_BODY" ]; then
    task_facts_parse_provenance "$FACT_RV_BODY"
    FACT_PROVENANCE_SUMMARY="${FACT_PROVENANCE_SUMMARY}; review role=${FACT_PROV_ROLE:-unknown} state=${FACT_PROV_STATE} self=${FACT_RV_SELF:-}"
  fi
  if [ -n "${Z_ISSUE_JSON:-}" ] && [ -f "${Z_ISSUE_JSON:-}" ]; then
    FACT_LABELS="$(task_issue_labels "$Z_ISSUE_JSON")"
  fi
  FACT_HIST_REFS="$(task_facts_hist_ref_summary)"
  FACT_NEXT="$(task_facts_derive_next "$wt" "$base")"
  TASK_FACTS_READY=1
}

task_facts_load_history_body() {
  local comment_id="$1" js="${2:-$FACT_COMMENTS_JSON}" c
  [[ "$comment_id" =~ ^[1-9][0-9]*$ ]] || return 1
  [ -n "$js" ] || return 1
  c="$(task_facts_comment_by_id "$js" "$comment_id")"
  [ -n "$c" ] || return 1
  printf '%s' "$c" | jq -r '.body // empty'
}

task_facts_card() {
  local head="${Z_HEAD:-}" blob="${Z_CONTRACT_BLOB:-}"
  local findings next appl
  findings="$(printf '%s\n' "${FACT_FINDINGS:-}" | awk 'NF{n++; if(n<=6) print}')"
  [ -n "$findings" ] || findings='（无当前适用 FAIL findings）'
  next="${FACT_NEXT:-$TASK_BOOTSTRAP_NEXT_DEV}"
  appl="${FACT_REVIEW_APPLICABILITY:-missing}"
  cat <<EOF
${TASK_FACTS_CARD_BEGIN}
## Current stage facts

| Field | Value |
| --- | --- |
| Issue | ${Z_OWNER:-?}/${Z_REPO:-?}#${Z_NUMBER:-?} |
| Binding | ${FACT_BIND:-${Z_NUMBER:-unbound}} |
| Contract | \`${blob:-unknown}\` |
| Candidate HEAD | \`${head:-unknown}\` |
| Bounded diff | ${FACT_DIFF_SUMMARY:-n/a} |
| Checkpoint tip | id=${FACT_CK_ID:-none} shape=${FACT_CK_SHAPE:-none} HEAD=\`${FACT_CK_HEAD:-}\` completion=${FACT_CK_COMPLETION:-} |
| Review tip | id=${FACT_RV_ID:-none} verdict=${FACT_RV_VERDICT:-none} reviewed=\`${FACT_RV_HEAD:-}\` applicability=${appl} head_kind=${FACT_HEAD_KIND:-} |
| PR | ${FACT_CK_PR:-unknown} |
| Provenance | ${FACT_PROVENANCE_SUMMARY:-unknown} |
| Historical refs | ${FACT_HIST_REFS:-none} |
| Next canonical command | ${next} |

### Unresolved findings
${findings}

正常恢复只包含当前 tip、当前 finding 与历史引用。完整历史按需用 fact comment id 追溯。
ancestry 只解释 HEAD 变化，不把祖先 PASS 当成当前 verdict。
无法证明独立性时记录 unknown/unverified，不得宣称 Self-review=no。
${TASK_FACTS_CARD_END}
EOF
}

task_facts_print_card() {
  task_facts_card
}

task_facts_projection_has_history_bodies() {
  local card="$1" js="${2:-$FACT_COMMENTS_JSON}" id body needle
  [ -n "$js" ] || return 1
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    body="$(task_facts_load_history_body "$id" "$js")" || continue
    needle="$(printf '%s\n' "$body" | awk 'NF && $0 !~ /^<!-- / && $0 !~ /^\|/ {print; exit}')"
    [ -n "$needle" ] || continue
    printf '%s\n' "$card" | grep -Fq -- "$needle" && return 0
  done < <(printf '%s\n' \
    "$(task_facts_comment_ids_with_mark "$js" "$TASK_CHECKPOINT_HISTORY_MARK")" \
    "$(task_facts_comment_ids_with_mark "$js" "$TASK_REVIEW_HISTORY_MARK")")
  return 1
}
