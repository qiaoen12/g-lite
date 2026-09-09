# 决策记录扫描、总索引与各目录受控块。生成器和审计 decision_links 共用。
# 由 0-meta/bin/new 加载，不要单独执行。

# ─────────────────────────────────────────────── 决策记录的 scope 声明
#
# 决策与它作用的对象是多对多：一条 ADR 常同时动 policy、脚本、docs 和某个项目，
# 一个项目的决策也不止一条。这种关系塞不进目录名——名字只有一个位置。
# 与 3-data 的采集端/应用端是同一个形状的问题，所以照搬同一套分工：
#   4-know/decision/  物理存放（按文档种类分，不按主题分）
#   frontmatter.scope 事实（多值、完整）
#   两个生成的索引    反向查询（0-meta/DECISIONS.md + 各目录受控块）
#
# scope 词表不在这里实现。check-commit-msg.sh 已经有一份（从 derived.lock 读规则、
# 从目录树现场派生 unit），照抄一份的结局是 new adr --index 认为合法的 scope
# 被 daily 审计报成非法，然后没人知道该信哪个。
DECISION_DIR_REL="$(policy_get decision.records_dir)"; DECISION_DIR_REL="${DECISION_DIR_REL:-4-know/decision}"
DECISION_INDEX_REL="$(policy_get decision.index_file)"; DECISION_INDEX_REL="${DECISION_INDEX_REL:-0-meta/DECISIONS.md}"
CHECK_MSG_REL="$(policy_get decision.scope_tool)"; CHECK_MSG_REL="${CHECK_MSG_REL:-0-meta/audit/scripts/check-commit-msg.sh}"
CHECK_SCOPE_VALID_MODE="$(policy_get decision.scope_validate_mode)"; CHECK_SCOPE_VALID_MODE="${CHECK_SCOPE_VALID_MODE:---scope-valid}"
CHECK_SCOPE_DIR_MODE="$(policy_get decision.scope_dir_mode)"; CHECK_SCOPE_DIR_MODE="${CHECK_SCOPE_DIR_MODE:---scope-dir}"
CHECK_SCOPE_LEVEL_MODE="$(policy_get decision.scope_level_mode)"; CHECK_SCOPE_LEVEL_MODE="${CHECK_SCOPE_LEVEL_MODE:---scope-level}"
for _policy_path in "$DECISION_DIR_REL" "$DECISION_INDEX_REL" "$CHECK_MSG_REL"; do
  case "$_policy_path" in /*|..|../*|*/../*|*/..) die "policy 派生了工作区外路径：$_policy_path" ;; esac
done
unset _policy_path
DECISION_DIR="$ROOT/$DECISION_DIR_REL"
CHECK_MSG="$ROOT/$CHECK_MSG_REL"

# 决策标题：frontmatter 之后第一个 `# ` 标题。索引里给人看的就是这个。
fm_title() {
  awk 'NR==1 && $0=="---" {f=1;next} f && $0=="---" {f=0;b=1;next} b && /^# / {sub(/^# +/,""); print; exit}' "$1" 2>/dev/null
}

# 级别与路径映射仍交给 scope 的唯一实现。不能在这里按点号数量猜：
# 合法目录名本身可以含点，`code.foo.bar` 可能是单元 foo.bar，也可能是成员 bar。
scope_level() {
  "$CHECK_MSG" "$CHECK_SCOPE_LEVEL_MODE" "$1"
}

# Markdown 链接标签与表格单元格共用这份转义。路径另走 url_path。
md_text() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/|/\\|/g' -e 's/\[/\\[/g' -e 's/]/\\]/g'
}

