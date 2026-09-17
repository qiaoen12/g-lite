# z 系列脚本共用。由各入口 scripts/ 加载，不要单独执行。
# 依赖：先有 git 工作树，再 source 本文件并调用 z_load。

# 度量里的入口名：.agents/skills/<skill>/scripts/<action>.sh → <skill>.<action>。
# canonical CLI 通过 Z_ENTRY_SCRIPT 保留真实入口；zfix 复用实现也必须记为 zfix.*。
z_entry_name() {
  local script="${Z_ENTRY_SCRIPT:-$0}" action skill
  action="$(basename "$script" .sh)"
  # 纯字面派生，不 cd：scripts/ 的上一级目录名就是 skill 名。
  skill="$(basename "$(dirname "$(dirname "$script")")")"
  case "$skill" in ''|.|/) skill=z ;; esac
  printf '%s.%s\n' "$skill" "$action"
}

z_load() {
  Z_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || { echo "✗ 不在 git 工作树（不猜测）" >&2; return 1; }
  ROOT="$Z_ROOT"
  # shellcheck source=/dev/null
  . "$ROOT/0-meta/lib/new/core.sh"
  # shellcheck source=/dev/null
  . "$ROOT/0-meta/lib/new/task.sh"
  # shellcheck source=/dev/null
  . "$ROOT/0-meta/lib/new/contract.sh"
  # shellcheck source=/dev/null
  . "$ROOT/0-meta/lib/new/metrics.sh"
  # 从这里开始计时；退出时按退出码落一行度量，再清临时文件。不改变退出码。
  metrics_begin "$(z_entry_name)"
  metrics_set agent "${NEW_TASK_ACTOR:-${NEW_TASK_AGENT:-}}"
  trap 'metrics_exit_trap $?' EXIT
  command -v jq >/dev/null 2>&1 || die_code task.missing_jq "找不到 jq"
  command -v gh >/dev/null 2>&1 || die_code task.missing_gh "找不到 gh"

  Z_WT="$(task_canon "$Z_ROOT")"
  [ "$(git -C "$Z_WT" rev-parse --is-bare-repository 2>/dev/null || true)" != true ] \
    || die_code task.bare_repo "这是 bare 仓库"
  if task_is_main_worktree "$Z_WT"; then
    die_code task.main_workspace "这是主工作区，不是任务工作树"
  fi

  local nwo
  task_config_require
  Z_NUMBER="$(task_bind_read "$Z_WT")"
  if [ -z "$Z_NUMBER" ]; then
    err_code task.issue_unbound "未 bind Issue。不从目录名或分支名猜测。"
    task_hint_bind
    return 1
  fi
  [[ "$Z_NUMBER" =~ ^[1-9][0-9]*$ ]] || die_code task.issue_number_invalid "Issue 编号不可用：$Z_NUMBER"
  nwo="$(task_repo_nwo "$Z_WT" || true)"
  [ -n "$nwo" ] || die_code review.origin_unparsed "无法从 origin URL 解析 GitHub 仓库（不猜测）"
  Z_OWNER="${nwo%/*}"
  Z_REPO="${nwo#*/}"
  task_is_sparse "$Z_WT" \
    || die_code task.not_sparse "任务工作树必须是 Git sparse-checkout（可见性边界）。先 new task bind ${Z_NUMBER}。"

  Z_ISSUE_JSON="$(mktemp -t z-issue.XXXXXX)"; TMPS="$TMPS $Z_ISSUE_JSON"
  task_fetch_issue "$Z_OWNER" "$Z_REPO" "$Z_NUMBER" "$Z_ISSUE_JSON" \
    || die_code task.issue_fetch_failed "gh 读取 ${Z_OWNER}/${Z_REPO}#${Z_NUMBER} 失败"
  [ "$(jq -r '.data.repository.issue.id // empty' "$Z_ISSUE_JSON")" != "" ] \
    || die_code task.issue_not_found "${Z_OWNER}/${Z_REPO}#${Z_NUMBER} 不存在或无权读取"
  Z_ISSUE_URL="$(jq -r '.data.repository.issue.url' "$Z_ISSUE_JSON")"
  Z_ISSUE_TITLE="$(jq -r '.data.repository.issue.title' "$Z_ISSUE_JSON")"
  metrics_set issue "${Z_OWNER}/${Z_REPO}#${Z_NUMBER}"
  metrics_set labels "$(task_issue_labels "$Z_ISSUE_JSON")"

  if ! Z_GIT_BR="$(git -C "$Z_WT" symbolic-ref --short HEAD 2>/dev/null)"; then
    die_code task.detached_head "游离 HEAD，没有分支"
  fi
  local regex
  regex="$(policy_get git.branch.naming_regex)"
  [ -n "$regex" ] || die_code task.branch_regex_missing "derived.lock 没有 git.branch.naming_regex"
  if printf '%s\n' "$Z_GIT_BR" | grep -qE "$regex"; then
    Z_LOGICAL_BR="$Z_GIT_BR"
  else
    die_code task.branch_naming "分支不符合 domain 前缀规则 ${regex}"
  fi

  Z_MAIN="$(default_branch)"
  if git -C "$Z_WT" rev-parse --verify -q "origin/${Z_MAIN}" >/dev/null; then
    Z_BASE="origin/${Z_MAIN}"
  elif git -C "$Z_WT" rev-parse --verify -q "$Z_MAIN" >/dev/null; then
    Z_BASE="$Z_MAIN"
  else
    die_code task.base_missing "找不到基线引用 ${Z_MAIN}"
  fi
  z_contract_load
  Z_HEAD="$(git -C "$Z_WT" rev-parse HEAD)" || die_code task.head_unreadable "读不到 HEAD"
  Z_STATUS="$(task_read_status_name "$Z_ISSUE_JSON" || true)"
}

