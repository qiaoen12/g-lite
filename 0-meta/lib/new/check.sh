# 三档审计。明文凭据判定式只有这一份。
# 由 0-meta/bin/new 加载，不要单独执行。

# ─────────────────────────────────────────────── check
#
# 分两档，理由见 policy.yaml 的 audit.tiers：
#   commit  只回答「这一次写入能不能放行」——只看暂存区，预算 3 秒
#   daily   回答「现在整体健不健康」——全树扫描，预算 120 秒
#
# 把 daily 档挂进 pre-commit 是一个已知的失败模式：工作区长到 25 万文件之后
# 每次提交要等十几秒，真实结局是 hook 被关掉。而被关掉的门禁比没有门禁更糟——
# 它还在制造安全感。

# 敏感文件路径规则：按 basename 与风险等级判定。commit / daily / git 索引共用。
# 不匹配完整路径或目录名，避免 docs/id_rsa/notes.md、mysecrets.json 这类误报。
#
# 等级与 basename glob 只有下面两份声明。secret_class 和 daily 预筛都从这里读，
# 不要再手写一份 -name 清单。
#
#   high    明确高危私钥材料：未跟踪、暂存、已跟踪一律硬失败
#   config  高概率敏感配置：未跟踪告警，进入 Git（暂存或已跟踪）硬失败
#   pem     basename 是 *.pem，再读 armor 头行决定是否升为 high
#   none    路径规则放行（模板/文档/密文/普通文件）；不构成 gitleaks 白名单
SECRET_NAME_ALLOW=$'*.enc.*
*.pub
*.tpl
*.template
*.sample
*.example
credentials.schema.json
README
README.md
README.txt'

SECRET_NAME_RULES=$'config\t.env
config\t.env.local
config\t.env.production
config\tcredentials.json
config\t*.ovpn
high\tid_ed25519
high\tid_rsa*
high\t*.key
pem\t*.pem'

secret_glob_match() {
  case "$1" in $2) return 0 ;; *) return 1 ;; esac
}

secret_class() {
  local base="$1" class glob
  while IFS= read -r glob || [ -n "$glob" ]; do
    [ -n "$glob" ] || continue
    secret_glob_match "$base" "$glob" && { printf '%s\n' none; return; }
  done <<EOF
$SECRET_NAME_ALLOW
EOF
  while IFS=$'\t' read -r class glob || [ -n "$class" ]; do
    [ -n "$glob" ] || continue
    secret_glob_match "$base" "$glob" && { printf '%s\n' "$class"; return; }
  done <<EOF
$SECRET_NAME_RULES
EOF
  printf '%s\n' none
}

# 最多 32 行，只吐出第一条 -----BEGIN 行。私钥正文不进 shell 变量。
secret_pem_begin_line() {
  awk 'NR > 32 { exit } /^-----BEGIN / { print; exit }'
}

secret_pem_line_is_private() {
  case "$1" in
    '-----BEGIN '*"PRIVATE KEY-----") return 0 ;;
  esac
  return 1
}

# indexed：读 Git 索引 blob 的头行，不读工作区副本（sparse / 暂存后改工作区）。
# 索引里的符号链接（mode 120000）不跟随。
secret_pem_read_indexed() {
  local rel="$1" mode line
  in_repo || return 1
  mode="$(git -C "$ROOT" ls-files --stage -- "$rel" 2>/dev/null | awk '{print $1; exit}')"
  [ -n "$mode" ] || return 1
  [ "$mode" != 120000 ] || return 1
  line="$(git -C "$ROOT" cat-file blob ":0:$rel" 2>/dev/null | secret_pem_begin_line)" || true
  secret_pem_line_is_private "$line"
}

# untracked：只读工作区有限头行，拒绝跟随符号链接。
secret_pem_read_untracked() {
  local f="$1" line
  [ -n "$f" ] || return 1
  [ -L "$f" ] && return 1
  [ -f "$f" ] || return 1
  line="$(secret_pem_begin_line < "$f")" || true
  secret_pem_line_is_private "$line"
}

secret_pem_is_private() {
  local rel="$1" state="$2"
  if [ "$state" = indexed ]; then
    secret_pem_read_indexed "$rel"
  else
    secret_pem_read_untracked "$ROOT/$rel"
  fi
}

secret_class_rel() {
  local rel="$1" state="$2" class
  class="$(secret_class "${rel##*/}")"
  if [ "$class" = pem ]; then
    if secret_pem_is_private "$rel" "$state"; then
      printf '%s\n' high
    else
      printf '%s\n' none
    fi
    return
  fi
  printf '%s\n' "$class"
}

# state：untracked | indexed（暂存与已跟踪都算进入 Git）
secret_verdict() {
  local class="$1" state="$2"
  case "$class" in
    high) printf '%s\n' fail ;;
    config)
      if [ "$state" = untracked ]; then printf '%s\n' warn
      else printf '%s\n' fail
      fi ;;
    *) printf '%s\n' ok ;;
  esac
}

SECRET_HIT_FAIL=0
SECRET_HIT_WARN=0