# 扫全部决策记录，把结果写进 $1 目录下五个文件：
#   rows     id \t 标题 \t primary_scope \t 级别 \t status \t created \t supersedes \t 相对路径 \t 链接用路径
#   byscope  scope \t id \t 标题 \t 相对路径 \t 链接用路径
#   warn     id \t 问题描述
#   ids      id \t 相对路径，仅决策记录，供 supersedes 校验用
#   allids   id \t 相对路径，整个 4-know，供重复检测用
#
# 路径必须存进来，不能靠 id 拼。4-know 的命名是 free-with-id，文档明确承诺
# 「文件重命名、换目录，引用都不断」——靠 id 拼出 <id>.md 的话，一旦有人真的
# 改名，索引里全部链接就断了，而审计比的是「重新渲染的结果与磁盘一致」，
# 两边一样地断，照样报绿。报绿的坏检查比没有检查更糟。
#
# 判据只有这一份实现，生成器（cmd_adr_index）与审计（decision_links）共用。
# 返回值恒为 0：这里只陈述事实，判决权归调用方。
decision_scan() {
  local dir="$1"
  : > "$dir/rows"; : > "$dir/byscope"; : > "$dir/warn"; : > "$dir/ids"; : > "$dir/allids"

  [ -d "$DECISION_DIR" ] || return 0
  [ -x "$CHECK_MSG" ] || { c_err "scope 校验器不存在或不可执行：$CHECK_MSG"; return 2; }

  local f n id rel urlrel dup
  # 先过一遍收 id 与路径。冲突检测的集合是整个 4-know 而不只决策记录：
  # schema 里 id 的定义是「跨文档引用、Dataview 查询、外部链接全部靠它」，
  # 那它的命名空间就是整个 4-know。`new note x` 之后再 `new adr x` 是两条普通
  # 命令，不挡的话两个文件同 id 而全程无人出声——「笔记升格成决策」正好会撞上。
  # supersedes 校验仍然只认决策 id：取代关系不该指向一篇笔记。
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    id="$(fm_scalar "$f" id)"
    [ -n "$id" ] || continue
    printf '%s\t%s\n' "$id" "${f#"$ROOT"/}" >> "$dir/allids"
    case "$f" in "$DECISION_DIR"/*) printf '%s\t%s\n' "$id" "${f#"$ROOT"/}" >> "$dir/ids" ;; esac
  done < <(find "$ROOT/4-know" -name '_files' -prune -o -type f -name '*.md' \
             ! -name AGENTS.md ! -name README.md -print 2>/dev/null | sort)

  # id 重复要报。链接指向、supersedes 校验、反查表去重全都假设它唯一，
  # 而不唯一时的表现是最坏那种：反查表把两条决策 sort -u 合成一条，静默少一条。
  while IFS= read -r dup; do
    [ -n "$dup" ] || continue
    # 只在至少一侧是决策记录时报。两篇笔记互撞也违反 schema 契约，但那超出本检查
    # 的范围，硬报会变成 decision_links 替别人说话。
    awk -F'\t' -v k="$dup" -v d="4-know/decision/" '$1==k && index($2,d)==1{f=1} END{exit !f}' "$dir/allids" || continue
    printf '%s\t%s\n' "$dup" "id 与 4-know 里其他文档重复：$(awk -F'\t' -v k="$dup" '$1==k{printf "%s ", $2}' "$dir/allids")" >> "$dir/warn"
  done < <(cut -f1 "$dir/allids" | sort | uniq -d)

  local ids; ids="$(cut -f1 "$dir/ids" | tr '\n' ' ')"

  local ty title prim form invalid s shallow lvl st created sup rc
  local -a scopes valid_scopes
  for f in "$DECISION_DIR"/*.md; do
    [ -f "$f" ] || continue
    n="$(basename "$f" .md)"
    rel="${f#"$ROOT"/}"
    urlrel="$(url_path "$rel")"
    id="$(fm_scalar "$f" id)"
    if [ -z "$id" ]; then
      printf '%s\t%s\n' "$n" "缺 frontmatter 或缺 id 字段，索引无从引用它" >> "$dir/warn"; continue
    fi

    ty="$(fm_scalar "$f" type)"
    if [ "$ty" != decision ]; then
      printf '%s\t%s\n' "$id" "type 是 ${ty:-空}，decision/ 下只该放 type: decision" >> "$dir/warn"
    fi

    title="$(fm_title "$f")"
    case "$title" in
      ''|*'<'*'>'*) printf '%s\t%s\n' "$id" "标题还是模板占位符，索引里会是一行看不懂的表格" >> "$dir/warn"
                    title="（未填标题）" ;;
    esac
    title="$(md_text "$title")"

    st="$(fm_scalar "$f" status)";   st="${st:-—}"
    created="$(fm_scalar "$f" created)"; created="${created:-—}"
    sup="$(fm_scalar "$f" supersedes)"
    case "$sup" in null|'') sup="" ;; esac
    if [ -n "$sup" ]; then
      case " $ids " in
        *" $sup "*) ;;
        *) printf '%s\t%s\n' "$id" "supersedes 指向的 ${sup} 不存在，演进链断在这里" >> "$dir/warn" ;;
      esac
    fi

    # 形态先判。合法 YAML 但不合本工作区约定（典型是行内 scope: [a, b]）
    # 必须大声拒绝——上一代同类解析器把它算成 0 项，索引少一行而没人知道。
    form="$(fm_form "$f" scope)"
    case "$form" in
      block|empty) ;;
      absent) printf '%s\t%s\n' "$id" "缺 scope 字段，说不出这条决策作用于什么" >> "$dir/warn" ;;
      *)      printf '%s\t%s\n' "$id" "scope 是$(fm_form_zh "$form")，只认 [] 或块式列表（每项一行、以 - 开头）" >> "$dir/warn" ;;
    esac

    scopes=()
    if [ "$form" = block ]; then
      while IFS= read -r s; do
        [ -n "$s" ] && scopes+=("$s")
      done < <(fm_list "$f" scope)
      [ "${#scopes[@]}" -gt 0 ] || printf '%s\t%s\n' "$id" "scope 声明成块式却没有任何 - 项；空列表要显式写成 []" >> "$dir/warn"
    fi

    # 合法性交给唯一那份词表实现。它打印不合法的那些，全合法则无输出。
    valid_scopes=()
    if [ "${#scopes[@]}" -gt 0 ]; then
      rc=0
      invalid="$("$CHECK_MSG" "$CHECK_SCOPE_VALID_MODE" "${scopes[@]}" 2>"$dir/scope-validator.err")" || rc=$?
      case "$rc" in
        0) ;;
        1)
          [ -n "$invalid" ] || {
            c_err "scope 校验器返回失败但没有指出具体 scope"
            [ ! -s "$dir/scope-validator.err" ] || c_err "$(cat "$dir/scope-validator.err")"
            return 2
          } ;;
        *)
          c_err "scope 校验器执行失败（退出码 $rc）"
          [ ! -s "$dir/scope-validator.err" ] || c_err "$(cat "$dir/scope-validator.err")"
          return 2 ;;
      esac
      for s in "${scopes[@]}"; do
        if printf '%s\n' "$invalid" | awk -v q="$s" '$0 == q { found=1 } END { exit !found }'; then
          printf '%s\t%s\n' "$id" "scope 里的 ${s} 不是合法 scope，或映射有歧义（词表见 policy.yaml 的 git.commit 段）" >> "$dir/warn"
        else
          valid_scopes+=("$s")
          printf '%s\t%s\t%s\t%s\t%s\n' "$s" "$id" "$title" "$rel" "$urlrel" >> "$dir/byscope"
        fi
      done
    fi

    prim="$(fm_scalar "$f" primary_scope)"
    case "$prim" in
      '')     printf '%s\t%s\n' "$id" "缺 primary_scope 字段；多个 scope 地位平等时显式写 null" >> "$dir/warn"; prim=null ;;
      *'<'*'>'*) printf '%s\t%s\n' "$id" "primary_scope 还是模板占位符" >> "$dir/warn"; prim=null ;;
    esac

    if [ "$prim" != null ]; then
      local prim_in_scope=0
      for s in "${scopes[@]}"; do [ "$s" = "$prim" ] && prim_in_scope=1; done
      [ "$prim_in_scope" = 1 ] || printf '%s\t%s\n' "$id" "primary_scope（${prim}）不在 scope 里" >> "$dir/warn"
    fi

    # 级别：primary_scope 有效就按它；为 null 时取有效 scope 里最宽的一项。
    # 路径深度由校验器返回，不按点号数猜，因目录名本身允许含点。
    if [ "$prim" != null ]; then
      local prim_valid=0
      for s in "${valid_scopes[@]}"; do [ "$s" = "$prim" ] && prim_valid=1; done
      if [ "$prim_valid" = 1 ]; then
        lvl="$(scope_level "$prim" 2>/dev/null)" || { c_err "无法解析 primary_scope 的级别：$prim"; return 2; }
      else
        lvl='未定'
      fi
    elif [ "${#valid_scopes[@]}" -gt 0 ]; then
      local best_rank=99 rank one_level
      shallow=""
      for s in "${valid_scopes[@]}"; do
        one_level="$(scope_level "$s" 2>/dev/null)" || { c_err "无法解析 scope 的级别：$s"; return 2; }
        case "$one_level" in 体系级) rank=0 ;; 单元级) rank=1 ;; 成员级) rank=2 ;; *) rank=99 ;; esac
        if [ "$rank" -lt "$best_rank" ]; then
          best_rank="$rank"; shallow="$s"; lvl="$one_level"
        fi
      done
    else
      lvl='未定'
      printf '%s\t%s\n' "$id" "scope 为空，级别推不出来；它没说清作用于什么，等于没做完" >> "$dir/warn"
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$title" "$prim" "$lvl" "$st" "$created" "$sup" "$rel" "$urlrel" >> "$dir/rows"
  done
  return 0
}

# 从 decision_scan 的结果渲染总索引全文到 $1。纯函数，不碰目标文件——
# 审计要拿它的输出和磁盘上的 DECISIONS.md 做全文件比较，渲染和落盘必须分开。
decisions_index_render() {
  local dst="$1" dir="$2" lvl index_dir p
  index_dir="$(dirname "$DECISION_INDEX_REL")"; [ "$index_dir" = "." ] && index_dir=""
  : > "$dir/indexlinks"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    printf '%s\t%s\n' "$p" "$(url_path "$(rel_path "$index_dir" "$p")")" >> "$dir/indexlinks"
  done < <(cut -f8 "$dir/rows" | sort -u)
  {
    echo "# 架构决策索引"
    echo
    echo "由 \`new adr --index\` 生成，**不要手改**。事实源是 \`${DECISION_DIR_REL}/\` 各文件的 frontmatter。"
    echo
    echo "\`new check\` 会重新渲染一遍并与本文件逐字节比较，改了声明没重算、或手改过本文件，都会报出来。"
    echo
    echo "级别不是单独的字段，由 \`primary_scope\` 的形状推：裸 domain 体系级，单元目录是单元级，"
    echo "分组内成员是成员级。**级别回答「声明得多粗」，不回答「影响面多大」**——影响面要读正文。"
    echo "词表、真实路径与级别都由提交语言的 scope 工具统一解析。"
    echo

    for lvl in 体系级 单元级 成员级 未定; do
      if awk -F'\t' -v l="$lvl" '$4==l{found=1} END{exit !found}' "$dir/rows" 2>/dev/null; then
        echo "## $lvl"
        echo
        case "$lvl" in
          体系级) echo "声明粒度是整个域。裸 \`repo\` / \`meta\` 约束整个工作区，其余域只约束自己那一块。" ;;
          单元级) echo "作用于一个项目、一个基础设施单元或一个数据集。" ;;
          成员级) echo "作用于分组项目里的某一个成员。" ;;
          未定)   echo "scope 没声明清楚，级别推不出来。这一组属于待处理，不属于分级结果。" ;;
        esac
        echo
        echo "| 决策 | 主归属 | 状态 | 记于 |"
        echo "| --- | --- | --- | --- |"
        awk -F'\t' -v l="$lvl" '$4==l{print}' "$dir/rows" | sort -t$'\t' -k6,6r -k1,1 \
          | awk -F'\t' -v lf="$dir/indexlinks" '
            BEGIN { while ((getline x < lf) > 0) { split(x, a, "\t"); L[a[1]] = a[2] } close(lf) }
            {
              sup = ($7 != "") ? " （取代 `" $7 "`）" : ""
              print "| [" $2 "](" L[$8] ")" sup " | `" $3 "` | " $5 " | " $6 " |"
            }'
        echo
      fi
    done

    echo "## 按 scope 反查"
    echo
    echo "「我在改 X，它背后有哪些决策」——各目录 \`AGENTS.md\` / \`README.md\` 里的受控块是同一份数据的就近副本。"
    echo
    echo "| scope | 决策 |"
    echo "| --- | --- |"
    if [ -s "$dir/byscope" ]; then
      sort -u "$dir/byscope" \
        | awk -F'\t' -v lf="$dir/indexlinks" '
            BEGIN { while ((getline x < lf) > 0) { split(x, z, "\t"); L[z[1]] = z[2] } close(lf) }
            { a[$1] = a[$1] (a[$1] ? "、" : "") "[" $3 "](" L[$4] ")" }
            END { for (k in a) print k "\t" a[k] }' \
        | sort | awk -F'\t' '{print "| `" $1 "` | " $2 " |"}'
    else
      echo "| （无声明） |  |"
    fi
    echo

    echo "## 时间线"
    echo
    echo "按记录日期排。这一节回答「当时在解决什么问题」，级别分组回答「现在这套东西为什么长这样」。"
    echo
    if [ -s "$dir/rows" ]; then
      sort -t$'\t' -k6,6 -k1,1 "$dir/rows" \
        | awk -F'\t' -v lf="$dir/indexlinks" '
          BEGIN { while ((getline x < lf) > 0) { split(x, a, "\t"); L[a[1]] = a[2] } close(lf) }
          {
            sup = ($7 != "") ? "，取代 `" $7 "`" : ""
            print "- **" $6 "** `" $4 "` [" $2 "](" L[$8] ") — `" $3 "`，" $5 sup
          }'
    fi

    if [ -s "$dir/warn" ]; then
      echo
      echo "## 需要处理"
      echo
      sort "$dir/warn" | awk -F'\t' '{print "- `" $1 "` " $2}'
    fi
  } > "$dst"
}

# ── 各目录的受控块 ──────────────────────────────────────────────────────────
# 总索引解决「看演进」，受控块解决「干活时读得到」。后者是真缺口：根 AGENTS.md
# 定的阅读顺序是「目标目录最近的 AGENTS.md → 目录内 README.md → policy.yaml」，
# 4-know/decision/ 不在这条链的任何一环——在 2-infra/backup 里改备份脚本的人
# 永远不会知道 restic-cold-backup 这条决策存在。
#
# 模式与 AGENTS.md 的提交语言块相同：生成、被审计钉住、手改即报不一致。
DEC_BEGIN="$(policy_get decision.marker_begin)"
DEC_END="$(policy_get decision.marker_end)"
DEC_BEGIN="${DEC_BEGIN:-<!-- BEGIN decisions (generated by new adr --index) -->}"
DEC_END="${DEC_END:-<!-- END decisions -->}"

# 从 $1 这个目录看 $2 这个路径的相对写法，两者都相对工作区根（空串表示根）。
# 受控块要写进任意深度的目录，链接得当场算——写死 `../` 前缀会在 0-meta 里
# 生成 `../0-meta/DECISIONS.md` 这种能用但绕路的链接。
rel_path() {
  local from="$1" to="$2" out="" i=0 j
  local -a fa=() ta=()
  [ -n "$from" ] && IFS=/ read -r -a fa <<<"$from"
  IFS=/ read -r -a ta <<<"$to"
  # 共同前缀段跳过，但最后一段是文件名，不参与比较
  while [ "$i" -lt "${#fa[@]}" ] && [ "$i" -lt "$((${#ta[@]} - 1))" ] && [ "${fa[i]}" = "${ta[i]}" ]; do
    i=$((i + 1))
  done
  for ((j = i; j < ${#fa[@]}; j++)); do out="../$out"; done
  for ((j = i; j < ${#ta[@]}; j++)); do out="$out${ta[j]}/"; done
  printf '%s' "${out%/}"
}

# 路径 → 能安全放进 Markdown 链接括号里的写法。
#
# 4-know 的命名是 free-with-id，文件名里可以出现 Markdown 与 URL 的活字符，
# 而决策记录的标题格式恰好爱用它们：`为什么不用 borg?.md` 里的 `?` 会被当成
# query，`选 restic (而不是 borg).md` 里的 `)` 直接截断链接语法。断掉的样子是
# 链接照样渲染、点进去什么都没有——静默的那种。
#
# 只编码会破坏解析的那几个，UTF-8 原样留着：把中文也按 RFC 3986 编码掉，
# 链接就成了一串 %E4%B8%BA，而中文文件名是策略明确允许的。
# `%` 必须第一个换，否则会把后面几步自己生成的转义再转一遍。
url_path() {
  printf '%s' "$1" | sed -e 's/%/%25/g' -e 's/\\/%5C/g' -e 's/ /%20/g' \
    -e 's/#/%23/g' -e 's/?/%3F/g' -e 's/(/%28/g' -e 's/)/%29/g' \
    -e 's/\[/%5B/g' -e 's/]/%5D/g' -e 's/</%3C/g' -e 's/>/%3E/g' -e 's/"/%22/g'
}

# 路径的第一段是否落在 ai_access 声明为 deny 的顶层目录里。
# 事实源是 policy.yaml 的 ai_access 段，经 derived.lock 传递——支持新的 deny
# 目录是改 policy，不是改这个脚本。
in_deny() {
  local first="${1%%/*}"
  [ -n "$first" ] || return 1
  awk -F' = ' -v p="$first" '
    /^ai_access\./ && $2 == "deny" { sub(/^ai_access\./, "", $1); if ($1 == p) found = 1 }
    END { exit !found }
  ' "$LOCK"
}

# 只做 lstat，不解析符号链接目标。这样能在碰到允许域里的链接时及时停住，
# 不会为了判断它指向哪里而先遍历到 deny 目录。
path_has_symlink_component() {
  local rel="${1#/}" cur="$ROOT" part
  case "$rel" in ''|.|..|../*|*/../*|*/..) return 0 ;; esac
  local -a parts=()
  IFS=/ read -r -a parts <<<"$rel"
  for part in "${parts[@]}"; do
    [ -n "$part" ] || continue
    cur="$cur/$part"
    [ -L "$cur" ] && return 0
  done
  return 1
}

