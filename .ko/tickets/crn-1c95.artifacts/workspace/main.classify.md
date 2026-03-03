cranium dev shell
  just test    — run tests
  just build   — build binary
  just deploy  — build + upgrade
Looking at this ticket:

**"Consolidate the tts.json idea as just a field in the identity file. But can we also make sure changes to the identity file update the running system without a restart?"**

This describes **what to build**, not what's broken:
1. Refactor/consolidate TTS configuration into the identity file
2. Implement hot-reload of the identity file without requiring a system restart

Both are code change requests describing desired implementation, not reporting unexpected behavior or asking investigative questions.

```json
{"disposition": "route", "workflow": "task"}
```
