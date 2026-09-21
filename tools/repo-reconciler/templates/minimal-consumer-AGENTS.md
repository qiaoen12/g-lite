# Agent protocol

This repository uses the G-lite GitHub-native protocol.

## Contract

Work starts from a GitHub Issue containing Goal, Acceptance, Out of scope, and Authorization.

Before development and again before PR review, read the current OPEN Issue Contract, author/editor, lastEditedAt, current approved label and latest approved label event (actor and timestamp). Missing approval is INVALID; lastEditedAt absent or <= approvedAt is FRESH; later edits are STALE. Stop if facts cannot be verified or authorization is invalid/stale. The Actor that writes or materially edits the current Contract version cannot approve it. Reauthorization requires independent fresh approved; do not cache authorization.

## Roles

- Developer Actor: machine identity / GitHub App; may create/edit Contracts, develop, push, and open/update PRs within fresh authorized scope. It must not approve its own Contract, provide its own Required Review, or merge.
- Reviewer Actor: independent machine identity / GitHub App; may independently add approved and review the current PR HEAD with APPROVE / REQUEST_CHANGES. It must not develop, push, change repository governance, or merge.
- Developer and Reviewer must not independently change the Ruleset / governance that constrains them.
- Human Authority: one or more human accounts with appropriate permissions on this repository. After GitHub gates pass, it may perform final Squash merge through GitHub UI, CLI, API, or tools under its explicit instruction.
- Concrete account/App bindings are replaceable per consumer; no canonical username or App is required. Verify both Apps' identities, independence, and installation access externally. Do not add a Merge Bot / Merge Executor or identity registry.

## Genesis / ACTIVE

Human Authority controls Genesis: create the repository, install/authorize both Apps, establish initial protocol files and CI, configure Ruleset / governance / security, and verify ACTIVE readiness. Tools may execute under Human Authority's identity and authorization; this does not grant Developer administrator powers.

In ACTIVE, Developer + Reviewer handle daily tasks; Human Authority intervenes at governance boundaries or final merge.

## Local Bootstrap

Local Bootstrap ≠ Repository Task. Local App private key installation/rotation, ~/.config/g-lite/ credential directories, token helpers, shell identity bootstrap, read-only identity preflight, and new-machine identity setup need no Issue Contract. They do not authorize changing repository durable facts; repository changes enter the appropriate lifecycle.

Developer / Reviewer use short-lived Installation Access Tokens. Never put private keys, JWTs, tokens, or PATs in repo, Issue, PR, evidence logs, or canonical state; do not persist tokens in state files. Local credentials stay in external secure mechanisms, outside canonical runtime.

Verify API Actor, commit author, and Git transport separately. Developer clone/fetch/push uses App HTTPS credentials. Before each operation verify the effective HTTPS remote and absence of applicable insteadOf rewrite: user/global Git config can silently turn HTTPS into human SSH authentication. Prefer task-process config/credential isolation, inspect repo-local config, and preserve existing user global Git / SSH settings.

## GitHub facts

GitHub is the source of truth for Issue authorization, PR, Checks, Review, Ruleset, merge eligibility, and merge result. Do not create local task, review, merge, or approval state or a second GitHub database.

The default branch requires PRs, at least one independent approval, stale review dismissal, a stable consumer-owned Required Check, squash-only merge, and no routine bypass. Enable Secret scanning / Push protection where supported. Consumer CI is owned by this repository and its Agent; G-lite does not generate or select it. Reconciler App assertions are invocation-only, require external verification of both roles, and do not authorize governance writes or manage credentials.
