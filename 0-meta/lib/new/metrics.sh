# 度量：每个受管理入口（new task、z 系列）结束时追加一行 JSON。
# 只追加、不改写；写失败只打一行警告，不改变入口的退出码；不联网。
# 汇总用 new metrics。由 0-meta/bin/new 与 .agents/skills/z-lib.sh 加载，不要单独执行。
#
# 一行的形状（字段顺序固定，便于肉眼 diff）：
#   {"ts":"2026-09-07T08:12:33Z","issue":"o/r#26","entry":"zdev.wip-commit","result":"ok",
#    "reason_code":"","detail":"","duration_ms":812,"agent":"codex","head":"<sha>",
#    "labels":["meta"],"task_class":"framework","loaded_bytes":null}
#   fail 时 reason_code 为 <action>.<snake_case>；ok 时为空。loaded_bytes 只在 claim 有值。

METRICS_ENTRY=""
METRICS_T0=""
METRICS_DONE=0
METRICS_ISSUE=""
METRICS_AGENT=""
METRICS_LABELS="[]"
METRICS_LOADED=""
METRICS_TASK_CLASS=""
METRICS_STATE_FILE="${METRICS_STATE_FILE:-}"
METRICS_LAST_ERROR=""
METRICS_DIE_MESSAGE=""

# 入口状态必须能穿过 $(...) 子 shell。状态文件只存在于本机临时目录，
# 不作为 metrics 事件之外的事实源，也不进入仓库；每次 metrics_begin 都新建。
metrics_state_init() {
  local f=""
  f="$(mktemp "${TMPDIR:-/tmp}/new-metrics-state.XXXXXX" 2>/dev/null || true)"
  if [ -z "$f" ]; then
    f="$(mktemp -t new-metrics-state 2>/dev/null || true)"
  fi
  [ -n "$f" ] || return 1
  METRICS_STATE_FILE="$f"
  TMPS="${TMPS:-} $f"
}

metrics_state_clean() {
  local s="${1:-}"
  s="${s//$'\t'/ }"
  s="${s//$'\r'/ }"
  s="${s//$'\n'/ }"
  printf '%s' "$s"
}

metrics_state_save() {
  local f="${METRICS_STATE_FILE:-}" tmp
  [ -n "$f" ] || return 0
  tmp="$(mktemp "${f}.XXXXXX" 2>/dev/null)" || return 1
  {
    printf 'entry\t%s\n' "$(metrics_state_clean "$METRICS_ENTRY")"
    printf 't0\t%s\n' "$(metrics_state_clean "$METRICS_T0")"
    printf 'done\t%s\n' "$(metrics_state_clean "$METRICS_DONE")"
    printf 'issue\t%s\n' "$(metrics_state_clean "$METRICS_ISSUE")"
    printf 'agent\t%s\n' "$(metrics_state_clean "$METRICS_AGENT")"
    printf 'labels\t%s\n' "$(metrics_state_clean "$METRICS_LABELS")"
    printf 'loaded_bytes\t%s\n' "$(metrics_state_clean "$METRICS_LOADED")"
    printf 'task_class\t%s\n' "$(metrics_state_clean "$METRICS_TASK_CLASS")"
    printf 'reason_code\t%s\n' "$(metrics_state_clean "$METRICS_REASON_CODE")"
    printf 'last_error\t%s\n' "$(metrics_state_clean "$METRICS_LAST_ERROR")"
    printf 'die_message\t%s\n' "$(metrics_state_clean "$METRICS_DIE_MESSAGE")"
  } >"$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

metrics_state_load() {
  local f="${METRICS_STATE_FILE:-}" key value
  [ -n "$f" ] && [ -r "$f" ] || return 0
  while IFS=$'\t' read -r key value || [ -n "${key:-}" ]; do
    case "$key" in
      entry)       METRICS_ENTRY="${value:-}" ;;
      t0)          METRICS_T0="${value:-}" ;;
      done)        METRICS_DONE="${value:-0}" ;;
      issue)       METRICS_ISSUE="${value:-}" ;;
      agent)       METRICS_AGENT="${value:-}" ;;
      labels)      METRICS_LABELS="${value:-[]}" ;;
      loaded_bytes) METRICS_LOADED="${value:-}" ;;
      task_class)  METRICS_TASK_CLASS="${value:-}" ;;
      reason_code) METRICS_REASON_CODE="${value:-}" ;;
      last_error)  METRICS_LAST_ERROR="${value:-}" ;;
      die_message) METRICS_DIE_MESSAGE="${value:-}" ;;
    esac
  done <"$f"
}

