#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# derive-paths.sh — 从 policy.yaml 推导「备份 / 同步 / 权限」的规则集合
#
# 这是 v2.1 的核心：备份清单和同步清单不再手写，由本脚本从唯一事实源算出。
# 输出格式是扁平的 `key = value`，排过序，为的是让 git diff 可读——
# derived.lock 的 diff 本身就是变更预览。
#
# 注意范围：本脚本只推导「规则集合」，不展开具体文件路径。
# 规则集合小而稳定，适合进 git；路径展开有 25 万条且每天都变，属于运行产物。
#
# 用法：
#   derive-paths.sh              输出规则集合到 stdout
#   derive-paths.sh --json       输出 policy 的 JSON 形式（调试用）
# ─────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail
export LC_COLLATE=C

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/../../.." && pwd)"
POLICY="$ROOT/0-meta/policy.yaml"

[ -f "$POLICY" ] || { echo "找不到 $POLICY" >&2; exit 2; }

# ── YAML → JSON。三条后路，任一可用即可 ──────────────────────────────────
yaml2json() {
  if command -v yq >/dev/null 2>&1; then
    yq -o=json '.' "$1"
  elif command -v ruby >/dev/null 2>&1; then
    ruby -ryaml -rjson -e 'puts YAML.load_file(ARGV[0]).to_json' "$1"
  elif python3 -c 'import yaml' >/dev/null 2>&1; then
    python3 -c 'import sys,yaml,json; json.dump(yaml.safe_load(open(sys.argv[1])),sys.stdout)' "$1"
  else
    echo "需要 yq / ruby / python3+pyyaml 三者之一来解析 YAML。" >&2
    echo "推荐：brew install yq" >&2
    exit 2
  fi
}

command -v jq >/dev/null 2>&1 || { echo "需要 jq。brew install jq" >&2; exit 2; }

J="$(yaml2json "$POLICY")"

if [ "${1:-}" = "--json" ]; then echo "$J" | jq '.'; exit 0; fi

POLICY_SHA="$(shasum -a 256 "$POLICY" | awk '{print $1}')"

# 把 jq 的数组结果压成空格分隔的一行，并排序去重
flat() { jq -r "$1" <<<"$J" | sort -u | tr '\n' ' ' | sed 's/ *$//'; }
one()  { jq -r "$1" <<<"$J"; }

# ── 头 ────────────────────────────────────────────────────────────────────
cat <<EOF
# ═══════════════════════════════════════════════════════════════════════════
# derived.lock —— 由 0-meta/policy.yaml 推导而来。不要手改。
#
# 改完 policy.yaml 跑 \`new plan\` 重算；policy.yaml 与本文件必须同一个 commit。
# 本文件的 git diff 就是变更预览：它记录规则集合，不记录展开后的文件路径。
#
# 生成器：0-meta/audit/scripts/derive-paths.sh
# ═══════════════════════════════════════════════════════════════════════════

schema = derived/v1
policy_sha256 = $POLICY_SHA
EOF

