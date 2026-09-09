# ⚠️ 这是模板。实际生效的文件是工作区根目录的 .cursorignore。
#
# 为什么要多这一步：Cursor 不允许 agent 写入 .cursorignore——
# 一个能修改自己访问控制文件的 agent，等于没有访问控制。
# 这条限制正好说明了 layer 2 的定位：它是工具在执行，不是文档在约定。
#
# 安装（一次性，必须你自己跑）：
#   cp 0-meta/templates/cursorignore.tpl .cursorignore
#
# 之后每次改 policy.yaml 的 ai_access 段，`new plan` 会提示这个文件已过期。

# ═══ deny：机密档案 ═══════════════════════════════════════════
5-record/

# ═══ deny：凭据 ═══════════════════════════════════════════════
**/.env
**/.env.*
!**/.env.tpl
!**/.env.example
**/*.pem
**/*.key
!**/*.pub
**/id_rsa*
**/id_ed25519
**/secrets.json
**/*credentials*.json
**/*password*.csv
**/*密码*.csv
**/*.ovpn

**/*.enc.yaml
**/*.enc.yml
**/*.enc.json
**/*.enc.env
**/*.age
**/*.gpg

# ═══ 检索效率：可再生目录 ═════════════════════════════════════
**/node_modules/
**/.venv/
**/venv/
**/__pycache__/
**/.mypy_cache/
**/.pytest_cache/
**/.ruff_cache/
**/.turbo/
**/.parcel-cache/
**/target/
**/dist/
**/build/
**/.next/
**/.nuxt/
**/.astro/
**/.svelte-kit/

# ═══ 检索效率：保留名 ═════════════════════════════════════════
**/_out/
**/_cache/
**/_archive/
_vendor/
**/_raw/
4-know/_files/

# ═══ 检索效率：二进制与日志 ═══════════════════════════════════
**/*.mp4
**/*.mov
**/*.avi
**/*.mkv
**/*.zip
**/*.tar.gz
**/*.rar
**/*.7z
**/*.exe
**/*.bin
**/*.dmg
**/*.pkg
**/*.sqlite
**/*.db
**/*.log
**/.DS_Store
