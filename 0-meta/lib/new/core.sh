# new 的共享核心：路径、policy、临时文件、原子写入。
# 由 0-meta/bin/new 加载，不要单独执行。

c_ok()   { printf '\033[32m%s\033[0m\n' "$*"; }
# 告警要被计数。原先 check 的判决行只看硬失败，于是一轮里刷过十条黄字、
# 最后仍然打绿色「自查通过」——一个会替你消化告警的判决行，等于把告警删掉。
WARN_N=0
c_warn() { WARN_N=$((WARN_N+1)); printf '\033[33m%s\033[0m\n' "$*"; }
# 最后一条错误留在 LAST_ERR：入口结束时度量用它当 detail。
# die 的消息另记 DIE_MSG，优先级更高。reason_code 由 err_code / die_code 写入
# METRICS_REASON_CODE；裸 c_err / die 不改这个变量，避免收尾句盖掉具体故障码。
LAST_ERR=""
DIE_MSG=""
METRICS_REASON_CODE=""
metrics_record_field() {
  # metrics.sh 在 task.sh/core.sh 之后加载；运行时再探测，避免把核心
  # 原语绑死在可选的本机度量实现上。metrics_set 会把值同步到 state file，
  # 因而 $(...) 子 shell 中产生的失败归因也能被最终 EXIT trap 读回。
  if [ "$(type -t metrics_set 2>/dev/null)" = function ]; then
    metrics_set "$1" "$2" || true
  fi
}

c_err()  { LAST_ERR="$*"; metrics_record_field last_error "$*"; printf '\033[31m%s\033[0m\n' "$*" >&2; }
die()    { DIE_MSG="$*"; metrics_record_field die_message "$*"; c_err "$*"; exit 1; }
err_code() { METRICS_REASON_CODE="$1"; metrics_record_field reason_code "$1"; shift; c_err "$@"; }
die_code() { METRICS_REASON_CODE="$1"; metrics_record_field reason_code "$1"; shift; die "$@"; }

