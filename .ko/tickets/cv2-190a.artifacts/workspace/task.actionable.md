cranium-v2 dev shell
  mix test     — run tests
  mix compile  — compile
  iex -S mix   — interactive shell
  just         — list recipes

Elixir Elixir 1.18.4 (compiled with Erlang/OTP 27)
Erlang/OTP 28
```json
{
  "disposition": "needs_input",
  "plan_questions": [
    {
      "id": "q1",
      "question": "Should the unused `handoffs` table be dropped in the same migration, or left for follow-up cleanup?",
      "context": "After moving handoff text to the epochs table, the separate handoffs table becomes unused. Dropping it in the same migration is cleaner but removes data; leaving it defers cleanup.",
      "options": [
        {
          "label": "Drop in same migration (Recommended)",
          "value": "drop_now",
          "description": "Remove the handoffs table immediately for a complete, clean migration"
        },
        {
          "label": "Leave for follow-up",
          "value": "defer_cleanup",
          "description": "Keep the table for safety; drop it in a separate cleanup ticket later"
        }
      ]
    }
  ]
}
```
