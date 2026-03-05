You are evaluating whether a plan is ready for implementation.

Read the plan artifact at `$KO_ARTIFACT_DIR/plan.md`.

Check:

1. **Open Questions section.** If the plan lists open questions that require
   human input, this plan is NOT actionable. End with a `needs_input` disposition.
   Convert each open question into a structured plan question with:
   - `id`: short slug (e.g. `q1`, `q2`)
   - `question`: the question text, standalone and self-contained
   - `context`: (optional) relevant background from the plan
   - `options`: 2-4 concrete choices, each with `label`, `value`, and optional `description`

   Option formatting rules:
   - Labels should be concise noun phrases, not prefixed with "Option A" etc.
   - Do NOT include an "Other" or "Custom" option — that's added by the UI.
   - When the plan recommends an approach, mark it: "Redis migration (Recommended)"
   - `value` should be a short snake_case slug (e.g. `redis`, `local_cache`)
   - `description` is a single sentence expanding on what the option means

   The options should represent the realistic choices surfaced by the plan. If the
   plan doesn't suggest specific options, infer the most likely alternatives from
   context.

2. **Completeness.** Does the plan have a clear goal, identified files, and
   ordered tasks with verification steps? If the plan is vague or missing
   key sections, end with a `fail` disposition explaining what's missing.

3. **Feasibility.** Do the referenced files and patterns plausibly exist based
   on the plan's Context section? Flag anything that looks wrong.

If the plan is complete, has no open questions, and looks feasible: end with
a `continue` disposition.

Do NOT investigate the codebase yourself. You are judging the plan as written.

Your output MUST end with a fenced JSON block. Examples:

```json
{"disposition": "continue"}
```

```json
{"disposition": "needs_input", "plan_questions": [{"id": "q1", "question": "Should we keep backwards compatibility?", "context": "INVARIANTS.md requires semver", "options": [{"label": "Deprecation path (Recommended)", "value": "deprecate", "description": "Add warnings, support both for 2 releases"}, {"label": "Hard break", "value": "hard_break", "description": "Remove support immediately"}]}]}
```

```json
{"disposition": "fail", "reason": "Plan is missing verification steps for tasks 2 and 3"}
```
