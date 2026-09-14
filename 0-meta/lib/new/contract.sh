# Task Contract v1：契约文件在 main 里。
#
# Issue 正文是人写契约的地方；`new task approve <n>` 把它解析后写进
# origin/main:0-meta/tasks/<n>/contract.md（原文）与 contract.json（规范化解析结果）。
# 领取、wip 提交、Review、交付、合并五处门禁只从 origin/main 读这份文件；
# 契约版本就是 contract.json 的 blob SHA。任务分支改不了 main。
# Ledger / digest / drift / trusted-ruleset 已由契约进 main(#27)取代。
#
# 由 bin/new 在 task.sh 之后加载；z-lib.sh 同样加载。不要单独执行。
# 流程底线在本文件与 0-meta/schema/task-contract.v1.yaml，不能靠改单个 Issue 放宽。

TASK_CONTRACT_MARK='<!-- task-contract:v1 -->'
CONTRACT_SCHEMA_VERSION='task-contract/v1'
CONTRACT_SCHEMA_FILE="${ROOT:-}/0-meta/schema/task-contract.v1.yaml"
# 契约文件目录。永不进入任何任务的允许范围（hard-deny，与 git.never_domains 同级，Issue 无法放宽）。
CONTRACT_TASKS_DIR='0-meta/tasks'

if [ "$(type -t validator_contract_validate 2>/dev/null)" != function ]; then
  # shellcheck source=/dev/null
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/validator.sh"
fi

contract_err() { local code="$1"; shift; err_code "$code" "$@"; }

contract_norm_nl() {
  printf '%s' "$1" | tr -d '\r'
}

contract_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

contract_norm_text() {
  printf '%s\n' "$1" | tr -d '\r' | awk '
    BEGIN { start=0 }
    {
      line=$0
      sub(/[ \t]+$/, "", line)
      if (!start) {
        if (line ~ /^[ \t]*$/) next
        start=1
      }
      lines[++n]=line
    }
    END {
      while (n>0 && lines[n] ~ /^[ \t]*$/) n--
      for (i=1; i<=n; i++) print lines[i]
    }
  '
}

contract_has_v1_marker() {
  case "$1" in
    *"$TASK_CONTRACT_MARK"*) return 0 ;;
    *) return 1 ;;
  esac
}

contract_heading_key() {
  local h="$1"
  h="$(contract_trim "$h")"
  case "$h" in
    背景) printf '%s\n' background ;;
    目标) printf '%s\n' goal ;;
    要求|要求/实现细节|'要求 / 实现细节') printf '%s\n' requirements ;;
    验收) printf '%s\n' acceptances ;;
    允许改动范围) printf '%s\n' scope ;;
    分支建议) printf '%s\n' branch_suggestion ;;
    *) printf '%s\n' "other:$h" ;;
  esac
}

# stdout：每个 section 三行块：KEY \n TITLE \n BODY（body 内换行保持，块以 \0 分隔不现实）
# 改为写入 dest 目录：<idx>.key / <idx>.title / <idx>.body，并把数量写到 dest/count

