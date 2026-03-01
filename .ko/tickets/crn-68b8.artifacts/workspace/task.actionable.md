cranium dev shell
  just test    — run tests
  just build   — build binary
  just deploy  — build + upgrade
I'll evaluate the plan across the three dimensions:

## 1. Open Questions

The plan has an **Open Questions** section with two items, but both include **Assuming:** statements that provide decisions:

- **Q1 (Empty transcription)**: "should we echo empty transcriptions?" → Assuming: skip the echo when transcription is empty
- **Q2 (MsgType)**: "should we use `sendMessage` or `sendNotice`?" → Assuming: `sendMessage` (supports Markdown rendering)

Q2 is resolved by the requirements ("Markdown quote block" necessitates `sendMessage`). However, **Q1 is a genuine architectural choice** — skipping vs. emitting an empty blockquote are both defensible — that warrants confirmation before implementation.

## 2. Completeness ✓

- **Goal**: Clear and specific
- **Context**: Provides relevant code locations and existing patterns
- **Files identified**: handlers.go, bridge.go, bridge_test.go, handlers_test.go, stt.go
- **Ordered tasks**: 4 well-defined tasks with specific line numbers
- **Verification**: Each task includes a `Verify:` step

The plan is complete and well-structured.

## 3. Feasibility ✓

References to specific patterns (`formatAudioPrompt`, `sendMessage`, `transcribeAudio`) and file structures align with the repo context (Go Matrix bridge with handlers, bridge logic, and STT integration). The proposed approach (pure function → integration test with `httptest.Server`) follows stated conventions.

---

This plan has one resolvable decision point before implementation can proceed:

```json
{"disposition": "needs_input", "plan_questions": [{"id": "q1", "question": "When STT returns an empty transcription, should we echo nothing, or should we emit an empty blockquote (`> `)?", "context": "The plan assumes skipping the echo for empty transcriptions is more defensive, but this affects the user-visible behavior in the chat.", "options": [{"label": "Skip empty echoes (Recommended)", "value": "skip_empty", "description": "Only echo transcriptions with non-empty text content"}, {"label": "Echo all transcriptions", "value": "echo_all", "description": "Emit `> ` (an empty blockquote) even for empty transcriptions"}]}]}
```
