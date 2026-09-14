# canonical `new z review` 的结构化 Review 协议与渲染器。
#
# 输入是逐行协议，不接受手写完整 Markdown：
#   verdict: 通过
#   title: feat(meta): 一个已校验的标题
#   notes: 本轮审查说明
#   R1: 满足 | 证据
#   A1: 通过 | 证据
# 空行与 # 开头的注释行允许，其余行必须命中上述语法。
# 本文件不调用 Skill；Skill adapter 只 exec `new z review`。

review_reject() {
  local code="$1"
  shift
  if [ "$(type -t err_code 2>/dev/null)" = function ]; then
    err_code "$code" "$@"
  else
    printf '%s\n' "$*" >&2
  fi
  return 1
}

review_trim() {
  local s="${1:-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

review_evidence_valid() {
  local evidence normalized
  evidence="$(review_trim "${1:-}")"
  [ -n "$evidence" ] || return 1
  normalized="$evidence"
  while :; do
    case "$normalized" in
      ：*|:*|\(*|\[*|\{*) normalized="${normalized#?}" ;;
      *。|*！|*？|*；|*，|*、|*\.|*!|*\?|*\;|*\,) normalized="${normalized%?}" ;;
      *) break ;;
    esac
    normalized="$(review_trim "$normalized")"
  done
  case "$normalized" in
    满足|不满足|通过|不通过|不适用|pending|passed|failed|not-applicable) return 1 ;;
  esac
  return 0
}

review_contract_id_exists() {
  local json="$1" kind="$2" id="$3"
  if [ "$kind" = R ]; then
    jq -e --arg id "$id" '.requirements | any(.id == $id)' "$json" >/dev/null 2>&1
  else
    jq -e --arg id "$id" '.acceptances | any(.id == $id)' "$json" >/dev/null 2>&1
  fi
}

review_actor_policy() {
  local review_actor="$1" claim_actor="$2" allow_self="${3:-0}" human_merge="${4:-0}"
  if [ "$review_actor" != "$claim_actor" ]; then
    printf '%s\n' no
    return 0
  fi
  if [ "$allow_self" != 1 ]; then
    review_reject review.actor_not_independent 'review_actor 与 claim_actor 相同；需要 --allow-self 才能显式 self-review'
    return 1
  fi
  if [ "$human_merge" != 1 ]; then
    review_reject review.self_requires_human_merge 'Self-review 必须有 human-merge 标签；拒绝发布'
    return 1
  fi
  printf '%s\n' yes
}