contract_split_sections() {
  local body="$1" dest="$2"
  mkdir -p "$dest"
  printf '%s\n' "$body" | tr -d '\r' | awk -v dest="$dest" '
    function flush() {
      if (title == "") return
      n++
      keyfile = dest "/" n ".key"
      titlefile = dest "/" n ".title"
      bodyfile = dest "/" n ".body"
      print key > keyfile
      print title > titlefile
      printf "%s", body > bodyfile
      close(keyfile); close(titlefile); close(bodyfile)
    }
    BEGIN { title=""; key=""; body=""; fence=0; n=0 }
    {
      line=$0
      if (index(line, "```") == 1) {
        fence = fence ? 0 : 1
        if (title != "") body = body line "\n"
        next
      }
      if (!fence && line ~ /^##[ \t]+/) {
        flush()
        title=line
        sub(/^##[ \t]+/, "", title)
        sub(/[ \t]+$/, "", title)
        body=""
        next
      }
      if (title != "") body = body line "\n"
    }
    END {
      flush()
      print n > (dest "/count")
      close(dest "/count")
    }
  '
}

contract_section_nonempty() {
  local text="$1" stripped
  stripped="$(printf '%s\n' "$text" | tr -d '\r' | awk '
    BEGIN { fence=0 }
    {
      line=$0
      if (index(line, "```") == 1) { fence = fence ? 0 : 1; next }
      if (fence) next
      if (line ~ /^[ \t]*<!--/) next
      if (line ~ /^[ \t]*$/) next
      print line
    }
  ')"
  [ -n "$(contract_trim "$stripped")" ]
}

# 从某个 section body 抽出 ID 项到 dest/。kind=R 或 A。
# dest/count、dest/<n>.id、dest/<n>.req、dest/<n>.text

contract_extract_items() {
  local kind="$1" sec="$2" dest="$3"
  mkdir -p "$dest"
  printf '%s\n' "$sec" | tr -d '\r' | awk -v kind="$kind" -v dest="$dest" '
    function flush() {
      if (id == "") return
      gsub(/\n+$/, "", text)
      n++
      print id > (dest "/" n ".id")
      print req > (dest "/" n ".req")
      printf "%s", text > (dest "/" n ".text")
      close(dest "/" n ".id")
      close(dest "/" n ".req")
      close(dest "/" n ".text")
    }
    function is_item(line) {
      if (kind == "R") {
        return (line ~ /^#+[ \t]*\[R[1-9][0-9]*\]/ || line ~ /^[ \t]*[-*][ \t]+\[R[1-9][0-9]*\]/ || line ~ /^[ \t]*[0-9]+[.)][ \t]+\[R[1-9][0-9]*\]/)
      }
      return (line ~ /^#+[ \t]*\[A[1-9][0-9]*/ || line ~ /^[ \t]*[-*][ \t]+\[A[1-9][0-9]*/ || line ~ /^[ \t]*[0-9]+[.)][ \t]+\[A[1-9][0-9]*/)
    }
    BEGIN { id=""; req=""; text=""; fence=0; n=0 }
    {
      line=$0
      if (index(line, "```") == 1) {
        fence = fence ? 0 : 1
        if (id != "") text = text line "\n"
        next
      }
      if (fence) {
        if (id != "") text = text line "\n"
        next
      }
      if (is_item(line)) {
        flush()
        id=""; req=""; text=""
        if (kind == "R") {
          if (match(line, /\[R[1-9][0-9]*\]/)) {
            id = substr(line, RSTART+1, RLENGTH-2)
            rest = substr(line, RSTART+RLENGTH)
            sub(/^[ \t]+/, "", rest)
            text = rest "\n"
          }
        } else {
          if (match(line, /\[A[1-9][0-9]*[^]]*\]/)) {
            raw = substr(line, RSTART+1, RLENGTH-2)
            if (match(raw, /^A[1-9][0-9]*/)) {
              id = substr(raw, RSTART, RLENGTH)
              req = substr(raw, RSTART+RLENGTH)
            }
            rest = substr(line, RSTART+RLENGTH)
            sub(/^[ \t]+/, "", rest)
            text = rest "\n"
          }
        }
        next
      }
      if (id != "") text = text line "\n"
    }
    END {
      flush()
      print n > (dest "/count")
      close(dest "/count")
    }
  '
}

contract_parse_applicable_when() {
  local text="$1" line
  while IFS= read -r line; do
    line="$(contract_trim "$line")"
    case "$line" in
      适用条件：*|适用条件:*)
        line="${line#适用条件：}"
        line="${line#适用条件:}"
        contract_trim "$line"
        return 0
        ;;
    esac
  done <<< "$text"
  return 1
}

# 解析 Issue 正文为 JSON 文件。失败打 stderr 并 return 1。

contract_scope_section() {
  printf '%s\n' "$1" | tr -d '\r' | awk '
    BEGIN { s=0 }
    /^##[ \t]+/ {
      if (s) exit
      if ($0 ~ /^##[ \t]+允许改动范围/) { s=1; next }
    }
    s { print }
  '
}

contract_scope_items() {
  printf '%s\n' "$1" | tr -d '\r' | awk '
    BEGIN { fence=0 }
    {
      line=$0
      if (index(line, "```") == 1) { fence = fence ? 0 : 1; next }
      if (fence) next
      if (line !~ /^[ \t]*[-*][ \t]+/) next
      sub(/^[ \t]*[-*][ \t]+/, "", line)
      sub(/[ \t]+$/, "", line)
      print line
    }
  '
}

contract_parse_scope_section() {
  local sec="$1" item p out="" seen=" "
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    case "$item" in
      \`*)
        p="${item#\`}"
        p="${p%%\`*}"
        task_repo_path_ok "$p" || continue ;;
      *)
        p="$item"
        task_repo_path_ascii_ok "$p" || continue ;;
    esac
    p="$(task_norm_scope_path "$p")"
    [ -n "$p" ] || continue
    case "$seen" in *" $p "*) continue ;; esac
    seen="$seen$p "
    out="${out}${p}"$'\n'
  done < <(contract_scope_items "$sec")
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# 范围里不得出现 hard-deny 路径（0-meta/tasks、never_domains、5-record、密钥文件）。
# stdout 打印命中的项，命中则 return 1。

contract_scope_denied_items() {
  local scope="$1" p bad=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if task_path_hard_denied "$p"; then
      printf '%s\n' "$p"; bad=1
    fi
  done <<< "$scope"
  [ "$bad" = 0 ]
}

# ── 解析 Issue 正文 ─────────────────────────────────────
# 解析 Issue 正文为 JSON 文件。失败打 stderr 并 return 1，列出全部缺失项。

contract_parse_body() {
  local body="$1" out="$2"
  local secdir n i key title sbody seen="" goal="" bg="" req_sec="" acc_sec="" scope_sec="" br_sec=""
  local has_bg=0 has_goal=0 has_req=0 has_acc=0 has_scope=0
  local items_r items_a json_r json_a scope_txt scope_json id text req rest nr na requires req_json bad when rpart oldifs refs validator_json vref
  local seen_ids=" " missing=0 itemdir denied

  [ -n "$body" ] || { contract_err contract.body_empty "Issue 正文为空"; return 1; }
  if ! contract_has_v1_marker "$body"; then
    contract_err contract.marker_missing "缺少 ${TASK_CONTRACT_MARK}"
    return 1
  fi

  tmp_mkd secdir contract-sec
  contract_split_sections "$body" "$secdir"
  n="$(cat "$secdir/count" 2>/dev/null || echo 0)"
  if ! [[ "$n" =~ ^[0-9]+$ ]] || [ "$n" -eq 0 ]; then
    contract_err contract.no_sections "Issue 没有可解析的 ## 段"
    tmp_rmd "$secdir"
    return 1
  fi

  for i in $(seq 1 "$n"); do
    title="$(cat "$secdir/$i.title")"
    sbody="$(cat "$secdir/$i.body")"
    key="$(contract_heading_key "$title")"
    case " $seen " in
      *" $key "*)
        contract_err contract.duplicate_section "重复 section：$title"
        tmp_rmd "$secdir"
        return 1
        ;;
    esac
    seen="$seen $key "
    if ! contract_section_nonempty "$sbody"; then
      contract_err contract.empty_section "空 section：$title"
      tmp_rmd "$secdir"
      return 1
    fi
    case "$key" in
      background) has_bg=1; bg="$sbody" ;;
      goal) has_goal=1; goal="$sbody" ;;
      requirements) has_req=1; req_sec="$sbody" ;;
      acceptances) has_acc=1; acc_sec="$sbody" ;;
      scope) has_scope=1; scope_sec="$sbody" ;;
      branch_suggestion) br_sec="$sbody" ;;
    esac
  done
  tmp_rmd "$secdir"

  [ "$has_bg" = 1 ] || { contract_err contract.missing_background "缺少「背景」"; return 1; }
  [ "$has_goal" = 1 ] || { contract_err contract.missing_goal "缺少「目标」"; return 1; }
  [ "$has_req" = 1 ] || { contract_err contract.missing_requirements "缺少「要求 / 实现细节」"; return 1; }
  [ "$has_acc" = 1 ] || { contract_err contract.missing_acceptances "缺少「验收」"; return 1; }
  [ "$has_scope" = 1 ] || { contract_err contract.missing_scope "缺少「允许改动范围」"; return 1; }

  goal="$(contract_norm_text "$goal")"
  [ -n "$goal" ] || { contract_err contract.goal_empty "目标为空"; return 1; }

  tmp_mkd itemdir contract-items
  contract_extract_items R "$req_sec" "$itemdir/r"
  contract_extract_items A "$acc_sec" "$itemdir/a"
  nr="$(tr -d '[:space:]' < "$itemdir/r/count" 2>/dev/null || echo 0)"
  na="$(tr -d '[:space:]' < "$itemdir/a/count" 2>/dev/null || echo 0)"
  if ! [[ "$nr" =~ ^[1-9][0-9]*$ ]]; then
    contract_err contract.no_r "没有稳定唯一的 [R*]"
    tmp_rmd "$itemdir"
    return 1
  fi
  if ! [[ "$na" =~ ^[1-9][0-9]*$ ]]; then
    contract_err contract.no_a "没有稳定唯一的 [A*]"
    tmp_rmd "$itemdir"
    return 1
  fi

  json_r='[]'
  i=0
  while [ "$i" -lt "$nr" ]; do
    i=$((i+1))
    id="$(contract_trim "$(cat "$itemdir/r/$i.id")")"
    text="$(cat "$itemdir/r/$i.text")"
    [ -n "$id" ] || continue
    case "$seen_ids" in *" $id "*)
      contract_err contract.duplicate_id "重复 R/A ID：$id"
      tmp_rmd "$itemdir"
      return 1
      ;;
    esac
    seen_ids="$seen_ids$id "
    text="$(contract_norm_text "$text")"
    [ -n "$text" ] || { contract_err contract.item_empty "$id 正文为空"; tmp_rmd "$itemdir"; return 1; }
    json_r="$(jq -c --arg id "$id" --arg text "$text" '. + [{id:$id,text:$text}]' <<<"$json_r")"
  done

  json_a='[]'
  i=0
  while [ "$i" -lt "$na" ]; do
    i=$((i+1))
    id="$(contract_trim "$(cat "$itemdir/a/$i.id")")"
    requires="$(cat "$itemdir/a/$i.req")"
    requires="$(printf '%s' "$requires" | sed -E 's/^[[:space:]]*(→|->)[[:space:]]*//; s/[[:space:]]+//g')"
    text="$(cat "$itemdir/a/$i.text")"
    [ -n "$id" ] || continue
    case "$seen_ids" in *" $id "*)
      contract_err contract.duplicate_id "重复 R/A ID：$id"
      tmp_rmd "$itemdir"
      return 1
      ;;
    esac
    seen_ids="$seen_ids$id "
    text="$(contract_norm_text "$text")"
    [ -n "$text" ] || { contract_err contract.item_empty "$id 正文为空"; tmp_rmd "$itemdir"; return 1; }
    if [ -z "$requires" ]; then
      contract_err contract.a_missing_r "$id 缺少 A→R 关系"
      missing=1
      continue
    fi
    req_json='[]'
    bad=0
    oldifs="$IFS"
    IFS=','
    # shellcheck disable=SC2086
    set -- $requires
    IFS="$oldifs"
    for rpart in "$@"; do
      rpart="$(contract_trim "$rpart")"
      if [ -z "$rpart" ]; then
        continue
      fi
      if ! [[ "$rpart" =~ ^R[1-9][0-9]*$ ]]; then
        contract_err contract.undefined_r_alias "$id 引用了未定义的 R 别名：$rpart"
        bad=1
        missing=1
        continue
      fi
      case "$seen_ids" in
        *" $rpart "*) ;;
        *)
          contract_err contract.undefined_r "$id 引用不存在的 R ID：$rpart"
          bad=1
          missing=1
          ;;
      esac
      req_json="$(jq -c --arg r "$rpart" '. + [$r]' <<<"$req_json")"
    done
    [ "$bad" = 0 ] || continue
    if [ "$(jq 'length' <<<"$req_json")" -eq 0 ]; then
      contract_err contract.a_missing_r "$id 缺少 A→R 关系"
      missing=1
      continue
    fi
    when="$(contract_parse_applicable_when "$text" || true)"
    validator_json='[]'
    if ! refs="$(validator_refs_from_text "$text")"; then
      tmp_rmd "$itemdir"
      return 1
    fi
    while IFS= read -r vref; do
      [ -n "$vref" ] || continue
      if ! validator_known "$vref"; then
        contract_err contract.validator_unknown "$id 引用了未知 validator：${vref}（已登记：$(validator_ids | tr '\n' ' ')）"
        tmp_rmd "$itemdir"
        return 1
      fi
      validator_json="$(jq -c --arg v "$vref" 'if any(.[]; . == $v) then . else . + [$v] end' <<<"$validator_json")"
    done <<< "$refs"
    json_a="$(jq -c --arg id "$id" --arg text "$text" --argjson req "$req_json" --argjson validators "$validator_json" --arg when "$when" '
      . + [{id:$id, text:$text, requires:$req,
            applicable_when: (if $when == "" then null else $when end),
            validators:$validators}]
    ' <<<"$json_a")"
  done
  tmp_rmd "$itemdir"
  [ "$missing" = 0 ] || return 1

  if [ "$(jq 'length' <<<"$json_r")" -lt 1 ] || [ "$(jq 'length' <<<"$json_a")" -lt 1 ]; then
    contract_err contract.parse_empty "R/A 解析结果为空（示例代码块中的伪字段不算）"
    return 1
  fi

  if ! scope_txt="$(contract_parse_scope_section "$scope_sec")"; then
    contract_err contract.unclassified "允许改动范围没有可解析的列表项路径（只认 - \`path\` 形式的列表项）"
    return 1
  fi
  if denied="$(contract_scope_denied_items "$scope_txt")"; [ -n "$denied" ]; then
    contract_err contract.unclassified "允许改动范围含硬拒绝路径（Issue 无法放宽）：$(printf '%s' "$denied" | tr '\n' ' ')"
    return 1
  fi
  scope_json="$(printf '%s\n' "$scope_txt" | jq -Rsc 'split("\n") | map(select(length>0))')"

  local br_json='null'
  if [ -n "$br_sec" ]; then
    if ! contract_section_nonempty "$br_sec"; then
      contract_err contract.branch_unreadable "分支建议存在但不可读"
      return 1
    fi
    br_json="$(jq -n --arg t "$(contract_norm_text "$br_sec")" '$t')"
  fi

  jq -n \
    --arg schema "$CONTRACT_SCHEMA_VERSION" \
    --arg goal "$goal" \
    --arg bg "$(contract_norm_text "$bg")" \
    --argjson req "$json_r" \
    --argjson acc "$json_a" \
    --argjson scope "$scope_json" \
    --argjson br "$br_json" \
    '{
      schema_version:$schema,
      goal:$goal,
      background:$bg,
      requirements:($req | sort_by(.id | ltrimstr("R") | tonumber)),
      acceptances:($acc | sort_by(.id | ltrimstr("A") | tonumber)),
      scope:$scope,
      branch_suggestion:$br
    }' > "$out"
  validator_contract_validate "$out" || return 1
}

# contract.json 的内容：只留进入契约的字段，键排序、缩进固定，git diff 可读。
# 背景与分支建议只在 contract.md 原文里。

contract_canonical_json() {
  local json="$1" issue="${2:-}" title="${3:-}"
  jq -S --indent 2 --arg issue "$issue" --arg title "$title" '{
    schema_version,
    issue: (if $issue == "" then null else $issue end),
    title: (if $title == "" then null else $title end),
    goal,
    requirements: (.requirements | map({id,text}) | sort_by(.id | ltrimstr("R") | tonumber)),
    acceptances: (.acceptances | map({id,text,requires,applicable_when,validators:(.validators // [])}) | sort_by(.id | ltrimstr("A") | tonumber)),
    scope
  }' "$json"
}

# ── 契约文件：只从 origin/main 读 ───────────────────────

contract_dir() { printf '%s/%s\n' "$CONTRACT_TASKS_DIR" "$1"; }

contract_json_path() { printf '%s/%s/contract.json\n' "$CONTRACT_TASKS_DIR" "$1"; }

contract_md_path() { printf '%s/%s/contract.md\n' "$CONTRACT_TASKS_DIR" "$1"; }

# 使用前 fetch。失败硬停，不用本地陈旧的 origin/main。

contract_fetch_main() {
  local wt="$1" main="${2:-main}"
  [ -n "$wt" ] || { contract_err contract.unclassified "contract_fetch_main 缺少工作树"; return 1; }
  if ! GIT_TERMINAL_PROMPT=0 git -C "$wt" fetch --quiet origin \
      "refs/heads/${main}:refs/remotes/origin/${main}" 2>/dev/null; then
    contract_err contract.fetch_main_failed "无法 fetch origin/${main}，不使用本地陈旧副本，停止"
    return 1
  fi
}

# origin/main 上 contract.json 的 blob SHA。不存在 return 1，stdout 为空。

contract_main_blob() {
  local wt="$1" n="$2" main="${3:-main}" sha
  sha="$(git -C "$wt" rev-parse --verify -q "origin/${main}:$(contract_json_path "$n")" 2>/dev/null)" || return 1
  [ -n "$sha" ] || return 1
  printf '%s\n' "$sha"
}

# fetch + 读 origin/main:0-meta/tasks/<n>/contract.json 到 out。
# 成功设置 CONTRACT_BLOB。返回码：2 fetch 失败；3 文件不存在（末行提示 approve）；1 其它。

contract_load_main() {
  local wt="$1" n="$2" out="$3" main="${4:-main}" blob
  CONTRACT_BLOB=""
  contract_fetch_main "$wt" "$main" || return 2
  if ! blob="$(contract_main_blob "$wt" "$n" "$main")"; then
    contract_err contract.missing "origin/${main} 上没有 $(contract_json_path "$n")：任务尚未批准。先在稳定主工作区运行："
    printf '%s\n' "new task approve ${n}" >&2
    return 3
  fi
  if ! git -C "$wt" show "origin/${main}:$(contract_json_path "$n")" > "$out" 2>/dev/null; then
    contract_err contract.unclassified "无法读取 origin/${main}:$(contract_json_path "$n")"
    return 1
  fi
  if ! jq -e --arg v "$CONTRACT_SCHEMA_VERSION" '.schema_version == $v and (.requirements|length) > 0 and (.acceptances|length) > 0 and (.scope|length) > 0' "$out" >/dev/null 2>&1; then
    contract_err contract.unclassified "$(contract_json_path "$n") 不是合法的 ${CONTRACT_SCHEMA_VERSION} 契约文件"
    return 1
  fi
  validator_contract_validate "$out" || return 1
  CONTRACT_BLOB="$blob"
}

# 契约文件里的允许范围，每行一个。

contract_scope_from_json() {
  jq -r '.scope[]' "$1"
}

# 文档记录的 Contract 与 origin/main 当前 blob 不同即 stale。stale 时 return 0 并报错。

contract_stale() {
  local recorded="$1" current="$2" what="${3:-文档}"
  [ -n "$current" ] || { contract_err contract.unclassified "当前契约 blob 为空，无法比对"; return 0; }
  if [ "$recorded" != "$current" ]; then
    contract_err contract.stale "${what} 绑定的 Contract 已过期（stale）：记录 ${recorded:-空}，origin/main 当前 ${current}。契约已重新批准，需要重新 zreview。"
    return 0
  fi
  return 1
}

# Issue 正文与 main 上文件是否一致（只比进入契约的字段）。不一致只警告，以文件为准。

contract_warn_if_issue_differs() {
  local body="$1" file_json="$2" n="$3" tmp saved_code saved_err
  local saved_metrics_code saved_metrics_err saved_metrics_die parse_rc=0
  [ -n "$body" ] || return 0
  if [ "$(type -t metrics_state_load 2>/dev/null)" = function ]; then
    metrics_state_load
  fi
  saved_code="${METRICS_REASON_CODE-}"
  saved_err="${LAST_ERR-}"
  saved_metrics_code="${METRICS_REASON_CODE-}"
  saved_metrics_err="${METRICS_LAST_ERROR-}"
  saved_metrics_die="${METRICS_DIE_MESSAGE-}"
  tmp="$(mktemp -t contract-issue.XXXXXX)"; TMPS="$TMPS $tmp"
  contract_parse_body "$body" "$tmp" 2>/dev/null || parse_rc=$?
  METRICS_REASON_CODE="$saved_code"
  LAST_ERR="$saved_err"
  if [ "$(type -t metrics_set 2>/dev/null)" = function ]; then
    metrics_set reason_code "$saved_metrics_code"
    metrics_set last_error "$saved_metrics_err"
    metrics_set die_message "$saved_metrics_die"
  fi
  if [ "$parse_rc" != 0 ]; then
    c_warn "    ⚠ Issue 正文当前不是合法 Contract；以 origin/main 上的契约文件为准"
    return 0
  fi
  if [ "$(contract_canonical_json "$tmp" | jq -cS 'del(.issue,.title)')" \
       != "$(jq -cS 'del(.issue,.title)' "$file_json")" ]; then
    c_warn "    ⚠ Issue 正文与 origin/main 上的契约不一致；以文件为准。要采用新正文请在主工作区运行 new task approve ${n}"
  fi
  return 0
}

# ── 批准：把 Issue 正文写进 main ─────────────────────────
# 纯 git 部分，可用本地夹具测试。root 必须是主工作区、在 main 上、本地 main 等于 origin/main。
# 成功 stdout 打印 contract.json 的 blob SHA；内容未变时不产生提交（no-op）。
# 失败前不写任何文件。push 失败时提交保留在本地，返回 1。

contract_approve() {
  local root="$1" n="$2" body="$3" title="${4:-}" url="${5:-}" main="${6:-main}"
  local json canon md_path json_path dir cur_br old_json old_md new_md blob
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || { contract_err contract.unclassified "Issue 编号不合法：$n"; return 1; }

  json="$(mktemp -t contract-approve.XXXXXX)"; TMPS="$TMPS $json"
  if ! contract_parse_body "$body" "$json"; then
    contract_err contract.unclassified "Issue #${n} 不是合法的 ${CONTRACT_SCHEMA_VERSION}，未写任何东西。"
    return 1
  fi
  canon="$(contract_canonical_json "$json" "#${n}" "$title")" || return 1

  cur_br="$(git -C "$root" symbolic-ref --short HEAD 2>/dev/null || true)"
  [ "$cur_br" = "$main" ] || { contract_err contract.approve_failed "approve 必须在 ${main} 分支的主工作区运行（当前：${cur_br:-游离}）"; return 1; }
  if task_git_busy "$root" >/dev/null; then
    contract_err contract.unclassified "git 忙（merge/rebase 进行中），停止"; return 1
  fi
  contract_fetch_main "$root" "$main" || return 1
  if [ "$(git -C "$root" rev-parse HEAD)" != "$(git -C "$root" rev-parse "origin/${main}")" ]; then
    contract_err contract.approve_failed "本地 ${main} 与 origin/${main} 不一致。先 git pull --ff-only，再 approve。"
    return 1
  fi

  dir="$root/$(contract_dir "$n")"
  md_path="$(contract_md_path "$n")"
  json_path="$(contract_json_path "$n")"
  new_md="$(printf '%s' "$body" | tr -d '\r')"
  old_json="$(git -C "$root" show "HEAD:${json_path}" 2>/dev/null || true)"
  old_md="$(git -C "$root" show "HEAD:${md_path}" 2>/dev/null || true)"
  if [ "$old_json" = "$canon" ] && [ "$old_md" = "$new_md" ]; then
    blob="$(git -C "$root" rev-parse "HEAD:${json_path}")"
    echo "    契约未变，无新提交（blob ${blob:0:12}）" >&2
    printf '%s\n' "$blob"
    return 0
  fi

  mkdir -p "$dir"
  printf '%s\n' "$new_md" > "$dir/contract.md"
  printf '%s\n' "$canon" > "$dir/contract.json"
  git -C "$root" add -- "$md_path" "$json_path" || { contract_err contract.unclassified "git add 失败"; return 1; }
  local subject verb
  if [ -n "$old_json" ]; then verb="修订"; else verb="批准"; fi
  subject="docs(meta): ${verb}任务契约 #${n}"
  if ! git -C "$root" commit -q -m "$subject" -m "${title:+Issue: ${title}}${url:+
${url}}" -- "$md_path" "$json_path"; then
    contract_err contract.unclassified "提交失败（钩子未通过则不提交）。已写入的文件保留在工作区，可 git checkout -- ${md_path} ${json_path} 撤销。"
    return 1
  fi
  if ! GIT_TERMINAL_PROMPT=0 git -C "$root" push --quiet origin "${main}:${main}" 2>/dev/null; then
    contract_err contract.approve_failed "push origin ${main} 失败。提交已在本地 ${main}；请 git pull --rebase origin ${main} && git push 后重试 approve（幂等）。"
    return 1
  fi
  blob="$(git -C "$root" rev-parse "HEAD:${json_path}")"
  printf '%s\n' "$blob"
}

# ── 路径采集与范围门禁（R4/R5）─────────────────────────
# 全部用 -z 逐条读，重命名/复制两端、type change、删除都进入判定；含空格路径是单一值。
# 输出每行一个路径（路径本身不含换行；git 对含换行的路径已用 -z 原样给出）。

contract_paths_from_status_z() {
  # stdin：git diff --name-status -z 的输出
  local st a b
  while IFS= read -r -d '' st; do
    case "$st" in
      R*|C*)
        IFS= read -r -d '' a || break
        IFS= read -r -d '' b || break
        [ -n "$a" ] && printf '%s\n' "$a"
        [ -n "$b" ] && printf '%s\n' "$b"
        ;;
      *)
        IFS= read -r -d '' a || break
        [ -n "$a" ] && printf '%s\n' "$a"
        ;;
    esac
  done
}

# NUL 不能进 bash 变量，-z 输出先落临时文件再逐条读。
# 暂存区触及的全部路径。读失败 return 1，不得当成空。

contract_staged_paths() {
  local wt="$1" zf
  zf="$(mktemp -t contract-staged.XXXXXX)"; TMPS="$TMPS $zf"
  git -C "$wt" -c core.quotePath=false diff --cached --name-status -z > "$zf" 2>/dev/null \
    || { contract_err contract.unclassified "无法读取暂存区"; return 1; }
  contract_paths_from_status_z < "$zf"
}

# base...head 真实 diff 触及的全部路径。失败不得当成空。

contract_diff_paths() {
  local wt="$1" base="$2" head="$3" zf
  zf="$(mktemp -t contract-diff.XXXXXX)"; TMPS="$TMPS $zf"
  git -C "$wt" -c core.quotePath=false diff --name-status -z "${base}...${head}" > "$zf" 2>/dev/null \
    || { contract_err contract.diff_unreadable "无法读取 ${base}...${head} 的真实 diff"; return 1; }
  contract_paths_from_status_z < "$zf"
}

# 逐条判定：先 hard-deny，再范围。stdout 打印「denied\t路径」或「outside\t路径」，有任一则 return 1。

contract_paths_in_scope() {
  local paths="$1" scope="$2" f bad=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if task_path_hard_denied "$f"; then
      printf 'denied\t%s\n' "$f"; bad=1
    elif ! task_path_in_scope "$f" "$scope"; then
      printf 'outside\t%s\n' "$f"; bad=1
    fi
  done <<< "$paths"
  [ "$bad" = 0 ]
}

contract_require_diff_in_scope() {
  local wt="$1" base="$2" head="$3" scope="$4" paths verdicts
  paths="$(contract_diff_paths "$wt" "$base" "$head")" || return 1
  if ! verdicts="$(contract_paths_in_scope "$paths" "$scope")"; then
    contract_err contract.diff_out_of_scope "真实 diff 含越界路径："
    printf '%s\n' "$verdicts" | awk -F '\t' 'NF{printf "  %s  %s\n", ($1=="denied"?"硬拒绝":"越界  "), $2}' >&2
    return 1
  fi
  return 0
}

# ── 阶段文档校验：Checkpoint / Review / PR ─────────────
# 三类文档只有一个 Contract 字段，值是 origin/main 上 contract.json 的 blob SHA。

contract_table_field() {
  task_review_table_field "$1" "$2"
}

contract_require_review_min_report() {
  local body="$1" sec need val
  printf '%s\n' "$body" | grep -Eq '^### 最小充分审查[[:space:]]*$' \
    || { contract_err contract.review_min_heading "Review 正文缺少「### 最小充分审查」"; return 1; }
  sec="$(printf '%s\n' "$body" | awk '
    BEGIN { s=0 }
    /^### / {
      if (s) exit
      if ($0 ~ /^### 最小充分审查[[:space:]]*$/) { s=1; next }
    }
    s { print }
  ')"
  [ -n "$sec" ] || { contract_err contract.review_min_empty "Review「最小充分审查」段为空"; return 1; }
  for need in \
      '审查代码与调用点' \
      '复用证据' \
      '新增验证' \
      '覆盖范围' \
      '未执行的大范围验证' \
      '剩余风险'
  do
    val="$(printf '%s\n' "$sec" | awk -v k="$need" '
      index($0, k) {
        line=$0
        sub(/\r$/, "", line)
        rest=substr(line, index(line, k) + length(k))
        sub(/^[[:space:]]*[：:][[:space:]]*/, "", rest)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", rest)
        print rest
        exit
      }
    ')"
    printf '%s\n' "$sec" | grep -Fq "$need" \
      || { contract_err contract.review_min_field "Review「最小充分审查」缺少：${need}"; return 1; }
    [ -n "$val" ] || { contract_err contract.review_min_blank "Review「最小充分审查」字段为空：${need}"; return 1; }
  done
}

contract_ckpt_field() { task_review_table_field "$1" "$2"; }

# Checkpoint 的 completion 字段是成组出现的；没有交接状态表示仍是 claim/
# 进行中记录，可以沿用旧格式。只要出现其中一个字段，就必须把整组写完整，
# 并且 review-ready/no-change 只能声明 committed + clean HEAD。
contract_checkpoint_completion_validate() {
  local body="$1" state persistence classification
  local untracked unstaged staged
  CONTRACT_CHECKPOINT_STATE=""
  CONTRACT_CHECKPOINT_PERSISTENCE=""
  CONTRACT_CHECKPOINT_CLASSIFICATION=""
  CONTRACT_CHECKPOINT_HEAD=""
  CONTRACT_CHECKPOINT_UNTRACKED=""
  CONTRACT_CHECKPOINT_UNSTAGED=""
  CONTRACT_CHECKPOINT_STAGED=""

  state="$(contract_ckpt_field "$body" "交接状态")"
  persistence="$(contract_ckpt_field "$body" "HEAD 持久化")"
  classification="$(contract_ckpt_field "$body" "工作树分类")"
  CONTRACT_CHECKPOINT_HEAD="$(contract_ckpt_field "$body" HEAD)"
  [ -n "$state" ] || [ -n "$persistence" ] || [ -n "$classification" ] || return 0

  [ -n "$state" ] || {
    contract_err contract.checkpoint_completion_field "Checkpoint completion 字段缺少：交接状态"
    return 1
  }
  [ -n "$persistence" ] || {
    contract_err contract.checkpoint_completion_field "Checkpoint completion 字段缺少：HEAD 持久化"
    return 1
  }
  [ -n "$classification" ] || {
    contract_err contract.checkpoint_completion_field "Checkpoint completion 字段缺少：工作树分类"
    return 1
  }

  case "$state" in
    review-ready|no-change|'未完成 / BLOCKED') ;;
    *)
      contract_err contract.checkpoint_completion_state "Checkpoint 交接状态非法：$state"
      return 1
      ;;
  esac
  if [[ "$classification" =~ ^untracked=([0-9]+)[[:space:]]*/[[:space:]]*unstaged=([0-9]+)[[:space:]]*/[[:space:]]*staged=([0-9]+)$ ]]; then
    untracked="${BASH_REMATCH[1]}"
    unstaged="${BASH_REMATCH[2]}"
    staged="${BASH_REMATCH[3]}"
  else
    contract_err contract.checkpoint_completion_classification \
      "Checkpoint 工作树分类格式非法：$classification"
    return 1
  fi

  CONTRACT_CHECKPOINT_STATE="$state"
  CONTRACT_CHECKPOINT_PERSISTENCE="$persistence"
  CONTRACT_CHECKPOINT_CLASSIFICATION="$classification"
  CONTRACT_CHECKPOINT_UNTRACKED="$untracked"
  CONTRACT_CHECKPOINT_UNSTAGED="$unstaged"
  CONTRACT_CHECKPOINT_STAGED="$staged"

  case "$state" in
    review-ready|no-change)
      [ "$persistence" = 'committed + clean HEAD' ] || {
        contract_err contract.checkpoint_completion_persistence \
          "Checkpoint $state 必须声明 HEAD 持久化为 committed + clean HEAD"
        return 1
      }
      if [ "$untracked" != 0 ] || [ "$unstaged" != 0 ] || [ "$staged" != 0 ]; then
        contract_err contract.checkpoint_completion_dirty \
          "Checkpoint $state 的工作树分类必须为 untracked=0 / unstaged=0 / staged=0"
        return 1
      fi
      ;;
  esac
  return 0
}

contract_parse_status_table() {
  local body="$1" heading="$2"
  printf '%s\n' "$body" | tr -d '\r' | awk -v h="$heading" '
    BEGIN { s=0 }
    $0 == "### " h { s=1; next }
    s && /^### / { exit }
    s && /^\|/ {
      line=$0
      n=split(line, a, "|")
      if (n<4) next
      id=a[2]; st=a[3]; ev=a[4]
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", id)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", st)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", ev)
      if (id=="ID" || id=="---" || id ~ /^-+$/) next
      if (id=="") next
      print id "\t" st "\t" ev
    }
  '
}

contract_checkpoint_validate() {
  local body="$1" contract_json="$2" expect_blob="$3"
  local f val
  case "$body" in
    *"$TASK_CHECKPOINT_MARK"*) ;;
    *) contract_err contract.checkpoint_marker "Checkpoint 缺少标记"; return 1 ;;
  esac
  for f in Issue Contract Agent claim_actor 分支 工作树 HEAD 工作区状态 允许范围 Project PR 下一步; do
    val="$(contract_ckpt_field "$body" "$f")"
    [ -n "$val" ] || { contract_err contract.checkpoint_field "Checkpoint 缺字段：$f"; return 1; }
  done
  if [ "$(task_machine_field_count "$body" claim_actor)" != 1 ]; then
    contract_err contract.checkpoint_actor "Checkpoint 必须含且仅含一个 claim_actor machine field"
    return 1
  fi
  [ "$(contract_ckpt_field "$body" claim_actor)" = "$(task_machine_field "$body" claim_actor)" ] \
    || { contract_err contract.checkpoint_actor "Checkpoint 的 claim_actor 表格值与 machine field 不一致"; return 1; }
  task_actor_valid "$(task_machine_field "$body" claim_actor)" \
    || { contract_err contract.checkpoint_actor "Checkpoint 的 claim_actor 非法"; return 1; }
  [ "$(contract_ckpt_field "$body" "Contract")" = "$expect_blob" ] \
    || { contract_err contract.unclassified "Checkpoint Contract 与 origin/main 上的契约不一致"; return 1; }
  contract_checkpoint_completion_validate "$body" || return 1

  local r_tbl a_tbl
  r_tbl="$(contract_parse_status_table "$body" "R 进度")"
  a_tbl="$(contract_parse_status_table "$body" "A 执行")"
  [ -n "$r_tbl" ] || { contract_err contract.checkpoint_r_table "Checkpoint 缺少 R 进度"; return 1; }
  [ -n "$a_tbl" ] || { contract_err contract.checkpoint_a_table "Checkpoint 缺少 A 执行"; return 1; }

  local ids seen=" " id st ev line
  ids="$(jq -r '.requirements[].id' "$contract_json")"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    line="$(printf '%s\n' "$r_tbl" | awk -F '\t' -v i="$id" '$1==i{print; exit}')"
    [ -n "$line" ] || { contract_err contract.checkpoint_missing_r "Checkpoint 缺少当前 R：$id"; return 1; }
    st="$(printf '%s' "$line" | awk -F '\t' '{print $2}')"
    ev="$(printf '%s' "$line" | awk -F '\t' '{print $3}')"
    case "$st" in pending|addressed|blocked) ;; *)
      contract_err contract.r_status_invalid "R 状态非法：$id=$st"; return 1 ;;
    esac
    [ -n "$ev" ] || { contract_err contract.r_evidence_missing "R 缺少证据：$id"; return 1; }
    case "$seen" in *" $id "*) contract_err contract.checkpoint_dup_r "Checkpoint 重复 R：$id"; return 1 ;; esac
    seen="$seen$id "
  done <<< "$ids"
  while IFS=$'\t' read -r id st ev; do
    [ -n "$id" ] || continue
    jq -e --arg id "$id" '.requirements | any(.id==$id)' "$contract_json" >/dev/null \
      || { contract_err contract.checkpoint_unknown_r "Checkpoint 含未知 R：$id"; return 1; }
  done <<< "$r_tbl"

  seen=" "
  ids="$(jq -r '.acceptances[].id' "$contract_json")"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    line="$(printf '%s\n' "$a_tbl" | awk -F '\t' -v i="$id" '$1==i{print; exit}')"
    [ -n "$line" ] || { contract_err contract.checkpoint_missing_a "Checkpoint 缺少当前 A：$id"; return 1; }
    st="$(printf '%s' "$line" | awk -F '\t' '{print $2}')"
    ev="$(printf '%s' "$line" | awk -F '\t' '{print $3}')"
    case "$st" in pending|passed|failed|not-applicable) ;; *)
      contract_err contract.a_status_invalid "A 状态非法：$id=$st"; return 1 ;;
    esac
    [ -n "$ev" ] || { contract_err contract.a_evidence_missing "A 缺少证据：$id"; return 1; }
    if [ "$st" = not-applicable ]; then
      local when
      when="$(jq -r --arg id "$id" '.acceptances[] | select(.id==$id) | .applicable_when // empty' "$contract_json")"
      [ -n "$when" ] || { contract_err contract.na_without_when "Contract 未定义适用条件，不能标 not-applicable：$id"; return 1; }
    fi
    case "$seen" in *" $id "*) contract_err contract.checkpoint_dup_a "Checkpoint 重复 A：$id"; return 1 ;; esac
    seen="$seen$id "
  done <<< "$ids"
  return 0
}

# 同步/交付更新时保留已有开发验证，不拿 push/PR 日志覆盖。

contract_checkpoint_preserve_evidence() {
  local old="$1" new="$2"
  local old_ev new_ev
  old_ev="$(printf '%s\n' "$old" | awk '
    $0=="### 验证证据"{s=1;print;next}
    s&&/^### /{exit}
    s{print}
  ')"
  new_ev="$(printf '%s\n' "$new" | awk '
    $0=="### 验证证据"{s=1;print;next}
    s&&/^### /{exit}
    s{print}
  ')"
  if [ -n "$old_ev" ] && printf '%s\n' "$new_ev" | grep -Eq 'push origin |PR https://'; then
    if printf '%s\n' "$old_ev" | grep -Eq '尚未验证|contract\.test|定向'; then
      local keepf
      keepf="$(mktemp -t contract-ev.XXXXXX)"; TMPS="$TMPS $keepf"
      printf '%s\n' "$old_ev" > "$keepf"
      printf '%s\n' "$new" | awk -v keepf="$keepf" '
        $0=="### 验证证据"{
          while ((getline k < keepf) > 0) print k
          close(keepf)
          skip=1
          next
        }
        skip && /^### /{skip=0}
        skip{next}
        {print}
      '
      return 0
    fi
  fi
  printf '%s\n' "$new"
}

contract_list_field() {
  local sec="$1" key="$2"
  printf '%s\n' "$sec" | awk -v key="$key" '
    {
      line=$0
      sub(/\r$/, "", line)
      if (line ~ /^- /) {
        rest=line
        sub(/^- +/, "", rest)
        k=rest
        sub(/[：:].*/, "", k)
        sub(/[ \t]+$/, "", k)
        if (k==key) {
          val=rest
          sub(/^[^：:]*[：:][ \t]*/, "", val)
          print val
          exit
        }
      }
    }
  '
}

contract_review_section() {
  local body="$1" title="$2"
  printf '%s\n' "$body" | tr -d '\r' | awk -v title="$title" '
    BEGIN { grab=0; level=0 }
    {
      line=$0
      if (line ~ /^#{1,6}[ \t]+/) {
        h=line
        sub(/^#+[ \t]+/, "", h)
        sub(/[ \t]+$/, "", h)
        n=0
        tmp=line
        while (tmp ~ /^#/) { n++; sub(/^#/, "", tmp) }
        if (h==title) { grab=1; level=n; next }
        if (grab && n<=level) exit
      }
      if (grab) print line
    }
  '
}

# 只认列表项开头的结论行：「- R1：满足。…」「- A2：不通过。…」。
# 说明句里出现 R1 字样不算（B2）。

contract_parse_ra_conclusions() {
  local sec="$1" kind="$2"
  printf '%s\n' "$sec" | awk -v kind="$kind" '
    {
      line=$0
      sub(/\r$/, "", line)
      if (line !~ /^[ \t]*[-*][ \t]+/) next
      sub(/^[ \t]*[-*][ \t]+/, "", line)
      if (kind=="R" && match(line, /^R[1-9][0-9]*/)) {
        id=substr(line, RSTART, RLENGTH)
        rest=substr(line, RLENGTH+1)
        sub(/^[ \t]*[：:][ \t]*/, "", rest)
        st=""
        if (rest ~ /^不满足([ \t。:：]|$)/) { st="不满足"; sub(/^不满足/, "", rest) }
        else if (rest ~ /^满足([ \t。:：]|$)/) { st="满足"; sub(/^满足/, "", rest) }
        sub(/^[ \t]*[。:：][ \t]*/, "", rest)
        print id "\t" st "\t" rest
      }
      if (kind=="A" && match(line, /^A[1-9][0-9]*/)) {
        id=substr(line, RSTART, RLENGTH)
        rest=substr(line, RLENGTH+1)
        sub(/^[ \t]*[：:][ \t]*/, "", rest)
        st=""
        if (rest ~ /^不适用([ \t。:：]|$)/) { st="不适用"; sub(/^不适用/, "", rest) }
        else if (rest ~ /^不通过([ \t。:：]|$)/) { st="不通过"; sub(/^不通过/, "", rest) }
        else if (rest ~ /^通过([ \t。:：]|$)/) { st="通过"; sub(/^通过/, "", rest) }
        sub(/^[ \t]*[。:：][ \t]*/, "", rest)
        print id "\t" st "\t" rest
      }
    }
  '
}

contract_review_evidence_valid() {
  local status="$1" evidence normalized
  evidence="$(contract_trim "${2:-}")"
  [ -n "$evidence" ] || return 1
  normalized="$evidence"
  while :; do
    case "$normalized" in
      ：*|:*|\(*|\[*|\{*) normalized="${normalized#?}" ;;
      *。|*！|*？|*；|*，|*、|*\.|*!|*\?|*\;|*\,) normalized="${normalized%?}" ;;
      *) break ;;
    esac
    normalized="$(contract_trim "$normalized")"
  done
  case "$normalized" in
    满足|不满足|通过|不通过|不适用|pending|passed|failed|not-applicable) return 1 ;;
  esac
  return 0
}

contract_review_validate() {
  local body="$1" contract_json="$2" expect_blob="$3" expect_head="$4"
  local verdict rhead title issue blob review_actor claim_actor self_review
  local table_actor table_claim_actor table_self_review
  case "$body" in
    *"$TASK_REVIEW_MARK"*) ;;
    *) contract_err contract.review_marker "Review 缺少标记"; return 1 ;;
  esac
  contract_require_review_min_report "$body" || return 1
  validator_contract_validate "$contract_json" || return 1
  if [ "$(task_machine_field_count "$body" review_actor)" != 1 ]; then
    contract_err contract.review_actor "Review 必须含且仅含一个 review_actor machine field"
    return 1
  fi
  if [ "$(task_machine_field_count "$body" Self-review)" != 1 ]; then
    contract_err contract.self_review_field "Review 必须含且仅含一个 Self-review machine field"
    return 1
  fi
  if [ "$(task_machine_field_count "$body" claim_actor)" != 1 ]; then
    contract_err contract.claim_actor "Review 必须含且仅含一个 claim_actor machine field"
    return 1
  fi
  review_actor="$(task_machine_field "$body" review_actor)"
  claim_actor="$(task_machine_field "$body" claim_actor)"
  self_review="$(task_machine_field "$body" Self-review)"
  task_actor_valid "$review_actor" \
    || { contract_err contract.review_actor_invalid "Review 的 review_actor 非法"; return 1; }
  task_actor_valid "$claim_actor" \
    || { contract_err contract.claim_actor_invalid "Review 的 claim_actor 非法"; return 1; }
  case "$self_review" in
    yes|no) ;;
    *) contract_err contract.self_review_invalid "Review 的 Self-review 必须是 yes 或 no"; return 1 ;;
  esac
  table_actor="$(contract_table_field "$body" review_actor)"
  [ "$table_actor" = "$review_actor" ] \
    || { contract_err contract.review_actor "Review 的 review_actor 表格值与 machine field 不一致"; return 1; }
  table_claim_actor="$(contract_table_field "$body" claim_actor)"
  [ "$table_claim_actor" = "$claim_actor" ] \
    || { contract_err contract.claim_actor "Review 的 claim_actor 表格值与 machine field 不一致"; return 1; }
  table_self_review="$(contract_table_field "$body" "Self-review")"
  [ "$table_self_review" = "$self_review" ] \
    || { contract_err contract.self_review_field "Review 的 Self-review 表格值与 machine field 不一致"; return 1; }
  case "$self_review" in
    yes)
      [ "$review_actor" = "$claim_actor" ] || {
        contract_err contract.self_review_actor_mismatch "Self-review=yes 但 review_actor 与 claim_actor 不一致"
        return 1
      }
      ;;
    no)
      [ "$review_actor" != "$claim_actor" ] || {
        contract_err contract.self_review_actor_mismatch "Self-review=no 但 review_actor 与 claim_actor 相同"
        return 1
      }
      ;;
  esac
  verdict="$(contract_table_field "$body" "Verdict")"
  rhead="$(contract_table_field "$body" "reviewed HEAD")"
  title="$(contract_table_field "$body" "Squash-Title")"
  issue="$(contract_table_field "$body" "Issue")"
  blob="$(contract_table_field "$body" "Contract")"
  [ -n "$issue" ] || { contract_err contract.review_issue "Review 缺 Issue"; return 1; }
  [ -n "$blob" ] || { contract_err contract.unclassified "Review 缺 Contract"; return 1; }
  if contract_stale "$blob" "$expect_blob" "Review"; then return 1; fi
  [ -n "$rhead" ] || { contract_err contract.review_head "Review 缺 reviewed HEAD"; return 1; }
  if [ -n "$expect_head" ] && [ "$rhead" != "$expect_head" ]; then
    contract_err contract.review_head_mismatch "reviewed HEAD 不是当前 HEAD"
    return 1
  fi
  case "$verdict" in
    通过|不通过) ;;
    *) contract_err contract.verdict_invalid "Verdict 非法：$verdict"; return 1 ;;
  esac

  local min cov scope_f
  min="$(contract_review_section "$body" "最小充分审查")"
  cov="$(contract_list_field "$min" "覆盖范围")"
  scope_f="$(contract_table_field "$body" "范围")"
  [ -n "$cov" ] || { contract_err contract.coverage_empty "覆盖范围为空"; return 1; }
  if [ "$cov" = "$scope_f" ]; then
    contract_err contract.coverage_copied "覆盖范围不能复制授权范围冒充验证覆盖"
    return 1
  fi
  [ -n "$(contract_list_field "$min" "未执行的大范围验证")" ] \
    || { contract_err contract.unrun_empty "未执行的大范围验证为空"; return 1; }
  [ -n "$(contract_list_field "$min" "剩余风险")" ] \
    || { contract_err contract.risk_empty "剩余风险为空"; return 1; }

  local contra rsec asec
  contra="$(contract_review_section "$body" "Contract 对照")"
  [ -n "$contra" ] || { contract_err contract.review_contra "Review 缺少 Contract 对照"; return 1; }
  rsec="$(contract_parse_ra_conclusions "$contra" R)"
  asec="$(contract_parse_ra_conclusions "$contra" A)"

  local id st rest seen=" " line
  if ! printf '%s\n' "$rsec" | awk -F '\t' 'NF && $1!=""{c[$1]++} END{for (i in c) if (c[i]>1) exit 1; exit 0}'; then
    contract_err contract.review_dup_r "Review 重复 R 结论"
    return 1
  fi
  if ! printf '%s\n' "$asec" | awk -F '\t' 'NF && $1!=""{c[$1]++} END{for (i in c) if (c[i]>1) exit 1; exit 0}'; then
    contract_err contract.review_dup_a "Review 重复 A 结论"
    return 1
  fi
  while IFS=$'\t' read -r id st rest; do
    [ -n "$id" ] || continue
    jq -e --arg id "$id" '.requirements | any(.id==$id)' "$contract_json" >/dev/null \
      || { contract_err contract.review_unknown_r "Review 含未知 R：$id"; return 1; }
  done <<< "$rsec"
  while IFS=$'\t' read -r id st rest; do
    [ -n "$id" ] || continue
    jq -e --arg id "$id" '.acceptances | any(.id==$id)' "$contract_json" >/dev/null \
      || { contract_err contract.review_unknown_a "Review 含未知 A：$id"; return 1; }
  done <<< "$asec"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    line="$(printf '%s\n' "$rsec" | awk -F '\t' -v i="$id" '$1==i{print;exit}')"
    [ -n "$line" ] || { contract_err contract.review_missing_r "Review 缺少当前 R：$id"; return 1; }
    st="$(printf '%s' "$line" | awk -F '\t' '{print $2}')"
    rest="$(printf '%s' "$line" | awk -F '\t' '{print $3}')"
    case "$st" in
      满足|不满足) ;;
      *) contract_err contract.r_status_invalid "R 状态非法：$id=$st"; return 1 ;;
    esac
    [ -n "$(contract_trim "$rest")" ] || { contract_err contract.r_evidence_empty "R 证据为空：$id"; return 1; }
    contract_review_evidence_valid "$st" "$rest" \
      || { contract_err contract.r_evidence_status_only "R 证据不能只有状态词：$id"; return 1; }
    case "$seen" in *" $id "*) contract_err contract.unclassified "Review 重复 R：$id"; return 1 ;; esac
    seen="$seen$id "
    if [ "$verdict" = 通过 ] && [ "$st" != 满足 ]; then
      contract_err contract.review_pass_r "Verdict=通过 但 $id 不满足"
      return 1
    fi
  done < <(jq -r '.requirements[].id' "$contract_json")

  seen=" "
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    line="$(printf '%s\n' "$asec" | awk -F '\t' -v i="$id" '$1==i{print;exit}')"
    [ -n "$line" ] || { contract_err contract.review_missing_a "Review 缺少当前 A：$id"; return 1; }
    st="$(printf '%s' "$line" | awk -F '\t' '{print $2}')"
    rest="$(printf '%s' "$line" | awk -F '\t' '{print $3}')"
    case "$st" in
      通过|不通过|不适用) ;;
      *) contract_err contract.a_status_invalid "A 状态非法：$id=$st"; return 1 ;;
    esac
    [ -n "$(contract_trim "$rest")" ] || { contract_err contract.a_evidence_empty "A 证据为空：$id"; return 1; }
    contract_review_evidence_valid "$st" "$rest" \
      || { contract_err contract.a_evidence_status_only "A 证据不能只有状态词：$id"; return 1; }
    case "$seen" in *" $id "*) contract_err contract.unclassified "Review 重复 A：$id"; return 1 ;; esac
    seen="$seen$id "
    if [ "$st" = 不适用 ]; then
      local when
      when="$(jq -r --arg id "$id" '.acceptances[] | select(.id==$id) | .applicable_when // empty' "$contract_json")"
      [ -n "$when" ] || { contract_err contract.review_na_without_when "Contract 未定义适用条件，Review 不能标不适用：$id"; return 1; }
    fi
    if [ "$verdict" = 通过 ]; then
      case "$st" in
        通过) ;;
        不适用) ;;
        *) contract_err contract.review_pass_a "Verdict=通过 但必要验收 $id 为 $st"; return 1 ;;
      esac
    fi
  done < <(jq -r '.acceptances[].id' "$contract_json")

  if [ "$verdict" = 通过 ]; then
    if printf '%s\n' "$body" | grep -Eq '^### 阻断项' \
       && contract_section_nonempty "$(contract_review_section "$body" "阻断项")"; then
      contract_err contract.blocking_item "存在任务相关阻断项，不能 Verdict=通过"
      return 1
    fi
    [ -n "$title" ] && [ "$title" != "（无）" ] || { contract_err contract.squash_title_missing "通过的 Review 必须有 Squash-Title"; return 1; }
  fi
  return 0
}

contract_pr_validate() {
  local body="$1" expect_issue="$2" expect_blob="$3" expect_head="$4"
  local issue blob rhead
  case "$body" in
    *"$TASK_PR_MARK_BEGIN"*) ;;
    *) contract_err contract.pr_marker "PR 缺少自动管理区块"; return 1 ;;
  esac
  issue="$(contract_table_field "$body" "Issue")"
  blob="$(contract_table_field "$body" "Contract")"
  rhead="$(contract_table_field "$body" "reviewed HEAD")"
  [ -n "$issue" ] || { contract_err contract.pr_issue "PR 缺 Issue"; return 1; }
  [ -n "$blob" ] || { contract_err contract.unclassified "PR 缺 Contract"; return 1; }
  [ -n "$rhead" ] || { contract_err contract.pr_head "PR 缺 reviewed HEAD"; return 1; }
  if contract_stale "$blob" "$expect_blob" "PR"; then return 1; fi
  [ "$rhead" = "$expect_head" ] || { contract_err contract.pr_head_mismatch "PR reviewed HEAD 不一致"; return 1; }
  printf '%s\n' "$body" | tr -d '\r' | grep -qx "Fixes #${expect_issue}" \
    || { contract_err contract.pr_fixes "PR 缺少独立一行 Fixes #${expect_issue}"; return 1; }
  local summary verify
  summary="$(contract_review_section "$body" "变更摘要")"
  verify="$(contract_review_section "$body" "验证摘要")"
  [ -n "$(contract_trim "$summary")" ] || { contract_err contract.pr_summary "PR 缺变更摘要"; return 1; }
  [ -n "$(contract_trim "$verify")" ] || { contract_err contract.pr_verify "PR 缺验证摘要"; return 1; }
  return 0
}

# 领取时的 R/A 表：全部 pending / 尚未验证。

contract_checkpoint_pending_tables() {
  local json="$1" id
  printf '%s\n' "### R 进度"
  printf '%s\n' ""
  printf '%s\n' "| ID | 状态 | 证据 |"
  printf '%s\n' "| --- | --- | --- |"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    printf '| %s | pending | 尚未验证 |\n' "$id"
  done < <(jq -r '.requirements[].id' "$json")
  printf '\n%s\n\n' "### A 执行"
  printf '%s\n' "| ID | 状态 | 证据 |"
  printf '%s\n' "| --- | --- | --- |"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    printf '| %s | pending | 尚未验证 |\n' "$id"
  done < <(jq -r '.acceptances[].id' "$json")
}