# 按 origin 推导出的身份隔离本机 state；解析不了则 unknown。不进 git。
metrics_identity_dir() {
  local nwo
  if [ "$(type -t task_repo_nwo 2>/dev/null)" = function ]; then
    nwo="$(task_repo_nwo "${ROOT:-.}" 2>/dev/null || true)"
  elif [ "$(type -t task_github_nwo 2>/dev/null)" = function ]; then
    nwo="$(task_github_nwo "$(git -C "${ROOT:-.}" remote get-url origin 2>/dev/null || true)" 2>/dev/null || true)"
  fi
  if [ -n "${nwo:-}" ]; then
    printf '%s' "github.com-${nwo//\//-}"
    return 0
  fi
  printf '%s' unknown
}

metrics_file() {
  printf '%s/%s/metrics.jsonl\n' "${XDG_STATE_HOME:-$HOME/.local/state}" "$(metrics_identity_dir)"
}

metrics_now_ms() {
  perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000' 2>/dev/null \
    || echo $(( $(date +%s) * 1000 ))
}

# 入口开始时调用一次。entry 形如 new-task.claim / zdev.wip-commit。
metrics_begin() {
  METRICS_ENTRY="$1"
  METRICS_T0="$(metrics_now_ms)"
  METRICS_DONE=0
  METRICS_ISSUE=""
  METRICS_AGENT=""
  METRICS_LABELS="[]"
  METRICS_LOADED=""
  METRICS_REASON_CODE=""
  METRICS_TASK_CLASS=""
  METRICS_LAST_ERROR=""
  METRICS_DIE_MESSAGE=""
  LAST_ERR=""
  DIE_MSG=""
  METRICS_STATE_FILE=""
  metrics_state_init || true
  metrics_state_save || true
}

# 过程中补充字段。labels 必须是 JSON 数组字面量。
metrics_set() {
  local key="${1:-}" value="${2:-}"
  metrics_state_load
  case "$key" in
    issue)        METRICS_ISSUE="$value" ;;
    agent)        METRICS_AGENT="$value" ;;
    labels)       METRICS_LABELS="${value:-[]}" ;;
    loaded_bytes) METRICS_LOADED="$value" ;;
    task_class)   METRICS_TASK_CLASS="$value" ;;
    reason_code)  METRICS_REASON_CODE="$value" ;;
    last_error)   METRICS_LAST_ERROR="$value" ;;
    die_message)  METRICS_DIE_MESSAGE="$value" ;;
    *) return 1 ;;
  esac
  metrics_state_save || true
}

# entry 点号后的段：new-task.claim → claim，zdev.wip-commit → wip-commit。
metrics_action() {
  local e="${1:-$METRICS_ENTRY}"
  case "$e" in
    *.*) printf '%s' "${e##*.}" ;;
    *)   printf '%s' "${e:-unknown}" ;;
  esac
}

# 任一路径等于/位于 0-meta/ 或 .agents/ 之下，或是它们的祖先（如 .）→ framework。
# 解析不到返回空串，不猜。
metrics_task_class_from_scope() {
  local p norm class=""
  [ -n "${1:-}" ] || return 0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    norm="${p#./}"
    norm="${norm%/}"
    case "$norm" in
      .|0-meta|0-meta/*|.agents|.agents/*)
        printf '%s' framework
        return 0
        ;;
    esac
    class=business
  done <<< "$(printf '%s\n' "$1" | tr ' ' '\n')"
  printf '%s' "$class"
}

# 失败原因：去掉 ANSI 与「✗ · ⚠」前缀，压成一行，截到 200 字符。
metrics_clean_reason() {
  local s
  s="$(printf '%s' "$1" | sed -E $'s/\x1b\\[[0-9;]*m//g' | tr '\n' ' ' \
    | sed -E 's/^[[:space:]]*[✗·⚠]?[[:space:]]*//; s/[[:space:]]+/ /g; s/[[:space:]]+$//')"
  printf '%s' "${s:0:200}"
}

