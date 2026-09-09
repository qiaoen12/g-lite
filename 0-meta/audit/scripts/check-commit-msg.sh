#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# check-commit-msg.sh — 提交语言门禁
#
# 七个入口，一套判断：
#   check-commit-msg.sh <msgfile>            commit-msg 钩子（pre-commit 传消息文件）
#   check-commit-msg.sh --scan <range>       daily 档回扫主线，事后发现
#   check-commit-msg.sh --title <subject> [--against <rev>]
#                                            无副作用：按 main 严格度校验一条标题
#                                            （Squash-Title / PR 标题）。不读暂存区，
#                                            不写仓库。--against 时用 rev...HEAD 的
#                                            文件做 scope 证据，仍不猜测 type/scope。
#   check-commit-msg.sh --scope-valid <s>... scope 词表查询，供 new adr --index 用
#   check-commit-msg.sh --scope-dir <s>      scope → 目录，供受控块定位用
#   check-commit-msg.sh --scope-level <s>    scope → 级别，避免按点号数量猜路径深度
#   check-commit-msg.sh --receive <git-dir> <snapshot-main> <commit> <branch>
#                                            Guard：策略读 snapshot，scope 目录读 commit tree
#
# 「一套」是硬要求，不是省代码。例外判断（自动生成的 merge / revert / fixup
# 消息、enforce_after 之前的历史）如果两个入口各写一份，两份迟早分叉，
# 表现就是钩子放行的提交被审计天天报——而「审计总在报一件你已经决定允许的
# 事」是门禁被整项关掉的标准前奏。所以下面 msg_exempt 只有一个。
#
# 规则全部读自 derived.lock，脚本里不写死任何词表。改规则改 policy.yaml。
# 唯一例外是 scope 白名单：它来自目录树而不是 policy，现场扫，不进 lock。
# ─────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail
export LC_COLLATE=C

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/../../.." && pwd)"
LOCK="$ROOT/0-meta/derived.lock"
RECEIVE_DIR=""
RECEIVE_TREE=""
RECEIVE_LOCK=""
if [ "${1:-}" = --receive ]; then
  [ $# -eq 5 ] || { echo '用法：--receive <git-dir> <snapshot-main> <commit> <branch>' >&2; exit 2; }
  RECEIVE_DIR="$2"
  RECEIVE_TREE="$4"
  RECEIVE_LOCK="$(git --git-dir="$RECEIVE_DIR" show "$3:0-meta/derived.lock")" || exit 2
fi

c_err() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
c_ok()  { printf '\033[32m%s\033[0m\n' "$*"; }

[ -n "$RECEIVE_LOCK" ] || [ -f "$LOCK" ] || { c_err "缺 0-meta/derived.lock —— 先跑 new plan --apply"; exit 2; }

p() {
  if [ -n "$RECEIVE_DIR" ]; then
    awk -F' = ' -v k="$1" '$1==k{sub(/^[^=]* = /,"");print;exit}' <<< "$RECEIVE_LOCK"
  else
    awk -F' = ' -v k="$1" '$1==k{sub(/^[^=]* = /,"");print;exit}' "$LOCK" 2>/dev/null || true
  fi
}

DOMAINS="$(p git.commit.scope_domains)"
NO_UNIT="$(p git.commit.scope_no_unit)"
SKIP_RESERVED="$(p git.commit.scope_skip_reserved)"
ALIASES="$(p git.commit.scope_aliases)"
TYPES_ALL="$(p git.commit.types.all)"
TYPES_UNIVERSAL="$(p git.commit.types.universal)"
SEP="$(p git.commit.multi_scope_separator)"; SEP="${SEP:-,}"
MIN_CHARS="$(p git.commit.desc_min_chars)"; MIN_CHARS="${MIN_CHARS:-1}"
VAGUE_RE="$(p git.commit.main_vague_re)"
AUTOGEN_RE="$(p git.commit.exempt_autogen_re)"
ENFORCE_AFTER="$(p git.commit.enforce_after)"
ALLOW_WIP="$(p git.commit.allow_wip_on_short_lived)"
BRANCH_RE="$(p git.branch.naming_regex)"
MAIN_BRANCH="$(p git.default_branch)"; MAIN_BRANCH="${MAIN_BRANCH:-main}"
SKIP_EMPTY_STAGE="$(p git.commit.skip_path_check_when_empty_stage)"

# ── 例外判断。两个入口共用，只此一份。 ──────────────────────────────────────
# git revert / git merge / git commit --fixup 生成的消息不受提交语言约束：
# 它们不是人写的，拦下来只会逼人加 --no-verify，而 --no-verify 关掉的是
# 密钥搜捕和 git 卫生，代价远大于一条不合规的 revert 标题。
msg_exempt() {
  [ -n "$AUTOGEN_RE" ] || return 1
  printf '%s' "$1" | grep -qE "$AUTOGEN_RE"
}

# UTF-8 字符数。不能用 ${#s}——钩子跑在什么 locale 下不由我们决定，
# LC_ALL=C 时它数的是字节，一个汉字会被当成三个字符。
utf8_len() {
  LC_ALL=C printf '%s' "$1" | LC_ALL=C tr -d '\200-\277' | LC_ALL=C wc -c | tr -d ' '
}

in_list() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# receive 模式只枚举 Git tree 的目录名，不检出或读取业务文件。
scope_child_dirs() {
  local path="$1" row
  if [ -n "$RECEIVE_DIR" ]; then
    while IFS= read -r -d '' row; do
      printf '%s\n' "${row#*$'\t'}"
    done < <(git --git-dir="$RECEIVE_DIR" ls-tree -d -z "${RECEIVE_TREE}:${path}" 2>/dev/null)
  else
    local d
    for d in "$ROOT/$path"/*/; do
      [ ! -L "${d%/}" ] && [ -d "$d" ] || continue
      basename "$d"
    done
  fi
}

# ── scope 白名单：现场从目录树派生 ──────────────────────────────────────────
# 每条记录是 scope \t 实际路径 \t 级别。路径必须在枚举目录时一并保留，不能事后
# 把 scope 里的 `.` 全换成 `/`：命名规则允许目录名本身含点，`code.foo.bar`
# 既可能是一级目录 foo.bar，也可能是分组 foo 里的成员 bar。两者同时存在时，
# scope 本身有歧义，必须拒绝，不能任选一个。
scope_records_of() {
  local domain="$1"
  local src; src="$(p "git.commit.scope_src.$domain")"
  [ -n "$src" ] && [ "$src" != "." ] || return 0
  printf '%s\t%s\t%s\n' "$domain" "$src" "体系级"
  in_list "$domain" "$NO_UNIT" && return 0
  local excl; excl="$(p "git.commit.scope_unit_exclude.$domain")"
  local member_from; member_from="$(p "git.commit.scope_member_from.$domain")"
  local n
  while IFS= read -r n; do
    in_list "$n" "$SKIP_RESERVED" && continue
    in_list "$n" "$excl" && continue
    printf '%s.%s\t%s/%s\t%s\n' "$domain" "$n" "$src" "$n" "单元级"
    [ -n "$member_from" ] || continue
    local mn
    while IFS= read -r mn; do
      in_list "$mn" "$SKIP_RESERVED" && continue
      printf '%s.%s.%s\t%s/%s/%s\t%s\n' "$domain" "$n" "$mn" "$src" "$n" "$mn" "成员级"
    done < <(scope_child_dirs "$src/$n")
  done < <(scope_child_dirs "$src")
}

# 输出实际路径与级别。0 条是不合法，2 条以上是点号造成的歧义。
scope_lookup() {
  local scope="$1"
  local ap; ap="$(p "git.commit.scope_alias.$scope")"
  if [ -n "$ap" ]; then
    local dots lvl
    dots="$(printf '%s' "$scope" | tr -cd '.' | wc -c | tr -d ' ')"
    case "$dots" in
      0) lvl="体系级" ;;
      1) lvl="单元级" ;;
      *) lvl="成员级" ;;
    esac
    printf '%s\t%s\n' "$ap" "$lvl"
    return 0
  fi

  local domain="${scope%%.*}"
  in_list "$domain" "$DOMAINS" || return 1
  local src; src="$(p "git.commit.scope_src.$domain")"
  if [ "$src" = "." ]; then
    [ "$scope" = "$domain" ] || return 1
    printf '.\t体系级\n'
    return 0
  fi

  local rows n
  rows="$(scope_records_of "$domain" | awk -F'\t' -v s="$scope" '$1 == s { print $2 "\t" $3 }')"
  n="$(printf '%s\n' "$rows" | awk 'NF { n++ } END { print n+0 }')"
  [ "$n" -gt 0 ] || return 1
  [ "$n" -eq 1 ] || return 2
  printf '%s\n' "$rows"
}

units_of() {
  local domain="$1"
  scope_records_of "$domain" \
    | awk -F'\t' -v p="$domain." 'index($1, p) == 1 { sub("^" p, "", $1); print $1 }' \
    | sort -u
}

scope_valid() {
  scope_lookup "$1" >/dev/null
}

# 某个 scope 在暂存清单里有没有证据。
# 单向：只问「声明的 scope 有没有对应改动」，不问「所有改动是否都被 scope 覆盖」。
# 边界说明见 policy.yaml 的 scope_path_consistency.boundary。
scope_has_evidence() {
  local scope="$1" files="$2" f
  local ap; ap="$(p "git.commit.scope_alias.$scope")"
  if [ -n "$ap" ]; then
    while IFS= read -r f; do [ "$f" = "$ap" ] && return 0; done <<< "$files"
    return 1
  fi
  local row prefix
  row="$(scope_lookup "$scope")" || return $?
  prefix="${row%%$'\t'*}"

  # repo 的语义是「不属于任何域」，不是「仓库根目录下的文件」——
  # .claude/settings.json 带斜杠但仍是仓库级配置，按后者会漏掉它。
  if [ "$prefix" = "." ]; then
    local dirs="" d
    for d in $DOMAINS; do
      local s; s="$(p "git.commit.scope_src.$d")"
      [ "$s" = "." ] || dirs="$dirs $s"
    done
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      local hit=0
      for d in $dirs; do case "$f" in "$d"/*) hit=1; break ;; esac; done
      [ "$hit" = 0 ] && return 0
    done <<< "$files"
    return 1
  fi

  while IFS= read -r f; do
    case "$f" in "$prefix"|"$prefix"/*) return 0 ;; esac
  done <<< "$files"
  return 1
}

# scope → 目录。决策记录的受控块要落到「干活时读得到」的地方，而
# scope→路径 的映射和 scope_has_evidence 用的是同一份（scope_src + alias），
# 所以放这里，不在 bin/new 里重算一遍。
# 工作区根打印 `.`，调用方自己接。
scope_dir() {
  local scope="$1"
  # 别名绑的是文件（meta.policy → 0-meta/policy.yaml），取它所在目录。
  local ap; ap="$(p "git.commit.scope_alias.$scope")"
  if [ -n "$ap" ]; then dirname "$ap"; return 0; fi

  local row
  row="$(scope_lookup "$scope")" || return $?
  printf '%s\n' "${row%%$'\t'*}"
}

scope_level() {
  local row
  row="$(scope_lookup "$1")" || return $?
  printf '%s\n' "${row#*$'\t'}"
}

types_for_domain() {
  local domain="$1"
  echo "$TYPES_UNIVERSAL $(p "git.commit.types.$domain")"
}

# ── 校验一条 subject ────────────────────────────────────────────────────────
# $1 subject  $2 strict(1=按 main 判)  $3 暂存文件清单（空则跳过 path 一致性）
# 返回 0 通过。错误全部打完再返回，不要一次只报一条——
# 让人改三次才知道有三个问题，第四次就会 --no-verify。
validate_subject() {
  local subject="$1" strict="$2" files="${3:-}" bad=0

  msg_exempt "$subject" && return 0

  if [ "$strict" != 1 ] && [ "$ALLOW_WIP" = true ]; then
    printf '%s' "$subject" | grep -qE '^wip(\([^)]*\))?:' && return 0
  fi

  # 括号里必须是 token(<SEP>token)*：token 非空，不含分隔符与空白。
  # 不限定字符集——unit 名来自目录树，4-know 下允许中文名；「这个 scope 存不存在」
  # 由 scope_valid 回答，这一层只管标点。
  #
  # 标点必须在这里卡死，因为下面的 tr + 词拆分会把 `code.a,`、`code.a code.b`、
  # `code.a,,code.b`、`( )` 一律规整成看起来合法的东西然后放行。
  # 语法写在文档里、门禁却不执行，就是两边分叉的开始。
  local tok="[^${SEP}()[:space:]]+"
  if ! printf '%s' "$subject" | grep -qE "^[a-z]+\(${tok}(${SEP}${tok})*\): .+"; then
    c_err "  ✗ 格式不对：$subject"
    c_err "    要求 $(p git.commit.format)，scope 必填"
    if printf '%s' "$subject" | grep -qE '^[a-z]+: '; then
      c_err "    你写的是没有 scope 的形式。scope 回答「改的是哪一块」，"
      c_err "    形状 $(p git.commit.scope_shape)，例如 code.my-livetranslate、infra.backup"
    elif printf '%s' "$subject" | grep -qE '^[a-z]+\([^)]*\): .+'; then
      c_err "    括号里的 scope 列表不合法：多个 scope 只能用「${SEP}」分隔，"
      c_err "    两侧不留空格，也不留空项。写成 feat(code.a${SEP}infra.b)"
    fi
    return 1
  fi

  local type scopes desc
  type="${subject%%(*}"
  scopes="${subject#*(}"; scopes="${scopes%%)*}"
  desc="${subject#*): }"

  if ! in_list "$type" "$TYPES_ALL"; then
    c_err "  ✗ 未知 type：$type"
    c_err "    全部 type：$TYPES_ALL"
    bad=1
  fi

  local s nscope=0
  for s in $(printf '%s' "$scopes" | tr "$SEP" ' '); do
    [ -n "$s" ] || continue
    nscope=$((nscope+1))
    local scope_rc=0
    scope_valid "$s" || scope_rc=$?
    if [ "$scope_rc" != 0 ]; then
      if [ "$scope_rc" = 2 ]; then
        c_err "  ✗ scope 有歧义：$s"
        c_err "    同一个 scope 同时对应点号目录与分组成员；请重命名其中一个目录。"
        bad=1
        continue
      fi
      c_err "  ✗ scope 不存在：$s"
      local dm="${s%%.*}"
      if in_list "$dm" "$DOMAINS"; then
        local avail; avail="$(units_of "$dm" | tr '\n' ' ')"
        if [ -n "$avail" ]; then
          c_err "    ${dm} 下可用：${avail%% }"
        else
          c_err "    ${dm} 没有可用 unit，只能写裸 ${dm}"
        fi
      else
        c_err "    可用 domain：$DOMAINS"
      fi
      bad=1
      continue
    fi
    local dm="${s%%.*}" legal
    legal="$(types_for_domain "$dm")"
    if ! in_list "$type" "$legal"; then
      c_err "  ✗ type 与 domain 不匹配：${type}(${s})"
      c_err "    ${dm} 的合法 type：$legal"
      c_err "    选 type 看的是「实际改了什么对象」，不是主题词。"
      bad=1
    fi
    if [ -n "$files" ] && ! scope_has_evidence "$s" "$files"; then
      c_err "  ✗ scope 无对应改动：$s"
      c_err "    这次暂存的文件里没有一个落在它的目录下——scope 是不是猜的？"
      bad=1
    fi
  done

  if [ "$nscope" -gt 1 ]; then
    echo "  · 多 scope（${nscope} 个）。默认单 scope，确认这确实是一个不可分割的意图。" >&2
  fi

  local dlen; dlen="$(utf8_len "$desc")"
  if [ "$dlen" -lt "$MIN_CHARS" ]; then
    c_err "  ✗ 描述太短（${dlen} 字，至少 ${MIN_CHARS}）：$desc"
    bad=1
  fi

  if [ "$strict" = 1 ] && [ -n "$VAGUE_RE" ]; then
    local norm
    norm="$(printf '%s' "$desc" | tr '[:upper:]' '[:lower:]' \
            | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[.。!！]*$//')"
    if printf '%s' "$norm" | grep -qE "$VAGUE_RE"; then
      c_err "  ✗ ${MAIN_BRANCH} 上不接受无语义描述：$desc"
      c_err "    判据是整条描述等于空泛词，不是子串——"
      c_err "    「更新 Quest 用户画像结论」是合法的，「更新」不是。"
      bad=1
    fi
  fi

  return "$bad"
}

# ── 入口一：commit-msg 钩子 ─────────────────────────────────────────────────
hook_mode() {
  local msgfile="$1"
  [ -f "$msgfile" ] || { c_err "读不到提交信息文件：$msgfile"; exit 2; }

  # 取第一条非注释、非空行，去掉行尾空白。
  # 用 awk 而不是 while read：后者在最后一行不带换行符时返回非零、循环体不执行，
  # subject 留空，接着被下面「空消息交给 git 自己拒」当成空消息静默放行——
  # 整条消息一个字都没校验。awk 把无换行的末行当成完整记录，没有这个缺口。
  local subject
  subject="$(awk '!/^#/ { sub(/[[:space:]]+$/, ""); if (length($0)) { print; exit } }' "$msgfile")"
  # 空消息交给 git 自己拒（它本来就会）。这里只管非空的。
  [ -n "$subject" ] || exit 0

  local branch strict=1
  branch="$(git -C "$ROOT" symbolic-ref --short HEAD 2>/dev/null || echo '?')"
  if [ "$branch" = "$MAIN_BRANCH" ]; then
    strict=1
  elif [ -n "$BRANCH_RE" ] && printf '%s' "$branch" | grep -qE "$BRANCH_RE"; then
    strict=0
  else
    strict=1
    [ "$branch" = '?' ] || echo "  · 分支名 ${branch} 不符合 ${BRANCH_RE}，按 ${MAIN_BRANCH} 的严格度校验。" >&2
  fi

  local files
  files="$(git -C "$ROOT" -c core.quotePath=false diff --cached --name-only --diff-filter=ACMRD 2>/dev/null || true)"
  # --amend 且没有新增改动时暂存区是空的。给空清单，下游自动跳过 path 一致性，
  # 否则改一句错别字都会被判成「scope 无对应改动」。
  if [ -z "$files" ] && [ "$SKIP_EMPTY_STAGE" != true ]; then
    c_err "  ✗ 暂存区为空，验证不了 scope 与改动是否一致"
    exit 1
  fi

  if validate_subject "$subject" "$strict" "$files"; then
    exit 0
  fi
  echo >&2
  c_err "提交信息不符合提交语言。规则见 0-meta/docs/07-git-工作流.md 第五节。"
  exit 1
}

# ── 入口二：daily 档回扫 ────────────────────────────────────────────────────
# 只校验消息本身，不查 scope-path 一致性——逐条 git show 会让这一项
# 随历史长度线性变慢，而它的价值在于「钩子被绕过时消息还合不合规」。
scan_mode() {
  local range="${1:-}"
  if [ -z "$range" ]; then
    [ -n "$ENFORCE_AFTER" ] || { echo "    （未声明 enforce_after，跳过）"; return 0; }
    git -C "$ROOT" rev-parse --verify -q "$ENFORCE_AFTER" >/dev/null 2>&1 || {
      echo "    （enforce_after=${ENFORCE_AFTER} 在本仓库里找不到，跳过）"; return 0; }
    # 扫 main 而不是 HEAD。回扫永远按 main 的严格度判，而 daily 是定时跑的——
    # 用 HEAD 的话，审计恰好在工作分支上跑起来，就会把分支里合法的 wip:
    # 全部报成主线违规。定时任务不能依赖「跑的时候你在哪个分支」。
    local tip="$MAIN_BRANCH"
    git -C "$ROOT" rev-parse --verify -q "$tip" >/dev/null 2>&1 || tip=HEAD
    range="${ENFORCE_AFTER}..${tip}"
  fi

  local n=0 bad=0 sha subject out
  while IFS=$'\t' read -r sha subject; do
    [ -n "$sha" ] || continue
    n=$((n+1))
    if out="$(validate_subject "$subject" 1 "" 2>&1)"; then
      continue
    fi
    c_err "    ✗ ${sha:0:7}  ${subject}"
    printf '%s\n' "$out" | sed 's/^ */        /' >&2
    bad=$((bad+1))
  done < <(git -C "$ROOT" log --first-parent --format='%H%x09%s' "$range" 2>/dev/null || true)

  if [ "$n" = 0 ]; then
    echo "    ✓ ${range} 区间内没有新提交"
  elif [ "$bad" = 0 ]; then
    c_ok "    ✓ ${n} 条主线提交全部符合提交语言"
  else
    c_err "    ⚠ ${n} 条里有 ${bad} 条不符合（多半是 --no-verify 绕过的）"
    return 1
  fi
}

# ── 入口三：Squash-Title / PR 标题 ──────────────────────────────────────────
# 按 main 的严格度校验一条已写好的标题。机械脚本只判，不猜 type/scope。
# 自动生成前缀（Merge / Revert / fixup!）在钩子里是例外，在这里必须拒绝——
# 它们不能当进 main 的 squash 标题。
title_mode() {
  local subject="$1" against="${2:-}" files=""
  [ -n "$subject" ] || {
    c_err "用法：check-commit-msg.sh --title <subject> [--against <rev>]"
    exit 2
  }

  if msg_exempt "$subject"; then
    c_err "  ✗ 自动生成标题不能作为 Squash-Title：$subject"
    exit 1
  fi

  if [ -n "$against" ]; then
    git -C "$ROOT" rev-parse --verify -q "${against}^{commit}" >/dev/null 2>&1 || {
      c_err "  ✗ --against 不是可解析的提交：${against}"
      exit 2
    }
    files="$(git -C "$ROOT" -c core.quotePath=false diff --name-only --diff-filter=ACMRD \
      "${against}...HEAD" 2>/dev/null || true)"
  fi

  if validate_subject "$subject" 1 "$files"; then
    exit 0
  fi
  echo >&2
  c_err "标题不符合提交语言。规则见 0-meta/docs/07-git-工作流.md 第五节。"
  exit 1
}

# ── 入口四至六：scope 词表查询 ──────────────────────────────────────────────
# 决策记录（4-know/decision/）的 scope 用的是同一套词表，判据必须在这里。
# 在 bin/new 里再写一份的话，两份迟早分叉，表现是 new adr --index 认为合法的
# scope 被 daily 审计报成非法——而这正是 dataset_scan 那段注释在防的事。
#
# --scope-valid  打印不合法或有歧义的那些（每行一个），全合法则无输出、退出 0
# --scope-dir    打印一个 scope 对应的目录
# --scope-level  打印一个 scope 对应的体系级 / 单元级 / 成员级
scope_valid_mode() {
  [ $# -gt 0 ] || { c_err "用法：check-commit-msg.sh --scope-valid <scope>..."; exit 2; }
  local s bad=0
  for s in "$@"; do
    scope_valid "$s" || { printf '%s\n' "$s"; bad=1; }
  done
  return "$bad"
}

scope_dir_mode() {
  local s="${1:-}"
  [ -n "$s" ] || { c_err "用法：check-commit-msg.sh --scope-dir <scope>"; exit 2; }
  local out rc=0
  out="$(scope_dir "$s")" || rc=$?
  case "$rc" in
    0) printf '%s\n' "$out" ;;
    1) c_err "不是合法 scope：$s"; exit 1 ;;
    2) c_err "scope 有歧义：$s"; exit 1 ;;
    *) exit "$rc" ;;
  esac
}

