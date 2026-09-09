# 数据集扫描与索引。生成器和审计 dataset_links 共用 dataset_scan。
# 由 0-meta/bin/new 加载，不要单独执行。

# ─────────────────────────────────────────────── DATASET.md 归属声明
#
# 采集端与应用端是多对多：一个采集器能产出多个数据集，一份数据能被多个项目引用，
# 还存在只有一端甚至两端皆空的情况。这种关系塞不进目录名——名字只有一个位置。
#
# 所以分工是：目录名承载导航（主应用端，一眼可见但只是近似），
# frontmatter 承载事实（完整、精确），INDEX.md 由 frontmatter 生成，提供反向查询。
# 索引必须是生成的：手写清单会漂移，这一点 backup 和 sync 已经各证明过一次。
#
# 下面不是通用 YAML 解析器，只认本工作区约定的这三个键。需要更复杂的结构时改格式，
# 不要在这里加解析能力——半吊子的解析器会在别人写出合法 YAML 时静默给错答案。
#
# 而「静默」是这里唯一不能接受的失败方式，所以 fm_form 负责先判形态：
# 合法 YAML 但不合本工作区约定（典型是行内列表 `consumers: [a, b]`）要被大声拒绝，
# 不能像上一版那样解析成 0 项、让索引少一行而没有任何人知道。

