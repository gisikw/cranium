cranium dev shell
  just test    — run tests
  just build   — build binary
  just deploy  — build + upgrade
The plan is written to `.ko/tickets/crn-1c95.artifacts/plan.md`. Here's a summary:

## What I found

The current TTS config lives in a separate XDG JSON file (`~/.config/cranium/tts.json`) loaded on every TTS call via `loadTTSConfig()` in `socket.go`. Identity config (`identity.yaml`) is loaded once at startup and its fields are scattered individually across the `Bridge` struct — no synchronization, because they're written once before any goroutines start.

## The Plan

**Two-part change:**

**1. Consolidate TTS into identity.yaml:**
- Add a `TTS { Voice, Format }` sub-struct to `IdentityConfig`
- Remove `TTSConfig`/`ttsConfigPath`/`loadTTSConfig` from `socket.go`
- `synthesizeAndPostAudio` reads defaults from the bridge instead

**2. Hot-reload via SIGHUP:**
- Introduce an `identityState` struct holding all hot-reloadable fields (`displayName`, `systemPromptContent`, `summaryThreshold`, `attachmentsDir`, `projectsDir`, `ttsVoice`, `ttsFormat`)
- Store it in `Bridge` as `atomic.Pointer[identityState]` — atomic swap means no mutex needed at call sites, call sites just change from `b.displayName` to `b.ident.Load().displayName`
- Add `reloadIdentity()` method that re-parses the file and calls `b.ident.Store()`
- Add `SIGHUP` to `main.go`'s signal handler to trigger reload without stopping the process

## Open Questions

Three questions worth human input before implementation:
1. Should `attachmentsDir`/`projectsDir` be hot-reloadable?
2. Should a `data_dir` change on reload log a warning?
3. Should changes to `system_prompt_file` *path* (not just content) take effect immediately on reload, or only on restart?
