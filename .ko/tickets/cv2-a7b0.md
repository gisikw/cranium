---
id: cv2-a7b0
status: blocked
deps: []
created: 2026-03-11T15:39:56Z
type: task
priority: 2
plan-questions:
  - id: q1
    question: "Should `last_reminder_bucket` be added to the Store.Epoch schema and persisted after each injection, or is it acceptable to fire saturation injections repeatedly once the threshold is crossed?"
    context: "TurnInjector uses this field for rising-edge detection to avoid repeated reminders. The Store.Epoch schema doesn't currently have this field. Without it, saturation injections will fire on every turn once saturation > 50%."
    options:
      - label: "Add to schema and track (Recommended)"
        value: track_bucket
        description: "Add `last_reminder_bucket` field to Store.Epoch and update it after injections fire for proper rising-edge detection"
      - label: "Allow repeated firing"
        value: repeated_ok
        description: "Accept that injections fire every turn once conditions are met, without edge-detection tracking"
  - id: q2
    question: "Should `interrupted_context` and `resume_breadcrumb` fields be added to the Store.Epoch schema as part of this ticket, or deferred to a follow-on?"
    context: "TurnInjector reads these fields for resume and interruption injections, but they don't currently exist in the Store schema or codebase. Adding them expands scope but completes TurnInjector's backing state."
    options:
      - label: "In scope — add to schema (Recommended)"
        value: in_scope
        description: "Add both fields to Store.Epoch schema to fully support TurnInjector functionality"
      - label: "Deferred — out of scope"
        value: deferred
        description: "Skip these fields for now, address in a follow-on ticket"
  - id: q3
    question: "Should `updated_at` be used as a proxy for `last_invoked_at`, or should a dedicated `last_invoked_at` field be added to Store.Epoch?"
    context: "Store.Epoch has `updated_at` (last schema update timestamp). TurnInjector reads `last_invoked_at` for time-gap calculations. Using `updated_at` is simpler but reflects schema updates, not necessarily actual LLM invocations."
    options:
      - label: "Use `updated_at` as proxy (Recommended)"
        value: use_proxy
        description: "Map Store's `updated_at` to TurnInjector's `last_invoked_at` for simplicity"
      - label: "Add dedicated field"
        value: dedicated_field
        description: "Add `last_invoked_at` to Store.Epoch schema for precise tracking of actual invocation times"
---
# Persist TurnInjector system-reminders alongside raw user messages. Currently the raw text is stored (epoch.ex:179) but the enriched text with time-gap, saturation, interrupted, and resume injections is only used for inference and discarded. Injections should be visible in stored history so subsequent turns can reference them.
