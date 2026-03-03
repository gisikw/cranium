cranium dev shell
  just test    — run tests
  just build   — build binary
  just deploy  — build + upgrade
I'll read and evaluate the plan now.

The plan is well-structured with a clear goal, identified files, and ordered tasks. However, it contains **3 open questions** that require human decision-making before implementation can proceed:

1. **Which fields to hot-reload**: Should `attachmentsDir` and `projectsDir` be included, or only the more frequently-changed fields?
2. **data_dir change handling**: Should silently ignoring `data_dir` changes include a warning log?
3. **systemPromptFile path changes**: Should path changes take effect on reload, or only on restart?

These are genuine architectural decisions that need clarification.

```json
{
  "disposition": "needs_input",
  "plan_questions": [
    {
      "id": "q1",
      "question": "Which identity fields should be included in hot-reload behavior?",
      "context": "The plan includes attachmentsDir and projectsDir as reloadable (safe to change, rarely modified). The caller should decide whether these directory path changes are worth supporting or if they should be simplification-removed.",
      "options": [
        {
          "label": "Include directories (Recommended)",
          "value": "include_dirs",
          "description": "Hot-reload displayName, systemPromptContent, summaryThreshold, attachmentsDir, projectsDir, and TTS settings"
        },
        {
          "label": "Exclude directories",
          "value": "exclude_dirs",
          "description": "Hot-reload only displayName, systemPromptContent, summaryThreshold, and TTS settings"
        }
      ]
    },
    {
      "id": "q2",
      "question": "How should changes to `data_dir` on reload be handled?",
      "context": "data_dir cannot be reloaded safely (session/crypto DB is already open on that path). The plan silently ignores changes. Should operators be warned when a reload detects this mismatch?",
      "options": [
        {
          "label": "Log warning on change (Recommended)",
          "value": "warn_on_change",
          "description": "Emit a warning log when data_dir changes are detected during reload, helping operators notice the mismatch"
        },
        {
          "label": "Silently ignore",
          "value": "silent_ignore",
          "description": "Accept data_dir changes in the identity file but do not apply or warn about them"
        }
      ]
    },
    {
      "id": "q3",
      "question": "When `system_prompt_file` path itself changes, when should the new path take effect?",
      "context": "The plan re-reads the system prompt from the path specified in the new identity config. If that path changes (not just content), the new path is used immediately.",
      "options": [
        {
          "label": "Take effect on reload",
          "value": "reload_immediately",
          "description": "A changed system_prompt_file path takes effect on SIGHUP, not requiring restart"
        },
        {
          "label": "Require restart",
          "value": "restart_required",
          "description": "Only path changes on restart; reload only re-reads the existing path's content"
        }
      ]
    }
  ]
}
```
