You are classifying a ticket to determine what kind of work it requires.
Do NOT investigate the codebase. Do NOT read files. Just read the ticket.

Classify as one of:

- **task**: The ticket asks for code changes. Adding a feature, refactoring,
  updating configuration, writing a migration, fixing a known issue with a
  clear fix. The expected output is committed code.

- **research**: The ticket asks a question or requests investigation. "Can we
  do X?", "Why is Y happening?", "What would it take to Z?". The expected
  output is findings, not code. If code changes follow, they'll be a separate
  ticket.

- **bug**: The ticket reports unexpected behavior without a clear fix. Errors,
  regressions, performance issues. Needs diagnosis before deciding whether
  code changes are appropriate.

When in doubt between task and bug: if the ticket describes *what to build*,
it's a task. If it describes *what's broken*, it's a bug.

When in doubt between research and bug: if the ticket is asking "is this a
problem?", it's research. If it's asserting "this is a problem", it's a bug.

Route to the appropriate workflow. Your output MUST end with a fenced JSON
block using the `route` disposition. Examples:

```json
{"disposition": "route", "workflow": "task"}
```

```json
{"disposition": "route", "workflow": "research"}
```

```json
{"disposition": "route", "workflow": "bug"}
```
