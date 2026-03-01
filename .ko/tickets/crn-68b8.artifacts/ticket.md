---
id: crn-68b8
status: open
deps: []
created: 2026-03-01T05:15:10Z
type: task
priority: 2
---
# Echo transcription as quote block before agent dispatch

When a voice message transcription completes, cranium should post the transcript back to the room as a Markdown quote block before forwarding it to the underlying agent for a reply. This makes transcription failures visible in-chat without needing to dig through logs.
