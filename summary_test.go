package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"maunium.net/go/mautrix/id"
)

// --- shouldGenerateSummary ---
// Spec: cross_room_awareness.feature - "Summary is generated after 10 turns",
//   "Summary is not generated before 10 turns"

func TestShouldGenerateSummary(t *testing.T) {
	tests := []struct {
		turns     int
		threshold int
		want      bool
	}{
		{9, 10, false},
		{10, 10, true},
		{11, 10, true},
		{0, 10, false},
		{5, 5, true},
	}
	for _, tt := range tests {
		t.Run(fmt.Sprintf("turns=%d_threshold=%d", tt.turns, tt.threshold), func(t *testing.T) {
			got := shouldGenerateSummary(tt.turns, tt.threshold)
			if got != tt.want {
				t.Errorf("shouldGenerateSummary(%d, %d) = %v, want %v", tt.turns, tt.threshold, got, tt.want)
			}
		})
	}
}

// --- detectCompaction ---
// Spec: context_saturation.feature - "Context compaction is detected and announced"

func TestDetectCompaction(t *testing.T) {
	tests := []struct {
		name           string
		prevSaturation int
		saturation     int
		hasPinned      bool
		want           bool
	}{
		{"large drop with pin — compaction", 72, 40, true, true},
		{"large drop without pin — no compaction", 72, 40, false, false},
		{"small drop with pin — no compaction (hysteresis)", 60, 59, true, false},
		{"at 60 with pin — no compaction", 65, 60, true, false},
		{"above 60 with pin — no compaction", 80, 75, true, false},
		{"exactly 10 point drop below 60 — no compaction (boundary)", 69, 59, true, false},
		{"11 point drop below 60 — compaction", 70, 59, true, true},
		{"drop to 0 from high — compaction", 85, 20, true, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := detectCompaction(tt.prevSaturation, tt.saturation, tt.hasPinned)
			if got != tt.want {
				t.Errorf("detectCompaction(%d, %d, %v) = %v, want %v", tt.prevSaturation, tt.saturation, tt.hasPinned, got, tt.want)
			}
		})
	}
}

// --- filterAndFormatSummaries ---
// Spec: cross_room_awareness.feature

func TestFilterAndFormatSummaries(t *testing.T) {
	now := time.Date(2026, 2, 12, 15, 0, 0, 0, time.UTC)
	summaries := []RoomSummary{
		{RoomID: "!infra:example.com", RoomName: "infra", Summary: "Debugging deploy", LastMessageTS: now.Add(-1 * time.Hour).Unix()},
		{RoomID: "!personal:example.com", RoomName: "personal", Summary: "Weekend plans", LastMessageTS: now.Add(-30 * time.Minute).Unix()},
		{RoomID: "!stale:example.com", RoomName: "stale", Summary: "Old stuff", LastMessageTS: now.Add(-25 * time.Hour).Unix()},
		{RoomID: "!current:example.com", RoomName: "current", Summary: "Current room", LastMessageTS: now.Add(-5 * time.Minute).Unix()},
	}

	// Exclude current room
	got := filterAndFormatSummaries(summaries, "!current:example.com", 0, now)
	if contains(got, "current") {
		t.Error("should exclude current room")
	}
	if !contains(got, "infra") || !contains(got, "personal") || !contains(got, "stale") {
		t.Errorf("should include other rooms: %q", got)
	}

	// With maxAge filter
	got = filterAndFormatSummaries(summaries, "!current:example.com", 2*time.Hour, now)
	if !contains(got, "infra") || !contains(got, "personal") {
		t.Error("should include recent rooms")
	}
	if contains(got, "stale") {
		t.Error("should exclude stale room with maxAge filter")
	}

	// Empty summaries
	got = filterAndFormatSummaries(nil, "!any:room", 0, now)
	if got != "" {
		t.Errorf("empty summaries should return empty string, got %q", got)
	}

	// All excluded
	got = filterAndFormatSummaries(summaries[:1], "!infra:example.com", 0, now)
	if got != "" {
		t.Errorf("all excluded should return empty, got %q", got)
	}
}

// --- deriveSlug ---
// Spec: session_lifecycle.feature - handoff storage

