# new task [agent|review]：Orca 工作树开工与交付。预检、领取、交付分开。
# 由 0-meta/bin/new 加载，不要单独执行。

# ─────────────────────────────────────────────── task
#
# Orca 工作树的开工与交付入口。三步分开，避免「看一眼」变成「领走」，
# 也避免「交付到评审」变成「合并进 main」：
#   new task           只预检，GitHub 只读，不 exec，不改 git 分支名
#   new task approve <n> 人在主工作区、main 上把 Issue 正文写成
#                       origin/main:0-meta/tasks/<n>/contract.{md,json}。
#                       Backlog → Ready；在途任务只换契约、不动 Status。
#                       内容未变则 no-op。
#   new task claim [--actor <id>]
#                       预检通过后领取（Ready → In progress），写 Checkpoint，
#                       不启动 Agent。actor 只记 provenance/metrics，不是授权。
#   new task grok|codex 同一 claim 核心，成功后再 exec 对应 Agent，
#                       并把 zdev 作为首条指令传入。
#                       zdev / new z dev 本身不领取、不改 Project 状态。
#                       分支预检时若 git 分支恰好是 Orca 把合法 displayName
#                       的 / 拍成 - 的结果，则在安全条件下改回 displayName，
#                       回读后再跑现有分支与基线校验。不改 Orca displayName、
#                       Issue 绑定或 worktree 路径。
#   new task review     预检通过后才 push 当前任务分支并更新 PR：
#                       推导 In progress：创建或复用 PR，写 Checkpoint；
#                       Project Status 写 In review 失败只警告。
#                       推导 In review：仅当存在唯一、可证明属于当前任务的未关闭 PR
#                       时，重新 push 已审查 HEAD 并更新原 PR；不得新建第二个 PR。
#                       PR 标题必须通过现有 commit-msg 校验：优先 Squash-Title；
#                       没有适用 Review 时不得直接使用不合规的 Issue 标题。
#
# Agent 名是白名单，不是「PATH 里有这个命令就算」。未登记的名字必须在
# 碰 GitHub、碰工作树之前就拒绝，否则一次拼写错误会先改 Project 状态。
# review 不是 Agent，是交付子命令。
#
# Issue 绑定只信 worktree-local `new task bind <n>`（git config）。
# 目录名、分支名、gh issue list、Orca linkedWorkItem 都不算绑定。
#
# new task review 及其内部函数不得：合并 PR、关闭 Issue、向默认分支
# 写入、把 Project 状态改为 Done。默认合并由 zmerge 在门禁通过后 squash；
# 有 human-merge 时由 zpr 送 PR，之后由人决定合并。
# 领取与交付的授权对象是精确终端命令；自然语言不是授权。见 0-meta/AGENTS.md。

# Project/Status 名称从 derived.lock 读（policy.yaml → new plan --apply）。
# 状态名的 Bash 缺省只给单测 source 顺序兜底；生产入口见 task_config_require。
TASK_PROJECT_NUMBER=""
TASK_PROJECT_TITLE=""
TASK_STATUS_BACKLOG='Backlog'
TASK_STATUS_READY='Ready'
TASK_STATUS_PROGRESS='In progress'
TASK_STATUS_REVIEW='In review'
TASK_STATUS_DONE='Done'

task_load_github_config() {
  local v
  v="$(policy_get github.project.number)"; if [ -n "$v" ]; then TASK_PROJECT_NUMBER="$v"; fi
  v="$(policy_get github.project.title)"; if [ -n "$v" ]; then TASK_PROJECT_TITLE="$v"; fi
  v="$(policy_get github.status.backlog)"; if [ -n "$v" ]; then TASK_STATUS_BACKLOG="$v"; fi
  v="$(policy_get github.status.ready)"; if [ -n "$v" ]; then TASK_STATUS_READY="$v"; fi
  v="$(policy_get github.status.progress)"; if [ -n "$v" ]; then TASK_STATUS_PROGRESS="$v"; fi
  v="$(policy_get github.status.review)"; if [ -n "$v" ]; then TASK_STATUS_REVIEW="$v"; fi
  v="$(policy_get github.status.done)"; if [ -n "$v" ]; then TASK_STATUS_DONE="$v"; fi
  return 0
}

task_config_require() {
  task_load_github_config
  [ -n "$TASK_PROJECT_NUMBER" ] && [ -n "$TASK_PROJECT_TITLE" ] \
    && [ -n "$TASK_STATUS_BACKLOG" ] && [ -n "$TASK_STATUS_READY" ] \
    && [ -n "$TASK_STATUS_PROGRESS" ] && [ -n "$TASK_STATUS_REVIEW" ] \
    && [ -n "$TASK_STATUS_DONE" ] \
    || die_code task.project_config_missing \
      "derived.lock 缺少 github.project / github.status。改 0-meta/policy.yaml 后在稳定主工作区跑 new plan --apply。"
}

task_load_github_config
TASK_CHECKPOINT_MARK='<!-- new-task-checkpoint -->'
TASK_REVIEW_MARK='<!-- new-task-review -->'
TASK_PR_MARK_BEGIN='<!-- new-task-pr -->'
TASK_PR_MARK_END='<!-- /new-task-pr -->'
TASK_VERDICT_PASS='通过'
TASK_COMMIT_MSG_CHECK="$ROOT/0-meta/audit/scripts/check-commit-msg.sh"

task_usage() {
  cat <<'USAGE'
用法：new task [claim|grok|codex|review|approve|bind]

  new task           预检当前已 bind 的 Git 工作树与 Issue
                     不领取、不改 GitHub Project 状态、不启动 Agent
  new task bind <n>  在任务 worktree 上显式绑定 Issue（本 worktree 的 git dir）
                     若当前不是 sparse，工作区干净时收成 cone sparse（公共目录 + 契约范围）
                     不 claim、不改 Project、不写 Checkpoint、不启动 Agent
  new task approve <n>
                     人在主工作区、main 分支上运行：把 Issue 正文写成
                     origin/main 上的契约文件。Backlog → Ready；
                     在途任务只换契约、不动 Status。
                     内容未变则 no-op。Status 写失败只警告。
  new task claim [--actor <id>]
                     预检通过后领取：claim remote 建锁、Ready → In progress，写 Checkpoint。
                     不启动 Agent。actor 只作 provenance/audit/metrics，不是授权，
                     也不是产品白名单。下一步：new z dev
  new task grok      同一 claim 核心，成功后当前终端启动 grok 并自动执行 /zdev
                     若 git 分支恰好是 Orca 把合法 displayName 的 / 拍成 - 的结果，
                     开工前在安全条件下改回规范名，再重跑分支与基线校验
  new task codex     同一 claim 核心，成功后启动 codex 并自动执行 $zdev
  new task review    在推导为 In progress 或 In review 的已 bind 任务工作树中交付：
                     In progress：预检 → push → 创建或复用 base=main 的非 Draft PR
                     → 更新 Checkpoint；Project Status 写失败只警告
                     In review：仅当存在唯一属于当前任务的未关闭 PR 时，
                     重新 push 已审查 HEAD 并更新原 PR；
                     没有匹配 PR 或多个候选 PR 时硬停止，不新建第二个 PR
                     PR 标题必须符合 <type>(<scope>): <描述>，复用 check-commit-msg.sh。
                     有当前 HEAD 的通过 Review 时用 Squash-Title；否则不得直接使用
                     不合规的 Issue 标题，无法确定合法标题则停止。
                     写入后回读。为修正标题只改 title，不覆盖人工正文。
                     不合并 PR、不关闭 Issue、不向 main push、不把状态改为 Done。
                     默认合并走 zmerge；human-merge 由 zpr 送 PR 后由人决定。
                     仅当人实际输入本命令，或明确要求 Agent「输入并执行 new task review」
                     时才可运行。「可以交付」「可以合并」等自然语言不是授权。

已登记 Agent：codex、grok。其它名字一律拒绝。review 不是 Agent。
USAGE
}

# canonical start card 的协议只有一份；保留变量名供旧 fixture 做兼容性检查。
# 产品 adapter 仍可选择触发词，但不能改变卡片内容。
TASK_START_PROMPT_VARIANT=C

TASK_START_CARD_BEGIN='<!-- canonical-start-card -->'
TASK_START_CARD_END='<!-- /canonical-start-card -->'

task_zdev_token() {
  case "$1" in
    grok) printf '%s\n' '/zdev' ;;
    codex) printf '%s\n' '$zdev' ;;
    *) return 1 ;;
  esac
}

# start card 已把开工所需事实直接交给 Agent；其它规则和 rationale 按需读取。
# 这个列表只允许放「prompt 明确要求强制加载」的文件，不能把后续阅读算进指标。
TASK_PROMPT_READS=""

task_prompt_reads_sentence() {
  local f out=""
  for f in $TASK_PROMPT_READS; do
    [ -z "$out" ] && out="$f" || out="$out 和 $f"
  done
  printf '%s\n' "$out"
}