slug_ok() { [[ "$1" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; }
exists()  { if [ -e "$1" ]; then die "已存在：$1"; fi; return 0; }
ymd_valid() {
  local d="$1" parsed
  parsed="$(date -j -f '%Y-%m-%d' "$d" '+%Y-%m-%d' 2>/dev/null \
    || date -d "$d" '+%Y-%m-%d' 2>/dev/null \
    || true)"
  [ "$parsed" = "$d" ]
}

# 原子替换要求临时文件与目标同目录（跨文件系统的 mv 是复制，不是 rename），
# 于是临时文件落在进 git 的目录里。RETURN 陷阱管不了异常退出——set -u 的致命
# 错误、Ctrl-C、kill 都不跑它，实测就漏过 .INDEX.md.XXXXXX 在 3-data/ 里。
# 所以树内临时文件登记到 TMPS，退出路径统一兜底。
#
# 登记必须在调用方做：$(...) 是子 shell，在里面改 TMPS 改的是副本，父 shell 看不到。
# 信号档要显式 exit——信号陷阱跑完会继续往下执行，不像 EXIT。
TMPS=""
TMPDIRS=""
tmp_cleanup() {
  [ -z "$TMPS" ] || rm -f $TMPS
  [ -z "$TMPDIRS" ] || rm -rf $TMPDIRS
  return 0
}

tmp_unregister() {
  local f="$1" out="" x
  for x in $TMPS; do
    [ "$x" = "$f" ] || out="$out $x"
  done
  TMPS="${out# }"
}

# 在目标同目录建空临时文件，并在当前 shell 登记到 TMPS。
# 用法：atomic_tmp <变量名> <目标路径>。不要用 $(atomic_tmp ...)——
# 命令替换是子 shell，里面改 TMPS 父进程看不见（见上方登记注释）。
atomic_tmp() {
  local _at_dest="$1" _at_target="$2" _at_t
  _at_t="$(mktemp "$(dirname "$_at_target")/.$(basename "$_at_target").XXXXXX")" || return 1
  TMPS="$TMPS $_at_t"
  eval "$_at_dest=\"\$_at_t\""
}

atomic_abort() {
  local tmp="$1"
  rm -f "$tmp"
  tmp_unregister "$tmp"
}

# 失败不碰目标：先写完临时文件，再 rename。
atomic_commit() {
  local tmp="$1" target="$2"
  chmod 0644 "$tmp"
  mv "$tmp" "$target"
  tmp_unregister "$tmp"
}

# 内容有变则替换并返回 0；与目标相同则丢掉临时文件并返回 1。
atomic_install() {
  local tmp="$1" target="$2"
  if [ -f "$target" ] && cmp -s "$tmp" "$target"; then
    atomic_abort "$tmp"
    return 1
  fi
  atomic_commit "$tmp" "$target"
}

# 用法：tmp_mkd <变量名> [前缀]。同样不能包在 $(... ) 里。
tmp_mkd() {
  local _td_dest="$1" _td_t
  _td_t="$(mktemp -d -t "${2:-new}.XXXXXX")" || return 1
  TMPDIRS="$TMPDIRS $_td_t"
  eval "$_td_dest=\"\$_td_t\""
}

tmp_rmd() {
  local d="$1" out="" x
  rm -rf "$d"
  for x in $TMPDIRS; do
    [ "$x" = "$d" ] || out="$out $x"
  done
  TMPDIRS="${out# }"
}

LOCK="$ROOT/0-meta/derived.lock"
DERIVE="$ROOT/0-meta/audit/scripts/derive-paths.sh"

# 取 lock 文件里某个键的值
lock_get() { awk -F' = ' -v k="$2" '$1==k{sub(/^[^=]* = /,"");print;exit}' "$1" 2>/dev/null || true; }

# ─────────────────────────────────────────────── git 公共
# 脚本从 derived.lock 读策略，不从自己的常量读。
# derived.lock 由 policy.yaml 推导，plan_staleness 保证两者同步——
# 所以「改 policy 就改行为」这条闭环在这里成立，无需在脚手架里解析 YAML。
policy_get() { lock_get "$LOCK" "$1"; }

GIT_MODE_CACHE=""
git_mode() {
  if [ -z "$GIT_MODE_CACHE" ]; then
    GIT_MODE_CACHE="$(policy_get git.mode)"
    [ -n "$GIT_MODE_CACHE" ] || GIT_MODE_CACHE="monorepo"
  fi
  echo "$GIT_MODE_CACHE"
}

# 根仓库的顶层目录。不在仓库里则返回空。
repo_top() { git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null || true; }
in_repo()  { [ -n "$(repo_top)" ]; }
is_sparse_worktree() {
  in_repo || return 1
  [ "$(git -C "$ROOT" config --bool core.sparseCheckout 2>/dev/null || true)" = true ]
}

# worktree 根目录（绝对路径）。policy 里写的是相对 ROOT 的路径。
worktree_root() {
  local r; r="$(policy_get git.worktree.root)"
  [ -n "$r" ] || r="../worktrees"
  case "$r" in
    /*) echo "$r" ;;
    *)  (cd "$ROOT" && cd "$(dirname "$r")" 2>/dev/null && echo "$PWD/$(basename "$r")") \
          || echo "$ROOT/$r" ;;
  esac
}

default_branch() { local b; b="$(policy_get git.default_branch)"; echo "${b:-main}"; }

# 集合差：在 $1 里但不在 $2 里的元素
set_minus() {
  local out=""
  for x in $1; do
    case " $2 " in *" $x "*) ;; *) out="$out $x" ;; esac
  done
  echo "${out# }"
}

# 本工作区约定的 frontmatter 读取。不是通用 YAML 解析器：
# 合法 YAML 但不合约定（典型是行内列表）必须被大声拒绝，不能静默读成 0 项。
fm_block()  { awk 'NR==1 && $0=="---" {f=1;next} f && $0=="---" {exit} f' "$1" 2>/dev/null; }
fm_scalar() { fm_block "$1" | awk -v k="$2" '$0 ~ "^"k":" {sub(/^[^:]*:[[:space:]]*/,""); print; exit}'; }
fm_list()   {
  fm_block "$1" | awk -v k="$2" '
    $0 ~ "^"k":[[:space:]]*\\[\\]"          { exit }
    $0 ~ "^"k":[[:space:]]*(#.*)?$"         { inl=1; next }
    inl && /^[[:space:]]+-[[:space:]]/      { sub(/^[[:space:]]*-[[:space:]]*/,""); print; next }
    inl && /^[^[:space:]#]/                 { exit }
  '
}

# 某个键的书写形态：absent / empty / block / inline / scalar。
# 只有 empty 与 block 是本工作区认的，其余两种由调用方报出来。
fm_form() {
  fm_block "$1" | awk -v k="$2" '
    $0 ~ "^"k":" {
      rest = $0
      sub(/^[^:]*:[[:space:]]*/, "", rest)
      sub(/[[:space:]]+#.*$/, "", rest)
      if      (rest == "")           print "block"
      else if (rest == "[]")         print "empty"
      else if (rest ~ /^\[.*\]$/)    print "inline"
      else                           print "scalar"
      found = 1; exit
    }
    END { if (!found) print "absent" }
  '
}

fm_form_zh() {
  case "$1" in
    inline) echo "行内列表（[a, b]）" ;;
    scalar) echo "标量" ;;
    *)      echo "$1" ;;
  esac
}

