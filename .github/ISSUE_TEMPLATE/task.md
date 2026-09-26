---
name: Task
about: Define a small, reviewable task contract
title: ""
labels: []
assignees: []
---

## Original Intent

<!-- Paste the user's original request or a fixed PRD reference. Keep it distinct from the implementation Contract. -->

## Contract

### Context

<!-- Describe the current situation, problem, and concrete examples. -->

### Goal

<!-- What outcome is required? -->

### Acceptance

<!-- Observable conditions that must be true when complete. -->

### Constraints

<!-- Already-decided limits or requirements; do not invent implementation details. -->

### Out of scope

<!-- What must not be changed or added in this task. -->

### Execution Plan (optional)

<!-- May be left empty. If repository reading and design have produced a useful plan, record it here in any suitable format. -->

G-lite does not require an Execution Plan or parse its contents. Without a plan, Developer uses the current repository facts and Issue goals to implement and verify the task. Editing this section follows the same Issue body freshness rules as any other edit.

### Authorization

Human Authority controls repository governance; Developer may create or edit the Contract. The independent Reviewer authorizes the current version. A GitHub Actor that wrote or materially edited this Contract must not add `approved` to the same Contract version.

Chat instructions do not replace fresh `approved` for development. Work starts only after the independent Reviewer adds it. Developer and Reviewer must not merge; final Squash merge belongs to Human Authority after GitHub gates pass.

### Delivery lifecycle

Repository task files are changed only in a dedicated native Git worktree with one writable task branch; the primary checkout stays on default/main. Use `git worktree list --porcelain` as the binding source of truth. Reviewer local execution, if needed, uses a separate temporary detached-HEAD worktree.

Reach LOCAL GREEN before opening the PR, then CI GREEN for the current PR HEAD before REVIEW-READY and independent Review.

### Merge authorization

Default: no task-level preauthorization for final merge. Human Authority may explicitly authorize Squash merge after gates pass. Main verifies the human Actor and records that instruction with a fresh `merge-authorized` label event.

Developer-authored Issue text does not grant merge permission. If the label is absent or stale, Main asks Human Authority again before final merge.
