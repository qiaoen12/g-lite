# G-lite v1.0 extract allowlist

Source Freeze (only this SHA):

```text
qiaoen12/Project-qiaoen
@ 988ba573c8bc8b841539223e547e82f70719f52c
Freeze UTC: 2026-09-09T10:55:57Z
```

This file is the extract evidence for `qiaoen12/g-lite#1`. It is not a copy of Project-qiaoen.

## INCLUDE

| Path | REASON |
| --- | --- |
| `0-meta/bin/new` | Canonical CLI entry |
| `0-meta/lib/**` | Runtime + tests (`core`, task/claim/review, z-cli, setup, check, guard, metrics, scaffold) |
| `0-meta/schema/**` | Contract and knowledge frontmatter |
| `0-meta/templates/**` | `new-shim`, Contract templates, setup guardrails, z-workflow |
| `0-meta/policy.yaml` + `0-meta/derived.lock` | Policy SSOT and generated lock; identity fields generalized after extract |
| `0-meta/audit/scripts/**` | `derive-paths.sh`, `check-commit-msg.sh` |
| `0-meta/docs/**` | Runtime/workspace docs; freeze + this allowlist |
| `0-meta/AGENTS.md` | Domain agent-card |
| `.agents/skills/z-lib.sh` and `zdev`/`zfix`/`zreview`/`zsync`/`zpr`/`zmerge` | Thin adapters + executables sourced/exec'd by `new z` |
| `2-infra/git-guard/**` | Staging bare pre-receive + main tripwire |
| `.github/workflows/main-guard.yml` | Main provenance tripwire |
| `.pre-commit-config.yaml` | Commit-time `new check --tier commit` + commit-msg |
| `.gitignore` `.aiignore` `.cursorignore` `.claude/settings.json` | Tracking and AI-boundary adapters |
| `2-infra/backup/**` | `new check` daily/deep calls password and closure checkers; destinations reset to placeholders |
| `2-infra/example-host/**` | Deletable infra example |
| Domain skeletons: `1-code/AGENTS.md`, `3-data/{AGENTS,INDEX}.md`, `4-know/AGENTS.md`, `5-record/{AGENTS,RETENTION}.md`, `_inbox/AGENTS.md`, `_vendor/{AGENTS,VENDOR}.md` | Topology required by check |
| `1-code/example-app/**`, `3-data/example-dataset/**`, `4-know/{note,runbook,source,research/example-topic,writing}` examples | Deletable samples, not business content |
| `4-know/decision/{monorepo,policy-single-source,workspace-topology,restic-cold-backup,framework-freeze}.md` | Framework ADRs indexed by `new adr --index`; freeze ADR is provenance |
| Root `AGENTS.md` `README.md` `.g-lite-version` | Role, provenance, version mark |

## EXCLUDE

| Path | REASON |
| --- | --- |
| `1-code/my-livetranslate/**` | Business project |
| `3-data/research-career-jd/**` | Personal/research dataset |
| `4-know/research/career/**` | Personal knowledge |
| `4-know/report/**` | Personal report artifact |
| `0-meta/tasks/**` | Historical Contract blobs |
| `0-meta/audit/restore-drill/2026-08-27-local-pipeline.md` | Host-specific drill evidence |
| `5-record/**` beyond AGENTS/RETENTION | Personal records (none were tracked) |
| `_inbox/**` beyond AGENTS.md | Unsorted personal inbox |
| Project-qiaoen restic dest / Keychain / sync host / launchd absolute paths | Host-exclusive backup config; replaced with `REPLACE-ME` / `../worktrees` |
| credentials / tokens / secrets / metrics.jsonl / claim refs / worktree state | Runtime state, not framework source |

## Portability after extract

Production runtime identity is derived from Git origin (`task_github_nwo` / `task_repo_nwo`). Defaults that still need a path use a relative sibling `../worktrees`, not `/Users/qiaoen/Projects2`.

Historical ADRs and freeze docs may name `Project-qiaoen@988ba573…` as provenance. That is allowed and must not be deleted to make `grep` silent.
