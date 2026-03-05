You are diagnosing a bug reported in a ticket.

1. **Reproduce the problem.** Search the codebase for the code paths described
   in the ticket. Read the relevant files. Understand how the current code
   behaves and why it might produce the reported issue.

2. **Identify the root cause.** Don't just find where the error happens — trace
   back to *why* it happens. Is it a logic error? A missing check? A race
   condition? A misconfiguration?

3. **Assess fixability.** Can this be fixed with a straightforward code change?
   Or does it require architectural decisions, dependency changes, or human
   input?

Write your diagnosis to `$KO_ARTIFACT_DIR/diagnosis.md` with:
- **Symptoms**: What the ticket reports
- **Root Cause**: What's actually going wrong and where
- **Affected Code**: File paths and relevant functions
- **Recommended Fix**: What a fix would look like (in natural language)
- **Risk Assessment**: What could go wrong with the fix, what else it might affect

Do NOT make any code changes. Diagnosis only.

End with a brief summary of what you found.
