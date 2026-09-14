# zmerge 互斥、持锁复读、按事实 finalize。由 squash-merge.sh 加载，不要单独执行。

zmerge_lock_path() {
  local common
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [ -z "$common" ] || [ "$common" = --git-common-dir ]; then
    common="$(git rev-parse --git-common-dir)" || return 1
    case "$common" in
      /*) ;;
      *) common="$(cd "$common" && pwd -P)" || return 1 ;;
    esac
  fi
  [ -n "$common" ] || return 1
  printf '%s/zmerge.lock\n' "$common"
}

# 0=拿到锁；2=已被占用（不排队）；1=其它失败。
# 持锁进程由 bash 后台拉起，不用命令替换，避免等进程组死锁。
z_merge_lock_acquire() {
  local path status holder i line
  path="$(zmerge_lock_path)" || {
    err_code z.merge_lock_failed "读不到 git common dir，无法加 zmerge 锁"
    return 1
  }
  holder="${ZMERGE_LOCK_HOLDER:-$ROOT/.agents/skills/zmerge/scripts/hold-lock.py}"
  [ -f "$holder" ] || {
    err_code z.merge_lock_failed "找不到锁持有脚本 ${holder}"
    return 1
  }
  status="${path}.status.$$"
  rm -f "$status"
  python3 "$holder" "$path" "$status" &
  ZMERGE_LOCK_PID=$!
  ZMERGE_LOCK_PATH="$path"
  ZMERGE_LOCK_STATUS="$status"
  for i in $(seq 1 40); do
    if [ -f "$status" ]; then
      line="$(cat "$status" 2>/dev/null || true)"
      case "$line" in
        ok) return 0 ;;
        busy)
          wait "$ZMERGE_LOCK_PID" 2>/dev/null || true
          ZMERGE_LOCK_PID=""
          rm -f "$status"
          err_code z.merge_locked "另一个 zmerge 正在运行（锁 ${path}）。不排队。
下一步：new z merge"
          return 2
          ;;
        fail)
          wait "$ZMERGE_LOCK_PID" 2>/dev/null || true
          ZMERGE_LOCK_PID=""
          rm -f "$status"
          err_code z.merge_lock_failed "无法获取 zmerge 锁"
          return 1
          ;;
      esac
    fi
    if ! kill -0 "$ZMERGE_LOCK_PID" 2>/dev/null; then
      wait "$ZMERGE_LOCK_PID" 2>/dev/null || true
      ZMERGE_LOCK_PID=""
      rm -f "$status"
      err_code z.merge_lock_failed "锁进程意外退出"
      return 1
    fi
    sleep 0.05
  done
  kill "$ZMERGE_LOCK_PID" 2>/dev/null || true
  wait "$ZMERGE_LOCK_PID" 2>/dev/null || true
  ZMERGE_LOCK_PID=""
  rm -f "$status"
  err_code z.merge_lock_failed "等待 zmerge 锁超时"
  return 1
}

z_merge_lock_release() {
  if [ -n "${ZMERGE_LOCK_PID:-}" ]; then
    kill "$ZMERGE_LOCK_PID" 2>/dev/null || true
    wait "$ZMERGE_LOCK_PID" 2>/dev/null || true
    ZMERGE_LOCK_PID=""
  fi
  if [ -n "${ZMERGE_LOCK_STATUS:-}" ]; then
    rm -f "$ZMERGE_LOCK_STATUS"
    ZMERGE_LOCK_STATUS=""
  fi
}

zmerge_find_merged_pr() {
  local owner="$1" repo="$2" head="$3" base="$4" js n
  if ! js="$(GH_PAGER=cat gh pr list \
      --repo "${owner}/${repo}" \
      --head "$head" \
      --base "$base" \
      --state merged \
      --limit 20 \
      --json number,url,headRefName,baseRefName,state,title,headRefOid,mergeCommit)"; then
    err_code z.pr_list_failed "读取已合并 PR 列表失败"
    return 2
  fi
  n="$(printf '%s' "$js" | jq 'length' 2>/dev/null || true)"
  if ! [[ "$n" =~ ^[0-9]+$ ]]; then
    err_code z.pr_list_failed "已合并 PR 列表无法解析"
    return 2
  fi
  if [ "$n" = 0 ]; then
    printf ''
    return 0
  fi
  printf '%s' "$js" | jq -c '.[0]'
}

# 为当前 tip 取 squash 等价证明。优先本轮 ZMERGE_MERGED_PR（headRefOid 必须
# 等于 tip，mergeCommit 可空以便走 unobserved）；否则从该任务分支已 MERGED
# PR 里挑 headRefOid 等于 tip 的一条。stdout 为 PR json 或空。
# return 2 = 列表读取失败。
zmerge_squash_proof_pr() {
  local tip="$1" pr_head js n
  if [ -n "${ZMERGE_MERGED_PR:-}" ]; then
    pr_head="$(printf '%s' "$ZMERGE_MERGED_PR" | jq -r '.headRefOid // empty' 2>/dev/null || true)"
    if [ "$pr_head" = "$tip" ]; then
      printf '%s' "$ZMERGE_MERGED_PR"
      return 0
    fi
  fi
  if ! js="$(GH_PAGER=cat gh pr list \
      --repo "${Z_OWNER}/${Z_REPO}" \
      --head "$Z_GIT_BR" \
      --base "$Z_MAIN" \
      --state merged \
      --limit 20 \
      --json number,url,headRefName,baseRefName,state,title,headRefOid,mergeCommit)"; then
    err_code z.pr_list_failed "读取已合并 PR 列表失败"
    return 2
  fi
  n="$(printf '%s' "$js" | jq 'length' 2>/dev/null || true)"
  if ! [[ "$n" =~ ^[0-9]+$ ]]; then
    err_code z.pr_list_failed "已合并 PR 列表无法解析"
    return 2
  fi
  printf '%s' "$js" | jq -c --arg tip "$tip" \
    'map(select(.headRefOid == $tip)) | .[0] // empty'
}

# 0=有 PR；1=确认无 PR；2=读取失败。
zmerge_any_pr_for_head() {
  local owner="$1" repo="$2" head="$3" js n
  if ! js="$(GH_PAGER=cat gh pr list \
      --repo "${owner}/${repo}" \
      --head "$head" \
      --state all \
      --limit 20 \
      --json number,state)"; then
    err_code z.pr_list_failed "读取 PR 列表失败"
    return 2
  fi
  n="$(printf '%s' "$js" | jq 'length' 2>/dev/null || true)"
  if ! [[ "$n" =~ ^[0-9]+$ ]]; then
    err_code z.pr_list_failed "PR 列表无法解析"
    return 2
  fi
  [ "$n" != 0 ]
}

# 设置 ZMERGE_ACTION=merge|finalize。finalize 时 ZMERGE_MERGED_PR 可能为空。
zmerge_decide_action() {
  local merged any_rc=0
  ZMERGE_ACTION=""
  ZMERGE_MERGED_PR=""
  merged="$(zmerge_find_merged_pr "$Z_OWNER" "$Z_REPO" "$Z_GIT_BR" "$Z_MAIN")" || return 1
  if [ -n "$merged" ]; then
    ZMERGE_ACTION=finalize
    ZMERGE_MERGED_PR="$merged"
    return 0
  fi
  zmerge_any_pr_for_head "$Z_OWNER" "$Z_REPO" "$Z_GIT_BR" || any_rc=$?
  case "$any_rc" in
    0) ;;
    1)
      z_fetch_origin_main "$Z_WT" "$Z_MAIN" || return 1
      if git -C "$Z_WT" merge-base --is-ancestor HEAD "origin/${Z_MAIN}"; then
        ZMERGE_ACTION=finalize
        return 0
      fi
      ;;
    *)
      return 1
      ;;
  esac
  ZMERGE_ACTION=merge
}

# 持锁后最后复读。放行看 derive_task_state；Project Status 只警告。
zmerge_reread_before_merge() {
  local derived project pr pr_num js head_oid cur_blob

  Z_HEAD="$(git -C "$Z_WT" rev-parse HEAD)" || {
    err_code task.head_unreadable "读不到 HEAD"
    return 1
  }
  z_fetch_origin_main "$Z_WT" "$Z_MAIN" || return 1
  if ! z_main_is_current "$Z_WT" "origin/${Z_MAIN}" HEAD; then
    err_code z.main_ahead "main 已前进，请显式执行 zsync。
如果同步导致 HEAD 改变，旧 Review 将失效，需重新 zreview。"
    return 1
  fi

  z_require_passing_review || return 1
  z_require_auto_merge_safe_review || return 1

  contract_fetch_main "$Z_WT" "$Z_MAIN" \
    || { err_code contract.fetch_main_failed "无法 fetch origin/${Z_MAIN}，不使用本地陈旧副本"; return 1; }
  cur_blob="$(contract_main_blob "$Z_WT" "$Z_NUMBER" "$Z_MAIN")" \
    || { err_code contract.missing "origin/${Z_MAIN} 上没有契约，拒绝 merge"; return 1; }
  if contract_stale "$Z_CONTRACT_BLOB" "$cur_blob" "合并前复读"; then
    err_code contract.stale "契约已重新批准，拒绝 merge。重新 zreview 后再试。"
    return 1
  fi

  pr="$(task_find_matching_pr "$Z_OWNER" "$Z_REPO" "$Z_GIT_BR" "$Z_MAIN")" \
    || { err_code z.pr_ambiguous "找不到唯一匹配 PR（不唯一则停止）"; return 1; }
  [ -n "$pr" ] || { err_code z.pr_missing "没有 head=${Z_GIT_BR} base=${Z_MAIN} 的未关闭 PR，停止"; return 1; }
  pr_num="$(printf '%s' "$pr" | jq -r '.number // empty')"
  js="$(task_pr_view_json "$Z_OWNER" "$Z_REPO" "$pr_num")" \
    || { err_code task.pr_unreadable "回读 PR 失败"; return 1; }
  if [ "$(printf '%s' "$js" | jq -r '.title // empty')" != "$Z_SQUASH_TITLE" ]; then
    err_code z.pr_title_mismatch "远端 PR 标题与 Squash-Title 不一致（已被改过则停止，不静默修正）：$(printf '%s' "$js" | jq -r '.title // empty')"
    return 1
  fi
  task_pr_fields_ok "$js" "$Z_GIT_BR" "$Z_MAIN" "$Z_NUMBER" "$Z_SQUASH_TITLE" \
    || { err_code z.pr_fields "PR 非 Draft / head / base / Fixes / 标题 未通过"; return 1; }
  head_oid="$(printf '%s' "$js" | jq -r '.headRefOid // empty')"
  [ "$head_oid" = "$Z_HEAD" ] || {
    err_code z.pr_head_changed "远端 PR head 已变化（${head_oid:-空} ≠ ${Z_HEAD}），需要重新 zreview"
    return 1
  }

  if ! task_fetch_issue "$Z_OWNER" "$Z_REPO" "$Z_NUMBER" "$Z_ISSUE_JSON"; then
    err_code task.issue_fetch_failed "无法读取 Issue / Project 状态"
    return 1
  fi
  derived="$(derive_task_state "$Z_NUMBER")" \
    || { err_code z.derive_failed "无法推导任务状态"; return 1; }
  project="$(task_read_status_name "$Z_ISSUE_JSON" || true)"
  z_warn_if_status_drift "$derived" "$project"
  case "$derived" in
    "$TASK_STATUS_PROGRESS"|"$TASK_STATUS_REVIEW") ;;
    *)
      err_code z.wrong_dev_status "推导状态不是 ${TASK_STATUS_PROGRESS} 或 ${TASK_STATUS_REVIEW}（当前：${derived:-空}）。"
      return 1
      ;;
  esac
  ZMERGE_PR_NUM="$pr_num"
  ZMERGE_PR_JSON="$js"
}

zmerge_find_main_worktree() {
  local main="${Z_MAIN:-main}" found
  found="$(git -C "${Z_WT:-.}" worktree list --porcelain | awk -v main="$main" '
    $1 == "worktree" { wt = substr($0, 10); next }
    $1 == "branch" && $2 == "refs/heads/" main { n++; found = wt }
    END { if (n == 1 && found != "") print found; else exit 1 }
  ')" || return 1
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

# 条件不满足只打印「本地 main 未同步」并返回 0。真正 ff 失败返回 1。
zmerge_ff_local_main() {
  local main_wt why now want
  ZMERGE_FF_HARD_FAIL=0
  if ! z_fetch_origin_main "$Z_WT" "${Z_MAIN:-main}"; then
    echo "本地 main 未同步"
    return 0
  fi
  if ! main_wt="$(zmerge_find_main_worktree)"; then
    echo "本地 main 未同步"
    return 0
  fi
  if [ "$(git -C "$main_wt" symbolic-ref --short HEAD 2>/dev/null || true)" != "${Z_MAIN:-main}" ]; then
    echo "本地 main 未同步"
    return 0
  fi
  if [ -n "$(git -C "$main_wt" -c core.quotePath=false status --porcelain 2>/dev/null || true)" ]; then
    echo "本地 main 未同步"
    return 0
  fi
  if why="$(task_git_busy "$main_wt")"; then
    echo "本地 main 未同步"
    return 0
  fi
  if ! git -C "$main_wt" merge-base --is-ancestor HEAD "origin/${Z_MAIN:-main}"; then
    echo "本地 main 未同步"
    return 0
  fi
  if ! git -C "$main_wt" merge --ff-only "origin/${Z_MAIN:-main}"; then
    echo "本地 main 未同步"
    ZMERGE_FF_HARD_FAIL=1
    return 1
  fi
  now="$(git -C "$main_wt" rev-parse HEAD)"
  want="$(git -C "$main_wt" rev-parse "origin/${Z_MAIN:-main}")"
  if [ "$now" != "$want" ]; then
    echo "本地 main 未同步"
    ZMERGE_FF_HARD_FAIL=1
    return 1
  fi
  echo "本地 main 已 ff-only 到 origin/${Z_MAIN:-main}（${now:0:12}）。"
  return 0
}

# porcelain 首字段：- = 已删除；! = 拒绝（含 lease stale）。不得 grep 英文错误文本。
zmerge_delete_porcelain_status() {
  local line field
  while IFS= read -r line; do
    case "$line" in
      To\ *|Done|'') continue ;;
    esac
    field="${line%%	*}"
    case "$field" in
      -) printf 'deleted\n'; return 0 ;;
      !) printf 'rejected\n'; return 0 ;;
    esac
  done
  printf 'fail\n'
}

# squash 后 GitHub 对 mergeCommit 最终一致。有界等待，超时仍为空则
# z.merge_commit_unobserved：不删分支、不二次 merge。
# 测试可设 ZMERGE_MERGE_COMMIT_TRIES / ZMERGE_MERGE_COMMIT_SLEEP。
zmerge_observe_merge_commit() {
  local owner="$1" repo="$2" pr_num="$3"
  local tries="${ZMERGE_MERGE_COMMIT_TRIES:-8}"
  local sleep_s="${ZMERGE_MERGE_COMMIT_SLEEP:-1}"
  local i=1 json oid state
  while [ "$i" -le "$tries" ]; do
    json="$(GH_PAGER=cat gh pr view "$pr_num" --repo "${owner}/${repo}" \
        --json state,mergeCommit,title,headRefOid)" \
      || { err_code z.finalize_incomplete "远端已合并;finalize 未完成:回读 PR"; return 1; }
    state="$(printf '%s' "$json" | jq -r '.state // empty')"
    oid="$(printf '%s' "$json" | jq -r '.mergeCommit.oid // empty')"
    if [ -n "$oid" ]; then
      printf '%s' "$json"
      return 0
    fi
    if [ "$state" = MERGED ] && [ "$i" -lt "$tries" ]; then
      sleep "$sleep_s"
    elif [ "$state" = MERGED ]; then
      err_code z.merge_commit_unobserved "squash 后 PR 已 MERGED，但 mergeCommit 仍未观察，拒绝删分支、不二次 merge"
      return 1
    else
      err_code z.not_merged "PR 状态不是 MERGED"
      return 1
    fi
    i=$((i + 1))
  done
  err_code z.merge_commit_unobserved "squash 后 PR 已 MERGED，但 mergeCommit 仍未观察，拒绝删分支、不二次 merge"
  return 1
}

zmerge_delete_remote_branch() {
  local tip out rc=0 verdict proof pr_head merge_oid
  task_branch_pushable "$Z_GIT_BR" "$Z_MAIN" || {
    err_code z.delete_branch_denied "拒绝删除远端分支：${Z_GIT_BR}"
    return 1
  }
  if ! tip="$(GIT_TERMINAL_PROMPT=0 git -C "$Z_WT" ls-remote origin "refs/heads/${Z_GIT_BR}")"; then
    err_code z.delete_branch_failed "无法确认远端 ref 状态：origin/refs/heads/${Z_GIT_BR}（git ls-remote 失败）"
    return 1
  fi
  tip="$(printf '%s\n' "$tip" | awk 'NF >= 1 { print $1; exit }')"
  if [ -z "$tip" ]; then
    echo "远端已无 ${Z_GIT_BR}，不删本地分支。"
    return 0
  fi
  z_fetch_origin_main "$Z_WT" "$Z_MAIN" || return 1
  if ! git -C "$Z_WT" cat-file -e "${tip}^{commit}" 2>/dev/null; then
    if ! GIT_TERMINAL_PROMPT=0 git -C "$Z_WT" fetch --quiet origin "$tip"; then
      err_code z.delete_branch_not_in_main "读不到远端 ${Z_GIT_BR} tip ${tip:0:12}，拒绝删除"
      return 1
    fi
  fi
  if ! git -C "$Z_WT" merge-base --is-ancestor "$tip" "origin/${Z_MAIN}"; then
    proof="$(zmerge_squash_proof_pr "$tip")" || return 1
    pr_head="$(printf '%s' "$proof" | jq -r '.headRefOid // empty' 2>/dev/null || true)"
    merge_oid="$(printf '%s' "$proof" | jq -r '.mergeCommit.oid // empty' 2>/dev/null || true)"
    if [ -z "$proof" ]; then
      err_code z.delete_branch_not_in_main "远端 ${Z_GIT_BR}（${tip:0:12}）既未进入 origin/${Z_MAIN}，也没有 headRefOid 与 tip 相等且 mergeCommit 已进入主线的 MERGED PR，拒绝删除"
      return 1
    fi
    if [ "$pr_head" = "$tip" ] && [ -z "$merge_oid" ]; then
      err_code z.merge_commit_unobserved "远端 ${Z_GIT_BR} 的 MERGED PR head 等于 tip，但 mergeCommit 尚未观察，拒绝删除"
      return 1
    fi
    if [ -n "$merge_oid" ] && ! git -C "$Z_WT" cat-file -e "${merge_oid}^{commit}" 2>/dev/null; then
      GIT_TERMINAL_PROMPT=0 git -C "$Z_WT" fetch --quiet origin "$merge_oid" 2>/dev/null || true
    fi
    if [ "$pr_head" != "$tip" ] \
        || [ -z "$merge_oid" ] \
        || ! git -C "$Z_WT" merge-base --is-ancestor "$merge_oid" "origin/${Z_MAIN}"; then
      err_code z.delete_branch_not_in_main "远端 ${Z_GIT_BR}（${tip:0:12}）既未进入 origin/${Z_MAIN}，也没有 headRefOid 与 tip 相等且 mergeCommit 已进入主线的 MERGED PR，拒绝删除"
      return 1
    fi
  fi
  out="$(GIT_TERMINAL_PROMPT=0 git -C "$Z_WT" push --porcelain \
    --force-with-lease="refs/heads/${Z_GIT_BR}:${tip}" \
    origin ":refs/heads/${Z_GIT_BR}" 2>&1)" || rc=$?
  verdict="$(printf '%s\n' "$out" | zmerge_delete_porcelain_status)"
  if [ "$verdict" = deleted ]; then
    echo "远端 ${Z_GIT_BR} 已删除（porcelain=deleted）。"
    return 0
  fi
  if [ "$verdict" = rejected ]; then
    err_code z.delete_branch_lease_stale "远端 ${Z_GIT_BR} 在读取后被推进，lease 拒绝删除（不重试无 lease）"
    return 1
  fi
  err_code z.delete_branch_failed "删除远端任务分支失败：${Z_GIT_BR}（porcelain=${verdict} rc=${rc}）"
  return 1
}

zmerge_report_main_title() {
  local oid title expect msg
  expect="${Z_SQUASH_TITLE:-}"
  if [ -z "$expect" ] && [ -n "${ZMERGE_MERGED_PR:-}" ]; then
    expect="$(printf '%s' "$ZMERGE_MERGED_PR" | jq -r '.title // empty')"
  fi
  oid=""
  if [ -n "${ZMERGE_MERGED_PR:-}" ]; then
    oid="$(printf '%s' "$ZMERGE_MERGED_PR" | jq -r '.mergeCommit.oid // empty')"
  fi
  if [ -z "$oid" ]; then
    echo "主线标题：无 merge commit 可核对（只报告不修改）"
    return 0
  fi
  title="$(git -C "$Z_WT" log -1 --format=%s "$oid" 2>/dev/null || true)"
  if [ -z "$title" ] && [ -n "${Z_OWNER:-}" ] && [ -n "${Z_REPO:-}" ]; then
    msg="$(GH_PAGER=cat gh api "repos/${Z_OWNER}/${Z_REPO}/git/commits/${oid}" --jq .message 2>/dev/null || true)"
    title="$(printf '%s\n' "$msg" | awk 'NR==1 { print; exit }')"
  fi
  if [ -n "$expect" ] && [ "$title" != "$expect" ]; then
    echo "主线提交标题与 Squash-Title 不一致（只报告不修改）：${title:-空}"
    return 0
  fi
  echo "主线提交标题与 Squash-Title 一致：${title:-空}"
  return 0
}

zmerge_deliver_review() {
  "$ROOT/0-meta/bin/new" task review
}

# R3 的重试只允许由一次 Guard staging-main stale 失败触发。refresh 前后
# 都复读 candidate HEAD、origin/main、Review、auto-merge 和 Contract；真正
# 创建/读取 PR 后，zmerge_do_merge 还会走 zmerge_reread_before_merge 的全门禁。
zmerge_guard_recovery_preflight() {
  local current cur_blob
  current="$(git -C "$Z_WT" rev-parse HEAD 2>/dev/null || true)"
  [ -n "$current" ] || { err_code task.head_unreadable "无法读取 candidate HEAD，停止 Guard recovery"; return 1; }
  [ "$current" = "$Z_HEAD" ] || {
    err_code z.pr_head_changed "candidate HEAD 已改变（${current} ≠ ${Z_HEAD}），需要新的 zreview"; return 1;
  }
  z_fetch_origin_main "$Z_WT" "$Z_MAIN" || {
    err_code z.main_fetch_failed "无法复读 origin/${Z_MAIN}，停止 Guard recovery"; return 1;
  }
  if ! z_main_is_current "$Z_WT" "origin/${Z_MAIN}" HEAD; then
    err_code z.main_ahead "candidate 真落后于最新 main；不要由 Guard recovery 偷偷同步。下一步：new z sync"; return 1
  fi
  z_require_passing_review || return 1
  z_require_auto_merge_safe_review || return 1
  contract_fetch_main "$Z_WT" "$Z_MAIN" \
    || { err_code contract.fetch_main_failed "无法复读 origin/${Z_MAIN} 上的 Contract，停止 Guard recovery"; return 1; }
  cur_blob="$(contract_main_blob "$Z_WT" "$Z_NUMBER" "$Z_MAIN" 2>/dev/null || true)"
  [ -n "$cur_blob" ] || { err_code contract.missing "origin/${Z_MAIN} 没有 Contract，停止 Guard recovery"; return 1; }
  if contract_stale "$Z_CONTRACT_BLOB" "$cur_blob" "Guard recovery"; then
    err_code contract.stale "Contract 已改变，旧 Review/merge authorization 失效；需要新的 zreview"; return 1
  fi
  return 0
}

zmerge_deliver_review_with_guard_recovery() {
  local out retry_out refresh_out domain rc=0 retry_rc=0
  ZMERGE_DELIVER_FAILURE_CLASSIFIED=0
  out="$(zmerge_deliver_review 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    [ -z "$out" ] || printf '%s\n' "$out"
    return 0
  fi
  if [ "$(type -t guard_classify_push_failure 2>/dev/null)" = function ]; then
    domain="$(guard_classify_push_failure "$Z_WT" "$out" "$rc")"
  else
    domain=unknown
  fi
  if [ "$domain" != guard-staging ]; then
    [ -z "$out" ] || printf '%s\n' "$out" >&2
    return "$rc"
  fi

  [ -z "$out" ] || printf '%s\n' "$out" >&2
  # 这一步只在现有 merge authorization 仍可证明时执行；不因 staging
  # stale 而放宽 HEAD/Review/Contract 门禁。
  zmerge_guard_recovery_preflight || {
    ZMERGE_DELIVER_FAILURE_CLASSIFIED=1
    return 1
  }
  refresh_out="$(guard_refresh_staging_for_merge "$Z_WT" "$Z_MAIN")" || {
    err_code z.guard_refresh_blocked "Guard staging stale 但 refresh 被 fail-closed；未 replay transaction/lease。请显式 new guard sync 核对";
    ZMERGE_DELIVER_FAILURE_CLASSIFIED=1
    return 1
  }
  case "$refresh_out" in
    refreshed|noop) ;;
    *)
      err_code z.guard_refresh_blocked "Guard refresh 未返回可证明的 scoped result；未重试 task review。请显式 new guard sync 核对"
      ZMERGE_DELIVER_FAILURE_CLASSIFIED=1
      return 1
      ;;
  esac
  echo "Guard staging stale：已完成 scoped ${refresh_out}，复读全部已有 merge gates。" >&2
  zmerge_guard_recovery_preflight || {
    ZMERGE_DELIVER_FAILURE_CLASSIFIED=1
    return 1
  }

  retry_out="$(zmerge_deliver_review 2>&1)" || retry_rc=$?
  if [ "$retry_rc" -ne 0 ]; then
    [ -z "$retry_out" ] || printf '%s\n' "$retry_out" >&2
    err_code z.review_deliver_failed "Guard scoped refresh 后 task review 仍失败；不再自动重试";
    ZMERGE_DELIVER_FAILURE_CLASSIFIED=1
    return 1
  fi
  [ -z "$retry_out" ] || printf '%s\n' "$retry_out"
  return 0
}

# after_merge=1：本轮刚 gh pr merge 成功，失败必须用「远端已合并;finalize 未完成:…」
zmerge_finalize() {
  local after_merge="${1:-0}"

  zmerge_report_main_title

  if ! zmerge_delete_remote_branch; then
    if [ "$after_merge" = 1 ]; then
      err_code z.finalize_incomplete "远端已合并;finalize 未完成:删除远端分支"
    fi
    return 1
  fi

  if ! zmerge_ff_local_main; then
    if [ "$after_merge" = 1 ]; then
      err_code z.finalize_incomplete "远端已合并;finalize 未完成:本地 main ff-only"
    fi
    return 1
  fi
  return 0
}

zmerge_do_merge() {
  local status derived project pr pr_num js got head_oid
  local issue_file ck_file review_file pr_file body_file
  local js2 head_oid2 got2 merged oid msg subj body ck rev pr_body cur_blob

  z_require_current_main
  z_require_passing_review
  z_require_auto_merge_safe_review
  if z_has_label human-merge; then
    err_code z.human_merge "Issue 有 human-merge 标签，zmerge 拒绝。需要人用 zpr 送 PR。"
    return 1
  fi
  echo "Squash-Title: ${Z_SQUASH_TITLE}"
  contract_require_diff_in_scope "$Z_WT" "$Z_BASE" "$Z_HEAD" "$Z_SCOPE" \
    || { err_code z.diff_out_of_scope "真实 diff 越界，拒绝 merge"; return 1; }

  if ! task_fetch_issue "$Z_OWNER" "$Z_REPO" "$Z_NUMBER" "$Z_ISSUE_JSON"; then
    err_code task.issue_fetch_failed "无法读取 Issue / Project 状态"
    return 1
  fi
  derived="$(derive_task_state "$Z_NUMBER")" \
    || { err_code z.derive_failed "无法推导任务状态"; return 1; }
  project="$(task_read_status_name "$Z_ISSUE_JSON" || true)"
  z_warn_if_status_drift "$derived" "$project"
  case "$derived" in
    "$TASK_STATUS_PROGRESS"|"$TASK_STATUS_REVIEW")
      zmerge_deliver_review_with_guard_recovery || {
        if [ "${ZMERGE_DELIVER_FAILURE_CLASSIFIED:-0}" != 1 ]; then
          err_code z.review_deliver_failed "new task review 失败"
        fi
        return 1
      }
      ;;
    *)
      err_code z.wrong_dev_status "任务不在 ${TASK_STATUS_PROGRESS} 或 ${TASK_STATUS_REVIEW}（当前：${derived:-空}）。"
      return 1
      ;;
  esac
  # 保留 TASK_STATUS_REVIEW 字面，供合入前门禁夹具检索。
  status="$TASK_STATUS_REVIEW"

  pr="$(task_find_matching_pr "$Z_OWNER" "$Z_REPO" "$Z_GIT_BR" "$Z_MAIN")" \
    || { err_code z.pr_ambiguous "找不到唯一匹配 PR（不唯一则停止）"; return 1; }
  [ -n "$pr" ] || { err_code z.pr_missing "没有 head=${Z_GIT_BR} base=${Z_MAIN} 的未关闭 PR，停止"; return 1; }
  pr_num="$(printf '%s' "$pr" | jq -r '.number // empty')"
  js="$(task_pr_view_json "$Z_OWNER" "$Z_REPO" "$pr_num")" \
    || { err_code task.pr_unreadable "回读 PR 失败"; return 1; }
  got="$(printf '%s' "$js" | jq -r '.title // empty')"
  if [ "$got" != "$Z_SQUASH_TITLE" ]; then
    err_code z.pr_title_mismatch "远端 PR 标题与 Squash-Title 不一致（已被改过则停止，不静默修正）：${got:-空}"
    return 1
  fi
  task_pr_fields_ok "$js" "$Z_GIT_BR" "$Z_MAIN" "$Z_NUMBER" "$Z_SQUASH_TITLE" \
    || { err_code z.pr_fields "PR 非 Draft / head / base / Fixes / 标题 未通过"; return 1; }
  pr_body="$(printf '%s' "$js" | jq -r '.body // empty')"
  contract_pr_validate "$pr_body" "$Z_NUMBER" "$Z_CONTRACT_BLOB" "$Z_HEAD" \
    || { err_code contract.pr_invalid "PR 未绑定当前 Contract / reviewed HEAD"; return 1; }
  head_oid="$(printf '%s' "$js" | jq -r '.headRefOid // empty')"
  [ "$head_oid" = "$Z_HEAD" ] || {
    err_code z.pr_head_mismatch "PR head OID 与当前 HEAD 不一致"
    return 1
  }
  [ "$head_oid" = "$Z_HEAD" ] || {
    err_code z.pr_head_changed "远端 PR head 已变化（${head_oid:-空} ≠ ${Z_HEAD}），需要重新 zreview"
    return 1
  }

  if ! z_required_contexts; then
    err_code z.required_checks_unknown "required checks 状态未知${Z_REQUIRED_ERR:+：${Z_REQUIRED_ERR}}。不合并，不把 Checkpoint 写成「无 required checks」。"
    return 1
  fi
  z_pr_checks_ok "$pr_num"

  issue_file="$(mktemp -t z-squash-issue.XXXXXX)"; TMPS="$TMPS $issue_file"
  ck_file="$(mktemp -t z-squash-ck.XXXXXX)"; TMPS="$TMPS $ck_file"
  review_file="$(mktemp -t z-squash-review.XXXXXX)"; TMPS="$TMPS $review_file"
  pr_file="$(mktemp -t z-squash-pr.XXXXXX)"; TMPS="$TMPS $pr_file"
  body_file="$(mktemp -t z-squash-body.XXXXXX)"; TMPS="$TMPS $body_file"

  jq -r '.data.repository.issue.body // empty' "$Z_ISSUE_JSON" > "$issue_file" \
    || { err_code contract.body_empty "无法读取 Issue 正文"; return 1; }
  ck="$(task_unique_marked_comment "$Z_OWNER" "$Z_REPO" "$Z_NUMBER" \
      "$TASK_CHECKPOINT_MARK" "Checkpoint")" \
    || { err_code z.checkpoint_unreadable "无法读取 Checkpoint"; return 1; }
  [ -n "$ck" ] || { err_code z.checkpoint_missing "没有 Checkpoint，拒绝汇编 squash body"; return 1; }
  printf '%s' "$ck" | jq -r '.body // empty' > "$ck_file"
  rev="$(task_unique_marked_comment "$Z_OWNER" "$Z_REPO" "$Z_NUMBER" \
      "$TASK_REVIEW_MARK" "Review")" \
    || { err_code z.review_unreadable "无法读取 Review"; return 1; }
  [ -n "$rev" ] || { err_code z.review_missing "没有 Review，拒绝汇编 squash body"; return 1; }
  printf '%s' "$rev" | jq -r '.body // empty' > "$review_file"
  printf '%s' "$js" | jq -r '.body // empty' > "$pr_file"

  Z_SQUASH_STRICT=1
  z_compose_squash_body "$issue_file" "$ck_file" "$review_file" "$pr_file" \
      "$Z_NUMBER" "$pr_num" > "$body_file" \
    || { err_code z.squash_body_failed "生成 squash body 失败（必要上游缺失不得以未记录放行）"; return 1; }
  z_validate_squash_body "$(cat "$body_file")" "$Z_NUMBER" "$pr_num" \
    || { err_code z.squash_body_invalid "生成的 squash body 不合格（缺四段、含未记录、缺 Contract，或含临时路径/push 日志）"; return 1; }

  z_append_checkpoint_merge_gate "$(cat <<EOF
| 项 | 值 |
| --- | --- |
| required checks | ${Z_CHECKS_NOTE} |
| Squash-Title | \`${Z_SQUASH_TITLE}\` |
| PR | #${pr_num} |
| reviewed HEAD | \`${Z_HEAD}\` |
| squash body | 背景 / 改动 / 验证 / 备注 |
EOF
)"

  js2="$(task_pr_view_json "$Z_OWNER" "$Z_REPO" "$pr_num")" \
    || { err_code task.pr_unreadable "合并前再次回读 PR 失败"; return 1; }
  head_oid2="$(printf '%s' "$js2" | jq -r '.headRefOid // empty')"
  [ "$head_oid2" = "$Z_HEAD" ] || {
    err_code z.pr_head_changed "合并前 PR head 已变化，停止"
    return 1
  }
  got2="$(printf '%s' "$js2" | jq -r '.title // empty')"
  [ "$got2" = "$Z_SQUASH_TITLE" ] || {
    err_code z.pr_title_mismatch "合并前 PR 标题已不是 Squash-Title，停止"
    return 1
  }

  if ! zmerge_reread_before_merge; then
    return 1
  fi

  if ! GH_PROMPT_DISABLED=1 GH_PAGER=cat gh pr merge "$pr_num" \
    --repo "${Z_OWNER}/${Z_REPO}" \
    --squash \
    --subject "$Z_SQUASH_TITLE" \
    --body-file "$body_file" \
    --match-head-commit "$Z_HEAD"; then
    err_code z.squash_merge_failed "squash merge 失败"
    return 1
  fi

  merged="$(zmerge_observe_merge_commit "$Z_OWNER" "$Z_REPO" "$pr_num")" || return 1
  oid="$(printf '%s' "$merged" | jq -r '.mergeCommit.oid // empty')"
  [ -n "$oid" ] || {
    err_code z.merge_commit_unobserved "squash 后 PR 已 MERGED，但 mergeCommit 仍未观察，拒绝删分支、不二次 merge"
    return 1
  }
  msg="$(GH_PAGER=cat gh api "repos/${Z_OWNER}/${Z_REPO}/git/commits/${oid}" --jq .message)" \
    || { err_code z.finalize_incomplete "远端已合并;finalize 未完成:验证主线提交"; return 1; }
  subj="$(printf '%s\n' "$msg" | awk 'NR==1 { print; exit }')"
  body="$(printf '%s\n' "$msg" | awk 'NR==1 { next } { print }')"
  if ! z_validate_squash_body "$body" "$Z_NUMBER" "$pr_num"; then
    err_code z.finalize_incomplete "远端已合并;finalize 未完成:验证主线提交"
    return 1
  fi
  echo "main ${oid:0:12} 结构化 body 已写入。"
  ZMERGE_MERGED_PR="$(printf '%s' "$merged" | jq -c --arg t "$Z_SQUASH_TITLE" \
    '{number:null,title:$t,headRefOid:(.headRefOid // ""),mergeCommit:{oid:(.mergeCommit.oid // "")}}')"

  if ! zmerge_finalize 1; then
    return 1
  fi
  z_wait_auto_close
  echo "zmerge 完成。未删除工作树或本地分支，未调用 gh issue close，未写 Project Done。"
}

zmerge_run_locked() {
  zmerge_decide_action || return 1
  if [ "$ZMERGE_ACTION" = finalize ]; then
    echo "已合并或主线已包含当前 HEAD，跳过 gh pr merge，只 finalize。"
    zmerge_finalize 0 || return 1
    z_wait_auto_close
    echo "zmerge 完成。未删除工作树或本地分支，未调用 gh issue close，未写 Project Done。"
    return 0
  fi
  zmerge_do_merge
}

zmerge_run() {
  local rc=0
  z_merge_lock_acquire || rc=$?
  case "$rc" in
    0) ;;
    2) return 2 ;;
    *) die_code z.merge_lock_failed "无法获取 zmerge 锁" ;;
  esac
  rc=0
  zmerge_run_locked || rc=$?
  z_merge_lock_release
  return "$rc"
}
