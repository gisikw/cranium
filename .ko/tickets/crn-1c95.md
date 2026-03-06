---
id: crn-1c95
status: in_progress
deps: []
created: 2026-03-03T00:08:26Z
type: task
priority: 2
---
# Consolidate the tts.json idea as just a field in the identity file. But can we also make sure changes to the identity file update the running system without a restart?

## Notes

**2026-03-03 04:29:46 UTC:** Question: Which identity fields should be included in hot-reload behavior?
Answer: Include directories (Recommended)
Hot-reload displayName, systemPromptContent, summaryThreshold, attachmentsDir, projectsDir, and TTS settings

**2026-03-03 04:29:46 UTC:** Question: When `system_prompt_file` path itself changes, when should the new path take effect?
Answer: Take effect on reload
A changed system_prompt_file path takes effect on SIGHUP, not requiring restart

**2026-03-03 04:29:46 UTC:** Question: How should changes to `data_dir` on reload be handled?
Answer: Log warning on change (Recommended)
Emit a warning log when data_dir changes are detected during reload, helping operators notice the mismatch