review_parse_structured_input() {
  local file="$1" contract_json="$2" out="$3"
  local records line_no=0 raw line key value id kind rhs status evidence
  local verdict="" title="" notes="" verdict_line=0 title_line=0 notes_line=0
  local contract_id missing_count=0 rjson='[]' ajson='[]'

  [ -f "$file" ] || { review_reject review.input_missing "Review 输入文件不存在：$file"; return 1; }
  [ -f "$contract_json" ] || { review_reject contract.missing "找不到当前 Contract：$contract_json"; return 1; }
  validator_contract_validate "$contract_json" || return 1

  records="$(mktemp -t review-ra.XXXXXX)" || {
    review_reject review.input_temp "无法创建 Review 解析临时文件"
    return 1
  }
  TMPS="$TMPS $records"

  while IFS= read -r raw || [ -n "$raw" ]; do
    line_no=$((line_no + 1))
    line="${raw%$'\r'}"
    line="$(review_trim "$line")"
    [ -n "$line" ] || continue
    case "$line" in
      \#*) continue ;;
    esac

    if [[ "$line" =~ ^(verdict|title|notes)[[:space:]]*([=:])[[:space:]]*(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      value="$(review_trim "${BASH_REMATCH[3]}")"
      case "$key" in
        verdict)
          [ "$verdict_line" = 0 ] || {
            review_reject review.input_line "Review 输入第 ${line_no} 行重复 verdict（首次在第 ${verdict_line} 行）"
            return 1
          }
          [ -n "$value" ] || {
            review_reject review.input_line "Review 输入第 ${line_no} 行的 verdict 为空"
            return 1
          }
          verdict="$value"; verdict_line="$line_no" ;;
        title)
          [ "$title_line" = 0 ] || {
            review_reject review.input_line "Review 输入第 ${line_no} 行重复 title（首次在第 ${title_line} 行）"
            return 1
          }
          [ -n "$value" ] || {
            review_reject review.input_line "Review 输入第 ${line_no} 行的 title 为空"
            return 1
          }
          title="$value"; title_line="$line_no" ;;
        notes)
          [ "$notes_line" = 0 ] || {
            review_reject review.input_line "Review 输入第 ${line_no} 行重复 notes（首次在第 ${notes_line} 行）"
            return 1
          }
          [ -n "$value" ] || {
            review_reject review.input_line "Review 输入第 ${line_no} 行的 notes 为空"
            return 1
          }
          notes="$value"; notes_line="$line_no" ;;
      esac
      continue
    fi

    if [[ "$line" =~ ^([RA][1-9][0-9]*)[[:space:]]*([=:])[[:space:]]*(.*)$ ]]; then
      id="${BASH_REMATCH[1]}"
      rhs="${BASH_REMATCH[3]}"
      kind="${id:0:1}"
      if [[ "$rhs" != *\|* ]]; then
        review_reject review.input_line "Review 输入第 ${line_no} 行缺少 | 证据分隔符"
        return 1
      fi
      status="$(review_trim "${rhs%%|*}")"
      evidence="$(review_trim "${rhs#*|}")"
      case "$status" in
        满足|不满足)
          [ "$kind" = R ] || {
            review_reject review.input_line "Review 输入第 ${line_no} 行的 $id 状态集合不适用"
            return 1
          } ;;
        通过|不通过|不适用)
          [ "$kind" = A ] || {
            review_reject review.input_line "Review 输入第 ${line_no} 行的 $id 状态集合不适用"
            return 1
          } ;;
        *)
          review_reject review.input_line "Review 输入第 ${line_no} 行的 $id 状态非法：${status:-空}"
          return 1 ;;
      esac
      review_contract_id_exists "$contract_json" "$kind" "$id" || {
        review_reject review.unknown_ra "Review 输入第 ${line_no} 行含未知 ${id}"
        return 1
      }
      if awk -F '\t' -v id="$id" '$1 == id { found=1 } END { exit(found ? 0 : 1) }' "$records"; then
        review_reject review.duplicate_ra "Review 输入第 ${line_no} 行重复 ${id}"
        return 1
      fi
      case "$evidence" in
        *$'\t'*)
          review_reject review.input_line "Review 输入第 ${line_no} 行证据不能含 tab"
          return 1 ;;
      esac
      review_evidence_valid "$evidence" || {
        review_reject review.evidence_empty "Review 输入第 ${line_no} 行的 ${id} 证据为空或只有状态词"
        return 1
      }
      if [ "$kind" = A ] && [ "$status" = 不适用 ]; then
        if [ -z "$(jq -r --arg id "$id" '.acceptances[] | select(.id == $id) | .applicable_when // empty' "$contract_json")" ]; then
          review_reject review.na_without_when "Review 输入第 ${line_no} 行的 ${id} 没有 Contract 适用条件"
          return 1
        fi
      fi
      printf '%s\t%s\t%s\t%s\n' "$id" "$status" "$evidence" "$line_no" >> "$records"
      continue
    fi

    review_reject review.input_line "Review 输入第 ${line_no} 行非法；只接受 verdict/title/notes 或 R/A 的 状态 | 证据"
    return 1
  done < "$file"

  [ "$verdict_line" -gt 0 ] || {
    review_reject review.input_missing "Review 输入缺少 verdict（第 $((line_no + 1)) 行前未提供）"
    return 1
  }
  [ "$title_line" -gt 0 ] || {
    review_reject review.input_missing "Review 输入缺少 title（第 $((line_no + 1)) 行前未提供）"
    return 1
  }
  [ "$notes_line" -gt 0 ] || {
    review_reject review.input_missing "Review 输入缺少 notes（第 $((line_no + 1)) 行前未提供）"
    return 1
  }
  case "$verdict" in
    通过|不通过) ;;
    *)
      review_reject review.input_line "Review 输入第 ${verdict_line} 行的 verdict 非法：$verdict"
      return 1 ;;
  esac
  if [ "$verdict" = 通过 ] && [ "$title" = "（无）" ]; then
    review_reject review.input_line "Review 输入第 ${title_line} 行：通过时 title 不能是（无）"
    return 1
  fi
  if [ "$verdict" = 不通过 ] && [ "$title" != "（无）" ]; then
    review_reject review.input_line "Review 输入第 ${title_line} 行：不通过时 title 必须是（无）"
    return 1
  fi

  while IFS= read -r contract_id; do
    [ -n "$contract_id" ] || continue
    if ! awk -F '\t' -v id="$contract_id" '$1 == id { found=1 } END { exit(found ? 0 : 1) }' "$records"; then
      review_reject review.missing_ra "Review 输入缺少 ${contract_id}（第 $((line_no + 1)) 行后仍未提供）"
      missing_count=$((missing_count + 1))
    fi
  done < <(jq -r '.requirements[].id, .acceptances[].id' "$contract_json")
  [ "$missing_count" = 0 ] || return 1

  while IFS=$'\t' read -r id status evidence line_no; do
    [ -n "$id" ] || continue
    if [ "${id:0:1}" = R ]; then
      rjson="$(jq -c --arg id "$id" --arg status "$status" --arg evidence "$evidence" --argjson line "$line_no" \
        '. + [{id:$id,status:$status,evidence:$evidence,line:$line}]' <<<"$rjson")"
    else
      ajson="$(jq -c --arg id "$id" --arg status "$status" --arg evidence "$evidence" --argjson line "$line_no" \
        --argjson validators "$(jq -c --arg id "$id" '.acceptances[] | select(.id == $id) | (.validators // [])' "$contract_json")" \
        '. + [{id:$id,status:$status,evidence:$evidence,line:$line,validators:$validators}]' <<<"$ajson")"
    fi
  done < "$records"

  jq -n --arg verdict "$verdict" --arg title "$title" --arg notes "$notes" \
    --argjson requirements "$rjson" --argjson acceptances "$ajson" \
    '{verdict:$verdict,title:$title,notes:$notes,requirements:$requirements,acceptances:$acceptances}' > "$out"
}