# fetch origin/main 后读契约文件。缺文件时末行是 approve 命令。
z_contract_load() {
  local json rc=0 body
  json="$(mktemp -t z-contract.XXXXXX)"; TMPS="$TMPS $json"
  contract_load_main "$Z_WT" "$Z_NUMBER" "$json" "$Z_MAIN" || rc=$?
  if [ "$rc" = 3 ]; then
    exit 1
  fi
  if [ "$rc" != 0 ]; then
    die_code contract.fetch_main_failed "无法从 origin/${Z_MAIN} 读取任务契约，不使用本地陈旧副本"
  fi
  Z_CONTRACT_JSON="$json"
  Z_CONTRACT_BLOB="$CONTRACT_BLOB"
  Z_SCOPE="$(contract_scope_from_json "$json")"
  [ -n "$Z_SCOPE" ] || die_code task.scope_unparsed "契约没有允许改动范围"
  metrics_set task_class "$(metrics_task_class_from_scope "$Z_SCOPE")"
  body="$(jq -r '.data.repository.issue.body // empty' "$Z_ISSUE_JSON")"
  contract_warn_if_issue_differs "$body" "$json" "$Z_NUMBER"
}

z_git_busy() {
  local why
  if why="$(task_git_busy "$Z_WT")"; then
    die_code task.git_busy "git 忙：${why}"
  fi
}

z_require_clean() {
  z_git_busy
  local dirty
  dirty="$(git -C "$Z_WT" -c core.quotePath=false status --porcelain 2>/dev/null || true)"
  [ -z "$dirty" ] || die_code task.dirty_worktree "工作区不干净，拒绝继续"
}

# 拉取最新 origin/<main> 到远程跟踪引用。不改 HEAD、不 merge、不 rebase。
z_fetch_origin_main() {
  local wt="${1:-$Z_WT}" main="${2:-$Z_MAIN}"
  [ -n "$wt" ] && [ -n "$main" ] || die_code z.fetch_args "z_fetch_origin_main 缺少工作树或主分支名"
  if ! GIT_TERMINAL_PROMPT=0 git -C "$wt" fetch --quiet origin \
      "refs/heads/${main}:refs/remotes/origin/${main}"; then
    die_code task.fetch_main_failed "无法 fetch origin/${main}"
  fi
  Z_BASE="origin/${main}"
}

# 最新 main 是否已经包含在 head 历史中。
# 不得把「有共同祖先」或「相对 main 仍有提交」当成已最新。
z_main_is_current() {
  local wt="${1:-$Z_WT}" main_ref="${2:-origin/${Z_MAIN}}" head="${3:-HEAD}"
  git -C "$wt" merge-base --is-ancestor "$main_ref" "$head"
}

# 最新 main 门禁。zreview 写入前、zmerge 真正 merge 前、zpr 送 PR 前都调用。
# 落后则硬失败，不写 Review、不 merge、不改工作树。
z_require_current_main() {
  local wt="${1:-$Z_WT}" main="${2:-$Z_MAIN}"
  z_fetch_origin_main "$wt" "$main"
  if z_main_is_current "$wt" "origin/${main}" HEAD; then
    return 0
  fi
  die_code z.main_ahead "main 已前进，请显式执行 zsync。
如果同步导致 HEAD 改变，旧 Review 将失效，需重新 zreview。
下一步：new z sync"
}

