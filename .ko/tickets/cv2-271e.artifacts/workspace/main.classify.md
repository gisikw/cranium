cranium-v2 dev shell
  mix test     — run tests
  mix compile  — compile
  iex -S mix   — interactive shell
  just         — list recipes

Elixir Elixir 1.18.4 (compiled with Erlang/OTP 27)
Erlang/OTP 28
This is a **task**.

The ticket describes *what to build*: a concrete feature implementation with specific steps and acceptance criteria. It's asking for code changes to implement TTS integration in the Egress stage, wire the Synthesizer step, and implement paragraph-based chunking with word thresholds.

The ticket provides:
- Clear implementation steps (read modules, implement Kokoro backend, wire Synthesizer, implement chunking)
- Specific technical details (paragraph boundaries, word thresholds: 30-word first chunk, 100-word subsequent)
- Acceptance criteria to validate completion

```json
{"disposition": "route", "workflow": "task"}
```
