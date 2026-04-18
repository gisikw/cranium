---
id: crn-4a5f
status: closed
deps: [crn-8b38]
created: 2026-03-30T06:37:46Z
type: task
priority: 2
---
# Global SSE firehose: all events, one connection.

Global SSE firehose: GET /v1/events that emits all stream events across all conversations. Single fat-pipe connection for consumers like headjack — subscribe once, get everything. Builds on conversation-level firehose (crn-8b38) by adding a global {:stream_raw_all} topic that Agent also broadcasts to, or by having the conversation-level topic fan into a global aggregator. Enables fire-and-forget submission from Matrix relay with response pickup via one persistent SSE connection.