# zdev / zfix / zreview / zsync 只接受推导为进行中的任务。Project Status 只警告。
# derive_task_state 在 claim.sh，经 task.sh 加载。
z_require_dev_status() {
  local derived project
  derived="$(derive_task_state "$Z_NUMBER")" \
    || die_code z.derive_failed "无法推导任务状态"
  project="${Z_STATUS:-}"
  if [ -z "$project" ] && [ -n "${Z_ISSUE_JSON:-}" ]; then
    project="$(task_read_status_name "$Z_ISSUE_JSON" || true)"
    Z_STATUS="$project"
  fi
  z_warn_if_status_drift "$derived" "$project"
  Z_DERIVED="$derived"
  case "$derived" in
    "${TASK_STATUS_PROGRESS:-In progress}"|"${TASK_STATUS_REVIEW:-In review}")
      return 0
      ;;
  esac
  case "$derived" in
    "${TASK_STATUS_BACKLOG:-Backlog}"|"${TASK_STATUS_READY:-Ready}")
      die_code z.wrong_dev_status "推导状态不是 ${TASK_STATUS_PROGRESS} 或 ${TASK_STATUS_REVIEW}（当前：${derived:-空}）。zdev/zfix/zreview/zsync 拒绝继续。${TASK_STATUS_BACKLOG}/${TASK_STATUS_READY} 须先 new task claim 领取。
下一步：new task claim"
      ;;
    "${TASK_STATUS_DONE:-Done}")
      die_code z.wrong_dev_status "推导状态为 ${TASK_STATUS_DONE}，任务已完成，拒绝继续修改。
下一步：new task"
      ;;
    *)
      die_code z.wrong_dev_status "推导状态不是 ${TASK_STATUS_PROGRESS} 或 ${TASK_STATUS_REVIEW}（当前：${derived:-空}），拒绝继续。
下一步：new task claim"
      ;;
  esac
}

# remote_sha 必须是同步前本地 HEAD 的祖先。空 SHA = 远端不存在，放行（随后不 push）。
z_require_remote_ancestor() {
  local wt="${1:-$Z_WT}" remote_sha="$2" local_head="$3"
  [ -n "$wt" ] && [ -n "$local_head" ] || die_code z.ancestor_args "z_require_remote_ancestor 缺少工作树或本地 HEAD"
  [ -n "$remote_sha" ] || return 0
  if git -C "$wt" merge-base --is-ancestor "$remote_sha" "$local_head"; then
    return 0
  fi
  die_code z.remote_not_ancestor "远端任务分支含本地没有的工作（${remote_sha} 不是 ${local_head} 的祖先）。不 rebase、不 push。"
}

# 将当前分支 rebase 到 main_ref。冲突不自动选任一侧，abort 回同步前 HEAD。
z_rebase_onto_current_main() {
  local wt="${1:-$Z_WT}" main_ref="${2:-origin/${Z_MAIN}}"
  local before conflicts gd now
  before="$(git -C "$wt" rev-parse HEAD)" || die_code task.head_unreadable "读不到 HEAD"
  if GIT_TERMINAL_PROMPT=0 git -C "$wt" -c core.editor=true rebase "$main_ref"; then
    return 0
  fi
  conflicts="$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null || true)"
  gd="$(git -C "$wt" rev-parse --absolute-git-dir)"
  if [ -d "$gd/rebase-merge" ] || [ -d "$gd/rebase-apply" ]; then
    git -C "$wt" rebase --abort >/dev/null 2>&1 \
      || die_code z.rebase_abort_failed "rebase 冲突且 abort 失败，工作树可能仍处于冲突状态。停止。"
  fi
  now="$(git -C "$wt" rev-parse HEAD)"
  [ "$now" = "$before" ] || die_code z.rebase_head_changed "rebase 失败后 HEAD 不是同步前状态（${now} ≠ ${before}）。停止。"
  die_code z.rebase_conflict "rebase 出现冲突，已恢复到同步前状态。不自动解决。冲突文件：${conflicts:-未知}。请人处理后再显式执行 zsync。"
}

# 读远端任务分支当前 SHA。读失败硬停止。不存在则 stdout 为空。
# 必须在 rebase 前调用，把返回值交给 z_push_rebased_branch 做 lease。
z_remote_branch_sha() {
  local wt="${1:-$Z_WT}" br="${2:-$Z_GIT_BR}" out rc=0
  [ -n "$wt" ] && [ -n "$br" ] || die_code z.remote_sha_args "z_remote_branch_sha 缺少工作树或分支名"
  out="$(GIT_TERMINAL_PROMPT=0 git -C "$wt" ls-remote --heads origin "refs/heads/${br}" 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    die_code task.remote_ref_unreadable "无法确认远端是否存在任务分支 ${br}，停止"
  fi
  printf '%s\n' "$out" | awk '{print $1; exit}'
}

# 用 rebase 前记录的远端 SHA 做 --force-with-lease。空 SHA = 当时不存在，不 push。
# 不得在 push 前重新 ls-remote 来填 SHA，否则 lease 失去「远端已被别人改过」的保护。
# 不得使用裸 --force。
z_push_rebased_branch() {
  local wt="${1:-$Z_WT}" br="${2:-$Z_GIT_BR}" expected="${3:-}"
  [ -n "$wt" ] && [ -n "$br" ] || die_code z.push_args "z_push_rebased_branch 缺少工作树或分支名"
  if [ -z "$expected" ]; then
    echo "远端无 ${br}，不 push。"
    return 0
  fi
  GIT_TERMINAL_PROMPT=0 git -C "$wt" push \
      --force-with-lease="refs/heads/${br}:${expected}" \
      origin "HEAD:refs/heads/${br}" \
    || die_code z.force_with_lease "远端任务分支已变化，--force-with-lease 拒绝覆盖。停止，不得 --force。"
}

