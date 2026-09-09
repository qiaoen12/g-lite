#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# check-password.sh — 审计 password_sources
#
# 查三件事实，都不读口令正文：
#
#   1. password_source 现在能不能取到东西（机器取值，硬失败）
#   2. password_recovery 有没有至少一个本机之外的来源（人取值，硬失败）
#   3. 若要求纸质副本，attestation 文件是否声明过日期（告警，不硬失败）
#
# 第 3 条无法证明纸还在。它只证明「有人写过一份声明」。缺席则每天告警，
# 直到声明出现——这比一个没人检查的 boolean 强，但仍然替代不了纸本身。
# ─────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SELF_DIR/lib.sh"

fail=0

src="$(lock_get backup.password_source)"
if [ -z "$src" ]; then
  c_err "    ✗ derived.lock 里 backup.password_source 为空"
  fail=1
else
  cmd="$(password_command "$src")" || {
    c_err "    ✗ 看不懂的口令来源：${src}"
    fail=1
    cmd=""
  }
  if [ -n "$cmd" ]; then
    probe="$(eval "$cmd" 2>/dev/null | head -1)" || true
    if [ -z "$probe" ]; then
      c_err "    ✗ 机器取值失败：${src}"
      case "$src" in
        keychain://*)
          c_err "      Keychain 里还没有这一项，或当前会话读不到。"
          c_err "      跑：2-infra/backup/scripts/install-unattended-password.sh" ;;
        bw://*)
          c_err "      Bitwarden 未解锁。交互：export BW_SESSION=\"\$(bw unlock --raw)\""
          c_err "      调度不要用 bw://，改 keychain://。" ;;
        *)
          c_err "      命令没有输出：${cmd}" ;;
      esac
      fail=1
    else
      c_ok "    ✓ 机器取值可达：${src}"
    fi
    unset probe
  fi
fi

recovery="$(lock_get backup.password_recovery)"
off=""
for r in $recovery; do
  case "$r" in
    # 判据是「本机挂了还拿得到吗」，不是「是不是个口令库」。
    # pass:// 和 keychain:// 一样地本机：GPG 密文在 ~/.password-store，
    # 解密私钥也在这台机器上。就算 store 同步到了 git 远端，没有私钥也打不开。
    # 所以它不算离机来源——算进来会让检查在「钥匙锁在保险箱里」时通过。
    bw://*|op://*|vault://*|paper|paper://*) off="$off $r" ;;
  esac
done
if [ -z "$recovery" ]; then
  c_err "    ✗ backup.password_recovery 为空——人取值没有声明"
  fail=1
elif [ -z "$off" ]; then
  c_err "    ✗ password_recovery 没有本机之外的来源：${recovery}"
  c_err "      Mac 挂了就取不到口令。至少留 bw:// 或 paper。"
  fail=1
else
  c_ok "    ✓ 人恢复含离机来源：${off# }"
fi

required="$(lock_get backup.password_offline_copy_required)"
attest="$(lock_get backup.password_offline_copy_attestation)"
if [ "$required" = "true" ]; then
  [ -n "$attest" ] || attest="0-meta/audit/offline-copy.attestation"
  f="$ROOT/$attest"
  if [ ! -f "$f" ]; then
    c_warn "    ⚠ 纸质副本尚未声明：缺 $attest"
    c_warn "      抄一份 restic 口令，放到不与本机同处的纸上，再："
    c_warn "      cp 0-meta/templates/offline-copy.attestation.tpl $attest"
    c_warn "      填 attested_on，不要把口令写进这个文件。"
  elif grep -qiE "^[[:space:]]*[\"']?(password|secret|restic_password)[\"']?[[:space:]]*:" "$f"; then
    c_err "    ✗ $attest 里出现了口令字段。这文件只允许声明「做过」，删掉那一行。"
    fail=1
  elif ! grep -qE '^attested_on:[[:space:]]*[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]*$' "$f"; then
    c_warn "    ⚠ $attest 缺 attested_on: YYYY-MM-DD"
  else
    on="$(awk -F':[[:space:]]*' '$1=="attested_on"{print $2; exit}' "$f")"
    c_ok "    ✓ 纸质副本已声明（${on}）。文件里不应含口令。"
  fi
fi

exit "$fail"
