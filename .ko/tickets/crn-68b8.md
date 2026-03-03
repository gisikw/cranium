---
id: crn-68b8
status: closed
deps: []
created: 2026-03-01T05:15:10Z
type: task
priority: 2
---
# Echo transcription as quote block before agent dispatch

When a voice message transcription completes, cranium should post the transcript back to the room as a Markdown quote block before forwarding it to the underlying agent for a reply. This makes transcription failures visible in-chat without needing to dig through logs.

## Notes

**2026-03-01 06:07:13 UTC:** Question: When STT returns an empty transcription, should we echo nothing, or should we emit an empty blockquote (`> `)?
Answer: Skip empty echoes (Recommended)
Only echo transcriptions with non-empty text content

**2026-03-01 06:15:12 UTC:** # Implementation Summary: crn-68b8

## What was done

Implemented the full audio message pipeline for the Matrix bridge, culminating in the transcript echo feature:

- **`stt.go`** (new file): `transcribeAudio(sttURL, filePath string) string` — POSTs a multipart audio file to the STT service, parses `{"text": "..."}` JSON response.
- **`rooms.go`**: Added `saveMatrixAudio` (handles encrypted and plaintext MXC URLs) and `audioExtFromMime` (MIME → file extension mapping with `.ogg` fallback for Element voice messages).
- **`bridge.go`**: Added `formatTranscriptEcho` (prefixes each line with `> ` for Markdown blockquote rendering), `formatAudioPrompt` (wraps transcription text for Claude prompt), updated `isSupportedMessageType` to include `MsgAudio`, and threaded `sttURL` through `Bridge`/`BridgeConfig`.
- **`handlers.go`**: Audio handling block — download → transcribe → echo (if non-empty) → forward to Claude.
- **`config.go`** / **`main.go`**: Added `stt_url` to `CraniumConfig` and wired it through `BridgeConfig` to `Bridge`.

## Tests added

- `TestFormatTranscriptEcho` (single-line, multi-line, empty string)
- `TestFormatAudioPrompt` (with and without caption)
- `TestAudioExtFromMime` (full MIME type table)
- `TestBridge_HandleMessage_AudioEchoesTranscript` (httptest.Server mock for STT, verifies echo appears before Claude response)

## Notable decisions

- **Empty transcription**: echo is skipped (`if transcription != ""`), per ticket author confirmation.
- **Message type**: `sendMessage` (MsgText + HTML), not `sendNotice`, so the `> ` prefix renders as a visual `<blockquote>` in Matrix clients.
- **No stt_url configured**: bridge sends a user-visible error message and returns early rather than silently dropping the audio event.

## Fixes applied during review

1. **`time.Now()` → `b.now()`** in `saveMatrixAudio` (INVARIANTS.md: all time access through injectable clock).
2. **`spec/message_routing.feature`** updated: replaced the obsolete "audio is dropped" scenario with three new scenarios covering audio transcription, empty-transcription skip, and the remaining "non-text/image/audio types are dropped" case.

## Context for future readers

The audio pipeline is intentionally scope-expanded beyond the minimal echo change: the triage plan described `formatAudioPrompt`/`transcribeAudio` as pre-existing, but they were not present in HEAD. The implementer built the complete foundation. `stt.go`'s `transcribeAudio` is a standalone package-level function (not a `*Bridge` method) so it can be mocked via `httptest.Server` without structural changes to `Bridge`, as the plan specified.

**2026-03-01 06:15:12 UTC:** ko: SUCCEED
