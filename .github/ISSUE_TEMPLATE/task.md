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

### Goal

<!-- What outcome is required? -->

### Acceptance

<!-- Observable conditions that must be true when complete. -->

### Implementation & Verification Plan

Medium or larger work names this before implementation: expected files and responsibility boundaries, estimated implementation LOC, estimated test LOC, primary risk, the L0-L4 levels this Contract uses, Local / CI / Pilot placement, Permanent / Stage / Pilot, LOCAL GREEN, CI GREEN, REVIEW-READY, and stop conditions.

Trivial or docs-only work may say the full plan is not applicable.

### Out of scope

<!-- What must not be changed or added in this task. -->

### Authorization

Human Authority controls repository governance; Developer may create or edit the Contract. The independent Reviewer authorizes the current version. A GitHub Actor that wrote or materially edited this Contract must not add `approved` to the same Contract version.

Chat instructions do not replace fresh `approved` for development. Work starts only after the independent Reviewer adds it. Developer and Reviewer must not merge; final Squash merge belongs to Human Authority after GitHub gates pass.

### Merge authorization

Default: no task-level preauthorization for final merge. Human Authority may explicitly authorize Squash merge after gates pass. Main verifies the human Actor and records that instruction with a fresh `merge-authorized` label event.

Developer-authored Issue text does not grant merge permission. If the label is absent or stale, Main asks Human Authority again before final merge.
