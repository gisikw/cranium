package main

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"maunium.net/go/mautrix/id"
)

// --- Integration tests: generateHandoff via mock ---
// Spec: session_lifecycle.feature

func TestGenerateHandoff_WritesFile(t *testing.T) {
	b, mc, mci := newTestBridge(t)
	ctx := context.Background()
	roomID := id.RoomID("!test:example.com")
	mc.roomNames[roomID] = "test-room"

	mci.QueueResponse(
		claudeResultMsg("sess-handoff", "# Handoff\n\nWe were working on X.", 200000),
	)

	err := b.generateHandoff(ctx, roomID, "sess-handoff")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Check that a handoff file was written
	handoffDir := filepath.Join(b.dataDir, "handoffs", "test-room")
	entries, err := os.ReadDir(handoffDir)
	if err != nil {
		t.Fatalf("handoff dir not created: %v", err)
	}
	if len(entries) != 1 {
		t.Fatalf("expected 1 handoff file, got %d", len(entries))
	}

	data, err := os.ReadFile(filepath.Join(handoffDir, entries[0].Name()))
	if err != nil {
		t.Fatalf("failed to read handoff file: %v", err)
	}
	if !contains(string(data), "We were working on X") {
		t.Errorf("handoff file missing expected content, got: %s", string(data))
	}
}

func TestGenerateHandoff_EmptyResultErrors(t *testing.T) {
	b, mc, mci := newTestBridge(t)
	ctx := context.Background()
	roomID := id.RoomID("!test:example.com")
	mc.roomNames[roomID] = "test-room"

	// Queue a result with empty text
	mci.QueueResponse(
		claudeResultMsg("sess-handoff", "", 200000),
	)

	err := b.generateHandoff(ctx, roomID, "sess-handoff")
	if err == nil {
		t.Fatal("expected error for empty handoff result")
	}
	if !contains(err.Error(), "empty result") {
		t.Errorf("expected 'empty result' in error, got: %v", err)
	}
}

func TestGenerateHandoff_ArgsCorrect(t *testing.T) {
	b, mc, mci := newTestBridge(t)
	ctx := context.Background()
	roomID := id.RoomID("!test:example.com")
	mc.roomNames[roomID] = "test-room"

	mci.QueueResponse(
		claudeResultMsg("sess-ho", "Handoff content", 200000),
	)

	_ = b.generateHandoff(ctx, roomID, "sess-ho")

	inv := mci.getInvocations()[0]
	// Should have --resume, --no-session-persistence, --tools ""
	if !containsStr(inv.Args, "--resume") {
		t.Error("expected --resume in handoff args")
	}
	if !containsStr(inv.Args, "--no-session-persistence") {
		t.Error("expected --no-session-persistence in handoff args")
	}
	// Env should be nil for handoff
	if len(inv.Env) != 0 {
		t.Errorf("expected no env vars for handoff, got %v", inv.Env)
	}
}