z_has_label() {
  local want="$1" js
  js="$(GH_PAGER=cat gh issue view "$Z_NUMBER" --repo "${Z_OWNER}/${Z_REPO}" --json labels)" \
    || die_code task.labels_unreadable "无法读取 Issue 标签"
  printf '%s' "$js" | jq -e --arg n "$want" '.labels | map(.name) | index($n) != null' >/dev/null
}

z_require_passing_review() {
  local title c body rblob
  if [ "${TASK_FACTS_READY:-0}" != 1 ] && [ "$(type -t task_facts_load)" = function ] \
     && [ -n "${Z_OWNER:-}" ] && [ -n "${Z_REPO:-}" ] && [ -n "${Z_NUMBER:-}" ] && [ -n "${Z_WT:-}" ]; then
    task_facts_load "$Z_OWNER" "$Z_REPO" "$Z_NUMBER" "$Z_WT" \
      "${Z_BASE:-origin/${Z_MAIN:-main}}" \
      || die_code facts.comments_unreadable "无法加载当前阶段事实，拒绝把 Review 当适用 PASS。
下一步：new z review <review-input>"
  fi
  if ! title="$(task_passing_squash_title "$Z_OWNER" "$Z_REPO" "$Z_NUMBER" "$Z_HEAD" "$Z_BASE")"; then
    die_code z.review_unreadable "无法读取可用的通过 Review / Squash-Title"
  fi
  [ -n "$title" ] || die_code z.no_passing_review "没有当前 HEAD 的通过 Review，或 Squash-Title 缺失。
下一步：new z review <review-input>"
  Z_SQUASH_TITLE="$title"
  [ -n "${Z_CONTRACT_BLOB:-}" ] || die_code contract.missing "尚未加载契约。
下一步：new z dev"
  c="$(task_unique_marked_comment "$Z_OWNER" "$Z_REPO" "$Z_NUMBER" \
      "$TASK_REVIEW_MARK" "Review")" || die_code z.review_unreadable "无法读取 Review"
  [ -n "$c" ] || die_code z.review_missing "没有 Review。
下一步：new z review <review-input>"
  body="$(printf '%s' "$c" | jq -r '.body // empty')"
  rblob="$(task_review_table_field "$body" "Contract")"
  if contract_stale "$rblob" "$Z_CONTRACT_BLOB" "Review"; then
    die_code contract.review_stale "Review 已过期，需要重新 zreview。
下一步：new z review <review-input>"
  fi
  contract_review_validate "$body" "$Z_CONTRACT_JSON" "$Z_CONTRACT_BLOB" "$Z_HEAD" \
    || die_code contract.review_invalid "Review 未通过当前 Contract 的完整校验。
下一步：new z review <review-input>"
  if [ "$(type -t task_facts_review_is_applicable_pass)" = function ] \
     && ! task_facts_review_is_applicable_pass "$body" "$Z_HEAD" "$Z_CONTRACT_BLOB" "$Z_WT"; then
    die_code z.review_not_applicable "当前 Review 不是适用的独立 PASS（HEAD/Contract/provenance/current-fact）。
下一步：new z review <review-input>"
  fi
  Z_REVIEW_BODY="$body"
  Z_REVIEW_ACTOR="$(task_machine_field "$body" review_actor)"
  Z_SELF_REVIEW="$(task_machine_field "$body" Self-review)"
}

# 这是自动 squash 的最后一道读取门禁。Review 可以在 human-merge 流程中
# 记录 Self-review=yes，但自动 zmerge 不得把它当成独立审查。
z_require_auto_merge_safe_review() {
  case "${Z_SELF_REVIEW:-}" in
    no) return 0 ;;
    yes)
      die_code z.self_review_forbidden \
        "reason_code=z.self_review_forbidden：Review 含 Self-review=yes，拒绝自动 squash；请人工合并。"
      ;;
    *)
      die_code z.self_review_unknown \
        "reason_code=z.self_review_unknown：Review 缺少可证明的 Self-review=no，拒绝自动 squash。"
      ;;
  esac
}

