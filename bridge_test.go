package main

import (
	"context"
	"testing"
	"time"

	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
)

// --- slugify ---
// Spec: session_lifecycle.feature - handoff storage uses slugified room names

func TestSlugify(t *testing.T) {
	tests := []struct {
		input    string
		expected string
	}{
		{"general", "general"},
		{"My Cool Room", "my-cool-room"},
		{"project-website", "project-website"},
		{"ops", "ops"},
		{"Room With  Multiple   Spaces", "room-with-multiple-spaces"},
		{"CamelCaseRoom", "camelcaseroom"},
		{"room!@#$%special", "room-special"},
		{"  leading-trailing  ", "leading-trailing"},
		{"123-numeric", "123-numeric"},
	}
	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			got := slugify(tt.input)
			if got != tt.expected {
				t.Errorf("slugify(%q) = %q, want %q", tt.input, got, tt.expected)
			}
		})
	}
}

// --- isExcludedRoomName ---
// Spec: message_routing.feature - "Messages in the ops room are ignored",
//   "Messages in project rooms are ignored",
//   "Messages in rooms without a name are not excluded"

func TestIsExcludedRoomName(t *testing.T) {
	defaultExcludes := []string{"ops", "project-"}
	tests := []struct {
		name     string
		excluded bool
	}{
		{"ops", true},
		{"project-website", true},
		{"project-", true},
		{"project-foo-bar", true},
		{"general", false},
		{"", false},
		{"operations", false},
		{"my-project", false},
		{"OPS", false}, // case-sensitive
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := isExcludedRoomName(tt.name, defaultExcludes)
			if got != tt.excluded {
				t.Errorf("isExcludedRoomName(%q) = %v, want %v", tt.name, got, tt.excluded)
			}
		})
	}
}

// --- parseCommand ---
// Spec: message_routing.feature - command dispatch,
//   session_lifecycle.feature - "!clear", "!new"

func TestParseCommand(t *testing.T) {
	tests := []struct {
		message string
		cmd     string
		args    string
		isCmd   bool
	}{
		{"!clear", "clear", "", true},
		{"/clear", "clear", "", true},
		{"!new my-room", "new", "my-room", true},
		{"/new my-room", "new", "my-room", true},
		{"!new   spaced-room  ", "new", "spaced-room", true},
		{"!new", "new", "", true},
		{"hello", "", "", false},
		{"!clearfoo", "", "", false},       // not a prefix match — must be exact or followed by space
		{"!clearing things", "", "", false}, // "clearing" is not "clear"
		{"/newfoo", "", "", false},
		{"clear", "", "", false},  // no prefix
		{"!Clear", "", "", false}, // case-sensitive
	}
	for _, tt := range tests {
		t.Run(tt.message, func(t *testing.T) {
			cmd, args, isCmd := parseCommand(tt.message)
			if cmd != tt.cmd || args != tt.args || isCmd != tt.isCmd {
				t.Errorf("parseCommand(%q) = (%q, %q, %v), want (%q, %q, %v)",
					tt.message, cmd, args, isCmd, tt.cmd, tt.args, tt.isCmd)
			}
		})
	}
}

// --- formatImagePrompt ---
// Spec: message_routing.feature - "An image message is saved and described to Claude"

func TestFormatImagePrompt(t *testing.T) {
	tests := []struct {
		name     string
		path     string
		caption  string
		expected string
	}{
		{
			"with caption",
			"notes/attachments/2026-02-12_img.png",
			"check this out",
			"[Image attached: notes/attachments/2026-02-12_img.png]\n\ncheck this out",
		},
		{
			"without caption",
			"notes/attachments/2026-02-12_img.png",
			"",
			"[Image attached: notes/attachments/2026-02-12_img.png]",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := formatImagePrompt(tt.path, tt.caption)
			if got != tt.expected {
				t.Errorf("formatImagePrompt(%q, %q) = %q, want %q", tt.path, tt.caption, got, tt.expected)
			}
		})
	}
}

// --- formatAudioPrompt ---
// Spec: message_routing.feature - "An audio message is transcribed and forwarded to Claude"

func TestFormatAudioPrompt(t *testing.T) {
	tests := []struct {
		name          string
		transcription string
		caption       string
		expected      string
	}{
		{
			"transcription only",
			"Hello, this is a voice message",
			"",
			"[Transcribed from audio]\n\nHello, this is a voice message",
		},
		{
			"with caption",
			"Hello, this is a voice message",
			"important note",
			"[Transcribed from audio]\n\nHello, this is a voice message\n\nimportant note",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := formatAudioPrompt(tt.transcription, tt.caption)
			if got != tt.expected {
				t.Errorf("formatAudioPrompt(%q, %q) = %q, want %q", tt.transcription, tt.caption, got, tt.expected)
			}
		})
	}
}

// --- formatTranscriptEcho ---
// Spec: message_routing.feature - "An audio transcription is echoed as a blockquote before agent dispatch"

