# canonical `new z <verb>`。由 0-meta/bin/new 加载，不要单独执行。
# 实现与 .agents/skills/*/scripts 共用：dev/fix 走 z-lib 门禁；
# sync/review/pr/merge 执行同一组脚本，避免第二套协议。

z_cli_usage() {
  cat <<'USAGE'
用法：new z <dev|fix|sync|review|pr|merge> [...]

  new z dev              开发入口：加载 binding + Contract，门禁后打印开工摘要。
                         不领取、不改 Project。门禁成功不是开发完成；
                         未通过 completion gate 时下一步是继续开发，不是 Review。
  new z fix              修复入口：同一加载与门禁，不打印开发摘要。
  new z sync             将任务分支 rebase 到最新 origin/main
  new z review [--actor <id>] [--allow-self] <review-input>
                         写入唯一 Review 评论
  new z pr               调用 new task review 送出标题一致的 PR
  new z merge            squash merge（无 human-merge 时）

Skill 只是 adapter：`.agents/skills/z*/SKILL.md` 调用本入口。
USAGE
}

z_cli_source_lib() {
  local lib="${ROOT:-}/.agents/skills/z-lib.sh"
  [ -f "$lib" ] || die_code z.lib_missing "找不到 $lib"
  # shellcheck source=/dev/null
  . "$lib"
}

z_cli_gate() {
  local verb="$1"
  case "$verb" in
    dev) export Z_ENTRY_SCRIPT="${ROOT}/.agents/skills/zdev/scripts/dev.sh" ;;
    fix) export Z_ENTRY_SCRIPT="${ROOT}/.agents/skills/zfix/scripts/fix.sh" ;;
  esac
  z_cli_source_lib
  z_load
  z_require_dev_status
}

z_cli_dev_summary() {
  local next
  next="$(task_next_canonical_command "$Z_WT" "origin/${Z_MAIN:-main}")"
  task_start_card "$Z_OWNER" "$Z_REPO" "$Z_NUMBER" "$Z_ISSUE_URL" "$Z_MAIN" \
    "$Z_CONTRACT_BLOB" "$Z_WT" "$Z_LOGICAL_BR" "$Z_GIT_BR" \
    "${Z_DERIVED:-${Z_STATUS:-unknown}}" "$Z_SCOPE" \
    "$next" "$Z_HEAD"
  if [ "$next" = "$TASK_BOOTSTRAP_NEXT_DEV" ]; then
    echo
    task_developer_handoff_text
  fi
}

z_cli_exec_skill() {
  local rel="$1"
  shift || true
  local script="${ROOT}/${rel}"
  [ -f "$script" ] || die_code z.impl_missing "找不到 ${rel}"
  exec "$script" "$@"
}

z_cli_review() {
  export Z_ENTRY_SCRIPT="${ROOT}/.agents/skills/zreview/scripts/publish-review.sh"
  z_cli_source_lib
  # shellcheck source=/dev/null
  . "$ROOT/0-meta/lib/new/review.sh"
  z_load
  review_publish "$@"
}

cmd_z() {
  local verb="${1:-}"
  case "$verb" in
    -h|--help|"") z_cli_usage; return 0 ;;
  esac
  shift || true
  case "$verb" in
    dev)
      z_cli_gate dev
      echo "Status=${Z_STATUS}，允许 zdev/zfix/zreview。"
      z_cli_dev_summary
      ;;
    fix)
      z_cli_gate fix
      echo "Status=${Z_STATUS}，允许 zdev/zfix/zreview。"
      ;;
    sync)
      z_cli_exec_skill .agents/skills/zsync/scripts/sync-main.sh "$@"
      ;;
    review)
      z_cli_review "$@"
      ;;
    pr)
      z_cli_exec_skill .agents/skills/zpr/scripts/open-pr.sh "$@"
      ;;
    merge)
      z_cli_exec_skill .agents/skills/zmerge/scripts/squash-merge.sh "$@"
      ;;
    *)
      die_code z.usage "$(z_cli_usage)"$'\n'"未知入口：${verb}"
      ;;
  esac
}
