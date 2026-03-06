---
id: cv2-15da
status: open
deps: []
created: 2026-03-06T12:43:03Z
type: task
priority: 2
---
# Epoch lifecycle: track saturation via upsert_epoch during inference

## Notes

**2026-03-06 16:57:25 UTC:** Question: How should the `compute_saturation` function be exposed for testing?
Answer: Public def with @doc false (Recommended)
Define as `def` in epoch.ex with @doc false, enabling direct unit tests without a new module

**2026-03-06 16:57:25 UTC:** Question: When should the epoch row be created in the database?
Answer: On process start in init (Recommended)
Call upsert_epoch in init/1 so a DB row exists whenever an epoch process exists

**2026-03-06 16:57:25 UTC:** Question: How should the max context token limit be set?
Answer: Read from model configuration
Query the model's actual context limit at runtime, enabling flexibility for future changes
