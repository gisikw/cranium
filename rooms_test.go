package main

import (
	"context"
	"testing"

	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
)

// --- Integration tests: sendMessage/editMessage ---
// Spec: edit_in_place.feature — message sending and editing through the Bridge

func TestBridge_SendMessage(t *testing.T) {
	b, mc, _ := newTestBridge(t)
	_ = b

	ctx := context.Background()
	roomID := id.RoomID("!test:example.com")

	eid := b.sendMessage(ctx, roomID, "hello world")
	if eid == "" {
		t.Fatal("sendMessage returned empty event ID")
	}

	msgs := mc.getMessages()
	if len(msgs) != 1 {
		t.Fatalf("expected 1 message, got %d", len(msgs))
	}
	if msgs[0].Body != "hello world" {
		t.Errorf("body = %q, want %q", msgs[0].Body, "hello world")
	}
	if msgs[0].RoomID != roomID {
		t.Errorf("roomID = %q, want %q", msgs[0].RoomID, roomID)
	}
}

func TestBridge_EditMessage(t *testing.T) {
	b, mc, _ := newTestBridge(t)

	ctx := context.Background()
	roomID := id.RoomID("!test:example.com")

	// Send initial message
	eid := b.sendMessage(ctx, roomID, "first version")

	// Edit it
	_ = b.editMessage(ctx, roomID, eid, "second version")

	msgs := mc.getMessages()
	if len(msgs) != 2 {
		t.Fatalf("expected 2 messages (send + edit), got %d", len(msgs))
	}
	if !msgs[1].IsEdit {
		t.Error("second message should be an edit")
	}
	// Matrix edit body has "* " prefix per spec (fallback text)
	if msgs[1].Body != "* second version" {
		t.Errorf("edited body = %q, want %q", msgs[1].Body, "* second version")
	}
}

// --- Integration tests: context pin lifecycle ---
// Spec: context_saturation.feature — "Context pin is created at 60%",
//   "Context pin is updated on subsequent turns", "Context pin is removed on clear"

func TestBridge_ContextPinLifecycle(t *testing.T) {
	b, mc, _ := newTestBridge(t)
	defer settleAsync()
	ctx := context.Background()
	roomID := id.RoomID("!test:example.com")

	// Below 60% — no pin
	b.updateContextPin(ctx, roomID, 55, 110, 200)
	msgs := mc.getMessages()
	if len(msgs) != 0 {
		t.Fatalf("expected no messages below 60%%, got %d", len(msgs))
	}

	// At 60% — creates pin
	b.updateContextPin(ctx, roomID, 60, 120, 200)
	msgs = mc.getMessages()
	if len(msgs) != 2 { // notice message + state event (pin)
		t.Fatalf("expected 2 messages at 60%%, got %d", len(msgs))
	}

	_, hasPinned := b.sessions.GetPinnedEvent(roomID)
	if !hasPinned {
		t.Error("expected pinned event to be tracked")
	}

	// At 75% — edits existing pin
	b.updateContextPin(ctx, roomID, 75, 150, 200)
	msgs = mc.getMessages()
	if len(msgs) != 3 { // +1 edit
		t.Fatalf("expected 3 messages after pin update, got %d", len(msgs))
	}
	if !msgs[2].IsEdit {
		t.Error("pin update should be an edit")
	}

	// Unpin on clear
	b.unpinContext(ctx, roomID)
	if _, ok := b.sessions.GetPinnedEvent(roomID); ok {
		t.Error("pinned event should be cleared after unpin")
	}
}

// --- Integration tests: permission alert on pin failure ---
// Spec: context_saturation.feature — "Pin failure due to missing permissions triggers alert"

func TestBridge_PinPermissionAlert(t *testing.T) {
	b, mc, _ := newTestBridge(t)
	defer settleAsync()
	ctx := context.Background()
	roomID := id.RoomID("!test:example.com")

	// Configure mock to fail pin attempts with permission error
	mc.pinErrorRooms[roomID] = true

	// Attempt to pin at 60% — should fail but send alert
	b.updateContextPin(ctx, roomID, 60, 120, 200)
	msgs := mc.getMessages()

	// Should have: 1) context indicator message, 2) permission alert
	// The state event (pin) will fail, but we should still see the messages
	if len(msgs) < 2 {
		t.Fatalf("expected at least 2 messages (indicator + alert), got %d", len(msgs))
	}

	// Check that the permission alert was sent
	var foundAlert bool
	for _, msg := range msgs {
		if contains(msg.Body, "Moderator") && contains(msg.Body, "power level 50") {
			foundAlert = true
			break
		}
	}
	if !foundAlert {
		t.Error("expected permission alert to be sent")
	}

	// Attempt again — should NOT send duplicate alert
	b.updateContextPin(ctx, roomID, 65, 130, 200)
	msgs = mc.getMessages()

	alertCount := 0
	for _, msg := range msgs {
		if contains(msg.Body, "Moderator") && contains(msg.Body, "power level 50") {
			alertCount++
		}
	}
	if alertCount > 1 {
		t.Errorf("expected permission alert to be sent only once, got %d alerts", alertCount)
	}
}

// --- Integration tests: handleNewRoom ---
// Spec: session_lifecycle.feature — "!new creates a room and invites the sender"

func TestBridge_HandleNewRoom(t *testing.T) {
	b, mc, _ := newTestBridge(t)
	ctx := context.Background()
	fromRoom := id.RoomID("!from:example.com")
	sender := id.UserID("@alice:example.com")

	b.handleNewRoom(ctx, fromRoom, sender, "my-project")

	if len(mc.createdRooms) != 1 || mc.createdRooms[0] != "my-project" {
		t.Errorf("expected room created with name 'my-project', got %v", mc.createdRooms)
	}

	// Should send confirmation to the originating room
	msgs := mc.getMessages()
	found := false
	for _, m := range msgs {
		if m.RoomID == fromRoom && contains(m.Body, "my-project") {
			found = true
		}
	}
	if !found {
		t.Error("expected confirmation message in originating room")
	}
}

// --- Integration tests: handleInvite ---
// Spec: session_lifecycle.feature (implicit — auto-join behavior)

func TestBridge_HandleInvite(t *testing.T) {
	b, mc, _ := newTestBridge(t)
	ctx := context.Background()
	roomID := id.RoomID("!invited:example.com")

	// Set power level high enough so no nudge is sent
	mc.powerLevels[roomID] = 100

	evt := &event.Event{
		Sender: "@alice:example.com",
		RoomID: roomID,
		Type:   event.StateMember,
	}

	b.handleInvite(ctx, evt)

	if len(mc.joinedByID) != 1 || mc.joinedByID[0] != roomID {
		t.Errorf("expected to join room %s, got %v", roomID, mc.joinedByID)
	}
}

func TestBridge_HandleInvite_LowPowerNudge(t *testing.T) {
	b, mc, _ := newTestBridge(t)
	ctx := context.Background()
	roomID := id.RoomID("!invited:example.com")

	// Power level too low — should send nudge
	mc.powerLevels[roomID] = 0

	evt := &event.Event{
		Sender: "@alice:example.com",
		RoomID: roomID,
		Type:   event.StateMember,
	}

	b.handleInvite(ctx, evt)

	msgs := mc.getMessages()
	found := false
	for _, m := range msgs {
		if m.RoomID == roomID && contains(m.Body, "Moderator") {
			found = true
		}
	}
	if !found {
		t.Error("expected moderator nudge message for low power level")
	}
}
