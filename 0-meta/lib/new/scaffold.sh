# 脚手架：code / data / note / source / adr / rb / research / vendor / infra。
# 由 0-meta/bin/new 加载，不要单独执行。

# ─────────────────────────────────────────────── code
cmd_code() {
  local n="$1"; slug_ok "$n" || die "项目名必须匹配 ^[a-z0-9][a-z0-9._-]*$"
  local d="$ROOT/1-code/$n"; exists "$d"
  mkdir -p "$d/_out"

  cat > "$d/README.md" <<EOF
# $n

做什么：

## 怎么跑

\`\`\`bash
op run --env-file=.env.tpl -- <启动命令>
\`\`\`

## 依赖

## 产物

运行输出写在 \`_out/\`，可随时删除重建。
EOF

  cat > "$d/.env.tpl" <<'EOF'
# 只写引用，不写明文。运行时用 op run --env-file=.env.tpl -- <cmd> 注入。
# API_KEY=op://Private/<item>/<field>
EOF

  # 项目级 .gitignore 只写这个项目特有的东西。
  # 依赖目录、保留名、密钥这三类由根 .gitignore 统一管，不在这里重复——
  # 重复一遍就等于多一份会漂移的清单。
  cat > "$d/.gitignore" <<'EOF'
# 本项目特有的忽略项写在这里。
# 依赖目录（node_modules/.venv/target/dist）、保留名（_out/_cache）、
# 明文密钥，都由根 .gitignore 统一管辖，不要在这里重复声明。
EOF

  touch "$d/_out/.gitkeep"

  c_ok "✓ 已建 1-code/$n"

  local mode; mode="$(git_mode)"
  if [ "$mode" = "monorepo" ]; then
    # 不 git init。这个目录属于根仓库，不需要也不应该有自己的 .git。
    echo
    echo "  它已经属于本工作区根仓库，不需要建 remote，也不需要 git init。"
    echo "  下一步（在项目目录里直接跑就行，git 会自动往上找根仓库）："
    echo
    echo "    cd 1-code/${n} && git add . && git commit -m \"feat(code.${n}): 建项目骨架\""
    echo
    echo "  要独占一个工作目录给 AI 用："
    echo "    new worktree ${n} --path 1-code/${n}"
    if ! in_repo; then
      echo
      c_warn "⚠ 但根仓库还没初始化。先跑："
      echo "    cd ${ROOT} && git init -b $(default_branch) && git add -A && git commit -m \"chore: init workspace\""
    fi
  else
    (cd "$d" && git init -q && git add -A && git commit -qm "chore: scaffold $n")
    c_warn "⚠ per_project 模式：还差 remote，没有 remote 等于零副本"
    echo "    cd 1-code/${n} && gh repo create --private --source=. --push"
  fi
}

# ─────────────────────────────────────────────── data
cmd_data() {
  local n="$1"; slug_ok "$n" || die "数据集名必须匹配 ^[a-z0-9][a-z0-9._-]*$"
  local d="$ROOT/3-data/$n"; exists "$d"
  mkdir -p "$d"/{_raw,_out,pipeline}
  touch "$d/_raw/.gitkeep" "$d/_out/.gitkeep" "$d/pipeline/.gitkeep"

  cat > "$d/DATASET.md" <<EOF
---
dataset: $n
# 采集端：这份数据是谁产出的。key 取 code / pipeline / manual / external
#   code      1-code/<tool>，独立的采集工具项目
#   pipeline  本数据集自带的 pipeline/<script>
#   manual    人工下载导入，写清楚从哪下的
#   external  外部工具或服务（浏览器 agent、第三方导出）
producers:
  - manual: <填这里>
# 应用端：谁在用这份数据。多个就多行；还没人用就保持 []
consumers: []
# 目录名取自它。多个应用端地位平等时填 null，目录名改用 shared- 前缀
primary_consumer: null
---

# 数据集：$n

## 这是什么

<一句话说明>

## 采集

| 项 | 值 |
| --- | --- |
| 来源 | <API / 站点 / 导出> |
| 方式 | \`pipeline/<script>\` |
| 频率 | <每日增量 / 一次性> |
| 起始 | $TODAY |
| 中断记录 | 无 |

## 字段

| 列名 | 类型 | 单位 | 说明 |
| --- | --- | --- | --- |
|  |  |  |  |

唯一键：\`<id>\`

## 已知问题

-

## 可重采性

**能否重新采到同样的数据：** <能 / 不能，为什么>

> 这一栏决定备份策略。不能重采 = 必须永久备份。

## 保留期

| 目录 | 保留 | 依据 |
| --- | --- | --- |
| \`_raw/\` | <永久 / N 年> | <不可重采 / 合规要求> |
| \`_out/\` | 不备份 | 可由 pipeline 重建 |

## \`_out/\` 重建命令

\`\`\`bash
<填这里。说不出重建命令的目录就不是 _out/>
\`\`\`
EOF

  c_ok "✓ 已建 3-data/$n"
  c_warn "⚠ 先填完 DATASET.md 再开始采集。"
  echo "    采完一批后固化：new data --seal $n"
}

# 给 _raw/ 生成或更新哈希清单。
# 语义是 append-only：新增文件写入清单，已有文件哈希变动即报错。
cmd_data_seal() {
  local n="$1"
  local d="$ROOT/3-data/$n"
  [ -d "$d" ] || die "找不到数据集：3-data/$n"
  local raw="$d/_raw"
  [ -d "$raw" ] || die "找不到 3-data/$n/_raw/"
  local mf="$raw/MANIFEST.sha256"

  local tmp; tmp="$(mktemp -t manifest.XXXXXX)"; TMPS="$TMPS $tmp"

  (cd "$raw" && find . -type f \
      ! -name 'MANIFEST.sha256' ! -name '.gitkeep' ! -name '.DS_Store' \
      -exec shasum -a 256 {} + 2>/dev/null | sort -k2) > "$tmp" || true

  local nfiles; nfiles="$(wc -l < "$tmp" | tr -d ' ')"

  if [ ! -f "$mf" ]; then
    cp "$tmp" "$mf"
    c_ok "✓ 已生成 3-data/$n/_raw/MANIFEST.sha256（$nfiles 个文件）"
    c_warn "  建议同时加只读位：find 3-data/$n/_raw -type f -exec chmod a-w {} +"
    return 0
  fi

  # 逐条比对：只允许新增，不允许改动或消失
  local mutated=0 deleted=0 appended=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    local oh op nh
    oh="${line%% *}"; op="${line#* }"; op="${op# }"
    nh="$(awk -v p="$op" '{h=$1; $1=""; sub(/^ +/,""); if ($0==p) {print h; exit}}' "$tmp")"
    if [ -z "$nh" ]; then
      c_err "    RAW_DELETED  $op"; deleted=$((deleted+1))
    elif [ "$nh" != "$oh" ]; then
      c_err "    RAW_MUTATED  $op"; mutated=$((mutated+1))
    fi
  done < "$mf"

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    local np; np="${line#* }"; np="${np# }"
    if ! grep -qF "  $np" "$mf" 2>/dev/null; then appended=$((appended+1)); fi
  done < "$tmp"

  echo "  新增 $appended  改动 $mutated  丢失 $deleted"
  if [ "$mutated" -gt 0 ] || [ "$deleted" -gt 0 ]; then
    c_err "✗ _raw/ 里已有的原始记录被改写或删除。这是硬失败——先查清原因，不要直接重新 seal。"
    return 1
  fi
  cp "$tmp" "$mf"
  c_ok "✓ 清单已更新（${nfiles} 个文件，新增 ${appended}）"
}

# ─────────────────────────────────────────────── 4-know 通用
_know() {
  local sub="$1" type="$2" slug="$3" extra="${4:-}"
  slug_ok "$slug" || die "slug 必须匹配 ^[a-z0-9][a-z0-9._-]*$"
  local f="$ROOT/4-know/$sub/$slug.md"; exists "$f"
  mkdir -p "$(dirname "$f")"
  {
    echo "---"
    echo "id: $slug"
    echo "type: $type"
    echo "status: draft"
    echo "topic: []"
    if [ -n "$extra" ]; then echo "$extra"; fi
    echo "confidence: medium"
    echo "created: $TODAY"
    echo "review: $REVIEW_6M"
    echo "---"
    echo
    echo "# <标题>"
    echo
  } > "$f"
  echo "$f"
}

cmd_note()   { local f; f="$(_know note     note     "$1")"; c_ok "✓ $f"; }
cmd_source() { local f; f="$(_know source   source   "$1" "source: ")"; c_ok "✓ $f"; c_warn "⚠ 记得填 source 字段"; }

cmd_adr() {
  local slug="$1"; local f
  # scope / primary_scope 预填成空声明而不是省略：省略的字段没人会想起来补，
  # 而空声明会被 new adr --index 当场报出来。
  f="$(_know decision decision "$slug" "$(cat <<'FM'
# scope：这条决策作用于哪几块。词表与提交语言完全相同
#   （<domain>[.<unit>[.<member>]]，unit 从目录树派生），`new adr --index` 会校验。
#   多值，每项一行、以 - 开头。跨域是常态，不要勉强只写一个。
#   写成 scope: [a, b] 不认——行内列表会被拒绝，不会静默算成 0 项。
scope: []
# primary_scope：主归属，必须是 scope 里的一项；多个地位平等时填 null。
#   决策级别从它的形状推：裸 domain（repo / meta）体系级，<domain>.<unit> 单元级。
primary_scope: null
FM
)")"
  cat >> "$f" <<'EOF'
## 背景与约束

为什么现在必须决定？当时有哪些不能动的前提？

## 考虑过的选项

当时真正比较过什么？不知道就明确写不知道，别把空表留在这里。

| 方案 | 优 | 劣 |
| --- | --- | --- |
|  |  |  |

## 决定

## 后果

什么变容易、什么变困难、增加了哪些要人记住的约束？正面、负面、中性都要写。

## 什么情况下要重新考虑

哪些可观察的变化会让上面的理由失效？
EOF
  c_ok "✓ $f"
  c_warn "⚠ 记得填 scope 与 primary_scope，然后跑 new adr --index"
}

cmd_rb() {
  local slug="$1"; local f; f="$(_know runbook runbook "$slug")"
  cat >> "$f" <<'EOF'
## 什么时候用

## 前置条件

## 步骤

1.

## 验证

## 出错了怎么回退
EOF
  c_ok "✓ $f"
}

# ─────────────────────────────────────────────── research
cmd_research() {
  local n="$1"; slug_ok "$n" || die "专题名必须小写英文"
  local d="$ROOT/4-know/research/$n"; exists "$d"
  mkdir -p "$d/notes"; touch "$d/notes/.gitkeep"

  cat > "$d/QUESTION.md" <<EOF
---
id: research-$n
type: note
status: draft
topic: []
created: $TODAY
review: $REVIEW_6M
---

# 调研：$n

## 要回答的问题

<一句话，具体到能判断"答完了没有">

## 纳入标准

先写标准再检索。事后定标准 = 给已有结论找理由。

-

## 排除标准

-

## 检索计划

| 库 / 源 | 检索式 |
| --- | --- |
|  |  |

## 结论

<调研完成后回填>
EOF

  cat > "$d/screening.csv" <<'EOF'
date,source,query,hits,screened_out,included,note
EOF

  c_ok "✓ 已建 4-know/research/$n"
  c_warn "⚠ 先填 QUESTION.md 的纳入/排除标准，再开始检索。"
}

# ─────────────────────────────────────────────── vendor
cmd_vendor() {
  local url="$1"
  local name; name="$(basename "$url" .git | tr '[:upper:]' '[:lower:]')"
  local d="$ROOT/_vendor/$name"; exists "$d"
  git clone --depth 50 "$url" "$d" || die "clone 失败"

  # 记录精确版本。只记 URL 不构成可再生性证明——
  # 两年后 clone 同一个 URL 拿到的可能是完全不同的代码。
  local sha tag lic
  sha="$(cd "$d" && git rev-parse --short HEAD 2>/dev/null || echo '?')"
  tag="$(cd "$d" && git describe --tags --exact-match HEAD 2>/dev/null || echo '-')"
  lic='-'
  for f in LICENSE LICENSE.md LICENSE.txt COPYING; do
    if [ -f "$d/$f" ]; then
      lic="$(head -3 "$d/$f" | tr -d '\r' | grep -oiE 'MIT|Apache|BSD|GPL[v0-9.-]*|MPL|ISC|Unlicense' | head -1 || echo '见 '"$f")"
      break
    fi
  done

  local vf="$ROOT/_vendor/VENDOR.md"
  if [ ! -f "$vf" ]; then
    printf '# 第三方代码登记\n\n| 目录 | 上游 | commit | tag | 获取日期 | 许可证 | 留存理由 |\n| --- | --- | --- | --- | --- | --- | --- |\n' > "$vf"
  fi
  printf '| `%s` | %s | `%s` | %s | %s | %s | <填理由> |\n' \
    "$name" "$url" "$sha" "$tag" "$TODAY" "$lic" >> "$vf"

  c_ok "✓ 已 clone 到 _vendor/${name}（commit ${sha}）并登记"
  c_warn "⚠ 去 _vendor/VENDOR.md 补「留存理由」，否则半年后你不敢删它。"
  echo "    恢复命令：git clone $url && cd $name && git checkout $sha"
  echo "    若上游消失会让你痛，它就不该待在 _vendor —— 见 VENDOR.md 的判定表。"
}

# ─────────────────────────────────────────────── infra
cmd_infra() {
  local n="$1"; slug_ok "$n" || die "名字必须小写英文"
  local d="$ROOT/2-infra/$n"; exists "$d"
  mkdir -p "$d/_out"; touch "$d/_out/.gitkeep"
  cat > "$d/README.md" <<EOF
# $n

管什么：

## 凭据

本目录不存明文。引用形如 \`op://Private/$n/<field>\`，
需要随代码走的配置加密成 \`secrets.enc.yaml\`：

\`\`\`bash
sops -e secrets.yaml > secrets.enc.yaml && rm -P secrets.yaml
sops secrets.enc.yaml   # 之后直接编辑
\`\`\`

## 操作

## 巡检输出

写在 \`_out/\`。
EOF
  c_ok "✓ 已建 2-infra/$n"
}