# rel 相对仓库根。_vendor 第三方源码同名文件不算。
secret_scan_one() {
  local rel="$1" state="$2" class v
  [ -n "$rel" ] || return 0
  case "$rel" in _vendor|_vendor/*) return 0 ;; esac
  class="$(secret_class_rel "$rel" "$state")"
  v="$(secret_verdict "$class" "$state")"
  case "$v" in
    fail)
      SECRET_HIT_FAIL=$((SECRET_HIT_FAIL+1))
      case "$class" in
        high)   c_err "    ✗ ${rel}  明确高危私钥材料" ;;
        config) c_err "    ✗ ${rel}  高概率敏感配置已进入 Git" ;;
      esac ;;
    warn)
      SECRET_HIT_WARN=$((SECRET_HIT_WARN+1))
      c_warn "    ⚠ ${rel}  高概率敏感配置（未跟踪：告警；进入 Git 会硬失败）" ;;
  esac
}

# 预筛条件由 SECRET_NAME_RULES 生成，不另写一份文件名清单。
secret_scan_untracked() {
  local tracked="${1:-}" rel abs class glob
  local pred=()
  while IFS=$'\t' read -r class glob || [ -n "$class" ]; do
    [ -n "$glob" ] || continue
    [ "${#pred[@]}" -eq 0 ] || pred+=(-o)
    pred+=(-name "$glob")
  done <<EOF
$SECRET_NAME_RULES
EOF
  [ "${#pred[@]}" -gt 0 ] || return 0
  while IFS= read -r abs; do
    [ -n "$abs" ] || continue
    rel="${abs#"$ROOT"/}"
    if [ -n "$tracked" ] && printf '%s\n' "$tracked" | grep -Fxq "$rel"; then
      continue
    fi
    secret_scan_one "$rel" untracked
  done < <(find "$ROOT" \
      \( -name node_modules -o -name .git -o -name .venv -o -name venv -o -path "$ROOT/_vendor" \) -prune -o \
      \( -type f -o -type l \) \( "${pred[@]}" \) -print 2>/dev/null)
}

# core.quotePath=false：默认 git 会把中文路径转义成 "\345\220\210\345\220\214"
# 并加引号，于是 ^5-record/ 这类锚定匹配全部落空——而中文路径恰恰是最该拦的。
staged_files() {
  git -C "$ROOT" -c core.quotePath=false diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true
}

# ── prompt / agent-card 预算 ─────────────────────────────────────────────
# 这是 commit 档的显式门禁，不是只被测试脚本知道的旁路检查。commit 档优先
# 读取索引内容，因此「即将写入」的版本和检查对象一致；未进入索引的文件回退到
# 工作区，方便首次添加新卡片时得到可执行的失败信息。
prompt_budget_file_content() {
  local root="$1" rel="$2" staged
  staged="$(git -C "$root" diff --cached --name-only --diff-filter=ACMR -- "$rel" 2>/dev/null || true)"
  if [ -n "$staged" ] && git -C "$root" cat-file -e ":0:${rel}" 2>/dev/null; then
    git -C "$root" cat-file blob ":0:${rel}"
  elif [ -f "$root/$rel" ]; then
    cat "$root/$rel"
  else
    return 1
  fi
}

prompt_budget_file_bytes() {
  local root="$1" rel="$2"
  prompt_budget_file_content "$root" "$rel" | wc -c | tr -d ' '
}

prompt_budget_block_bytes() {
  local root="$1" rel="$2" body
  body="$(prompt_budget_file_content "$root" "$rel")" || return 1
  printf '%s\n' "$body" | grep -Fxq '<!-- BEGIN agent-card -->' || return 1
  printf '%s\n' "$body" | grep -Fxq '<!-- END agent-card -->' || return 1
  printf '%s\n' "$body" | awk -v e='<!-- END agent-card -->' '
      $0 == "<!-- BEGIN agent-card -->" { on=1 }
      on { print }
      on && $0 == e { exit }
    ' | wc -c | tr -d ' '
}

prompt_budget_value() {
  local lock="$1" key="$2" value
  value="$(lock_get "$lock" "$key")"
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
    c_err "    ✗ prompt budget 缺少有效配置：${key}"
    return 1
  }
  printf '%s\n' "$value"
}

prompt_budget_assert() {
  local label="$1" actual="$2" budget="$3"
  if ! [[ "$actual" =~ ^[0-9]+$ ]] || ! [[ "$budget" =~ ^[1-9][0-9]*$ ]]; then
    c_err "    ✗ prompt budget 无法测量：${label}（actual=${actual:-空} budget=${budget:-空}）"
    return 1
  fi
  if [ "$actual" -gt "$budget" ]; then
    c_err "    ✗ prompt budget 超限：${label} ${actual} > ${budget} bytes"
    return 1
  fi
  c_ok "    ✓ ${label} ${actual}/${budget} bytes"
}

prompt_budget_check() {
  local root="${1:-$ROOT}" lock="${2:-$LOCK}" fail=0 actual
  local root_budget meta_budget card_budget
  root_budget="$(prompt_budget_value "$lock" prompt_budget.root_agents_bytes)" || fail=1
  meta_budget="$(prompt_budget_value "$lock" prompt_budget.meta_agents_bytes)" || fail=1
  card_budget="$(prompt_budget_value "$lock" prompt_budget.agent_card_bytes)" || fail=1
  [ "$fail" = 0 ] || return 1

  actual="$(prompt_budget_file_bytes "$root" AGENTS.md 2>/dev/null || true)"
  prompt_budget_assert "AGENTS.md" "$actual" "$root_budget" || fail=1
  actual="$(prompt_budget_file_bytes "$root" 0-meta/AGENTS.md 2>/dev/null || true)"
  prompt_budget_assert "0-meta/AGENTS.md" "$actual" "$meta_budget" || fail=1
  actual="$(prompt_budget_block_bytes "$root" AGENTS.md 2>/dev/null || true)"
  prompt_budget_assert "AGENTS.md agent-card" "$actual" "$card_budget" || fail=1
  actual="$(prompt_budget_block_bytes "$root" 0-meta/AGENTS.md 2>/dev/null || true)"
  prompt_budget_assert "0-meta/AGENTS.md agent-card" "$actual" "$card_budget" || fail=1
  [ "$fail" = 0 ]
}

# deep 档：读内容、算哈希、拉快照。分钟级到十分钟级，只由每周日的 launchd 触发。
# 它回答的问题和另外两档不同——「副本和原始数据是否真的完好」，
# 而不是「这次写入能不能放行」或者「现在整体健不健康」。
cmd_check_deep() {
  local fail=0

  echo "── backup_closure  备份闭环（应备份集合 vs 快照路径集合）"
  # 具体怎么问 restic 属于备份单元的知识，不属于治理层。这里只负责要一个判决。
  local closure="$ROOT/2-infra/backup/scripts/check-closure.sh"
  if [ ! -x "$closure" ]; then
    c_err "    ✗ 缺 2-infra/backup/scripts/check-closure.sh"
    c_err "      backup_closure 声明为 hard_fail。检查不存在时必须报出来——"
    c_err "      一个缺席的检查亮绿灯，比没有这项检查更糟。"
    fail=1
  else
    "$closure" || fail=1
  fi

  echo "── raw_integrity  _raw 完整性（全量哈希比对）"
  local any=0
  for d in "$ROOT"/3-data/*/; do
    [ -d "$d/_raw" ] || continue
    local n; n="$(basename "$d")"
    case "$n" in example-*) continue ;; esac
    any=1
    echo "  · $n"
    cmd_data_seal "$n" || fail=1
  done
  [ "$any" = 1 ] || echo "    （没有含 _raw/ 的数据集）"

  echo
  verdict deep "$fail"
}

