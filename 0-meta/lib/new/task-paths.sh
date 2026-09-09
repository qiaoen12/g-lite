# Task Contract 路径判据：runtime 与 Git Guard 共用；policy_get 由调用方提供。
task_is_under() {
  local child="${1%/}" parent="${2%/}"
  [ -n "$child" ] && [ -n "$parent" ] || return 1
  [ "$child" = "$parent" ] && return 0
  [ "${child#"$parent"/}" != "$child" ]
}

task_repo_path_ok() {
  local p="$1"
  case "$p" in
    ''|*..*|*' '*|*[[:space:]]*|http://*|https://*|*'*'*|*'?'*|*[[*]*|/*) return 1 ;;
  esac
  case "$p" in
    *。*|*，*|*；*|*！*|*？*|*、*) return 1 ;;
  esac
  # 允许中文文件名，但必须像路径：含 / . - _，或本身是 ASCII 标识。
  case "$p" in
    */*|*.*|*[-_]*|[A-Za-z0-9]*) ;;
    *) return 1 ;;
  esac
  return 0
}

# 无反引号的范围列表行只收 ASCII 路径。
# 反引号里可以有中文文件名；说明句即使带 / 也不能当路径。
task_repo_path_ascii_ok() {
  task_repo_path_ok "$1" || return 1
  [[ "$1" =~ ^[A-Za-z0-9._-][A-Za-z0-9._/-]*$ ]]
}

task_norm_scope_path() {
  local p="$1"
  p="${p#./}"
  p="${p%/}"
  printf '%s\n' "$p"
}

# 仓库级绝对禁止写入的路径。扩大 Issue 范围也不能绕过。
# 契约文件目录 0-meta/tasks 与 git.never_domains 同级：Issue 写了 0-meta/ 也不放宽。
task_path_hard_denied() {
  local p="$1" d
  p="$(task_norm_scope_path "$p")"
  [ -n "$p" ] || return 1
  d="${CONTRACT_TASKS_DIR:-0-meta/tasks}"
  case "$p" in
    "$d"|"$d"/*) return 0 ;;
  esac
  for d in $(policy_get git.never_domains); do
    [ -n "$d" ] || continue
    case "$p" in
      "$d"|"$d"/*) return 0 ;;
    esac
  done
  case "/$p/" in
    */5-record/*) return 0 ;;
  esac
  case "$p" in
    *.key|*.pem|.env|*/.env|id_ed25519|*/id_ed25519|id_rsa|id_rsa.*|*/id_rsa|*/id_rsa.*)
      return 0 ;;
  esac
  return 1
}

# f 是否落在 scope 里（scope 每行一个路径；精确文件或目录前缀）。
# 不按空白拆词：路径整体作为单一值比较。
task_path_in_scope() {
  local f="$1" scope="$2" p fn
  fn="$(task_norm_scope_path "$f")"
  [ -n "$fn" ] || return 1
  while IFS= read -r p; do
    p="$(task_norm_scope_path "$p")"
    [ -n "$p" ] || continue
    if [ "$fn" = "$p" ]; then
      return 0
    fi
    task_is_under "$fn" "$p" && return 0
  done <<< "$scope"
  return 1
}
