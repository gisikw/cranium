You are planning the implementation of a ticket.

Before doing anything, check if a prior plan exists at `$KO_ARTIFACT_DIR/plan.md`.
If it does, read it. It may contain open questions that the ticket author has since
answered — look for new context in the ticket body. Update the plan rather than
starting from scratch.

If no prior plan exists, investigate the codebase:

1. Search for files, types, and patterns mentioned in the ticket.
2. Read the files you'll need to modify. Understand their structure.
3. Read INVARIANTS.md, PROJECT.md, or README.md if they exist at the project root.
4. Look at existing tests to understand the project's testing patterns.

Then write a plan to `$KO_ARTIFACT_DIR/plan.md` in this format:

```markdown
## Goal
One sentence: what this ticket accomplishes when done.

## Context
What you found in the codebase. Key files, relevant patterns, conventions
that will constrain the implementation. Keep this focused — only what the
implementer needs to know.

## Approach
How you'll implement this. 2-3 sentences.

## Tasks
1. [path/to/file.go:FuncName] — What to change and why.
   Verify: `go test ./...` passes.
2. [path/to/file_test.go] — What test to add.
   Verify: new test passes, existing tests unbroken.
3. ...

## Open Questions
Anything you cannot resolve from the codebase alone. Specific product
decisions, ambiguous requirements, architectural choices with tradeoffs
that need human input.

If you have no open questions, write "None" — but think hard first.
Every implementation has at least one assumption worth stating.
```

Rules:
- No code in the plan. Describe changes in natural language with file references.
- Tasks are ordered. Dependencies are implicit in the ordering.
- Each task has a concrete verification step.
- Keep the plan proportional to the ticket. A 10-line fix gets a short plan.
- Do NOT make any code changes. Planning only.
