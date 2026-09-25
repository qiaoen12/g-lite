### G-lite delivery lifecycle

For medium-or-larger work, record an Implementation & Verification Plan in the Contract.

- Keep the primary checkout on default/main; make task edits in one dedicated native Git worktree on one writable task branch.
- Reach LOCAL GREEN before opening the PR.
- REVIEW-READY requires the intended PR HEAD, CI GREEN for that current HEAD, and no unresolved Contract blocker.
- An independent Reviewer reviews the current Contract and PR HEAD.
- Human Authority performs the final Squash merge after required gates pass.
