---
id: crn-68b8
status: blocked
deps: []
created: 2026-03-01T05:15:10Z
type: task
priority: 2
plan-questions:
  - id: q1
    question: "When STT returns an empty transcription, should we echo nothing, or should we emit an empty blockquote (`> `)?"
    context: "The plan assumes skipping the echo for empty transcriptions is more defensive, but this affects the user-visible behavior in the chat."
    options:
      - label: "Skip empty echoes (Recommended)"
        value: skip_empty
        description: "Only echo transcriptions with non-empty text content"
      - label: "Echo all transcriptions"
        value: echo_all
        description: "Emit `> ` (an empty blockquote) even for empty transcriptions"
---
# Echo transcription as quote block before agent dispatch

When a voice message transcription completes, cranium should post the transcript back to the room as a Markdown quote block before forwarding it to the underlying agent for a reply. This makes transcription failures visible in-chat without needing to dig through logs.