# 生成一张产品无关的 canonical start card。机器可判定的规则不在这里复制；
# 门禁仍由 canonical CLI 执行。参数依次为 owner repo issue url main contract_blob
# worktree logical_branch git_branch derived_state scope next_command head。
task_start_card() {
  local owner="$1" repo="$2" number="$3" issue_url="$4" main="$5"
  local contract_blob="$6" wt="$7" logical_br="$8" git_br="$9"
  local derived="${10}" scope="${11}" next="${12}" head="${13}"
  [ -n "$owner" ] && [ -n "$repo" ] && [ -n "$number" ] && [ -n "$issue_url" ] \
    && [ -n "$main" ] && [ -n "$contract_blob" ] && [ -n "$wt" ] \
    && [ -n "$logical_br" ] && [ -n "$git_br" ] && [ -n "$derived" ] \
    && [ -n "$scope" ] && [ -n "$next" ] && [ -n "$head" ] || return 1
  local card
  card="$(cat <<EOF
${TASK_START_CARD_BEGIN}
## Canonical start card

| Field | Value |
| --- | --- |
| Issue | ${owner}/${repo}#${number} (${issue_url}) |
| Contract | \`origin/${main}:0-meta/tasks/${number}/contract.json\` @ \`${contract_blob}\` |
| Worktree | \`${wt}\` |
| Branch | ${logical_br}（git: ${git_br}） |
| Derived state | ${derived} |
| Allowed scope | $(task_scope_oneline "$scope") |
| Next canonical command | ${next} |
| HEAD | \`${head}\` |

本卡包含当前任务的开工事实；不要求先完整阅读仓库规则或流程文档。
其它资料按需读取，机器可判定的规则由 canonical CLI 门禁执行。
${TASK_START_CARD_END}
EOF
  )"
  task_start_card_budget_check "$card" || return 1
  printf '%s\n' "$card"
}

# 从带 adapter trigger 的 prompt 中取出卡片本体。loaded_bytes 只量这一段。
task_start_card_extract() {
  awk -v begin="$TASK_START_CARD_BEGIN" -v end="$TASK_START_CARD_END" '
    $0 == begin { on=1 }
    on { print }
    on && $0 == end { exit }
  '
}

# 开工加载字节数 = start card 字节数 + 它明确要求强制加载的文件字节数。
# 文件在 sparse 里不可见就不计（Agent 也读不到）。没有 marker 的旧调用仍按
# 整段 prompt 计算，便于独立 fixture 给出清晰失败，而生产入口始终有 marker。
task_prompt_loaded_bytes() {
  local wt="$1" prompt="$2" total f card
  card="$(task_start_card_extract <<< "$prompt" || true)"
  [ -n "$card" ] || card="$prompt"
  total="$(printf '%s' "$card" | wc -c | tr -d ' ')"
  for f in $TASK_PROMPT_READS; do
    [ -f "$wt/$f" ] || continue
    total=$(( total + $(wc -c < "$wt/$f" | tr -d ' ') ))
  done
  printf '%s\n' "$total"
}

# 只构造启动 Agent 的首条 prompt，不改领取 / Checkpoint / Status / zdev 实现。
task_agent_start_prompt() {
  local variant="$1" number="$2" issue_url="$3" wt="$4" scope="$5"
  local status="$6" owner="$7" repo="$8" agent="$9"
  local main="${10:-${Z_MAIN:-main}}"
  local contract_blob="${11:-${Z_CONTRACT_BLOB:-unknown}}"
  local logical_br="${12:-${Z_LOGICAL_BR:-${Z_GIT_BR:-unknown}}}"
  local git_br="${13:-${Z_GIT_BR:-$logical_br}}"
  local head="${14:-${Z_HEAD:-unknown}}"
  local token card
  token="$(task_zdev_token "$agent")" || return 1
  [ -n "$number" ] && [ -n "$issue_url" ] && [ -n "$wt" ] && [ -n "$scope" ] \
    && [ -n "$status" ] && [ -n "$owner" ] && [ -n "$repo" ] || return 1
  case "$variant" in
    A|B|C) ;;
    *) return 1 ;;
  esac
  card="$(task_start_card "$owner" "$repo" "$number" "$issue_url" "$main" \
    "$contract_blob" "$wt" "$logical_br" "$git_br" "$status" "$scope" \
    "new z dev" "$head")" || return 1
  printf '%s\n' "$card"
  # 末行只保留具体产品的机械 trigger；卡片本体在不同产品之间完全一致。
  printf '%s\n' "$token"
}

task_canon() { (cd "$1" && pwd); }

task_ref_name() {
  local r="$1"
  r="${r#refs/remotes/origin/}"
  r="${r#refs/heads/}"
  r="${r#origin/}"
  printf '%s\n' "$r"
}

task_orca_bin() {
  local bin
  if [ -n "${ORCA_CLI_COMMAND:-}" ]; then
    bin="${ORCA_CLI_COMMAND}"
    command -v "$bin" >/dev/null 2>&1 \
      || die_code task.orca_bin_unusable "ORCA_CLI_COMMAND=$bin 不可执行。不改用其它 orca（避免打到另一套运行时）。"
    printf '%s\n' "$bin"
    return 0
  fi
  command -v orca >/dev/null 2>&1 \
    || die_code task.orca_missing "找不到 orca，无法确认当前是受管理的工作树（不猜测）。"
  printf '%s\n' orca
}

task_agent_registered() {
  case "$1" in
    grok|codex) return 0 ;;
    *) return 1 ;;
  esac
}

# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/task-paths.sh"

# 多行 scope 压成一行用于展示（Checkpoint 表格、日志）。不要拿展示值回去做门禁。
task_scope_oneline() {
  printf '%s\n' "$1" | awk 'NF{printf "%s%s", (n++?" ":""), $0} END{print ""}'
}

# 生产 start card 必须按真实动态字段检查同一份预算；固定短样例的 commit
# 检查不能替代这道运行时门禁。预算仍来自 derived.lock，不改变 metrics 口径。
task_start_card_budget_check() {
  local card="$1" budget_lock="${TASK_START_CARD_BUDGET_LOCK:-$LOCK}" budget actual
  budget="$(lock_get "$budget_lock" prompt_budget.start_card_bytes)"
  if ! [[ "$budget" =~ ^[1-9][0-9]*$ ]]; then
    err_code task.start_card_budget_missing \
      "canonical start card 缺少有效 prompt_budget.start_card_bytes"
    return 1
  fi
  actual="$(printf '%s' "$card" | wc -c | tr -d ' ')"
  if ! [[ "$actual" =~ ^[0-9]+$ ]]; then
    err_code task.start_card_budget_unreadable \
      "canonical start card 无法测量（budget=${budget} bytes）"
    return 1
  fi
  if [ "$actual" -gt "$budget" ]; then
    err_code task.start_card_over_budget \
      "canonical start card 超出 prompt budget：${actual} > ${budget} bytes"
    return 1
  fi
  return 0
}

# cone 只自动带上仓库根层文件。顶层目录（如 1-code）即使不含 / 也不是根层文件。
task_is_cone_root_file() {
  local wt="$1" p="$2"
  p="$(task_norm_scope_path "$p")"
  [ -n "$wt" ] && [ -n "$p" ] || return 1
  case "$p" in
    */*) return 1 ;;
  esac
  if git -C "$wt" ls-tree -d --name-only HEAD -- "$p" 2>/dev/null | grep -qx "$p"; then
    return 1
  fi
  if [ -d "$wt/$p" ]; then
    return 1
  fi
  return 0
}

# 把路径追加进 Issue「允许改动范围」段。已在范围内的跳过。stdout 为新正文。
# 生产路径已不再调用；定义留给 #33 一并删除。
task_append_scope_to_body() {
  local body="$1"
  shift
  local items="" p existing addf
  printf '%s\n' "$body" | grep -Eq '^##[ \t]+允许改动范围' \
    || { err_code task.scope_section_missing "    ✗ Issue 正文没有「允许改动范围」段"; return 1; }
  existing="$(task_parse_scope "$body" || true)"
  for p in "$@"; do
    p="$(task_norm_scope_path "$p")"
    task_repo_path_ok "$p" || { err_code task.path_invalid "    ✗ 路径不合法，不能加入范围：$p"; return 1; }
    if task_path_hard_denied "$p"; then
      err_code task.path_denied "    ✗ 绝对禁止路径不能加入任务范围：$p"
      return 1
    fi
    if [ -n "$existing" ] && task_path_in_scope "$p" "$existing"; then
      continue
    fi
    items="${items}- \`${p}\`"$'\n'
  done
  if [ -z "$items" ]; then
    printf '%s' "$body"
    case "$body" in
      *$'\n') ;;
      *) printf '\n' ;;
    esac
    return 0
  fi
  addf="$(mktemp -t new-task-scope.XXXXXX)"
  TMPS="$TMPS $addf"
  printf '%s' "$items" > "$addf"
  printf '%s\n' "$body" | awk -v addf="$addf" '
    BEGIN { s=0 }
    /^##[ \t]+/ {
      line=$0
      sub(/\r$/, "", line)
      if (s) {
        while ((getline x < addf) > 0) print x
        close(addf)
        s=0
      }
      if (line ~ /^##[ \t]+允许改动范围/) s=1
    }
    { print }
    END {
      if (s) {
        while ((getline x < addf) > 0) print x
        close(addf)
      }
    }
  '
}

task_checkpoint_set_scope() {
  local body="$1" scope="$2"
  printf '%s\n' "$body" | awk -v s="$scope" '
    $0 ~ /^\| 允许范围 \|/ {
      print "| 允许范围 | " s " |"
      next
    }
    { print }
  '
}

# 从 Issue 正文「允许改动范围」段抽出路径，每行一个。只认列表项（见 contract.sh）。
# 段不存在或抽不出路径都算失败——空范围会让「没有超出范围」恒成立，等于没检查。
task_parse_scope() {
  local body="$1" sec
  sec="$(contract_scope_section "$body")"
  [ -n "$sec" ] || return 1
  contract_parse_scope_section "$sec"
}

task_git_busy() {
  local wt="$1" gd
  gd="$(git -C "$wt" rev-parse --path-format=absolute --git-dir 2>/dev/null \
    || git -C "$wt" rev-parse --git-dir)"
  case "$gd" in
    /*) ;;
    *) gd="$(cd "$wt" && cd "$gd" && pwd -P)" ;;
  esac
  if [ -f "$gd/MERGE_HEAD" ]; then echo "merge 进行中"; return 0; fi
  if [ -f "$gd/index.lock" ]; then echo "index.lock 存在"; return 0; fi
  if [ -d "$gd/rebase-merge" ] || [ -d "$gd/rebase-apply" ]; then
    echo "rebase 进行中"; return 0
  fi
  if [ -f "$gd/CHERRY_PICK_HEAD" ]; then echo "cherry-pick 进行中"; return 0; fi
  if [ -f "$gd/REVERT_HEAD" ]; then echo "revert 进行中"; return 0; fi
  if [ -f "$gd/BISECT_LOG" ]; then echo "bisect 进行中"; return 0; fi
  if [ -n "$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null || true)" ]; then
    echo "有未合并冲突"
    return 0
  fi
  return 1
}

# 读取一次 Git porcelain 状态，给交接门禁提供唯一的 dirty 分类口径。
# X 是 index，Y 是 worktree；每条状态记录只计一次，但冲突会同时计入两类。
# 失败必须向上返回，不能把「读不到状态」解释成 clean。
task_worktree_status_counts() {
  local wt="$1" status line x y
  TASK_WORKTREE_STATUS=""
  TASK_WORKTREE_DIRTY=0
  TASK_WORKTREE_UNTRACKED=0
  TASK_WORKTREE_UNSTAGED=0
  TASK_WORKTREE_STAGED=0
  if ! status="$(git -C "$wt" -c core.quotePath=false status --porcelain=v1 --untracked-files=all 2>/dev/null)"; then
    return 1
  fi
  TASK_WORKTREE_STATUS="$status"
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    x="${line:0:1}"
    y="${line:1:1}"
    case "${x}${y}" in
      '!!') continue ;;
      '??') TASK_WORKTREE_UNTRACKED=$((TASK_WORKTREE_UNTRACKED + 1)) ;;
      *)
        [ "$x" = ' ' ] || TASK_WORKTREE_STAGED=$((TASK_WORKTREE_STAGED + 1))
        [ "$y" = ' ' ] || TASK_WORKTREE_UNSTAGED=$((TASK_WORKTREE_UNSTAGED + 1))
        ;;
    esac
    TASK_WORKTREE_DIRTY=$((TASK_WORKTREE_DIRTY + 1))
  done <<< "$status"
  return 0
}

# Developer/Fixer → Reviewer 的唯一完成态判断。
# changed 要求 HEAD 相对 base 至少前进一个提交；no-change 要求 HEAD 正好
# 停在有效基线。auto 仅供 wip adapter 根据同一份基线事实选择 changed/no-change。
# 这个函数只读 Git，不 add、commit、stash、清理或修改远端。
task_completion_gate() {
  local wt="$1" base="${2:-}" conclusion="${3:-changed}"
  local head="" busy="" ahead="" base_oid=""
  TASK_COMPLETION_HEAD=""
  TASK_COMPLETION_CONCLUSION=""
  TASK_COMPLETION_AHEAD=0

  head="$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null || true)"
  if [ -z "$head" ]; then
    err_code task.completion_head_unreadable \
      "未完成 / BLOCKED：无法读取待审实现 HEAD，不能交接"
    return 1
  fi
  TASK_COMPLETION_HEAD="$head"

  if busy="$(task_git_busy "$wt")"; then
    err_code task.completion_git_busy \
      "未完成 / BLOCKED：Git 持久化状态异常（${busy}）；不能交接"
    return 1
  fi
  if ! task_worktree_status_counts "$wt"; then
    err_code task.completion_status_unreadable \
      "未完成 / BLOCKED：无法读取工作树状态，不能把它解释为 clean"
    return 1
  fi
  if [ "$TASK_WORKTREE_DIRTY" -ne 0 ]; then
    err_code task.completion_dirty \
      "未完成 / BLOCKED：待审实现未形成 clean HEAD；HEAD=${head}；untracked=${TASK_WORKTREE_UNTRACKED}；unstaged=${TASK_WORKTREE_UNSTAGED}；staged=${TASK_WORKTREE_STAGED}"
    return 1
  fi

  case "$conclusion" in
    changed|no-change|auto) ;;
    *)
      err_code task.completion_conclusion_invalid \
        "未完成 / BLOCKED：completion 结论非法：${conclusion}（只能是 changed、no-change 或内部 auto）"
      return 1
      ;;
  esac

  if [ -z "$base" ] || ! base_oid="$(git -C "$wt" rev-parse --verify "${base}^{commit}" 2>/dev/null)"; then
    err_code task.completion_base_unreadable \
      "未完成 / BLOCKED：无法读取交接基线 ${base:-空}，不能计算待审提交"
    return 1
  fi
  if ! git -C "$wt" merge-base --is-ancestor "$base_oid" "$head" >/dev/null 2>&1; then
    err_code task.completion_base_not_ancestor \
      "未完成 / BLOCKED：交接基线 ${base} 不在 HEAD ${head} 历史中"
    return 1
  fi
  if ! ahead="$(git -C "$wt" rev-list --count "${base_oid}..${head}" 2>/dev/null)" \
     || ! [[ "$ahead" =~ ^[0-9]+$ ]]; then
    err_code task.completion_ahead_unreadable \
      "未完成 / BLOCKED：无法计算 HEAD ${head} 相对基线 ${base} 的提交数量"
    return 1
  fi

  if [ "$conclusion" = auto ]; then
    if [ "$ahead" = 0 ]; then
      conclusion=no-change
    else
      conclusion=changed
    fi
  fi

  case "$conclusion" in
    no-change)
      if [ "$ahead" != 0 ]; then
        err_code task.completion_no_change_commits \
          "未完成 / BLOCKED：不能报告 no-change；HEAD=${head} 相对基线 ${base} 已有 ${ahead} 个提交"
        return 1
      fi
      TASK_COMPLETION_CONCLUSION=no-change
      TASK_COMPLETION_AHEAD=0
      printf 'completion=no-change HEAD=%s untracked=0 unstaged=0 staged=0\n' "$head"
      return 0
      ;;
    changed)
      if ! [[ "$ahead" =~ ^[1-9][0-9]*$ ]]; then
        err_code task.completion_no_commit \
          "未完成 / BLOCKED：相对 ${base} 没有待审提交；HEAD=${head}；untracked=0；unstaged=0；staged=0"
        return 1
      fi
      TASK_COMPLETION_CONCLUSION=changed
      TASK_COMPLETION_AHEAD="$ahead"
      printf 'completion=changed HEAD=%s untracked=0 unstaged=0 staged=0 committed_ahead=%s\n' \
        "$head" "$ahead"
      return 0
      ;;
  esac
}

# Checkpoint writer 的 completion 入口。非 completion 的 claim/进行中记录不
# 触发交接门禁；一旦声明 review-ready/no-change，就必须同时证明当前 Git 状态
# 与 Checkpoint 的 HEAD 一致。这个函数只调用 task_completion_gate，不改变 Git。
task_checkpoint_completion_gate() {
  local body="$1" wt="${2:-}" base="${3:-}"
  local state expected checkpoint_head

  if [ "$(type -t contract_checkpoint_completion_validate 2>/dev/null)" != function ]; then
    err_code task.checkpoint_completion_validator_missing \
      "未完成 / BLOCKED：缺少 Checkpoint completion 字段校验器"
    return 1
  fi
  contract_checkpoint_completion_validate "$body" || return 1
  state="${CONTRACT_CHECKPOINT_STATE:-}"
  case "$state" in
    '') return 0 ;;
    '未完成 / BLOCKED') return 0 ;;
    review-ready) expected=changed ;;
    no-change) expected=no-change ;;
    *)
      err_code task.checkpoint_completion_state \
        "未完成 / BLOCKED：Checkpoint 交接状态不可用：${state:-空}"
      return 1
      ;;
  esac
  [ -n "$wt" ] || {
    err_code task.checkpoint_completion_worktree \
      "未完成 / BLOCKED：Checkpoint completion 缺少当前工作树，不能交接"
    return 1
  }
  [ -n "$base" ] || {
    err_code task.checkpoint_completion_base \
      "未完成 / BLOCKED：Checkpoint completion 缺少交接基线，不能交接"
    return 1
  }
  task_completion_gate "$wt" "$base" "$expected" || return 1
  checkpoint_head="${CONTRACT_CHECKPOINT_HEAD:-}"
  if [ "$checkpoint_head" != "${TASK_COMPLETION_HEAD:-}" ]; then
    err_code task.checkpoint_head_mismatch \
      "未完成 / BLOCKED：Checkpoint HEAD（${checkpoint_head:-空}）不是当前门禁 HEAD（${TASK_COMPLETION_HEAD:-空}），不写入"
    return 1
  fi
  return 0
}

# Orca 创建工作树时可能把 displayName 里的 / 拍成 -。只做正向映射，不反向猜。
task_orca_flatten_slash() {
  printf '%s\n' "${1//\//-}"
}

task_name_matches_re() {
  local name="$1" regex="$2"
  [ -n "$name" ] && [ -n "$regex" ] || return 1
  printf '%s\n' "$name" | grep -qE "$regex"
}

task_branch_has_upstream() {
  local wt="$1" br="$2" remote merge
  remote="$(git -C "$wt" config --get "branch.${br}.remote" 2>/dev/null || true)"
  merge="$(git -C "$wt" config --get "branch.${br}.merge" 2>/dev/null || true)"
  [ -n "$remote" ] || [ -n "$merge" ]
}

task_local_head_exists() {
  git -C "$1" show-ref --verify --quiet "refs/heads/${2}"
}

# 真实读 origin。0=存在，1=不存在，2=读失败（调用方必须当硬失败，不猜测）。
task_origin_head_exists() {
  local wt="$1" br="$2" out rc=0
  out="$(GIT_TERMINAL_PROMPT=0 git -C "$wt" ls-remote --heads origin "refs/heads/${br}" 2>/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] || return 2
  [ -n "$out" ]
}

task_git_rename_blocked() {
  local wt="$1" gd
  gd="$(git -C "$wt" rev-parse --git-dir 2>/dev/null || true)"
  [ -n "$gd" ] || { echo "读不到 git-dir"; return 0; }
  if [ -f "$gd/locked" ]; then echo "worktree 已锁定"; return 0; fi
  if [ -f "$gd/index.lock" ] || [ -f "$gd/HEAD.lock" ] \
     || [ -f "$gd/packed-refs.lock" ] || [ -f "$gd/config.lock" ]; then
    echo "存在 git 锁文件"
    return 0
  fi
  return 1
}

# 把当前本地分支从 Orca 扁平化名改回 displayName。不碰 Orca 字段。
# 调用方必须已经证明：受 Orca 管理、displayName 合法、git 分支恰好是扁平化结果。
task_rename_orca_flat_branch() {
  local wt="$1" old="$2" new="$3" main cur busy blocked rc

  [ -n "$wt" ] && [ -n "$old" ] && [ -n "$new" ] && [ "$old" != "$new" ] \
    || { err_code claim.rename_args "    ✗ 自动改名参数不完整（不猜测）"; return 1; }

  main="$(default_branch)"
  if [ "$old" = "$main" ] || [ "$new" = "$main" ] || [ "$old" = main ] || [ "$new" = main ]; then
    err_code claim.rename_default_branch "    ✗ 拒绝把默认分支纳入自动改名"
    return 1
  fi

  cur="$(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null || true)"
  if [ "$cur" != "$old" ]; then
    err_code claim.rename_head_mismatch "    ✗ HEAD 是 ${cur:-游离}，不是 ${old}，拒绝自动改名"
    return 1
  fi

  if busy="$(task_git_busy "$wt")"; then
    err_code claim.rename_git_busy "    ✗ 不能改名：${busy}"
    return 1
  fi
  if blocked="$(task_git_rename_blocked "$wt")"; then
    err_code claim.rename_blocked "    ✗ 不能改名：${blocked}"
    return 1
  fi

  if task_local_head_exists "$wt" "$new"; then
    err_code claim.local_ref_exists "    ✗ 目标本地分支已存在：${new}，拒绝自动改名"
    return 1
  fi
  if task_branch_has_upstream "$wt" "$old"; then
    err_code claim.has_upstream "    ✗ 当前分支已有 upstream，拒绝自动改名"
    return 1
  fi

  if ! git -C "$wt" remote get-url origin >/dev/null 2>&1; then
    err_code claim.no_origin "    ✗ 没有 origin，无法确认远端分支不存在（不猜测）"
    return 1
  fi
  rc=0
  task_origin_head_exists "$wt" "$old" || rc=$?
  if [ "$rc" -eq 0 ]; then
    err_code claim.remote_ref_exists "    ✗ 源远端分支已存在：origin/${old}，拒绝自动改名"
    return 1
  fi
  if [ "$rc" -eq 2 ]; then
    err_code claim.remote_ref_unreadable "    ✗ 无法读取 origin/${old}（不猜测）"
    return 1
  fi
  rc=0
  task_origin_head_exists "$wt" "$new" || rc=$?
  if [ "$rc" -eq 0 ]; then
    err_code claim.remote_ref_exists "    ✗ 目标远端分支已存在：origin/${new}，拒绝自动改名"
    return 1
  fi
  if [ "$rc" -eq 2 ]; then
    err_code claim.remote_ref_unreadable "    ✗ 无法读取 origin/${new}（不猜测）"
    return 1
  fi

  if ! git -C "$wt" branch -m "$old" "$new"; then
    err_code claim.rename_failed "    ✗ git branch -m ${old} → ${new} 失败"
    return 1
  fi
  return 0
}

task_fetch_issue() {
  local owner="$1" repo="$2" number="$3" out="$4"
  GH_PAGER=cat gh api graphql \
    -f owner="$owner" \
    -f name="$repo" \
    -F number="$number" \
    -f query='query($owner:String!, $name:String!, $number:Int!) {
      repository(owner:$owner, name:$name) {
        issue(number:$number) {
          id title url body
          labels(first: 20) { nodes { name } }
          projectItems(first: 20) {
            nodes {
              id
              project { id number title }
              fieldValueByName(name: "Status") {
                ... on ProjectV2ItemFieldSingleSelectValue {
                  name
                  optionId
                  field {
                    ... on ProjectV2SingleSelectField {
                      id
                      options { id name }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }' > "$out"
}

# Issue 的标签名，JSON 数组。来自 task_fetch_issue 已取回的同一份 JSON，不另发请求。
# 路径安全由 task_repo_path_ok / task_path_in_scope 统一执行（旧名 task_repo_path_ascii_ok 仅作契约兼容标记）。
# In review 交付只复用唯一 PR，保持 In review，不改变生命周期语义。
task_issue_labels() {
  jq -c '[.data.repository.issue.labels.nodes[]?.name] // []' "$1" 2>/dev/null || echo '[]'
}

task_project_item() {
  local json="$1"
  jq -c --argjson n "$TASK_PROJECT_NUMBER" --arg t "$TASK_PROJECT_TITLE" '
    .data.repository.issue.projectItems.nodes
    | map(select(.project.number == $n and .project.title == $t))
    | if length == 1 then .[0] else empty end
  ' "$json"
}

task_option_id() {
  local item_json="$1" name="$2"
  printf '%s\n' "$item_json" | jq -r --arg n "$name" '
    ((.fieldValueByName.field.options) // [])
    | map(select(.name == $n) | .id)
    | .[0] // empty
  '
}

task_set_status() {
  local item_id="$1" project_id="$2" field_id="$3" option_id="$4"
  GH_PAGER=cat gh project item-edit \
    --id "$item_id" \
    --project-id "$project_id" \
    --field-id "$field_id" \
    --single-select-option-id "$option_id" \
    --format json >/dev/null
}

task_read_status_name() {
  local issue_json="$1" item
  [ -n "$issue_json" ] && [ -f "$issue_json" ] || return 1
  item="$(task_project_item "$issue_json" || true)"
  [ -n "$item" ] || return 1
  printf '%s' "$item" | jq -r '.fieldValueByName.name // empty'
}

# jq 的 // 把 false 当空。布尔字段必须走 tostring，不能 // empty。
task_json_bool() {
  local js="$1" expr="$2"
  printf '%s' "$js" | jq -r "$expr | if type == \"boolean\" then tostring else empty end"
}

# 成功列出评论后：stdout 是评论对象数组（可以是 []）。
# 列出失败、空输出、非数组 JSON 必须返回非 0，调用方不得当成「零条」去 POST。
# 不得把异常响应归一成 []。
task_issue_comments_json() {
  local owner="$1" repo="$2" number="$3" js
  if ! js="$(GH_PAGER=cat gh api --paginate "repos/${owner}/${repo}/issues/${number}/comments")"; then
    return 1
  fi
  if [ -z "$js" ] || [ -z "${js//[$' \t\r\n']/}" ]; then
    return 1
  fi
  printf '%s' "$js" | jq -rs '
      if length == 0 then
        error("empty comment response")
      elif any(type != "array") then
        error("comment response is not an array")
      else
        add
      end
      | if type != "array" then
          error("comment list is not an array")
        else
          .
        end
    '
}

# stdout：含标记的评论对象数组。
task_comments_matching() {
  local js="$1" mark="$2"
  printf '%s' "$js" | jq -c --arg m "$mark" \
    'map(select(.body != null and (.body | contains($m))))'
}

# 零条：stdout 空。一条：stdout 为该评论 JSON 对象。多条或列出失败：return 1。
task_unique_marked_comment() {
  local owner="$1" repo="$2" number="$3" mark="$4" label="$5"
  local all matches n
  if ! all="$(task_issue_comments_json "$owner" "$repo" "$number")"; then
    return 1
  fi
  if ! matches="$(task_comments_matching "$all" "$mark")"; then
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

# 成功列出评论后：有 Checkpoint 则打印其 id，没有则打印空行。
# 列出失败、空输出、非数组 JSON、多条 Checkpoint 必须返回非 0，
# 调用方不得因此新建评论。
task_find_checkpoint_id() {
  local owner="$1" repo="$2" number="$3" c
  if ! c="$(task_unique_marked_comment "$owner" "$repo" "$number" \
      "$TASK_CHECKPOINT_MARK" "Checkpoint")"; then
    return 1
  fi
  [ -n "$c" ] || { printf '\n'; return 0; }
  printf '%s' "$c" | jq -r '.id // empty'
}

# 从固定 Review 表格读字段。值两侧的反引号会去掉。
task_review_table_field() {
  local body="$1" key="$2"
  printf '%s' "$body" | awk -F '|' -v k="$key" '
    {
      raw = $0
      sub(/\r$/, "", raw)
      n = split(raw, a, "|")
      if (n < 3) next
      key = a[2]
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      if (key != k) next
      val = a[3]
      for (i = 4; i < n; i++) val = val "|" a[i]
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
      if (val ~ /^`.*`$/) {
        sub(/^`/, "", val)
        sub(/`$/, "", val)
      }
      print val
      exit
    }
  '
}

# actor 只记录 provenance，不是认证。允许 email / opaque id，但拒绝会破坏
# Markdown 表格或 machine-field 边界的字符；绝不把产品名当作缺省 actor。
task_actor_valid() {
  local actor="${1:-}"
  case "$actor" in
    ''|*[[:space:]]*|*'|'*|*'`'*|*'='*) return 1 ;;
  esac
  return 0
}

