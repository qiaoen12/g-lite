# Task-aware bootstrap：从 origin/main Contract 派生 exact sparse、
# worktree、合法 task branch 与 bind。不 claim、不 launch。
# 由 task.sh 加载，不要单独执行。

TASK_BOOTSTRAP_NEXT_DEV='continue development'
TASK_BOOTSTRAP_NEXT_REVIEW='new z review <review-input>'
TASK_BOOTSTRAP_NEXT_CLAIM='new z dev'
TASK_BOOTSTRAP_NEXT_FIX='new z fix'
TASK_BOOTSTRAP_NEXT_PASS_HUMAN='new z pr'
TASK_BOOTSTRAP_NEXT_PASS_AUTO='new z merge'

# 框架必须可读、但不因此可写的根文件。cone 会带上根层文件；若 skip-worktree
# 仍挡住，bootstrap / bind 负责 materialize，不要求用户手工 checkout。
task_framework_root_files() {
  printf '%s\n' AGENTS.md
}

task_framework_readable_path() {
  local p="$1" a
  p="$(task_norm_scope_path "$p")"
  [ -n "$p" ] || return 1
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    [ "$p" = "$a" ] && return 0
  done < <(task_framework_root_files)
  for a in $(worktree_always_include); do
    [ -n "$a" ] || continue
    task_is_under "$p" "$a" && return 0
  done
  return 1
}

task_rev_path_type() {
  local wt="$1" rev="$2" p="$3"
  git -C "$wt" cat-file -t "$rev:$p" 2>/dev/null || true
}

task_rev_path_exists() {
  local wt="$1" rev="$2" p="$3"
  git -C "$wt" cat-file -e "$rev:$p" 2>/dev/null
}

# 用 git 对象判断覆盖关系，不依赖工作区是否已 checkout。
# 获准但基点尚不存在的目录按目录对待，覆盖其子路径。
task_sparse_entry_covers() {
  local wt="$1" rev="$2" child="$3" parent="$4" kind
  child="$(task_norm_scope_path "$child")"
  parent="$(task_norm_scope_path "$parent")"
  [ -n "$child" ] && [ -n "$parent" ] || return 1
  [ "$child" = "$parent" ] && return 0
  task_is_under "$child" "$parent" || return 1
  kind="$(task_rev_path_type "$wt" "$rev" "$parent")"
  case "$kind" in
    tree|'') return 0 ;;
    *) return 1 ;;
  esac
}

# stdout：exact sparse set 路径，每行一个。根层文件不进 set 列表。
task_sparse_expected_paths() {
  local wt="$1" scope="$2" rev="${3:-HEAD}"
  local always p q covered seen=" "
  always="$(worktree_always_include)"
  [ -n "$always" ] || {
    err_code task.sparse_set_failed "always_include 为空"
    return 1
  }
  for p in $always; do
    p="$(task_norm_scope_path "$p")"
    [ -n "$p" ] || continue
    task_rev_path_exists "$wt" "$rev" "$p" || {
      err_code task.sparse_missing_always "公共可见路径在基点不存在：$p"
      return 1
    }
    case "$seen" in *" $p "*) continue ;; esac
    seen="${seen}${p} "
    printf '%s\n' "$p"
  done
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    p="$(task_norm_scope_path "$p")"
    [ -n "$p" ] || continue
    task_is_cone_root_file "$wt" "$p" && continue
    covered=0
    for q in $always; do
      q="$(task_norm_scope_path "$q")"
      if [ "$q" != "$p" ] && task_sparse_entry_covers "$wt" "$rev" "$p" "$q"; then
        covered=1
        break
      fi
    done
    [ "$covered" = 1 ] && continue
    while IFS= read -r q; do
      [ -n "$q" ] || continue
      q="$(task_norm_scope_path "$q")"
      if [ "$q" != "$p" ] && task_sparse_entry_covers "$wt" "$rev" "$p" "$q"; then
        covered=1
        break
      fi
    done <<< "$scope"
    [ "$covered" = 1 ] && continue
    case "$seen" in *" $p "*) continue ;; esac
    seen="${seen}${p} "
    printf '%s\n' "$p"
  done <<< "$scope"
}

