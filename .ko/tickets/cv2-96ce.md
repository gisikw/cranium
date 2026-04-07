---
id: cv2-96ce
status: closed
deps: []
created: 2026-04-05T21:11:25Z
type: task
priority: 2
---
# Route a test room through exo-local profile via headjack

## Context

Cranium-v2 now has a full profile system (`e0eacc8`). Profiles bundle backend + model + identity into named configs in `~/.config/cranium/profiles.yaml`. Three profiles exist on ratched: `exo` (claudecode), `exo-local` (ollama/gemma4-cranium), `code` (ollama, no identity).

The profile is selected per-conversation via the `profile` field in the HTTP POST body that cranium's transport reads. Currently, the Go dispatcher (headjack/cranium-v1) sends `model` but not `profile`.

## What needs to happen

1. **Headjack needs to send `profile` in the HTTP body** to cranium-v2's transport endpoint. The field is `"profile": "exo-local"` (or whatever the room is configured for).

2. **Room-level profile config** — headjack needs a way to map specific Matrix rooms to profiles. Could be:
   - A config field on the room definition (e.g., `profile: exo-local` in whatever config headjack uses for room routing)
   - A dedicated test room (e.g., `#exo-local-test`) mapped to the `exo-local` profile

3. **Test end-to-end** — Send a message in the test room, verify it routes through Ollama on lordhenry (gemma4-cranium), and that handoffs/summaries generate correctly on `!clear`.

## Notes

- PassHeader already supports both `profile` and `model` fields — if `model` is set it overrides the profile's model, so existing rooms sending `model` won't break.
- The `exo-local` profile uses the same EXO.md identity as `exo`, just running on gemma4-cranium via Ollama on lordhenry.
- Effects (handoff/summary) for non-CC backends are now implemented — they assemble history from Store and call the backend directly instead of using CC session resume.