# 判决行。硬失败之外还要报告未处理的告警数——
# 一个把十条黄字消化成绿色「通过」的判决行，等于把这些检查删掉。
#
# 计数只覆盖本脚本自己发的告警。check-password.sh / check-commit-msg.sh 这些
# 外部检查的黄字进不了这个数，要收进来得改它们的返回码协议——跨三个模块换一个
# 更准的数字，不划算。所以这里把口径说清楚，而不是让判决行替它们背书。
verdict() {
  local tier="$1" fail="$2"
  if [ "$fail" != 0 ]; then c_err "${tier} 档发现硬失败项"; exit 1; fi
  if [ "$WARN_N" = 0 ]; then
    if [ "$tier" = commit ]; then
      c_ok "commit 档暂存区通过（只检查暂存区；不构成开发完成、修复完成或 review-ready）"
    else
      c_ok "${tier} 档通过（外部检查脚本的告警不计入本行，见上方输出）"
    fi
  else
    if [ "$tier" = commit ]; then
      c_warn "commit 档暂存区无硬失败，但有 ${WARN_N} 项告警未处理；不构成开发完成、修复完成或 review-ready"
    else
      c_warn "${tier} 档无硬失败，但有 ${WARN_N} 项告警未处理（不含外部检查脚本自己打的）"
    fi
  fi
}

# commit 档故意只看 index；同时展示当前工作树事实，避免空 staged set 的 PASS
# 被误读成当前实现已经完成。这个提示不改变 commit 档原有的返回码口径。
commit_tier_completion_note() {
  local head
  head="$(git -C "$ROOT" rev-parse --verify HEAD 2>/dev/null || true)"
  printf '    说明：commit 档只检查暂存区；HEAD=%s。即使本档返回 PASS，也不构成开发完成或 GitHub review-ready。\n' \
    "${head:-空}"
}