# scope → 受控块目标文件。两条规则。
#
# 一、deny 目录一律不碰，连 stat 都不做。`record` 是合法 scope 且映射到 `5-record`，
# 而后者是 `ai_access: deny`。不挡的话，索引生成器会读并整份重写一个策略声明
# 「不准读」的目录里的文件——用工具把边界洗掉，比人直接去读更难发现。
# 返回 2（区别于「找不到落点」的 1），让调用方报出来而不是静默跳过。
#
# 二、目录本身没有 AGENTS.md / README.md 就往上找最近的祖先。这不是将就：
# 根 AGENTS.md 定的阅读顺序本来就是「目标目录最近的 AGENTS.md」，在
# `3-data/foo/` 里干活的人读到的就是 `3-data/AGENTS.md`。不回退的话，19 个常见
# scope 里有 7 个会被静默跳过（全部数据集、4-know 各子目录、各调研专题），
# 而「干活时读得到」恰恰是这套机制唯一的存在理由。
#
# 回退深度取决于目标目录：八个域目录都有 AGENTS.md，所以域内 scope 最多退到
# 域目录；但 research.<topic> 走两层（4-know/research/<topic> → 4-know/research
# → 4-know），而别名 meta.hooks 的目录就是 `.`，落点直接是根 AGENTS.md。
#
# 仍然不主动创建文件：凭一条 scope 声明就在项目里凭空造出 AGENTS.md，
# 等于让索引去改变它本该只是描述的东西。
decision_block_target() {
  local scope="$1" d rc=0 candidate rel
  d="$("$CHECK_MSG" "$CHECK_SCOPE_DIR_MODE" "$scope")" || rc=$?
  [ "$rc" = 0 ] || return 4
  [ -n "$d" ] || return 4
  [ "$d" = "." ] && d=""
  in_deny "$d" && return 2
  [ -n "$d" ] && path_has_symlink_component "$d" && return 3

  while : ; do
    rel="${d:+$d/}AGENTS.md"; candidate="$ROOT/$rel"
    path_has_symlink_component "$rel" && return 3
    if [ -f "$candidate" ]; then printf '%s\n' "$candidate"; return 0; fi

    rel="${d:+$d/}README.md"; candidate="$ROOT/$rel"
    path_has_symlink_component "$rel" && return 3
    if [ -f "$candidate" ]; then printf '%s\n' "$candidate"; return 0; fi

    [ -n "$d" ] || return 1
    d="$(dirname "$d")"
    [ "$d" = "." ] && d=""
  done
}

