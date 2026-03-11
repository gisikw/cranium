---
id: cv2-28c1
status: open
deps: []
created: 2026-03-11T15:39:59Z
type: task
priority: 2
---
# Wire epoch state into TurnInjector pipeline context. Currently pipeline_ctx (epoch.ex:167-174) does not include epoch[:last_invoked_at], epoch[:saturation], epoch[:last_reminder_bucket], epoch[:interrupted_context], or epoch[:resume_breadcrumb]. All four TurnInjector injections (time-gap, saturation, interrupted, resume) are dead code because the data they check is never populated. Need: track last_invoked_at on epochs (add column or derive from last message timestamp), pass saturation through, wire interrupted_context and resume_breadcrumb.