# 写一行。同一入口只写一次；重复调用 no-op。任何一步失败都只警告。
metrics_emit() {
  local result="${1:-}" reason="${2:-}" now dur ts head file line code detail
  local labels loaded
  metrics_state_load
  [ -n "$METRICS_ENTRY" ] || return 0
  [ "${METRICS_DONE:-0}" = 0 ] || return 0
  METRICS_DONE=1
  metrics_state_save || true
  command -v jq >/dev/null 2>&1 || return 0
  labels="${METRICS_LABELS:-[]}"
  if ! printf '%s' "$labels" | jq -e 'type == "array"' >/dev/null 2>&1; then
    c_warn "⚠ 度量 labels 不是 JSON 数组，已按空数组记录（不影响本次结果）"
    labels='[]'
  fi
  loaded="${METRICS_LOADED:-}"
  if [ -n "$loaded" ] && ! [[ "$loaded" =~ ^[0-9]+$ ]]; then
    c_warn "⚠ 度量 loaded_bytes 不是非负整数，已记为 null（不影响本次结果）"
    loaded=""
  fi
  now="$(metrics_now_ms)"
  dur=$(( now - ${METRICS_T0:-$now} ))
  [ "$dur" -ge 0 ] || dur=0
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  head="$(git -C "${ROOT:-.}" rev-parse HEAD 2>/dev/null || true)"
  if [ "$result" = ok ]; then
    code=""
    detail=""
  else
    detail="$(metrics_clean_reason "$reason")"
    code="${METRICS_REASON_CODE:-}"
    [ -n "$code" ] || code="$(metrics_action).unclassified"
  fi
  line="$(jq -cn \
    --arg ts "$ts" --arg issue "$METRICS_ISSUE" --arg entry "$METRICS_ENTRY" \
    --arg result "$result" --arg code "$code" --arg detail "$detail" \
    --argjson dur "$dur" --arg agent "$METRICS_AGENT" --arg head "$head" \
    --argjson labels "$labels" --arg tclass "$METRICS_TASK_CLASS" \
    --arg loaded "$loaded" \
    '{ts:$ts, issue:$issue, entry:$entry, result:$result, reason_code:$code,
      detail:$detail, duration_ms:$dur, agent:$agent, head:$head, labels:$labels,
      task_class:$tclass,
      loaded_bytes:(if $loaded == "" then null else ($loaded|tonumber) end)}' 2>/dev/null)" \
    || { c_warn "⚠ 度量行构造失败（不影响本次结果）"; return 0; }
  file="$(metrics_file)"
  if ! { mkdir -p "$(dirname "$file")" && printf '%s\n' "$line" >> "$file"; } 2>/dev/null; then
    c_warn "⚠ 度量写入失败：${file}（不影响本次结果）"
  fi
  return 0
}

# 按退出码收尾：0 → ok，否则 fail；detail 取 die 消息，其次最后一条 c_err。
metrics_finish() {
  local rc="${1:-0}" shell_code="${METRICS_REASON_CODE:-}" reason
  metrics_state_load
  if [ -z "${METRICS_REASON_CODE:-}" ] && [ -n "$shell_code" ]; then
    METRICS_REASON_CODE="$shell_code"
    metrics_state_save || true
  fi
  if [ "$rc" = 0 ]; then
    metrics_emit ok ""
  else
    reason="${METRICS_DIE_MESSAGE:-}"
    [ -n "$reason" ] || reason="${DIE_MSG:-}"
    [ -n "$reason" ] || reason="${METRICS_LAST_ERROR:-}"
    [ -n "$reason" ] || reason="${LAST_ERR:-exit=$rc}"
    metrics_emit fail "$reason"
  fi
  return 0
}

# 给入口脚本用的 EXIT trap：trap 'metrics_exit_trap $?' EXIT
# 先记度量再清临时文件；不 exit，所以不改变原退出码。
metrics_exit_trap() {
  metrics_finish "${1:-0}"
  tmp_cleanup
  return 0
}

# ── new metrics ────────────────────────────────────────────────────────────

metrics_usage() {
  cat <<'USAGE'
用法：new metrics [--since <n>d] [--file <path>]
用法：new metrics doctor [--file <path>]

  汇总本机度量 JSONL：入口 × 结果计数、耗时 p50/p90、开工加载字节数、
  framework:business 任务比、fail 按 reason_code 计数。
  文件默认在 ${XDG_STATE_HOME:-~/.local/state}/<origin-id>/metrics.jsonl，不进 git。
  origin-id 由 origin 推导（如 github.com-owner-repo）；解析不了则为 unknown。
  --since 7d   只看最近 7 天
  doctor       检查目录、jq、JSONL schema，以及同目录测试事件的写入/回读。
USAGE
}

