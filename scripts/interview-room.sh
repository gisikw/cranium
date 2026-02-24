#!/usr/bin/env bash
set -euo pipefail

# Manual room summary generator
# Usage: ./scripts/interview-room.sh <room-slug> [room-id]
#
# Finds the session for the given room slug and forks it to generate
# a cross-room awareness summary.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Resolve data_dir from cranium.yaml -> identity.yaml chain
CRANIUM_CONFIG="${CRANIUM_CONFIG:-$REPO_ROOT/cranium.yaml}"
IDENTITY_FILE=$(grep -oP 'identity_file:\s*\K.*' "$CRANIUM_CONFIG" 2>/dev/null || echo "")
if [ -n "$IDENTITY_FILE" ]; then
    DATA_DIR=$(grep -oP 'data_dir:\s*\K.*' "$IDENTITY_FILE" 2>/dev/null || echo "$REPO_ROOT")
else
    DATA_DIR="$REPO_ROOT"
fi

SESSIONS_FILE="$DATA_DIR/.cranium-sessions.json"
SUMMARIES_DIR="$DATA_DIR/summaries"
SLUG="${1:?Usage: interview-room.sh <room-slug> [room-id]}"

SUMMARY_FILE="$SUMMARIES_DIR/${SLUG}.json"

# Try room ID from: arg > existing summary > interactive prompt
ROOM_ID="${2:-}"
if [ -z "$ROOM_ID" ] && [ -f "$SUMMARY_FILE" ]; then
    ROOM_ID=$(jq -r '.room_id' "$SUMMARY_FILE")
    echo "Found room ID from existing summary: $ROOM_ID"
elif [ -z "$ROOM_ID" ]; then
    echo "No existing summary for '$SLUG'."
    echo "Provide the Matrix room ID (e.g., !abc123:matrix.example.com):"
    read -r ROOM_ID
fi

if [ -z "$ROOM_ID" ]; then
    echo "Error: no room ID"
    exit 1
fi

# Look up session ID
SESSION_ID=$(jq -r --arg rid "$ROOM_ID" '.[$rid].session_id // empty' "$SESSIONS_FILE")
if [ -z "$SESSION_ID" ]; then
    echo "No active session found for room $ROOM_ID"
    exit 1
fi

echo "Session: $SESSION_ID"
echo "Generating summary..."

PROMPT='SYSTEM TASK: You are being invoked as a forked snapshot of an active session. Ignore the previous conversational flow and respond ONLY to this instruction.

Write a 2-4 sentence summary of what this room'\''s conversation has been about. This summary will be shown to your other instances in different rooms for cross-room awareness. Focus on: what'\''s being worked on, key decisions made, and current state. Respond with ONLY the summary text — no commentary, no meta-discussion, no tools.'

RESULT=$(claude -p "$PROMPT" \
    --resume "$SESSION_ID" \
    --fork-session \
    --no-session-persistence \
    --tools "" \
    2>/dev/null)

if [ -z "$RESULT" ]; then
    echo "Error: empty result from Claude"
    exit 1
fi

mkdir -p "$SUMMARIES_DIR"

NOW=$(date +%s)

# Try to get a better room name from existing summary, fall back to slug
ROOM_NAME="$SLUG"
if [ -f "$SUMMARY_FILE" ]; then
    EXISTING_NAME=$(jq -r '.room_name // empty' "$SUMMARY_FILE")
    if [ -n "$EXISTING_NAME" ]; then
        ROOM_NAME="$EXISTING_NAME"
    fi
fi

jq -n \
    --arg rid "$ROOM_ID" \
    --arg rname "$ROOM_NAME" \
    --arg summary "$RESULT" \
    --argjson ts "$NOW" \
    '{
        room_id: $rid,
        room_name: $rname,
        summary: $summary,
        last_message_ts: $ts,
        last_summary_ts: $ts,
        turns_since_summary: 0
    }' > "$SUMMARY_FILE"

echo ""
echo "--- Summary ---"
echo "$RESULT"
echo ""
echo "Saved to $SUMMARY_FILE"
