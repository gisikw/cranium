---
id: cv2-190a
status: open
deps: []
created: 2026-03-11T15:40:02Z
type: task
priority: 2
---
# Accrue handoff documents on the epoch rather than replacing globally. Currently handoffs are stored via Store.save_handoff(conversation_id, text) which overwrites. Instead, handoff text should be a field on the epoch row itself, so each epoch preserves its own handoff and the history is not lost. PromptBuilder would then read the handoff from the previous epoch's row rather than the latest global handoff.
