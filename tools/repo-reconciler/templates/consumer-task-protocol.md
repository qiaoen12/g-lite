### G-lite delivery lifecycle

Define the task through context, goals, observable acceptance, and known constraints / out of scope. Execution Plan is optional and may be empty for any task size; G-lite neither requires it nor parses its contents. Without a plan, Developer implements and verifies using current repository facts and Issue goals. Plan edits follow the same Issue body freshness rules.

- Keep the primary checkout on default/main; make task edits in one dedicated native Git worktree on one writable task branch.
- Reach LOCAL GREEN before opening the PR.
- REVIEW-READY requires the intended PR HEAD, CI GREEN for that current HEAD, and no unresolved Contract blocker.
- An independent Reviewer reviews the current Contract and PR HEAD.
- Human Authority performs the final Squash merge after required gates pass.
