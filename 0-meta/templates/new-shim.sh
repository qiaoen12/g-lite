#!/usr/bin/env bash
# `new` 的 PATH 入口。安装位置：~/.local/bin/new
#
# 它只做一件事：把 `new` 解析到「当前所在的那个工作区」的 0-meta/bin/new。
#
# 为什么不直接把 0-meta/bin 加进 PATH，也不做符号链接：
#
#   加进 PATH   路径写死指向某一个 clone。在 worktree 里跑 `new check`，
#               它会去审计那份 clone，然后报告全绿——被审计的对象根本
#               不是你以为的那个。
#
#   符号链接    真脚本用 ${BASH_SOURCE[0]} 反推 ROOT，而经符号链接调用时
#               它拿到的是链接自身的路径，ROOT 会算成 ~/.local。
#
# 不默认任何本机绝对路径：fresh clone / 另一台机器上的路径各不相同。
# 可选覆盖：NEW_WORKSPACE_ROOT（兼容旧名 PROJECTS2_ROOT）。
#
# 安装与漂移检查由 `new setup` 负责。
set -Eeuo pipefail

d="$PWD"
while [ "$d" != "/" ]; do
  if [ -x "$d/0-meta/bin/new" ]; then exec "$d/0-meta/bin/new" "$@"; fi
  d="$(dirname "$d")"
done

fallback="${NEW_WORKSPACE_ROOT:-${PROJECTS2_ROOT:-}}"
if [ -n "$fallback" ] && [ -x "$fallback/0-meta/bin/new" ]; then
  exec "$fallback/0-meta/bin/new" "$@"
fi

printf '%s\n' "new: 当前目录不属于任何工作区。cd 进 clone 再跑。" >&2
printf '%s\n' "     或设 NEW_WORKSPACE_ROOT 指向工作区根。" >&2
exit 127