task_sparse_normalize_list() {
  printf '%s\n' "$1" | awk '
    {
      gsub(/\r/, "")
      sub(/^\//, "")
      sub(/\/$/, "")
      if ($0 != "") print
    }
  ' | LC_ALL=C sort -u
}

task_sparse_current_paths() {
  local wt="$1" raw
  raw="$(git -C "$wt" sparse-checkout list 2>/dev/null || true)"
  task_sparse_normalize_list "$raw"
}

# current 去掉框架根文件后，是否与 expected 同一集合。
task_sparse_is_exact() {
  local expected="$1" current="$2" p filtered=""
  expected="$(task_sparse_normalize_list "$expected")"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    task_framework_readable_path "$p" && case "$p" in
      AGENTS.md) continue ;;
    esac
    filtered="${filtered}${p}"$'\n'
  done <<< "$(task_sparse_normalize_list "$current")"
  [ "$(task_sparse_normalize_list "$filtered")" = "$expected" ]
}

task_has_unique_commits() {
  local wt="$1" base="$2" ahead
  [ -n "$wt" ] && [ -n "$base" ] || return 0
  if ! ahead="$(git -C "$wt" rev-list --count "${base}..HEAD" 2>/dev/null)" \
     || ! [[ "$ahead" =~ ^[0-9]+$ ]]; then
    return 0
  fi
  [ "$ahead" != 0 ]
}

# 改 sparse 之前：busy / dirty / unique commits 任一成立即 BLOCK。
# 不 stash、不 reset、不 clean。
task_sparse_rewrite_blocked() {
  local wt="$1" base="$2" busy dirty
  if busy="$(task_git_busy "$wt")"; then
    err_code task.git_busy "不能改 sparse：${busy}"
    return 0
  fi
  dirty="$(git -C "$wt" -c core.quotePath=false status --porcelain 2>/dev/null || true)"
  if [ -n "$dirty" ]; then
    err_code task.sparse_requires_clean "改 sparse 会隐藏已有进度，工作区必须干净。"
    return 0
  fi
  if task_has_unique_commits "$wt" "$base"; then
    err_code task.sparse_hides_unique \
      "改 sparse 可能隐藏独有提交（HEAD 相对 ${base} 已前进）。拒绝覆盖。"
    return 0
  fi
  return 1
}

task_sparse_apply_exact() {
  local wt="$1" scope="$2" rev="${3:-HEAD}"
  local sparse=() p need_skip=0 kind
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    sparse+=("$p")
    kind="$(task_rev_path_type "$wt" "$rev" "$p")"
    # cone 只接受 tree。blob / 非 tree / 基点缺失都必须 --skip-checks。
    case "$kind" in
      tree) ;;
      *) need_skip=1 ;;
    esac
  done < <(task_sparse_expected_paths "$wt" "$scope" "$rev")
  [ "${#sparse[@]}" -gt 0 ] || {
    err_code task.sparse_set_failed "sparse 路径为空（always_include + 契约范围）"
    return 1
  }
  git -C "$wt" sparse-checkout init --cone >/dev/null \
    || { err_code task.sparse_init_failed "git sparse-checkout init --cone 失败"; return 1; }
  # Contract exact sparse：非 tree 条目才带 --skip-checks。
  # 通用 new worktree --path 不得走这条路，仍要求手工路径在基点存在。
  if [ "$need_skip" = 1 ]; then
    git -C "$wt" sparse-checkout set --skip-checks "${sparse[@]}" >/dev/null \
      || { err_code task.sparse_set_failed "git sparse-checkout set --skip-checks 失败"; return 1; }
  else
    git -C "$wt" sparse-checkout set "${sparse[@]}" >/dev/null \
      || { err_code task.sparse_set_failed "git sparse-checkout set 失败"; return 1; }
  fi
  task_is_sparse "$wt" \
    || { err_code task.not_sparse "写入后工作树仍不是 sparse-checkout"; return 1; }
  c_ok "    ✓ exact sparse（可见 ${sparse[*]}；可写范围仍由契约约束）"
}