z_require_staged_in_scope() {
  local staged="$1" f denied="" extra=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if task_path_hard_denied "$f"; then
      denied="${denied}${f}"$'\n'
    elif ! task_path_in_scope "$f" "$Z_SCOPE"; then
      extra="${extra}${f}"$'\n'
    fi
  done <<< "$staged"
  if [ -n "$denied" ]; then
    die_code z.staged_denied "staged 命中绝对禁止路径，拒绝提交，不可通过扩大任务范围绕过：
${denied}下一步：new z dev"
  fi
  if [ -n "$extra" ]; then
    die_code z.staged_out_of_scope "staged 超出当前契约允许范围，不得静默提交。越界路径：
$(printf '%s' "$extra" | sed 's/^/  /')
扩范围：改 Issue → new task approve ${Z_NUMBER} → git sparse-checkout add <路径>
然后重新 git add 并 wip-commit。不要退回 Project 状态或重新领取。
下一步：new task approve ${Z_NUMBER}"
  fi
}

z_wip_commit() {
  local msg="${1:-}" staged dirty
  z_git_busy
  z_require_dev_status
  dirty="$(git -C "$Z_WT" -c core.quotePath=false status --porcelain 2>/dev/null || true)"
  if [ -z "$dirty" ]; then
    echo "没有可提交改动，不创建 commit。"
    return 0
  fi
  staged="$(contract_staged_paths "$Z_WT")" || die_code z.nothing_staged "无法读取暂存区"
  [ -n "$staged" ] || die_code z.nothing_staged "有改动但未暂存。先按允许范围 git add，不要 git add -A。"
  z_require_staged_in_scope "$staged"
  [ -n "$msg" ] || die_code z.commit_msg_missing "缺少 commit 说明"
  case "$msg" in
    wip:*) ;;
    *) msg="wip: ${msg}" ;;
  esac
  git -C "$Z_WT" commit -m "$msg" || die_code z.commit_failed "提交失败（门禁未通过则不提交）"
}

z_write_checkpoint_file() {
  local f="$1" body oldck
  [ -f "$f" ] || die_code z.checkpoint_missing "Checkpoint 文件不存在：$f"
  [ -n "${Z_CONTRACT_JSON:-}" ] && [ -n "${Z_CONTRACT_BLOB:-}" ] \
    || die_code contract.missing "尚未加载契约"
  body="$(cat "$f")"
  oldck="$(task_unique_marked_comment "$Z_OWNER" "$Z_REPO" "$Z_NUMBER" \
      "$TASK_CHECKPOINT_MARK" "Checkpoint" || true)"
  if [ -n "$oldck" ]; then
    body="$(contract_checkpoint_preserve_evidence \
      "$(printf '%s' "$oldck" | jq -r '.body // empty')" "$body")"
  fi
  contract_checkpoint_validate "$body" "$Z_CONTRACT_JSON" "$Z_CONTRACT_BLOB" \
    || die_code contract.checkpoint_invalid "Checkpoint 未通过当前 Contract 校验"
  task_write_checkpoint "$Z_OWNER" "$Z_REPO" "$Z_NUMBER" "$body" \
    || die_code z.checkpoint_write_failed "Checkpoint 写入失败"
}

# Review 正文必须含「最小充分审查」段；六项字段都在该段内且值非空。
z_require_review_min_report() {
  local body="$1" sec need val
  printf '%s\n' "$body" | grep -Eq '^### 最小充分审查[[:space:]]*$' \
    || die_code z.review_min_heading "Review 正文缺少「### 最小充分审查」"
  sec="$(printf '%s\n' "$body" | awk '
    BEGIN { s=0 }
    /^### / {
      if (s) exit
      if ($0 ~ /^### 最小充分审查[[:space:]]*$/) { s=1; next }
    }
    s { print }
  ')"
  [ -n "$sec" ] || die_code z.review_min_empty "Review「最小充分审查」段为空"
  for need in \
      '审查代码与调用点' \
      '复用证据' \
      '新增验证' \
      '覆盖范围' \
      '未执行的大范围验证' \
      '剩余风险'
  do
    val="$(printf '%s\n' "$sec" | awk -v k="$need" '
      index($0, k) {
        line=$0
        sub(/\r$/, "", line)
        rest=substr(line, index(line, k) + length(k))
        sub(/^[[:space:]]*[：:][[:space:]]*/, "", rest)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", rest)
        print rest
        exit
      }
    ')"
    printf '%s\n' "$sec" | grep -Fq "$need" \
      || die_code z.review_min_field "Review「最小充分审查」缺少：${need}"
    [ -n "$val" ] || die_code z.review_min_blank "Review「最小充分审查」字段为空：${need}"
  done
}

