# g-lite

Canonical G-lite framework source.

```text
qiaoen12/g-lite
= canonical G-lite framework source
= development + Issue + PR + Release + Template

qiaoen12/g-lite-harness
= external test / E2E / fault injection
= not a production dependency
```

> Fresh clone: `0-meta/bin/new setup` (installs `new` on PATH), then `new check --tier commit`.

## Provenance

Initial source:

```text
qiaoen12/Project-qiaoen
@ 988ba573c8bc8b841539223e547e82f70719f52c
Freeze UTC: 2026-09-09T10:55:57Z
```

Extracted by allowlist; see [`0-meta/docs/11-extract-allowlist.md`](0-meta/docs/11-extract-allowlist.md). This is not a copy of the whole Project-qiaoen tree.

`v1.0.0` is created after human squash merge of [#1](https://github.com/qiaoen12/g-lite/issues/1). This candidate does not tag or release itself.

## Four invariants

| # | Rule | If broken |
| :-: | --- | --- |
| 1 | **No plaintext secrets** in the workspace; only `op://` references and `*.enc.*` ciphertext | One leak is a whole-workspace leak |
| 2 | **One private repo, one `main`**; projects do not each get a repo | Dozens of repos are dozens of policy blind spots |
| 3 | **Backup and sync lists are generated from `policy.yaml`**, never hand-written | Hand lists drift |
| 4 | **After editing `policy.yaml`, run `new plan`**; policy and `derived.lock` share a commit | Stale derived state is silent policy drift |

## Where things go

```
new thing
│
├─ regenerable? ── yes ──▶  _out/ or _cache/    ← not backed up
│  └─ no
│     │
├─ shareable? ────── no ─┬ credentials ──▶  1Password / Keychain
│  │                     └ personal records ──▶  5-record/
│  └─ yes
│     │
└─ who owns it?
   ├─ git-managed code ──────────▶  1-code/
   ├─ git-managed infra ─────────▶  2-infra/
   ├─ writing ───────────────────▶  4-know/
   ├─ collected data ────────────▶  3-data/
   ├─ other people's code ───────▶  _vendor/
   └─ unknown ───────────────────▶  _inbox/   ← handle within 30 days
```

## Eight domains

| Dir | What | Git | Backup | Sync | AI | Naming |
| --- | --- | :-: | :-: | :-: | :-: | --- |
| `0-meta/` | rules, audit, templates, schema | tracked | ✓ | ✓ | read | ascii |
| `1-code/` | own code, one child dir per project | tracked | ✓ | ✓ | rw | ascii |
| `2-infra/` | infra; credentials only as ciphertext | tracked | ✓ | ✓ | rw | ascii |
| `3-data/` | datasets; `_raw` append-only / `_out` rebuildable | contract + pipeline | ✓ | ✗ | read | ascii |
| `4-know/` | notes, research, ADRs | tracked | ✓ | ✓ | rw | free + `id` |
| `5-record/` | personal records | **two manifests only** | ✓ | **no** | **no** | human-first |
| `_inbox/` | unsorted, 30-day expiry | `AGENTS.md` only | ✓ | ✗ | read | free |
| `_vendor/` | third-party, re-fetchable | governance docs | ✗ | ✗ | read | ascii |

Git tracking and backup are independent questions. A git remote is not a backup.

`example-*` trees are deletable samples. The domain directories themselves are required topology.

## Reserved names (any depth)

| Name | Meaning | Backup | Git |
| --- | --- | :-: | :-: |
| `_raw/` | original data, append-only, hashed | ✓ | ✗ |
| `_out/` | mechanically rebuildable | ✗ | ✗ |
| `_cache/` | cache | ✗ | ✗ |
| `_vendor/` | third-party code | ✗ | ✗ |
| `_archive/` | cold store, needs `RETENTION.md` | ✓ | ✗ |

## Scaffolding

`new` is installed by `0-meta/bin/new setup`. It resolves the workspace from the current directory (or `NEW_WORKSPACE_ROOT`). Repo identity comes from `git remote origin`, not from a hardcoded path or repository name.

```bash
new code     my-app
new data     reddit-posts
new note     cf-waf-rules
new task bind <n>
new z dev
new check --tier commit
```

Worktrees live in a sibling of the clone, default `../worktrees` (set `git.worktree.root` in `policy.yaml`).

```bash
new worktree reddit-v3 --path 1-code/reddit --path 3-data/reddit-posts
# then, from the main worktree:
git merge --squash <branch> && git commit
```

## Version mark

Framework repo (this tree) keeps [`.g-lite-version`](.g-lite-version) without a self-referential commit SHA:

```text
kind=framework
version=v1.0.0
source=qiaoen12/g-lite
```

A consumer that pins a release later adds `commit=<resolved tag SHA>`. This round does not implement auto-upgrade.

## Further reading

- Permissions: [`0-meta/docs/06-权限边界.md`](0-meta/docs/06-权限边界.md)
- Git / worktree / sync / restore: [`0-meta/docs/07-git-工作流.md`](0-meta/docs/07-git-工作流.md)
- Contract / checkpoint / review / merge: [`0-meta/docs/08-task-contract.md`](0-meta/docs/08-task-contract.md)
- Start card / adapters: [`0-meta/docs/09-agent-card.md`](0-meta/docs/09-agent-card.md)
- Freeze and extract: [`0-meta/docs/10-framework-freeze.md`](0-meta/docs/10-framework-freeze.md)
- Allowlist: [`0-meta/docs/11-extract-allowlist.md`](0-meta/docs/11-extract-allowlist.md)