METRICS_SCHEMA_JQ='
def metrics_string($key): (.[$key] | type) == "string";
def metrics_labels_ok:
  if (.labels | type) == "array"
  then all(.labels[]; type == "string")
  else false
  end;
def metrics_loaded_ok:
  (.loaded_bytes == null)
  or (((.loaded_bytes | type) == "number") and (.loaded_bytes >= 0));
def metrics_schema:
  if type != "object" then false
  else
    ((["ts","issue","entry","result","reason_code","detail","duration_ms",
       "agent","head","labels","task_class","loaded_bytes"] - keys) | length == 0)
    and metrics_string("ts")
    and ((.ts | try fromdateiso8601 catch null) != null)
    and metrics_string("issue")
    and metrics_string("entry")
    and ((.result == "ok") or (.result == "fail"))
    and metrics_string("reason_code")
    and (if .result == "fail" then (.reason_code != "") else true end)
    and metrics_string("detail")
    and ((.duration_ms | type) == "number")
    and (.duration_ms >= 0)
    and metrics_string("agent")
    and metrics_string("head")
    and metrics_labels_ok
    and metrics_string("task_class")
    and metrics_loaded_ok
  end;
'

metrics_schema_file_ok() {
  jq -s -e "$METRICS_SCHEMA_JQ
all(.[]; metrics_schema)" "$1" >/dev/null 2>&1
}

# doctor 与 summary 共用这一份入口分类：control-plane 只参与健康判定，
# task-runtime 才参与字段门禁与 framework:business 统计。
METRICS_EVENT_CLASS_JQ='
def metrics_event_class:
  if ((.entry | type) != "string") then "unmanaged"
  elif (.entry == "new-task.approve" or .entry == "new-task.bind") then "control-plane"
  elif ((.entry | startswith("new-task."))
        or (.entry | startswith("z"))) then "task-runtime"
  else "unmanaged"
  end;
'

METRICS_HEALTH_JQ="${METRICS_EVENT_CLASS_JQ}"'
. as $all
| [
    $all[]
    | select((try metrics_schema catch false))
    | . + {event_class: metrics_event_class}
  ] as $classified
| {
    malformed: ([$all[] | select((try metrics_schema catch false) | not)] | length),
    managed: ([$classified[] | select(.event_class != "unmanaged")] | length),
    control_plane: ([$classified[] | select(.event_class == "control-plane")] | length),
    broken: ([
      $classified[]
      | select(.event_class == "task-runtime")
      | select(
          ((.issue | type) != "string")
          or (.issue == "")
          or ((.head | type) != "string")
          or (.head == "")
          or ((.task_class != "framework")
              and (.task_class != "business"))
          or ((.result == "fail") and (.reason_code == ""))
        )
    ] | length),
    framework: ([$classified[]
      | select(.event_class == "task-runtime"
               and .issue != ""
               and .task_class == "framework")] | length),
    business: ([$classified[]
      | select(.event_class == "task-runtime"
               and .issue != ""
               and .task_class == "business")] | length)
  }
'

