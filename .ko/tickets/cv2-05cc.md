---
id: cv2-05cc
status: closed
deps: []
created: 2026-03-30T21:39:09Z
type: task
priority: 2
---
# Add conversation_id to SSE payloads via Map.put.

Include conversation_id in all lifecycle event SSE payloads — epoch_started, epoch_cleared, handoff_complete, message_received all carry conversation_id in the internal tuple but the multi_stream_sse_loop drops it during serialization. One-line fix per event: Map.put(meta, :conversation_id, conversation_id) before sse_event/2. Headjack firehose cutover blocked on this.
