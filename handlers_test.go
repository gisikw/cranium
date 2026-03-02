package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
)

// --- Integration tests: handleMessage basics ---
// Spec: message_routing.feature — dedup, self-ignore, draining, excluded rooms

func TestBridge_HandleMessage_IgnoresOwnMessages(t *testing.T) {
	b, mc, _ := newTestBridge(t)
	ctx := context.Background()
	roomID := id.RoomID("!test:example.com")

	// Send a message from self
	evt := makeEvent(b.userID, roomID, "my own message", b.startTime.Add(1*time.Minute))
	b.handleMessage(ctx, evt)

	// Should not send any response
	msgs := mc.getMessages()
	if len(msgs) != 0 {
		t.Errorf("expected no messages for own message, got %d", len(msgs))
	}
}

func TestBridge_HandleMessage_IgnoresOldMessages(t *testing.T) {
	b, mc, _ := newTestBridge(t)
	ctx := context.Background()
	roomID := id.RoomID("!test:example.com")

	// Message from before bridge start
	evt := makeEvent("@alice:example.com", roomID, "old message", b.startTime.Add(-1*time.Minute))
	b.handleMessage(ctx, evt)

	msgs := mc.getMessages()
	if len(msgs) != 0 {
		t.Errorf("expected no messages for old message, got %d", len(msgs))
	}
}

func TestBridge_HandleMessage_IgnoresDuplicateEvents(t *testing.T) {
	b, mc, _ := newTestBridge(t)
	ctx := context.Background()
	roomID := id.RoomID("!test:example.com")

	// Create event and mark as seen
	evt := makeEvent("@alice:example.com", roomID, "hello", b.startTime.Add(1*time.Minute))
	b.seenEvents.Store(evt.ID, b.now())

	b.handleMessage(ctx, evt)

	msgs := mc.getMessages()
	if len(msgs) != 0 {
		t.Errorf("expected no messages for duplicate event, got %d", len(msgs))
	}
}