# 检查已解析的事件是否能解释；summary 只警告，doctor 将其作为失败。
metrics_health_from_rows() {
  local rows="$1" stats malformed managed broken control_plane framework business
  if [ -z "$rows" ]; then
    c_warn "⚠ 采集健康未知：没有可识别的受管理事件，无法把 business=0 解读为真实业务结果"
    return 1
  fi
  stats="$(printf '%s\n' "$rows" | jq -rs "$METRICS_SCHEMA_JQ
$METRICS_HEALTH_JQ" 2>/dev/null)" \
    || {
      c_warn "⚠ 采集健康未知/失败：无法读取 metrics 事件字段，framework:business 不可信"
      return 1
    }
  malformed="$(printf '%s' "$stats" | jq -r '.malformed')"
  managed="$(printf '%s' "$stats" | jq -r '.managed')"
  broken="$(printf '%s' "$stats" | jq -r '.broken')"
  control_plane="$(printf '%s' "$stats" | jq -r '.control_plane')"
  framework="$(printf '%s' "$stats" | jq -r '.framework')"
  business="$(printf '%s' "$stats" | jq -r '.business')"
  if [ "$malformed" -gt 0 ] || [ "$broken" -gt 0 ]; then
    c_warn "⚠ 采集健康未知/失败：$malformed 条 schema 异常，$broken 条受管理事件缺少 issue/head/task_class 或 fail reason_code；framework:business 不可信"
    return 1
  fi
  if [ "$managed" = 0 ]; then
    c_warn "⚠ 采集健康未知：没有可识别的受管理事件，无法把 business=0 解读为真实业务结果"
    return 1
  fi
  if [ "$control_plane" -gt 0 ] && [ "$framework" = 0 ] && [ "$business" = 0 ]; then
    c_ok "✓ 采集健康：control-plane 事件合法；当前没有 task-runtime / business 事件"
  elif [ "$framework" -gt 0 ] && [ "$business" = 0 ]; then
    c_ok "✓ 采集健康：受管理事件字段完整；当前窗口只有 framework 事件，没有 business 事件（business=0 不是采集器故障）"
  else
    c_ok "✓ 采集健康：受管理事件字段完整，framework=$framework business=$business"
  fi
  return 0
}

metrics_doctor() {
  local file="$1" dir probe line fail=0 rows
  dir="$(dirname "$file")"
  if ! mkdir -p "$dir" 2>/dev/null; then
    c_err "采集健康失败：metrics 目录不可创建：$dir"
    fail=1
  elif [ ! -d "$dir" ] || [ ! -w "$dir" ]; then
    c_err "采集健康失败：metrics 目录不可写：$dir"
    fail=1
  else
    c_ok "✓ metrics 目录可写：$dir"
  fi

  if [ -e "$file" ]; then
    if [ ! -r "$file" ]; then
      c_err "采集健康失败：metrics 文件不可读：$file"
      fail=1
    elif [ ! -w "$file" ]; then
      c_err "采集健康失败：metrics 文件不可写：$file"
      fail=1
    elif [ -s "$file" ] && ! metrics_schema_file_ok "$file"; then
      c_err "采集健康失败：metrics JSONL 解析失败或字段 schema 不完整：$file"
      fail=1
    else
      c_ok "✓ metrics JSONL 可解析且 schema 完整：$file"
    fi
  else
    c_ok "✓ metrics 文件尚不存在，将以空样本开始：$file"
  fi

  if [ -d "$dir" ] && [ -w "$dir" ]; then
    probe="$(mktemp "$dir/.metrics-doctor.XXXXXX" 2>/dev/null || true)"
    if [ -z "$probe" ]; then
      c_err "采集健康失败：无法创建同目录测试文件：$dir"
      fail=1
    else
      TMPS="$TMPS $probe"
      line="$(jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{ts:$ts, issue:"metrics.doctor", entry:"metrics.doctor", result:"ok",
          reason_code:"", detail:"doctor probe", duration_ms:0, agent:"doctor",
          head:"doctor", labels:[], task_class:"framework", loaded_bytes:null}')"
      if ! printf '%s\n' "$line" >"$probe" \
          || ! jq -s -e "$METRICS_SCHEMA_JQ
            (length == 1 and all(.[]; metrics_schema)
             and .[0].entry == \"metrics.doctor\")" "$probe" >/dev/null 2>&1; then
        c_err "采集健康失败：测试事件写入或回读失败：$dir"
        fail=1
      else
        c_ok "✓ 测试事件可写入并回读"
      fi
      rm -f "$probe"
      tmp_unregister "$probe"
    fi
  fi

  if [ "$fail" = 0 ] && [ -s "$file" ]; then
    rows="$(jq -c . "$file" 2>/dev/null || true)"
    metrics_health_from_rows "$rows" || fail=1
  elif [ "$fail" = 0 ]; then
    c_ok "✓ 尚无受管理事件；采集器自检通过，business=0 未作业务结论"
  fi
  [ "$fail" = 0 ]
}

METRICS_JQ_REPORT="${METRICS_EVENT_CLASS_JQ}"'
def pct(p):
  if length == 0 then null
  else (sort as $s | $s[([((length * p) | ceil) - 1, 0] | max)])
  end;
def n(x): if x == null then "-" else (x|tostring) end;

