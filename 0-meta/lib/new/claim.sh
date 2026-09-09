# 领取：claim remote 上建 refs/claims/<n>、分支加 -<n> 后缀、winner 重入。
# 由 task.sh 加载，不要单独执行。也给 z-lib 的 derive / 放行判定用。

task_claim_ref() {
  printf 'refs/claims/%s\n' "$1"
}

task_claim_host() {
  if [ -n "${CLAIM_HOST:-}" ]; then
    printf '%s\n' "$CLAIM_HOST"
    return 0
  fi
  hostname 2>/dev/null || uname -n 2>/dev/null
}

task_claim_lock_field() {
  local body="$1" key="$2"
  printf '%s\n' "$body" | awk -v k="$key" '
    index($0, k ": ") == 1 { print substr($0, length(k) + 3); exit }
  '
}

task_claim_lock_field_count() {
  local body="$1" key="$2"
  printf '%s\n' "$body" | awk -v p="$key: " '
    index($0, p) == 1 { n++ }
    END { print n + 0 }
  '
}

# origin 上以 -<n> 结尾的任务分支，每行一个。只给尚无 claim ref 的历史任务用。
z_remote_issue_branches() {
  local wt="${1:-$Z_WT}" n="$2" out rc=0
  [ -n "$wt" ] && [[ "$n" =~ ^[1-9][0-9]*$ ]] \
    || { echo "z_remote_issue_branches 参数不完整" >&2; return 1; }
  out="$(GIT_TERMINAL_PROMPT=0 git -C "$wt" ls-remote --heads origin 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    err_code task.remote_ref_unreadable "无法列出 origin 上的任务分支，停止"
    return 1
  fi
  printf '%s\n' "$out" | awk -v suf="-${n}" '
    NF >= 2 {
      ref = $2
      sub(/^refs\/heads\//, "", ref)
      if (ref != "" && length(ref) > length(suf) \
          && substr(ref, length(ref) - length(suf) + 1) == suf) print ref
    }
  '
}

# 只看耐久事实，不读 Project Status。
derive_task_state_decide() {
  local has_contract="$1" has_branch="$2" pr_kind="$3"
  if [ "$has_contract" != 1 ]; then
    printf '%s\n' "${TASK_STATUS_BACKLOG:-Backlog}"
    return 0
  fi
  case "$pr_kind" in
    merged)
      printf '%s\n' "${TASK_STATUS_DONE:-Done}"
      return 0
      ;;
    open)
      printf '%s\n' "${TASK_STATUS_REVIEW:-In review}"
      return 0
      ;;
  esac
  if [ "$has_branch" = 1 ]; then
    printf '%s\n' "${TASK_STATUS_PROGRESS:-In progress}"
    return 0
  fi
  printf '%s\n' "${TASK_STATUS_READY:-Ready}"
}

