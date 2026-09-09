# zmerge squash commit body：只汇编 Issue / Checkpoint / Review / PR 已有事实。
# 由 squash-merge.sh 加载；check-squash-body.sh 可单独 source，不调用 z_load。
# 不发明技术判断，不把 WIP 标题当主线说明，不写入 worktree 路径 / push 日志。

z_sb_section() {
  local text="$1" title="$2"
  printf '%s\n' "$text" | awk -v title="$title" '
    BEGIN { grab=0; level=0 }
    {
      line = $0
      sub(/\r$/, "", line)
      if (line ~ /^#{1,6}[ \t]+/) {
        h = line
        sub(/^#+[ \t]+/, "", h)
        sub(/[ \t]+$/, "", h)
        n = 0
        tmp = line
        while (tmp ~ /^#/) { n++; sub(/^#/, "", tmp) }
        if (h == title) { grab=1; level=n; next }
        if (grab && n <= level) exit
      }
      if (grab) print line
    }
  '
}

z_sb_table_field() {
  task_review_table_field "$1" "$2"
}

z_sb_list_field() {
  local text="$1" key="$2"
  printf '%s\n' "$text" | awk -v key="$key" '
    BEGIN { grab=0 }
    {
      line = $0
      sub(/\r$/, "", line)
      if (line ~ /^- /) {
        rest = line
        sub(/^- +/, "", rest)
        k = rest
        sub(/[：:].*/, "", k)
        sub(/[ \t]+$/, "", k)
        if (k == key) {
          grab=1
          val = rest
          sub(/^[^：:]*[：:][ \t]*/, "", val)
          if (val != "") print val
          next
        }
        if (grab) exit
      } else if (grab) {
        if (line == "" || line ~ /^[ \t]/) {
          sub(/^[ \t]+/, "", line)
          if (line != "") print line
        } else exit
      }
    }
  '
}

z_sb_pr_human() {
  local text="$1"
  printf '%s\n' "$text" | awk '
    BEGIN { begin="<!-- new-task-pr -->"; end="<!-- /new-task-pr -->"; skip=0 }
    {
      line = $0
      sub(/\r$/, "", line)
      if (line == begin) { skip=1; next }
      if (skip && line == end) { skip=0; next }
      if (!skip) print line
    }
  '
}

z_sb_strip_bullet() {
  local t="$1"
  case "$t" in
    '- '*) t="${t#- }" ;;
    '* '*) t="${t#\* }" ;;
  esac
  t="${t#"${t%%[![:space:]]*}"}"
  printf '%s' "$t"
}

z_sb_line_drop() {
  local line="$1" drop_wip="${2:-0}"
  case "$line" in
    *'/Users/'*|*'/home/'*|*'/tmp/'*|*'/var/folders/'*) return 0 ;;
    '```'*) return 0 ;;
    '<!--'*) return 0 ;;
    '#'*) return 0 ;;
    '|'*) return 0 ;;
  esac
  if printf '%s' "$line" | grep -Eq 'push origin |git push |Enumerating objects|Writing objects|Counting objects|To github\.com|To https://github\.com|^remote: |Orca 管理'; then
    return 0
  fi
  if [ "$drop_wip" = 1 ]; then
    if printf '%s' "$line" | grep -Eq '^[[:space:]]*[-*]?[[:space:]]*wip:'; then
      return 0
    fi
    if printf '%s' "$line" | grep -Eq 'files? changed'; then
      return 0
    fi
    if printf '%s' "$line" | grep -Eq '^[[:space:]]*[^[:space:]|]+[[:space:]]+\|[[:space:]]+[0-9]+'; then
      return 0
    fi
  fi
  return 1
}

