---
id: cv2-db59
status: open
deps: []
created: 2026-03-06T16:59:35Z
type: task
priority: 2
---
# Input protocol: chunked audio upload with take/seal/backfill (start → chunk → done → backfill missing)

## Notes

**2026-03-06 17:23:28 UTC:** Question: Should the TakeRegistry implement TTL-based cleanup for completed takes?
Answer: Add TTL eviction now
Implement automatic cleanup with configurable TTL (e.g., 24h after completion)

**2026-03-06 17:23:28 UTC:** Question: What Content-Type format do chunk uploads use?
Answer: Multipart form data
Client sends chunks wrapped in multipart/form-data with form fields

**2026-03-06 17:23:28 UTC:** Question: How should the server determine the expected range of chunks in a take?
Answer: Client sends `last_seq` in body (Recommended)
Client includes highest sequence number in /done request; server uses it to compute missing range
