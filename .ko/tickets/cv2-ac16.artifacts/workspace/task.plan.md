cranium-v2 dev shell
  mix test     — run tests
  mix compile  — compile
  iex -S mix   — interactive shell
  just         — list recipes

Elixir Elixir 1.18.4 (compiled with Erlang/OTP 27)
Erlang/OTP 28
Plan written to `.ko/tickets/cv2-ac16.artifacts/plan.md`.

**Summary:** The fix is a single uncomment in `epoch.ex:199`. `Effects.generate_handoff/1` is fully implemented and ready — the call was intentionally left commented as a TODO. The plan also covers an integration test that wires up the required supervisors, uses `LLM.Mock`, and asserts a handoff lands in Store after `clear` is called.