# 把 byscope 摊成「目标文件 → scope → 决策」，写进 $dir/targets，
# 目标文件清单去重后写 $dir/targetfiles。
decision_targets_build() {
  local dir="$1" s id title rel target rc
  : > "$dir/targets"; : > "$dir/targetfiles"; : > "$dir/errors"
  while IFS=$'\t' read -r s id title rel _; do
    [ -n "$s" ] || continue
    target="$(decision_block_target "$s")" && rc=0 || rc=$?
    case "$rc" in
      0) ;;
      1)
        printf '%s\t%s\n' "$id" "scope ${s} 找不到 AGENTS.md / README.md 落点，不生成受控块" >> "$dir/warn"
        continue ;;
      2)
        # deny 目录不写受控块，但要说出来。静默跳过会让人以为那条 scope 已经
        # 有了就近入口，而它没有——总索引里仍然查得到，那是唯一的入口。
        printf '%s\t%s\n' "$id" "scope ${s} 落在 ai_access: deny 的目录里，不写受控块；这条决策只在总索引里可查" >> "$dir/warn"
        continue ;;
      3)
        printf '%s\t%s\n' "$id" "scope ${s} 的落点路径含符号链接；为避免越过访问边界，拒绝读写" >> "$dir/errors"
        continue ;;
      *)
        printf '%s\t%s\n' "$id" "scope ${s} 无法解析到目录（scope 校验器退出码 ${rc}）" >> "$dir/errors"
        continue ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\n' "$target" "$s" "$id" "$title" "$rel" >> "$dir/targets"
  done < "$dir/byscope"
  cut -f1 "$dir/targets" | sort -u > "$dir/targetfiles"
  [ ! -s "$dir/errors" ]
}