func TestFormatTranscriptEcho(t *testing.T) {
	tests := []struct {
		name          string
		transcription string
		expected      string
	}{
		{
			"single line",
			"Hello from voice",
			"> Hello from voice",
		},
		{
			"multi line",
			"First line\nSecond line\nThird line",
			"> First line\n> Second line\n> Third line",
		},
		{
			// Caller guards against empty input; function returns "> " for empty string
			"empty string",
			"",
			"> ",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := formatTranscriptEcho(tt.transcription)
			if got != tt.expected {
				t.Errorf("formatTranscriptEcho(%q) = %q, want %q", tt.transcription, got, tt.expected)
			}
		})
	}
}

// --- isSupportedMessageType ---
// Spec: message_routing.feature - "Non-text, non-image, non-audio message types are dropped"

func TestIsSupportedMessageType(t *testing.T) {
	tests := []struct {
		msgType   event.MessageType
		supported bool
	}{
		{event.MsgText, true},
		{event.MsgImage, true},
		{event.MsgAudio, true},
		{event.MsgVideo, false},
		{event.MsgFile, false},
		{event.MsgNotice, false},
		{event.MsgEmote, false},
	}
	for _, tt := range tests {
		t.Run(string(tt.msgType), func(t *testing.T) {
			got := isSupportedMessageType(tt.msgType)
			if got != tt.supported {
				t.Errorf("isSupportedMessageType(%q) = %v, want %v", tt.msgType, got, tt.supported)
			}
		})
	}
}

// --- isMessageAfterStartup ---
// Spec: message_routing.feature - "Messages from before bridge startup are discarded"

func TestIsMessageAfterStartup(t *testing.T) {
	startup := time.Date(2026, 2, 12, 10, 0, 0, 0, time.UTC)
	tests := []struct {
		name    string
		msgTime time.Time
		want    bool
	}{
		{"before startup", startup.Add(-1 * time.Second), false},
		{"at startup", startup, true},
		{"after startup", startup.Add(1 * time.Second), true},
		{"well after startup", startup.Add(1 * time.Hour), true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := isMessageAfterStartup(tt.msgTime, startup)
			if got != tt.want {
				t.Errorf("isMessageAfterStartup(%v, %v) = %v, want %v", tt.msgTime, startup, got, tt.want)
			}
		})
	}
}

// --- Integration tests: findRoomByName ---
// Spec: implicit (used by ops room lookup at startup)

func TestBridge_FindRoomByName(t *testing.T) {
	b, mc, _ := newTestBridge(t)
	ctx := context.Background()

	opsRoom := id.RoomID("!ops:example.com")
	generalRoom := id.RoomID("!general:example.com")

	mc.joinedRooms = []id.RoomID{opsRoom, generalRoom}
	mc.roomNames[opsRoom] = "ops"
	mc.roomNames[generalRoom] = "general"

	found := b.findRoomByName(ctx, "ops")
	if found != opsRoom {
		t.Errorf("findRoomByName('ops') = %q, want %q", found, opsRoom)
	}

	found = b.findRoomByName(ctx, "nonexistent")
	if found != "" {
		t.Errorf("findRoomByName('nonexistent') = %q, want empty", found)
	}
}

// --- Integration tests: announceStartup ---
// Spec: upgrade_drain.feature — "Bridge announces startup in ops"

func TestBridge_AnnounceStartup(t *testing.T) {
	b, mc, _ := newTestBridge(t)
	ctx := context.Background()

	b.opsRoomID = id.RoomID("!ops:example.com")
	b.announceStartup(ctx)

	msgs := mc.getMessages()
	if len(msgs) != 1 {
		t.Fatalf("expected 1 startup message, got %d", len(msgs))
	}
	if msgs[0].RoomID != b.opsRoomID {
		t.Errorf("startup message sent to %q, want ops room", msgs[0].RoomID)
	}
	if !contains(msgs[0].Body, "online") {
		t.Errorf("startup message = %q, want it to contain 'online'", msgs[0].Body)
	}
}

func TestBridge_AnnounceStartup_NoOpsRoom(t *testing.T) {
	b, mc, _ := newTestBridge(t)
	ctx := context.Background()

	b.opsRoomID = "" // no ops room
	b.announceStartup(ctx)

	msgs := mc.getMessages()
	if len(msgs) != 0 {
		t.Errorf("expected no messages when ops room is unset, got %d", len(msgs))
	}
}

// --- Integration tests: announceDrain ---
// Spec: upgrade_drain.feature — "SIGUSR1 initiates graceful drain"

func TestBridge_AnnounceDrain(t *testing.T) {
	b, mc, _ := newTestBridge(t)
	ctx := context.Background()

	b.opsRoomID = id.RoomID("!ops:example.com")
	b.announceDrain(ctx)

	msgs := mc.getMessages()
	if len(msgs) != 1 {
		t.Fatalf("expected 1 drain message, got %d", len(msgs))
	}
	if !contains(msgs[0].Body, "upgrading") {
		t.Errorf("drain message = %q, want it to contain 'upgrading'", msgs[0].Body)
	}
}

