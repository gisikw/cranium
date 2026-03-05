---
id: cv2-bae4
status: blocked
deps: []
created: 2026-03-05T22:55:49Z
type: task
priority: 2
plan-questions:
  - id: q1
    question: "Should the audio rendition include a `duration` field, and if so, how should it be populated before TTS synthesis completes?"
    context: "The README shows `"duration": 1.2` on audio renditions, but audio is served lazily from TTS cache. Duration won't be known until synthesis finishes. If the manifest needs post-synthesis updates, an `update_segment/3` API would be required."
    options:
      - label: "Omit duration field (Recommended)"
        value: omit_duration
        description: "Audio renditions don't include duration initially; updated via API after TTS synthesis if needed"
      - label: "Include duration as null"
        value: null_duration
        description: "Audio renditions include `"duration": null` initially, replaced with actual value after synthesis"
      - label: "Add update API"
        value: update_api
        description: "Implement an explicit `update_segment/3` function to modify segments after creation"
  - id: q2
    question: "How should `conversation_id` be passed to the Manifest?"
    context: "The ticket API signatures don't include `conversation_id` in `add_utterance/add_cue`. The plan assumes first-call initialization or nil default, but a cleaner design might use an explicit `init_stream` call that Egress invokes with metadata from `stream_metadata`."
    options:
      - label: "Explicit init_stream call (Recommended)"
        value: init_stream_api
        description: "Add `init_stream(stream_id, conversation_id)` for Egress to call on stream start"
      - label: "Optional param on first call"
        value: first_call_param
        description: "Pass `conversation_id` to the first `add_utterance` call; no separate init"
      - label: "Defaults to nil"
        value: nil_default
        description: "Conversation_id defaults to nil; no explicit initialization needed"
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