# 固定缺省链：显式 --actor → NEW_TASK_ACTOR → 当前 worktree 生效的
# git config user.email。命中即停；空值/非法值 fail-closed。
task_actor_resolve() {
  local candidate="${1:-}" wt="${2:-}" explicit="${3:-0}" actor
  if [ "$explicit" = 1 ] || [ -n "$candidate" ]; then
    actor="$candidate"
  elif [ -n "${NEW_TASK_ACTOR:-}" ]; then
    actor="$NEW_TASK_ACTOR"
  else
    actor="$(git -C "$wt" config --get user.email 2>/dev/null || true)"
  fi
  task_actor_valid "$actor" || return 1
  printf '%s\n' "$actor"
}

# Review / Checkpoint 内的精确 machine field。只认行首 key=，不从散文猜。
task_machine_field() {
  local body="$1" key="$2"
  printf '%s\n' "$body" | awk -v p="${key}=" '
    index($0, p) == 1 {
      line=$0
      sub(/\r$/, "", line)
      print substr(line, length(p) + 1)
      exit
    }
  '
}

task_machine_field_count() {
  local body="$1" key="$2"
  printf '%s\n' "$body" | awk -v p="${key}=" '
    index($0, p) == 1 { n++ }
    END { print n + 0 }
  '
}

task_validate_commit_title() {
  local title="$1" against="${2:-}"
  if [ -n "$against" ]; then
    "$TASK_COMMIT_MSG_CHECK" --title "$title" --against "$against"
  else
    "$TASK_COMMIT_MSG_CHECK" --title "$title"
  fi
}

# 当前 HEAD 有且仅有一条通过 Review 时，打印其中已校验的 Squash-Title。
# 没有适用的通过 Review：stdout 空、返回 0（由调用方另取合法标题，
# 不得沿用不合规 Issue 标题）。
# 多条 Review、列出失败、通过但缺标题或标题非法：返回 1。
task_passing_squash_title() {
  local owner="$1" repo="$2" number="$3" head="$4" against="${5:-}"
  local c body verdict rhead title
  if ! c="$(task_unique_marked_comment "$owner" "$repo" "$number" \
      "$TASK_REVIEW_MARK" "Review")"; then
    return 1
  fi
  [ -n "$c" ] || { printf '\n'; return 0; }
  body="$(printf '%s' "$c" | jq -r '.body // empty')"
  [ -n "$body" ] || { printf '\n'; return 0; }
  verdict="$(task_review_table_field "$body" "Verdict")"
  rhead="$(task_review_table_field "$body" "reviewed HEAD")"
  title="$(task_review_table_field "$body" "Squash-Title")"
  if [ "$verdict" != "$TASK_VERDICT_PASS" ] || [ "$rhead" != "$head" ]; then
    printf '\n'
    return 0
  fi
  if [ -z "$title" ] || [ "$title" = "（无）" ]; then
    err_code review.squash_title_missing "    ✗ 通过的 Review 没有 Squash-Title"
    return 1
  fi
  if ! task_validate_commit_title "$title" "$against"; then
    err_code task.squash_title_invalid "    ✗ Review 的 Squash-Title 未通过提交标题校验：$title"
    return 1
  fi
  printf '%s\n' "$title"
}

# 取得符合现有提交规范的 PR 标题。不另写 type/scope 规则，不猜。
# 优先：当前 HEAD 的通过 Review Squash-Title。
# 否则：已有匹配 PR 的标题若通过同一校验器。
# 否则：Issue 标题若通过同一校验器。
# 都没有：失败，请求人确认。
# 成功时在当前 shell 设置 TASK_PR_TITLE 与 TASK_PR_TITLE_SRC=review|pr|issue。
# 调用方不得用 $(...) 捕获：那是子 shell，写不回这两个变量，set -u 会炸。
task_resolve_pr_title() {
  local owner="$1" repo="$2" number="$3" head="$4" against="$5"
  local git_br="$6" main="$7" issue_title="$8"
  local title="" pr="" pr_title=""
  TASK_PR_TITLE=
  TASK_PR_TITLE_SRC=
  if ! title="$(task_passing_squash_title "$owner" "$repo" "$number" "$head" "$against")"; then
    return 1
  fi
  if [ -n "$title" ]; then
    TASK_PR_TITLE="$title"
    TASK_PR_TITLE_SRC=review
    return 0
  fi

  if ! pr="$(task_find_matching_pr "$owner" "$repo" "$git_br" "$main")"; then
    return 1
  fi
  if [ -n "$pr" ]; then
    pr_title="$(printf '%s' "$pr" | jq -r '.title // empty')"
    if [ -z "$pr_title" ]; then
      local pr_num js
      pr_num="$(printf '%s' "$pr" | jq -r '.number // empty')"
      if [[ "$pr_num" =~ ^[1-9][0-9]*$ ]] && js="$(task_pr_view_json "$owner" "$repo" "$pr_num")"; then
        pr_title="$(printf '%s' "$js" | jq -r '.title // empty')"
      fi
    fi
    if [ -n "$pr_title" ] && task_validate_commit_title "$pr_title" "$against" >/dev/null 2>&1; then
      TASK_PR_TITLE="$pr_title"
      TASK_PR_TITLE_SRC=pr
      return 0
    fi
  fi

  if [ -n "$issue_title" ] && task_validate_commit_title "$issue_title" "$against" >/dev/null 2>&1; then
    TASK_PR_TITLE="$issue_title"
    TASK_PR_TITLE_SRC=issue
    return 0
  fi

  err_code review.no_pr_title "    ✗ 没有可用的合法 PR 标题（不猜 type/scope，不另写规则）。"
  c_err "      没有当前 HEAD 的通过 Review Squash-Title。"
  if [ -n "$pr_title" ]; then
    c_err "      已有 PR 标题未通过提交规范校验：${pr_title}"
  fi
  if [ -n "$issue_title" ]; then
    c_err "      Issue 标题未通过提交规范校验：${issue_title}"
  else
    c_err "      Issue 标题为空。"
  fi
  c_err "      请先 zreview 写出 Squash-Title，或把 Issue/PR 标题改成 <type>(<scope>): <描述> 后再交付。"
  return 1
}

