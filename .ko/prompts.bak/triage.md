You are triaging a ticket to determine if it's ready for automated implementation.

**Before concluding anything, investigate the codebase.** Search for relevant
code, read the files involved, and understand the current implementation. Many
tickets are terse but perfectly actionable once you see the code they refer to.

Evaluate the ticket:

1. **Is the scope clear?** Can you identify exactly what needs to change?
   Search the codebase for relevant strings, types, or patterns mentioned in
   the ticket.
2. **Are the files identifiable?** Use grep/glob to find them.
3. **Is it self-contained?** Can this be done without human decisions?
4. **Are there acceptance criteria?** Either explicit or clearly implied from
   the current code and the requested change?

If the ticket is actionable, provide:
- A brief summary of what needs to be done
- The files you expect to modify
- Any assumptions you're making

Then end with a `continue` disposition.

If the ticket is genuinely ambiguous *after* you've looked at the code, end
with a `fail` disposition explaining what's missing.

If implementing this ticket requires something else to be done first that isn't
captured in the ticket's dependencies, end with a `blocked` disposition
identifying the blocker.

If the ticket is too large for a single implementation pass, end with a
`decompose` disposition listing the subtasks.