# 对比新旧 lock，报出必须人工确认的变更
plan_danger() {
  local old="$1" new="$2" n=0
  local o c

  o="$(lock_get "$old" backup.include)"; c="$(lock_get "$new" backup.include)"
  local dropped; dropped="$(set_minus "$o" "$c")"
  if [ -n "$dropped" ]; then c_err "  ⚠ 危险：域 [$dropped] 退出冷备"; n=$((n+1)); fi

  o="$(lock_get "$old" sync.include)"; c="$(lock_get "$new" sync.include)"
  local added; added="$(set_minus "$c" "$o")"
  if [ -n "$added" ]; then c_err "  ⚠ 危险：域 [$added] 新进入热同步"; n=$((n+1)); fi

  o="$(lock_get "$old" backup.keep.reserved)"; c="$(lock_get "$new" backup.keep.reserved)"
  dropped="$(set_minus "$o" "$c")"
  if [ -n "$dropped" ]; then c_err "  ⚠ 危险：保留名 [$dropped] 不再备份"; n=$((n+1)); fi

  o="$(lock_get "$old" secrets.deny_glob_count)"; c="$(lock_get "$new" secrets.deny_glob_count)"
  if [ -n "$o" ] && [ -n "$c" ] && [ "$c" -lt "$o" ] 2>/dev/null; then
    c_err "  ⚠ 危险：密钥拦截模式从 $o 条减到 $c 条"; n=$((n+1))
  fi

  o="$(lock_get "$old" audit.hard_fail)"; c="$(lock_get "$new" audit.hard_fail)"
  dropped="$(set_minus "$o" "$c")"
  if [ -n "$dropped" ]; then c_err "  ⚠ 危险：审计项 [$dropped] 由硬失败降级"; n=$((n+1)); fi

  for d in 5-record 3-data; do
    o="$(lock_get "$old" "ai_access.$d")"; c="$(lock_get "$new" "ai_access.$d")"
    if [ "$o" = "deny" ] && [ "$c" != "deny" ]; then
      c_err "  ⚠ 危险：$d 的 AI 访问由 deny 放宽为 $c"; n=$((n+1))
    fi
  done

  # git 段。改 mode 会同时改变 new code 的行为和全部跟踪范围，
  # 而把某个域移出 never 名单，等于允许 5-record 或 _raw 进 git——
  # 这类错误一旦提交就要 filter-repo 重写历史，必须在应用前拦下。
  o="$(lock_get "$old" git.mode)"; c="$(lock_get "$new" git.mode)"
  if [ -n "$o" ] && [ "$o" != "$c" ]; then
    c_err "  ⚠ 危险：git.mode 由 $o 改为 $c —— new code 行为与跟踪范围会同时变"; n=$((n+1))
  fi

  o="$(lock_get "$old" git.never_domains)"; c="$(lock_get "$new" git.never_domains)"
  dropped="$(set_minus "$o" "$c")"
  if [ -n "$dropped" ]; then c_err "  ⚠ 危险：域 [$dropped] 由「永不进 git」变为可进 git"; n=$((n+1)); fi

  o="$(lock_get "$old" git.never_reserved)"; c="$(lock_get "$new" git.never_reserved)"
  dropped="$(set_minus "$o" "$c")"
  if [ -n "$dropped" ]; then c_err "  ⚠ 危险：保留名 [$dropped] 由「永不进 git」变为可进 git"; n=$((n+1)); fi

  # 人恢复丢了离机来源 = 口令又锁回本机。机器取值改成本机（keychain）是刻意的，
  # 不在这里拦；recovery 变空或只剩 keychain/file 才是危险变更。
  c="$(lock_get "$new" backup.password_recovery_gap)"
  if [ -n "$c" ]; then
    c_err "  ⚠ 危险：backup.password_recovery 没有本机之外的来源"
    n=$((n+1))
  fi

  return "$n"
}