map(select(try metrics_schema catch false))
| map(select($cutoff == 0 or ((.ts | try fromdateiso8601 catch 0) >= $cutoff)))
| map(. + {event_class: metrics_event_class})
| . as $ev
| ($ev | map(select(.event_class == "task-runtime"
                    and .issue != ""
                    and (.task_class == "framework" or .task_class == "business")))
        | group_by(.issue) | map(.[0])) as $tasks
| ($tasks | map(select(.task_class == "framework")) | length) as $fw
| ($tasks | map(select(.task_class == "business")) | length) as $biz
| "事件 \($ev|length) 条",
  "",
  "── 入口 × 结果 ────────────────────────────",
  ( $ev | group_by(.entry) | .[]
    | "\(.[0].entry)\tok=\(map(select(.result=="ok"))|length)\tfail=\(map(select(.result=="fail"))|length)" ),
  "",
  "── 耗时 ms（p50 / p90）────────────────────",
  ( $ev | group_by(.entry) | .[]
    | (map(.duration_ms | numbers)) as $d
    | "\(.[0].entry)\t\(n($d|pct(0.5)))\t\(n($d|pct(0.9)))" ),
  "",
  "── 开工加载（new-task.claim 的 loaded_bytes）──",
  ( ($ev | map(select(.entry == "new-task.claim" and (.loaded_bytes|type) == "number") | .loaded_bytes)) as $lb
    | "样本 \($lb|length)\t中位数 \(n($lb|pct(0.5))) 字节" ),
  "",
  "── 任务构成（按 task_class，Issue 去重）──────",
  "framework \($fw)\tbusiness \($biz)\tframework:business = \($fw):\($biz)",
  "",
  "── 失败 reason_code ────────────────────────",
  ( $ev | map(select(.result == "fail" and (.reason_code|type) == "string" and .reason_code != ""))
        | group_by(.reason_code) | sort_by(-length)[]
    | "\(length)×\t\(.[0].reason_code)" )
'

cmd_metrics() {
  local mode=summary
  if [ "${1:-}" = doctor ]; then
    mode=doctor
    shift
  fi
  local since_days="" file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --since)
        [ -n "${2:-}" ] || die_code metrics.bad_since "--since 后面要跟 <n>d，如 7d"
        since_days="${2%d}"
        [[ "$since_days" =~ ^[0-9]+$ ]] || die_code metrics.bad_since "--since 只接受 <n>d，如 7d"
        shift 2 ;;
      --file) [ -n "${2:-}" ] || die_code metrics.bad_file "--file 后面要跟路径"; file="$2"; shift 2 ;;
      -h|--help) metrics_usage; return 0 ;;
      *) die_code metrics.unknown_arg "未知参数：$1"$'\n'"$(metrics_usage)" ;;
    esac
  done
  command -v jq >/dev/null 2>&1 || die_code task.missing_jq "找不到 jq（new setup 会装）。"
  [ -n "$file" ] || file="$(metrics_file)"
  if [ "$mode" = doctor ]; then
    metrics_doctor "$file"
    return $?
  fi
  if [ ! -s "$file" ]; then
    echo "暂无度量数据：${file}"
    echo "受管理入口（new task、z 系列）每次结束都会追加一行；跑过一次再来看。"
    c_warn "⚠ 采集健康未知：尚无受管理事件，不能把 business=0 当作真实业务结论"
    return 0
  fi
  local cutoff=0
  [ -z "$since_days" ] || cutoff=$(( $(date +%s) - since_days * 86400 ))
  echo "度量文件：${file}"
  # 整份能解析就一次过；有坏行时退回逐行解析，丢坏行而不是让整份报告失败。
  local rows parse_failed=0
  if ! rows="$(jq -c . "$file" 2>/dev/null)"; then
    parse_failed=1
    c_warn "⚠ 采集健康未知/失败：度量文件里有无法解析的行，已跳过坏行；framework:business 不可信"
    rows="$(while IFS= read -r l; do printf '%s\n' "$l" | jq -c . 2>/dev/null || true; done < "$file")"
  fi
  if [ "$parse_failed" = 0 ]; then
    metrics_health_from_rows "$rows" || true
  fi
  printf '%s\n' "$rows" | jq -rs --argjson cutoff "$cutoff" "$METRICS_SCHEMA_JQ
$METRICS_JQ_REPORT"
}
