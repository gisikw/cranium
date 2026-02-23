package main

import (
	"context"
	"encoding/json"
	"os"
	"testing"
	"time"

	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
)

// --- Integration tests: handleReaction ---
// Spec: tool_approval.feature — reaction-based approval

func TestBridge_HandleReaction_Approve(t *testing.T) {
	b, _, _ := newTestBridge(t)
	ctx := context.Background()

	// Set up pending approval
	approvalEventID := id.EventID("$approval-1")
	pending := &pendingApproval{
		eventID:  approvalEventID,
		roomID:   id.RoomID("!test:example.com"),
		response: make(chan ApprovalResponse, 1),
	}
	b.pendingApprovals.Store(approvalEventID, pending)

	// Simulate thumbs-up reaction
	reactionEvt := &event.Event{
		Sender: "@alice:example.com",
		RoomID: id.RoomID("!test:example.com"),
		Type:   event.EventReaction,
	}
	reactionEvt.Content.Parsed = &event.ReactionEventContent{
		RelatesTo: event.RelatesTo{
			Type:    event.RelAnnotation,
			EventID: approvalEventID,
			Key:     "\U0001f44d", // 👍
		},
	}

	b.handleReaction(ctx, reactionEvt)

	select {
	case resp := <-pending.response:
		if resp.Decision != "allow" {
			t.Errorf("expected 'allow', got %q", resp.Decision)
		}
	case <-time.After(1 * time.Second):
		t.Fatal("timed out waiting for approval response")
	}
}

func TestBridge_HandleReaction_Deny(t *testing.T) {
	b, _, _ := newTestBridge(t)
	ctx := context.Background()

	approvalEventID := id.EventID("$approval-2")
	pending := &pendingApproval{
		eventID:  approvalEventID,
		roomID:   id.RoomID("!test:example.com"),
		response: make(chan ApprovalResponse, 1),
	}
	b.pendingApprovals.Store(approvalEventID, pending)

	reactionEvt := &event.Event{
		Sender: "@alice:example.com",
		RoomID: id.RoomID("!test:example.com"),
		Type:   event.EventReaction,
	}
	reactionEvt.Content.Parsed = &event.ReactionEventContent{
		RelatesTo: event.RelatesTo{
			Type:    event.RelAnnotation,
			EventID: approvalEventID,
			Key:     "\U0001f44e", // 👎
		},
	}

	b.handleReaction(ctx, reactionEvt)

	select {
	case resp := <-pending.response:
		if resp.Decision != "deny" {
			t.Errorf("expected 'deny', got %q", resp.Decision)
		}
	case <-time.After(1 * time.Second):
		t.Fatal("timed out waiting for denial response")
	}
}

func TestBridge_HandleReaction_Stop(t *testing.T) {
	b, _, _ := newTestBridge(t)
	ctx := context.Background()

	approvalEventID := id.EventID("$approval-3")
	pending := &pendingApproval{
		eventID:  approvalEventID,
		roomID:   id.RoomID("!test:example.com"),
		response: make(chan ApprovalResponse, 1),
	}
	b.pendingApprovals.Store(approvalEventID, pending)

	reactionEvt := &event.Event{
		Sender: "@alice:example.com",
		RoomID: id.RoomID("!test:example.com"),
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
			t.Errorf("expected deny/STOP, got %q/%q", resp.Decision, resp.Message)
		}
	case <-time.After(1 * time.Second):
		t.Fatal("timed out waiting for stop response")
	}
}

func TestBridge_HandleReaction_IgnoresSelfReaction(t *testing.T) {
	b, _, _ := newTestBridge(t)
	ctx := context.Background()

	approvalEventID := id.EventID("$approval-4")
	pending := &pendingApproval{
		eventID:  approvalEventID,
		roomID:   id.RoomID("!test:example.com"),
		response: make(chan ApprovalResponse, 1),
	}
	b.pendingApprovals.Store(approvalEventID, pending)

	// Reaction from self — should be ignored
	reactionEvt := &event.Event{
		Sender: b.userID,
		RoomID: id.RoomID("!test:example.com"),
		Type:   event.EventReaction,
	}
	reactionEvt.Content.Parsed = &event.ReactionEventContent{
		RelatesTo: event.RelatesTo{
			Type:    event.RelAnnotation,
			EventID: approvalEventID,
			Key:     "\U0001f44d", // 👍
		},
	}

	b.handleReaction(ctx, reactionEvt)

	select {
	case <-pending.response:
		t.Fatal("should not have received response for self-reaction")
	case <-time.After(100 * time.Millisecond):
		// Expected — no response
	}
}