# ─────────────────────────────────────────────── AGENTS.md 的提交语言受控块
#
# 根 AGENTS.md 是**唯一**需要复制词表的地方。policy 自己声明 Codex 与
# WorkBuddy 的 adapter enforced:false —— 对它们而言 layer 2 是空的，
# AGENTS.md 就是它们能看到的全部规则。但复制一份手维护的词表必然漂移，
# 所以这块由 new plan --apply 生成，plan_staleness 顺带校验它没被改脏。
AGENTS_MD="$ROOT/AGENTS.md"
CC_BEGIN='<!-- BEGIN commit-convention (generated by new plan) -->'
CC_END='<!-- END commit-convention -->'

# 把空格分隔的清单包成 `a` `b` `c`。
# 直接在 echo 里拼反引号很容易被引号层数坑到（单引号里的 \` 是字面反斜杠），
# 所以统一走这个函数。
_bt() {
  local x out=""
  for x in $1; do out="$out\`$x\` "; done
  printf '%s' "${out% }"
}

commit_block_content() {
  local d t a

  echo "格式 \`$(policy_get git.commit.format)\`。**type 是动作，scope 是对象，两者正交，scope 必填。**"
  echo
  echo "不要再把 infra / data / know / research / meta 当 type，它们是 scope 的 domain。"
  echo
  echo "**scope** 形状 \`$(policy_get git.commit.scope_shape)\`。unit 从目录树实时派生，"
  echo "跳过保留名（$(_bt "$(policy_get git.commit.scope_skip_reserved)")）。"
  echo
  echo "| domain | 目录 | 说明 |"
  echo "| --- | --- | --- |"
  for d in $(policy_get git.commit.scope_domains); do
    local note=""
    case " $(policy_get git.commit.scope_no_unit) " in
      *" $d "*) note="不派生 unit，只用裸 domain" ;;
    esac
    [ "$d" = repo ] && note="不派生 unit；指「不属于任何域」"
    echo "| \`$d\` | \`$(policy_get "git.commit.scope_src.$d")\` | $note |"
  done
  echo
  echo "另有绑定实际路径的语义 scope："
  for a in $(policy_get git.commit.scope_aliases); do
    printf -- '- `%s` → `%s`\n' "$a" "$(policy_get "git.commit.scope_alias.$a")"
  done
  echo
  echo "**type** 的合法集合按 scope 所属 domain 限定，实际可用 = 全域通用 + 本域那组："
  echo
  echo "| scope domain | 合法 type |"
  echo "| --- | --- |"
  echo "| 全域通用 | $(_bt "$(policy_get git.commit.types.universal)") |"
  for d in $(policy_get git.commit.scope_domains); do
    echo "| \`$d\` | $(_bt "$(policy_get "git.commit.types.$d")") |"
  done
  echo
  for t in $(policy_get git.commit.types.all | tr ' ' '\n' | sort -u); do
    printf -- '- `%s` — %s\n' "$t" "$(policy_get "git.commit.type_glossary.$t")"
  done
  echo
  echo "选 type 看**实际被修改的对象**，不看主题词。改翻译程序的代码是"
  echo "\`feat(code.x)\` 而不是 \`translate(code.x)\`；\`translate\` 只用于真的翻译数据内容。"
  echo "整理代码是 \`refactor\`，整理数据才是 \`clean\`。能用领域专属 type 就不要用 \`chore\`。"
  echo
  echo "**粒度**：一个 commit = 一个可以独立理解、验证、回滚的单一意图。多个文件共同"
  echo "完成一个目标可以是一条；同一个文件里两个不相关的意图要拆成两条。"
  echo "默认单 scope；只有不可分割的意图确实跨多个 scope 且共用同一个 type 时才用"
  echo "\`$(policy_get git.commit.multi_scope_separator)\` 分隔。"
  echo
  echo "**位置**：工作分支可以有阶段性提交（\`wip:\` 放行）。"
  echo "\`$(policy_get git.default_branch)\` 上只接受完整、可验证、可独立回滚的正式提交，"
  echo "整条描述等于空泛词会被拒（判据是整条相等，不是子串）。"
  echo
  echo "**分支前缀**与 scope domain 是同一份词表：\`$(policy_get git.branch.naming_regex)\`。"
  echo "分支回答「属于哪块」，提交 type 回答「什么性质」。"
  echo
  echo "事实源是 \`0-meta/policy.yaml\` 的 \`git.commit\` 段，本块由 \`new plan --apply\` 生成。"
  echo "完整说明见 [\`0-meta/docs/07-git-工作流.md\`](0-meta/docs/07-git-工作流.md) 第五节。"
}

