#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# gen-restic-args.sh — 把 0-meta/derived.lock 翻译成 restic 的两个入参文件
#
#   _out/files-from.txt   → restic backup --files-from
#   _out/exclude.txt      → restic backup --exclude-file
#
# 唯一输入是 derived.lock。不解析 policy.yaml，也不在本文件里写任何路径常量——
# 策略变了，跑 `new plan --apply` 再跑本脚本，两个文件跟着变。
#
# v1 的教训写在这里，因为它们决定了下面几个具体选择：
#
#   1. v1 的路径清单是手写的（rules/projects-cold-restic-paths.txt，23 行）。
#      结果是 60-dev / 80-data / 80-research 三个目录零副本，
#      而审计报告显示「漂移 0 项」。清单必须是算出来的。
#
#   2. v1 对不存在的路径**静默跳过**（load_paths 把它们塞进 MISSING_PATHS 就不管）。
#      一个打错字的域名会安静地从备份里消失。这里改成硬失败。
#
#   3. v1 无条件排除 **/.git/**。v2 不排除——worktree 的 .git 只是个指针文件，
#      主仓库的 .git 进了备份，worktree 里的分支才恢复得出来。
#
# 用法：
#   gen-restic-args.sh            生成两个文件，打印摘要
#   gen-restic-args.sh --print    连同文件内容一起打印（调试用）
# ─────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_DIR="$(cd "$SELF_DIR/.." && pwd)"
ROOT="$(cd "$UNIT_DIR/../.." && pwd)"
LOCK="$ROOT/0-meta/derived.lock"
OUT_DIR="$UNIT_DIR/_out"
FILES_FROM="$OUT_DIR/files-from.txt"
EXCLUDE="$OUT_DIR/exclude.txt"

PRINT=0
case "${1:-}" in
  "")        ;;
  --print)   PRINT=1 ;;
  -h|--help) sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *)         echo "未知参数：$1" >&2; exit 2 ;;
esac

[ -f "$LOCK" ] || { echo "找不到 $LOCK —— 先跑 new plan --apply" >&2; exit 2; }

c_err()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }
c_warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }
c_ok()   { printf '\033[32m%s\033[0m\n' "$*"; }

