package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"maunium.net/go/mautrix/id"
)

// --- SessionStore ---
// Spec: session_lifecycle.feature - "Session data persists across bridge restarts",
//   "Session store migrates old format transparently"

// settleAsync lets background goroutines from SessionStore.save() complete
// before the test's TempDir cleanup runs.
func settleAsync() { time.Sleep(50 * time.Millisecond) }

func TestSessionStore_BasicOperations(t *testing.T) {
	tmp := t.TempDir()
	path := filepath.Join(tmp, "sessions.json")
	store := NewSessionStore(path, time.Now)
	defer settleAsync()

	roomID := id.RoomID("!test:example.com")

	// Initially empty
	if _, ok := store.Get(roomID); ok {
		t.Error("expected no session for new room")
	}

	// Set and get
	store.Set(roomID, "sess-123")
	if sid, ok := store.Get(roomID); !ok || sid != "sess-123" {
		t.Errorf("Get() = %q, %v, want %q, true", sid, ok, "sess-123")
	}

	// Reverse lookup
	if rid, ok := store.GetRoomBySession("sess-123"); !ok || rid != roomID {
		t.Errorf("GetRoomBySession() = %v, %v, want %v, true", rid, ok, roomID)
	}
	if _, ok := store.GetRoomBySession("nonexistent"); ok {
		t.Error("expected no room for nonexistent session")
	}
}

func TestSessionStore_LastMessage(t *testing.T) {
	tmp := t.TempDir()
	path := filepath.Join(tmp, "sessions.json")
	store := NewSessionStore(path, time.Now)
	defer settleAsync()

	roomID := id.RoomID("!test:example.com")

	// Initially empty
	if _, _, ok := store.GetLastMessage(roomID); ok {
		t.Error("expected no last message for new room")
	}

	// Set and get
	store.SetLastMessage(roomID, "evt-001", "hello world")
	eid, msg, ok := store.GetLastMessage(roomID)
	if !ok || eid != "evt-001" || msg != "hello world" {
		t.Errorf("GetLastMessage() = %q, %q, %v", eid, msg, ok)
	}

	// Clear
	store.ClearLastMessage(roomID)
	if _, _, ok := store.GetLastMessage(roomID); ok {
		t.Error("expected no last message after clear")
	}
}

func TestSessionStore_Invocation(t *testing.T) {
	tmp := t.TempDir()
	path := filepath.Join(tmp, "sessions.json")
	store := NewSessionStore(path, time.Now)
	defer settleAsync()

	// Mark invoked
	store.MarkInvoked("sess-123")

	// Recently invoked
	if !store.IsRecentlyInvoked("sess-123", 1*time.Minute) {
		t.Error("expected recently invoked")
	}
	if store.IsRecentlyInvoked("sess-123", 0) {
		t.Error("expected not recently invoked with zero timeout")
	}
	if store.IsRecentlyInvoked("nonexistent", 1*time.Minute) {
		t.Error("expected not recently invoked for unknown session")
	}

	// Time since last invoked
	dur, ok := store.TimeSinceLastInvoked("sess-123")
	if !ok || dur > 1*time.Second {
		t.Errorf("TimeSinceLastInvoked() = %v, %v", dur, ok)
	}
	if _, ok := store.TimeSinceLastInvoked("nonexistent"); ok {
		t.Error("expected false for unknown session")
	}
}

func TestSessionStore_Saturation(t *testing.T) {
	tmp := t.TempDir()
	path := filepath.Join(tmp, "sessions.json")
	store := NewSessionStore(path, time.Now)

	roomID := id.RoomID("!test:example.com")

	// Defaults to 0
	if got := store.GetLastSaturation(roomID); got != 0 {
		t.Errorf("expected 0, got %d", got)
	}

	store.SetLastSaturation(roomID, 65)
	if got := store.GetLastSaturation(roomID); got != 65 {
		t.Errorf("expected 65, got %d", got)
	}

	// Reminder threshold
	if got := store.GetLastReminderAt(roomID); got != 0 {
		t.Errorf("expected 0, got %d", got)
	}
	store.SetLastReminderAt(roomID, 60)
	if got := store.GetLastReminderAt(roomID); got != 60 {
		t.Errorf("expected 60, got %d", got)
	}
}

