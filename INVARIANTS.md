# Invariants

These are architectural contracts. They're not aspirational — they're load-bearing.
Violations are bugs, not style issues. No grandfather clauses.

If an invariant no longer serves the project, remove it explicitly with rationale.
Don't just ignore it.

## Code Organization

- Decision logic is pure: functions take data, return decisions, no I/O
- I/O is plumbing: thin orchestrators that gather data -> call pure functions -> act
- No multi-purpose functions: separate decision from effect
- New logic goes into testable functions first, not handler/framework layer

## File Size

- 500 lines max per file (ergonomic, not aesthetic)
- Split along behavioral seams, not alphabetically
- Tests mirror source files
- No grab-bag utility files (util.go, helpers.js)

## Naming

- Timestamps: `2006-01-02_15-04-05` (lexicographic, filesystem-safe)

## Secrets

- No hardcoded secrets, tokens, PII, or infrastructure-specific details
- Environment-specific values come from .env (gitignored)
- .env.example documents required vars with placeholders

## Policy

- Decisions that shape code are explicit (here), not implicit
- No "look at how X does it" as policy — write it down or it doesn't exist

---

## Project-Specific

> TODO: Add sections for this project's architectural decisions.
> Common categories:
> - Data model (files? database? in-memory?)
> - Concurrency model
> - External dependencies policy
> - API boundaries (CLI? HTTP? SDK?)
> - Build & deployment
> - Testing strategy
