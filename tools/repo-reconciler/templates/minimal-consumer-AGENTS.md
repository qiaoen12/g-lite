# Agent protocol

This repository uses the G-lite GitHub-native protocol.

## Contract

Work starts from a GitHub Issue containing:

- Goal
- Acceptance
- Out of scope
- Authorization

The current Issue Contract must have an independent `approved` label before development starts. The Actor that writes or materially edits the Contract cannot add that label.

## Roles

- The Developer changes only the authorized scope and opens a pull request.
- The independent Reviewer is `g-lite-reviewer[bot]`.
- The Reviewer may read code, review the pull request, and authorize the current Contract; it does not push development changes, merge, or change repository governance.

## GitHub facts

GitHub is the source of truth for Issues, labels, pull requests, reviews, checks, branch protection, and merge eligibility. Do not create a local task, review, merge, or approval state.

The default branch is changed through a pull request. Consumer CI and its Required Check are owned by this repository and its Agent; G-lite does not generate or select them.