func TestDeriveSlug(t *testing.T) {
	tests := []struct {
		name     string
		roomName string
		roomID   string
		expected string
	}{
		{"normal room", "general", "!abc:example.com", "general"},
		{"room with spaces", "My Cool Room", "!abc:example.com", "my-cool-room"},
		{"empty name uses room ID", "", "!abcdefghijklmnop:example.com", "abcdefghijklmnop"},
		{"empty name truncates long ID", "", "!abcdefghijklmnopqrstuvwxyz1234567890:example.com", "qrstuvwxyz1234567890"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := deriveSlug(tt.roomName, tt.roomID)
			if got != tt.expected {
				t.Errorf("deriveSlug(%q, %q) = %q, want %q", tt.roomName, tt.roomID, got, tt.expected)
			}
		})
	}
}

// --- Integration tests: generateSummary via mock ---
// Spec: cross_room_awareness.feature

func TestGenerateSummary_WritesSummaryFile(t *testing.T) {
	b, mc, mci := newTestBridge(t)
	ctx := context.Background()
	roomID := id.RoomID("!test:example.com")
	mc.roomNames[roomID] = "test-room"
	b.sessions.Set(roomID, "sess-sum")

	mci.QueueResponse(
		claudeResultMsg("sess-sum", "Working on bridge testing. Key decisions: use interface extraction pattern.", 200000),
	)

	b.generateSummary(ctx, roomID)

	// Check summary file was written
	summaryPath := filepath.Join(b.dataDir, "summaries", "test-room.json")
	data, err := os.ReadFile(summaryPath)
	if err != nil {
		t.Fatalf("summary file not created: %v", err)
	}

	var summary RoomSummary
	if err := json.Unmarshal(data, &summary); err != nil {
		t.Fatalf("failed to parse summary JSON: %v", err)
	}
	if !contains(summary.Summary, "bridge testing") {
		t.Errorf("summary missing expected content: %q", summary.Summary)
	}
	if summary.RoomName != "test-room" {
		t.Errorf("expected room name test-room, got %q", summary.RoomName)
	}
	if summary.TurnsSinceSummary != 0 {
		t.Errorf("expected turns since summary to be reset to 0, got %d", summary.TurnsSinceSummary)
	}
}

func TestGenerateSummary_ResetsTurns(t *testing.T) {
	b, mc, mci := newTestBridge(t)
	ctx := context.Background()
	roomID := id.RoomID("!test:example.com")
	mc.roomNames[roomID] = "test-room"
	b.sessions.Set(roomID, "sess-turns")
	b.sessions.IncrementTurns(roomID) // simulate some turns
	b.sessions.IncrementTurns(roomID)

	mci.QueueResponse(
		claudeResultMsg("sess-turns", "Summary text", 200000),
	)

	b.generateSummary(ctx, roomID)

	turns := b.sessions.GetTurns(roomID)
	if turns != 0 {
		t.Errorf("expected turns reset to 0, got %d", turns)
	}
}

func TestGenerateSummary_ForkSessionArgs(t *testing.T) {
	b, mc, mci := newTestBridge(t)
	ctx := context.Background()
	roomID := id.RoomID("!test:example.com")
	mc.roomNames[roomID] = "test-room"
	b.sessions.Set(roomID, "sess-fork")

	mci.QueueResponse(
		claudeResultMsg("sess-fork", "Summary", 200000),
	)

	b.generateSummary(ctx, roomID)

	inv := mci.getInvocations()[0]
	if !containsStr(inv.Args, "--fork-session") {
		t.Error("expected --fork-session in summary args")
	}
	if !containsStr(inv.Args, "--no-session-persistence") {
		t.Error("expected --no-session-persistence in summary args")
	}
	if !containsStr(inv.Args, "--resume") {
		t.Error("expected --resume in summary args")
	}
}

func TestGenerateSummary_NoSessionSkips(t *testing.T) {
	b, mc, _ := newTestBridge(t)
	ctx := context.Background()
	roomID := id.RoomID("!test:example.com")
	mc.roomNames[roomID] = "test-room"
	// Don't set session — should skip

	b.generateSummary(ctx, roomID)

	// No summary file should exist
	summaryPath := filepath.Join(b.dataDir, "summaries", "test-room.json")
	if _, err := os.Stat(summaryPath); err == nil {
		t.Error("summary file should not exist when no session is set")
	}
}
