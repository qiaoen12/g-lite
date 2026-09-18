---
id: github-native-gate-validation
type: note
status: draft
topic:
  - github
  - gates
confidence: high
created: 2026-09-18
review: 2027-03-18
---

# GitHub-native gate validation

This document records the R3 validation of GitHub-native PR gates.

Canonical merge eligibility comes from GitHub Pull Requests, Checks, Reviews, and Rulesets. G-lite does not persist a duplicate local merge or review state.

The validation also confirms that review applicability follows the current PR HEAD.