task_claim_pr_kind() {
  local prs="$1" matcher="$2" mode="$3"
  if [ "$mode" = exact ]; then
    printf '%s' "$prs" | jq -r --arg br "$matcher" '
      (map(select((.headRefName // "") == $br))) as $h
      | if any($h[]; (.mergedAt != null) and (.mergedAt != "")) then "merged"
        elif any($h[]; (.state == "OPEN") and (.isDraft != true)) then "open"
        else "none" end
    '
  else
    printf '%s' "$prs" | jq -r --arg s "$matcher" '
      (map(select((.headRefName // "") | endswith($s)))) as $h
      | if any($h[]; (.mergedAt != null) and (.mergedAt != "")) then "merged"
        elif any($h[]; (.state == "OPEN") and (.isDraft != true)) then "open"
        else "none" end
    '
  fi
}

task_claim_list_prs() {
  local head="${1:-}"
  [ -n "${Z_OWNER:-}" ] && [ -n "${Z_REPO:-}" ] \
    || { err_code task.issue_unbound "derive_task_state 缺少 owner/repo"; return 1; }
  [ -n "$head" ] || { err_code review.pr_unreadable "PR 查询需要精确 head，不用全仓窗口"; return 1; }
  GH_PAGER=cat gh pr list --repo "${Z_OWNER}/${Z_REPO}" --head "$head" --state all \
    --json number,headRefName,state,isDraft,mergedAt \
    || { err_code review.pr_unreadable "无法列出 ${Z_OWNER}/${Z_REPO} head=${head} 的 PR，无法推导状态"; return 1; }
}

# 读 origin 上的 refs/claims/<n>。0=stdout 为正文；2=不存在；1=不可读或字段不完整。
task_claim_read_lock() {
  local wt="$1" n="$2" ref sha body host worktree branch claim_actor
  ref="$(task_claim_ref "$n")"
  sha="$(GIT_TERMINAL_PROMPT=0 git -C "$wt" ls-remote origin "$ref" 2>/dev/null | awk '{print $1; exit}')" || {
    err_code task.remote_ref_unreadable "    ✗ 无法读取 origin 上的 ${ref}"
    return 1
  }
  if [ -z "$sha" ]; then
    return 2
  fi
  if ! GIT_TERMINAL_PROMPT=0 git -C "$wt" fetch --quiet origin "${ref}:${ref}"; then
    err_code task.remote_ref_unreadable "    ✗ 无法 fetch ${ref}"
    return 1
  fi
  body="$(git -C "$wt" log -1 --format=%B "$sha" 2>/dev/null)" || {
    err_code claim.lock_unreadable "    ✗ ${ref} 对象不可读"
    return 1
  }
  host="$(task_claim_lock_field "$body" host)"
  worktree="$(task_claim_lock_field "$body" worktree)"
  branch="$(task_claim_lock_field "$body" branch)"
  if [ "$(task_claim_lock_field_count "$body" claim_actor)" != 1 ]; then
    err_code claim.lock_actor "    ✗ ${ref} 必须含且仅含一个 claim_actor，停止"
    return 1
  fi
  claim_actor="$(task_claim_lock_field "$body" claim_actor)"
  if [ -z "$host" ] || [ -z "$worktree" ] || [ -z "$branch" ]; then
    err_code claim.lock_incomplete "    ✗ ${ref} 缺少 host/worktree/branch，停止"
    return 1
  fi
  task_actor_valid "$claim_actor" || {
    err_code claim.lock_actor "    ✗ ${ref} 的 claim_actor 非法，停止"
    return 1
  }
  printf '%s' "$body"
}

derive_task_state() {
  local n="$1" wt="${Z_WT:-}" main="${Z_MAIN:-main}"
  local has_contract=0 has_branch=0 pr_kind=none prs branches lock body winner rc=0
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || { err_code task.issue_number_invalid "derive_task_state 需要 Issue 编号"; return 1; }
  [ -n "$wt" ] || { err_code z.derive_args "derive_task_state 缺少工作树（Z_WT）"; return 1; }
  if git -C "$wt" cat-file -e "origin/${main}:$(contract_json_path "$n")" 2>/dev/null; then
    has_contract=1
  fi
  if [ "$has_contract" != 1 ]; then
    derive_task_state_decide 0 0 none
    return 0
  fi

  lock="$(task_claim_read_lock "$wt" "$n")" || rc=$?
  if [ "$rc" = 1 ]; then
    return 1
  fi
  if [ "$rc" = 0 ]; then
    winner="$(task_claim_lock_field "$lock" branch)"
    [ -n "$winner" ] || { err_code claim.lock_incomplete "    ✗ refs/claims/${n} 没有 winner branch"; return 1; }
    prs="$(task_claim_list_prs "$winner")" || return 1
    pr_kind="$(task_claim_pr_kind "$prs" "$winner" exact)"
    derive_task_state_decide 1 1 "$pr_kind"
    return 0
  fi

  branches="$(z_remote_issue_branches "$wt" "$n")" || return 1
  [ -n "$branches" ] && has_branch=1
  prs='[]'
  local br extra
  for br in $branches; do
    extra="$(task_claim_list_prs "$br")" || return 1
    prs="$(jq -c --argjson a "$prs" --argjson b "$extra" '$a + $b')"
  done
  pr_kind="$(task_claim_pr_kind "$prs" "-${n}" suffix)"
  derive_task_state_decide 1 "$has_branch" "$pr_kind"
}

z_warn_if_status_drift() {
  local derived="$1" project="${2:-}"
  [ -n "$project" ] || return 0
  [ "$project" = "$derived" ] && return 0
  c_warn "    ⚠ Project Status 是 ${project}，推导状态是 ${derived}（以推导为准，不写回）"
}

# origin 的 fetch URL。不得用 --push：#30 会把 origin push URL 改指本机暂存仓。
task_origin_fetch_url() {
  local wt="$1"
  git -C "$wt" remote get-url origin 2>/dev/null || true
}

# 命名 remote `claim` 必须等于 origin fetch URL。缺失或指错就改，不要求人操作。
task_ensure_claim_remote() {
  local wt="$1" want have
  want="$(task_origin_fetch_url "$wt")"
  [ -n "$want" ] || { err_code claim.no_origin "    ✗ 没有 origin fetch URL，无法建立 claim remote"; return 1; }
  if git -C "$wt" remote get-url claim >/dev/null 2>&1; then
    have="$(git -C "$wt" remote get-url claim 2>/dev/null || true)"
    if [ "$have" != "$want" ]; then
      git -C "$wt" remote set-url claim "$want" \
        || { err_code claim.claim_remote "    ✗ 无法把 claim remote 改回 origin fetch URL"; return 1; }
    fi
  else
    git -C "$wt" remote add claim "$want" \
      || { err_code claim.claim_remote "    ✗ 无法创建 claim remote"; return 1; }
  fi
  return 0
}

# 只看 porcelain 首字段：* = winner；= 或 ! = 已被领取。不得 grep 英文错误文本。
task_claim_porcelain_status() {
  local line field
  while IFS= read -r line; do
    case "$line" in
      To\ *|Done|'') continue ;;
    esac
    field="${line%%	*}"
    case "$field" in
      '*') printf 'won\n'; return 0 ;;
      '='|'!') printf 'taken\n'; return 0 ;;
    esac
  done
  printf 'fail\n'
}

task_claim_make_lock() {
  local wt="$1" n="$2" br="$3" host canon empty claim_actor
  claim_actor="${TASK_CLAIM_ACTOR:-}"
  if [ -z "$claim_actor" ]; then
    claim_actor="$(task_actor_resolve "" "$wt" "${TASK_CLAIM_ACTOR_EXPLICIT:-0}" || true)"
    [ -n "$claim_actor" ] || { err_code claim.actor_missing "    ✗ 无法解析 claim actor，拒绝创建领取锁"; return 1; }
    TASK_CLAIM_ACTOR="$claim_actor"
  fi
  task_actor_valid "$claim_actor" \
    || { err_code claim.actor_invalid "    ✗ claim actor 非法，拒绝创建领取锁"; return 1; }
  host="$(task_claim_host)"
  [ -n "$host" ] || { err_code claim.host_unreadable "    ✗ 读不到 host，无法写 claim 锁"; return 1; }
  canon="$(task_canon "$wt")"
  empty="$(git -C "$wt" hash-object -t tree /dev/null)" \
    || { err_code claim.lock_commit "    ✗ 无法得到空树"; return 1; }
  git -C "$wt" commit-tree "$empty" \
    -m "claim #${n}" \
    -m "issue: ${owner}/${repo}#${n}" \
    -m "host: ${host}" \
    -m "worktree: ${canon}" \
    -m "branch: ${br}" \
    -m "claim_actor: ${claim_actor}" \
    -m "at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

# 在 claim remote 上原子创建 refs/claims/<n>。0=本次 winner；2=已被领取；1=其它失败。
task_claim_create_lock() {
  local wt="$1" n="$2" br="$3" lock out rc=0 verdict
  [ -n "$wt" ] && [[ "$n" =~ ^[1-9][0-9]*$ ]] && [ -n "$br" ] \
    || { err_code claim.rename_args "    ✗ claim 锁参数不完整"; return 1; }
  task_ensure_claim_remote "$wt" || return 1
  lock="$(task_claim_make_lock "$wt" "$n" "$br")" \
    || { err_code claim.lock_commit "    ✗ 无法创建 claim 锁对象"; return 1; }
  out="$(GIT_TERMINAL_PROMPT=0 git -C "$wt" push --porcelain \
    --force-with-lease="$(task_claim_ref "$n"):" \
    claim "${lock}:$(task_claim_ref "$n")" 2>&1)" || rc=$?
  verdict="$(printf '%s\n' "$out" | task_claim_porcelain_status)"
  case "$verdict" in
    won) return 0 ;;
    taken) return 2 ;;
  esac
  err_code claim.push_failed "    ✗ claim push 失败（porcelain=${verdict} rc=${rc}）"
  return 1
}

task_claim_winner_matches() {
  local body="$1" wt="$2" br="$3"
  local host worktree branch canon
  host="$(task_claim_lock_field "$body" host)"
  worktree="$(task_claim_lock_field "$body" worktree)"
  branch="$(task_claim_lock_field "$body" branch)"
  [ -n "$host" ] && [ -n "$worktree" ] && [ -n "$branch" ] || return 1
  [ "$host" = "$(task_claim_host)" ] || return 1
  canon="$(task_canon "$wt")"
  [ "$worktree" = "$canon" ] || [ "$worktree" = "$wt" ] || return 1
  [ "$branch" = "$br" ]
}

task_ensure_issue_branch_suffix() {
  local wt="$1" br="$2" n="$3" new
  [ -n "$wt" ] && [ -n "$br" ] && [[ "$n" =~ ^[1-9][0-9]*$ ]] \
    || { err_code claim.rename_args "    ✗ 分支后缀参数不完整"; return 1; }
  if [ "$br" != "-${n}" ] && [ "${br%"-${n}"}" != "$br" ]; then
    printf '%s\n' "$br"
    return 0
  fi
  new="${br}-${n}"
  if ! task_rename_orca_flat_branch "$wt" "$br" "$new"; then
    return 1
  fi
  # Orca displayName 只是 adapter：未安装 orca、或这棵树不受 Orca 管理时，
  # git 改名仍然成立。
  if task_orca_manages_worktree "$wt"; then
    if ! orca worktree set --worktree "path:${wt}" --display-name "$new" --json >/dev/null; then
      err_code claim.rename_failed "    ✗ git 已改为 ${new}，但无法把 Orca displayName 改成同名"
      return 1
    fi
  fi
  printf '%s\n' "$new"
}

# 这棵树是否受 Orca 管理。orca 退出 0 但 ok=false（selector_not_found）不算。
task_orca_manages_worktree() {
  local wt="$1" js
  command -v orca >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  js="$(cd "$wt" && orca worktree current --json 2>/dev/null || true)"
  [ -n "$js" ] || return 1
  [ "$(printf '%s' "$js" | jq -r '.ok // false')" = true ]
}

task_checkpoint_body() {
  local owner="$1" repo="$2" number="$3" c
  if ! c="$(task_unique_marked_comment "$owner" "$repo" "$number" \
      "$TASK_CHECKPOINT_MARK" "Checkpoint")"; then
    return 1
  fi
  [ -n "$c" ] || { printf ''; return 0; }
  printf '%s' "$c" | jq -r '.body // empty'
}

# Checkpoint 的工作树/分支与当前一致。
task_checkpoint_matches_here() {
  local body="$1" wt="$2" git_br="$3" logical_br="${4:-$3}"
  local ck_wt ck_br canon_wt canon_ck
  ck_wt="$(task_review_table_field "$body" "工作树")"
  ck_br="$(task_review_table_field "$body" "分支")"
  [ -n "$ck_wt" ] && [ -n "$ck_br" ] || return 1
  canon_wt="$(task_canon "$wt")"
  canon_ck="$(task_canon "$ck_wt" 2>/dev/null || printf '%s' "$ck_wt")"
  [ "$canon_wt" = "$canon_ck" ] || [ "$ck_wt" = "$wt" ] || return 1
  case "$ck_br" in
    "$git_br"|"$logical_br"|"${logical_br}（git: ${git_br}）") return 0 ;;
  esac
  printf '%s' "$ck_br" | grep -Fq "$git_br" || return 1
}

task_claim_write_checkpoint() {
  local now_iso next_txt ck_ra ck_body by_cmd actor_label
  [ -n "${TASK_CLAIM_ACTOR:-}" ] && task_actor_valid "$TASK_CLAIM_ACTOR" \
    || { err_code claim.actor_missing "    ✗ Checkpoint 缺少有效 claim actor"; return 1; }
  now_iso="$(date +%Y-%m-%dT%H:%M:%S%z)"
  by_cmd="new task claim"
  [ -n "${agent:-}" ] && by_cmd="new task ${agent}"
  actor_label="${agent:-（无）}"
  if [ "${TASK_CLAIM_LAUNCH:-1}" = 0 ]; then
    next_txt="已领取。下一步：new z dev。只改允许范围（$(task_scope_oneline "$scope")）。失败步骤重新运行同一命令补齐，不要退回 Ready。"
  else
    next_txt="已领取并自动进入 zdev。只改允许范围（$(task_scope_oneline "$scope")）。失败步骤重新运行同一命令补齐，不要退回 Ready。"
  fi
  ck_ra="$(contract_checkpoint_pending_tables "$contract_json")"
  ck_body="$(cat <<EOF
${TASK_CHECKPOINT_MARK}
claim_actor=${TASK_CLAIM_ACTOR}
## Checkpoint

由 \`${by_cmd}\` 写入或更新，同一条评论反复覆盖，不另开新楼。

| 项 | 值 |
| --- | --- |
| Issue | ${owner}/${repo}#${number} |
| Contract | ${contract_blob} |
| Agent | \`${actor_label}\`（${agent_bin:-未启动}） |
| claim_actor | \`${TASK_CLAIM_ACTOR}\` |
| 分支 | ${logical_br}（git: ${git_br}） |
| 工作树 | \`${wt}\` |
| 启动时间 | ${now_iso} |
| HEAD | \`${head}\` |
| 工作区状态 | ${ws_status} |
| 允许范围 | $(task_scope_oneline "$scope") |
| Project | ${TASK_PROJECT_TITLE} #${TASK_PROJECT_NUMBER} Status=${TASK_STATUS_PROGRESS} |
| PR | 无 |
| 下一步 | ${next_txt} |

${ck_ra}

### 验证证据

\`\`\`
${evidence}领取以 refs/claims/${number} 为准；Status 是视图
\`\`\`
EOF
)"
  task_write_checkpoint "$owner" "$repo" "$number" "$ck_body"
}

task_claim_try_status_progress() {
  local item_id project_id field_id to_id
  [ -n "$item_json" ] || return 1
  item_id="$(printf '%s' "$item_json" | jq -r '.id // empty')"
  project_id="$(printf '%s' "$item_json" | jq -r '.project.id // empty')"
  field_id="$(printf '%s' "$item_json" | jq -r '.fieldValueByName.field.id // empty')"
  to_id="$(task_option_id "$item_json" "$TASK_STATUS_PROGRESS")"
  [ -n "$item_id" ] && [ -n "$project_id" ] && [ -n "$field_id" ] && [ -n "$to_id" ] || return 1
  task_set_status "$item_id" "$project_id" "$field_id" "$to_id" || return 1
  if ! task_fetch_issue "$owner" "$repo" "$number" "$issue_json"; then
    return 1
  fi
  item_json="$(task_project_item "$issue_json" || true)"
  project_status="$(printf '%s' "$item_json" | jq -r '.fieldValueByName.name // empty')"
  [ "$project_status" = "$TASK_STATUS_PROGRESS" ]
}

task_claim_start_agent() {
  local prompt
  local claim_main="${main:-${Z_MAIN:-main}}"
  local claim_blob="${contract_blob:-${Z_CONTRACT_BLOB:-unknown}}"
  local claim_logical="${logical_br:-${Z_LOGICAL_BR:-${git_br:-unknown}}}"
  local claim_git="${git_br:-${Z_GIT_BR:-$claim_logical}}"
  local claim_head="${head:-${Z_HEAD:-unknown}}"
  echo
  c_ok "✓ 领取完成，当前终端启动 ${agent} 并自动执行 zdev"
  cd "$wt" || { err_code claim.chdir_failed "无法进入 $wt"; return 1; }
  prompt="$(task_agent_start_prompt "${TASK_START_PROMPT_VARIANT}" \
      "$number" "$issue_url" "$wt" "$scope" \
      "$TASK_STATUS_PROGRESS" "$owner" "$repo" "$agent" \
      "$claim_main" "$claim_blob" "$claim_logical" "$claim_git" "$claim_head")" \
    || { err_code claim.prompt_failed "无法构造 ${agent} 开工 prompt"; return 1; }
  metrics_set loaded_bytes "$(task_prompt_loaded_bytes "$wt" "$prompt")"
  export NEW_TASK_ACTOR="${TASK_CLAIM_ACTOR:-}"
  export NEW_TASK_AGENT="$agent"
  metrics_emit ok ""
  if [ "${TASK_CLAIM_NO_EXEC:-}" = 1 ]; then
    printf '%s\n' "CLAIM_EXEC ${agent}"
    return 0
  fi
  tmp_cleanup
  exec "$agent_bin" "$prompt" || {
    err_code claim.exec_failed "启动 ${agent} 失败（${agent_bin}）。领取已成立，重新运行同一命令补齐，不退回 Ready。"
    # claim 已经成立且 success 事件已追加；metrics 是 append-only，启动失败
    # 不能把同一条 claim 改写成第二条 fail。失败信息仍按原命令语义返回。
    return 1
  }
}

task_claim_resume() {
  local lock body rc=0 lock_actor checkpoint_actor
  lock="$(task_claim_read_lock "$wt" "$number")" || rc=$?
  if [ "$rc" != 0 ]; then
    err_code claim.lock_unreadable "    ✗ 无法读取 refs/claims/${number}，拒绝猜测 resume。"
    return 1
  fi
  if ! task_claim_winner_matches "$lock" "$wt" "$git_br"; then
    err_code claim.already_taken "    ✗ 已被领取（锁内 winner 不是当前 host/worktree/branch）。不写 Status、不写 Checkpoint。"
    return 1
  fi
  lock_actor="$(task_claim_lock_field "$lock" claim_actor)"
  task_actor_valid "$lock_actor" || {
    err_code claim.lock_actor "    ✗ 领取锁的 claim_actor 非法，拒绝 resume"
    return 1
  }
  # resume 只恢复耐久 claim provenance；当前重跑者不能覆盖 claim actor。
  TASK_CLAIM_ACTOR="$lock_actor"
  if ! body="$(task_checkpoint_body "$owner" "$repo" "$number")"; then
    err_code task.comment_ambiguous "    ✗ 无法读取 Checkpoint，拒绝猜测"
    return 1
  fi
  if [ -n "$body" ]; then
    if [ "$(task_machine_field_count "$body" claim_actor)" != 1 ]; then
      err_code claim.checkpoint_actor "    ✗ Checkpoint 必须含且仅含一个 claim_actor machine field。不写 Status、不写 Checkpoint。"
      return 1
    fi
    checkpoint_actor="$(task_machine_field "$body" claim_actor)"
    task_actor_valid "$checkpoint_actor" || {
      err_code claim.checkpoint_actor "    ✗ Checkpoint 的 claim_actor 非法。不写 Status、不写 Checkpoint。"
      return 1
    }
    [ "$checkpoint_actor" = "$lock_actor" ] || {
      err_code claim.checkpoint_actor "    ✗ Checkpoint claim_actor=${checkpoint_actor} 与领取锁 claim_actor=${lock_actor} 不一致。不写 Status、不写 Checkpoint。"
      return 1
    }
    [ "$(task_review_table_field "$body" claim_actor)" = "$lock_actor" ] || {
      err_code claim.checkpoint_actor "    ✗ Checkpoint 表格 claim_actor 与领取锁不一致。不写 Status、不写 Checkpoint。"
      return 1
    }
    if ! task_checkpoint_matches_here "$body" "$wt" "$git_br" "$logical_br"; then
      err_code claim.already_taken "    ✗ 已被领取（Checkpoint 指向其它工作树或分支）。不写 Status、不写 Checkpoint。"
      return 1
    fi
    if ! task_checkpoint_matches_here "$body" "$(task_claim_lock_field "$lock" worktree)" \
        "$(task_claim_lock_field "$lock" branch)" "$(task_claim_lock_field "$lock" branch)"; then
      err_code claim.already_taken "    ✗ 已被领取（Checkpoint 与锁内 winner 冲突）。不写 Status、不写 Checkpoint。"
      return 1
    fi
  fi
  if [ "${project_status:-}" != "$TASK_STATUS_PROGRESS" ]; then
    if [ -z "${item_json:-}" ]; then
      err_code claim.not_on_project "    ✗ 领取已成立，但 Issue 不在 ${TASK_PROJECT_TITLE} 上，Status 未写。重新运行同一命令补齐，不退回。"
      return 1
    fi
    if ! task_claim_try_status_progress; then
      err_code claim.status_update_failed "    ✗ 领取已成立，但 Status 未能写成 ${TASK_STATUS_PROGRESS}。重新运行同一命令补齐，不退回 Ready。"
      return 1
    fi
    c_ok "    ✓ 已补齐 Status → ${TASK_STATUS_PROGRESS}"
  fi
  if [ -n "$body" ]; then
    c_ok "    ✓ winner 重入：不 push claim，Checkpoint 保持"
  else
    if ! task_claim_write_checkpoint; then
      err_code claim.checkpoint_write_failed "    ✗ 领取已成立，Checkpoint 仍缺失。重新运行同一命令补齐，不退回 Ready。"
      return 1
    fi
    c_ok "    ✓ 已补齐 Checkpoint"
  fi
  task_claim_finish
}

task_claim_first() {
  local rc=0
  task_claim_create_lock "$wt" "$number" "$git_br" || rc=$?
  if [ "$rc" = 2 ]; then
    err_code claim.already_taken "    ✗ 已被领取。不写 Status、不写 Checkpoint。"
    return 1
  fi
  [ "$rc" = 0 ] || return 1
  c_ok "    ✓ refs/claims/${number} 已创建（领取成立）"

  if [ -z "$item_json" ]; then
    err_code claim.not_on_project "    ✗ 领取已成立，但 Issue 不在 ${TASK_PROJECT_TITLE} 上，Status 未写。重新运行同一命令补齐，不退回。"
    return 1
  fi
  if ! task_claim_try_status_progress; then
    err_code claim.status_update_failed "    ✗ 领取已成立，但 Status 未能写成 ${TASK_STATUS_PROGRESS}。重新运行同一命令补齐，不退回 Ready。"
    return 1
  fi
  c_ok "    ✓ ${TASK_STATUS_READY} → ${TASK_STATUS_PROGRESS}"

  echo "── Checkpoint ───────────────────────────"
  if ! task_claim_write_checkpoint; then
    err_code claim.checkpoint_write_failed "    ✗ 领取已成立，Checkpoint 未写入。重新运行同一命令补齐，不退回 Ready。"
    return 1
  fi
  c_ok "    ✓ 已写入同一条 Checkpoint 评论"
  task_claim_finish
}

# grok/codex adapter 才启动产品；`new task claim` 在领取完成后停。
task_claim_finish() {
  local card
  local claim_main="${main:-${Z_MAIN:-main}}"
  local claim_blob="${contract_blob:-${Z_CONTRACT_BLOB:-unknown}}"
  local claim_logical="${logical_br:-${Z_LOGICAL_BR:-${git_br:-unknown}}}"
  local claim_git="${git_br:-${Z_GIT_BR:-$claim_logical}}"
  local claim_head="${head:-${Z_HEAD:-unknown}}"
  card="$(task_start_card "$owner" "$repo" "$number" "$issue_url" "$claim_main" \
    "$claim_blob" "$wt" "$claim_logical" "$claim_git" "$TASK_STATUS_PROGRESS" \
    "$scope" "new z dev" "$claim_head")" \
    || { err_code claim.start_card_failed "无法构造 canonical start card"; return 1; }
  metrics_set loaded_bytes "$(task_prompt_loaded_bytes "$wt" "$card")"
  if [ "${TASK_CLAIM_LAUNCH:-1}" = 0 ]; then
    echo
    c_ok "✓ 领取完成，未启动 Agent。下一步：new z dev"
    printf '%s\n' "$card"
    return 0
  fi
  task_claim_start_agent
}

# 依赖 cmd_task 局部变量（动态作用域）。
task_claim_or_resume() {
  local new_br derived rc=0 actor_candidate actor_explicit
  actor_candidate="${TASK_CLAIM_ACTOR:-}"
  actor_explicit="${TASK_CLAIM_ACTOR_EXPLICIT:-0}"
  echo "── claim remote ─────────────────────────"
  task_ensure_claim_remote "$wt" || return 1
  c_ok "    ✓ claim = origin fetch URL"

  new_br="$(task_ensure_issue_branch_suffix "$wt" "$git_br" "$number")" || return 1
  if [ "$new_br" != "$git_br" ]; then
    git_br="$new_br"
    logical_br="$new_br"
    c_ok "    ✓ 分支已加 Issue 后缀：${git_br}"
  fi

  Z_WT="$wt"
  Z_MAIN="$main"
  Z_OWNER="$owner"
  Z_REPO="$repo"
  derived="$(derive_task_state "$number")" || return 1
  z_warn_if_status_drift "$derived" "$project_status"

  case "$derived" in
    "$TASK_STATUS_REVIEW")
      err_code claim.not_resume_review "    ✗ 推导状态是 ${TASK_STATUS_REVIEW}，不是 resume 入口。"
      return 1
      ;;
    "$TASK_STATUS_DONE"|"$TASK_STATUS_BACKLOG")
      err_code claim.not_ready "    ✗ 推导状态是 ${derived}，不能领取。"
      return 1
      ;;
    "$TASK_STATUS_PROGRESS")
      task_claim_resume
      return
      ;;
    "$TASK_STATUS_READY")
      if ! TASK_CLAIM_ACTOR="$(task_actor_resolve "$actor_candidate" "$wt" "$actor_explicit")"; then
        err_code claim.actor_missing "    ✗ actor 缺省链为空或非法；不写 claim、Status 或 Checkpoint"
        return 1
      fi
      task_claim_first
      return
      ;;
    *)
      err_code claim.not_ready "    ✗ 无法推导状态（${derived:-空}）"
      return 1
      ;;
  esac
}