extract_commit_block() {
  awk -v b="$CC_BEGIN" -v e="$CC_END" '$0==e{f=0} f{print} $0==b{f=1}' "$1" 2>/dev/null || true
}

write_commit_block() {
  [ -f "$AGENTS_MD" ] || { c_warn "  ⚠ 找不到 $AGENTS_MD"; return 0; }
  if ! grep -qF "$CC_BEGIN" "$AGENTS_MD"; then
    c_warn "  ⚠ 根 AGENTS.md 里没有受控块标记，跳过生成"
    return 0
  fi
  local body tmp
  body="$(mktemp -t ccblock.XXXXXX)"; TMPS="$TMPS $body"
  atomic_tmp tmp "$AGENTS_MD"
  commit_block_content > "$body"
  awk -v b="$CC_BEGIN" -v e="$CC_END" -v f="$body" '
    $0==b { print; while ((getline l < f) > 0) print l; close(f); skip=1; next }
    $0==e { skip=0; print; next }
    !skip { print }
  ' "$AGENTS_MD" > "$tmp"
  if atomic_install "$tmp" "$AGENTS_MD"; then
    c_ok "✓ 已更新 AGENTS.md 的提交语言受控块"
  fi
  atomic_abort "$body"
}

cmd_plan() {
  local apply=0
  if [ "${1:-}" = "--apply" ] || [ "${1:-}" = "-y" ]; then apply=1; fi
  [ -x "$DERIVE" ] || die "找不到或不可执行：$DERIVE"

  local tmp; atomic_tmp tmp "$LOCK"
  "$DERIVE" > "$tmp"

  # derive 自己发现的策略内部不一致
  local gaps; gaps="$(grep -c '^# !!' "$tmp" || true)"
  if [ "${gaps:-0}" -gt 0 ]; then
    c_warn "── 策略内部不一致 ──────────────────────"
    grep '^# !!' "$tmp" | sed 's/^# !! /    /'
    echo
  fi

  if [ ! -f "$LOCK" ]; then
    c_warn "首次生成 derived.lock"
    atomic_commit "$tmp" "$LOCK"
    c_ok "✓ 已写入 0-meta/derived.lock（请与 policy.yaml 一起提交）"
    write_commit_block
    return 0
  fi

  if diff -q "$LOCK" "$tmp" >/dev/null 2>&1; then
    atomic_abort "$tmp"
    c_ok "✓ derived.lock 已是最新，策略无变更"
    # lock 没变不等于 AGENTS.md 的受控块没变——它可能被手改过。
    # 受控块的意义就是「不许手维护」，所以这里也要对齐。
    if [ "$apply" = 1 ]; then
      write_commit_block
    elif [ -f "$AGENTS_MD" ] && [ "$(extract_commit_block "$AGENTS_MD")" != "$(commit_block_content)" ]; then
      c_warn "  ⚠ 但 AGENTS.md 的提交语言受控块与 policy 不一致 —— new plan --apply"
      return 1
    fi
    return 0
  fi

  echo "── 派生结果变更 ────────────────────────"
  diff -u "$LOCK" "$tmp" | sed '1,2d' | sed 's/^-/  - /; s/^+/  + /; s/^ /    /' || true
  echo

  local ndanger=0
  plan_danger "$LOCK" "$tmp" || ndanger=$?
  if [ "$ndanger" -gt 0 ]; then
    echo
    c_err "共 $ndanger 项危险变更。确认这是你想要的再 --apply。"
  else
    c_ok "无危险变更。"
  fi
  echo

  if [ "$apply" = 1 ]; then
    atomic_commit "$tmp" "$LOCK"
    c_ok "✓ 已写入 0-meta/derived.lock"
    write_commit_block
    c_warn "  记得与 policy.yaml 放进同一个 commit。"
  else
    atomic_abort "$tmp"
    c_warn "未写入。确认后跑：new plan --apply"
    return 1
  fi
}