func TestSessionStore_Turns(t *testing.T) {
	tmp := t.TempDir()
	path := filepath.Join(tmp, "sessions.json")
	store := NewSessionStore(path, time.Now)

	roomID := id.RoomID("!test:example.com")

	// Starts at 0
	if got := store.GetTurns(roomID); got != 0 {
		t.Errorf("expected 0 turns, got %d", got)
	}

	// Increment returns new value
	for i := 1; i <= 10; i++ {
		got := store.IncrementTurns(roomID)
		if got != i {
			t.Errorf("IncrementTurns() = %d, want %d", got, i)
		}
	}

	// Reset
	store.ResetTurns(roomID)
	if got := store.GetTurns(roomID); got != 0 {
		t.Errorf("expected 0 after reset, got %d", got)
	}
}

func TestSessionStore_PinnedEvent(t *testing.T) {
	tmp := t.TempDir()
	path := filepath.Join(tmp, "sessions.json")
	store := NewSessionStore(path, time.Now)
	defer settleAsync()

	roomID := id.RoomID("!test:example.com")

	// Initially no pin
	if _, ok := store.GetPinnedEvent(roomID); ok {
		t.Error("expected no pinned event")
	}

	store.SetPinnedEvent(roomID, "$pin-123")
	if eid, ok := store.GetPinnedEvent(roomID); !ok || eid != "$pin-123" {
		t.Errorf("GetPinnedEvent() = %q, %v", eid, ok)
	}

	// Clear also clears saturation and reminder state
	store.SetLastSaturation(roomID, 70)
	store.SetLastReminderAt(roomID, 65)
	store.ClearPinnedEvent(roomID)

	if _, ok := store.GetPinnedEvent(roomID); ok {
		t.Error("expected no pinned event after clear")
	}
	if got := store.GetLastSaturation(roomID); got != 0 {
		t.Errorf("expected saturation cleared, got %d", got)
	}
	if got := store.GetLastReminderAt(roomID); got != 0 {
		t.Errorf("expected reminder cleared, got %d", got)
	}
}

func TestSessionStore_Persistence(t *testing.T) {
	tmp := t.TempDir()
	path := filepath.Join(tmp, "sessions.json")

	// Create store and set data
	store := NewSessionStore(path, time.Now)
	roomID := id.RoomID("!test:example.com")
	store.Set(roomID, "sess-456")
	store.SetLastMessage(roomID, "evt-789", "test message")
	store.SetPinnedEvent(roomID, "$pin-001")
	store.MarkInvoked("sess-456")

	// Give async save a moment
	time.Sleep(100 * time.Millisecond)

	// Load fresh store from same file
	store2 := NewSessionStore(path, time.Now)
	if sid, ok := store2.Get(roomID); !ok || sid != "sess-456" {
		t.Errorf("persisted session = %q, %v, want %q", sid, ok, "sess-456")
	}
	if eid, msg, ok := store2.GetLastMessage(roomID); !ok || eid != "evt-789" || msg != "test message" {
		t.Errorf("persisted last message = %q, %q, %v", eid, msg, ok)
	}
	if pid, ok := store2.GetPinnedEvent(roomID); !ok || pid != "$pin-001" {
		t.Errorf("persisted pinned event = %q, %v", pid, ok)
	}
}