# 全部可能带受控块的文档。受控块只会写进 AGENTS.md / README.md，别的不找。
# deny 目录在这里就滤掉：`5-record/AGENTS.md` 是被 git 跟踪的，不滤的话
# 残留块检查会对它跑 grep——每次 new check 都读一遍 deny 目录里的文件。
decision_block_files() {
  local f d
  {
    if in_repo; then
      git -C "$ROOT" ls-files -- '*AGENTS.md' '*README.md' 2>/dev/null || true
    else
      printf '%s\n' AGENTS.md README.md
      while IFS= read -r d; do
        [ -n "$d" ] || continue
        path_has_symlink_component "$d" && continue
        [ -d "$ROOT/$d" ] || continue
        ( cd "$ROOT" && find "$d" \
            -type d ! -path "$d" \( -name .git -o -name _cache -o -name _out -o -name _raw \
              -o -name _vendor -o -name _archive -o -name _files \) -prune \
            -o -type f \( -name AGENTS.md -o -name README.md \) -print )
      done < <(awk -F' = ' '/^ai_access\./ && ($2 == "read" || $2 == "read-write") {
        sub(/^ai_access\./, "", $1); print $1
      }' "$LOCK")
    fi
  } | while IFS= read -r f; do
    in_deny "$f" || printf '%s\n' "$f"
  done
}