# 每个段标题以 policy 的 audit.checks[].id 开头，不用序号。
#
# 序号曾经有两套：0-meta/AGENTS.md 那张表的行序，和这里打印的编号。两套各自
# 稳定、互不相干，而文档里写「第 N 项」时没有任何标记说明用的是哪套——结果
# docs/05-备份与恢复.md 里三处「第 4 项」指了两个不同的检查。id 只有一份事实源。
#
# 尾部不再补等长横线：那要按显示宽度手数，加一项就得重新数一遍，而这正是
# 这套工具在别处消灭的手工活。
cmd_check() {
  local tier=daily
  while [ $# -gt 0 ]; do
    case "$1" in
      --tier) [ -n "${2:-}" ] || die "--tier 后面要跟 commit / daily / deep"; tier="$2"; shift 2 ;;
      *) die "未知参数：$1（用法：new check [--tier commit|daily|deep]）" ;;
    esac
  done
  case "$tier" in commit|daily|deep) ;; *) die "未知档位：${tier}（只有 commit / daily / deep）" ;; esac

  if [ "$tier" = deep ]; then cmd_check_deep; return; fi

  local fail=0
  [ "$tier" = commit ] && echo "（commit 档：只看暂存区）"
  [ "$tier" = commit ] && commit_tier_completion_note

  echo "── plan_staleness  derived.lock 是否与 policy 同步"
  if [ ! -f "$LOCK" ]; then
    c_err "    ✗ 缺 0-meta/derived.lock —— 跑 new plan"; fail=1
  else
    local want have
    want="$(shasum -a 256 "$ROOT/0-meta/policy.yaml" | awk '{print $1}')"
    have="$(lock_get "$LOCK" policy_sha256)"
    if [ "$want" != "$have" ]; then
      c_err "    ✗ policy.yaml 改过但没重算派生结果"
      c_err "      跑：new plan   （确认 diff 后 new plan --apply）"
      fail=1
    else
      c_ok "    ✓ 同步"
    fi
    # AGENTS.md 的提交语言块是 Codex / WorkBuddy 唯一能读到规则的地方
    # （policy 声明它们 enforced:false，layer 2 对它们是空的）。
    # 它是复制品，所以必须被机器钉住——手改一次就会开始漂移。
    if [ -f "$AGENTS_MD" ] && grep -qF "$CC_BEGIN" "$AGENTS_MD"; then
      if [ "$(extract_commit_block "$AGENTS_MD")" != "$(commit_block_content)" ]; then
        c_err "    ✗ AGENTS.md 的提交语言受控块与 policy 不一致 —— new plan --apply"
        fail=1
      else
        c_ok "    ✓ AGENTS.md 受控块同步"
      fi
    fi
  fi

  echo "── plaintext_secrets  明文密钥"
  SECRET_HIT_FAIL=0
  SECRET_HIT_WARN=0
  local sec_tracked="" sec_rel
  if in_repo; then
    sec_tracked="$(git -C "$ROOT" -c core.quotePath=false ls-files 2>/dev/null || true)"
  fi
  if [ "$tier" = commit ]; then
    while IFS= read -r sec_rel; do
      [ -n "$sec_rel" ] || continue
      secret_scan_one "$sec_rel" indexed
    done < <(staged_files)
  else
    secret_scan_untracked "$sec_tracked"
  fi
  if [ "$SECRET_HIT_FAIL" != 0 ]; then
    fail=1
  elif [ "$SECRET_HIT_WARN" = 0 ]; then
    c_ok "    ✓ 无明文凭据路径硬失败"
  fi

  # 3d / 3e 也要用，所以取值放在档位分支外面。
  local sa; sa="$(policy_get git.standalone.paths)"

  if [ "$tier" = daily ]; then
  echo "── copy_count  根仓库副本数"
  # v2.2：测量对象从「1-code 下每个子仓库」收敛为「根仓库 + 已登记的 standalone」。
  # monorepo 之后 remote 只有一个，这项从几十次独立测量变成一次——
  # 这本身就是换模式的主要收益。
  if ! in_repo; then
    c_err "    ✗ 根仓库还没初始化（整个工作区零版本历史）"
    echo "      cd ${ROOT} && git init -b $(default_branch) && git add -A && git commit -m 'chore: init workspace'"
    fail=1
  else
    if git -C "$ROOT" remote get-url origin >/dev/null 2>&1; then
      local rdirty runpushed
      rdirty="$(git -C "$ROOT" status --porcelain | wc -l | tr -d ' ')"
      runpushed="$(git -C "$ROOT" rev-list --count @{u}..HEAD 2>/dev/null || echo '?')"
      if [ "$rdirty" != 0 ] || [ "$runpushed" != 0 ]; then
        c_warn "    ⚠ 未提交=${rdirty}  未推送=${runpushed}"
      else
        c_ok "    ✓ 已提交且已推送"
      fi
    else
      c_err "    ✗ 根仓库没有 remote —— 全工作区只有本机一份 git"
      echo "      gh repo create --private --source=. --push"
      fail=1
    fi
  fi
  if [ -n "$sa" ]; then
    for p in $sa; do
      if [ ! -d "$ROOT/$p/.git" ]; then c_err "    ✗ 登记为 standalone 但没有 .git：$p"; fail=1; continue; fi
      if git -C "$ROOT/$p" remote get-url origin >/dev/null 2>&1; then
        c_ok "    ✓ standalone $p"
      else
        c_err "    ✗ standalone $p 没有 remote（零副本）"; fail=1
      fi
    done
  fi
  fi   # ← tier = daily

  echo "── git_hygiene  git 卫生（实查 ls-files）"
  # 只检查 .gitignore 是不够的：它只能阻止未来的 add，
  # 不会让已经 tracked 的文件消失。判据必须是索引里实际有什么。
  local gh_fail=0
  if in_repo; then
    # core.quotePath=false 是必须的：默认情况下 git 会把非 ASCII 路径转义成
    # "5-record/\345\220\210\345\220\214/…" 并加上引号，于是 ^5-record/ 匹配不上。
    # 而 5-record 恰恰整个域都是中文文件名——不关掉这个开关，
    # 这项检查会精确地漏掉它最该拦的东西。
    local tracked; tracked="$(git -C "$ROOT" -c core.quotePath=false ls-files 2>/dev/null || true)"

    # 3a. 5-record 只允许两个清单文件
    local rec_ok; rec_ok="$(policy_get git.never_exception.5-record)"
    [ -n "$rec_ok" ] || rec_ok="AGENTS.md RETENTION.md"
    local rec_bad=""
    for f in $(echo "$tracked" | grep '^5-record/' || true); do
      local base="${f#5-record/}"
      case " $rec_ok " in *" $base "*) ;; *) rec_bad="$rec_bad $f" ;; esac
    done
    if [ -n "$rec_bad" ]; then
      c_err "    ✗ 5-record 有档案本体进了 git（硬失败）："
      for f in $rec_bad; do echo "        $f"; done
      echo "      清理：git rm --cached <file>；若已进历史，需要 filter-repo 重写"
      gh_fail=1
    fi

    # 3b. 保留名任意深度都不该出现在索引里
    local resv; resv="$(policy_get git.never_reserved)"
    [ -n "$resv" ] || resv="_raw _out _cache _vendor _archive _files"
    for r in $resv; do
      local hits2; hits2="$(echo "$tracked" | grep -E "(^|/)${r}/" || true)"
      if [ "$r" = "_vendor" ]; then
        hits2="$(echo "$hits2" | grep -vE '^_vendor/(AGENTS\.md|VENDOR\.md)$' || true)"
      fi
      if [ -n "$hits2" ]; then
        c_err "    ✗ 保留名 ${r}/ 下的文件进了 git（硬失败）："
        echo "$hits2" | head -5 | sed 's/^/        /'
        gh_fail=1
      fi
    done

    # 3c. 明文凭据进索引。路径规则与 plaintext_secrets 共用 secret_class。
    SECRET_HIT_FAIL=0
    while IFS= read -r sec_rel; do
      [ -n "$sec_rel" ] || continue
      secret_scan_one "$sec_rel" indexed
    done < <(printf '%s\n' "$tracked")
    [ "$SECRET_HIT_FAIL" = 0 ] || gh_fail=1

    # 3d. 未登记的嵌套 .git。monorepo 里它会被记成 gitlink，
    #     外层 clone 拿不到内容，而且 clone 的人不会收到任何警告。
    local nested; nested="$(find "$ROOT/1-code" "$ROOT/2-infra" "$ROOT/4-know" "$ROOT/3-data" \
        -maxdepth 3 -name .git -not -path "$ROOT/.git" 2>/dev/null | sed "s|^$ROOT/||; s|/\.git$||" | sort || true)"
    for p in $nested; do
      case " $sa " in
        *" $p "*) c_ok "    ✓ 嵌套 .git 已登记为 standalone：$p" ;;
        *) c_err "    ✗ 未登记的嵌套 .git：$p"
           echo "        monorepo 模式下它会被记成 gitlink，clone 出来是个空目录。"
           echo "        要么 rm -rf ${p}/.git 并入根仓库，"
           echo "        要么登记到 policy.yaml 的 git.standalone.repos 并在根 .gitignore 排除。"
           gh_fail=1 ;;
      esac
    done

    # 3e. standalone 登记与 .gitignore 的闭环
    for p in $sa; do
      grep -qE "^/?${p}/?$" "$ROOT/.gitignore" 2>/dev/null \
        || { c_err "    ✗ standalone ${p} 未在根 .gitignore 排除"; gh_fail=1; }
    done

    # 3f. 超大文件。逐文件 stat 是这一整项里唯一随仓库线性变慢的部分，
    #     所以 commit 档只量这次要提交的文件——判据不变，范围收窄。
    local maxb; maxb="$(policy_get git.max_tracked_file_bytes)"; maxb="${maxb:-5242880}"
    local size_scope
    if [ "$tier" = commit ]; then size_scope="$(staged_files)"; else size_scope="$tracked"; fi
    local big=""
    while IFS= read -r f; do
      [ -n "$f" ] && [ -f "$ROOT/$f" ] || continue
      local sz; sz="$(stat -f%z "$ROOT/$f" 2>/dev/null || stat -c%s "$ROOT/$f" 2>/dev/null || echo 0)"
      [ "$sz" -gt "$maxb" ] && big="$big\n        $((sz/1024/1024))MiB  $f"
    done <<< "$size_scope"
    if [ -n "$big" ]; then
      c_warn "    ⚠ 超过 $((maxb/1024/1024)) MiB 的已跟踪文件（考虑 _files/ 或 git-lfs）：$(printf "$big")"
    fi

    # 3g. 命名。只查目录段，不查文件名——strict-ascii 的理由是「路径即接口」
    #     （脚本、部署、bind mount 会引用目录），而 AGENTS.md / DATASET.md
    #     这类大写清单名是刻意的。把规则铺到文件名上会立刻制造一批
    #     永远修不掉的违规，然后整条规则失去可信度。这是 v1 已经踩过的坑。
    #     hard_fail:false，所以只告警。
    local name_scope
    if [ "$tier" = commit ]; then name_scope="$(staged_files)"; else name_scope="$tracked"; fi
    local badname=""
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      case "$f" in 0-meta/*|1-code/*|2-infra/*|3-data/*|_vendor/*) ;; *) continue ;; esac
      local dirs="${f%/*}"
      [ "$dirs" = "$f" ] && continue                  # 域根下的文件，没有中间目录
      dirs="${dirs#*/}"                               # 去掉域名本身
      [ "$dirs" = "${f%/*}" ] && continue
      # 3-data 只管数据集目录名；_raw/ 内的采集文件保持原样
      case "$f" in 3-data/*) dirs="${dirs%%/*}" ;; esac
      if printf '%s' "$dirs" | tr '/' '\n' | grep -qvE '^[a-z0-9][a-z0-9._-]*$'; then
        badname="$badname\n        $f"
      fi
    done <<< "$name_scope"
    if [ -n "$badname" ]; then
      c_warn "    ⚠ 目录名不符合 strict-ascii（^[a-z0-9][a-z0-9._-]*\$）：$(printf "$badname")"
    fi

    [ "$gh_fail" = 0 ] && c_ok "    ✓ 跟踪范围与 policy 一致"
  else
    echo "    （仓库未初始化，跳过）"
  fi
  [ "$gh_fail" = 0 ] || fail=1

  if [ "$tier" = commit ]; then
    echo
    echo "── prompt_budget  AGENTS.md / agent-card"
    prompt_budget_check || fail=1
    echo
    verdict commit "$fail"
    return 0
  fi

  echo "── password_sources  口令来源（机器取值 + 人恢复）"
  local pwcheck="$ROOT/2-infra/backup/scripts/check-password.sh"
  if [ ! -x "$pwcheck" ]; then
    c_err "    ✗ 缺 $pwcheck"
    c_err "      password_sources 声明为 hard_fail。检查不存在时必须报出来。"
    fail=1
  else
    "$pwcheck" || fail=1
  fi

  echo "── worktree_hygiene  worktree 状态"
  # worktree 在备份根之外，未提交的改动零副本。
  # copy_count 覆盖不到这里——它测量仓库，而脏数据不在任何仓库里。
  if in_repo; then
    local wt_any=0 wt_warn=0 p wbr wdirty
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      wt_any=1
      wbr="$(git -C "$p" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
      wdirty="$(git -C "$p" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
      if [ "$wdirty" != 0 ]; then
        c_warn "    ⚠ $(basename "$p")  分支=${wbr}  未提交=${wdirty}（在备份根之外，零副本）"
        wt_warn=1
      else
        c_ok "    ✓ $(basename "$p")  分支=${wbr}"
      fi
    done < <(wt_paths)
    [ "$wt_any" = 1 ] || echo "    （无 worktree）"
    [ "$wt_warn" = 0 ] || echo "      及时 commit，或确认 restic 已收录 $(worktree_root)"
  else
    echo "    （仓库未初始化，跳过）"
  fi

  echo "── retention  缺失的 manifest"
  local mfail=0
  for d in "$ROOT"/3-data/*/; do
    [ -d "$d" ] || continue
    if [ ! -f "$d/DATASET.md" ]; then c_err "    ✗ $(basename "$d") 缺 DATASET.md"; mfail=1; fi
  done
  if [ ! -f "$ROOT/5-record/RETENTION.md" ]; then c_err "    ✗ 5-record 缺 RETENTION.md"; mfail=1; fi
  if [ ! -f "$ROOT/_vendor/VENDOR.md" ];     then c_err "    ✗ _vendor 缺 VENDOR.md";   mfail=1; fi
  if [ "$mfail" = 0 ]; then c_ok "    ✓ manifest 齐全"; else fail=1; fi

  echo "── retention  _inbox 超期（>30 天）"
  local old
  old="$(find "$ROOT/_inbox" -mindepth 1 -maxdepth 1 ! -name 'AGENTS.md' -mtime +30 2>/dev/null || true)"
  if [ -n "$old" ]; then c_warn "    ⚠ 以下条目超过 30 天："; echo "$old" | sed 's/^/      /'
  else c_ok "    ✓ 无超期条目"; fi

  echo "── retention  4-know 复审到期（frontmatter.review）"
  # policy 的 retention 一项从 v1 起就写着「frontmatter.review 过期」，但实现一直是空的。
  # 一个声明存在、从不发声的检查比没有这个检查更糟：它让人以为知识库腐烂有人在管。
  # 判据只看日期，不看内容——「这篇还准不准」机器答不了，能答的是「该看一眼了」。
  local rvfail=0 rvn=0 rvskip=0 rvarch=0 rvf rvd rvid rvst
  while IFS= read -r rvf; do
    [ -n "$rvf" ] || continue
    rvst="$(fm_scalar "$rvf" status)"
    if [ "$rvst" = archived ]; then rvarch=$((rvarch+1)); continue; fi
    rvd="$(fm_scalar "$rvf" review)"
    case "$rvd" in
      ''|null) rvskip=$((rvskip+1)); continue ;;
      *) if ! ymd_valid "$rvd"; then
           c_warn "    ⚠ ${rvf#"$ROOT"/} 的 review 不是有效的 YYYY-MM-DD 日期：${rvd}"
           rvfail=1; continue
         fi ;;
    esac
    rvn=$((rvn+1))
    if [ "${rvd//-/}" -lt "${TODAY//-/}" ]; then
      rvid="$(fm_scalar "$rvf" id)"
      c_warn "    ⚠ ${rvid:-${rvf#"$ROOT"/}} 的复审日期 ${rvd} 已过 —— 复审后更新 review，或改 status: archived"
      rvfail=1
    fi
  # AGENTS.md / README.md 排除在外：它们是目录规则文件，不是知识条目，
  # 没有 frontmatter 契约。算进「未声明 review」只会让这个数字看起来像有问题。
  done < <(find "$ROOT/4-know" -name '_files' -prune -o -type f -name '*.md' \
             ! -name AGENTS.md ! -name README.md -print 2>/dev/null | sort)
  if [ "$rvfail" = 0 ]; then
    if [ "$rvskip" = 0 ]; then c_ok "    ✓ ${rvn} 篇都在复审期内（跳过 ${rvarch} 篇 archived）"
    else c_ok "    ✓ ${rvn} 篇都在复审期内（${rvskip} 篇未声明 review，跳过 ${rvarch} 篇 archived）"; fi
  fi

  # 这一段刻意没有 id 前缀——policy 的 audit.checks 里没有对应条目。
  # 实现先跑起来、声明没补上，补 id 要改 policy，那是另一件事。
  # 不给它编个假 id，否则「输出里的 id 都能在 policy 里查到」这条就不成立了。
  echo "── AI 访问边界适配器（policy 未声明 check id）"
  # layer 2 不是一个文件，是一组 adapter：每个工具只认自己的配置。
  # 清单从 derived.lock 读，而 lock 由 policy.yaml 推导——
  # 支持一个新工具是改 policy，不是改这个脚本。
  local adapters; adapters="$(policy_get ai_access.adapter_files)"
  [ -n "$adapters" ] || adapters=".aiignore .cursorignore .claude/settings.json"
  local ig_fail=0
  for f in $adapters; do
    if [ ! -f "$ROOT/$f" ]; then
      if [ "$f" = ".cursorignore" ]; then
        # 唯一不能自动装的一个：Cursor 禁止 agent 写它。
        c_warn "    ⚠ 缺 $f —— cp 0-meta/templates/cursorignore.tpl .cursorignore（必须你自己跑）"
      else
        c_err "    ✗ 缺 $f"; ig_fail=1
      fi
      continue
    fi
    # 判据按文件格式走。ignore 文件要行首锚定，否则注释里提一句 5-record
    # 就能让检查通过——而注释挡不住任何东西。
    case "$f" in
      *.json)
        grep -qF 'Read(/5-record/**)' "$ROOT/$f" \
          || { c_err "    ✗ $f 的 permissions.deny 没有 Read(/5-record/**)"; ig_fail=1; } ;;
      *)
        grep -q '^5-record/' "$ROOT/$f" \
          || { c_err "    ✗ $f 没有排除 5-record/（ai_access 声明为 deny）"; ig_fail=1; } ;;
    esac
  done
  if [ "$ig_fail" = 0 ]; then c_ok "    ✓ 各适配器均已 deny 5-record/"; else fail=1; fi
  local advisory; advisory="$(policy_get ai_access.adapter_advisory)"
  if [ -n "$advisory" ]; then
    echo "    · 仅行为规范、无法强制的工具走：${advisory}（Codex / WorkBuddy）"
    echo "      对它们而言 layer 2 是空的。真边界要等 layer 3（未挂载的加密卷）。"
  fi

  echo "── raw_integrity  _raw 哈希清单是否存在（全量比对在 deep 档）"
  local seal_missing=0
  for d in "$ROOT"/3-data/*/; do
    [ -d "$d/_raw" ] || continue
    local n; n="$(basename "$d")"
    case "$n" in example-*) continue ;; esac
    if [ ! -f "$d/_raw/MANIFEST.sha256" ]; then
      c_warn "    ⚠ $n 缺 _raw/MANIFEST.sha256 —— new data --seal $n"; seal_missing=1
    fi
  done
  if [ "$seal_missing" = 0 ]; then c_ok "    ✓ 齐全（完整性比对在 deep 档）"; fi

  echo "── commit_convention  主线提交语言（回扫）"
  # commit-msg 钩子能被 git commit --no-verify 绕过，本地补不了这个洞，
  # 所以这里事后回扫。用的是同一个脚本、同一套例外判断——
  # 两边各写一份的话判断迟早分叉，表现就是审计天天报一件钩子已经放行的事，
  # 而那正是门禁被整项关掉的前奏。
  local cmsg="$ROOT/0-meta/audit/scripts/check-commit-msg.sh"
  if [ ! -x "$cmsg" ]; then
    c_err "    ✗ 缺 $cmsg"; fail=1
  elif ! in_repo; then
    echo "    （仓库未初始化，跳过）"
  else
    # hard_fail:false —— 提交已经发生，阻断当天其余检查没有意义，
    # 而一个会让整轮 daily 变红的历史遗留问题，最后会被人整项关掉。
    "$cmsg" --scan || true
  fi

  echo "── dataset_links  数据集归属声明"
  # 不设硬失败。缺一行声明不会造成不可逆后果，而一个会让整轮 daily 变红的
  # 文档类问题，最后会被人整项关掉——这个代价比声明缺失本身大。
  # 判据与生成器共用 dataset_scan，这里只把它陈述的事实翻成告警。
  local idx="$ROOT/3-data/INDEX.md" dldir dltmp dlfail=0
  tmp_mkd dldir dscheck
  atomic_tmp dltmp "$idx"
  dataset_scan "$dldir"
  if [ -s "$dldir/warn" ]; then
    while IFS=$'\t' read -r dn msg; do
      [ -n "$dn" ] || continue
      c_warn "    ⚠ ${dn}：$msg"
    done < <(sort "$dldir/warn")
    dlfail=1
  fi
  # 判据是整份文件，不是一个指纹。指纹能证明声明没变，证明不了索引内容正确——
  # 上一版只 grep 那串指纹，删光全部表格、留下指纹那一行，检查照样通过。
  dataset_index_render "$dltmp" "$dldir"
  if [ ! -f "$idx" ]; then
    c_warn "    ⚠ 缺 3-data/INDEX.md —— new data --index"; dlfail=1
  elif ! cmp -s "$dltmp" "$idx"; then
    c_warn "    ⚠ INDEX.md 与当前声明不是同一份内容（过期或被手改）—— new data --index"; dlfail=1
  fi
  tmp_rmd "$dldir"; atomic_abort "$dltmp"
  [ "$dlfail" = 0 ] && c_ok "    ✓ 归属声明齐全，索引与声明一致"

  echo "── decision_links  决策记录 scope 声明"
  # 同 dataset_links 不设硬失败：让一个文档类问题把整轮 daily 变红，
  # 结局是这一项被整项关掉，代价大于声明缺失本身。
  # 判据与生成器共用 decision_scan，这里只把它陈述的事实翻成告警。
  local dcidx="$ROOT/$DECISION_INDEX_REL" dcdir dctmp dcfail=0 dct dcstate targets_ok=1 scan_ok=1
  if is_sparse_worktree; then
    c_warn "    ⚠ 当前是 sparse worktree，未展开的目录不能当成空；本项跳过，请在完整主工作区运行 new check"
    dcfail=1
  else
    tmp_mkd dcdir dccheck
    atomic_tmp dctmp "$dcidx"
    if ! decision_scan "$dcdir"; then
      c_err "    ✗ 决策记录扫描器执行失败"
      fail=1; dcfail=1; targets_ok=0; scan_ok=0
    elif ! decision_targets_build "$dcdir"; then
      targets_ok=0; dcfail=1
    elif ! decision_stale_find "$dcdir"; then
      targets_ok=0; dcfail=1
    fi

    if [ -s "$dcdir/errors" ]; then
      while IFS=$'\t' read -r dn msg; do
        [ -n "$dn" ] || continue
        c_warn "    ⚠ ${dn}：$msg"
      done < <(sort "$dcdir/errors")
      dcfail=1
    fi
    # target 构建会补充 deny / 无落点告警，所以必须在这里之后统一消费。
    if [ -s "$dcdir/warn" ]; then
      while IFS=$'\t' read -r dn msg; do
        [ -n "$dn" ] || continue
        c_warn "    ⚠ ${dn}：$msg"
      done < <(sort "$dcdir/warn")
      dcfail=1
    fi
    # 判据是整份文件而不是指纹，理由同 dataset_links：
    # 指纹能证明声明没变，证明不了索引内容正确，而这里要保的恰恰是后者。
    if [ "$scan_ok" = 1 ]; then
      decisions_index_render "$dctmp" "$dcdir"
      if [ ! -f "$dcidx" ]; then
        c_warn "    ⚠ 缺 ${DECISION_INDEX_REL} —— new adr --index"; dcfail=1
      elif ! cmp -s "$dctmp" "$dcidx"; then
        c_warn "    ⚠ DECISIONS.md 与当前声明不是同一份内容（过期或被手改）—— new adr --index"; dcfail=1
      fi
    fi
    # 各目录的受控块同样逐字节比。marker 不完整时只报告，绝不尝试抽取或改写。
    if [ "$targets_ok" = 1 ]; then
      while IFS= read -r dct; do
        [ -n "$dct" ] || continue
        decision_block_render "$dcdir" "$dct"
        dcstate="$(decision_block_state "$dct")"
        case "$dcstate" in
          absent)
            c_warn "    ⚠ ${dct#"$ROOT"/} 缺受控块 —— new adr --index"; dcfail=1 ;;
          invalid)
            c_warn "    ⚠ ${dct#"$ROOT"/} 的受控块 marker 缺失、重复或顺序错误；拒绝自动改写"; dcfail=1 ;;
          valid)
            if ! decision_block_current "$dct" | cmp -s - "$dcdir/body"; then
              c_warn "    ⚠ ${dct#"$ROOT"/} 的受控块与当前声明不一致（过期或被手改）—— new adr --index"; dcfail=1
            fi ;;
        esac
      done < "$dcdir/targetfiles"
      while IFS= read -r dct; do
        [ -n "$dct" ] || continue
        dcstate="$(decision_block_state "$dct")"
        if [ "$dcstate" = valid ]; then
          c_warn "    ⚠ ${dct#"$ROOT"/} 的受控块已不在任何 scope 里，留着就是一条谎 —— new adr --index"
        else
          c_warn "    ⚠ ${dct#"$ROOT"/} 含残留且损坏的受控块 marker，拒绝自动改写"
        fi
        dcfail=1
      done < "$dcdir/stale"
    fi
    tmp_rmd "$dcdir"; atomic_abort "$dctmp"
  fi
  [ "$dcfail" = 0 ] && c_ok "    ✓ scope 声明齐全，总索引与各处受控块都与声明一致"

  echo
  verdict daily "$fail"
}