# 根 AGENTS.md：框架可读。已跟踪但被 skip-worktree 挡住时在内部 materialize。
# 不把该文件加入 writable scope。
task_framework_materialize() {
  local wt="$1" f bits
  for f in $(task_framework_root_files); do
    git -C "$wt" cat-file -e "HEAD:$f" 2>/dev/null || continue
    bits="$(git -C "$wt" ls-files -v -- "$f" 2>/dev/null | awk '{print substr($1,1,1); exit}')"
    if [ ! -f "$wt/$f" ] || [ "$bits" = S ] || [ "$bits" = s ]; then
      git -C "$wt" update-index --no-skip-worktree -- "$f" >/dev/null 2>&1 || true
      git -C "$wt" checkout -q --ignore-skip-worktree-bits -- "$f" >/dev/null 2>&1 \
        || git -C "$wt" checkout -q -- "$f" >/dev/null 2>&1 \
        || {
          err_code task.framework_materialize_failed \
            "无法让框架输入 ${f} 可见（不要求用户手工 checkout）"
          return 1
        }
    fi
    [ -f "$wt/$f" ] || {
      err_code task.framework_materialize_failed "框架输入 ${f} 仍不可读"
      return 1
    }
  done
  return 0
}

# 完整检出或过宽 sparse：仅在可安全收窄时写成 exact sparse。
# 已是 exact 则只保证框架输入可见。已是 sparse 不再「直接 return」。
task_bind_ensure_sparse() {
  local wt="$1" scope="$2" rev="HEAD" expected current base main
  main="$(default_branch)"
  if git -C "$wt" rev-parse --verify -q "origin/${main}" >/dev/null; then
    base="origin/${main}"
  else
    base="$rev"
  fi
  expected="$(task_sparse_expected_paths "$wt" "$scope" "$rev")" || return 1
  [ -n "$expected" ] || {
    err_code task.sparse_set_failed "sparse 路径为空（always_include + 契约范围）"
    return 1
  }
  if task_is_sparse "$wt"; then
    current="$(task_sparse_current_paths "$wt")"
    if task_sparse_is_exact "$expected" "$current"; then
      task_framework_materialize "$wt" || return 1
      return 0
    fi
    if task_sparse_rewrite_blocked "$wt" "$base"; then
      return 1
    fi
  else
    if task_sparse_rewrite_blocked "$wt" "$base"; then
      return 1
    fi
  fi
  task_sparse_apply_exact "$wt" "$scope" "$rev" || return 1
  task_framework_materialize "$wt" || return 1
}

# 未加载阶段事实时：只有 changed completion 成立才把 Review 当下一步。
# 已加载时由当前 Checkpoint / Review applicability 派生 fix / review / merge。
# ahead=0 的干净树是尚未开发，不是已声明的 no-change。
task_next_canonical_command() {
  local wt="$1" base="$2"
  if [ "${TASK_FACTS_READY:-0}" = 1 ] && [ "$(type -t task_facts_derive_next)" = function ]; then
    task_facts_derive_next "$wt" "$base"
    return 0
  fi
  if [ -n "$wt" ] && [ -n "$base" ] \
     && task_completion_gate "$wt" "$base" changed >/dev/null 2>&1; then
    printf '%s\n' "$TASK_BOOTSTRAP_NEXT_REVIEW"
    return 0
  fi
  printf '%s\n' "$TASK_BOOTSTRAP_NEXT_DEV"
}

task_developer_handoff_text() {
  cat <<'EOF'
开工门禁 / launcher / start card 成功只表示领取成立且 Developer execution 已交接，不表示开发完成、验证完成或 review-ready。
请读取 origin/main Contract，只在允许范围内实现 R/A，验证并提交。
只有 committed + clean HEAD 完成态门禁通过后（changed：HEAD 相对合法基线前进；或明确 no-change 且干净），下一步才是 Review。
Agent 退出码 0 不是 completion。启动失败或交接不确定时，不得报告完成，也不得启动第二个 Developer。
EOF
}

task_bootstrap_name() {
  printf 'task-%s\n' "$1"
}

task_bootstrap_branch() {
  local scope="$1" n="$2" first prefix
  first="$(printf '%s\n' "$scope" | awk 'NF{print; exit}')"
  [ -n "$first" ] || return 1
  prefix="$(infer_prefix "$first")"
  [ -n "$prefix" ] || prefix=repo
  printf '%s/task-%s\n' "$prefix" "$n"
}

task_phys() {
  (cd "$1" && pwd -P) 2>/dev/null || printf '%s' "$1"
}

