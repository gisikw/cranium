## Goal

Move TTS voice/format config into `identity.yaml` and make the identity file hot-reloadable via SIGHUP.

## Context

**Current TTS config**: `socket.go` loads TTS defaults from `~/.config/cranium/tts.json` via `loadTTSConfig()` / `TTSConfig` struct / `ttsConfigPath` func var. This is called on every `synthesizeAndPostAudio` invocation.

**Identity config** (`config.go:IdentityConfig`): holds personality config (`system_prompt_file`, `data_dir`, `display_name`, `attachments_dir`, `projects_dir`, `summary_turn_threshold`). Loaded once at startup in `main.go`, then individual fields are scattered across `Bridge` struct (`bridge.go:Bridge`).

**Identity fields on Bridge** (written once at startup, never synced): `displayName`, `systemPromptContent`, `attachmentsDir`, `projectsDir`, `summaryThreshold`. Plus `sttURL` from craniumCfg. These are currently read without synchronization — safe because they're only written before any goroutines are spawned.

**Hot-reload constraint**: Fields that can change at runtime safely: `displayName`, `systemPromptContent` (re-read from file), `summaryThreshold`, `attachmentsDir`, `projectsDir`, plus new TTS defaults. **Not safe to reload**: `dataDir` (session/crypto DB open on that path), `sttURL` (infrastructure config).

**Thread-safety approach**: Use `atomic.Pointer[identityState]` (available since Go 1.19; project uses Go 1.25.4). Define `identityState` struct holding all hot-reloadable fields. All reads call `b.ident.Load()`. Reload atomically swaps with `b.ident.Store()`. This avoids adding mutex locks to many call sites.

**Signal handling**: `main.go` already handles `SIGINT`, `SIGTERM`, `SIGUSR1`. SIGHUP is free for config reload.

**Spec invariant**: Every behavior needs a spec (`spec/*.feature`). Hot-reload needs a new feature file.

**500-line limit**: `socket.go` is already at 602 lines (existing violation). We remove ~100 lines from it (TTSConfig, ttsConfigPath, loadTTSConfig), bringing it toward compliance.

## Approach

1. Add a `TTS` sub-struct to `IdentityConfig` with `Voice` and `Format` fields (yaml tags). Remove the XDG-based `TTSConfig`/`ttsConfigPath`/`loadTTSConfig` from `socket.go` and replace with `b.ident.Load().ttsVoice`/`ttsFormat`.
2. Introduce `identityState` struct in `bridge.go`, replacing the scattered identity fields in `Bridge` with a single `ident atomic.Pointer[identityState]`. Update all read call sites to use `b.ident.Load()`.
3. Add a `reloadIdentity(path string) error` method, a `SIGHUP` handler in `main.go`, and a `spec/identity_hot_reload.feature` spec file.

## Tasks

1. **[config.go:IdentityConfig]** — Add `TTS struct { Voice string \`yaml:"voice"\`; Format string \`yaml:"format"\` } \`yaml:"tts"\`` field to `IdentityConfig`. No validation change needed (TTS fields are optional; defaults applied elsewhere).
   Verify: existing `TestLoadIdentityConfig_*` tests still pass; new test `TestLoadIdentityConfig_TTSFields` passes.

2. **[config_test.go]** — Add `TestLoadIdentityConfig_TTSFields`: write an identity.yaml with `tts: {voice: af_kore, format: wav}` and assert the parsed fields round-trip correctly.
   Verify: `just test` passes.

3. **[bridge.go]** — Define `identityState` struct with fields: `displayName`, `systemPromptContent`, `summaryThreshold`, `attachmentsDir`, `projectsDir`, `ttsVoice`, `ttsFormat`. Remove those individual fields from `Bridge`. Add `ident atomic.Pointer[identityState]` and `identityPath string` to `Bridge`. Update `BridgeConfig` to add `TTSVoice string`, `TTSFormat string`, and `IdentityPath string`. Update `NewBridge` to construct an `identityState` and call `b.ident.Store()`. Update all 8 call sites that read identity fields (`b.displayName`, `b.systemPromptContent`, etc.) to use `b.ident.Load().fieldName`. Add `reloadIdentity() error` method: reads `b.identityPath`, re-parses identity YAML, re-reads the system prompt file, constructs a new `identityState`, calls `b.ident.Store()`, logs success.
   Verify: `just test` passes.

4. **[socket.go]** — Remove `TTSConfig` struct, `ttsConfigPath` func var, and `loadTTSConfig()` function. In `synthesizeAndPostAudio`, replace the `cfg := loadTTSConfig()` block with reading `b.ident.Load()` and using `.ttsVoice`/`.ttsFormat` as the defaults (same precedence: explicit arg > identity defaults > hardcoded fallback `af_nicole`/`mp3`).
   Verify: existing TTS tests still pass after updating their setup (next task).

5. **[socket_test.go]** — Remove the `ttsConfigPath` override pattern from `TestBridge_TTS_ConfigFileOverridesDefault` and `TestBridge_TTS_ExplicitArgOverridesConfig`. Replace with directly storing an `identityState` via `b.ident.Store(&identityState{ttsVoice: "af_kore", ...})` before the test. `TestBridge_TTS_Success` no longer needs the `ttsConfigPath` override (bridge ident will have empty defaults, falling back to `af_nicole`).
   Verify: all TTS tests pass.

6. **[main.go]** — Pass `IdentityPath: craniumCfg.IdentityFile`, `TTSVoice: identityCfg.TTS.Voice`, `TTSFormat: identityCfg.TTS.Format` in the `BridgeConfig` literal. Add `syscall.SIGHUP` to the `signal.Notify` call. In the signal goroutine, add a SIGHUP branch: call `bridge.reloadIdentity()`, log the result, and continue the loop (don't cancel/stop).
   Verify: build succeeds; `just test` passes.

7. **[spec/identity_hot_reload.feature]** — New spec file. Scenarios: (a) SIGHUP reloads display name without restart; (b) SIGHUP reloads system prompt content; (c) SIGHUP reloads TTS defaults; (d) if identity file is unreadable on reload, the old config is preserved and an error is logged.
   Verify: spec exists and is coherent.

8. **[bridge_test.go or a new bridge_reload_test.go]** — Add tests for `reloadIdentity`: (a) updates identity fields atomically; (b) re-reads system prompt file content; (c) returns an error and preserves old state if file is missing or invalid.
   Verify: new tests pass; `just test` passes.

## Open Questions

1. **Which fields should hot-reload update?** `attachmentsDir` and `projectsDir` are safe to reload (just directory paths), but they're also rarely changed. The plan includes them; remove if the caller prefers simpler semantics.

2. **Should `data_dir` changes in the identity file trigger a warning log?** Currently the plan silently ignores `data_dir` changes on reload (since the session store is already open). A log warning would help operators notice the mismatch.

3. **`systemPromptFile` path itself changing on reload**: the plan re-reads the system prompt file from whatever path `system_prompt_file` points to in the new config. If the *path* changes (not just the content), the new path is used. Is that intended, or should path changes only take effect on restart?
