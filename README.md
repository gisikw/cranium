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

## Running

Cranium expects the following environment variables:

```bash
MATRIX_PASSWORD=...      # Matrix account password
EXO_SESSION_ID=...       # Optional: session ID for self-awareness
```

See `.env.example` for the full list.

## Configuration

Cranium is parameterized by the directory it runs from. It reads:

- `EXO.md` (or equivalent identity file) for `--append-system-prompt` injection
- `handoffs/<room-slug>/` for session continuity
- `summaries/<room-slug>.json` for cross-room awareness

These paths are relative to a configurable base directory, not baked into the binary.