# 带受控块但已经不是任何 scope 的目标的文件，写进 $dir/stale。
# scope 撤掉之后块还留在原处，就是一条会被人当真的谎，比没有块糟。
decision_stale_find() {
  local dir="$1" f
  : > "$dir/stale"
  [ -e "$dir/errors" ] || : > "$dir/errors"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if path_has_symlink_component "$f"; then
      printf '%s\t%s\n' "$f" "候选受控块路径含符号链接；为避免越过访问边界，拒绝读取" >> "$dir/errors"
      continue
    fi
    [ -f "$ROOT/$f" ] || continue
    grep -qxF "$DEC_BEGIN" "$ROOT/$f" || continue
    grep -qxF "$ROOT/$f" "$dir/targetfiles" || printf '%s\n' "$ROOT/$f" >> "$dir/stale"
  done < <(decision_block_files)
  [ ! -s "$dir/errors" ]
}

# absent 可以安全追加；valid 可以替换/移除；其他状态一律拒绝写。
decision_block_state() {
  awk -v b="$DEC_BEGIN" -v e="$DEC_END" '
    $0 == b { bc++; if (bc == 1) bp = NR }
    $0 == e { ec++; if (ec == 1) ep = NR }
    END {
      if (bc == 0 && ec == 0) print "absent"
      else if (bc == 1 && ec == 1 && bp < ep) print "valid"
      else print "invalid"
    }
  ' "$1"
}