# 零条则 POST，一条则 PATCH，多条或列出失败则拒绝。正文必须含对应标记。
task_write_marked_comment() {
  local owner="$1" repo="$2" number="$3" mark="$4" label="$5" body="$6"
  local c cid payload
  case "$body" in
    *"$mark"*) ;;
    *)
      err_code task.comment_marker_missing "    ✗ ${label} 正文缺少标记 ${mark}，拒绝写入"
      return 1 ;;
  esac
  payload="$(jq -n --arg body "$body" '{body: $body}')"
  if ! c="$(task_unique_marked_comment "$owner" "$repo" "$number" "$mark" "$label")"; then
    err_code task.comment_unreadable "    ✗ 无法读取现有 ${label} 评论，不另开新楼。"
    return 1
  fi
  if [ -z "$c" ]; then
    printf '%s\n' "$payload" \
      | GH_PAGER=cat gh api -X POST "repos/${owner}/${repo}/issues/${number}/comments" --input - >/dev/null
    return
  fi
  cid="$(printf '%s' "$c" | jq -r '.id // empty')"
  if ! [[ "$cid" =~ ^[1-9][0-9]*$ ]]; then
    err_code task.comment_id_invalid "    ✗ ${label} 评论 id 不可用，不另开新楼。"
    return 1
  fi
  printf '%s\n' "$payload" \
    | GH_PAGER=cat gh api -X PATCH "repos/${owner}/${repo}/issues/comments/${cid}" --input - >/dev/null
}

task_write_checkpoint() {
  local body="$4" write_wt="${5:-${wt:-${Z_WT:-}}}" write_base="${6:-${base_git:-${Z_BASE:-}}}"
  task_checkpoint_completion_gate "$body" "$write_wt" "$write_base" || return 1
  task_write_marked_comment "$1" "$2" "$3" "$TASK_CHECKPOINT_MARK" "Checkpoint" "$body"
}

task_write_review() {
  task_write_marked_comment "$1" "$2" "$3" "$TASK_REVIEW_MARK" "Review" "$4"
}

