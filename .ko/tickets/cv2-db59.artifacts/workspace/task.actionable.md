cranium-v2 dev shell
  mix test     — run tests
  mix compile  — compile
  iex -S mix   — interactive shell
  just         — list recipes

Elixir Elixir 1.18.4 (compiled with Erlang/OTP 27)
Erlang/OTP 28
Looking at the plan, I can see it's well-structured with a clear goal, ordered tasks, and verification steps. However, it explicitly lists **3 open questions** that affect implementation:

1. **`last_seq` in `/done` body** — The plan assumes this is required, but the README spec doesn't explicitly say how the server determines the expected range. This affects `/done` endpoint parsing.

2. **Chunk Content-Type format** — The plan assumes `application/octet-stream` binary uploads, but needs confirmation on Hearth's actual format (multipart vs raw binary vs base64).

3. **Take lifetime cleanup** — Acknowledged as acceptable to defer but asks whether to add TTL eviction now or later.

These are genuine architectural decisions that should be confirmed before implementation starts. Especially Q1 and Q2 directly affect endpoint logic.

```json
{
  "disposition": "needs_input",
  "plan_questions": [
    {
      "id": "q1",
      "question": "How should the server determine the expected range of chunks in a take?",
      "context": "The plan assumes the client sends `last_seq` (highest sequence number) in the `/done` body so the server knows what chunks to expect. The README doesn't explicitly specify this. This affects how the seal logic detects missing chunks.",
      "options": [
        {
          "label": "Client sends `last_seq` in body (Recommended)",
          "value": "last_seq_in_body",
          "description": "Client includes highest sequence number in /done request; server uses it to compute missing range"
        },
        {
          "label": "Client sends chunk `count` instead",
          "value": "count_in_body",
          "description": "Client sends total chunk count; server derives last_seq as count-1"
        },
        {
          "label": "No trailing gaps allowed",
          "value": "no_trailing_gaps",
          "description": "Server infers expected range from received chunks only; assumes no trailing chunks were lost"
        }
      ]
    },
    {
      "id": "q2",
      "question": "What Content-Type format do chunk uploads use?",
      "context": "The plan assumes clients send `PUT` chunks with `Content-Type: application/octet-stream` (raw binary). If Hearth uses a different format (multipart, base64-encoded JSON, etc.), the request parsing needs adjustment.",
      "options": [
        {
          "label": "Raw binary with application/octet-stream (Recommended)",
          "value": "raw_binary",
          "description": "Client sends raw audio bytes; server reads via Plug.Conn.read_body/2"
        },
        {
          "label": "Multipart form data",
          "value": "multipart",
          "description": "Client sends chunks wrapped in multipart/form-data with form fields"
        },
        {
          "label": "Base64-encoded in JSON",
          "value": "base64_json",
          "description": "Client sends JSON with audio as base64 string; server decodes before buffering"
        }
      ]
    },
    {
      "id": "q3",
      "question": "Should the TakeRegistry implement TTL-based cleanup for completed takes?",
      "context": "Completed and abandoned takes will accumulate in TakeRegistry memory over time. The plan notes this is acceptable for now (takes are small), but asks whether to add eviction now or defer as a follow-up.",
      "options": [
        {
          "label": "Defer cleanup (Recommended)",
          "value": "defer_cleanup",
          "description": "Accept memory accumulation for now; track as technical debt for later optimization"
        },
        {
          "label": "Add TTL eviction now",
          "value": "ttl_now",
          "description": "Implement automatic cleanup with configurable TTL (e.g., 24h after completion)"
        },
        {
          "label": "Manual cleanup only",
          "value": "manual_cleanup",
          "description": "Add an admin endpoint to clear old takes on demand; no automatic cleanup"
        }
      ]
    }
  ]
}
```
