cranium-v2 dev shell
  mix test     — run tests
  mix compile  — compile
  iex -S mix   — interactive shell
  just         — list recipes

Elixir Elixir 1.18.4 (compiled with Erlang/OTP 27)
Erlang/OTP 28
I've read the plan. It has clear goals, context, an articulated approach, and 5 specific tasks with verification steps. However, **the plan lists 3 open questions that require human decision-making**.

Per the evaluation criteria, a plan with unresolved open questions is not actionable and requires input before implementation.

Here are the open questions extracted from the plan:

```json
{
  "disposition": "needs_input",
  "plan_questions": [
    {
      "id": "q1",
      "question": "How should the `compute_saturation` function be exposed for testing?",
      "context": "INVARIANTS.md requires pure decision functions to be unit testable. The saturation formula is a one-liner that computes input_tokens / 200,000 clamped to 1.0.",
      "options": [
        {
          "label": "Public def with @doc false (Recommended)",
          "value": "public_nodoc",
          "description": "Define as `def` in epoch.ex with @doc false, enabling direct unit tests without a new module"
        },
        {
          "label": "Private defp function",
          "value": "private_defp",
          "description": "Keep as private; test saturation indirectly via integration tests"
        },
        {
          "label": "Separate Cranium.Epoch.Saturation module",
          "value": "separate_module",
          "description": "Create a dedicated module for the saturation step, following architectural patterns"
        }
      ]
    },
    {
      "id": "q2",
      "question": "When should the epoch row be created in the database?",
      "context": "Creating on init ensures the DB always has a row for external readers; creating lazily keeps initialization lighter but requires handling the first submit specially.",
      "options": [
        {
          "label": "On process start in init (Recommended)",
          "value": "init",
          "description": "Call upsert_epoch in init/1 so a DB row exists whenever an epoch process exists"
        },
        {
          "label": "Lazily on first submit",
          "value": "lazy",
          "description": "Create the row only when the first {:submit, ...} call arrives"
        }
      ]
    },
    {
      "id": "q3",
      "question": "How should the max context token limit be set?",
      "context": "Currently all Claude models share a 200,000 token limit. If the backend model becomes configurable, this constant may need to be dynamic.",
      "options": [
        {
          "label": "Hardcoded constant 200,000 (Recommended)",
          "value": "hardcoded",
          "description": "Use a module attribute @max_context_tokens 200_000; sufficient for all current Claude models"
        },
        {
          "label": "Read from model configuration",
          "value": "configurable",
          "description": "Query the model's actual context limit at runtime, enabling flexibility for future changes"
        }
      ]
    }
  ]
}
```