func TestBridge_HandleMessage_IgnoresWhileDraining(t *testing.T) {
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

func TestBridge_HandleMessage_IgnoresExcludedRooms(t *testing.T) {
	b, mc, _ := newTestBridge(t)
	ctx := context.Background()
	roomID := id.RoomID("!ops:example.com")
	mc.roomNames[roomID] = "ops"

	evt := makeEvent("@alice:example.com", roomID, "hello", b.startTime.Add(1*time.Minute))
	b.handleMessage(ctx, evt)

	msgs := mc.getMessages()
	if len(msgs) != 0 {
		t.Errorf("expected no messages for excluded room, got %d", len(msgs))
	}
}

// --- Integration tests: !clear command ---
// Spec: session_lifecycle.feature — "!clear generates a handoff and resets the session"

func TestBridge_HandleMessage_ClearNoSession(t *testing.T) {
	b, mc, _ := newTestBridge(t)
	defer settleAsync()
	ctx := context.Background()
	roomID := id.RoomID("!test:example.com")

	evt := makeEvent("@alice:example.com", roomID, "!clear", b.startTime.Add(1*time.Minute))
	b.handleMessage(ctx, evt)

	// Wait for message to be processed
	time.Sleep(50 * time.Millisecond)

	msgs := mc.getMessages()
	// Should have sent a transient "Reloading..." notice (MsgNotice type)
	foundTransient := false
	for _, m := range msgs {
		if contains(m.Body, "Reloading") && m.MsgType == event.MsgNotice {
			foundTransient = true
			break
		}
	}
	if !foundTransient {
		t.Error("expected 'Reloading...' transient notice message")
	}

	// Should have redacted the transient message
	redactions := mc.getRedactions()
	if len(redactions) < 1 {
		t.Error("expected at least 1 redaction for transient message")
	}
}

func TestBridge_HandleMessage_ClearDuringActiveInvocation(t *testing.T) {
	b, mc, _ := newTestBridge(t)
	ctx := context.Background()
	roomID := id.RoomID("!test:example.com")

	// Simulate active invocation
	b.activeRooms.Store(roomID, true)

	evt := makeEvent("@alice:example.com", roomID, "!clear", b.startTime.Add(1*time.Minute))
	b.handleMessage(ctx, evt)
	time.Sleep(50 * time.Millisecond)

	msgs := mc.getMessages()
	found := false
	for _, m := range msgs {
		if contains(m.Body, "Can't clear") {
			found = true
		}
	}
	if !found {
		t.Error("expected rejection message when clearing during active invocation")
	}

	b.activeRooms.Delete(roomID)
}

// --- Integration tests: !new command ---
// Spec: session_lifecycle.feature — "!new creates a room and invites the sender"

func TestBridge_HandleMessage_NewRoom(t *testing.T) {
	b, mc, _ := newTestBridge(t)
	defer settleAsync()
	ctx := context.Background()
	roomID := id.RoomID("!test:example.com")

	evt := makeEvent("@alice:example.com", roomID, "!new test-room", b.startTime.Add(1*time.Minute))
	b.handleMessage(ctx, evt)
	time.Sleep(50 * time.Millisecond)

	if len(mc.createdRooms) != 1 || mc.createdRooms[0] != "test-room" {
		t.Errorf("expected room 'test-room' created, got %v", mc.createdRooms)
	}
}

func TestBridge_HandleMessage_NewRoomNoName(t *testing.T) {
	b, mc, _ := newTestBridge(t)
	ctx := context.Background()
	roomID := id.RoomID("!test:example.com")

	evt := makeEvent("@alice:example.com", roomID, "!new", b.startTime.Add(1*time.Minute))
	b.handleMessage(ctx, evt)
	time.Sleep(50 * time.Millisecond)

	msgs := mc.getMessages()
	found := false
	for _, m := range msgs {
		if contains(m.Body, "Usage") {
			found = true
		}
	}
	if !found {
		t.Error("expected usage message for !new without room name")
	}
	if len(mc.createdRooms) != 0 {
		t.Error("should not have created a room without a name")
	}
}

// --- Integration tests: typing indicators ---
// Spec: typing_indicators.feature

func TestBridge_TypingIndicator_ReadReceiptAndTypingFired(t *testing.T) {
	// Spec: "Read receipt is sent after approximately 800ms"
	// and "typing indicator starts after approximately 1000ms"
	//
	// The typing goroutine checks typingDone before each delay. Claude must
	// take longer than the typing delays for MarkRead and UserTyping(true) to fire.
	b, mc, mci := newTestBridge(t)
	b.typingReadDelay = 5 * time.Millisecond
	b.typingStartDelay = 5 * time.Millisecond
	ctx := context.Background()
	roomID := id.RoomID("!test:example.com")

	// Mock response delayed 50ms — goroutine's 10ms total delay fires well before
	mci.QueueDelayedResponse(50*time.Millisecond,
		claudeAssistantMsg("sess-typing", "Done!"),
		claudeResultMsg("sess-typing", "Done!", 200000),
	)

	evt := makeEvent("@alice:example.com", roomID, "test", b.startTime.Add(1*time.Minute))
	b.handleMessage(ctx, evt)

	// Brief settle time for goroutine to complete
	time.Sleep(50 * time.Millisecond)

	// Should have sent a read receipt
	mc.mu.Lock()
	receipts := make([]id.EventID, len(mc.readReceipts))
	copy(receipts, mc.readReceipts)
	mc.mu.Unlock()

	if len(receipts) < 1 {
		t.Error("expected at least 1 read receipt")
	}

	// Should have sent at least one typing=true call with 30s timeout
	calls := mc.getTypingCalls()
	foundTypingStart := false
	for _, c := range calls {
		if c.RoomID == roomID && c.Typing && c.Timeout == 30*time.Second {
			foundTypingStart = true
			break
		}
	}
	if !foundTypingStart {
		t.Errorf("expected UserTyping(true, 30s) call, got calls: %+v", calls)
	}
}

func TestBridge_TypingIndicator_CancelledOnResponse(t *testing.T) {
	// Spec: "Typing indicator is turned off" when Claude responds.
	// After handleMessage completes, a UserTyping(false) must have been sent.
	// There are actually two cancellation points:
	//   1. Inside invokeClaude's sendOrEdit (first message send)
	//   2. After invokeClaude returns in handleMessage
	b, mc, mci := newTestBridge(t)
	b.typingReadDelay = 0
	b.typingStartDelay = 0
	ctx := context.Background()
	roomID := id.RoomID("!test:example.com")

	mci.QueueResponse(
		claudeAssistantMsg("sess-cancel", "Quick response"),
		claudeResultMsg("sess-cancel", "Quick response", 200000),
	)

	evt := makeEvent("@alice:example.com", roomID, "hello", b.startTime.Add(1*time.Minute))
	b.handleMessage(ctx, evt)

	// Brief settle time for goroutine to complete
	time.Sleep(50 * time.Millisecond)

	calls := mc.getTypingCalls()

	// Must include at least one typing=false call for this room
	foundCancel := false
	for _, c := range calls {
		if c.RoomID == roomID && !c.Typing {
			foundCancel = true
			break
		}
	}
	if !foundCancel {
		t.Errorf("expected UserTyping(false) to cancel typing indicator, got calls: %+v", calls)
	}
}

func TestBridge_TypingIndicator_LastCallIsCancellation(t *testing.T) {
	// The final typing call for the room should always be typing=false,
	// regardless of the order things fire in.
	//
	// KNOWN BUG: When Claude responds faster than the 800ms+200ms typing
	// goroutine sleep, the goroutine sends UserTyping(true) *after* the
	// response and cancellation have already been sent. The goroutine
	// doesn't check typingDone before its initial typing call, so the
	// last observed call ends up being typing=true — a stale indicator
	// that briefly flashes after the response appears.
	//
	// This test documents the current (buggy) behavior. When fixed,
	// remove the Skip and the bug will be caught if it regresses.
	// Fixed: typing goroutine now checks typingDone before each sleep

	b, mc, mci := newTestBridge(t)
	b.typingReadDelay = 0
	b.typingStartDelay = 0
	ctx := context.Background()
	roomID := id.RoomID("!test:example.com")

	mci.QueueResponse(
		claudeAssistantMsg("sess-last", "Response"),
		claudeResultMsg("sess-last", "Response", 200000),
	)

	evt := makeEvent("@alice:example.com", roomID, "test", b.startTime.Add(1*time.Minute))
	b.handleMessage(ctx, evt)

	time.Sleep(50 * time.Millisecond)

	calls := mc.getTypingCalls()
	// Find the last typing call for this room
	var lastCall *typingCall
	for i := len(calls) - 1; i >= 0; i-- {
		if calls[i].RoomID == roomID {
			lastCall = &calls[i]
			break
		}
	}
	if lastCall == nil {
		t.Fatal("expected at least one typing call for room")
	}
	if lastCall.Typing {
		t.Error("last typing call should be false (cancellation), got true")
	}
}

func TestBridge_TypingIndicator_NotStartedForExcludedRoom(t *testing.T) {
	b, mc, _ := newTestBridge(t)
	ctx := context.Background()
	roomID := id.RoomID("!ops:example.com")
	mc.roomNames[roomID] = "ops"

	evt := makeEvent("@alice:example.com", roomID, "hello", b.startTime.Add(1*time.Minute))
	b.handleMessage(ctx, evt)

	time.Sleep(100 * time.Millisecond)

	calls := mc.getTypingCalls()
	if len(calls) != 0 {
		t.Errorf("expected no typing calls for excluded room, got %d", len(calls))
	}
}

func TestBridge_TypingIndicator_NotStartedWhileDraining(t *testing.T) {
	b, mc, _ := newTestBridge(t)
	ctx := context.Background()
	roomID := id.RoomID("!test:example.com")

	b.draining.Store(true)
	evt := makeEvent("@alice:example.com", roomID, "hello", b.startTime.Add(1*time.Minute))
	b.handleMessage(ctx, evt)

	time.Sleep(100 * time.Millisecond)

	calls := mc.getTypingCalls()
	if len(calls) != 0 {
		t.Errorf("expected no typing calls while draining, got %d", len(calls))
	}
}

// --- Integration tests: stop emoji ---

func TestBridge_StopEmoji_CancelsActiveInvocation(t *testing.T) {
	b, mc, mci := newTestBridge(t)
	b.typingReadDelay = 0
	b.typingStartDelay = 0
	ctx := context.Background()
	roomID := id.RoomID("!test:example.com")

	// Queue a delayed response — gives us time to send the stop reaction
	mci.QueueDelayedResponse(500*time.Millisecond,
		claudeAssistantMsg("sess-stop", "This should be interrupted"),
		claudeResultMsg("sess-stop", "This should be interrupted", 200000),
	)

	done := make(chan struct{})
	go func() {
		evt := makeEvent("@alice:example.com", roomID, "do something slow", b.startTime.Add(1*time.Minute))
		b.handleMessage(ctx, evt)
		close(done)
	}()

	// Wait for invocation to be active
	time.Sleep(50 * time.Millisecond)

	// Verify the room has an active invocation
	if _, active := b.activeRooms.Load(roomID); !active {
		t.Fatal("expected active invocation in room")
	}

	// Send stop emoji reaction
	reactionEvt := &event.Event{
		Sender: "@alice:example.com",
		RoomID: roomID,
		Type:   event.EventReaction,
	}
	reactionEvt.Content.Parsed = &event.ReactionEventContent{
		RelatesTo: event.RelatesTo{
			Type:    event.RelAnnotation,
			EventID: "$some-message",
			Key:     "\U0001f6d1", // 🛑
		},
	}
	b.handleReaction(ctx, reactionEvt)

	// handleMessage should return quickly after cancellation
	select {
	case <-done:
		// Good — invocation was cancelled
	case <-time.After(2 * time.Second):
		t.Fatal("handleMessage did not return after stop emoji — invocation was not cancelled")
	}

	// Should have sent "Stopped." confirmation
	msgs := mc.getMessages()
	foundStopped := false
	for _, m := range msgs {
		if contains(m.Body, "Stopped") {
			foundStopped = true
		}
	}
	if !foundStopped {
		t.Error("expected '*Stopped.*' confirmation message")
	}

	// Room should no longer be active
	if _, active := b.activeRooms.Load(roomID); active {
		t.Error("room should not be active after stop")
	}
}

func TestBridge_StopEmoji_NoActiveInvocation_FallsThrough(t *testing.T) {
	b, _, _ := newTestBridge(t)
	ctx := context.Background()
	roomID := id.RoomID("!test:example.com")

	// Set up a pending approval to verify fallthrough
	approvalEventID := id.EventID("$approval-stop-fallthrough")
	pending := &pendingApproval{
		eventID:  approvalEventID,
		roomID:   roomID,
		response: make(chan ApprovalResponse, 1),
	}
	b.pendingApprovals.Store(approvalEventID, pending)

	// No active invocation — stop emoji should fall through to approval handling
	reactionEvt := &event.Event{
		Sender: "@alice:example.com",
		RoomID: roomID,
		Type:   event.EventReaction,
	}
	reactionEvt.Content.Parsed = &event.ReactionEventContent{
		RelatesTo: event.RelatesTo{
			Type:    event.RelAnnotation,
			EventID: approvalEventID,
			Key:     "\U0001f6d1", // 🛑
		},
	}
	b.handleReaction(ctx, reactionEvt)

	select {
	case resp := <-pending.response:
		if resp.Decision != "deny" || resp.Message != "STOP" {
			t.Errorf("expected deny/STOP fallthrough, got %q/%q", resp.Decision, resp.Message)
		}
	case <-time.After(1 * time.Second):
		t.Fatal("timed out — stop emoji should have fallen through to approval handler")
	}
}

// --- Integration tests: audio transcript echo ---
// Spec: message_routing.feature - "An audio transcription is echoed as a threaded reply to the audio message before agent dispatch"

func TestBridge_HandleMessage_AudioEchoesTranscript(t *testing.T) {
	// Spin up a mock STT server returning a fixed transcription
	sttServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"text": "Hello from voice"}`)
	}))
	defer sttServer.Close()

	b, mc, mci := newTestBridge(t)
	b.sttURL = sttServer.URL

	mci.QueueResponse(
		claudeAssistantMsg("sess-stt", "Got it!"),
		claudeResultMsg("sess-stt", "Got it!", 200000),
	)

	ctx := context.Background()
	roomID := id.RoomID("!test:example.com")

	content := event.MessageEventContent{
		MsgType: event.MsgAudio,
		Body:    "voice.ogg",
		URL:     "mxc://matrix.example.com/fake-audio",
	}
	evt := &event.Event{
		Sender:    "@alice:example.com",
		RoomID:    roomID,
		ID:        "$audio-echo-test",
		Timestamp: b.startTime.Add(1 * time.Minute).UnixMilli(),
		Type:      event.EventMessage,
	}
	evt.Content.Parsed = &content

	b.handleMessage(ctx, evt)

	msgs := mc.getMessages()
	if len(msgs) < 2 {
		t.Fatalf("expected at least 2 messages (echo + Claude response), got %d", len(msgs))
	}

	// First message should be the transcript echo blockquote sent as a thread reply
	if !strings.HasPrefix(msgs[0].Body, "> ") {
		t.Errorf("first message should be transcript echo starting with '> ', got: %q", msgs[0].Body)
	}
	if !contains(msgs[0].Body, "Hello from voice") {
		t.Errorf("echo should contain transcription text, got: %q", msgs[0].Body)
	}
	if msgs[0].ThreadParent != evt.ID {
		t.Errorf("echo should be a threaded reply to the audio event %q, got ThreadParent=%q", evt.ID, msgs[0].ThreadParent)
	}
}

// --- Auto-TTS tests ---

func TestBridge_HandleMessage_AutoTTS_AudioPrefixRoom(t *testing.T) {
	// When the room name starts with "audio-", the agent's text reply
	// should be followed by a synthesized audio message.
	var ttsCalled bool
	var ttsText string
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ttsCalled = true
		var body map[string]string
		if err := json.NewDecoder(r.Body).Decode(&body); err == nil {
			ttsText = body["text"]
		}
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("fake-tts-audio"))
	}))
	defer ts.Close()

	origEndpoint := ttsEndpoint
	ttsEndpoint = ts.URL
	defer func() { ttsEndpoint = origEndpoint }()

	b, mc, mci := newTestBridge(t)
	b.typingReadDelay = 0
	b.typingStartDelay = 0
	ctx := context.Background()
	roomID := id.RoomID("!audio:matrix.example.com")

	// Set up room name with audio- prefix
	mc.joinedRooms = []id.RoomID{roomID}
	mc.roomNames[roomID] = "audio-hearth"

	mci.QueueResponse(
		claudeAssistantMsg("sess-tts", "Hello from the agent!"),
		claudeResultMsg("sess-tts", "Hello from the agent!", 200000),
	)

	evt := makeEvent("@alice:example.com", roomID, "hi there", b.startTime.Add(1*time.Minute))
	b.handleMessage(ctx, evt)

	// Wait for TTS goroutine to complete
	time.Sleep(200 * time.Millisecond)

	if !ttsCalled {
		t.Fatal("expected TTS endpoint to be called for audio-prefixed room")
	}
	if ttsText != "Hello from the agent!" {
		t.Errorf("expected TTS text 'Hello from the agent!', got %q", ttsText)
	}

	// Should have at least 2 messages: the text reply and the audio
	msgs := mc.getMessages()
	foundAudio := false
	for _, msg := range msgs {
		if msg.RoomID == roomID && msg.Body == "" {
			// Audio messages are sent via SendMessageEvent with raw content maps,
			// which don't populate sentMessage.Body in the mock.
			foundAudio = true
		}
	}
	if !foundAudio {
		t.Error("expected an audio message to be posted to the room")
	}
}

func TestBridge_HandleMessage_NoAutoTTS_NonAudioRoom(t *testing.T) {
	// Rooms without the "audio-" prefix should NOT trigger TTS.
	var ttsCalled bool
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ttsCalled = true
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("fake-tts-audio"))
	}))
	defer ts.Close()

	origEndpoint := ttsEndpoint
	ttsEndpoint = ts.URL
	defer func() { ttsEndpoint = origEndpoint }()

	b, mc, mci := newTestBridge(t)
	b.typingReadDelay = 0
	b.typingStartDelay = 0
	ctx := context.Background()
	roomID := id.RoomID("!regular:matrix.example.com")

	mc.joinedRooms = []id.RoomID{roomID}
	mc.roomNames[roomID] = "cranium"

	mci.QueueResponse(
		claudeAssistantMsg("sess-no-tts", "Just text"),
		claudeResultMsg("sess-no-tts", "Just text", 200000),
	)

	evt := makeEvent("@alice:example.com", roomID, "hello", b.startTime.Add(1*time.Minute))
	b.handleMessage(ctx, evt)

	time.Sleep(200 * time.Millisecond)

	if ttsCalled {
		t.Error("TTS endpoint should NOT be called for non-audio-prefixed room")
	}
}
