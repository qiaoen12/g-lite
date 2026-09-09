#!/usr/bin/env bash
# 将任务分支安全 rebase 到最新 origin/main。不写 Review、不合并、不用 --force。
set -Eeuo pipefail
export LC_COLLATE=C
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "✗ 不在 git 工作树" >&2; exit 1; }
# shellcheck source=/dev/null
. "$ROOT/.agents/skills/z-lib.sh"
z_load
z_require_clean
z_require_dev_status
task_branch_pushable "$Z_GIT_BR" "$Z_MAIN" || die_code task.branch_not_pushable "当前分支不可同步：${Z_GIT_BR}"

before_head="$(git -C "$Z_WT" rev-parse HEAD)"
z_fetch_origin_main
before_main="$(git -C "$Z_WT" rev-parse "origin/${Z_MAIN}")"
remote_sha="$(z_remote_branch_sha "$Z_WT" "$Z_GIT_BR")"
if [ -n "$remote_sha" ]; then
  GIT_TERMINAL_PROMPT=0 git -C "$Z_WT" fetch --quiet origin \
    "refs/heads/${Z_GIT_BR}:refs/remotes/origin/${Z_GIT_BR}" \
    || die_code task.remote_ref_unreadable "无法 fetch 远端任务分支 ${Z_GIT_BR}，停止"
fi
z_require_remote_ancestor "$Z_WT" "$remote_sha" "$before_head"

if z_main_is_current "$Z_WT" "origin/${Z_MAIN}" HEAD; then
  cat <<EOF
已包含最新 origin/${Z_MAIN}（${before_main}），无需同步，不改 HEAD。
同步前 HEAD=${before_head}
同步前 origin/${Z_MAIN}=${before_main}
同步后 HEAD=${before_head}
结果=noop
EOF
  exit 0
fi

echo "落后于 origin/${Z_MAIN}（${before_main}），rebase，不 merge。"
z_rebase_onto_current_main "$Z_WT" "origin/${Z_MAIN}"
after_head="$(git -C "$Z_WT" rev-parse HEAD)"
z_main_is_current "$Z_WT" "origin/${Z_MAIN}" HEAD \
  || die_code z.rebase_still_behind "rebase 后仍落后 origin/${Z_MAIN}，停止"
z_push_rebased_branch "$Z_WT" "$Z_GIT_BR" "$remote_sha"
cat <<EOF
已 rebase 到 origin/${Z_MAIN}。
同步前 HEAD=${before_head}
同步前 origin/${Z_MAIN}=${before_main}
同步后 HEAD=${after_head}
结果=rebased
下一步：重新 zreview。不自动 zmerge。
EOF
