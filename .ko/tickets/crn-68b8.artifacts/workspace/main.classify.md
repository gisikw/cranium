cranium dev shell
  just test    — run tests
  just build   — build binary
  just deploy  — build + upgrade
Looking at this ticket:

**Title**: "Echo transcription as quote block before agent dispatch"

**Description**: Specifies what cranium should do when a voice message transcription completes—post the transcript as a Markdown quote block back to the room before forwarding to the agent. Includes the purpose (make failures visible).

This describes **what to build**, not what's broken:
- Clear feature request with defined behavior
- Specific implementation details (Markdown quote block, timing relative to agent dispatch)
- Expected output is code changes

```json
{"disposition": "route", "workflow": "task"}
```