# 从 git remote URL 解析 GitHub owner/repo。解析不了就失败，不猜测。
task_github_nwo() {
  local url="$1" rest owner repo
  [ -n "$url" ] || return 1
  url="${url%.git}"
  case "$url" in
    git@github.com:*) rest="${url#git@github.com:}" ;;
    ssh://git@github.com/*) rest="${url#ssh://git@github.com/}" ;;
    https://github.com/*) rest="${url#https://github.com/}" ;;
    http://github.com/*) rest="${url#http://github.com/}" ;;
    git://github.com/*) rest="${url#git://github.com/}" ;;
    *) return 1 ;;
  esac
  rest="${rest#/}"
  rest="${rest%%#*}"
  rest="${rest%%\?*}"
  case "$rest" in */*) ;; *) return 1 ;; esac
  owner="${rest%%/*}"
  repo="${rest#*/}"
  repo="${repo%%/*}"
  [[ "$owner" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  [[ "$repo"  =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  printf '%s/%s\n' "$owner" "$repo"
}

# 身份：policy override（测试/镜像）优先，否则 origin fetch URL。不读 tracked workspace.id。
task_repo_nwo() {
  local wt="${1:-${ROOT:-.}}" override url
  override="$(policy_get github.repo_override)"
  case "$override" in
    ''|null) ;;
    *)
      [[ "$override" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 1
      printf '%s\n' "$override"
      return 0
      ;;
  esac
  # 读配置里的 origin URL，不走 insteadOf 改写后的有效地址（那可能是本机路径）。
  url="$(git -C "$wt" config --get remote.origin.url 2>/dev/null \
    || git -C "$wt" remote get-url origin 2>/dev/null || true)"
  task_github_nwo "$url"
}

task_branch_pushable() {
  local br="$1" main="$2"
  [ -n "$br" ] || return 1
  [ "$br" != HEAD ] || return 1
  [ "$br" != "$main" ] || return 1
  [ "$br" != main ] || return 1
  [[ "$br" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || return 1
}

# 经典 token 才看 scopes 行；缺少 repo / project 直接失败。
# 不把 delete_repo 当依赖。fine-grained / app token 没有这行，仓库侧改走 API 实测。
# Project Status 是视图：push 前不探写，PR 建成后 best-effort 写一次 In review。
task_confirm_gh_access() {
  local owner="$1" repo="$2" txt scopes have_repo=0 have_project=0 s
  if ! txt="$(gh auth status 2>&1)"; then
    err_code task.gh_auth "    ✗ gh 未登录或无法读取认证状态"
    return 1
  fi
  scopes="$(printf '%s\n' "$txt" | awk -F"'" '/Token scopes:/{
    for (i = 2; i <= NF; i += 2) printf "%s ", $i
    print ""
    exit
  }')"
  if [ -n "$scopes" ]; then
    for s in $scopes; do
      [ "$s" = repo ] && have_repo=1
      [ "$s" = project ] && have_project=1
    done
    if [ "$have_repo" != 1 ]; then
      err_code task.gh_repo_scope "    ✗ gh token 缺少 repo 权限"
      return 1
    fi
    if [ "$have_project" != 1 ]; then
      err_code task.gh_project_scope "    ✗ gh token 缺少 project 权限"
      return 1
    fi
  fi
  local full push
  full="$(GH_PAGER=cat gh api "repos/${owner}/${repo}" --jq .full_name 2>/dev/null || true)"
  if [ "$full" != "${owner}/${repo}" ]; then
    err_code task.gh_repo_unreadable "    ✗ gh 无法以 ${owner}/${repo} 读取当前仓库"
    return 1
  fi
  push="$(GH_PAGER=cat gh api "repos/${owner}/${repo}" --jq '.permissions.push // false' 2>/dev/null || true)"
  if [ "$push" != "true" ]; then
    err_code task.gh_no_push "    ✗ gh 对 ${owner}/${repo} 没有 push 权限，无法创建 PR"
    return 1
  fi
  if ! GH_PAGER=cat gh pr list --repo "${owner}/${repo}" --limit 1 --json number >/dev/null; then
    err_code task.gh_pr_list "    ✗ gh 无法列出 ${owner}/${repo} 的 PR"
    return 1
  fi
  return 0
}

# 只推当前任务分支。refspec 两端都是该分支，不会写成默认分支。
task_push_task_branch() {
  local wt="$1" br="$2" main="$3" cur remote_sha
  if ! task_branch_pushable "$br" "$main"; then
    err_code review.branch_not_pushable "    ✗ 拒绝 push：分支非法（${br:-空}）"
    return 1
  fi
  cur="$(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null || true)"
  if [ "$cur" != "$br" ]; then
    err_code review.head_mismatch "    ✗ HEAD 是 ${cur:-游离}，不是 ${br}，拒绝 push"
    return 1
  fi
  if ! GIT_TERMINAL_PROMPT=0 git -C "$wt" push -u origin -- "refs/heads/${br}:refs/heads/${br}" >&2; then
    err_code review.push_failed "    ✗ push origin ${br} 失败"
    return 1
  fi
  remote_sha="$(git -C "$wt" ls-remote origin "refs/heads/${br}" | awk 'NF{print $1; exit}')"
  if [ -z "$remote_sha" ]; then
    err_code review.push_unconfirmed "    ✗ push 后远端没有 refs/heads/${br}"
    return 1
  fi
  printf '%s\n' "$remote_sha"
}

task_change_summary() {
  local wt="$1" base="$2" log stat
  log="$(git -C "$wt" log --format='- %s' "${base}..HEAD" 2>/dev/null || true)"
  [ -n "$log" ] || return 1
  stat="$(git -C "$wt" diff --stat "${base}...HEAD" 2>/dev/null || true)"
  printf '%s\n' "$log"
  if [ -n "$stat" ]; then
    printf '\n%s\n' "$stat"
  fi
}

task_pr_body() {
  local number="$1" summary="$2" evidence="$3"
  local issue_id="${TASK_PR_ISSUE_ID:-#${number}}"
  local cblob="${TASK_PR_CONTRACT:-}"
  local rhead="${TASK_PR_REVIEWED_HEAD:-}"
  cat <<EOF
${TASK_PR_MARK_BEGIN}
## 任务身份

| 项 | 值 |
| --- | --- |
| Issue | ${issue_id} |
| Contract | ${cblob:-（无）} |
| reviewed HEAD | ${rhead:-（无）} |

## 变更摘要

${summary}

## 验证摘要

\`\`\`
${evidence}
\`\`\`

Fixes #${number}
${TASK_PR_MARK_END}
EOF
}

# 用新的自动交付区块替换 old 里的对应部分，区块外原文不动。
# 已有成对标记：只换标记内。没有标记：从首个「## 变更摘要」换到代码围栏外
# 的第一行 Fixes #N（旧模板终笔）；不能用全文最后一个 Fixes #N，否则会吃掉
# 后面同样含这一行的人工说明。认不出则追加。标记不成对：失败，不输出。
task_pr_merge_body() {
  local old="$1" auto="$2" number="$3"
  [ -n "$auto" ] || return 1
  [[ "$number" =~ ^[1-9][0-9]*$ ]] || return 1
  # old 走 stdin，避免 heredoc 展开正文里的 $ 和命令替换。
  # 环境变量必须加在 awk 上；加在 printf 上的话 awk 读不到。
  printf '%s' "$old" | \
  TASK_PR_AUTO="$auto" TASK_PR_NUMBER="$number" \
  TASK_PR_BEGIN="$TASK_PR_MARK_BEGIN" TASK_PR_END="$TASK_PR_MARK_END" \
  awk '
    BEGIN {
      begin = ENVIRON["TASK_PR_BEGIN"]
      end = ENVIRON["TASK_PR_END"]
      auto = ENVIRON["TASK_PR_AUTO"]
      number = ENVIRON["TASK_PR_NUMBER"]
      nbegin = 0; nend = 0
      begin_at = 0; end_at = 0
      start = 0; firstfix = 0; infence = 0
    }
    {
      line = $0
      sub(/\r$/, "", line)
      i = NR
      lines[i] = $0
      text[i] = line
      if (line == begin) { nbegin++; begin_at = i }
      if (line == end) { nend++; end_at = i }
      if (line == "## 变更摘要" && start == 0) start = i
      if (start > 0 && i >= start && firstfix == 0) {
        if (line ~ /^```/) infence = infence ? 0 : 1
        else if (!infence && line == ("Fixes #" number)) firstfix = i
      }
    }
    END {
      n = NR
      if (auto != "" && substr(auto, length(auto), 1) != "\n") auto = auto "\n"
      if (nbegin == 0 && nend == 0) {
        if (start > 0 && firstfix >= start) {
          for (i = 1; i < start; i++) print lines[i]
          printf "%s", auto
          for (i = firstfix + 1; i <= n; i++) print lines[i]
        } else {
          for (i = 1; i <= n; i++) print lines[i]
          if (n > 0 && text[n] != "") print ""
          printf "%s", auto
        }
        exit 0
      }
      if (nbegin == 1 && nend == 1 && begin_at > 0 && begin_at < end_at) {
        for (i = 1; i < begin_at; i++) print lines[i]
        printf "%s", auto
        for (i = end_at + 1; i <= n; i++) print lines[i]
        exit 0
      }
      exit 1
    }
  '
}

# 打印匹配的单个未关闭 PR 的 JSON 对象；没有则空行。多个则失败。
task_find_matching_pr() {
  local owner="$1" repo="$2" head="$3" base="$4" js n
  if ! js="$(GH_PAGER=cat gh pr list \
      --repo "${owner}/${repo}" \
      --head "$head" \
      --base "$base" \
      --state open \
      --json number,url,isDraft,headRefName,baseRefName,state,body,title)"; then
    return 1
  fi
  n="$(printf '%s' "$js" | jq 'length')"
  if [ "$n" -gt 1 ]; then
    err_code review.ambiguous_pr "    ✗ 同一 head/base 有 ${n} 个未关闭 PR，拒绝猜测复用哪一个"
    return 1
  fi
  if [ "$n" = 0 ]; then
    printf '\n'
    return 0
  fi
  printf '%s\n' "$js" | jq -c '.[0]'
}

task_pr_view_json() {
  local owner="$1" repo="$2" num="$3"
  GH_PAGER=cat gh pr view "$num" --repo "${owner}/${repo}" \
    --json url,number,baseRefName,headRefName,headRefOid,isDraft,state,body,title
}

# 确认 PR 真实存在、base/head 正确、非 Draft、正文含独立一行 Fixes #号。
# 第 5 个参数若非空，远端 title 必须与其完全一致。
task_pr_fields_ok() {
  local js="$1" head="$2" base="$3" number="$4" expect_title="${5:-}"
  local st base_r head_r draft body title
  st="$(printf '%s' "$js" | jq -r '.state // empty')"
  base_r="$(printf '%s' "$js" | jq -r '.baseRefName // empty')"
  head_r="$(printf '%s' "$js" | jq -r '.headRefName // empty')"
  # 不要用 //：false // empty 是 empty，所有非 Draft PR 都会被判失败。
  draft="$(task_json_bool "$js" .isDraft)"
  body="$(printf '%s' "$js" | jq -r '.body // empty')"
  title="$(printf '%s' "$js" | jq -r '.title // empty')"
  [ "$st" = OPEN ] || return 1
  [ "$base_r" = "$base" ] || return 1
  [ "$head_r" = "$head" ] || return 1
  [ "$draft" = false ] || return 1
  if [ -n "$expect_title" ] && [ "$title" != "$expect_title" ]; then
    return 1
  fi
  printf '%s\n' "$body" | tr -d '\r' | grep -qx "Fixes #${number}"
}

# 只改 title。修正标题不得夹带 --body，以免覆盖人工维护的正文。
# 写入后必须回读，不一致则失败。
task_ensure_pr_title() {
  local owner="$1" repo="$2" num="$3" expect="$4" js got
  [ -n "$expect" ] || return 1
  if ! js="$(task_pr_view_json "$owner" "$repo" "$num")"; then
    err_code task.pr_unreadable "    ✗ 无法读取 PR #${num} 标题"
    return 1
  fi
  got="$(printf '%s' "$js" | jq -r '.title // empty')"
  if [ "$got" != "$expect" ]; then
    GH_PROMPT_DISABLED=1 GH_PAGER=cat gh pr edit "$num" --repo "${owner}/${repo}" \
      --title "$expect" >/dev/null \
      || { err_code review.pr_title_update_failed "    ✗ 更新 PR #${num} 标题失败"; return 1; }
    if ! js="$(task_pr_view_json "$owner" "$repo" "$num")"; then
      err_code review.pr_title_reread_failed "    ✗ PR #${num} 标题已请求写入，但回读失败"
      return 1
    fi
    got="$(printf '%s' "$js" | jq -r '.title // empty')"
  fi
  if [ "$got" != "$expect" ]; then
    err_code review.pr_title_mismatch "    ✗ PR #${num} 标题回读不一致"
    c_err "      期望：${expect}"
    c_err "      实际：${got:-空}"
    return 1
  fi
  return 0
}

# 创建或复用 head=当前分支、base=默认分支的非 Draft PR。成功打印「编号 URL」。
# 第 8 个参数为 1 时：创建与复用都把远端标题写成 $title，并回读确认；
# 为修正标题只发 --title，不夹带 --body。调用方必须先取得合法标题。
# 第 9 个参数为 0 时：没有匹配 PR 则失败，不得创建第二个 PR（In review 重交付）。
task_ensure_pr() {
  local owner="$1" repo="$2" head="$3" base="$4" number="$5" title="$6" body_file="$7"
  local sync_title="${8:-0}"
  local allow_create="${9:-1}"
  local pr pr_num pr_url js is_draft created reused=0
  local old_body auto_body merged_file
  local expect_title=""
  if ! pr="$(task_find_matching_pr "$owner" "$repo" "$head" "$base")"; then
    return 1
  fi
  if [ -n "$pr" ]; then
    reused=1
    pr_num="$(printf '%s' "$pr" | jq -r '.number // empty')"
    pr_url="$(printf '%s' "$pr" | jq -r '.url // empty')"
    is_draft="$(task_json_bool "$pr" .isDraft)"
  else
    if [ "$allow_create" != 1 ]; then
      err_code review.no_matching_pr "    ✗ 不存在匹配的未关闭 PR，拒绝创建第二个 PR"
      return 1
    fi
    if created="$(GH_PROMPT_DISABLED=1 GH_PAGER=cat gh pr create \
        --repo "${owner}/${repo}" \
        --base "$base" \
        --head "$head" \
        --title "$title" \
        --body-file "$body_file")"; then
      pr_url="$(printf '%s\n' "$created" | awk '/https:\/\/github.com\/[^ ]+\/pull\/[0-9]+/{u=$0} END{print u}')"
      pr_num="${pr_url##*/}"
    else
      if ! pr="$(task_find_matching_pr "$owner" "$repo" "$head" "$base")"; then
        return 1
      fi
      if [ -z "$pr" ]; then
        err_code review.remote_exists_no_pr "    ✗ 远端分支已存在、未创建 PR"
        return 1
      fi
      reused=1
      pr_num="$(printf '%s' "$pr" | jq -r '.number // empty')"
      pr_url="$(printf '%s' "$pr" | jq -r '.url // empty')"
      is_draft="$(task_json_bool "$pr" .isDraft)"
    fi
  fi
  if [ -z "$pr_url" ] || ! [[ "$pr_num" =~ ^[1-9][0-9]*$ ]]; then
    err_code review.remote_exists_no_pr "    ✗ 远端分支已存在、未创建 PR"
    return 1
  fi

  if [ "$reused" = 1 ] && [ "$is_draft" = true ]; then
    GH_PROMPT_DISABLED=1 GH_PAGER=cat gh pr ready "$pr_num" --repo "${owner}/${repo}" >/dev/null \
      || { err_code review.undraft_failed "    ✗ 已有 PR #${pr_num} 是 Draft，转为 ready 失败"; return 1; }
  fi
  if [ "$reused" = 1 ]; then
    if ! printf '%s' "$pr" | jq -e 'has("body")' >/dev/null; then
      if ! js="$(task_pr_view_json "$owner" "$repo" "$pr_num")"; then
        err_code review.pr_body_unreadable "    ✗ 无法读取已有 PR #${pr_num} 正文，拒绝覆盖"
        return 1
      fi
      old_body="$(printf '%s' "$js" | jq -r '.body // empty')"
    else
      old_body="$(printf '%s' "$pr" | jq -r '.body // empty')"
    fi
    auto_body="$(cat "$body_file")"
    merged_file="$(mktemp -t new-task-pr-merged.XXXXXX)"
    TMPS="$TMPS $merged_file"
    if ! task_pr_merge_body "$old_body" "$auto_body" "$number" > "$merged_file"; then
      err_code review.pr_body_markers "    ✗ 已有 PR #${pr_num} 正文的交付区块标记不成对，拒绝覆盖。请人工整理后再交付。"
      return 1
    fi
    GH_PROMPT_DISABLED=1 GH_PAGER=cat gh pr edit "$pr_num" --repo "${owner}/${repo}" \
      --body-file "$merged_file" >/dev/null \
      || { err_code review.pr_body_update_failed "    ✗ 更新 PR #${pr_num} 正文失败"; return 1; }
  fi

  if [ "$sync_title" = 1 ]; then
    if ! task_ensure_pr_title "$owner" "$repo" "$pr_num" "$title"; then
      return 1
    fi
    expect_title="$title"
  fi

  if ! js="$(task_pr_view_json "$owner" "$repo" "$pr_num")"; then
    err_code review.pr_reread_failed "    ✗ PR 已请求写入，但回读失败（${pr_url}）"
    return 1
  fi
  if ! task_pr_fields_ok "$js" "$head" "$base" "$number" "$expect_title"; then
    err_code review.pr_fields "    ✗ PR ${pr_url} 存在，但 base/head/Draft/Fixes/标题 字段不正确"
    return 1
  fi
  pr_url="$(printf '%s' "$js" | jq -r '.url')"
  printf '%s %s\n' "$pr_num" "$pr_url"
}

# PR 已在之后处理 Status。尝试写一次 In review，回读不是 In review 只警告。
# 不 return 1，不写回其它 Status。
task_review_sync_status() {
  if [ -n "${item_id:-}" ] && [ -n "${project_id:-}" ] && [ -n "${field_id:-}" ] \
     && [ -n "${to_id:-}" ]; then
    task_set_status "$item_id" "$project_id" "$field_id" "$to_id" || true
  fi
  new_status=""
  if task_fetch_issue "$owner" "$repo" "$number" "$issue_json"; then
    item_json="$(task_project_item "$issue_json" || true)"
    new_status="$(task_read_status_name "$issue_json" || true)"
  fi
  if [ "$new_status" = "$TASK_STATUS_REVIEW" ]; then
    c_ok "    ✓ ${TASK_STATUS_REVIEW}"
    return 0
  fi
  if [ -n "$new_status" ]; then
    z_warn_if_status_drift "${derived_status:-$TASK_STATUS_REVIEW}" "$new_status"
  else
    c_warn "    ⚠ 回读 Project 失败或 Status 为空；PR 已在，不写回"
  fi
  return 0
}

# 依赖 cmd_task 预检已经通过：调用方的局部变量对 bash 动态作用域可见。
# 放行看推导状态。Project Status 是视图：best-effort 写一次 In review，失败只警告。
# In review：只更新已有唯一 PR，不新建第二个 PR。
task_review_deliver() {
  local origin_nwo remote_sha summary body_file pr_line pr_num pr_url pr
  local item_id project_id field_id from_id to_id now_iso ck_body new_status
  local claim_actor claim_body
  local redeliver=0 allow_create=1 exist_pr exist_js ck_project ck_next
  local completion_state completion_persistence completion_classification

  case "${derived_status:-}" in
    "$TASK_STATUS_PROGRESS") ;;
    "$TASK_STATUS_REVIEW")
      redeliver=1
      allow_create=0
      ;;
    *)
      err_code review.wrong_status "    ✗ 推导状态不是 ${TASK_STATUS_PROGRESS} 或 ${TASK_STATUS_REVIEW}（当前：${derived_status:-空}）。不 push、不创建 PR。"
      return 1
      ;;
  esac

  # 交付的唯一完成态：最终待审实现必须已经在明确 HEAD，且工作树 clean。
  # 这里先门禁，确保 git add / commit / index.lock 等持久化失败不会进入
  # gh、PR 或 Checkpoint 写入路径；Checkpoint 前还会再次复读。
  if ! task_completion_gate "$wt" "${base_git:-}" changed; then
    return 1
  fi
  if [ -n "${head:-}" ] && [ "$TASK_COMPLETION_HEAD" != "$head" ]; then
    err_code review.head_changed \
      "未完成 / BLOCKED：交付入口看到的 HEAD 已变化（${head} → ${TASK_COMPLETION_HEAD}），拒绝继续"
    return 1
  fi
  head="$TASK_COMPLETION_HEAD"
  completion_state=review-ready
  completion_persistence='committed + clean HEAD'
  completion_classification='untracked=0 / unstaged=0 / staged=0'

  # 在任何 push / PR 写入前先证明领取 provenance；交付阶段末尾会再次复读，
  # 防止 Checkpoint 在远端并发变化后仍覆盖成一条无 actor 的记录。
  claim_body="$(task_checkpoint_body "$owner" "$repo" "$number" || true)"
  [ "$(task_machine_field_count "$claim_body" claim_actor)" = 1 ] \
    || { err_code review.claim_actor_missing "    ✗ 当前 Checkpoint 必须含且仅含一个 claim_actor machine field，拒绝交付"; return 1; }
  claim_actor="$(task_machine_field "$claim_body" claim_actor)"
  task_actor_valid "$claim_actor" \
    || { err_code review.claim_actor_missing "    ✗ 当前 Checkpoint 的 claim_actor 非法，拒绝交付"; return 1; }

  echo "── 6. gh 权限与远端仓库 ────────────────"
  origin_nwo="$(task_repo_nwo "$wt" || true)"
  if [ -z "$origin_nwo" ]; then
    err_code review.origin_unparsed "    ✗ 无法从 origin URL 解析 GitHub 仓库（不猜测）"
    return 1
  fi
  if [ "$origin_nwo" != "${owner}/${repo}" ]; then
    err_code review.origin_mismatch "    ✗ origin 是 ${origin_nwo}，Issue 绑定的是 ${owner}/${repo}。远端不是当前仓库。"
    return 1
  fi
  if ! task_confirm_gh_access "$owner" "$repo"; then
    return 1
  fi

  if [ "$redeliver" = 1 ]; then
    if ! exist_pr="$(task_find_matching_pr "$owner" "$repo" "$git_br" "$main")"; then
      err_code review.ambiguous_pr "    ✗ In review 下存在多个候选 PR，拒绝猜测，不新建第二个 PR。"
      return 1
    fi
    if [ -z "$exist_pr" ]; then
      err_code review.no_matching_pr "    ✗ In review 下不存在匹配的未关闭 PR，不新建第二个 PR。"
      return 1
    fi
    pr_num="$(printf '%s' "$exist_pr" | jq -r '.number // empty')"
    if ! exist_js="$(task_pr_view_json "$owner" "$repo" "$pr_num")"; then
      err_code review.pr_unreadable "    ✗ 无法读取已有 PR #${pr_num}，不新建第二个 PR。"
      return 1
    fi
    if ! task_pr_fields_ok "$exist_js" "$git_br" "$main" "$number" ""; then
      err_code review.pr_not_owned "    ✗ 已有 PR #${pr_num} 不能证明属于当前任务（head/base/Draft/Fixes）。不新建第二个 PR。"
      return 1
    fi
    item_json="$(task_project_item "$issue_json" || true)"
    item_id="$(printf '%s' "$item_json" | jq -r '.id // empty')"
    project_id="$(printf '%s' "$item_json" | jq -r '.project.id // empty')"
    field_id="$(printf '%s' "$item_json" | jq -r '.fieldValueByName.field.id // empty')"
    from_id="$(task_option_id "$item_json" "$TASK_STATUS_PROGRESS")"
    to_id="$(task_option_id "$item_json" "$TASK_STATUS_REVIEW")"
    new_status="$TASK_STATUS_REVIEW"
    c_ok "    ✓ gh 可访问 ${owner}/${repo}；In review 重交付复用 PR #${pr_num}"
  else
    item_json="$(task_project_item "$issue_json" || true)"
    item_id="$(printf '%s' "$item_json" | jq -r '.id // empty')"
    project_id="$(printf '%s' "$item_json" | jq -r '.project.id // empty')"
    field_id="$(printf '%s' "$item_json" | jq -r '.fieldValueByName.field.id // empty')"
    from_id="$(task_option_id "$item_json" "$TASK_STATUS_PROGRESS")"
    to_id="$(task_option_id "$item_json" "$TASK_STATUS_REVIEW")"
    new_status="$TASK_STATUS_PROGRESS"
    if [ -z "$project_status" ]; then
      c_warn "    ⚠ Project Status 是空，推导状态是 ${derived_status}（以推导为准，不写回）"
    else
      z_warn_if_status_drift "$derived_status" "$project_status"
    fi
    c_ok "    ✓ gh 可访问 ${owner}/${repo}；origin 一致"
  fi
  evidence="${evidence}远端 origin=${origin_nwo}"$'\n'

  echo "── 7. PR 标题 ──────────────────────────"
  local title="" sync_title=1
  TASK_PR_TITLE=
  TASK_PR_TITLE_SRC=
  if ! task_resolve_pr_title "$owner" "$repo" "$number" "$head" "$base_git" \
      "$git_br" "$main" "$issue_title"; then
    c_err "      不 push、不创建 PR。"
    return 1
  fi
  title="$TASK_PR_TITLE"
  if [ -z "$title" ] || [ -z "$TASK_PR_TITLE_SRC" ]; then
    err_code review.no_pr_title "    ✗ 未得到合法 PR 标题（来源空）"
    c_err "      不 push、不创建 PR。"
    return 1
  fi
  if [ "$TASK_PR_TITLE_SRC" != review ]; then
    err_code review.no_passing_review "    ✗ 首次与重交付都需要当前 Contract/HEAD 的通过 Review / Squash-Title"
    c_err "      不 push、不创建或更新 PR。"
    return 1
  fi
  c_ok "    ✓ 使用合法 PR 标题（${TASK_PR_TITLE_SRC}）"
  echo "      ${title}"
  evidence="${evidence}PR 标题 ${title}（${TASK_PR_TITLE_SRC}）"$'\n'

  # Review 必须绑定 origin/main 当前的契约 blob；契约重新批准过就是 stale，拒绝交付。
  local _rc _rbody _rblob
  _rc="$(task_unique_marked_comment "$owner" "$repo" "$number" "$TASK_REVIEW_MARK" "Review")" \
    || { c_err "    ✗ 无法读取 Review"; return 1; }
  [ -n "$_rc" ] || { c_err "    ✗ 没有 Review，拒绝交付"; return 1; }
  _rbody="$(printf '%s' "$_rc" | jq -r '.body // empty')"
  _rblob="$(task_review_table_field "$_rbody" "Contract")"
  if contract_stale "$_rblob" "$contract_blob" "Review"; then
    c_err "      不 push、不创建或更新 PR。重新 zreview 后再交付。"
    return 1
  fi
  if ! contract_review_validate "$_rbody" "$contract_json" "$contract_blob" "$head"; then
    c_err "    ✗ Review 未通过当前 Contract 的完整校验，拒绝交付。"
    return 1
  fi
  c_ok "    ✓ Review 绑定当前 Contract ${contract_blob:0:12} 与 HEAD"

  echo "── 8. push 当前任务分支 ────────────────"
  if ! task_branch_pushable "$git_br" "$main"; then
    err_code review.branch_not_pushable "    ✗ 拒绝向 ${main} 或非法分支 push（当前：${git_br:-空}）"
    return 1
  fi
  if ! remote_sha="$(task_push_task_branch "$wt" "$git_br" "$main")"; then
    return 1
  fi
  if [ "$remote_sha" != "$head" ]; then
    err_code review.remote_head_mismatch "    ✗ 远端 ${git_br} 是 ${remote_sha}，与本地 HEAD ${head} 不一致"
    return 1
  fi
  c_ok "    ✓ origin/${git_br} @ ${head}"
  evidence="${evidence}push origin ${git_br} @ ${head}"$'\n'

  echo "── 9. 创建或复用 PR ────────────────────"
  if ! summary="$(task_change_summary "$wt" "$base_git")"; then
    err_code review.summary_failed "    ✗ 写不出相对 ${base_git} 的变更摘要"
    c_err "      远端分支已存在、未创建 PR"
    return 1
  fi
  evidence="${evidence}PR 目标 head=${git_br} base=${main} 非 Draft"$'\n'
  evidence="${evidence}Fixes #${number}"$'\n'

  body_file="$(mktemp -t new-task-pr-body.XXXXXX)"
  TMPS="$TMPS $body_file"
  TASK_PR_ISSUE_ID="${owner}/${repo}#${number}"
  TASK_PR_REVIEWED_HEAD="$head"
  TASK_PR_CONTRACT="$contract_blob"
  contract_pr_validate "$(task_pr_body "$number" "$summary" "$evidence")" \
    "$number" "$contract_blob" "$head" \
    || { err_code contract.pr_invalid "    ✗ PR 正文未通过 Contract 校验"; return 1; }
  task_pr_body "$number" "$summary" "$evidence" > "$body_file"

  if ! pr_line="$(task_ensure_pr "$owner" "$repo" "$git_br" "$main" "$number" "$title" "$body_file" "$sync_title" "$allow_create")"; then
    pr="$(task_find_matching_pr "$owner" "$repo" "$git_br" "$main" || true)"
    if [ -n "$pr" ]; then
      pr_url="$(printf '%s' "$pr" | jq -r '.url // empty')"
      [ -n "$pr_url" ] && c_err "      PR 已存在：${pr_url}"
    fi
    return 1
  fi
  pr_num="${pr_line%% *}"
  pr_url="${pr_line#* }"
  if [ -z "$pr_num" ] || [ -z "$pr_url" ] || [ "$pr_url" = "$pr_line" ]; then
    err_code review.remote_exists_no_pr "    ✗ 远端分支已存在、未创建 PR"
    return 1
  fi
  c_ok "    ✓ PR #${pr_num}  ${pr_url}"
  echo "      head=${git_br}  base=${main}  非 Draft  Fixes #${number}"
  echo "      title=${title}"
  evidence="${evidence}PR ${pr_url}"$'\n'

  echo "── 10. Checkpoint ──────────────────────────"
  if ! task_completion_gate "$wt" "${base_git:-}" changed; then
    err_code review.completion_not_persisted \
      "未完成 / BLOCKED：PR 已存在但当前 HEAD/worktree 未保持 completion；不写完成 Checkpoint"
    return 1
  fi
  if [ "$TASK_COMPLETION_HEAD" != "$head" ]; then
    err_code review.head_changed \
      "未完成 / BLOCKED：写 Checkpoint 前 HEAD 已变化（${head} → ${TASK_COMPLETION_HEAD}）；不写完成 Checkpoint"
    return 1
  fi
  evidence="${evidence}completion=changed HEAD=${head}；committed + clean HEAD；${completion_classification}；相对 ${base_git} 有 ${TASK_COMPLETION_AHEAD} 个待审提交"$'\n'
  now_iso="$(date +%Y-%m-%dT%H:%M:%S%z)"
  claim_body="$(task_checkpoint_body "$owner" "$repo" "$number" || true)"
  [ "$(task_machine_field_count "$claim_body" claim_actor)" = 1 ] \
    || { err_code review.claim_actor_missing "    ✗ 当前 Checkpoint 必须含且仅含一个 claim_actor machine field，拒绝覆盖"; return 1; }
  claim_actor="$(task_machine_field "$claim_body" claim_actor)"
  [ -n "$claim_actor" ] && task_actor_valid "$claim_actor" \
    || { err_code review.claim_actor_missing "    ✗ 当前 Checkpoint 没有有效 claim_actor，拒绝覆盖"; return 1; }
  if [ "$redeliver" = 1 ]; then
    ck_project="${TASK_PROJECT_TITLE} #${TASK_PROJECT_NUMBER} 重交付 Status=${TASK_STATUS_REVIEW}"
    ck_next="In review 重交付完成，Status 保持 ${TASK_STATUS_REVIEW}。等待审查与合并。"
  else
    ck_project="${TASK_PROJECT_TITLE} #${TASK_PROJECT_NUMBER} 交付前 Status=${TASK_STATUS_PROGRESS}，目标=${TASK_STATUS_REVIEW}"
    ck_next="等待人审查与合并"
  fi
  ck_body="$(cat <<EOF
