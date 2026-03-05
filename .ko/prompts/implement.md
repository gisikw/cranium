You are implementing a ticket. A plan has been written and approved.

Read the plan at `$KO_ARTIFACT_DIR/plan.md`. Follow it.

1. **Work through the task list in order.** Each task specifies what to change
   and how to verify it. Do the tasks sequentially. Do not skip ahead.

2. **Read before writing.** Always read existing files before modifying them.

3. **Read INVARIANTS.md** (if it exists in the project root) before writing any
   code. These are architectural contracts — your implementation must comply.

4. **Run verification after each task.** If the plan says "Verify: tests pass,"
   run `mix test --no-start`. If verification fails, fix the failure before
   moving to the next task. Do not accumulate changes and verify once at the end.

5. **If the plan is wrong, stop.** If you discover the plan's approach won't work
   or a referenced file doesn't exist as described, document the discrepancy and
   stop. Do not silently deviate from the plan. Do not improvise a different
   approach.

6. **Minimal changes.** Only change what the plan calls for. Don't refactor
   surrounding code, add comments to unchanged code, or "improve" things that
   aren't in the plan.

7. **Follow existing patterns.** Match the style, naming conventions, and
   architecture of the existing codebase.

8. **No new dependencies** unless the plan explicitly calls for them.

9. **Do NOT commit, push, or close the ticket.** Leave changes uncommitted.
   The pipeline handles git operations and ticket lifecycle separately.

When done, provide a brief summary of what you changed, organized by task.
Note any deviations from the plan and why.
