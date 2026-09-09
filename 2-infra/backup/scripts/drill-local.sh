#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# drill-local.sh — 用本地仓库当替身，验证整条备份管道
#
# 把「管道对不对」和「凭据故事完不完整」拆开：这个脚本用一次性口令和一个本地
# restic 仓库，跑完 生成清单 → 备份 → 查内容 → 恢复 → 比对 → 拆台，
# 不需要网络、不需要口令库、不动 policy。
#
# 它**不能**替代季度异机演练。它证明的是「规则翻译成 restic 参数这一段是对的」，
# 证明不了「本机没了还拿不拿得到口令」——后者才是演练要回答的问题。
# 记录写 0-meta/audit/restore-drill/。
#
# 首次跑这个脚本就抓到一处：源路径当时是「backup.include 各域相加」，
# 于是 .git 和根层的 AGENTS.md / .gitignore / .cursorignore 整批漏掉，
# 83 个文件对 297 个。上一代同类错误的规模是三万个文件。
#
# 用法：
#   drill-local.sh            跑完整演练，结束后删掉临时仓库
#   drill-local.sh --keep     保留临时仓库，便于手工翻查
# ─────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SELF_DIR/lib.sh"

GEN="$SELF_DIR/gen-restic-args.sh"
OUT_DIR="$UNIT_DIR/_out"

KEEP=0
case "${1:-}" in
  "")      ;;
  --keep)  KEEP=1 ;;
  -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *)       echo "未知参数：$1" >&2; exit 2 ;;
esac

command -v restic >/dev/null 2>&1 || { c_err "缺 restic"; exit 2; }

# 演练仓库放在 _out/ 下。这不只是图方便——它同时验证了「备份不会把自己的
# 仓库吞进去」，因为 _out 是 backup: forbidden 的保留名。
REPO_DIR="$OUT_DIR/drill-repo"
RESTORE_DIR="$(mktemp -d -t drill-restore.XXXXXX)"
CANARY_DIR=""
CANARY=""

cleanup() {
  rm -rf "$RESTORE_DIR"
  # 只删自己放的那个 canary 文件。CANARY_DIR 是 worktree 或 _inbox，都不是临时目录。
  [ -n "$CANARY" ] && rm -f "$CANARY"
  if [ "$KEEP" = 0 ]; then
    rm -rf "$REPO_DIR"
  else
    c_warn "临时仓库保留在 ${REPO_DIR}（口令：${RESTIC_PASSWORD}）"
  fi
  return 0
}
trap cleanup EXIT

export RESTIC_REPOSITORY="$REPO_DIR"
export RESTIC_PASSWORD="drill-$(openssl rand -hex 12)"
rm -rf "$REPO_DIR"

fail=0
step() { echo; echo "── $* ─────────────────────"; }

# ── 1. canary ────────────────────────────────────────────────────────────────
# 放在 worktree 里、且不提交。这是当前副本数最少的一类数据：
# 不在任何仓库里（未跟踪），也不在备份根里（worktree 是兄弟目录）。
step "1. 在 worktree 里放一个未跟踪的 canary"
WT_ROOT="$(cd "$ROOT" && cd "$(dirname "$(lock_get git.worktree.root)")" \
  && echo "$PWD/$(basename "$(lock_get git.worktree.root)")")"
WT="$(find "$WT_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)"
if [ -z "$WT" ]; then
  c_warn "    没有 worktree，canary 退回放在 _inbox/（这一轮验不到 external_paths）"
  CANARY_DIR="$ROOT/_inbox"
else
  CANARY_DIR="$WT"
fi
CANARY="$CANARY_DIR/.drill-canary-$(date -u +%Y%m%dT%H%M%SZ).txt"
printf 'restore-drill canary\ncreated: %s\nrandom: %s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(openssl rand -hex 16)" >"$CANARY"
CANARY_SHA="$(shasum -a 256 "$CANARY" | awk '{print $1}')"
echo "    ${CANARY#$ROOT/}"
echo "    sha256 ${CANARY_SHA}"

# ── 2. 清单 ──────────────────────────────────────────────────────────────────
step "2. 由 derived.lock 生成清单"
"$GEN" >/dev/null || { c_err "生成失败"; exit 1; }
echo "    源路径 $(wc -l <"$OUT_DIR/files-from.txt" | tr -d ' ') 条"