${TASK_CHECKPOINT_MARK}
claim_actor=${claim_actor}
## Checkpoint

由 \`new task review\` 写入或更新，同一条评论反复覆盖，不另开新楼。

| 项 | 值 |
| --- | --- |
| Issue | ${owner}/${repo}#${number} |
| Contract | \`${contract_blob}\` |
| claim_actor | \`${claim_actor}\` |
| 分支 | ${logical_br}（git: ${git_br}） |
| 工作树 | \`${wt}\` |
| 交付时间 | ${now_iso} |
| HEAD | \`${head}\` |
| 工作区状态 | ${ws_status} |
| 交接状态 | ${completion_state} |
| HEAD 持久化 | ${completion_persistence} |
| 工作树分类 | ${completion_classification} |
| 允许范围 | $(task_scope_oneline "$scope") |
| PR | ${pr_url} |
| PR head → base | ${git_br} → ${main} |
| Project | ${ck_project} |
| 下一步 | ${ck_next} |

### 验证证据

\`\`\`
${evidence}
\`\`\`
EOF
)"
  if ! task_write_checkpoint "$owner" "$repo" "$number" "$ck_body"; then
    err_code review.checkpoint_write_failed "    ✗ Checkpoint 写入失败。PR 已存在：${pr_url}"
    return 1
  fi
  c_ok "    ✓ 已写入同一条 Checkpoint 评论"

  echo "── 11. Project Status ──────────────────────"
  task_review_sync_status

  echo
  if [ "$redeliver" = 1 ]; then
    c_ok "✓ 已更新原 PR，Status 保持 ${TASK_STATUS_REVIEW}"
  else
    c_ok "✓ 已交付到评审"
  fi
  echo "  PR     ${pr_url}"
  echo "  Status ${new_status}"
  echo "  下一步 ${ck_next}"
  echo "  本命令未合并 PR、未关闭 Issue、未向 ${main} push、未改为 Done。"
  return 0
}

# 人在主工作区把 Issue 正文写成 origin/main 上的契约文件。
# Backlog → Ready；在途任务只换契约、不动 Status。契约已进 main 即批准成功；Status 写失败只警告。
task_approve() {
  local n="$1" main nwo owner repo issue_json body title url blob
  local item_json item_id project_id field_id ready_id st top root_c
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || die_code task.issue_number_invalid "Issue 编号不合法：$n"
  [ "$(git -C "$ROOT" rev-parse --is-inside-work-tree 2>/dev/null || true)" = true ] \
    || die_code contract.approve_failed "approve 必须在主工作区运行"
  top="$(cd "$(git -C "$ROOT" rev-parse --show-toplevel)" && pwd -P)"
  root_c="$(cd "$ROOT" && pwd -P)"
  [ "$top" = "$root_c" ] \
    || die_code contract.approve_failed "approve 必须在主工作区运行（当前仓库根不是 ${ROOT}）"
  # 链接 worktree 的 .git 是文件；主工作区是目录。
  [ ! -f "$ROOT/.git" ] \
    || die_code contract.approve_failed "approve 必须在主工作区运行，不是任务 worktree"
  nwo="$(task_repo_nwo "$ROOT" || true)"
  [ -n "$nwo" ] || die_code review.origin_unparsed "无法从 origin URL 解析 GitHub 仓库（不猜测）"
  owner="${nwo%/*}"
  repo="${nwo#*/}"
  main="$(default_branch)"
  issue_json="$(mktemp -t new-task-approve.XXXXXX)"; TMPS="$TMPS $issue_json"
  if ! task_fetch_issue "$owner" "$repo" "$n" "$issue_json"; then
    die_code task.issue_fetch_failed "gh 读取 ${owner}/${repo}#${n} 失败"
  fi
  if [ "$(jq -r '.data.repository.issue.id // empty' "$issue_json")" = "" ]; then
    die_code task.issue_not_found "${owner}/${repo}#${n} 不存在或无权读取"
  fi
  body="$(jq -r '.data.repository.issue.body // empty' "$issue_json")"
  title="$(jq -r '.data.repository.issue.title // empty' "$issue_json")"
  url="$(jq -r '.data.repository.issue.url // empty' "$issue_json")"
  blob="$(contract_approve "$ROOT" "$n" "$body" "$title" "$url" "$main")" || return 1
  echo "    契约 blob ${blob}"
  item_json="$(task_project_item "$issue_json" || true)"
  if [ -z "$item_json" ]; then
    c_warn "    ⚠ Issue 不在 ${TASK_PROJECT_TITLE} 上，未改 Status（契约已在 ${main}）"
    return 0
  fi
  st="$(printf '%s' "$item_json" | jq -r '.fieldValueByName.name // empty')"
  case "$st" in
    "$TASK_STATUS_READY")
      c_ok "    ✓ Status 已是 ${TASK_STATUS_READY}"
      return 0
      ;;
    "$TASK_STATUS_PROGRESS"|"$TASK_STATUS_REVIEW")
      c_ok "    ✓ 契约已在 main（${blob:0:12}），Status 保持 ${st}；若 blob 已变化，在途 Review 已 stale，需重新 zreview"
      return 0
      ;;
    "$TASK_STATUS_DONE")
      c_warn "    ⚠ 任务已 Done，契约文件已更新但 Status 不动；确需重开请人工改"
      return 0
      ;;
    ""|"$TASK_STATUS_BACKLOG")
      ;;
    *)
      c_warn "    ⚠ Status 为 ${st}（未知），契约已在 ${main}，未改 Status"
      return 0
      ;;
  esac
  item_id="$(printf '%s' "$item_json" | jq -r '.id // empty')"
  project_id="$(printf '%s' "$item_json" | jq -r '.project.id // empty')"
  field_id="$(printf '%s' "$item_json" | jq -r '.fieldValueByName.field.id // empty')"
  ready_id="$(task_option_id "$item_json" "$TASK_STATUS_READY")"
  if [ -z "$item_id" ] || [ -z "$project_id" ] || [ -z "$field_id" ] || [ -z "$ready_id" ]; then
    c_warn "    ⚠ 契约已在 ${main}，但 Project Status 字段不完整，未改 Status"
    return 0
  fi
  if ! task_set_status "$item_id" "$project_id" "$field_id" "$ready_id"; then
    c_warn "    ⚠ 契约已在 ${main}，但 Status 未能改为 ${TASK_STATUS_READY}（请人工改）"
    return 0
  fi
  c_ok "    ✓ Status → ${TASK_STATUS_READY}"
  return 0
}

# 绑定落在该 worktree 自己的 git dir，不进 tracked 文件、不 push。
# 不能用 `git config --local`：linked worktree 默认共用主仓 config，会串树。
TASK_BIND_FILE='new.task.issue'

task_is_main_worktree() {
  [ -d "$1/.git" ] && [ ! -f "$1/.git" ]
}

task_bind_path() {
  local wt="${1:-$ROOT}" gd
  gd="$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null || true)"
  [ -n "$gd" ] || return 1
  printf '%s/%s\n' "$gd" "$TASK_BIND_FILE"
}

task_bind_read() {
  local f
  f="$(task_bind_path "${1:-$ROOT}")" || return 0
  [ -f "$f" ] || return 0
  tr -d '\r\n' < "$f"
}

task_hint_bind() {
  printf '%s\n' "new task bind ${1:-<n>}" >&2
}

task_is_sparse() {
  [ "$(git -C "$1" config --bool core.sparseCheckout 2>/dev/null || true)" = true ]
}

# 可见性边界：always_include + 契约范围。根层文件由 cone 自动带上，不进 set 列表。
task_sparse_set_paths() {
  local wt="$1" scope="$2" always p q covered_by_dir
  always="$(worktree_always_include)"
  for p in $always; do
    printf '%s\n' "$p"
  done
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    p="${p#./}"; p="${p%/}"
    task_is_cone_root_file "$wt" "$p" && continue
    # cone 模式只接受目录。契约可以同时列出一个目录和其中的精确文件，
    # 后者已经被前者覆盖时不要把文件路径传给 sparse-checkout set。
    covered_by_dir=0
    for q in $always; do
      q="${q#./}"; q="${q%/}"
      if [ "$q" != "$p" ] && [ -d "$wt/$q" ] && task_is_under "$p" "$q"; then
        covered_by_dir=1
        break
      fi
    done
    [ "$covered_by_dir" = 1 ] && continue
    while IFS= read -r q; do
      [ -n "$q" ] || continue
      q="${q#./}"; q="${q%/}"
      if [ "$q" != "$p" ] && [ -d "$wt/$q" ] && task_is_under "$p" "$q"; then
        covered_by_dir=1
        break
      fi
    done <<< "$scope"
    [ "$covered_by_dir" = 1 ] && continue
    printf '%s\n' "$p"
  done <<< "$scope"
}

# 完整检出不是合法任务工作树。clean 时收成 cone sparse；已是 sparse 则保持。
task_bind_ensure_sparse() {
  local wt="$1" scope="$2" git_sparse busy dirty
  local sparse=()
  local p seen=" "
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$seen" in *" $p "*) continue ;; esac
    seen="${seen}${p} "
    sparse+=("$p")
  done < <(task_sparse_set_paths "$wt" "$scope")
  [ "${#sparse[@]}" -gt 0 ] || {
    err_code task.sparse_set_failed "sparse 路径为空（always_include + 契约范围）"
    return 1
  }

  if task_is_sparse "$wt"; then
    return 0
  fi
  if busy="$(task_git_busy "$wt")"; then
    err_code task.git_busy "bind 要把工作树收成 sparse，但不能在 git 忙时改检出：${busy}"
    return 1
  fi
  dirty="$(git -C "$wt" -c core.quotePath=false status --porcelain 2>/dev/null || true)"
  if [ -n "$dirty" ]; then
    err_code task.sparse_requires_clean "bind 要把完整检出收成 sparse-checkout，工作区必须干净。"
    return 1
  fi
  git -C "$wt" sparse-checkout init --cone >/dev/null \
    || { err_code task.sparse_init_failed "git sparse-checkout init --cone 失败"; return 1; }
  git -C "$wt" sparse-checkout set "${sparse[@]}" >/dev/null \
    || { err_code task.sparse_set_failed "git sparse-checkout set 失败"; return 1; }
  task_is_sparse "$wt" \
    || { err_code task.not_sparse "bind 后工作树仍不是 sparse-checkout"; return 1; }
  c_ok "    ✓ 已将完整检出收成 sparse（可见 ${sparse[*]}；可写范围仍由契约约束）"
}

task_bind() {
  local n="$1" wt="$ROOT" main nwo owner repo json load_rc=0 scope bindf
  task_config_require
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || die_code task.issue_number_invalid "Issue 编号不合法：$n"
  [ "$(git -C "$wt" rev-parse --is-inside-work-tree 2>/dev/null || true)" = true ] \
    || die_code task.not_git_worktree "bind 必须在 git 工作树里运行"
  [ "$(git -C "$wt" rev-parse --is-bare-repository 2>/dev/null || true)" != true ] \
    || die_code task.bare_repo "bare 仓库不能 bind"
  task_is_main_worktree "$wt" \
    && die_code task.main_workspace "bind 必须在任务 worktree，不是主工作区"
  main="$(default_branch)"
  json="$(mktemp -t new-task-bind-contract.XXXXXX)"; TMPS="$TMPS $json"
  contract_load_main "$wt" "$n" "$json" "$main" || load_rc=$?
  if [ "$load_rc" != 0 ]; then
    return 1
  fi
  scope="$(contract_scope_from_json "$json")"
  [ -n "$scope" ] || die_code task.scope_unparsed "契约没有允许改动范围"
  nwo="$(task_repo_nwo "$wt" || true)"
  [ -n "$nwo" ] || die_code review.origin_unparsed "无法从 origin URL 解析 GitHub 仓库（不猜测）"
  owner="${nwo%/*}"
  repo="${nwo#*/}"
  task_bind_ensure_sparse "$wt" "$scope" || return 1
  bindf="$(task_bind_path "$wt")" \
    || die_code task.issue_unbound "无法解析本 worktree 的 git dir，拒绝 bind"
  printf '%s\n' "$n" > "$bindf"
  [ "$(task_bind_read "$wt")" = "$n" ] || die_code task.issue_unbound "bind 写入后回读失败"
  task_is_sparse "$wt" || die_code task.not_sparse "bind 回读：工作树不是 sparse-checkout"
  c_ok "    ✓ 已 bind ${owner}/${repo}#${n}（仅本 worktree git dir，未 push）"
  if [ "$(type -t guard_wire_worktree 2>/dev/null)" = function ]; then
    guard_wire_worktree "$wt" || return 1
  fi
  echo "    下一步：new task"
}

cmd_task() {
  case "${1:-}" in
    -h|--help) task_usage; return 0 ;;
  esac

  local mode="start" agent=""
  TASK_CLAIM_LAUNCH=1
  TASK_CLAIM_ACTOR=""
  TASK_CLAIM_ACTOR_EXPLICIT=0
  case "${1:-}" in
    approve)
      [ $# -eq 2 ] || die_code task.usage "用法：new task approve <issue 编号>（在主工作区、main 分支上运行）"
      metrics_begin new-task.approve
      task_approve "$2"
      return ;;
    bind)
      [ $# -eq 2 ] || die_code task.usage "用法：new task bind <issue 编号>（在任务 worktree 上运行）"
      metrics_begin new-task.bind
      task_bind "$2"
      return ;;
    claim)
      shift
      mode="claim"
      TASK_CLAIM_LAUNCH=0
      while [ $# -gt 0 ]; do
        case "$1" in
          --actor)
            [ $# -ge 2 ] && [ -n "${2:-}" ] && [ "${2#-}" = "$2" ] \
              || die_code task.usage "用法：new task claim [--actor <id>]"
            TASK_CLAIM_ACTOR="$2"
            TASK_CLAIM_ACTOR_EXPLICIT=1
            shift 2
            ;;
          --actor=*)
            TASK_CLAIM_ACTOR="${1#--actor=}"
            [ -n "$TASK_CLAIM_ACTOR" ] || die_code task.usage "用法：new task claim [--actor <id>]"
            TASK_CLAIM_ACTOR_EXPLICIT=1
            shift
            ;;
          *) die_code task.usage "用法：new task claim [--actor <id>]" ;;
        esac
      done
      if [[ "$TASK_CLAIM_ACTOR" =~ [[:space:]] ]]; then
        die_code task.usage "actor 只作 provenance，不能含空白"
      fi
      ;;
    review)
      [ $# -eq 1 ] || die_code task.usage "$(task_usage)"$'\n'"多余参数。"
      mode="review" ;;
    "")
      [ $# -eq 0 ] || die_code task.usage "$(task_usage)"$'\n'"多余参数。" ;;
    *)
      [ $# -eq 1 ] || die_code task.usage "$(task_usage)"$'\n'"多余参数。"
      agent="$1"
      task_agent_registered "$agent" \
        || die_code task.unknown_agent "未登记的 Agent：${agent}。已登记：codex、grok。通用领取请用 new task claim。交付请用 new task review。"
      TASK_CLAIM_LAUNCH=1
      # 兼容入口只选择产品 adapter；actor 仍走统一缺省链。
      TASK_CLAIM_ACTOR=""
      TASK_CLAIM_ACTOR_EXPLICIT=0
      ;;
  esac

  # 度量从这里计时；结束由 bin/new 的 EXIT trap 按退出码落盘（成功领取在 exec 前显式落盘）。
  if [ "$mode" = review ]; then
    metrics_begin new-task.review
  elif [ -n "$agent" ] || [ "$mode" = claim ]; then
    metrics_begin new-task.claim
    if [ -n "$agent" ]; then
      metrics_set agent "$agent"
    elif [ -n "$TASK_CLAIM_ACTOR" ]; then
      metrics_set agent "$TASK_CLAIM_ACTOR"
    fi
  else
    metrics_begin new-task.precheck
  fi

  command -v jq >/dev/null 2>&1 || die_code task.missing_jq "找不到 jq（new setup 会装）。"
  command -v git >/dev/null 2>&1 || die_code task.missing_git "找不到 git。"
  command -v gh >/dev/null 2>&1 || die_code task.missing_gh "找不到 gh，无法读取 Issue / Project（不猜测）。"
  task_config_require

  local fail=0 bind_hint=""
  local wt="" git_br="" logical_br="" br_src="" head="" ws_status=""
  local owner="" repo="" number="" issue_url="" issue_title=""
  local scope="" always="" sparse_txt="" project_status="" derived_status=""
  local issue_json="" item_json=""
  local evidence=""
  local contract_json="" contract_blob="" approve_hint=""
  local orca_json="" git_sparse="" nwo=""

  echo "── 1. Git 任务工作树 ──────────"
  wt="$(task_canon "$ROOT")"
  if [ "$(git -C "$wt" rev-parse --is-inside-work-tree 2>/dev/null || true)" != "true" ]; then
    err_code task.not_git_worktree "    ✗ $wt 不是 git 工作树"; return 1
  fi
  if [ "$(git -C "$wt" rev-parse --is-bare-repository 2>/dev/null || true)" = true ]; then
    err_code task.bare_repo "    ✗ 这是 bare 仓库，不能开工"; fail=1
  fi
  if task_is_main_worktree "$wt"; then
    err_code task.main_workspace "    ✗ 这是主工作区，不是任务工作树"; fail=1
  fi
  if [ ! -f "$wt/0-meta/policy.yaml" ] || [ ! -f "$wt/0-meta/derived.lock" ]; then
    err_code task.missing_policy "    ✗ 工作树里没有 0-meta/policy.yaml 与 derived.lock，不像 G-lite 工作区"; fail=1
  fi
  git_sparse="$(git -C "$wt" config --bool core.sparseCheckout 2>/dev/null || true)"
  if [ "$(git_mode)" != "monorepo" ]; then
    err_code task.git_mode "    ✗ git.mode 不是 monorepo"; fail=1
  fi
  if [ "$fail" = 0 ]; then
    c_ok "    ✓ $wt"
    evidence="${evidence}工作树 ${wt}（Git worktree、非主工作区）"$'\n'
  fi
  if [ "$fail" = 0 ] && [ "$(type -t guard_require_wired 2>/dev/null)" = function ]; then
    guard_require_wired "$wt" || fail=1
  fi

  echo "── 2. bind 的 GitHub Issue ──────────"
  number="$(task_bind_read "$wt")"
  nwo="$(task_repo_nwo "$wt" || true)"
  if [ -z "$number" ]; then
    err_code task.issue_unbound "    ✗ 未 bind Issue。不从目录名、分支名或 gh issue list 推断。"
    bind_hint="new task bind <n>"
    fail=1
  elif ! [[ "$number" =~ ^[1-9][0-9]*$ ]]; then
    err_code task.issue_number_invalid "    ✗ Issue 编号不可用：${number}（不猜测）"; fail=1
  elif [ -z "$nwo" ]; then
    err_code review.origin_unparsed "    ✗ 无法从 origin URL 解析 GitHub 仓库（不猜测）"; fail=1
  else
    owner="${nwo%/*}"; repo="${nwo#*/}"
    issue_json="$(mktemp -t new-task-issue.XXXXXX)"; TMPS="$TMPS $issue_json"
    if ! task_fetch_issue "$owner" "$repo" "$number" "$issue_json"; then
      err_code task.issue_fetch_failed "    ✗ gh 读取 ${owner}/${repo}#${number} 失败。绑定存在但取不到，拒绝继续（不猜测）。"
      fail=1
    elif [ "$(jq -r '.data.repository.issue.id // empty' "$issue_json")" = "" ]; then
      err_code task.issue_not_found "    ✗ ${owner}/${repo}#${number} 不存在或无权读取。拒绝猜测另一条 Issue。"
      fail=1
    else
      issue_url="$(jq -r '.data.repository.issue.url' "$issue_json")"
      issue_title="$(jq -r '.data.repository.issue.title' "$issue_json")"
      c_ok "    ✓ ${owner}/${repo}#${number}  ${issue_title}"
      echo "      $issue_url"
      evidence="${evidence}Issue ${owner}/${repo}#${number} ${issue_url}"$'\n'
      metrics_set issue "${owner}/${repo}#${number}"
      metrics_set labels "$(task_issue_labels "$issue_json")"
    fi
  fi
  echo "── 3. 分支与基线 ────────────────────────"
  local br_fail=0 regex="" disp="" flat="" is_archived
  if ! git_br="$(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null)"; then
    err_code task.detached_head "    ✗ 游离 HEAD，没有分支"; br_fail=1; git_br=""
  fi
  regex="$(policy_get git.branch.naming_regex)"
  if [ -z "$regex" ]; then
    err_code task.branch_regex_missing "    ✗ derived.lock 没有 git.branch.naming_regex"; br_fail=1
  fi
  # Orca flatten 只是 adapter：orca 可用时才读 displayName。核心路径不要求 orca。
  if command -v orca >/dev/null 2>&1; then
    orca_json="$(orca worktree current --json 2>/dev/null || true)"
    disp="$(printf '%s' "$orca_json" | jq -r '.result.worktree.displayName // empty' 2>/dev/null || true)"
  fi

  # grok/codex 开工前：只纠正「displayName 合法且 git 名恰好是 / → -」这一种
  # Orca 扁平化。inspect 不改名；review 不改名。不改 Orca 侧字段。
  if [ -n "$disp" ] && [ "$br_fail" = 0 ] && [ "$fail" = 0 ] \
     && { [ -n "$agent" ] || [ "$mode" = claim ]; } && [ "$mode" != review ] \
     && task_name_matches_re "$disp" "$regex"; then
    flat="$(task_orca_flatten_slash "$disp")"
    if [ "$git_br" = "$disp" ]; then
      :
    elif [ -n "$flat" ] && [ "$git_br" = "$flat" ]; then
      is_archived="$(printf '%s' "$orca_json" | jq -r '.result.worktree.isArchived')"
      if [ "$is_archived" = true ]; then
        err_code claim.rename_head_mismatch "    ✗ 工作树已归档，拒绝自动改名"
        br_fail=1
      elif task_rename_orca_flat_branch "$wt" "$git_br" "$disp"; then
        git_br="$(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null || true)"
        if [ "$git_br" != "$disp" ]; then
          err_code claim.rename_mismatch "    ✗ 重命名后回读不一致（git=${git_br:-空}，期望 ${disp}）"
          br_fail=1
        else
          c_ok "    ✓ 已将 Orca 扁平化分支恢复为 ${disp}"
        fi
      else
        br_fail=1
      fi
    else
      err_code task.branch_not_flat "    ✗ git 分支与 Orca displayName 不一致，且不是可证明的 / → - 扁平化"
      c_err "      git 分支        ${git_br}"
      c_err "      Orca displayName ${disp}"
      br_fail=1
    fi
  fi

  if [ "$br_fail" = 0 ] && [ -n "$git_br" ] && [ -n "$regex" ]; then
    if task_name_matches_re "$git_br" "$regex"; then
      logical_br="$git_br"; br_src="git 分支"
    elif [ "$mode" = start ] && [ -z "$agent" ] \
         && task_name_matches_re "$disp" "$regex" \
         && [ "$git_br" = "$(task_orca_flatten_slash "$disp")" ]; then
      # 只预检：不改名。grok/codex 开工时才会纠偏。
      logical_br="$disp"
      br_src="Orca displayName（git 为扁平化名，开工时纠偏）"
    else
      err_code task.branch_naming "    ✗ 分支不符合 domain 前缀规则 ${regex}"
      c_err "      git 分支        ${git_br}"
      [ -n "$disp" ] && c_err "      Orca displayName ${disp}"
      br_fail=1
    fi
  fi

  local main base_git
  main="$(default_branch)"
  if git -C "$wt" rev-parse --verify -q "origin/${main}" >/dev/null; then
    base_git="origin/${main}"
  elif git -C "$wt" rev-parse --verify -q "$main" >/dev/null; then
    base_git="$main"
  else
    err_code task.base_missing "    ✗ 找不到基线引用 ${main}"; br_fail=1; base_git=""
  fi
  if [ -n "$base_git" ] && ! git -C "$wt" merge-base HEAD "$base_git" >/dev/null 2>&1; then
    err_code task.no_common_ancestor "    ✗ HEAD 与 ${base_git} 没有共同祖先"; br_fail=1
  fi
  if [ "$br_fail" = 0 ] && [ -n "$logical_br" ]; then
    c_ok "    ✓ 逻辑分支 ${logical_br}（${br_src}）"
    echo "      git 分支  ${git_br}"
    echo "      基线      ${base_git}"
    evidence="${evidence}分支 ${logical_br}（git: ${git_br}，${br_src}）；基线 ${base_git}"$'\n'
  fi
  if [ "$mode" = review ] && [ -n "$git_br" ]; then
    if [ "$git_br" = "$main" ] || ! task_branch_pushable "$git_br" "$main"; then
      err_code review.branch_not_pushable "    ✗ 当前 git 分支是 ${git_br}，拒绝交付（不会向 ${main} push）"
      br_fail=1
    fi
  fi
  [ "$br_fail" = 0 ] || fail=1

  echo "── 4. 稀疏检出与任务范围 ────────────────"
  always="$(worktree_always_include)"
  sparse_txt="$(git -C "$wt" sparse-checkout list 2>/dev/null || true)"
  if [ "$git_sparse" = true ] && [ -z "$sparse_txt" ]; then
    err_code task.sparse_empty "    ✗ sparse-checkout 列表为空"; fail=1
  fi
  if [ "$git_sparse" != true ] && [ -n "$number" ]; then
    err_code task.not_sparse "    ✗ 任务工作树必须是 Git sparse-checkout（可见性边界）。请重新运行 new task bind ${number}。"
    fail=1
  fi

  # 范围只从 origin/main 上的契约文件读：先 fetch，失败不用本地陈旧副本；
  # 文件不存在 = 任务未批准，末行给出 approve 命令。Issue 正文只用来提示不一致。
  local body="" load_rc=0
  if [ -n "$issue_json" ] && [ -f "$issue_json" ]; then
    body="$(jq -r '.data.repository.issue.body // empty' "$issue_json")"
  fi
  if [ -z "$number" ]; then
    err_code task.issue_number_invalid "    ✗ 没有 Issue 编号，无法读取契约（不猜测）"; fail=1
  else
    contract_json="$(mktemp -t new-task-contract.XXXXXX)"; TMPS="$TMPS $contract_json"
    contract_load_main "$wt" "$number" "$contract_json" "$main" || load_rc=$?
  fi
  if [ -n "$number" ] && [ "$load_rc" != 0 ]; then
    [ "$load_rc" = 3 ] && approve_hint="new task approve ${number}"
    fail=1
  elif [ -n "$number" ]; then
    contract_blob="$CONTRACT_BLOB"
    scope="$(contract_scope_from_json "$contract_json")"
    metrics_set task_class "$(metrics_task_class_from_scope "$scope")"
    c_ok "    ✓ 契约 origin/${main}:$(contract_json_path "$number") blob ${contract_blob:0:12}"
    evidence="${evidence}Contract ${contract_blob}"$'\n'
    contract_warn_if_issue_differs "$body" "$contract_json" "$number"
    local d p covered extra=0 missing=0
    local sparse_dirs=()
    if [ "$git_sparse" = true ]; then
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      d="${d#/}"; d="${d%/}"
      case "$d" in
        '*'|'/*'|'**'|')*'|'*/*')
          err_code task.sparse_full_tree "    ✗ 稀疏模式 ${d} 等于完整检出，超出范围"
          extra=1 ;;
        *) sparse_dirs+=("$d") ;;
      esac
    done <<< "$sparse_txt"

    for a in $always; do
      covered=0
      for d in "${sparse_dirs[@]+"${sparse_dirs[@]}"}"; do
        task_is_under "$a" "$d" && covered=1 && break
      done
      if [ "$covered" != 1 ]; then
        err_code task.sparse_missing_always "    ✗ 缺少必带路径 ${a}"; missing=1
      fi
    done

    while IFS= read -r p; do
      [ -n "$p" ] || continue
      covered=0
      # 只有真实的仓库根层文件才由 cone 自动带上。
      # 顶层目录（如 1-code）即使不含 / 也必须出现在 sparse-checkout 里。
      if task_is_cone_root_file "$wt" "$p"; then
        covered=1
      else
        for d in "${sparse_dirs[@]+"${sparse_dirs[@]}"}"; do
          task_is_under "$p" "$d" && covered=1 && break
        done
      fi
      if [ "$covered" != 1 ]; then
        err_code task.sparse_missing_scope "    ✗ 稀疏检出未覆盖契约范围 ${p}（扩范围：改 Issue → new task approve → git sparse-checkout add ${p}）"; missing=1
      fi
    done <<< "$scope"

    # 公共可见目录（always_include）允许出现在 sparse 中，不视为越界。
    # 这不是写授权：可写范围只来自 Issue「允许改动范围」。
    for d in "${sparse_dirs[@]+"${sparse_dirs[@]}"}"; do
      local ok=0
      for a in $always; do
        task_is_under "$d" "$a" && ok=1 && break
      done
      if [ "$ok" != 1 ]; then
        while IFS= read -r p; do
          [ -n "$p" ] || continue
          task_is_under "$d" "$p" && ok=1 && break
        done <<< "$scope"
      fi
      if [ "$ok" != 1 ]; then
        err_code task.sparse_extra "    ✗ 稀疏检出超出范围：${d}"; extra=1
      fi
    done

    if [ "$missing" = 1 ] || [ "$extra" = 1 ]; then
      fail=1
    else
      c_ok "    ✓ 可见 ${sparse_dirs[*]}（公共 ${always} 不计越界）；可写范围 $(task_scope_oneline "$scope")"
      evidence="${evidence}稀疏 ${sparse_dirs[*]}；范围 $(task_scope_oneline "$scope")"$'\n'
    fi
    else
      c_ok "    ✓ 可写范围 $(task_scope_oneline "$scope")"
      evidence="${evidence}范围 $(task_scope_oneline "$scope")"$'\n'
    fi
  fi

  echo "── 5. 工作树状态 ────────────────────────"
  head="$(git -C "$wt" rev-parse HEAD 2>/dev/null || true)"
  if [ -z "$head" ]; then
    err_code task.head_unreadable "    ✗ 读不到 HEAD"; fail=1
  fi
  local busy="" dirty_status_ok=1 n_dirty=0
  if busy="$(task_git_busy "$wt")"; then
    if [ "$mode" = review ]; then
      err_code review.git_busy "    ✗ 不能交付：${busy}"
    else
      err_code task.git_busy "    ✗ 不能开工：${busy}"
    fi
    fail=1
  fi
  if ! task_worktree_status_counts "$wt"; then
    dirty_status_ok=0
    if [ "$mode" = review ]; then
      err_code review.status_unreadable "    ✗ 无法读取工作树状态，拒绝交付（不猜测为 clean）"
    else
      err_code task.status_unreadable "    ✗ 无法读取工作树状态，拒绝开工"
    fi
    fail=1
  else
    n_dirty="$TASK_WORKTREE_DIRTY"
    if [ "$mode" = review ]; then
      if [ "$n_dirty" -ne 0 ]; then
        ws_status="待交接门禁（untracked=${TASK_WORKTREE_UNTRACKED}；unstaged=${TASK_WORKTREE_UNSTAGED}；staged=${TASK_WORKTREE_STAGED}）"
        c_warn "    ⚠ ${ws_status}；等待 committed + clean HEAD 门禁"
        printf '%s\n' "$TASK_WORKTREE_STATUS" | head -8 | sed 's/^/      /'
        [ "$n_dirty" -gt 8 ] && echo "      …"
      else
        ws_status="待交接门禁（当前表面 clean）"
        c_ok "    ✓ 当前表面 clean；继续核验 committed + clean HEAD"
      fi
    elif [ "$n_dirty" -ne 0 ]; then
      ws_status="有未提交改动 ${n_dirty} 处（允许开工，Checkpoint 会记下）"
      c_ok "    ✓ ${ws_status}"
      printf '%s\n' "$TASK_WORKTREE_STATUS" | head -8 | sed 's/^/      /'
      [ "$n_dirty" -gt 8 ] && echo "      …"
    else
      ws_status="干净"
      c_ok "    ✓ 干净，无进行中的 git 操作"
    fi
  fi
  evidence="${evidence}HEAD ${head}；工作区 ${ws_status}"$'\n'

  if [ "$mode" = review ] && [ -n "$main" ] && [ -n "$head" ]; then
    if ! git -C "$wt" fetch --quiet origin "refs/heads/${main}:refs/remotes/origin/${main}"; then
      err_code review.fetch_main_failed "    ✗ 无法 fetch origin/${main}，拒绝交付（不猜测基线是否过期）"
      fail=1
    else
      base_git="origin/${main}"
      if [ "$dirty_status_ok" != 1 ]; then
        fail=1
      elif task_completion_gate "$wt" "$base_git" changed; then
        ws_status="committed + clean HEAD"
        c_ok "    ✓ 已通过 committed + clean HEAD 交接门禁（HEAD=${TASK_COMPLETION_HEAD}；${TASK_COMPLETION_AHEAD} 个待审提交）"
        evidence="${evidence}completion=changed HEAD=${TASK_COMPLETION_HEAD}；untracked=0；unstaged=0；staged=0；${TASK_COMPLETION_AHEAD} 个待审提交（${base_git}..HEAD）"$'\n'
      else
        ws_status="未完成 / BLOCKED"
        fail=1
      fi
    fi
  fi

  echo
  if [ -n "$issue_json" ] && [ -f "$issue_json" ]; then
    item_json="$(task_project_item "$issue_json" || true)"
    if [ -z "$item_json" ]; then
      project_status=""
      echo "  Project #${TASK_PROJECT_NUMBER} ${TASK_PROJECT_TITLE}：未找到该 Issue 的条目"
    else
      project_status="$(printf '%s' "$item_json" | jq -r '.fieldValueByName.name // empty')"
      echo "  Project #${TASK_PROJECT_NUMBER} ${TASK_PROJECT_TITLE}：Status=${project_status:-（空）}"
    fi
  fi

  if [ -n "$number" ] && [ -n "$wt" ] && [ -n "$owner" ] && [ -n "$repo" ] && [ -n "$main" ]; then
    Z_WT="$wt" Z_MAIN="$main" Z_OWNER="$owner" Z_REPO="$repo"
    if ! derived_status="$(derive_task_state "$number")"; then
      fail=1
      derived_status=""
    elif [ -n "$derived_status" ]; then
      echo "  推导状态：${derived_status}"
      z_warn_if_status_drift "$derived_status" "$project_status"
    fi
  fi

  if [ "$mode" = review ] && [ "$fail" = 0 ]; then
    if [ "$derived_status" = "$TASK_STATUS_PROGRESS" ]; then
      if [ -z "$item_json" ]; then
        c_warn "    ⚠ Issue 不在 ${TASK_PROJECT_TITLE} 上；推导放行则继续，Status 不写回"
      fi
    elif [ "$derived_status" = "$TASK_STATUS_REVIEW" ]; then
      local exist_pr exist_js exist_num
      if ! exist_pr="$(task_find_matching_pr "$owner" "$repo" "$git_br" "$main")"; then
        err_code review.ambiguous_pr "    ✗ In review 下存在多个候选 PR，拒绝猜测，不新建第二个 PR。"
        fail=1
      elif [ -z "$exist_pr" ]; then
        err_code review.no_matching_pr "    ✗ In review 下不存在匹配的未关闭 PR，不新建第二个 PR。"
        fail=1
      else
        exist_num="$(printf '%s' "$exist_pr" | jq -r '.number // empty')"
        if ! exist_js="$(task_pr_view_json "$owner" "$repo" "$exist_num")"; then
          err_code review.pr_unreadable "    ✗ 无法读取已有 PR #${exist_num}，不新建第二个 PR。"
          fail=1
        elif ! task_pr_fields_ok "$exist_js" "$git_br" "$main" "$number" ""; then
          err_code review.pr_not_owned "    ✗ 已有 PR #${exist_num} 不能证明属于当前任务（head/base/Draft/Fixes）。不新建第二个 PR。"
          fail=1
        else
          c_ok "    ✓ In review 重交付：复用唯一 PR #${exist_num}，不新建"
        fi
      fi
    else
      err_code review.wrong_status "    ✗ 推导状态不是 ${TASK_STATUS_PROGRESS} 或 ${TASK_STATUS_REVIEW}（当前：${derived_status:-空}）。不 push、不创建 PR。"
      fail=1
    fi
  fi

  if [ "$fail" != 0 ]; then
    if [ "$mode" = review ]; then
      c_err "预检失败，不 push、不创建 PR、不更新 Project 状态。"
    else
      c_err "预检失败，拒绝领取与启动 Agent。"
    fi
    [ -n "$approve_hint" ] && printf '%s\n' "$approve_hint" >&2
    [ -n "$bind_hint" ] && printf '%s\n' "$bind_hint" >&2
    return 1
  fi

  if [ "$mode" = review ]; then
    if task_review_deliver; then
      return 0
    fi
    return 1
  fi

  if [ -z "$agent" ] && [ "$mode" != claim ]; then
    c_ok "✓ 预检通过。未领取、未改 GitHub、未启动 Agent。"
    echo "  领取：new task claim [--actor <id>]（不启动 Agent）。兼容：new task grok|codex（同一领取后再启动）。然后 new z dev。"
    return 0
  fi

  local agent_bin=""
  if [ -n "$agent" ]; then
    agent_bin="$(command -v "$agent" || true)"
    if [ -z "$agent_bin" ]; then
      err_code claim.agent_not_in_path "已登记 Agent ${agent} 不在 PATH 里，拒绝启动（GitHub 未改）。"
      return 1
    fi
  fi

  echo "── GitHub Status / 领取 ─────────────────"
  task_claim_or_resume
}

# Contract v1 与 task 入口同目录加载，避免改 0-meta/bin/new（超出本任务范围）。
if [ "$(type -t contract_parse_body 2>/dev/null)" != function ]; then
  # shellcheck source=/dev/null
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/contract.sh"
fi
if [ "$(type -t task_claim_or_resume 2>/dev/null)" != function ]; then
  # shellcheck source=/dev/null
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/claim.sh"
fi
# 度量同理：cmd_task 依赖 metrics_*，谁 source 了 task.sh 就一并有。
if [ "$(type -t metrics_begin 2>/dev/null)" != function ]; then
  # shellcheck source=/dev/null
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/metrics.sh"
fi
if [ "$(type -t guard_wire_worktree 2>/dev/null)" != function ]; then
  # shellcheck source=/dev/null
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/guard.sh"
fi