scope_level_mode() {
  local s="${1:-}"
  [ -n "$s" ] || { c_err "用法：check-commit-msg.sh --scope-level <scope>"; exit 2; }
  local out rc=0
  out="$(scope_level "$s")" || rc=$?
  case "$rc" in
    0) printf '%s\n' "$out" ;;
    1) c_err "不是合法 scope：$s"; exit 1 ;;
    2) c_err "scope 有歧义：$s"; exit 1 ;;
    *) exit "$rc" ;;
  esac
}

case "${1:-}" in
  --receive)
    _receive_subject="$(git --git-dir="$RECEIVE_DIR" show -s --format=%s "$RECEIVE_TREE")" || exit 2
    [ -n "$_receive_subject" ] || { c_err '提交信息为空'; exit 1; }
    _receive_files="$(git --git-dir="$RECEIVE_DIR" -c core.quotePath=false diff-tree \
      --root --no-commit-id --name-only --no-renames -r "$RECEIVE_TREE")" || exit 2
    _receive_strict=1
    if [ "$5" != "$MAIN_BRANCH" ] && [ -n "$BRANCH_RE" ] \
        && printf '%s' "$5" | grep -qE "$BRANCH_RE"; then
      _receive_strict=0
    fi
    validate_subject "$_receive_subject" "$_receive_strict" "$_receive_files"
    ;;
  --scan)        shift; scan_mode "${1:-}" ;;
  --title)
    shift
    _title_subject="${1:-}"
    [ -n "$_title_subject" ] || { c_err "用法：check-commit-msg.sh --title <subject> [--against <rev>]"; exit 2; }
    shift || true
    _title_against=""
    if [ "${1:-}" = "--against" ]; then
      shift
      _title_against="${1:-}"
      [ -n "$_title_against" ] || { c_err "用法：check-commit-msg.sh --title <subject> [--against <rev>]"; exit 2; }
      shift || true
    fi
    [ $# -eq 0 ] || { c_err "用法：check-commit-msg.sh --title <subject> [--against <rev>]"; exit 2; }
    title_mode "$_title_subject" "$_title_against"
    ;;
  --scope-valid) shift; scope_valid_mode "$@" ;;
  --scope-dir)   shift; scope_dir_mode "${1:-}" ;;
  --scope-level) shift; scope_level_mode "${1:-}" ;;
  '')     c_err "用法：check-commit-msg.sh <msgfile> | --scan [range] | --title <subject> [--against <rev>] | --scope-valid <scope>... | --scope-dir <scope> | --scope-level <scope>"; exit 2 ;;
  *)      hook_mode "$1" ;;
esac
