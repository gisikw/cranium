cranium-v2 dev shell
  mix test     — run tests
  mix compile  — compile
  iex -S mix   — interactive shell
  just         — list recipes

Elixir Elixir 1.18.4 (compiled with Erlang/OTP 27)
Erlang/OTP 28
The plan has **two open questions** that require human input before implementation can proceed:

1. **`interrupted_context` content** (line 88–89): Should this capture the user's message text or the assistant's partial work-in-progress? The current plan proposes user's message, but the TurnInjector injection language ("Here's what you were working on") could imply assistant output.

2. **`resume_breadcrumb` source** (line 90–91): Is the latest handoff document the right source? The plan acknowledges alternatives like "last N messages" or a dedicated field.

The rest of the plan is **complete and feasible**:
- Clear goal and context with specific file references
- Five well-ordered tasks with verification steps
- Proper handling of saturation unit conversion (0–1 → 0–100)
- Correct DB migration pattern noted
- Reasonable test coverage proposed

```json
{"disposition": "needs_input", "plan_questions": [{"id": "q1", "question": "What should be captured as `interrupted_context` when a turn is cancelled?", "context": "This field informs the user what work was interrupted. The plan proposes the user's message text, but TurnInjector's injection wording ('Here's what you were working on') could refer to the assistant's partial output.", "options": [{"label": "User's message text (Recommended)", "value": "user_message", "description": "Store what the user was asking when interrupted—simpler to implement and acceptable context."}, {"label": "Assistant's partial output", "value": "assistant_output", "description": "Capture what the assistant was generating during streaming—more semantically correct but requires storing during inference."}]}, {"id": "q2", "question": "What should be the source of the `resume_breadcrumb` field?", "context": "The plan uses the latest handoff document created by !clear to provide context on resume. If no handoff exists, it defaults to nil.", "options": [{"label": "Latest handoff document (Recommended)", "value": "latest_handoff", "description": "Use the most recent handoff from !clear—clean, explicit source with structured content."}, {"label": "Last N conversation messages", "value": "recent_messages", "description": "Extract context from the most recent epoch messages for lightweight breadcrumb."}, {"label": "Dedicated database field", "value": "dedicated_field", "description": "Store an explicit breadcrumb field in the epochs table for full control."}]}]}
```
