---
id: cv2-3833
status: open
deps: []
created: 2026-03-06T12:43:03Z
type: task
priority: 2
---
# Agent tool routing: implement real tool dispatch in ToolExecutor and ToolRouter registration

## Notes

**2026-03-06 16:58:17 UTC:** Question: Should tools be registered in application config (fixed at startup) or via a runtime registration function?
Answer: Runtime registration function
Add ToolRouter.register/2 for dynamic registration with cleaner test isolation

**2026-03-06 16:58:17 UTC:** Question: How should tool modules be identified in logs after changing the ToolExecutor signature?
Answer: Add name/0 callback to Tool behaviour (Recommended)
Add optional name/0 callback for human-readable tool names in logs
