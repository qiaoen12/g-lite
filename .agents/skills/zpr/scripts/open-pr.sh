#!/usr/bin/env bash
# human-merge 例外：送出标题已合规的 PR，保持 In review。不合并、不关 Issue。
set -Eeuo pipefail
export LC_COLLATE=C
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "✗ 不在 git 工作树" >&2; exit 1; }
# shellcheck source=/dev/null
. "$ROOT/.agents/skills/z-lib.sh"
z_load
z_require_clean
z_require_current_main
z_require_passing_review
echo "Squash-Title: ${Z_SQUASH_TITLE}"
"$ROOT/0-meta/bin/new" task review || die_code z.review_deliver_failed "new task review 失败"
local_pr="$(task_find_matching_pr "$Z_OWNER" "$Z_REPO" "$Z_GIT_BR" "$Z_MAIN")" \
  || die_code z.pr_ambiguous "找不到刚交付的 PR"
[ -n "$local_pr" ] || die_code z.pr_missing "new task review 之后没有未关闭 PR"
pr_num="$(printf '%s' "$local_pr" | jq -r '.number // empty')"
js="$(task_pr_view_json "$Z_OWNER" "$Z_REPO" "$pr_num")" || die_code task.pr_unreadable "回读 PR 失败"
got="$(printf '%s' "$js" | jq -r '.title // empty')"
[ "$got" = "$Z_SQUASH_TITLE" ] || die_code z.pr_title_mismatch "远端 PR 标题与 Squash-Title 不一致：${got:-空}"
task_pr_fields_ok "$js" "$Z_GIT_BR" "$Z_MAIN" "$Z_NUMBER" "$Z_SQUASH_TITLE" \
  || die_code z.pr_fields "PR 字段不正确"
echo "PR #${pr_num} 标题已与 Squash-Title 一致。保持 In review，不合并。"
