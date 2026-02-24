#!/usr/bin/env bash
set -euo pipefail

# Upgrade orchestrator for cranium
# Called by: just deploy (or directly)
# Session notification is automatic via CRN_ROOM_ID env var (set by bridge)

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BINARY="$REPO_ROOT/cranium"
BACKUP="$REPO_ROOT/cranium.old"
SERVICE="cranium"
NOTIFY_ROOM="${CRN_ROOM_ID:-}"

log() { echo "[upgrade] $*"; }

# 1. Back up current binary
if [ -f "$BINARY" ]; then
    cp "$BINARY" "$BACKUP"
    log "Backed up current binary to cranium.old"
else
    log "No existing binary found — fresh build"
fi

# 2. Build new binary with version from git
VERSION=$(git -C "$REPO_ROOT" rev-parse --short HEAD)
log "Building cranium ($VERSION)..."
cd "$REPO_ROOT"
if ! go build -tags goolm -ldflags "-X main.version=$VERSION" -o "$BINARY" .; then
    log "Build failed!"
    if [ -f "$BACKUP" ]; then
        mv "$BACKUP" "$BINARY"
        log "Restored previous binary"
    fi
    exit 1
fi
log "Build successful"

# 3. Get PID
PID=$(systemctl show "$SERVICE" --property=MainPID --value 2>/dev/null || true)
if [ -z "$PID" ] || [ "$PID" = "0" ]; then
    log "Service not running — nothing to drain"
    log "Start it with: systemctl start $SERVICE"
    exit 0
fi

# 4. Write resume breadcrumb so the new instance can resume the triggering session
SOCKET_PATH="${CRANIUM_SOCKET:-/tmp/cranium.sock}"
DATA_DIR=$(grep -oP 'data_dir:\s*\K.*' "$(grep -oP 'identity_file:\s*\K.*' "$REPO_ROOT/cranium.yaml")" 2>/dev/null || echo "$REPO_ROOT")
RESUME_FILE="$DATA_DIR/.cranium-resume"

if [ -n "$NOTIFY_ROOM" ]; then
    # Try to get enriched breadcrumb message from the running bridge
    RESUME_MSG=""
    if [ -S "$SOCKET_PATH" ]; then
        # Build the breadcrumb helper if needed
        BREADCRUMB_HELPER="$REPO_ROOT/cmd/crn-breadcrumb/crn-breadcrumb"
        if [ ! -f "$BREADCRUMB_HELPER" ]; then
            log "Building breadcrumb helper..."
            (cd "$REPO_ROOT" && go build -o cmd/crn-breadcrumb/crn-breadcrumb ./cmd/crn-breadcrumb/ 2>/dev/null) || true
        fi

        if [ -f "$BREADCRUMB_HELPER" ]; then
            log "Fetching enriched breadcrumb message from cranium..."
            RESUME_MSG=$(CRANIUM_SOCKET="$SOCKET_PATH" "$BREADCRUMB_HELPER" "$NOTIFY_ROOM" 2>/dev/null || true)
        fi
    fi

    # Fall back to default message if enrichment fails
    if [ -z "$RESUME_MSG" ]; then
        log "Using default breadcrumb message (enrichment unavailable)"
        RESUME_MSG="<system-reminder>IMPORTANT: Cranium was restarted. The world may have changed while you were away — tasks you initiated (including ko-agent pipelines) may have completed. Before continuing, reorient: check whether your in-flight work already landed. Do not assume the state is the same as when you last acted.</system-reminder>"
    else
        log "Using enriched breadcrumb message with recent room context"
    fi

    printf '%s\n%s\n' "$NOTIFY_ROOM" "$RESUME_MSG" > "$RESUME_FILE"
    log "Wrote resume breadcrumb to $RESUME_FILE"
fi

# 5. Send SIGUSR1 for graceful drain
log "Sending SIGUSR1 to PID $PID (graceful drain)..."
kill -USR1 "$PID"
log "Drain initiated — this process may be killed by the bridge shutting down"

# 6. Wait for drain (best-effort — we may get killed before this completes)
TIMEOUT=45
ELAPSED=0
while kill -0 "$PID" 2>/dev/null; do
    sleep 1
    ELAPSED=$((ELAPSED + 1))
    if [ $ELAPSED -ge $TIMEOUT ]; then
        log "Drain timeout — sending SIGTERM"
        kill -TERM "$PID" 2>/dev/null || true
        sleep 2
        break
    fi
done
log "Old process exited after ${ELAPSED}s"