lock_get() { awk -F' = ' -v k="$1" '$1==k{sub(/^[^=]* = /,"");print;exit}' "$LOCK"; }
has()      { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# derived.lock 的 root 必须与本脚本推算出的仓库根一致。不一致说明脚本被搬走了，
# 或者 policy 的 root 写错了——两种都会让备份对着错误的目录跑。
LOCK_ROOT="$(lock_get root)"
if [ -n "$LOCK_ROOT" ] && [ "$LOCK_ROOT" != "$ROOT" ]; then
  c_err "derived.lock 的 root=${LOCK_ROOT}，但本脚本推算出的是 ${ROOT}"
  exit 1
fi

mkdir -p "$OUT_DIR"

# ── 一、备份源路径 ───────────────────────────────────────────────────────────
# policy 的 backup.derive 写的是 `all_paths − 各项排除`，源就是**备份根本身**。
#
# 别把它实现成「backup.include 里各个域相加」。那样 .git、AGENTS.md、.gitignore、
# .cursorignore 这些根层条目不属于任何域，会整批漏掉——首次演练就是这么发现的。
# 漏掉 .git 尤其糟：整个版本历史就只剩 git 远端一份，而本套文档的前提恰恰是
# 「git 远端不算备份」。
#
# backup.include 在这里的角色因此是**校验**而不是枚举：逐个确认它们真的存在。
INCLUDE="$(lock_get backup.include)"
EXTERNAL="$(lock_get backup.external_paths)"
EXCLUDE_DOMAINS="$(lock_get backup.exclude.domains)"
[ -n "$INCLUDE" ] || { c_err "derived.lock 里 backup.include 为空"; exit 1; }

missing=""
for d in $INCLUDE; do
  [ -e "$ROOT/$d" ] || missing="$missing $d"
done
if [ -n "$missing" ]; then
  # 应备份的域不存在 = 要么域被删了没改 policy，要么它挂在一个没挂载的卷上
  # （5-record 迁到加密卷之后就是这种情况）。两种都不能当作「跳过」处理。
  c_err "以下域声明为 backup:required 但不存在：${missing}"
  c_err "  若是 5-record 迁到了加密卷，先挂载再跑；否则改 policy.yaml 后 new plan。"
  exit 1
fi

: >"$FILES_FROM"
printf '%s\n' "$ROOT" >>"$FILES_FROM"
n_src=1

# external_paths 允许暂时不存在——worktree 根是用一个建一个的。
# 但必须打印出来，不能像 v1 那样静默跳过。
for rel in $EXTERNAL; do
  case "$rel" in
    /*) p="$rel" ;;
    *)  p="$(cd "$ROOT" && cd "$(dirname "$rel")" 2>/dev/null && echo "$PWD/$(basename "$rel")")" \
          || p="$ROOT/$rel" ;;
  esac
  if [ -e "$p" ]; then
    printf '%s\n' "$p" >>"$FILES_FROM"
    n_src=$((n_src + 1))
  else
    c_warn "· external_path 暂不存在，本次不收录：$p"
    c_warn "  （worktree 根，建了 worktree 之后重跑本脚本）"
  fi
done

# ── 二、无条件排除 ───────────────────────────────────────────────────────────
# 保留名、纯缓存、OS 元数据。restic 的规则：不含斜杠的模式按 basename 匹配，
# 命中目录则整棵子树排除。所以裸名字一行就够。
{
  echo "# 由 gen-restic-args.sh 从 0-meta/derived.lock 生成。不要手改。"
  echo "# 生成时间：$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "# ── 保留名（backup: forbidden，任意深度）──"
  for x in $(lock_get backup.exclude.reserved); do echo "$x"; done
  echo
  echo "# ── 纯缓存（无需证据）──"
  for x in $(lock_get backup.exclude.always_disposable); do echo "$x"; done
  echo
  echo "# ── OS 元数据 ──"
  for x in $(lock_get backup.exclude.os_metadata); do echo "$x"; done
  echo
  echo "# ── backup: forbidden 的域 ──"
  # 源是备份根，所以这些域必须显式排除。不能指望它们恰好和某个保留名重名——
  # 今天 _vendor 是这样，明天新加一个 backup:forbidden 的域就不是了。
  for x in $EXCLUDE_DOMAINS; do echo "$ROOT/$x"; done
  echo
} >"$EXCLUDE"

# ── 三、条件排除：可再生目录 ─────────────────────────────────────────────────
# 目录名命中不等于可以不备份。policy 的判据是：
#   强证据（锁文件）  → 不备份，静默
#   弱证据（依赖声明）→ 不备份，但告警提示补锁文件
#   无证据            → 判定为不可再生，照常进备份
#
# 把它做成无条件排除会安静地丢掉「有 node_modules 但没有 package.json」这种目录，
# 而那正是最需要备份的一种——它谁也重建不出来。
#
# 构建产物（dist / build / .next…）走同一趟遍历，但判据不同：
# 能不能重建取决于源码是否已提交并推送，不是有没有锁文件。
echo "# ── 可再生目录与构建产物（按证据逐个判定）──" >>"$EXCLUDE"

REGEN_DIRS="$(lock_get backup.exclude.regenerable_strict) $(lock_get backup.exclude.regenerable_weak)"
REGEN_DIRS="$(printf '%s\n' $REGEN_DIRS | sort -u | tr '\n' ' ')"
BUILD_DIRS="$(lock_get backup.exclude.build_output)"
BUILD_FALLBACK="$(lock_get backup.evidence.build_output.fallback)"
PINNED_RE="$(lock_get backup.evidence.promote_pinned.requirements_txt)"

n_strict=0; n_weak=0; n_noev=0; n_build=0; n_build_keep=0

# 整棵已排除的目录不再往里走。不剪枝的话，_out/foo/node_modules 会多出一条
# 冗余规则，更糟的是「无证据，照常备份」那句告警会对一个根本不在备份里的目录发出来——
# 一个总是误报的告警等于没有告警。
# .git 只是不必往里找候选（对象库里不会有 node_modules），它本身照常进备份。
PRUNE_NAMES="$(lock_get backup.exclude.reserved) $(lock_get backup.exclude.always_disposable) .git"
prune_expr=()
for x in $PRUNE_NAMES; do prune_expr+=( -name "$x" -o ); done
prune_expr+=( -false )

# 候选目录一次走完。命中即 -prune，所以 node_modules 里面的 dist 不会被重复登记。
match_expr=()
for x in $REGEN_DIRS $BUILD_DIRS; do match_expr+=( -name "$x" -o ); done
match_expr+=( -false )

# requirements.txt 只有每行都用 == 钉死才算强证据。有一行不合规就仍是弱证据。
requirements_is_pinned() {
  local f="$1" line
  [ -s "$f" ] || return 1
  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | tr -d '[:space:]')"
    [ -z "$line" ] && continue
    printf '%s' "$line" | grep -qE "$PINNED_RE" || return 1
  done <"$f"
  return 0
}

# 在 dir 的父目录里找证据文件
find_evidence() {
  local parent="$1" list="$2" f
  for f in $list; do
    if [ -f "$parent/$f" ]; then echo "$f"; return 0; fi
  done
  return 1
}

# 某个路径所在的仓库是否「干净且已推送」。任一不成立，产物就还没有第二副本。
source_is_safe() {
  local p="$1"
  git -C "$p" rev-parse --show-toplevel >/dev/null 2>&1 || return 1
  [ -z "$(git -C "$p" status --porcelain -- "$p" 2>/dev/null)" ] || return 1
  git -C "$p" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1 || return 1
  [ -z "$(git -C "$p" log '@{upstream}..HEAD' --oneline 2>/dev/null)" ] || return 1
  return 0
}

# 依赖目录：证据来自锁文件
judge_regenerable() {
  local hit="$1" parent="$2" name="$3" ev
  ev="$(find_evidence "$parent" "$(lock_get "backup.evidence.strict.${name}")" || true)"
  if [ -n "$ev" ]; then
    echo "$hit" >>"$EXCLUDE"; n_strict=$((n_strict + 1)); return
  fi

  ev="$(find_evidence "$parent" "$(lock_get "backup.evidence.weak.${name}")" || true)"
  if [ -n "$ev" ]; then
    echo "$hit" >>"$EXCLUDE"
    # requirements.txt 每行都用 == 钉死才从弱证据升级为强证据
    if [ "$ev" = requirements.txt ] && requirements_is_pinned "$parent/requirements.txt"; then
      n_strict=$((n_strict + 1))
    else
      n_weak=$((n_weak + 1))
      c_warn "· 弱证据（只有 ${ev}，没有锁文件）已排除：${hit#$ROOT/}"
      c_warn "  补一个锁文件，否则半年后 install 拿到的不是同一套环境。"
    fi
    return
  fi

  n_noev=$((n_noev + 1))
  c_warn "· 无证据，照常备份：${hit#$ROOT/}"
  c_warn "  补一个锁文件比配排除规则划算。"
}

# 构建产物：证据是「源码已提交且已推送」，不是锁文件
judge_build_output() {
  local hit="$1" parent="$2"
  if source_is_safe "$parent"; then
    echo "$hit" >>"$EXCLUDE"; n_build=$((n_build + 1)); return
  fi
  if find_evidence "$parent" "$BUILD_FALLBACK" >/dev/null; then
    echo "$hit" >>"$EXCLUDE"; n_build=$((n_build + 1))
    c_warn "· 产物已排除，但源码未提交/未推送，只有弱证据：${hit#$ROOT/}"
    return
  fi
  n_build_keep=$((n_build_keep + 1))
  c_warn "· 产物照常备份（源码未推送且无构建声明）：${hit#$ROOT/}"
}

while IFS= read -r src; do
  [ -n "$src" ] || continue
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    name="$(basename "$hit")"
    parent="$(dirname "$hit")"
    if has "$name" "$REGEN_DIRS"; then
      judge_regenerable "$hit" "$parent" "$name"
    else
      judge_build_output "$hit" "$parent"
    fi
  done < <(find "$src" \( "${prune_expr[@]}" \) -prune -o \
                       -type d \( "${match_expr[@]}" \) -print -prune 2>/dev/null || true)
done <"$FILES_FROM"

# ── 摘要 ─────────────────────────────────────────────────────────────────────
echo
c_ok "✓ $(basename "$FILES_FROM")  ${n_src} 个源路径"
sed 's/^/    /' "$FILES_FROM"
echo
c_ok "✓ $(basename "$EXCLUDE")  $(grep -cv '^\s*\(#.*\)\?$' "$EXCLUDE") 条规则"
echo "    可再生目录：强证据 ${n_strict} · 弱证据 ${n_weak} · 无证据保留 ${n_noev}"
echo "    构建产物：  已排除 ${n_build} · 保留 ${n_build_keep}"

if [ "$PRINT" = 1 ]; then
  echo
  echo "── ${EXCLUDE#$ROOT/} ──"
  sed 's/^/    /' "$EXCLUDE"
fi