# 抽出 $1 现有受控块的正文（不含 marker）。没有块则无输出。
decision_block_current() {
  awk -v b="$DEC_BEGIN" -v e="$DEC_END" '
    $0 == b { inb = 1; next }
    inb && $0 == e { inb = 0; next }
    inb { print }
  ' "$1"
}

# 去掉 $1 的受控块，连同追加时多加的那个空行。返回 0 表示文件有变化。
decision_block_strip() {
  local target="$1" tmp state rel
  rel="${target#"$ROOT"/}"
  path_has_symlink_component "$rel" && return 2
  state="$(decision_block_state "$target")"
  [ "$state" = valid ] || return 2
  atomic_tmp tmp "$target"
  awk -v b="$DEC_BEGIN" -v e="$DEC_END" '
    $0 == b { inb = 1; next }
    inb && $0 == e { inb = 0; next }
    inb { next }
    { L[++n] = $0 }
    END { while (n > 0 && L[n] == "") n--; for (i = 1; i <= n; i++) print L[i] }
  ' "$target" > "$tmp"
  if atomic_install "$tmp" "$target"; then return 0; else return 1; fi
}

# 渲染某个目标文件该有的受控块正文到 $dir/body。纯函数，审计拿它逐字节比对。
decision_block_render() {
  local dir="$1" t="$2" reldir idxlink p
  reldir="${t#"$ROOT"}"; reldir="${reldir#/}"; reldir="$(dirname "$reldir")"
  [ "$reldir" = "." ] && reldir=""
  idxlink="$(rel_path "$reldir" "$DECISION_INDEX_REL")"

  # 每条决策到本目标文件的相对链接先算好，awk 里查表。逐条算是因为决策文件名
  # 可以是任意的（4-know 是 free-with-id），拼不出来；用 rel_path 而不是
  # 「../ × 深度 + 完整路径」是为了让 4-know/AGENTS.md 里的链接也是最短形式。
  : > "$dir/links"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    printf '%s\t%s\n' "$p" "$(url_path "$(rel_path "$reldir" "$p")")" >> "$dir/links"
  done < <(awk -F'\t' -v t="$t" '$1==t{print $5}' "$dir/targets" | sort -u)

  {
    echo
    echo "## 相关决策"
    echo
    echo "由 \`new adr --index\` 从 \`${DECISION_DIR_REL}/\` 各文件的 frontmatter 生成，**不要手改**。"
    echo "完整索引见 [\`${DECISION_INDEX_REL}\`](${idxlink})。"
    echo
    echo "| scope | 决策 |"
    echo "| --- | --- |"
    awk -F'\t' -v t="$t" '$1==t{print $2 "\t" $3 "\t" $4 "\t" $5}' "$dir/targets" | sort -u \
      | awk -F'\t' -v lf="$dir/links" '
          BEGIN { while ((getline l < lf) > 0) { split(l, x, "\t"); L[x[1]] = x[2] } close(lf) }
          { a[$1] = a[$1] (a[$1] ? "、" : "") "[" $3 "](" L[$4] ")" }
          END { for (k in a) print k "\t" a[k] }' \
      | sort | awk -F'\t' '{print "| `" $1 "` | " $2 " |"}'
    echo
  } > "$dir/body"
}

# 把 $2 这份正文写进 $1 的受控块。已有块整块替换，没有则追加到末尾。
# 先写临时文件再 rename：这个流程要连着改好几个文件，中途中断不能留下半个块。
# 返回 0 表示文件有变化，1 表示本来就一致。
decision_block_apply() {
  local target="$1" bodyfile="$2" tmp state rel
  rel="${target#"$ROOT"/}"
  path_has_symlink_component "$rel" && return 2
  state="$(decision_block_state "$target")"
  case "$state" in valid|absent) ;; *) return 2 ;; esac
  atomic_tmp tmp "$target"
  if [ "$state" = valid ]; then
    awk -v b="$DEC_BEGIN" -v e="$DEC_END" -v bf="$bodyfile" '
      $0 == b { print; while ((getline l < bf) > 0) print l; close(bf); skip = 1; next }
      skip && $0 == e { print; skip = 0; next }
      skip { next }
      { print }
    ' "$target" > "$tmp"
  else
    { cat "$target"; echo; echo "$DEC_BEGIN"; cat "$bodyfile"; echo "$DEC_END"; } > "$tmp"
  fi
  if atomic_install "$tmp" "$target"; then return 0; else return 1; fi
}

