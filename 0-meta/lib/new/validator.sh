# Task Contract validator registry。只登记固定实现，不执行 Contract 提供的命令。
# 由 contract.sh 加载；Review 在当前 task worktree 中调用。

VALIDATOR_OUTPUT_MAX_BYTES="${VALIDATOR_OUTPUT_MAX_BYTES:-4096}"

validator_ids() {
  printf '%s\n' new-check-commit contract-test bash-syntax
}

validator_id_valid() {
  [[ "${1:-}" =~ ^[a-z0-9][a-z0-9._-]*$ ]]
}

validator_known() {
  case "${1:-}" in
    new-check-commit|contract-test|bash-syntax) return 0 ;;
    *) return 1 ;;
  esac
}

validator_error() {
  local code="$1"
  shift
  if [ "$(type -t contract_err 2>/dev/null)" = function ]; then
    contract_err "$code" "$@"
  else
    printf '%s\n' "$*" >&2
  fi
}

# 从 Contract A 文本中只提取显式 validator:<id> token。
# 普通文本里的 R/A、validator failed 等没有冒号的内容不会进入协议。
validator_refs_from_text() {
  local text="${1:-}" token id
  while IFS= read -r token; do
    [ -n "$token" ] || continue
    id="${token#*validator:}"
    # Markdown 标点可以紧跟 token；路径、shell 字符等不会被静默截断。
    while :; do
      case "$id" in
        *'`'|*','|*'.'|*';'|*':'|*')'|*']'|*'}'|*'。 '|*'。'|*'；'|*'，'|*'）'|*'】'|*'！'|*'？')
          id="${id%?}" ;;
        *) break ;;
      esac
    done
    if ! validator_id_valid "$id"; then
      validator_error contract.validator_ref_invalid "Contract 中的 validator 引用非法：validator:${id:-（空）}"
      return 1
    fi
    printf '%s\n' "$id"
  done < <(printf '%s\n' "$text" | grep -oE '(^|[^[:alnum:]_.-])validator:[^[:space:]]+' || true)
}

# 校验 origin/main 上的 contract.json。除白名单外，不允许出现 command/shell/run 等
# 可执行字段；A 文本中的 validator:<id> 也必须是登记项。
validator_contract_validate() {
  local json="$1" id text vals refs v
  [ -f "$json" ] || {
    validator_error contract.validator_contract "找不到 Contract JSON：$json"
    return 1
  }
  if ! jq -e '
      ((.acceptances | type == "array") and
       (all(.acceptances[]; ((has("validators") | not) or
         ((.validators | type == "array") and
          (.validators | all(.[]; type == "string")))))) and
       ((any(.. | objects; any(keys[]?;
          . == "command" or . == "commands" or . == "shell" or
          . == "run" or . == "script" or . == "cmd"))) | not))
    ' "$json" >/dev/null 2>&1; then
    validator_error contract.validator_contract "Contract 含非法 validator 结构或可执行字段"
    return 1
  fi

  while IFS=$'\t' read -r id text; do
    [ -n "$id" ] || continue
    vals="$(jq -r --arg id "$id" '.acceptances[] | select(.id==$id) | (.validators // [])[]' "$json")"
    while IFS= read -r v; do
      [ -n "$v" ] || continue
      validator_id_valid "$v" || {
        validator_error contract.validator_ref_invalid "$id 的 validator ID 非法：$v"
        return 1
      }
      validator_known "$v" || {
        validator_error contract.validator_unknown "未知 validator：${v}（已登记：$(validator_ids | tr '\n' ' ')）"
        return 1
      }
    done <<< "$vals"

    refs="$(validator_refs_from_text "$text")" || return 1
    while IFS= read -r v; do
      [ -n "$v" ] || continue
      validator_known "$v" || {
        validator_error contract.validator_unknown "未知 validator：${v}（已登记：$(validator_ids | tr '\n' ' ')）"
        return 1
      }
    done <<< "$refs"
  done < <(jq -r '.acceptances[] | [.id, (.text // "")] | @tsv' "$json")
  return 0
}

validator_bash_syntax() {
  local wt="$1" scope="$2" list f count=0 rc=0
  list="$(mktemp -t validator-shell.XXXXXX)" || return 1
  if ! git -C "$wt" ls-files -z -- '*.sh' >"$list"; then
    rm -f "$list"
    return 1
  fi
  while IFS= read -r -d '' f; do
    task_path_in_scope "$f" "$scope" || continue
    count=$((count + 1))
    if ! bash -n "$wt/$f"; then
      rc=1
    fi
  done <"$list"
  rm -f "$list"
  [ "$count" -gt 0 ] || return 1
  return "$rc"
}

# 唯一执行入口。$1 是 registry ID，$2 是 task worktree，$3 是当前 Contract scope。
validator_run() {
  local id="$1" wt="$2" scope="${3:-}"
  validator_known "$id" || return 2
  [ -d "$wt" ] || return 1
  case "$id" in
    new-check-commit)
      [ -x "$wt/0-meta/bin/new" ] || return 127
      (cd "$wt" && "$wt/0-meta/bin/new" check --tier commit)
      ;;
    contract-test)
      [ -f "$wt/0-meta/lib/new/contract.test.sh" ] || return 127
      (cd "$wt" && bash "$wt/0-meta/lib/new/contract.test.sh")
      ;;
    bash-syntax)
      validator_bash_syntax "$wt" "$scope"
      ;;
  esac
}

validator_truncate_file() {
  local file="$1" limit="${2:-$VALIDATOR_OUTPUT_MAX_BYTES}" size
  [ -f "$file" ] || { printf '%s' ''; return 0; }
  size="$(wc -c <"$file" | tr -d ' ')"
  if [ "$size" -le "$limit" ]; then
    cat "$file"
  else
    head -c "$limit" "$file"
    printf '\n…[validator output truncated at %s bytes]\n' "$limit"
  fi
}
