---
id: cv2-bae4
status: open
deps: []
created: 2026-03-05T22:55:49Z
type: task
priority: 2
---
# Segment manifest design: define manifest format for multimedia responses (renditions, cues, growing playlist)

The manifest format is designed (see README.md "Segment Manifest" section). This ticket covers the implementation: a GenServer that tracks segments for active streams and serializes the manifest JSON.

## What to implement

1. Cranium.Manifest GenServer — tracks active streams as %{stream_id => manifest_state}
2. manifest_state holds: status (:streaming | :complete), segments list, conversation_id
3. API: add_utterance(stream_id, index, text), add_cue(stream_id, index, cue_type, data), complete(stream_id), get(stream_id)
4. Segments are utterance (with text rendition always available, audio rendition URL advertised but served lazily from TTS cache) or cue (SCTE marker data)
5. JSON serialization matching the shape in README.md
6. Manifest is ephemeral — lives only while stream is active + a short TTL after completion

## Depends on

Nothing strictly, but integrates with Egress (which populates it) and HTTP transport (which serves it).

## Acceptance criteria

- Manifest.add_utterance/add_cue builds correct segment list
- Manifest.get returns JSON-serializable map matching README spec
- Manifest.complete sets status to :complete
- Tests for all operations