# ── 3. 备份 ──────────────────────────────────────────────────────────────────
# 不加 --verbose：5-record 的 ai_access 是 deny，逐文件输出会把档案文件名打出来。
step "3. 备份到本地替身仓库"
restic init >/dev/null 2>&1
restic backup --host drill --tag "$BACKUP_TAG" \
  --files-from "$OUT_DIR/files-from.txt" \
  --exclude-file "$OUT_DIR/exclude.txt" 2>&1 | tail -3

# ── 4. 快照内容 ──────────────────────────────────────────────────────────────
step "4. 快照内容抽查"
LISTING="$(restic ls latest 2>/dev/null)"

expect_present() {
  local label="$1" pat="$2" n
  n="$(grep -c -- "$pat" <<<"$LISTING" || true)"
  if [ "${n:-0}" -gt 0 ]; then printf '    \033[32m✓\033[0m %-34s %s 条\n' "$label" "$n"
  else printf '    \033[31m✗\033[0m %-34s 0 条\n' "$label"; fail=1; fi
}
expect_absent() {
  local label="$1" pat="$2" n
  n="$(grep -c -- "$pat" <<<"$LISTING" || true)"
  if [ "${n:-0}" = 0 ]; then printf '    \033[32m✓\033[0m %-34s 0 条\n' "$label"
  else printf '    \033[31m✗\033[0m %-34s %s 条\n' "$label" "$n"; fail=1; fi
}

# .git 是重点。上一代无条件排除它，等于把整个版本历史交给 git 远端一份——
# 而本套文档的前提恰恰是「git 远端不算备份」。
expect_present ".git（版本历史）"        "${ROOT}/.git/"
expect_present "canary（未跟踪）"        "$(basename "$CANARY")"
expect_absent  "_out（不能把自己吞进去）" "/_out/"
expect_absent  "_vendor"                 "/_vendor"
expect_absent  ".DS_Store"               "\.DS_Store$"

# 根层还得有域以外的东西（AGENTS.md、.gitignore、.cursorignore…）。
# 拿深度 1 的条目数和域数比，就不用手写一份根层文件清单——
# 而手写清单正是这套系统在消灭的东西。
n_root="$(grep -c "^${ROOT}/[^/]*$" <<<"$LISTING" || true)"
n_dom="$(printf '%s\n' $(lock_get backup.include) | wc -l | tr -d ' ')"
if [ "${n_root:-0}" -gt "$n_dom" ]; then
  printf '    \033[32m✓\033[0m %-34s %s 条（域 %s + 根层 %s）\n' \
    "根层非域条目" "$n_root" "$n_dom" "$((n_root - n_dom))"
else
  printf '    \033[31m✗\033[0m %-34s 深度 1 只有 %s 条，等于域数——根层文件整批漏了\n' \
    "根层非域条目" "${n_root:-0}"
  fail=1
fi

# 每个应备份的域都要在。域缺席是整域缺席，深度 1 就查得出来。
for dom in $(lock_get backup.include); do
  if grep -qxF "${ROOT}/${dom}" <<<"$LISTING"; then
    printf '    \033[32m✓\033[0m %-34s\n' "域 ${dom}"
  else
    printf '    \033[31m✗\033[0m %-34s 不在快照里\n' "域 ${dom}"; fail=1
  fi
done

# ── 5. 恢复 ──────────────────────────────────────────────────────────────────
step "5. 恢复 canary 并逐字节比对"
restic restore latest --target "$RESTORE_DIR" --include "$CANARY" >/dev/null 2>&1
RESTORED="${RESTORE_DIR}${CANARY}"
if [ ! -f "$RESTORED" ]; then
  c_err "    ✗ 没恢复出文件"
  fail=1
elif [ "$(shasum -a 256 "$RESTORED" | awk '{print $1}')" = "$CANARY_SHA" ]; then
  c_ok "    ✓ 哈希一致 ${CANARY_SHA}"
else
  c_err "    ✗ 哈希不一致"
  fail=1
fi

echo
if [ "$fail" = 0 ]; then
  c_ok "本地管道演练通过。"
  echo "  注意：这不算季度演练。它没有回答「本机没了能不能拿到口令」——"
  echo "  那要在另一台机器上、只用口令库里的口令做，记录写 0-meta/audit/restore-drill/。"
else
  c_err "本地管道演练失败。"
  exit 1
fi