# 所有目标先验完再动第一份文件，避免第七个目标 marker 损坏时前六个已经被改。
decision_blocks_preflight() {
  local dir="$1" t state rel
  [ -e "$dir/errors" ] || : > "$dir/errors"
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    rel="${t#"$ROOT"/}"
    if path_has_symlink_component "$rel"; then
      printf '%s\t%s\n' "$rel" "受控块路径含符号链接，拒绝读写" >> "$dir/errors"
      continue
    fi
    state="$(decision_block_state "$t")"
    [ "$state" != invalid ] || printf '%s\t%s\n' "$rel" "受控块 marker 缺失、重复或顺序错误，拒绝改写" >> "$dir/errors"
  done < "$dir/targetfiles"
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    rel="${t#"$ROOT"/}"
    if path_has_symlink_component "$rel"; then
      printf '%s\t%s\n' "$rel" "待移除的受控块路径含符号链接，拒绝读写" >> "$dir/errors"
      continue
    fi
    state="$(decision_block_state "$t")"
    [ "$state" = valid ] || printf '%s\t%s\n' "$rel" "待移除的受控块 marker 不完整，拒绝改写" >> "$dir/errors"
  done < "$dir/stale"
  [ ! -s "$dir/errors" ]
}

cmd_adr_index() {
  local out="$ROOT/$DECISION_INDEX_REL" dir tmp
  is_sparse_worktree && die "new adr --index 必须在完整工作树运行；sparse worktree 会把未展开目录误当成空。请回主工作区执行。"
  tmp_mkd dir adrindex
  atomic_tmp tmp "$out"

  decision_scan "$dir" || die "决策记录扫描失败，未改写任何索引或受控块。"
  if ! decision_targets_build "$dir"; then
    sort "$dir/errors" | awk -F'\t' '{print "    · " $1 "：" $2}' >&2
    die "受控块目标解析失败，未改写任何文件。"
  fi
  if ! decision_stale_find "$dir"; then
    sort "$dir/errors" | awk -F'\t' '{print "    · " $1 "：" $2}' >&2
    die "受控块候选路径不安全，未改写任何文件。"
  fi
  if ! decision_blocks_preflight "$dir"; then
    sort "$dir/errors" | awk -F'\t' '{print "    · " $1 "：" $2}' >&2
    die "受控块 marker 校验失败，未改写任何文件。"
  fi

  decisions_index_render "$tmp" "$dir"

  local nd; nd="$(wc -l < "$dir/rows" | tr -d ' ')"
  if atomic_install "$tmp" "$out"; then
    c_ok "✓ 已重算 ${DECISION_INDEX_REL}（$nd 条决策）"
  else
    c_ok "✓ ${DECISION_INDEX_REL} 已是最新（$nd 条决策）"
  fi

  local t changed=0 total=0 rc
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    total=$((total+1))
    decision_block_render "$dir" "$t"
    rc=0
    decision_block_apply "$t" "$dir/body" || rc=$?
    if [ "$rc" = 0 ]; then
      changed=$((changed+1))
      echo "    · 受控块已更新 ${t#"$ROOT"/}"
    elif [ "$rc" != 1 ]; then
      die "受控块写入前状态发生变化：${t#"$ROOT"/}"
    fi
  done < "$dir/targetfiles"

  while IFS= read -r t; do
    [ -n "$t" ] || continue
    rc=0
    decision_block_strip "$t" || rc=$?
    if [ "$rc" = 0 ]; then
      changed=$((changed+1))
      echo "    · 受控块已移除 ${t#"$ROOT"/}（已不在任何 scope 里）"
    elif [ "$rc" != 1 ]; then
      die "受控块移除前状态发生变化：${t#"$ROOT"/}"
    fi
  done < "$dir/stale"

  if [ "$changed" = 0 ]; then
    c_ok "✓ ${total} 处受控块已是最新"
  else
    c_ok "✓ ${total} 处受控块，其中 ${changed} 处有变动"
  fi

  if [ -s "$dir/warn" ]; then
    c_warn "⚠ 有需要处理的条目，见 DECISIONS.md 末节："
    sort "$dir/warn" | awk -F'\t' '{print "    · " $1 "：" $2}'
  fi
  tmp_rmd "$dir"
}