# A5：不把本机绝对路径写入 tracked lock。`.` / 空 = 仓库自身，lock 写空，
# 让备份脚本用自身位置反推仓库根（root 为空时跳过绝对路径比对）。
root_raw="$(one '.root')"
case "$root_raw" in
  /*)
    echo "policy.yaml 的 root 是本机绝对路径（${root_raw}）。改为 \".\" 或留空。" >&2
    exit 1
    ;;
  .|""|null)
    echo "# root 为空：运行时用 git toplevel；禁止 tracked 本机绝对路径（#41 A5）"
    echo "root ="
    ;;
  *)
    echo "root = $root_raw"
    ;;
esac
echo

# ── 备份 ──────────────────────────────────────────────────────────────────
# 应备份集合 = 全部路径
#            − regenerable（强证据 + 弱证据）
#            − build_output（源码已推送时）
#            − always_disposable
#            − os_metadata
#            − reserved_dirs where backup == forbidden
#            − domains where backup == forbidden
echo "# ── 备份 ─────────────────────────────────────────────────────────────────"
echo "backup.include = $(flat '.domains | to_entries[] | select(.value.backup == "required") | .key')"
echo "backup.exclude.domains = $(flat '.domains | to_entries[] | select(.value.backup == "forbidden") | .key')"
echo "backup.exclude.reserved = $(flat '.reserved_dirs | to_entries[] | select(.value.backup == "forbidden") | .key')"
echo "backup.keep.reserved = $(flat '.reserved_dirs | to_entries[] | select(.value.backup == "required") | .key')"
echo "backup.exclude.regenerable_strict = $(flat '.regenerable.strict_lock | keys[]')"
echo "backup.exclude.regenerable_weak = $(flat '.regenerable.weak_declaration | keys[]')"
echo "backup.exclude.build_output = $(flat '.regenerable.build_output.dirs[]')"
echo "backup.exclude.always_disposable = $(flat '.regenerable.always_disposable[]')"
echo "backup.exclude.os_metadata = $(flat '.regenerable.os_metadata[]')"
# 上面三类里，regenerable 与 build_output 是**条件**排除：目录名命中不等于可以不备份，
# 还要看同级有没有锁文件、源码推没推。把「什么算证据」也导出来，
# 生成器才能照策略判断，而不是把条件排除退化成无条件排除。
for d in $(jq -r '.regenerable.strict_lock | keys[]' <<<"$J" | sort); do
  echo "backup.evidence.strict.${d} = $(flat ".regenerable.strict_lock[\"$d\"][]")"
done
for d in $(jq -r '.regenerable.weak_declaration | keys[]' <<<"$J" | sort); do
  echo "backup.evidence.weak.${d} = $(flat ".regenerable.weak_declaration[\"$d\"][]")"
done
echo "backup.evidence.build_output.rule = $(one '.regenerable.build_output.evidence')"
echo "backup.evidence.build_output.fallback = $(flat '.regenerable.build_output.fallback_weak[]')"
echo "backup.evidence.promote_pinned.requirements_txt = $(one '.regenerable.promote_if_fully_pinned["requirements.txt"]')"
echo "backup.destinations = $(flat '.backup.destinations[].name')"
# 每个目的地的 repo 与频率单独成行。备份脚本从 lock 读它们，不在脚本里写死——
# 换一个目的地是一次 policy 修改加一次 new plan，不是去 grep 哪个脚本硬编码了 URL。
for d in $(jq -r '.backup.destinations[].name' <<<"$J" | sort); do
  echo "backup.dest.${d}.repo = $(jq -r --arg d "$d" '.backup.destinations[] | select(.name == $d) | .repo' <<<"$J")"
  echo "backup.dest.${d}.schedule = $(jq -r --arg d "$d" '.backup.destinations[] | select(.name == $d) | .schedule' <<<"$J")"
done
echo "backup.password_source = $(one '.backup.password_source')"
echo "backup.password_recovery = $(flat '.backup.password_recovery[]?')"
echo "backup.password_offline_copy_required = $(one '.backup.password_offline_copy_required')"
echo "backup.password_offline_copy_attestation = $(one '.backup.password_offline_copy_attestation // ""')"
echo "backup.retention.keep_last = $(one '.backup.retention.keep_last')"
echo "backup.retention.keep_weekly = $(one '.backup.retention.keep_weekly')"
echo "backup.retention.keep_monthly = $(one '.backup.retention.keep_monthly')"
echo "backup.restore_drill_days = $(one '.backup.restore_drill.interval_days')"
# 备份根之外仍需收录的路径。目前只有 worktree 根——它是仓库根的兄弟目录，
# 不显式列出就不会被 restic 收，而 worktree 里未提交的工作副本数为零。
echo "backup.external_paths = $(flat '.backup.external_paths[]?.path')"
echo

# 人恢复必须有至少一个本机之外的来源。password_source 允许是 keychain://
# （否则 launchd 跑不起来），但如果 recovery 也全是本机，Mac 挂了就是死循环。
RECOVERY="$(flat '.backup.password_recovery[]?')"
OFF_MACHINE=""
for r in $RECOVERY; do
  case "$r" in
    # pass:// 的密文与解密私钥默认都在本机，不能把它误算为离机恢复来源。
    bw://*|op://*|vault://*|paper|paper://*) OFF_MACHINE="$OFF_MACHINE $r" ;;
  esac
done
if [ -z "$OFF_MACHINE" ]; then
  echo "# !! backup.password_recovery 没有本机之外的来源（bw:// / op:// / paper）—— Mac 挂了就是死循环"
  echo "backup.password_recovery_gap = no_off_machine_source"
  echo
fi

# 任何域使用了已废弃的 not_required，直接报出来
DEPRECATED="$(flat '.domains | to_entries[] | select(.value.backup == "not_required") | .key')"
if [ -n "$DEPRECATED" ]; then
  echo "# !! 以下域仍在使用已废弃的 backup: not_required —— $DEPRECATED"
  echo "backup.deprecated_not_required = $DEPRECATED"
  echo
fi

# ── 同步 ──────────────────────────────────────────────────────────────────
echo "# ── 同步（热镜像，不计入副本数）────────────────────────────────────────"
echo "sync.target = $(one '.sync.target')"
echo "sync.mode = $(one '.sync.mode')"
echo "sync.include = $(flat '.domains | to_entries[] | select(.value.sync == "allowed") | .key')"
echo "sync.forbid.domains = $(flat '.domains | to_entries[] | select(.value.sync == "forbidden") | .key')"
echo "sync.forbid.reserved = $(flat '.reserved_dirs | to_entries[] | select(.value.sync == "forbidden") | .key')"
echo "sync.flags_denylist = $(flat '.sync.rsync_flags_denylist[]')"
echo "sync.counts_as_backup_copy = $(one '.sync.counts_as_backup_copy')"
echo

# 交叉校验：policy 手写的 forbid_domains 是否漏了某个 sync:forbidden 的域
COMPUTED_FORBID="$(flat '.domains | to_entries[] | select(.value.sync == "forbidden") | .key')"
DECLARED_FORBID="$(flat '.sync.forbid_domains[]')"
MISSING=""
for d in $COMPUTED_FORBID; do
  case " $DECLARED_FORBID " in *" $d "*) ;; *) MISSING="$MISSING $d" ;; esac
done
if [ -n "$MISSING" ]; then
  echo "# !! sync.forbid_domains 手写清单漏了：${MISSING}（域策略已声明 forbidden）"
  echo "sync.forbid_domains_gap =${MISSING}"
  echo
fi

# ── 保留名 ────────────────────────────────────────────────────────────────
echo "# ── 保留名（任意深度生效）────────────────────────────────────────────"
for r in $(jq -r '.reserved_dirs | keys[]' <<<"$J" | sort); do
  b="$(jq -r --arg r "$r" '.reserved_dirs[$r].backup // "-"' <<<"$J")"
  s="$(jq -r --arg r "$r" '.reserved_dirs[$r].sync // "-"' <<<"$J")"
  v="$(jq -r --arg r "$r" '.reserved_dirs[$r].vcs // "-"' <<<"$J")"
  m="$(jq -r --arg r "$r" '.reserved_dirs[$r].mutable // "-"' <<<"$J")"
  echo "reserved.$r = backup:$b sync:$s vcs:$v mutable:$m"
done
echo

# ── Git ───────────────────────────────────────────────────────────────────
# 跟踪范围是一组规则，不是路径展开。它和备份范围是两件事：
# 备份问「丢了能不能回来」，git 问「值不值得留改动历史」。
echo "# ── Git（monorepo 跟踪范围）──────────────────────────────────────────"
echo "git.mode = $(one '.git.mode')"
echo "git.root = $(one '.git.root')"
echo "git.default_branch = $(one '.git.default_branch')"
echo "git.tracked_domains = $(flat '.git.tracked_domains[]')"
echo "git.partial_domains = $(flat '.git.partial_domains | keys[]')"
for d in $(jq -r '.git.partial_domains | keys[]' <<<"$J" | sort); do
  echo "git.partial.${d}.track = $(flat ".git.partial_domains[\"$d\"].track[]")"
  echo "git.partial.${d}.never = $(flat ".git.partial_domains[\"$d\"].never[]")"
done
echo "git.never_domains = $(flat '.git.never_domains[]')"
for d in $(jq -r '.git.never_domain_exceptions | keys[]' <<<"$J" | sort); do
  echo "git.never_exception.${d} = $(flat ".git.never_domain_exceptions[\"$d\"][]")"
done
echo "git.never_reserved = $(flat '.git.never_reserved[]')"
echo "git.max_tracked_file_bytes = $(one '.git.max_tracked_file_bytes')"
echo "git.branch.long_lived = $(flat '.git.branching.long_lived[]')"
# v2.4：分支前缀不再手写，从 commit.scope_domains 派生。
# 分支回答「属于哪块」，提交 type 回答「什么性质」——两个问题，
# 但「哪块」的词表只该有一份，所以它和 scope domain 是同一份。
echo "git.branch.prefixes = $(flat '.git.commit.scope_src | keys[]')"
echo "git.branch.naming_regex = ^($(jq -r '.git.commit.scope_src | keys | join("|")' <<<"$J"))/[a-z0-9][a-z0-9._-]*\$"
echo "git.branch.merge_strategy = $(one '.git.branching.merge_strategy')"
echo "git.worktree.root = $(one '.git.worktree.root')"
echo "git.worktree.always_include = $(flat '.git.worktree.always_include[]')"
echo "git.worktree.sparse_mode = $(one '.git.worktree.sparse_mode')"
echo "git.worktree.external_backup = $(one '.git.worktree.external_backup')"
echo "git.standalone.count = $(jq -r '.git.standalone.repos | length' <<<"$J")"
echo "git.standalone.paths = $(flat '.git.standalone.repos[]?.path')"
echo

# ── Prompt / agent-card 预算 ───────────────────────────────────────────
# 只导出规则，不展开文件内容；new check --tier commit 读取这些值并指出超限对象。
echo "prompt_budget.root_agents_bytes = $(one '.prompt_budget.root_agents_bytes')"
echo "prompt_budget.meta_agents_bytes = $(one '.prompt_budget.meta_agents_bytes')"
echo "prompt_budget.agent_card_bytes = $(one '.prompt_budget.agent_card_bytes')"
echo "prompt_budget.start_card_bytes = $(one '.prompt_budget.start_card_bytes')"
echo "prompt_budget.skill_card_bytes = $(one '.prompt_budget.skill_card_bytes')"
echo "prompt_budget.skill_card_lines = $(one '.prompt_budget.skill_card_lines')"
echo "prompt_budget.workflow_bytes = $(one '.prompt_budget.workflow_bytes')"
echo "prompt_budget.skill_paths = $(flat '.prompt_budget.skill_paths[]')"
echo

# 交叉校验一：reserved_dirs 里 vcs:forbidden 的名字，必须全部出现在 git.never_reserved。
# 两处都是手写清单，只要有两份就会漂移——所以让机器比对，而不是靠记性。
RESERVED_NOVCS="$(flat '.reserved_dirs | to_entries[] | select(.value.vcs == "forbidden" or .value.vcs == "upstream") | .key')"
NEVER_RESERVED="$(flat '.git.never_reserved[]')"
GAP=""
for r in $RESERVED_NOVCS; do
  case " $NEVER_RESERVED " in *" $r "*) ;; *) GAP="$GAP $r" ;; esac
done
if [ -n "$GAP" ]; then
  echo "# !! git.never_reserved 漏了：${GAP}（reserved_dirs 已声明 vcs 不进 git）"
  echo "git.never_reserved_gap =${GAP}"
  echo
fi

# 交叉校验二：worktree 声明了 external_backup 却没进 backup.external_paths，
# 等于承诺了保护但没有落到任何备份路径上。
WT_EXT="$(one '.git.worktree.external_backup')"
WT_ROOT="$(one '.git.worktree.root')"
BK_EXT="$(flat '.backup.external_paths[]?.path')"
if [ "$WT_EXT" = "true" ]; then
  case " $BK_EXT " in
    *" $WT_ROOT "*) ;;
    *) echo "# !! worktree.external_backup=true 但 ${WT_ROOT} 不在 backup.external_paths 里"
       echo "git.worktree.backup_gap = $WT_ROOT"
       echo ;;
  esac
fi

# 交叉校验三：登记为 standalone 的路径，必须同时被根 .gitignore 排除，
# 否则内层 .git 会被根仓库记成 gitlink。
STANDALONE="$(flat '.git.standalone.repos[]?.path')"
if [ -n "$STANDALONE" ] && [ -f "$ROOT/.gitignore" ]; then
  SGAP=""
  for p in $STANDALONE; do
    grep -qE "^/?${p}/?\$" "$ROOT/.gitignore" || SGAP="$SGAP $p"
  done
  if [ -n "$SGAP" ]; then
    echo "# !! 已登记 standalone 但根 .gitignore 未排除：${SGAP}"
    echo "git.standalone_ignore_gap =${SGAP}"
    echo
  fi
fi

# ── 提交语言 ──────────────────────────────────────────────────────────────
# 只导出规则，不导出展开后的 scope 白名单。
# 白名单来自目录树而不是 policy：把它写进 lock，`new code foo` 建个新项目
# 就会让 lock 过期，而 policy_sha256 没变——plan_staleness 抓不到，
# 同时你得先跑一次 new plan --apply 才能提交这个新项目。
# 钩子现场扫几个目录是毫秒级，完全在 commit 档的 3 秒预算内。
echo "# ── 提交语言 ─────────────────────────────────────────────────────────"
echo "git.commit.format = $(one '.git.commit.format')"
echo "git.commit.scope_shape = $(one '.git.commit.scope_shape')"
echo "git.commit.scope_domains = $(flat '.git.commit.scope_src | keys[]')"
for d in $(jq -r '.git.commit.scope_src | keys[]' <<<"$J" | sort); do
  echo "git.commit.scope_src.${d} = $(jq -r --arg d "$d" '.git.commit.scope_src[$d]' <<<"$J")"
done
echo "git.commit.scope_no_unit = $(flat '.git.commit.scope_no_unit[]')"
for d in $(jq -r '.git.commit.scope_unit_exclude // {} | keys[]' <<<"$J" | sort); do
  echo "git.commit.scope_unit_exclude.${d} = $(flat ".git.commit.scope_unit_exclude[\"$d\"][]")"
done
echo "git.commit.scope_skip_reserved = $(flat '.git.commit.scope_skip_reserved[]')"
for d in $(jq -r '.git.commit.scope_member_from // {} | keys[]' <<<"$J" | sort); do
  echo "git.commit.scope_member_from.${d} = $(jq -r --arg d "$d" '.git.commit.scope_member_from[$d]' <<<"$J")"
done
echo "git.commit.scope_aliases = $(flat '.git.commit.scope_alias // {} | keys[]')"
for a in $(jq -r '.git.commit.scope_alias // {} | keys[]' <<<"$J" | sort); do
  echo "git.commit.scope_alias.${a} = $(jq -r --arg a "$a" '.git.commit.scope_alias[$a]' <<<"$J")"
done
echo "git.commit.types.all = $(flat '.git.commit.types | to_entries[] | .value[]')"
for d in $(jq -r '.git.commit.types | keys[]' <<<"$J" | sort); do
  echo "git.commit.types.${d} = $(flat ".git.commit.types[\"$d\"][]")"
done
for t in $(jq -r '.git.commit.type_glossary | keys[]' <<<"$J" | sort); do
  echo "git.commit.type_glossary.${t} = $(jq -r --arg t "$t" '.git.commit.type_glossary[$t]' <<<"$J")"
done
echo "git.commit.multi_scope_separator = $(one '.git.commit.multi_scope.separator')"
echo "git.commit.scope_path_direction = $(one '.git.commit.scope_path_consistency.direction')"
echo "git.commit.scope_path_on_violation = $(one '.git.commit.scope_path_consistency.on_violation')"
echo "git.commit.desc_min_chars = $(one '.git.commit.description.min_chars')"
echo "git.commit.allow_wip_on_short_lived = $(one '.git.commit.main_gate.allow_wip_on_short_lived')"
echo "git.commit.enforce_after = $(one '.git.commit.enforce_after')"
echo "git.commit.skip_path_check_when_empty_stage = $(one '.git.commit.exempt.skip_path_check_when_empty_stage')"
# 下面两条直接导成正则而不是词表。
# 理由是「共用同一套例外判断」：commit-msg 钩子和 daily 回扫都读这两个键，
# 各自从词表拼一次正则的话，拼法迟早会分叉，而分叉的表现是
# 钩子放行的提交被审计天天报——那是门禁被整项关掉的标准前奏。
echo "git.commit.main_vague_re = ^($(jq -r '.git.commit.main_gate.vague_whole_match | join("|")' <<<"$J"))\$"
echo "git.commit.exempt_autogen_re = ^($(jq -r '.git.commit.exempt.autogenerated_prefixes | join("|")' <<<"$J"))"
echo

# 交叉校验四：每个 scope domain 都必须有 type 清单，否则那个域下的提交
# 无论写什么 type 都会被拒——而钩子拦住合法提交的下一步就是 --no-verify。
CT_DOMAINS="$(flat '.git.commit.scope_src | keys[]')"
CT_HAVE="$(flat '.git.commit.types | keys[]')"
CT_GAP=""
for d in $CT_DOMAINS; do
  case " $CT_HAVE " in *" $d "*) ;; *) CT_GAP="$CT_GAP $d" ;; esac
done
if [ -n "$CT_GAP" ]; then
  echo "# !! 以下 scope domain 没有 type 清单，该域下任何提交都会被拒：${CT_GAP}"
  echo "git.commit.type_matrix_gap =${CT_GAP}"
  echo
fi

# 交叉校验五：type 出现在矩阵里却没有词义，AGENTS.md 的受控块会缺一行。
CT_USED="$(flat '.git.commit.types | to_entries[] | .value[]')"
CT_DEFINED="$(flat '.git.commit.type_glossary | keys[]')"
CT_UNDEF=""
for t in $CT_USED; do
  case " $CT_DEFINED " in *" $t "*) ;; *) CT_UNDEF="$CT_UNDEF $t" ;; esac
done
if [ -n "$CT_UNDEF" ]; then
  echo "# !! 以下 type 在矩阵里出现但 type_glossary 没有定义：${CT_UNDEF}"
  echo "git.commit.type_glossary_gap =${CT_UNDEF}"
  echo
fi

# 交叉校验六：别名绑的路径必须真实存在。
# 绑路径的全部意义就在这里——只登记名字的白名单会静默漂移，
# 绑了路径之后 0-meta/bin/new 一旦改名，这条声明当场失效并被报出来。
AL_GAP=""
for a in $(jq -r '.git.commit.scope_alias // {} | keys[]' <<<"$J" | sort); do
  p="$(jq -r --arg a "$a" '.git.commit.scope_alias[$a]' <<<"$J")"
  [ -e "$ROOT/$p" ] || AL_GAP="$AL_GAP ${a}→${p}"
done
if [ -n "$AL_GAP" ]; then
  echo "# !! scope_alias 指向的路径不存在：${AL_GAP}"
  echo "git.commit.scope_alias_gap =${AL_GAP}"
  echo
fi

# ── 密钥 ──────────────────────────────────────────────────────────────────
echo "# ── 密钥 ─────────────────────────────────────────────────────────────"
echo "secrets.policy = $(one '.secrets.policy')"
echo "secrets.on_violation = $(one '.secrets.on_violation')"
echo "secrets.deny_glob_count = $(jq -r '.secrets.deny_globs | length' <<<"$J")"
echo "secrets.deny_globs = $(flat '.secrets.deny_globs[]')"
echo

# ── AI 访问 ───────────────────────────────────────────────────────────────
echo "# ── AI 访问边界（layer 1 声明）─────────────────────────────────────────"
for d in $(jq -r '.ai_access.layer_1_declaration | keys[]' <<<"$J" | grep -v '^strength$' | sort); do
  echo "ai_access.$d = $(jq -r --arg d "$d" '.ai_access.layer_1_declaration[$d]' <<<"$J")"
done
echo "ai_access.must_deny = $(flat '.ai_access.layer_2_tool.must_deny[]')"
# 只导出 enforced:true 的 adapter。new check 按这份清单逐个验证，
# 所以「支持一个新工具」是一次 policy 修改，不是一次脚本修改。
echo "ai_access.adapter_files = $(flat '.ai_access.layer_2_tool.adapters[] | select(.enforced == true) | .file')"
echo "ai_access.adapter_advisory = $(flat '.ai_access.layer_2_tool.adapters[] | select(.enforced != true) | .file')"
echo "ai_access.layer_3_status = $(one '.ai_access.layer_3_system.status')"
echo

# ── 审计 ──────────────────────────────────────────────────────────────────
echo "# ── 审计 ─────────────────────────────────────────────────────────────"
echo "audit.checks = $(flat '.audit.checks[].id')"
echo "audit.hard_fail = $(flat '.audit.checks[] | select(.hard_fail == true) | .id')"
for t in commit daily deep; do
  echo "audit.tier.$t = $(flat ".audit.tiers.$t.checks[]")"
  echo "audit.tier.$t.budget_seconds = $(one ".audit.tiers.$t.budget_seconds")"
done
echo

# ── 数据集归属 ────────────────────────────────────────────────────────────
# 采集端的类型白名单要导出，否则 bin/new 只能自己写死一份——
# 那就等于「改 policy 不改行为」，而这套设计的全部前提是反过来的。
echo "# ── 数据集归属声明 ───────────────────────────────────────────────────"
echo "data.producer_types = $(flat '.domains["3-data"].link_declaration.producer_types[]')"
echo "data.index_file = $(one '.domains["3-data"].link_declaration.index_file')"
echo

# ── 决策记录归属 ────────────────────────────────────────────────────────────
# 生成器、审计和 policy 必须指向同一组路径与 marker；否则两份代码可以共同使用
# 旧常量并一致报绿，而 policy 的“事实源”只是注释。
echo "# ── 决策记录归属声明 ─────────────────────────────────────────────────"
echo "decision.records_dir = $(one '.domains["4-know"].decision_declaration.records_dir')"
echo "decision.index_file = $(one '.domains["4-know"].decision_declaration.index_file')"
echo "decision.scope_tool = $(one '.domains["4-know"].decision_declaration.scope_tool.executable')"
echo "decision.scope_validate_mode = $(one '.domains["4-know"].decision_declaration.scope_tool.validate_mode')"
echo "decision.scope_dir_mode = $(one '.domains["4-know"].decision_declaration.scope_tool.directory_mode')"
echo "decision.scope_level_mode = $(one '.domains["4-know"].decision_declaration.scope_tool.level_mode')"
echo "decision.marker_begin = $(one '.domains["4-know"].decision_declaration.controlled_blocks.marker_begin')"
echo "decision.marker_end = $(one '.domains["4-know"].decision_declaration.controlled_blocks.marker_end')"
echo

# ── 命名 ──────────────────────────────────────────────────────────────────
echo "# ── 命名 ─────────────────────────────────────────────────────────────"
for d in $(jq -r '.naming.applies | keys[]' <<<"$J" | sort); do
  echo "naming.$d = $(jq -r --arg d "$d" '.naming.applies[$d]' <<<"$J")"
done
echo

# ── GitHub Project / Status（任务运行时视图，不是身份 SSOT）──────────────
# repo 身份从 origin 推导；此处只导出 Project 编号/标题与 Status 名称。
if ! jq -e '.github.project.number and (.github.project.title | type == "string" and length > 0)' \
    <<<"$J" >/dev/null; then
  echo "policy.yaml 缺少 github.project.number / title" >&2
  exit 1
fi
gh_num="$(one '.github.project.number')"
case "$gh_num" in
  ''|*[!0-9]*|0) echo "policy.yaml 的 github.project.number 不合法：$gh_num" >&2; exit 1 ;;
esac
echo "# ── GitHub Project（运行时视图；身份仍从 origin 推导）────────────────"
echo "github.project.number = $gh_num"
echo "github.project.title = $(one '.github.project.title')"
gh_over="$(jq -r '.github.repo_override // empty' <<<"$J")"
echo "github.repo_override = $gh_over"
for k in backlog ready progress review done; do
  v="$(jq -r --arg k "$k" '.github.status[$k] // empty' <<<"$J")"
  [ -n "$v" ] || { echo "policy.yaml 缺少 github.status.$k" >&2; exit 1; }
  echo "github.status.${k} = $v"
done
echo
