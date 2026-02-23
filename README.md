# Cranium

A Matrix-to-agent dispatcher. Receives messages from a Matrix homeserver and routes them to Claude Code sessions (and other agent runtimes), managing session lifecycle, cross-room awareness, and context continuity.

## What it does

- Listens for messages in Matrix rooms via the Matrix client-server API
- Dispatches each room's conversation to a dedicated Claude Code session
- Manages session lifecycle: creation, resumption, cancellation, graceful drain
- Generates handoff documents when sessions are cleared, preserving context for the next session
- Tracks cross-room activity summaries for ambient awareness between rooms
- Injects time-gap reminders and context saturation warnings
- Routes tool approval requests through Matrix reactions
- Supports image and audio message handling

## Building

```bash
just build
```

Requires Go 1.25+ and the `goolm` build tag (pure-Go OLM, no C dependencies).

## Configuration

Cranium uses two YAML config files:

**`cranium.yaml`** — Infrastructure config (Matrix connection, socket, room exclusions). Lives in the cranium repo directory, `.gitignored`. Set `CRANIUM_CONFIG` env var to override the path.

**`identity.yaml`** — Identity/personality config (system prompt file, data directory, display name, attachments). Lives outside the cranium repo, pointed to by `identity_file` in `cranium.yaml`.

```bash
cp cranium.example.yaml cranium.yaml
# Edit cranium.yaml with your Matrix homeserver, credentials, and identity file path
```

See `cranium.example.yaml` for the full schema with defaults.

### What identity.yaml controls

| Field | Default | Description |
|-------|---------|-------------|
| `system_prompt_file` | *(required)* | Path to the file injected via `--append-system-prompt` |
| `data_dir` | *(required)* | Base directory for handoffs, summaries, sessions |
| `display_name` | `Agent` | Name shown in working indicators |
| `attachments_dir` | `<data_dir>/notes/attachments` | Where Matrix images are saved |
| `projects_dir` | `~/Projects` | Base dir for room-name-to-project matching |
| `summary_turn_threshold` | `10` | Turns before triggering cross-room summary |

### Data directory structure

Relative to `data_dir`:

- `handoffs/<room-slug>/` — session continuity documents
- `summaries/<room-slug>.json` — cross-room awareness cache
- `.cranium-sessions.json` — session state
- `.cranium-crypto.db` — E2EE key store
