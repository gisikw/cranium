---
id: crn-8b38
status: closed
deps: []
created: 2026-03-30T06:37:39Z
type: task
priority: 2
---
# Real-time conversation event streaming via SSE.

Conversation-level SSE firehose: GET /v1/conversations/:id/events that subscribes to all Passes for a conversation, aggregating raw stream events across Pass boundaries. Epoch broadcasts {:pass_started, stream_id} on a {:conversation, conversation_id} topic when a new Pass begins; the conversation SSE handler auto-subscribes to each new Pass's raw stream and relays events to the client. Single long-lived connection per conversation.