review_run_validators() {
  local parsed="$1" out="$2" acceptance validator log rc output next
  printf '%s\n' '[]' > "$out"
  # 同一 Review 内同一个 validator 只执行一次；结果仍按引用它的 A 展开，
  # 让既有 acceptance 覆盖与渲染协议保持不变。
  while IFS= read -r validator; do
    [ -n "$validator" ] || continue
    log="$(mktemp -t review-validator.XXXXXX)" || {
      review_reject review.validator_temp "无法创建 validator 输出临时文件"
      return 1
    }
    TMPS="$TMPS $log"
    rc=0
    if validator_run "$validator" "$Z_WT" "$Z_SCOPE" >"$log" 2>&1; then
      rc=0
    else
      rc=$?
    fi
    output="$(validator_truncate_file "$log")"
    while IFS= read -r acceptance; do
      [ -n "$acceptance" ] || continue
      next="$(jq -c --arg acceptance "$acceptance" --arg validator "$validator" \
        --argjson exit_code "$rc" --arg output "$output" \
        '. + [{acceptance:$acceptance,validator:$validator,exit_code:$exit_code,output:$output}]' "$out")"
      printf '%s\n' "$next" > "$out"
    done < <(jq -r --arg validator "$validator" \
      '.acceptances[] | select((.validators // []) | index($validator) != null) | .id' "$parsed")
  done < <(jq -r '.acceptances[] | (.validators // [])[]' "$parsed" | awk '!seen[$0]++')
}