z_write_review_file() {
  local f="$1" body verdict rhead title
  z_require_dev_status
  [ -f "$f" ] || die_code z.review_file_missing "Review 文件不存在：$f"
  body="$(cat "$f")"
  case "$body" in
    *"$TASK_REVIEW_MARK"*) ;;
    *) die_code z.review_marker_missing "Review 正文缺少 ${TASK_REVIEW_MARK}" ;;
  esac
  z_require_review_min_report "$body"
  verdict="$(task_review_table_field "$body" "Verdict")"
  rhead="$(task_review_table_field "$body" "reviewed HEAD")"
  title="$(task_review_table_field "$body" "Squash-Title")"
  [ "$rhead" = "$Z_HEAD" ] || die_code z.review_head_mismatch "reviewed HEAD（${rhead:-空}）不是当前 HEAD ${Z_HEAD}"
  case "$verdict" in
    通过)
      [ -n "$title" ] && [ "$title" != "（无）" ] || die_code z.squash_title_missing "通过的 Review 必须有 Squash-Title"
      task_validate_commit_title "$title" "$Z_BASE" \
        || die_code task.squash_title_invalid "Squash-Title 未通过提交标题校验：$title"
      ;;
    不通过)
      [ "$title" = "（无）" ] || die_code z.squash_title_not_none "不通过时 Squash-Title 必须是（无）"
      ;;
    *) die_code z.verdict_invalid "Verdict 必须是「通过」或「不通过」（当前：${verdict:-空}）" ;;
  esac
  [ -n "${Z_CONTRACT_JSON:-}" ] && [ -n "${Z_CONTRACT_BLOB:-}" ] \
    || die_code contract.missing "尚未加载契约"
  contract_review_validate "$body" "$Z_CONTRACT_JSON" "$Z_CONTRACT_BLOB" "$Z_HEAD" \
    || die_code contract.review_invalid "Review 未通过当前 Contract 的完整校验"
  if [ "$verdict" = 通过 ]; then
    contract_require_diff_in_scope "$Z_WT" "$Z_BASE" "$Z_HEAD" "$Z_SCOPE" \
      || die_code z.diff_out_of_scope "真实 diff 越界，Review 拒绝"
  fi
  if [ "$(task_machine_field "$body" Self-review)" = no ]; then
    if [ "${TASK_FACTS_READY:-0}" != 1 ] && [ "$(type -t task_facts_load)" = function ] \
       && [ -n "${Z_WT:-}" ]; then
      task_facts_load "$Z_OWNER" "$Z_REPO" "$Z_NUMBER" "$Z_WT" \
        "${Z_BASE:-origin/${Z_MAIN:-main}}" || die_code facts.comments_unreadable \
        "无法加载当前阶段事实，拒绝写 Self-review=no。
下一步：new z review <review-input>"
    fi
    if [ "$(type -t task_facts_reviewer_independent)" != function ] \
       || ! task_facts_reviewer_independent "$body" "$Z_HEAD" "$Z_WT" "${FACT_COMMENTS_JSON:-}"; then
      die_code review.independence_unproven \
        "不能写 Self-review=no：execution provenance 无法证明相对当前 candidate 的全部 dev/fix 独立。
下一步：new z review <review-input>"
    fi
  fi
  task_write_review "$Z_OWNER" "$Z_REPO" "$Z_NUMBER" "$body" \
    || die_code z.review_write_failed "Review 写入失败"
}

z_append_checkpoint_merge_gate() {
  local note="$1" c body
  c="$(task_unique_marked_comment "$Z_OWNER" "$Z_REPO" "$Z_NUMBER" \
      "$TASK_CHECKPOINT_MARK" "Checkpoint")" || die_code z.checkpoint_unreadable "无法读取 Checkpoint"
  [ -n "$c" ] || die_code z.checkpoint_missing "没有 Checkpoint，拒绝另开新楼"
  body="$(printf '%s' "$c" | jq -r '.body // empty')"
  if printf '%s\n' "$body" | grep -qx '### zmerge 门禁'; then
    body="$(printf '%s\n' "$body" | awk '
      BEGIN { skip=0 }
      $0 == "### zmerge 门禁" { skip=1; next }
      skip && /^### / { skip=0 }
      skip { next }
      { print }
    ')"
  fi
  body="${body%$'\n'}"$'\n\n'"### zmerge 门禁"$'\n\n'"${note}"$'\n'
  task_write_marked_comment "$Z_OWNER" "$Z_REPO" "$Z_NUMBER" \
    "$TASK_CHECKPOINT_MARK" "Checkpoint" "$body" \
    || die_code z.checkpoint_gate_write_failed "Checkpoint 门禁段写入失败"
}

# GraphQL 读 required checks。REST /branches/.../protection 在免费私有仓库
# 会 403「Upgrade to GitHub Pro」，旧实现把失败吞成空列表，等于 fail-open。
z_required_checks_query() {
  cat <<'GQL'
query($owner: String!, $name: String!, $qualified: String!) {
  repository(owner: $owner, name: $name) {
    ref(qualifiedName: $qualified) {
      name
      refUpdateRule { requiredStatusCheckContexts }
      branchProtectionRule {
        requiresStatusChecks
        requiredStatusCheckContexts
        requiredStatusChecks { context }
      }
      rules(first: 50) {
        pageInfo { hasNextPage }
        nodes {
          type
          parameters {
            ... on RequiredStatusChecksParameters {
              requiredStatusChecks { context }
            }
          }
        }
      }
    }
    rulesets(first: 50) {
      pageInfo { hasNextPage }
      nodes {
        enforcement
        rules(first: 50) {
          pageInfo { hasNextPage }
          nodes {
            type
            parameters {
              ... on RequiredStatusChecksParameters {
                requiredStatusChecks { context }
              }
            }
          }
        }
      }
    }
  }
}
GQL
}

