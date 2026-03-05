---
id: cv2-ede0
status: open
deps: []
created: 2026-03-05T22:55:49Z
type: task
priority: 2
---
# STT integration: wire Ingress Transcriber to stt.gisi.network HTTP endpoint, accept audio input and transcribe to text

Cranium v2 Ingress stage has a Transcriber step (lib/cranium/ingress/transcriber.ex) that is currently a stub. Wire it to the Whisper STT HTTP endpoint.

## Whisper endpoint

POST audio to stt.gisi.network/transcribe. Check ~/Projects/cranium/ (v1 source, Go) for the exact request shape — it was wired there for voice message support. The endpoint accepts audio files and returns plain text transcription.

## What to implement

1. Read lib/cranium/ingress/transcriber.ex — stub step module
2. Read lib/cranium/backend/stt.ex — defines the STT behaviour
3. Implement Cranium.Backend.STT.Whisper to POST audio binary to stt.gisi.network/transcribe, return {:ok, text}
4. Wire Transcriber to call STT backend when event type is :audio
5. Pass-through for :text events (no transcription needed)

## Acceptance criteria

- Cranium.Backend.STT.Whisper.transcribe(audio_binary) returns {:ok, "transcribed text"}
- Ingress correctly routes audio events through transcription
- Tests for the backend (mock HTTP)