func TestSessionStore_OldFormatMigration(t *testing.T) {
	tmp := t.TempDir()
	path := filepath.Join(tmp, "sessions.json")

	// Write old format (plain map of room -> session_id)
	oldData := map[string]string{
		"!room1:example.com": "sess-old-1",
		"!room2:example.com": "sess-old-2",
	}
	data, _ := json.Marshal(oldData)
	os.WriteFile(path, data, 0600)

	store := NewSessionStore(path, time.Now)
	if sid, ok := store.Get("!room1:example.com"); !ok || sid != "sess-old-1" {
		t.Errorf("old format migration: got %q, %v", sid, ok)
	}
	if sid, ok := store.Get("!room2:example.com"); !ok || sid != "sess-old-2" {
		t.Errorf("old format migration: got %q, %v", sid, ok)
	}
}

func TestSessionStore_InterruptedContext(t *testing.T) {
	tmp := t.TempDir()
	path := filepath.Join(tmp, "sessions.json")
	store := NewSessionStore(path, time.Now)
	defer settleAsync()

	roomID := id.RoomID("!test:example.com")

	// Initially empty
	if _, ok := store.GetInterruptedContext(roomID); ok {
		t.Error("expected no interrupted context for new room")
	}

	// Set and get interrupted context
	testContext := "Some partial output\n\n> **Read** file.txt\n\nMore text..."
	store.SetInterruptedContext(roomID, testContext)
	if ctx, ok := store.GetInterruptedContext(roomID); !ok || ctx != testContext {
		t.Errorf("GetInterruptedContext() = %q, %v, want %q, true", ctx, ok, testContext)
	}

	// Clear
	store.ClearInterruptedContext(roomID)
	if _, ok := store.GetInterruptedContext(roomID); ok {
		t.Error("expected no interrupted context after clear")
	}
}

func TestSessionStore_InterruptedContextPersistsAcrossReload(t *testing.T) {
	tmp := t.TempDir()
	path := filepath.Join(tmp, "sessions.json")

	// Create store, set interrupted context
	store := NewSessionStore(path, time.Now)
	roomID := id.RoomID("!test:example.com")
	testContext := "Partial output from interrupted turn"
	store.Set(roomID, "sess-123") // need a session for persistence
	store.SetInterruptedContext(roomID, testContext)
	settleAsync() // Let async save complete

	// Reload from disk
	store2 := NewSessionStore(path, time.Now)
	defer settleAsync()
	if ctx, ok := store2.GetInterruptedContext(roomID); !ok || ctx != testContext {
		t.Errorf("after reload: GetInterruptedContext() = %q, %v, want %q, true", ctx, ok, testContext)
	}
}

func TestSessionStore_SystemPromptFile(t *testing.T) {
	store := NewSessionStore(filepath.Join(t.TempDir(), "sessions.json"), time.Now)
	store.syncSave = true
	roomID := id.RoomID("!test:example.com")

	// Initially empty
	if _, ok := store.GetSystemPromptFile(roomID); ok {
		t.Error("expected no system prompt file initially")
	}

	// Set and get
	store.SetSystemPromptFile(roomID, "/data/system-prompts/test_2025-01-01.md")
	path, ok := store.GetSystemPromptFile(roomID)
	if !ok || path != "/data/system-prompts/test_2025-01-01.md" {
		t.Errorf("GetSystemPromptFile() = %q, %v, want path and true", path, ok)
	}

	// Clear
	store.ClearSystemPromptFile(roomID)
	if _, ok := store.GetSystemPromptFile(roomID); ok {
		t.Error("expected no system prompt file after clear")
	}
}

func TestSessionStore_SystemPromptFilePersistsAcrossReload(t *testing.T) {
	tmp := t.TempDir()
	path := filepath.Join(tmp, "sessions.json")
	testPath := "/data/system-prompts/cranium_2025-01-01.md"

	store := NewSessionStore(path, time.Now)
	store.syncSave = true
	roomID := id.RoomID("!test:example.com")
	store.Set(roomID, "sess-123")
	store.SetSystemPromptFile(roomID, testPath)

	// Reload from disk
	store2 := NewSessionStore(path, time.Now)
	if got, ok := store2.GetSystemPromptFile(roomID); !ok || got != testPath {
		t.Errorf("after reload: GetSystemPromptFile() = %q, %v, want %q, true", got, ok, testPath)
	}
}
