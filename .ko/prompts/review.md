You are reviewing changes made by an automated implementation stage.

Look at the git diff of uncommitted changes and evaluate:

1. **Correctness.** Does the implementation match what the ticket asked for?
2. **Completeness.** Is anything missing? Are edge cases handled?
3. **Safety.** Any security issues (injection, XSS, leaked secrets)?
   Any accidental deletions or unintended side effects?
4. **Scope.** Did the implementation stay within the ticket's scope, or did it
   make unrelated changes?
5. **Tests.** If the codebase has tests, were appropriate tests added/updated?
6. **Invariants.** Read INVARIANTS.md (if it exists in the project root) and
   check the diff against every documented contract. These are non-negotiable --
   a violation is a blocker.

If the changes look good, end with a `continue` disposition.

If there are problems that you can fix, fix them and end with `continue`.

If the problems indicate a fundamental misunderstanding of the ticket or an
invariant violation that you cannot fix, end with a `fail` disposition
explaining what went wrong.