review_apply_validator_results() {
  local parsed="$1" results="$2" out="$3"
  jq --slurpfile validator_results "$results" '
    ($validator_results[0] // []) as $results
    | .acceptances |= map(
        . as $a
        | ($results | map(select(.acceptance == $a.id))) as $for_a
        | if ($for_a | length) == 0 then .
          else
            ($for_a | all(.exit_code == 0)) as $ok
            | .status = (if $ok then .status else "不通过" end)
            | .evidence = ((.evidence // "") + "；" +
                ($for_a | map("validator:" + .validator + " exit_code=" + (.exit_code | tostring)) | join("；")))
          end
      )
    | if ((any(.requirements[]; .status != "满足")) or
          (any(.acceptances[]; (.status != "通过" and .status != "不适用"))))
      then .verdict = "不通过" | .title = "（无）"
      else .
      end
  ' "$parsed" > "$out"
}

review_diff_display() {
  local paths="$1" one count
  one="$(printf '%s\n' "$paths" | awk 'NF{printf "%s%s", (n++ ? " " : ""), $0} END{print ""}')"
  count="$(printf '%s\n' "$paths" | awk 'NF{n++} END{print n+0}')"
  [ -n "$one" ] || one='无（未发现真实 diff）'
  printf '%s\t%s\n' "$one" "$count"
}

review_render_validator_results() {
  local results="$1" acceptance validator exit_code output line
  while IFS=$'\t' read -r acceptance validator exit_code output; do
    [ -n "$validator" ] || continue
    printf -- '- %s / validator:%s / exit_code=%s\n' "$acceptance" "$validator" "$exit_code"
    if [ -n "$output" ]; then
      while IFS= read -r line; do
        printf '  output: %s\n' "$line"
      done <<< "$output"
    else
      printf '  output: （空）\n'
    fi
  done < <(jq -r '.[] | [.acceptance,.validator,(.exit_code|tostring),.output] | @tsv' "$results")
}

review_render() {
  local parsed="$1" results="$2" out="$3" actor="$4" claim_actor="$5" self_review="$6" diff_paths="$7"
  local verdict title notes head issue contract scope diff_display diff_count
  verdict="$(jq -r '.verdict' "$parsed")"
  title="$(jq -r '.title' "$parsed")"
  notes="$(jq -r '.notes' "$parsed")"
  head="$Z_HEAD"
  issue="${Z_OWNER}/${Z_REPO}#${Z_NUMBER}"
  contract="$Z_CONTRACT_BLOB"
  scope="$(review_diff_display "$diff_paths")"
  diff_display="${scope%%$'\t'*}"
  diff_count="${scope#*$'\t'}"

  {
    printf '%s\n' "$TASK_REVIEW_MARK"
    printf 'review_actor=%s\n' "$actor"
    printf 'claim_actor=%s\n' "$claim_actor"
    printf 'Self-review=%s\n\n' "$self_review"
    printf '%s\n\n' '## Review'
    printf '%s\n' '| 项 | 值 |'
    printf '%s\n' '| --- | --- |'
    printf '| Verdict | %s |\n' "$verdict"
    printf '| reviewed HEAD | `%s` |\n' "$head"
    printf '| 范围 | %s |\n' "$diff_display"
    printf '| Squash-Title | `%s` |\n' "$title"
    printf '| Issue | %s |\n' "$issue"
    printf '| Contract | `%s` |\n' "$contract"
    printf '| review_actor | `%s` |\n' "$actor"
    printf '| claim_actor | `%s` |\n' "$claim_actor"
    printf '| Self-review | `%s` |\n\n' "$self_review"
    if [ "$verdict" = 通过 ]; then
      printf '%s\n\n' '### 通过理由'
    else
      printf '%s\n\n' '### 阻断项'
    fi
    printf '%s\n\n' "- $notes"
    printf '%s\n\n' '### 证据'
    printf '%s\n' "- 当前 HEAD：$head"
    printf '%s\n' "- 实际 diff：$diff_display"
    printf '%s\n\n' "- claim_actor=${claim_actor}；review_actor=${actor}；Self-review=${self_review}"
    printf '%s\n' '### Validator 结果'
    if [ "$(jq 'length' "$results")" = 0 ]; then
      printf '%s\n\n' '- Contract 未登记需要自动执行的 validator。'
    else
      review_render_validator_results "$results"
      printf '\n'
    fi
    printf '%s\n\n' '### 最小充分审查'
    printf '%s\n' '- 审查代码与调用点：工具不证明固定对象的语义覆盖；由 reviewer notes 与 R/A evidence 表达'
    printf '%s\n' "- 复用证据：当前 Contract blob ${contract} 与当前 HEAD ${head}"
    printf '%s\n' '- 新增验证：validator 名称、exit code 与截断输出见上方'
    printf '%s\n' "- 覆盖范围：检测到 ${diff_count} 个 diff 路径：${diff_display}（仅表示工具枚举到的路径）"
    printf '%s\n' '- 未执行的大范围验证：未运行与本 Contract 无关的全量 test/lint/build 或外部 CI'
    printf '%s\n\n' '- 剩余风险：actor 仅 provenance，不提供密码学认证；人工 Review 语义仍需独立会话复核'
    printf '%s\n\n' '### Contract 对照'
    jq -r '.requirements[] | [.id,.status,.evidence] | @tsv' "$parsed" | \
      while IFS=$'\t' read -r id status evidence; do
        printf -- '- %s：%s。%s\n' "$id" "$status" "$evidence"
      done
    jq -r '.acceptances[] | [.id,.status,.evidence] | @tsv' "$parsed" | \
      while IFS=$'\t' read -r id status evidence; do
        printf -- '- %s：%s。%s\n' "$id" "$status" "$evidence"
      done
  } > "$out"
}

review_claim_actor() {
  local owner="$1" repo="$2" number="$3" comment body actor table_actor
  comment="$(task_unique_marked_comment "$owner" "$repo" "$number" \
    "$TASK_CHECKPOINT_MARK" "Checkpoint")" || return 1
  [ -n "$comment" ] || {
    review_reject review.checkpoint_missing "没有唯一 Checkpoint，无法证明 claim_actor"
    return 1
  }
  body="$(printf '%s' "$comment" | jq -r '.body // empty')"
  [ "$(task_machine_field_count "$body" claim_actor)" = 1 ] || {
    review_reject review.claim_actor_missing "Checkpoint 必须含且仅含一个 claim_actor machine field"
    return 1
  }
  actor="$(task_machine_field "$body" claim_actor)"
  task_actor_valid "$actor" || {
    review_reject review.claim_actor_invalid "Checkpoint 的 claim_actor 非法"
    return 1
  }
  table_actor="$(task_review_table_field "$body" claim_actor)"
  [ "$table_actor" = "$actor" ] || {
    review_reject review.claim_actor_mismatch "Checkpoint 的 claim_actor 表格值与 machine field 不一致"
    return 1
  }
  printf '%s\n' "$actor"
}

review_publish() {
  local input="" actor_candidate="" actor_explicit=0 allow_self=0 arg
  local claim_actor review_actor self_review human_merge=0
  local checkpoint parsed results effective diff_paths rendered completion_base

  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --actor)
        [ "$#" -ge 2 ] && [ -n "${2:-}" ] || {
          review_reject review.usage '用法：new z review [--actor <id>] [--allow-self] <review-input>' || true
          return 1
        }
        actor_candidate="$2"
        actor_explicit=1
        shift 2
        ;;
      --actor=*)
        actor_candidate="${arg#--actor=}"
        [ -n "$actor_candidate" ] || {
          review_reject review.usage '用法：new z review [--actor <id>] [--allow-self] <review-input>' || true
          return 1
        }
        actor_explicit=1
        shift
        ;;
      --allow-self)
        allow_self=1
        shift
        ;;
      -h|--help)
        printf '%s\n' '用法：new z review [--actor <id>] [--allow-self] <review-input>'
        return 0
        ;;
      --*)
        review_reject review.usage "未知选项：$arg" || true
        return 1
        ;;
      *)
        [ -z "$input" ] || {
          review_reject review.usage 'Review 输入文件只能有一个' || true
          return 1
        }
        input="$arg"
        shift
        ;;
    esac
  done
  [ -n "$input" ] || {
    review_reject review.usage '缺少 Review 结构化输入文件' || true
    return 1
  }

  z_require_current_main
  completion_base="${Z_BASE:-origin/${Z_MAIN}}"
  if ! task_completion_gate "$Z_WT" "$completion_base" changed; then
    return 1
  fi
  if [ "${TASK_COMPLETION_HEAD:-}" != "${Z_HEAD:-}" ]; then
    review_reject review.head_changed \
      "未完成 / BLOCKED：Review 预检后 HEAD 已变化（${Z_HEAD:-空} → ${TASK_COMPLETION_HEAD:-空}），拒绝写 Review"
    return 1
  fi
  z_require_dev_status

  checkpoint="$(review_claim_actor "$Z_OWNER" "$Z_REPO" "$Z_NUMBER")" || return 1
  claim_actor="$checkpoint"
  if ! review_actor="$(task_actor_resolve "$actor_candidate" "$Z_WT" "$actor_explicit")"; then
    review_reject review.actor_missing 'actor 缺省链为空或非法；拒绝写 Review' || true
    return 1
  fi
  if [ "$review_actor" = "$claim_actor" ] && [ "$allow_self" = 1 ]; then
    if z_has_label human-merge; then
      human_merge=1
    fi
  fi
  if ! self_review="$(review_actor_policy "$review_actor" "$claim_actor" "$allow_self" "$human_merge")"; then
    return 1
  fi

  parsed="$(mktemp -t review-parsed.XXXXXX)"; TMPS="$TMPS $parsed"
  results="$(mktemp -t review-validators.XXXXXX)"; TMPS="$TMPS $results"
  effective="$(mktemp -t review-effective.XXXXXX)"; TMPS="$TMPS $effective"
  rendered="$(mktemp -t review-rendered.XXXXXX)"; TMPS="$TMPS $rendered"
  if ! review_parse_structured_input "$input" "$Z_CONTRACT_JSON" "$parsed"; then
    return 1
  fi
  review_run_validators "$parsed" "$results" || return 1
  review_apply_validator_results "$parsed" "$results" "$effective" || return 1
  diff_paths="$(contract_diff_paths "$Z_WT" "$Z_BASE" "$Z_HEAD")" || return 1
  review_render "$effective" "$results" "$rendered" "$review_actor" "$claim_actor" "$self_review" "$diff_paths"
  z_write_review_file "$rendered"
  printf '已写入结构化 Review（review_actor=%s claim_actor=%s Self-review=%s HEAD %s）。\n' \
    "$review_actor" "$claim_actor" "$self_review" "$Z_HEAD"
}
