cranium-v2 dev shell
  mix test     — run tests
  mix compile  — compile
  iex -S mix   — interactive shell
  just         — list recipes

Elixir Elixir 1.18.4 (compiled with Erlang/OTP 27)
Erlang/OTP 28
Plan updated. Both open questions are resolved:

1. **Audio duration** → Omit entirely. Audio renditions have `url` and `mime` only.
2. **`conversation_id` source** → Explicit `init_stream(stream_id, conversation_id)` call. Public API is now five functions: `init_stream/2`, `add_utterance/3`, `add_cue/4`, `complete/1`, `get/1`.
