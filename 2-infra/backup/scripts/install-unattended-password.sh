#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 把 restic 仓库口令装进本机 Keychain，供 launchd 无人值守取值。
#
# 本机只存这一个仓库口令，不存 Bitwarden 主密码。爆炸半径是这份冷备。
# 口令正文不打印、不写进任何文件。
#
# 用法（在你自己的终端跑，需要能看见和输入）：
#
#   cd /path/to/workspace
#   export BW_SESSION="$(bw unlock --raw)"    # 若已解锁可跳过
#   2-infra/backup/scripts/install-unattended-password.sh
#
# 若 bw 取不到，脚本会让 Keychain 自己提示你贴一次口令。
# ─────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SELF_DIR/lib.sh"

src="$(lock_get backup.password_source)"
case "$src" in
  keychain://*) ;;
  *)
    c_err "当前 password_source 不是 keychain://：${src}"
    c_err "  无人值守只往 Keychain 装。先改 policy.yaml 再 new plan --apply。"
    exit 2 ;;
esac

rest="${src#keychain://}"
svc="${rest%%/*}"
acct="${rest#*/}"
if [ -z "$svc" ] || [ -z "$acct" ] || [ "$svc" = "$rest" ]; then
  c_err "keychain 引用格式应为 keychain://<service>/<account>，现在是：${src}"
  exit 2
fi

if security find-generic-password -s "$svc" -a "$acct" -w >/dev/null 2>&1; then
  c_ok "Keychain 已有 ${svc}/${acct}，将覆盖写入"
fi

item=""
for r in $(lock_get backup.password_recovery); do
  case "$r" in bw://*) item="${r#bw://}"; break ;; esac
done

copy_from_bw=0
if [ -n "$item" ] && command -v bw >/dev/null 2>&1; then
  if [ -n "${BW_SESSION:-}" ]; then
    copy_from_bw=1
  else
    st="$(bw status 2>/dev/null | jq -r '.status' 2>/dev/null || echo unknown)"
    [ "$st" = "unlocked" ] && copy_from_bw=1
  fi
fi

if [ "$copy_from_bw" = 1 ]; then
  pw="$(bw get password "$item" 2>/dev/null || true)"
  if [ -z "$pw" ]; then
    c_warn "bw get password ${item} 没有输出，改成 Keychain 提示输入。"
    copy_from_bw=0
  fi
fi

if [ "$copy_from_bw" = 1 ]; then
  security add-generic-password \
    -s "$svc" -a "$acct" \
    -l "workspace restic cold backup" \
    -w "$pw" -U \
    -T /usr/bin/security \
    >/dev/null
  pw=""
  unset pw
  c_ok "已从 Bitwarden「${item}」写入 Keychain ${svc}/${acct}"
else
  echo "将由 macOS 提示输入 restic 仓库口令（不是 Bitwarden 主密码）。" >&2
  echo "打开离机口令库中的 restic-cold 条目，复制密码字段，贴进提示。" >&2
  security add-generic-password \
    -s "$svc" -a "$acct" \
    -l "workspace restic cold backup" \
    -U \
    -T /usr/bin/security \
    -w
  c_ok "已写入 Keychain ${svc}/${acct}"
fi

probe="$(security find-generic-password -s "$svc" -a "$acct" -w 2>/dev/null | head -1 || true)"
if [ -z "$probe" ]; then
  c_err "写完后读不回来。Keychain 可能弹了授权框被拒，或条目没写上。"
  exit 1
fi
unset probe
c_ok "回读成功（不显示内容）"

echo
echo "下一步："
echo "  1. 纸质副本：手抄 restic 口令，放到不与本机同处的地方。"
echo "     然后 cp 0-meta/templates/offline-copy.attestation.tpl \\"
echo "            0-meta/audit/offline-copy.attestation"
echo "     只填日期，不要把口令写进文件。"
echo "  2. 装调度："
echo "     # edit 2-infra/backup/launchd/com.g-lite.backup-cold.plist paths, then:"
echo "     cp 2-infra/backup/launchd/com.g-lite.backup-cold.plist \\"
echo "        ~/Library/LaunchAgents/"
echo "     launchctl bootstrap gui/\$(id -u) ~/Library/LaunchAgents/com.g-lite.backup-cold.plist"
echo "  3. 验证一次（不再需要 BW_SESSION）："
echo "     2-infra/backup/scripts/backup-cold.sh --snapshots"
