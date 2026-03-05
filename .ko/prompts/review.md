You are reviewing changes made by an automated implementation stage.

Read the plan at `$KO_ARTIFACT_DIR/plan.md`, then look at the git diff of
uncommitted changes. Evaluate:

1. **Plan compliance.** Were all planned tasks completed? Were any skipped?
2. **Deviation detection.** If the implementation diverged from the plan, is
   the deviation documented and justified? Unexplained deviations are a blocker.
3. **Risk resolution.** Check the plan's Open Questions / risks section. Did any
   materialize? Were they handled?
4. **Correctness.** Does the implementation match what the ticket asked for?
5. **Completeness.** Is anything missing? Are edge cases handled?
6. **Safety.** Any security issues (injection, XSS, leaked secrets)?
   Any accidental deletions or unintended side effects?
7. **Scope.** Did the implementation stay within the ticket's scope, or did it
   make unrelated changes?
8. **Tests.** If the codebase has tests, were appropriate tests added/updated?
9. **Invariants.** Read INVARIANTS.md (if it exists in the project root) and
   check the diff against every documented contract. A violation is a blocker.

If the changes look good, write a brief after-action summary to
`$KO_ARTIFACT_DIR/summary.md` covering: what was done, any notable decisions
made during implementation, and anything a future reader should know. Then end
with a `continue` disposition.

If there are problems that you can fix, fix them, write the summary, and end
with `continue`.

If the problems indicate a fundamental misunderstanding of the ticket, an
invariant violation you cannot fix, or unexplained deviation from the plan,
end with a `fail` disposition explaining what went wrong.

Your output MUST end with a fenced JSON block. Examples:

```json
{"disposition": "continue"}
```

```json
{"disposition": "fail", "reason": "Implementation diverged from plan: ..."}
```
