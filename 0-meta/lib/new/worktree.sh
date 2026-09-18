# worktree 的创建、列出、清理。porcelain 枚举只有这一份。
# 由 0-meta/bin/new 加载，不要单独执行。

# ─────────────────────────────────────────────── worktree
#
# 三个机制职责分开，不要混：
#   branch           版本 / 任务隔离
#   worktree         多个 branch 同时存在于多个物理目录
#   sparse-checkout  一个 worktree 实际暴露哪些文件
#
# 只用 worktree 不用 sparse，AI 会在一个 25 万文件的目录里干一件只涉及
# 20 个文件的事——90% 的内容对它是噪音，还会被索引进上下文。

# 按第一个路径所属的域推断分支前缀。branch 跟工作单元走，前缀只是让 git log 好读。
# 路径 → 分支前缀。前缀就是 scope domain，映射读自 derived.lock 的
# git.commit.scope_src.*，不在这里写死。
#
# v2.4 之前这里是一张硬编码表，而且 1-code 映射到 feat —— 拿一个动作词
# 回答一个位置问题。同一张「目录 ↔ domain」表现在有三个消费者
# （本函数、commit-msg 钩子、daily 回扫），写死就是三份各自漂移的清单。
infer_prefix() {
  local path="${1%/}" best="" bestlen=0 d src
  local domains; domains="$(policy_get git.commit.scope_domains)"
  [ -n "$domains" ] || die "derived.lock 里没有 git.commit.scope_domains —— 先跑 new plan --apply"
  for d in $domains; do
    src="$(policy_get "git.commit.scope_src.$d")"
    [ -n "$src" ] && [ "$src" != "." ] || continue
    case "$path" in
      "$src"|"$src"/*)
        # 最长匹配优先，否则 4-know/research 会被 4-know 抢走
        if [ "${#src}" -gt "$bestlen" ]; then best="$d"; bestlen="${#src}"; fi ;;
    esac
  done
  echo "${best:-repo}"
}

# 分支是否已经进入 main。必须同时处理两种合入方式：
#   普通 merge / fast-forward  → branch 是 main 的祖先
#   squash merge               → 提交不同但内容相同，祖先判定会漏
# 后者是本工作区的默认策略，只查 --merged 会把已合入的分支判成未合入，
# 然后拒绝清理——一个总是误报的守卫，最后一定会被 --force 绕过。
branch_merged() {
  local br="$1" main="$2"
  git -C "$ROOT" merge-base --is-ancestor "$br" "$main" 2>/dev/null && return 0
  git -C "$ROOT" rev-parse --verify -q "$main" >/dev/null 2>&1 || return 1
  git -C "$ROOT" diff --quiet "$main" "$br" 2>/dev/null && return 0
  return 1
}

# 每个任务工作树固定可见的公共目录。只进 sparse-checkout，不是默认可写范围。
worktree_always_include() {
  local always
  always="$(policy_get git.worktree.always_include)"
  [ -n "$always" ] || always="0-meta .agents"
  printf '%s\n' "$always"
}

# 非主工作区的 worktree 绝对路径，每行一个。
# 列出与卫生检查共用这一份 porcelain 解析，避免两处各写一遍迟早分叉。
wt_paths() {
  in_repo || return 0
  local top p
  top="$(repo_top)"
  while IFS= read -r line; do
    case "$line" in worktree\ *) ;; *) continue ;; esac
    p="${line#worktree }"
    [ "$p" = "$top" ] && continue
    printf '%s\n' "$p"
  done < <(git -C "$ROOT" worktree list --porcelain 2>/dev/null)
}

wt_list() {
  in_repo || die "还不是 git 仓库：$ROOT"
  local main; main="$(default_branch)"
  local wtroot; wtroot="$(worktree_root)"
  printf '%-28s %-32s %-8s %s\n' 工作目录 分支 未提交 已合入main
  echo "────────────────────────────────────────────────────────────────────────────"
  local any=0 p br dirty merged
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    any=1
    br="$(git -C "$p" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
    dirty="$(git -C "$p" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
    if branch_merged "$br" "$main"; then merged="是"; else merged="否"; fi
    printf '%-28s %-32s %-8s %s\n' "$(basename "$p")" "$br" "$dirty" "$merged"
  done < <(wt_paths)
  [ "$any" = 1 ] || echo "（暂无 worktree，根位置：${wtroot}）"
}

cmd_worktree() {
  if [ "${1:-}" = "--list" ] || [ "${1:-}" = "-l" ]; then wt_list; return 0; fi

  local name="" branch="" base="" paths=()
  name="${1:-}"; shift || true
  [ -n "$name" ] || die "用法：new worktree <name> --path <p> [--path <p>…]"
  slug_ok "$name" || die "worktree 名必须匹配 ^[a-z0-9][a-z0-9._-]*$"

  while [ $# -gt 0 ]; do
    case "$1" in
      --path)   [ -n "${2:-}" ] || die "--path 后面要跟路径"; paths+=("${2%/}"); shift 2 ;;
      --branch) [ -n "${2:-}" ] || die "--branch 后面要跟分支名"; branch="$2"; shift 2 ;;
      --from)   [ -n "${2:-}" ] || die "--from 后面要跟基点"; base="$2"; shift 2 ;;
      *) die "未知参数：$1" ;;
    esac
  done
  [ "${#paths[@]}" -gt 0 ] || die "至少要给一个 --path。一个任务可以跨域，多写几个 --path 就行。"

  [ "$(git_mode)" = "monorepo" ] || die "git.mode 不是 monorepo，worktree 流程不适用"
  in_repo || die "根仓库还没初始化。先跑：cd ${ROOT} && git init -b $(default_branch) && git add -A && git commit -m 'chore: init workspace'"
  git -C "$ROOT" rev-parse HEAD >/dev/null 2>&1 \
    || die "仓库还没有任何提交，无法开 worktree。先在根目录做第一个 commit。"

  local main; main="$(default_branch)"
  [ -n "$base" ] || base="$main"
  git -C "$ROOT" rev-parse --verify -q "$base" >/dev/null 2>&1 || die "基点不存在：$base"

  [ -n "$branch" ] || branch="$(infer_prefix "${paths[0]}")/$name"

  # 路径必须在基点里真实存在。sparse-checkout 对不存在的路径静默通过，
  # 打错一个字得到的是一个空工作区，而错误要等 AI 干了半天才暴露。
  # 公共可见目录同样要存在，否则 cone 会静默给出空的 0-meta。
  local always; always="$(worktree_always_include)"
  local missing=()
  for p in "${paths[@]}"; do
    git -C "$ROOT" cat-file -e "$base:$p" 2>/dev/null || missing+=("$p")
  done
  for p in $always; do
    git -C "$ROOT" cat-file -e "$base:$p" 2>/dev/null || missing+=("$p")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    c_err "以下路径在 $base 里不存在："
    printf '    %s\n' "${missing[@]}" >&2
    die "新目录要先在主工作区建好并提交，再开 worktree。"
  fi

  local wtroot dest
  wtroot="$(worktree_root)"
  dest="$wtroot/$name"
  [ -e "$dest" ] && die "已存在：$dest"
  mkdir -p "$wtroot"

  # 公共可见目录无条件带上（治理层）。只保证能读到，不构成写授权。

  local sparse=()
  for a in $always; do sparse+=("$a"); done
  for p in "${paths[@]}"; do
    case " ${sparse[*]} " in *" $p "*) ;; *) sparse+=("$p") ;; esac
  done

  if git -C "$ROOT" rev-parse --verify -q "$branch" >/dev/null 2>&1; then
    c_warn "分支已存在，直接挂上：$branch"
    git -C "$ROOT" worktree add --no-checkout "$dest" "$branch" >/dev/null
  else
    git -C "$ROOT" worktree add --no-checkout -b "$branch" "$dest" "$base" >/dev/null
  fi

  git -C "$dest" sparse-checkout init --cone >/dev/null
  git -C "$dest" sparse-checkout set "${sparse[@]}" >/dev/null
  git -C "$dest" checkout -q

  echo
  c_ok "✓ worktree 已就绪"
  echo "    目录    $dest"
  echo "    分支    ${branch}（基于 ${base}）"
  echo "    可见    ${sparse[*]}"
  echo "            其中 ${always} 是公共可见，不因此可写"
  echo "            外加仓库根层文件：AGENTS.md README.md .gitignore .aiignore 等"
  echo
  echo "  打开："
  echo "    cursor \"$dest\"        # 或 codex / claude，各开各的，互不干扰"
  echo
  echo "  完事："
  echo "    cd \"$dest\" && new check --tier commit"
  echo "    git push -u origin HEAD && gh pr create --base main"
  echo "    # GitHub squash merge 之后："
  echo "    new worktree-clean $name"
  echo

  if ! git -C "$ROOT" ls-files --error-unmatch .cursorignore >/dev/null 2>&1; then
    c_warn "⚠ .cursorignore 未被 git 跟踪，所以它不会出现在这个 worktree 里。"
    echo "    也就是说这个 worktree 里 Cursor 的访问边界是失效的。"
    echo "    在主工作区补上：cp 0-meta/templates/cursorignore.tpl .cursorignore && git add .cursorignore"
    echo "    （不需要 -f。文件名以点开头不会让 git 忽略它；先跑 git check-ignore -v 再决定。）"
  fi

  if [ "$(policy_get git.worktree.external_backup)" = "true" ]; then
    c_warn "⚠ worktree 在备份根之外。未提交的改动只有本机一份——记得及时 commit。"
  fi
}

cmd_worktree_clean() {
  local name="" force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --force|-f) force=1; shift ;;
      *) [ -z "$name" ] || die "只能指定一个 worktree"; name="$1"; shift ;;
    esac
  done
  [ -n "$name" ] || die "用法：new worktree-clean <name> [--force]"
  in_repo || die "还不是 git 仓库：$ROOT"

  local dest; dest="$(worktree_root)/$name"
  [ -d "$dest" ] || die "找不到 worktree：$dest"
  [ "$(cd "$dest" && pwd)" != "$(repo_top)" ] || die "这是主工作区，不能删。"

  local br main
  br="$(git -C "$dest" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
  main="$(default_branch)"
  echo "  worktree  $dest"
  echo "  分支      $br"
  echo

  local blocked=0

  echo "── 1. 未提交的改动 ──────────────────────"
  local dirty; dirty="$(git -C "$dest" status --porcelain 2>/dev/null || true)"
  if [ -n "$dirty" ]; then
    c_err "    ✗ 有 $(echo "$dirty" | wc -l | tr -d ' ') 处未提交改动（含未跟踪文件）"
    echo "$dirty" | head -10 | sed 's/^/      /'
    [ "$(echo "$dirty" | wc -l | tr -d ' ')" -gt 10 ] && echo "      …"
    blocked=1
  else
    c_ok "    ✓ 干净"
  fi

  echo "── 2. 是否已合入 ${main} ──────────────────"
  local merged=0
  if [ -z "$br" ] || [ "$br" = "HEAD" ]; then
    c_warn "    ⚠ 处于游离 HEAD，无法判定"
  elif branch_merged "$br" "$main"; then
    c_ok "    ✓ 已合入（普通 merge 或 squash 后内容一致）"
    merged=1
  else
    local ahead; ahead="$(git -C "$ROOT" rev-list --count "$main..$br" 2>/dev/null || echo '?')"
    c_err "    ✗ 未合入，领先 ${main} ${ahead} 个提交"
    blocked=1
  fi

  echo "── 3. 是否另有副本 ──────────────────────"
  if [ "$merged" = 1 ]; then
    c_ok "    ✓ 内容已在 ${main} 里，删掉分支不会丢东西"
  elif git -C "$ROOT" rev-parse --verify -q "$br@{u}" >/dev/null 2>&1; then
    local unpushed; unpushed="$(git -C "$ROOT" rev-list --count "$br@{u}..$br" 2>/dev/null || echo '?')"
    if [ "$unpushed" = 0 ]; then
      c_warn "    ⚠ 已推送到远端，但仍未合入 ${main}"
    else
      c_err "    ✗ 有 ${unpushed} 个提交既未合入也未推送 —— 这些提交只存在于本机"
      blocked=1
    fi
  else
    c_err "    ✗ 分支没有远端，也没合入 ${main} —— 删了就没了"
    blocked=1
  fi

  echo
  if [ "$blocked" = 1 ]; then
    if [ "$force" = 1 ]; then
      c_warn "⚠ --force：明知有未保全的工作，仍然删除。"
    else
      c_err "拒绝删除。先处理上面的红项，或者确认要丢弃后加 --force。"
      return 1
    fi
  fi

  git -C "$ROOT" worktree remove ${force:+--force} "$dest"
  git -C "$ROOT" worktree prune
  if [ -n "$br" ] && [ "$br" != "HEAD" ] && [ "$br" != "$main" ]; then
    if [ "$merged" = 1 ]; then
      git -C "$ROOT" branch -d "$br" >/dev/null 2>&1 || git -C "$ROOT" branch -D "$br" >/dev/null
      echo "  已删分支 $br"
    elif [ "$force" = 1 ]; then
      git -C "$ROOT" branch -D "$br" >/dev/null
      c_warn "  已强删未合入分支 $br"
    else
      c_warn "  保留分支 ${br}（未合入，只移除了工作目录）"
    fi
  fi
  c_ok "✓ 已清理 $name"
}
