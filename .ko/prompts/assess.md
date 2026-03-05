You are assessing whether a diagnosed bug should be routed to implementation.

Read the diagnosis at `$KO_ARTIFACT_DIR/diagnosis.md`.

Evaluate:

1. **Is the root cause identified?** If the diagnosis is inconclusive or
   speculative, this is not ready for a fix. End with a `continue` disposition
   to close the ticket with the diagnosis as findings.

2. **Is the fix straightforward?** If the recommended fix is a clear, scoped
   code change that doesn't require architectural decisions or human input,
   route to the task workflow. End with a `route` disposition targeting `task`.

3. **Does the fix need human input?** If the diagnosis reveals multiple possible
   approaches, breaking changes, or tradeoffs that need a product decision, end
   with a `fail` disposition listing the specific decisions needed.

When routing to `task`, the diagnosis artifact will be available to the plan
node in the task workflow.

Your output MUST end with a fenced JSON block. Examples:

```json
{"disposition": "continue"}
```

```json
{"disposition": "route", "workflow": "task"}
```

```json
{"disposition": "fail", "reason": "Multiple approaches possible: ..."}
```