func TestBridge_HandleReaction_UnknownEmoji(t *testing.T) {
	b, _, _ := newTestBridge(t)
	ctx := context.Background()

	approvalEventID := id.EventID("$approval-5")
	pending := &pendingApproval{
		eventID:  approvalEventID,
		roomID:   id.RoomID("!test:example.com"),
		response: make(chan ApprovalResponse, 1),
	}
	b.pendingApprovals.Store(approvalEventID, pending)

	reactionEvt := &event.Event{
		Sender: "@alice:example.com",
		RoomID: id.RoomID("!test:example.com"),
		Type:   event.EventReaction,
	}
	reactionEvt.Content.Parsed = &event.ReactionEventContent{
		RelatesTo: event.RelatesTo{
			Type:    event.RelAnnotation,
			EventID: approvalEventID,
			Key:     "\U0001f389", // 🎉
		},
	}

	b.handleReaction(ctx, reactionEvt)

	select {
	case <-pending.response:
		t.Fatal("should not have received response for unknown emoji")
	case <-time.After(100 * time.Millisecond):
		// Expected
	}
}

// --- Integration tests: requestApproval auto-approve ---
// Spec: tool_approval.feature — auto-approve config matching

func TestBridge_RequestApproval_AutoApprove(t *testing.T) {
	b, _, _ := newTestBridge(t)
	ctx := context.Background()

	// Write auto-approve config
	config := AutoApproveConfig{
		Allow: []string{"Read", "Glob"},
		Deny:  []string{"Bash(rm *)"},
	}
	data, _ := json.Marshal(config)
	os.WriteFile(b.autoApprovePath, data, 0600)
	defer os.Remove(b.autoApprovePath)

	// Test allow
	resp := b.requestApproval(ctx, ApprovalRequest{
		SessionID: "sess-1",
		ToolName:  "Read",
		ToolInput: map[string]interface{}{"file_path": "/any/path"},
	})
	if resp.Decision != "allow" {
		t.Errorf("expected allow, got %q", resp.Decision)
	}

	// Test deny
	resp = b.requestApproval(ctx, ApprovalRequest{
		SessionID: "sess-1",
		ToolName:  "Bash",
		ToolInput: map[string]interface{}{"command": "rm -rf /"},
	})
	if resp.Decision != "deny" {
		t.Errorf("expected deny, got %q", resp.Decision)
	}
}

// --- Integration tests: interactive approval flow ---
// Spec: tool_approval.feature — "Unmatched tool request prompts the user"