z_sb_to_bullets() {
  local text="$1" drop_wip="${2:-0}" line t out=""
  while IFS= read -r line || [ -n "$line" ]; do
    t="$line"
    t="${t%$'\r'}"
    t="${t#"${t%%[![:space:]]*}"}"
    t="${t%"${t##*[![:space:]]}"}"
    [ -n "$t" ] || continue
    z_sb_line_drop "$t" "$drop_wip" && continue
    t="$(z_sb_strip_bullet "$t")"
    [ -n "$t" ] || continue
    z_sb_line_drop "$t" "$drop_wip" && continue
    out="${out}- ${t}"$'\n'
  done <<< "$text"
  printf '%s' "$out"
}

z_sb_one_line() {
  local text="$1" drop_wip="${2:-0}" line t out=""
  while IFS= read -r line || [ -n "$line" ]; do
    t="$line"
    t="${t%$'\r'}"
    t="${t#"${t%%[![:space:]]*}"}"
    t="${t%"${t##*[![:space:]]}"}"
    [ -n "$t" ] || continue
    z_sb_line_drop "$t" "$drop_wip" && continue
    t="$(z_sb_strip_bullet "$t")"
    [ -n "$t" ] || continue
    z_sb_line_drop "$t" "$drop_wip" && continue
    [ "$t" = "未记录" ] && continue
    if [ -n "$out" ]; then
      out="${out}；${t}"
    else
      out="$t"
    fi
  done <<< "$text"
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
  else
    if [ "${Z_SQUASH_STRICT:-1}" = 1 ]; then
      return 1
    fi
    printf '%s\n' '未记录'
  fi
}

z_sb_or_missing() {
  local bullets="$1"
  if [ -z "${bullets//[$' \t\n']/}" ]; then
    if [ "${Z_SQUASH_STRICT:-1}" = 1 ]; then
      return 1
    fi
    printf '%s\n' '- 未记录'
    return 0
  fi
  printf '%s\n' "$bullets"
}

z_sb_compose_background() {
  local issue="$1" sec
  sec="$(z_sb_section "$issue" "背景")"
  [ -n "$sec" ] || sec="$(z_sb_section "$issue" "目标")"
  z_sb_or_missing "$(z_sb_to_bullets "$sec")"
}

z_sb_compose_changes() {
  local ck="$1" review="$2" pr="$3"
  local reason human summary bullets=""
  reason="$(z_sb_section "$review" "通过理由")"
  bullets="$(z_sb_to_bullets "$reason")"
  if [ -z "${bullets//[$' \t\n']/}" ]; then
    human="$(z_sb_pr_human "$pr")"
    bullets="$(z_sb_to_bullets "$human" 1)"
  fi
  if [ -z "${bullets//[$' \t\n']/}" ]; then
    summary="$(z_sb_section "$pr" "变更摘要")"
    bullets="$(z_sb_to_bullets "$summary" 1)"
  fi
  if [ -z "${bullets//[$' \t\n']/}" ]; then
    bullets="$(z_sb_to_bullets "$(z_sb_section "$ck" "改动")" 1)"
  fi
  z_sb_or_missing "$bullets"
}

z_sb_compose_verify() {
  local ck="$1" review="$2"
  local min ran cov skip risk ev ck_ev scope
  min="$(z_sb_section "$review" "最小充分审查")"
  ran="$(z_sb_list_field "$min" "新增验证")"
  [ -n "$ran" ] || ran="$(z_sb_list_field "$min" "实际运行")"
  if [ -z "$ran" ]; then
    ev="$(z_sb_section "$review" "证据")"
    ran="$(z_sb_to_bullets "$ev")"
  fi
  cov="$(z_sb_list_field "$min" "覆盖范围")"
  if [ -z "$cov" ]; then
    scope="$(z_sb_table_field "$review" "范围")"
    cov="$scope"
  fi
  skip="$(z_sb_list_field "$min" "未执行的大范围验证")"
  risk="$(z_sb_list_field "$min" "剩余风险")"
  if [ -z "$ran" ]; then
    ck_ev="$(z_sb_section "$ck" "验证证据")"
    ran="$(z_sb_to_bullets "$ck_ev")"
  fi
  printf '%s\n' "- 实际运行：$(z_sb_one_line "$ran")"
  printf '%s\n' "- 覆盖范围：$(z_sb_one_line "$cov")"
  printf '%s\n' "- 未执行的大范围验证：$(z_sb_one_line "$skip")"
  printf '%s\n' "- 剩余风险：$(z_sb_one_line "$risk")"
}

z_sb_compose_notes() {
  local issue="$1" review="$2" number="$3" pr_num="$4"
  local scope risk bullets
  if [ -n "${Z_CONTRACT_JSON:-}" ] && [ -f "$Z_CONTRACT_JSON" ]; then
    bullets="$(jq -r '.scope[] | "- " + .' "$Z_CONTRACT_JSON")"
  else
    scope="$(z_sb_section "$issue" "允许改动范围")"
    bullets="$(z_sb_to_bullets "$scope" 1)"
  fi
  z_sb_or_missing "$bullets" || return 1
  if [ -n "${Z_CONTRACT_BLOB:-}" ]; then
    printf '%s\n' "- Contract: ${Z_CONTRACT_BLOB}"
  fi
  risk="$(z_sb_list_field "$(z_sb_section "$review" "最小充分审查")" "剩余风险")"
  if [ -z "$risk" ] || [ "$risk" = "未记录" ]; then
    if [ "${Z_SQUASH_STRICT:-1}" = 1 ]; then
      return 1
    fi
  else
    printf '%s\n' "- 剩余风险：${risk}"
  fi
  printf '%s\n' "- Fixes #${number}"
  printf '%s\n' "- PR #${pr_num}"
}

z_compose_squash_body() {
  local issue_file="$1" ck_file="$2" review_file="$3" pr_file="$4"
  local number="$5" pr_num="$6"
  local issue ck review pr
  [ -f "$issue_file" ] && [ -f "$ck_file" ] && [ -f "$review_file" ] && [ -f "$pr_file" ] \
    || return 1
  [[ "$number" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ "$pr_num" =~ ^[1-9][0-9]*$ ]] || return 1
  issue="$(cat "$issue_file")"
  ck="$(cat "$ck_file")"
  review="$(cat "$review_file")"
  pr="$(cat "$pr_file")"
  printf '%s\n' "背景"
  z_sb_compose_background "$issue" || return 1
  printf '\n%s\n' "改动"
  z_sb_compose_changes "$ck" "$review" "$pr" || return 1
  printf '\n%s\n' "验证"
  z_sb_compose_verify "$ck" "$review" || return 1
  printf '\n%s\n' "备注"
  z_sb_compose_notes "$issue" "$review" "$number" "$pr_num" || return 1
}

z_validate_squash_body() {
  local body="$1" number="$2" pr_num="$3"
  local need
  [ -n "$body" ] || return 1
  [[ "$number" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ "$pr_num" =~ ^[1-9][0-9]*$ ]] || return 1
  for need in 背景 改动 验证 备注; do
    printf '%s\n' "$body" | grep -qx "$need" || return 1
  done
  printf '%s\n' "$body" | grep -Eq "^(- )?Fixes #${number}$" || return 1
  printf '%s\n' "$body" | grep -Eq "^(- )?PR #${pr_num}$" || return 1
  printf '%s\n' "$body" | grep -Eq '/Users/|/home/|/tmp/|/var/folders/|push origin |git push ' \
    && return 1
  if [ "${Z_SQUASH_STRICT:-1}" = 1 ]; then
    if printf '%s\n' "$body" | awk '
      BEGIN { sec="" }
      $0=="背景" || $0=="改动" || $0=="验证" { sec=$0; next }
      $0=="备注" { sec="备注"; next }
      (sec=="背景" || sec=="改动" || sec=="验证") && ($0=="- 未记录" || $0 ~ /：未记录$/) { exit 1 }
    '; then
      :
    else
      return 1
    fi
    printf '%s\n' "$body" | grep -Eq '剩余风险' || return 1
    if [ -n "${Z_CONTRACT_BLOB:-}" ]; then
      printf '%s\n' "$body" | grep -Fq "Contract: ${Z_CONTRACT_BLOB}" || return 1
    fi
  fi
  if printf '%s\n' "$body" | awk '
    BEGIN { inchg=0; n=0; wip=0; missing=0 }
    $0 == "改动" { inchg=1; next }
    inchg && ($0 == "验证" || $0 == "备注" || $0 == "背景") { exit }
    inchg && $0 ~ /[^[:space:]]/ {
      n++
      if ($0 ~ /未记录/) missing++
      if ($0 ~ /wip:/) wip++
    }
    END { if (n == 0) exit 1; if (n > 0 && wip == n) exit 1; if (n == missing && n > 0) exit 0 }
  '; then
    :
  else
    return 1
  fi
  return 0
}
