#!/usr/bin/env bash
# 在 receive 的 quarantine 中只读对象；规则与契约只读 wrapper 的 GitHub snapshot。
set -euo pipefail
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$HOOK_DIR/task-paths.sh"

dir="$1" snapshot="$2" tip="$3" branch="$4" issue="$5"
reject() { printf 'git-guard: %s\n' "$*" >&2; exit 1; }
[[ "$issue" =~ ^[1-9][0-9]*$ ]] || reject '缺少显式 Task Binding'
lock="$(git --git-dir="$dir" show "${snapshot}:0-meta/derived.lock")" \
  || reject '无法从 snapshot 读取策略'
policy_get() {
  awk -F' = ' -v k="$1" '$1==k{sub(/^[^=]* = /,"");print;exit}' <<< "$lock"
}
[ -n "$(policy_get git.never_domains)" ] && [ -n "$(policy_get git.commit.types.all)" ] \
  || reject 'snapshot 策略缺少路径或提交规则'
contract="$(git --git-dir="$dir" show "${snapshot}:0-meta/tasks/${issue}/contract.json")" \
  || reject "snapshot 没有已批准契约 #${issue}"
if ! jq -e --arg issue "#${issue}" '
    .schema_version == "task-contract/v1" and .issue == $issue
    and (.requirements | type == "array" and length > 0)
    and (.acceptances | type == "array" and length > 0)
    and (.scope | type == "array" and length > 0 and all(.[]; type == "string" and length > 0))
  ' <<< "$contract" >/dev/null; then
  reject "snapshot 契约 #${issue} 格式无效"
fi
scope="$(jq -r '.scope[]' <<< "$contract")" || reject '无法读取契约 scope'
while IFS= read -r path; do
  task_repo_path_ok "$path" || reject "契约 scope 路径无效：${path}"
done <<< "$scope"

# 不只检查最终净 diff：越界后 revert、bad message 后补合法提交都不能夹带进历史。
# main 已有历史不重判；同步 main 的 merge 以 merge-base 判任务自己的改动。
commits="$(git --git-dir="$dir" rev-list "$tip" "^$snapshot")" \
  || reject '无法读取待推送提交'
scratch="$(mktemp -d "${TMPDIR:-/tmp}/git-guard-validate.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
for sha in $commits; do
  git --git-dir="$dir" diff --no-ext-diff --no-textconv --no-renames --name-only -z \
    "${snapshot}...${sha}" > "$scratch/paths" || reject '无法读取任务 diff'
  while IFS= read -r -d '' path; do
    case "$path" in
      *$'\n'*|*$'\r'*|*$'\t'*) reject '路径含控制字符，无法安全判定 scope' ;;
    esac
    if task_path_hard_denied "$path"; then
      reject "hard-deny：${path}（${sha:0:12}）"
    fi
    task_path_in_scope "$path" "$scope" || reject "越界 diff：${path}（契约 #${issue}）"
  done < "$scratch/paths"
  bash "$HOOK_DIR/check-commit-msg.sh" --receive "$dir" "$snapshot" "$sha" "$branch" \
    || reject "非法提交信息：${sha:0:12}"
done