# 扫一遍全部数据集的归属声明，把结果写进 $1 目录下四个文件：
#   producers  类型 \t 说明 \t 数据集
#   consumers  应用端 \t 数据集
#   rows       数据集 \t 主应用端 \t 采集端数 \t 应用端数
#   warn       数据集 \t 问题描述
#
# 全部判据只有这一份实现，生成器和审计 dataset_links 共用。上一版两边各写了一遍
# 「缺 frontmatter / 留着占位符 / 两端皆空」——两份判据迟早分叉，
# 表现是审计报一件生成器不认为有问题的事，然后没人知道该信哪个。
# 返回值恒为 0：这里只负责陈述事实，判决权归调用方（生成器写进索引，审计打告警）。
dataset_scan() {
  local dir="$1"
  : > "$dir/producers"; : > "$dir/consumers"; : > "$dir/rows"; : > "$dir/warn"

  local types; types="$(policy_get data.producer_types)"
  [ -n "$types" ] || types="code external manual pipeline"

  local d n f prim clist form item k v np nc nrp nrc todo
  for d in "$ROOT"/3-data/*/; do
    [ -d "$d" ] || continue
    n="$(basename "$d")"; f="$d/DATASET.md"
    if [ ! -f "$f" ]; then
      printf '%s\t%s\n' "$n" "缺 DATASET.md" >> "$dir/warn"; continue
    fi
    if [ -z "$(fm_block "$f")" ]; then
      printf '%s\t%s\n' "$n" "DATASET.md 没有 frontmatter，采集端与应用端无从得知" >> "$dir/warn"
      printf '%s\t%s\t%s\t%s\n' "$n" "未声明" "?" "?" >> "$dir/rows"; continue
    fi

    # dataset 字段没有任何程序在消费——索引用的是目录名。不校验它，
    # 它就是一行随时会开始说谎的注释，而改目录名时最容易漏的恰好是它。
    # 字段整个缺失也要报：只查「非空且不相等」等于给「干脆不写」开一道后门。
    v="$(fm_scalar "$f" dataset)"
    if [ -z "$v" ]; then
      printf '%s\t%s\n' "$n" "frontmatter 缺 dataset 字段" >> "$dir/warn"
    elif [ "$v" != "$n" ]; then
      printf '%s\t%s\n' "$n" "frontmatter 写的 dataset: $v 与目录名不一致" >> "$dir/warn"
    fi

    todo=0; np=0; nc=0; nrp=0; nrc=0

    form="$(fm_form "$f" producers)"
    case "$form" in
      block|empty) ;;
      absent) printf '%s\t%s\n' "$n" "frontmatter 缺 producers" >> "$dir/warn" ;;
      *)      printf '%s\t%s\n' "$n" "producers 是$(fm_form_zh "$form")，只认 [] 或块式列表（每项一行、以 - 开头）" >> "$dir/warn" ;;
    esac
    if [ "$form" = block ]; then
      while IFS= read -r item; do
        [ -n "$item" ] || continue
        nrp=$((nrp+1))
        # 模板占位符不算声明。不挡住它的话，new data 建出来的空壳能直接过审计，
        # 而「审计绿了但什么都没声明」比没有这项检查更糟。
        case "$item" in *'<'*'>'*) todo=1; continue ;; esac
        k="${item%%:*}"; v="${item#*:}"; v="${v# }"
        if [ "$k" = "$item" ]; then
          printf '%s\t%s\n' "$n" "producers 的「${item}」缺类型前缀，应写成 <类型>: <说明>" >> "$dir/warn"; continue
        fi
        # 说明为空的话，索引「从采集端找数据」那张表会多出一行空白主键——
        # policy 写了「每项形如 <类型>: <说明>」，不查就等于 policy 在说一件没人保证的事。
        if [ -z "$v" ]; then
          printf '%s\t%s\n' "$n" "producers 的「${k}」没写说明，应写成 <类型>: <说明>" >> "$dir/warn"; continue
        fi
        case " $types " in
          *" $k "*) ;;
          # 中文标点紧跟变量名时必须用 ${} 定界：bash 会把多字节字符的首字节
          # 当成标识符的一部分，set -u 下直接炸成 unbound variable。
          *) printf '%s\t%s\n' "$n" "producers 的类型「${k}」不在允许集合内（${types}）" >> "$dir/warn"; continue ;;
        esac
        printf '%s\t%s\t%s\n' "$k" "$v" "$n" >> "$dir/producers"; np=$((np+1))
      done < <(fm_list "$f" producers)
      # 声明成块式却一项都没有。典型写法是把 `- ` 漏了、写成了映射：
      #     producers:
      #       code: collector
      # 这在 YAML 里合法，但这里的解析器只认 `- ` 开头的项，会读成 0 项——
      # 而「读成空」恰好是这一整套校验要消灭的失败方式。空列表必须显式说出来。
      [ "$nrp" != 0 ] || printf '%s\t%s\n' "$n" "producers 声明成块式却没有任何 - 项；空列表要显式写成 []" >> "$dir/warn"
    fi

    form="$(fm_form "$f" consumers)"
    case "$form" in
      block|empty) ;;
      absent) printf '%s\t%s\n' "$n" "frontmatter 缺 consumers" >> "$dir/warn" ;;
      *)      printf '%s\t%s\n' "$n" "consumers 是$(fm_form_zh "$form")，只认 [] 或块式列表（每项一行、以 - 开头）" >> "$dir/warn" ;;
    esac
    clist=""
    if [ "$form" = block ]; then
      clist="$(fm_list "$f" consumers)"
      while IFS= read -r item; do
        [ -n "$item" ] || continue
        nrc=$((nrc+1))
        case "$item" in *'<'*'>'*) todo=1; continue ;; esac
        # 路径存在性。同 new worktree 对 --path 的处理：打错一个字，
        # sparse-checkout 会静默通过并给你一个空工作区，这里则给你一条死链索引，
        # 而索引存在的全部意义就是「读一个文件就知道去哪」。
        [ -d "$ROOT/$item" ] || printf '%s\t%s\n' "$n" "consumers 里的 $item 在工作区里不存在" >> "$dir/warn"
        printf '%s\t%s\n' "$item" "$n" >> "$dir/consumers"; nc=$((nc+1))
      done < <(printf '%s\n' "$clist")
      [ "$nrc" != 0 ] || printf '%s\t%s\n' "$n" "consumers 声明成块式却没有任何 - 项；空列表要显式写成 []" >> "$dir/warn"
    fi

    prim="$(fm_scalar "$f" primary_consumer)"
    case "$prim" in null|''|*'<'*'>'*) prim="—" ;; esac
    # 多个应用端地位平等时 primary_consumer 填 null（目录名走 shared- 前缀），
    # 所以这里只在它非空时要求它是 consumers 的成员。管道会被 grep -q 提前关掉，
    # pipefail 下那会变成假失败，所以用纯 bash 的子串匹配。
    if [ "$prim" != "—" ]; then
      case $'\n'"$clist"$'\n' in
        *$'\n'"$prim"$'\n'*) ;;
        *) printf '%s\t%s\n' "$n" "primary_consumer（${prim}）不在 consumers 里" >> "$dir/warn" ;;
      esac
    fi

    printf '%s\t%s\t%s\t%s\n' "$n" "$prim" "$np" "$nc" >> "$dir/rows"
    if [ "$todo" = 1 ]; then
      printf '%s\t%s\n' "$n" "frontmatter 还留着模板占位符，等于没声明" >> "$dir/warn"
    elif [ "$np" = 0 ] && [ "$nc" = 0 ]; then
      printf '%s\t%s\n' "$n" "两端皆空：没有采集端说明来路不明，没有应用端说明没人用——它该进 _inbox" >> "$dir/warn"
    fi
  done
  return 0
}

# 从 dataset_scan 的结果渲染索引全文到 $1。纯函数，不碰目标文件——
# 审计要拿它的输出和磁盘上的 INDEX.md 做全文件比较，所以渲染和落盘必须分开。
dataset_index_render() {
  local dst="$1" dir="$2"
  {
    echo "# 3-data 索引"
    echo
    echo "由 \`new data --index\` 生成，**不要手改**。事实源是各个 \`DATASET.md\` 的 frontmatter。"
    echo
    echo "\`new check\` 会重新渲染一遍并与本文件逐字节比较，改了声明没重算、或手改过本文件，都会报出来。"
    echo
    echo "## 从项目找数据"
    echo
    echo "「我在做 X，需要哪份数据」——绝大多数查询是这个方向，所以放在最前面。"
    echo
    echo "| 应用端 | 数据集 |"
    echo "| --- | --- |"
    if [ -s "$dir/consumers" ]; then
      sort -u "$dir/consumers" | awk -F'\t' '{a[$1]=a[$1] (a[$1]?"、":"") "`" $2 "`"} END{for(k in a) print k "\t" a[k]}' \
        | sort | awk -F'\t' '{print "| " $1 " | " $2 " |"}'
    else
      echo "| （无声明） |  |"
    fi
    echo
    echo "## 从采集端找数据"
    echo
    echo "同一个采集器产出多份数据时，这张表能看出它的全部产出。"
    echo
    echo "| 采集端 | 类型 | 数据集 |"
    echo "| --- | --- | --- |"
    if [ -s "$dir/producers" ]; then
      sort -u "$dir/producers" | awk -F'\t' '{key=$2 "\t" $1; a[key]=a[key] (a[key]?"、":"") "`" $3 "`"} END{for(k in a) print k "\t" a[k]}' \
        | sort | awk -F'\t' '{print "| " $1 " | " $2 " | " $3 " |"}'
    else
      echo "| （无声明） |  |  |"
    fi
    echo
    echo "## 全部数据集"
    echo
    echo "| 数据集 | 主应用端 | 采集端 | 应用端 |"
    echo "| --- | --- | --: | --: |"
    if [ -s "$dir/rows" ]; then
      sort "$dir/rows" | awk -F'\t' '{print "| `" $1 "` | " $2 " | " $3 " | " $4 " |"}'
    fi
    if [ -s "$dir/warn" ]; then
      echo
      echo "## 需要处理"
      echo
      sort "$dir/warn" | awk -F'\t' '{print "- `" $1 "` " $2}'
    fi
  } > "$dst"
}

cmd_data_index() {
  local out="$ROOT/3-data/INDEX.md" dir tmp
  tmp_mkd dir dsindex
  # 上一版直接 `} > INDEX.md`，中途中断会留下一份残缺索引——
  # 而残缺索引比没有索引更糟，它看起来是权威的。
  atomic_tmp tmp "$out"

  dataset_scan "$dir"
  dataset_index_render "$tmp" "$dir"

  local nds; nds="$(wc -l < "$dir/rows" | tr -d ' ')"
  if atomic_install "$tmp" "$out"; then
    c_ok "✓ 已重算 3-data/INDEX.md（$nds 个数据集）"
  else
    c_ok "✓ 3-data/INDEX.md 已是最新（$nds 个数据集）"
  fi

  if [ -s "$dir/warn" ]; then
    c_warn "⚠ 有需要处理的条目，见 INDEX.md 末节："
    sort "$dir/warn" | awk -F'\t' '{print "    · " $1 "：" $2}'
  fi
  tmp_rmd "$dir"
}