# 三态解析。成功（含确认没有 checks）返回 0；读取/解析失败返回 1。
# 成功时在当前 shell 设置 Z_REQUIRED_CONTEXTS（确认没有 checks 时为空）
# 与 Z_REQUIRED_OK=1。失败时设置 Z_REQUIRED_ERR，并将 Z_REQUIRED_CONTEXTS、
# Z_REQUIRED_OK 置空。不得把失败当成空列表。
# 调用方不得用 $(...) 捕获：子 shell 写不回这些变量。
z_parse_required_checks_json() {
  local js="$1" err names truncated
  Z_REQUIRED_ERR=
  Z_REQUIRED_CONTEXTS=
  Z_REQUIRED_OK=
  if [ -z "$js" ]; then
    Z_REQUIRED_ERR="required checks 响应为空"
    return 1
  fi
  if ! printf '%s' "$js" | jq -e . >/dev/null 2>&1; then
    Z_REQUIRED_ERR="required checks 响应不是 JSON"
    return 1
  fi
  err="$(printf '%s' "$js" | jq -r '
    if (.errors | type == "array") and (.errors | length > 0) then
      [.errors[] | (.message // "unknown")] | join("; ")
    else
      empty
    end
  ')"
  if [ -n "$err" ]; then
    Z_REQUIRED_ERR="GraphQL errors: ${err}"
    return 1
  fi
  if [ "$(printf '%s' "$js" | jq -r 'if .data.repository == null then "missing" else "ok" end')" != ok ]; then
    Z_REQUIRED_ERR="GraphQL 未返回 repository"
    return 1
  fi
  if [ "$(printf '%s' "$js" | jq -r 'if .data.repository.ref == null then "missing" else "ok" end')" != ok ]; then
    Z_REQUIRED_ERR="找不到基线分支的 ref，无法确认 required checks"
    return 1
  fi
  truncated="$(printf '%s' "$js" | jq -r '
    [
      .data.repository.ref.rules.pageInfo.hasNextPage,
      .data.repository.rulesets.pageInfo.hasNextPage,
      ((.data.repository.rulesets.nodes // [])[] | .rules.pageInfo.hasNextPage)
    ] | map(. == true) | any
  ')"
  if [ "$truncated" = true ]; then
    Z_REQUIRED_ERR="required checks 规则未读完（分页截断），状态未知"
    return 1
  fi
  if ! names="$(printf '%s' "$js" | jq -r '
    [
      (.data.repository.ref.refUpdateRule.requiredStatusCheckContexts // []),
      (.data.repository.ref.branchProtectionRule.requiredStatusCheckContexts // []),
      ((.data.repository.ref.branchProtectionRule.requiredStatusChecks // []) | map(.context // empty)),
      ((.data.repository.ref.rules.nodes // [])
        | map(select(.type == "REQUIRED_STATUS_CHECKS")
              | (.parameters.requiredStatusChecks // [])[]
              | .context // empty)),
      ((.data.repository.rulesets.nodes // [])
        | map(select(.enforcement == "ACTIVE")
              | (.rules.nodes // [])[]
              | select(.type == "REQUIRED_STATUS_CHECKS")
              | (.parameters.requiredStatusChecks // [])[]
              | .context // empty))
    ]
    | add
    | map(select(type == "string" and length > 0))
    | unique
    | .[]
  ')"; then
    Z_REQUIRED_ERR="解析 required checks 失败"
    return 1
  fi
  Z_REQUIRED_CONTEXTS="$names"
  Z_REQUIRED_OK=1
  return 0
}

z_required_request_err() {
  local rc="$1"
  Z_REQUIRED_OK=
  Z_REQUIRED_CONTEXTS=
  Z_REQUIRED_ERR="GraphQL 请求失败（exit ${rc}）"
  if [ -s "$2" ]; then
    Z_REQUIRED_ERR="${Z_REQUIRED_ERR}: $(tr '\n' ' ' < "$2")"
  fi
}

# 成功时在当前 shell 设置 Z_REQUIRED_CONTEXTS、Z_REQUIRED_OK=1，Z_REQUIRED_ERR 为空。
# 失败时设置 Z_REQUIRED_ERR，Z_REQUIRED_CONTEXTS 与 Z_REQUIRED_OK 为空。
# gh api graphql 遇到 GraphQL errors 时 exit 非 0，正文在 stdout；必须先解析 stdout，
# 不能只看 stderr，否则 zmerge 只能看到「请求失败」，看不到 GraphQL errors / 缺 repository。
# 调用方必须在当前 shell 直接调用，不得用 $(...) 捕获。
z_required_contexts() {
  local js errfile rc=0
  Z_REQUIRED_ERR=
  Z_REQUIRED_CONTEXTS=
  Z_REQUIRED_OK=
  errfile="$(mktemp -t z-req.XXXXXX)"; TMPS="$TMPS $errfile"
  js="$(GH_PAGER=cat gh api graphql \
      -F owner="$Z_OWNER" \
      -F name="$Z_REPO" \
      -F qualified="refs/heads/${Z_MAIN}" \
      -f query="$(z_required_checks_query)" \
      2>"$errfile")" || rc=$?
  if [ "$rc" -eq 0 ]; then
    z_parse_required_checks_json "$js"
    return
  fi
  if [ -n "$js" ]; then
    if z_parse_required_checks_json "$js"; then
      z_required_request_err "$rc" "$errfile"
      return 1
    fi
    case "$Z_REQUIRED_ERR" in
      "required checks 响应不是 JSON"|"required checks 响应为空")
        z_required_request_err "$rc" "$errfile"
        ;;
    esac
    return 1
  fi
  z_required_request_err "$rc" "$errfile"
  return 1
}

# 仅在 required checks 已成功读取后调用（Z_REQUIRED_OK=1）。
# Z_REQUIRED_CONTEXTS 空 = 确认没有 required checks。未成功读取时不得当成没有 checks。
z_pr_checks_ok() {
  local pr_num="$1" js name st
  if [ "${Z_REQUIRED_OK:-}" != 1 ]; then
    die_code z.required_checks_unknown "required checks 尚未成功读取，拒绝当成「无 required checks」"
    return 1
  fi
  if [ -z "${Z_REQUIRED_CONTEXTS:-}" ]; then
    Z_CHECKS_NOTE='无 required checks'
    return 0
  fi
  js="$(GH_PAGER=cat gh pr view "$pr_num" --repo "${Z_OWNER}/${Z_REPO}" \
      --json statusCheckRollup)" || die_code z.pr_checks_unreadable "无法读取 PR checks"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    st="$(printf '%s' "$js" | jq -r --arg n "$name" '
      [.statusCheckRollup[]? | select(.name == $n) | (.conclusion // .state // .status // "")]
      | .[0] // ""
    ')"
    case "$st" in
      SUCCESS|success) ;;
      *) die_code z.required_check_failed "required check 未成功：${name}（${st:-空}）" ;;
    esac
  done <<< "$Z_REQUIRED_CONTEXTS"
  Z_CHECKS_NOTE="required checks 全部成功：$(printf '%s' "$Z_REQUIRED_CONTEXTS" | tr '\n' ' ')"
}

z_delete_remote_branch() {
  task_branch_pushable "$Z_GIT_BR" "$Z_MAIN" || die_code z.delete_branch_denied "拒绝删除远端分支：${Z_GIT_BR}"
  if git -C "$Z_WT" ls-remote --exit-code origin "refs/heads/${Z_GIT_BR}" >/dev/null 2>&1; then
    GIT_TERMINAL_PROMPT=0 git -C "$Z_WT" push origin --delete -- "refs/heads/${Z_GIT_BR}" \
      || die_code z.delete_branch_failed "删除远端任务分支失败：${Z_GIT_BR}"
  else
    echo "远端已无 ${Z_GIT_BR}，不删本地分支。"
  fi
}

z_wait_auto_close() {
  local i js state reason status
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    js="$(GH_PAGER=cat gh issue view "$Z_NUMBER" --repo "${Z_OWNER}/${Z_REPO}" \
        --json state,stateReason 2>/dev/null || true)"
    state="$(printf '%s' "$js" | jq -r '.state // empty')"
    reason="$(printf '%s' "$js" | jq -r '.stateReason // empty')"
    if [ "$state" = CLOSED ] && [ "$reason" = COMPLETED ]; then
      echo "Issue #${Z_NUMBER} 已 Closed as completed。"
      break
    fi
    if [ "$i" = 15 ]; then
      echo "⚠ Issue 未在等待期内自动关闭（state=${state:-空} reason=${reason:-空}）。不调用 gh issue close。"
    else
      sleep 2
    fi
  done
  if ! task_fetch_issue "$Z_OWNER" "$Z_REPO" "$Z_NUMBER" "$Z_ISSUE_JSON"; then
    echo "⚠ 无法回读 Project 状态。不手写 Done。"
    return 0
  fi
  status="$(task_read_status_name "$Z_ISSUE_JSON" || true)"
  if [ "$status" = Done ]; then
    echo "Project Status=Done。"
  else
    echo "⚠ Project Status 现为 ${status:-空}，不是 Done。不手写 Done。"
  fi
}