func TestBridge_RequestApproval_InteractivePrompt(t *testing.T) {
	// When no auto-approve rule matches, requestApproval sends a formatted
	// prompt to the room and waits for a reaction.
	b, mc, _ := newTestBridge(t)
	ctx := context.Background()
	roomID := id.RoomID("!test:example.com")

	// Set up a session so GetRoomBySession works
	b.sessions.Set(roomID, "sess-interactive")

	// No auto-approve config — everything goes interactive
	// Run requestApproval in a goroutine since it blocks
	var resp ApprovalResponse
	done := make(chan struct{})
	go func() {
		resp = b.requestApproval(ctx, ApprovalRequest{
			SessionID: "sess-interactive",
			ToolName:  "Bash",
			ToolInput: map[string]interface{}{"command": "git status"},
		})
		close(done)
	}()

	// Wait for the message to be sent
	time.Sleep(50 * time.Millisecond)

	msgs := mc.getMessages()
	if len(msgs) < 1 {
		t.Fatal("expected at least 1 message (approval prompt)")
	}
	promptMsg := msgs[len(msgs)-1]

	// Verify prompt formatting
	if !contains(promptMsg.Body, "Bash") {
		t.Errorf("prompt should contain tool name, got: %q", promptMsg.Body)
	}
	if !contains(promptMsg.Body, "git status") {
		t.Errorf("prompt should contain command, got: %q", promptMsg.Body)
	}

	// Now simulate a reaction on the approval event
	reactionEvt := &event.Event{
		Sender: "@alice:example.com",
		RoomID: roomID,
		Type:   event.EventReaction,
	}
	reactionEvt.Content.Parsed = &event.ReactionEventContent{
		RelatesTo: event.RelatesTo{
			Type:    event.RelAnnotation,
			EventID: promptMsg.EventID,
			Key:     "\U0001f44d", // 👍
		},
	}
	b.handleReaction(ctx, reactionEvt)

	select {
	case <-done:
		if resp.Decision != "allow" {
			t.Errorf("expected 'allow', got %q", resp.Decision)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for requestApproval to return")
	}
}

func TestBridge_RequestApproval_InteractiveDeny(t *testing.T) {
	b, mc, _ := newTestBridge(t)
	ctx := context.Background()
	roomID := id.RoomID("!test:example.com")
	b.sessions.Set(roomID, "sess-deny")

	var resp ApprovalResponse
	done := make(chan struct{})
	go func() {
		resp = b.requestApproval(ctx, ApprovalRequest{
			SessionID: "sess-deny",
			ToolName:  "Bash",
			ToolInput: map[string]interface{}{"command": "curl evil.com"},
		})
		close(done)
	}()

	time.Sleep(50 * time.Millisecond)

	msgs := mc.getMessages()
	promptMsg := msgs[len(msgs)-1]

	reactionEvt := &event.Event{
		Sender: "@alice:example.com",
		RoomID: roomID,
		Type:   event.EventReaction,
	}
	reactionEvt.Content.Parsed = &event.ReactionEventContent{
		RelatesTo: event.RelatesTo{
			Type:    event.RelAnnotation,
			EventID: promptMsg.EventID,
			Key:     "\U0001f44e", // 👎
		},
	}
	b.handleReaction(ctx, reactionEvt)

	select {
	case <-done:
		if resp.Decision != "deny" {
			t.Errorf("expected 'deny', got %q", resp.Decision)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for requestApproval to return")
	}
}

func TestBridge_RequestApproval_ContextCancellation(t *testing.T) {
	// Spec: approval times out → deny (we test context cancellation as a
	// proxy since the 5-minute timeout is hardcoded)
	b, _, _ := newTestBridge(t)
	ctx, cancel := context.WithCancel(context.Background())
	roomID := id.RoomID("!test:example.com")
	b.sessions.Set(roomID, "sess-timeout")

	var resp ApprovalResponse
	done := make(chan struct{})
	go func() {
		resp = b.requestApproval(ctx, ApprovalRequest{
			SessionID: "sess-timeout",
			ToolName:  "Bash",
			ToolInput: map[string]interface{}{"command": "sleep 999"},
		})
		close(done)
	}()

	// Let the approval prompt be sent, then cancel
	time.Sleep(50 * time.Millisecond)
	cancel()

	select {
	case <-done:
		if resp.Decision != "deny" {
			t.Errorf("expected 'deny' on context cancellation, got %q", resp.Decision)
		}
		if !contains(resp.Message, "cancelled") {
			t.Errorf("expected message about cancellation, got %q", resp.Message)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for requestApproval to return after cancel")
	}
}

func TestBridge_RequestApproval_NoSession(t *testing.T) {
	// When the session ID isn't known, defer to Claude Code's permission model
	b, _, _ := newTestBridge(t)
	ctx := context.Background()

	resp := b.requestApproval(ctx, ApprovalRequest{
		SessionID: "unknown-session",
		ToolName:  "Read",
		ToolInput: map[string]interface{}{"file_path": "/etc/passwd"},
	})
	if resp.Decision != "ask" {
		t.Errorf("expected 'ask' for unknown session, got %q", resp.Decision)
	}
}

func TestBridge_RequestApproval_MessageFormatting(t *testing.T) {
	// Verify different tool input formatting paths
	tests := []struct {
		name     string
		input    map[string]interface{}
		contains string
	}{
		{"command field", map[string]interface{}{"command": "ls -la"}, "`ls -la`"},
		{"description field", map[string]interface{}{"description": "Read a file"}, "Read a file"},
		{"other fields", map[string]interface{}{"foo": "bar"}, "bar"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			b, mc, _ := newTestBridge(t)
			ctx, cancel := context.WithCancel(context.Background())
			roomID := id.RoomID("!test:example.com")
			b.sessions.Set(roomID, "sess-fmt")

			go func() {
				b.requestApproval(ctx, ApprovalRequest{
					SessionID: "sess-fmt",
					ToolName:  "TestTool",
					ToolInput: tt.input,
				})
			}()

			time.Sleep(50 * time.Millisecond)
			cancel()
			time.Sleep(50 * time.Millisecond)

			msgs := mc.getMessages()
			if len(msgs) < 1 {
				t.Fatal("expected approval prompt message")
			}
			if !contains(msgs[0].Body, tt.contains) {
				t.Errorf("prompt should contain %q, got: %q", tt.contains, msgs[0].Body)
			}
		})
	}
}