func TestBridge_AnnounceDrain_NoOpsRoom(t *testing.T) {
	b, mc, _ := newTestBridge(t)
	ctx := context.Background()

	// No ops room configured
	b.opsRoomID = ""
	b.announceDrain(ctx)

	msgs := mc.getMessages()
	if len(msgs) != 0 {
		t.Errorf("expected no messages when ops room is empty, got %d", len(msgs))
	}
}

// --- Integration tests: activeRoomCount ---
// Spec: upgrade_drain.feature — drain completion logic

func TestBridge_ActiveRoomCount(t *testing.T) {
	b, _, _ := newTestBridge(t)

	if got := b.activeRoomCount(); got != 0 {
		t.Errorf("initial count = %d, want 0", got)
	}

	b.activeRooms.Store(id.RoomID("!a:example.com"), true)
	b.activeRooms.Store(id.RoomID("!b:example.com"), true)

	if got := b.activeRoomCount(); got != 2 {
		t.Errorf("after adding 2 rooms, count = %d, want 2", got)
	}

	b.activeRooms.Delete(id.RoomID("!a:example.com"))
	if got := b.activeRoomCount(); got != 1 {
		t.Errorf("after removing 1 room, count = %d, want 1", got)
	}
}

// --- Integration tests: draining ---
// Spec: upgrade_drain.feature — "SIGUSR1 initiates graceful drain"

func TestBridge_DrainingPreventsNewMessages(t *testing.T) {
	b, mc, _ := newTestBridge(t)
	ctx := context.Background()
	roomID := id.RoomID("!test:example.com")

	b.draining.Store(true)
	evt := makeEvent("@alice:example.com", roomID, "hello", b.startTime.Add(1*time.Minute))
	b.handleMessage(ctx, evt)

	msgs := mc.getMessages()
	if len(msgs) != 0 {
		t.Errorf("expected no messages while draining, got %d", len(msgs))
	}
}

// --- Integration tests: drain completion ---
// Spec: upgrade_drain.feature — "Drain completes when active invocations finish"

func TestBridge_DrainCompletesWhenRoomsDropToOne(t *testing.T) {
	// Simulates the drain polling loop: with 2 active rooms, drain waits.
	// When one finishes, remaining=1 (the upgrade initiator), drain considers complete.
	b, _, _ := newTestBridge(t)

	// Simulate 2 active rooms
	b.activeRooms.Store(id.RoomID("!infra:example.com"), true)
	b.activeRooms.Store(id.RoomID("!general:example.com"), true)

	if got := b.activeRoomCount(); got != 2 {
		t.Fatalf("expected 2 active rooms, got %d", got)
	}

	// Drain should NOT consider this complete (remaining > 1)
	if b.activeRoomCount() <= 1 {
		t.Fatal("drain should not complete with 2 active rooms")
	}

	// One invocation finishes
	b.activeRooms.Delete(id.RoomID("!infra:example.com"))

	// Now remaining=1 — drain considers complete (1 = upgrade initiator)
	if got := b.activeRoomCount(); got != 1 {
		t.Fatalf("expected 1 remaining room, got %d", got)
	}
	if b.activeRoomCount() > 1 {
		t.Error("drain should consider complete when remaining <= 1")
	}
}

func TestBridge_DrainCompletesWhenAllRoomsFinish(t *testing.T) {
	b, _, _ := newTestBridge(t)

	b.activeRooms.Store(id.RoomID("!only:example.com"), true)
	b.activeRooms.Delete(id.RoomID("!only:example.com"))

	if got := b.activeRoomCount(); got != 0 {
		t.Fatalf("expected 0 remaining rooms, got %d", got)
	}
}

func TestBridge_ActiveRoomTracking_ThroughInvocation(t *testing.T) {
	// Verifies that handleMessage correctly registers and deregisters active rooms
	b, _, mci := newTestBridge(t)
	ctx := context.Background()
	roomID := id.RoomID("!test:example.com")

	mci.QueueResponse(
		claudeAssistantMsg("sess-drain", "Done!"),
		claudeResultMsg("sess-drain", "Done!", 200000),
	)

	// Before invocation: room not active
	if _, active := b.activeRooms.Load(roomID); active {
		t.Fatal("room should not be active before invocation")
	}

	evt := makeEvent("@alice:example.com", roomID, "test", b.startTime.Add(1*time.Minute))
	b.handleMessage(ctx, evt)

	// After invocation completes: room no longer active (handleMessage is synchronous
	// except for the goroutine — but the active room tracking uses LoadOrStore and
	// defers Delete, so after handleMessage returns, the room is cleaned up)
	// Give a moment for the goroutine to finish
	time.Sleep(100 * time.Millisecond)

	if _, active := b.activeRooms.Load(roomID); active {
		t.Error("room should not be active after invocation completes")
	}
}

func TestBridge_DrainMode_SetsAtomicFlag(t *testing.T) {
	b, _, _ := newTestBridge(t)

	if b.draining.Load() {
		t.Fatal("bridge should not be draining initially")
	}

	b.draining.Store(true)

	if !b.draining.Load() {
		t.Fatal("bridge should be draining after Store(true)")
	}
}