task_bootstrap_other_bind() {
  local dest="$1" n="$2" p bound dest_c p_c
  dest_c="$(task_phys "$dest")"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    p_c="$(task_phys "$p")"
    [ "$p_c" = "$dest_c" ] && continue
    bound="$(task_bind_read "$p" || true)"
    if [ "$bound" = "$n" ]; then
      printf '%s\n' "$p"
      return 0
    fi
  done < <(wt_paths)
  return 1
}

task_bootstrap_verify_fresh_branch() {
  local wt="$1" branch="$2" created="$3"
  if ! task_branch_has_upstream "$wt" "$branch"; then
    return 0
  fi
  if [ "$created" = 1 ]; then
    git -C "$wt" branch --unset-upstream >/dev/null 2>&1 || true
    if ! task_branch_has_upstream "$wt" "$branch"; then
      return 0
    fi
  fi
  err_code claim.has_upstream \
    "    ✗ 任务分支 ${branch} 已有 upstream，拒绝覆盖。请保留并诊断，不要手工猜测改名。"
  return 1
}

# 正常路径：只要 Issue 号。从已批准 Contract 建 worktree + exact sparse + bind。
# 结束态：clean、bound、unclaimed。不 claim、不 launch、不改 Task identity。
task_bootstrap_worktree() {
  local n="$1" wt="$ROOT" main nwo owner repo json load_rc=0 scope
  local dest name branch oid created=0 existing bound other regex
  local busy dirty
  task_config_require
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || die_code task.issue_number_invalid "Issue 编号不合法：$n"
  [ "$(git -C "$wt" rev-parse --is-inside-work-tree 2>/dev/null || true)" = true ] \
    || die_code task.not_git_worktree "bootstrap 必须在 git 工作树里运行"
  [ "$(git_mode)" = "monorepo" ] || die_code task.git_mode "git.mode 不是 monorepo"
  main="$(default_branch)"
  if ! git -C "$wt" fetch --quiet origin "refs/heads/${main}:refs/remotes/origin/${main}"; then
    err_code task.bootstrap_fetch_failed "    ✗ 无法 fetch origin/${main}，拒绝猜测契约基点"
    return 1
  fi
  git -C "$wt" rev-parse --verify -q "origin/${main}" >/dev/null \
    || { err_code task.base_missing "    ✗ 找不到 origin/${main}"; return 1; }
  oid="$(git -C "$wt" rev-parse "origin/${main}")" \
    || { err_code task.base_missing "    ✗ 读不到 origin/${main} OID"; return 1; }

  json="$(mktemp -t new-task-boot-contract.XXXXXX)"; TMPS="$TMPS $json"
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

  name="$(task_bootstrap_name "$n")"
  dest="$(worktree_root)/$name"
  if [ -e "$dest" ]; then
    dest="$(task_canon "$dest")"
  fi
  branch="$(task_bootstrap_branch "$scope" "$n")" \
    || { err_code task.branch_naming "    ✗ 无法从契约范围派生分支名"; return 1; }
  regex="$(policy_get git.branch.naming_regex)"
  if [ -z "$regex" ] || ! task_name_matches_re "$branch" "$regex"; then
    err_code task.branch_naming "    ✗ 派生分支 ${branch} 不符合 ${regex:-missing naming_regex}"
    return 1
  fi

  if other="$(task_bootstrap_other_bind "$dest" "$n")"; then
    err_code task.binding_conflict \
      "    ✗ Issue #${n} 已 bind 到另一工作树：${other}。拒绝覆盖。"
    return 1
  fi

  if [ -e "$dest" ]; then
    [ "$(git -C "$dest" rev-parse --is-inside-work-tree 2>/dev/null || true)" = true ] \
      || { err_code task.binding_conflict "    ✗ 已存在且不是本仓库 worktree：$dest"; return 1; }
    if busy="$(task_git_busy "$dest")"; then
      err_code task.git_busy "    ✗ 已有 worktree 正忙：${busy}。拒绝覆盖。"
      return 1
    fi
    dirty="$(git -C "$dest" -c core.quotePath=false status --porcelain 2>/dev/null || true)"
    if [ -n "$dirty" ]; then
      err_code task.bootstrap_dirty "    ✗ 已有 worktree 不干净，拒绝覆盖、stash 或 reset。"
      return 1
    fi
    if task_has_unique_commits "$dest" "$oid"; then
      err_code task.bootstrap_unique_commits \
        "    ✗ 已有 worktree 含独有提交，拒绝覆盖或隐藏。"
      return 1
    fi
    bound="$(task_bind_read "$dest" || true)"
    if [ -n "$bound" ] && [ "$bound" != "$n" ]; then
      err_code task.binding_conflict \
        "    ✗ ${dest} 已 bind #${bound}，与 #${n} 冲突。拒绝覆盖。"
      return 1
    fi
    existing="$(git -C "$dest" symbolic-ref --short HEAD 2>/dev/null || true)"
    if [ -n "$existing" ] && [ "$existing" != "$branch" ]; then
      err_code task.binding_conflict \
        "    ✗ ${dest} 当前分支是 ${existing}，不是 ${branch}。拒绝覆盖。"
      return 1
    fi
    if [ -n "$existing" ] && task_branch_has_upstream "$dest" "$existing"; then
      err_code claim.has_upstream \
        "    ✗ 已有任务分支带 upstream，拒绝自动改写。请保留并诊断。"
      return 1
    fi
  else
    if task_local_head_exists "$wt" "$branch"; then
      err_code claim.local_ref_exists \
        "    ✗ 本地分支已存在：${branch}。拒绝覆盖。"
      return 1
    fi
    case "$(task_origin_head_exists "$wt" "$branch"; echo $?)" in
      0)
        err_code claim.remote_ref_exists \
          "    ✗ 远端已有同名分支 origin/${branch}。拒绝覆盖。"
        return 1
        ;;
      2)
        err_code claim.remote_ref_unreadable \
          "    ✗ 无法确认 origin/${branch} 是否存在（不猜测）"
        return 1
        ;;
    esac
    mkdir -p "$(worktree_root)"
    # 用 origin/main 的 OID，而不是 origin/main 引用：后者会把新分支
    # 误设成 tracking origin/main，随后 claim 因 has_upstream 无法规范化。
    git -C "$wt" worktree add --no-checkout -b "$branch" "$dest" "$oid" >/dev/null \
      || { err_code task.bootstrap_worktree_failed "    ✗ 无法创建 worktree $dest"; return 1; }
    created=1
    if ! task_bootstrap_verify_fresh_branch "$dest" "$branch" 1; then
      return 1
    fi
    git -C "$dest" sparse-checkout init --cone >/dev/null \
      || { err_code task.sparse_init_failed "git sparse-checkout init --cone 失败"; return 1; }
    task_sparse_apply_exact "$dest" "$scope" "$oid" || return 1
    git -C "$dest" checkout -q \
      || { err_code task.bootstrap_checkout_failed "    ✗ checkout 失败"; return 1; }
  fi

  if [ "$created" != 1 ]; then
    task_bind_ensure_sparse "$dest" "$scope" || return 1
  else
    task_framework_materialize "$dest" || return 1
  fi

  task_bind "$n" "$dest" || return 1
  [ "$(task_bind_read "$dest")" = "$n" ] \
    || { err_code task.issue_unbound "bind 回读失败"; return 1; }
  task_is_sparse "$dest" || { err_code task.not_sparse "bootstrap 后不是 sparse-checkout"; return 1; }
  dirty="$(git -C "$dest" -c core.quotePath=false status --porcelain 2>/dev/null || true)"
  [ -z "$dirty" ] || {
    err_code task.bootstrap_dirty "    ✗ bootstrap 结束后工作区必须干净"
    return 1
  }

  echo
  c_ok "✓ task-aware bootstrap 已就绪（clean / bound / unclaimed）"
  echo "    Issue   ${owner}/${repo}#${n}"
  echo "    目录    $dest"
  echo "    分支    ${branch}（基于 origin/${main} @ ${oid}，不跟踪 origin/${main}）"
  echo "    可见    $(task_sparse_current_paths "$dest" | awk 'NF{printf "%s%s", (n++?" ":""), $0} END{print ""}')"
  echo "    可写    $(task_scope_oneline "$scope")"
  echo "    框架可读 AGENTS.md（不可因此写入）"
  echo
  echo "  下一步：进入工作树后 new task 预检，或 new task grok|codex 领取并启动。"
  echo "  高级/恢复：new worktree / new task bind / new task claim 仍可用。"
}
