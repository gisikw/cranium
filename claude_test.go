package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"maunium.net/go/mautrix/id"
)

// --- Integration tests: invokeClaude via mock ---
// Spec: edit_in_place.feature, session_lifecycle.feature

func TestInvokeClaude_SimpleResponse(t *testing.T) {
	b, mc, mci := newTestBridge(t)
	ctx := context.Background()
	roomID := id.RoomID("!test:example.com")
	mc.roomNames[roomID] = "test-room"

	// Queue a simple response: one text section + result
	mci.QueueResponse(
		claudeAssistantMsg("sess-123", "Hello from Claude!"),
		claudeResultMsg("sess-123", "Hello from Claude!", 200000),
	)

	result, newSID, ctxInfo, _, err := b.invokeClaude(ctx, roomID, "Hi there")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Edit-in-place: should have sent initial message, result is empty (delivered via edit-in-place)
	if result != "" {
		t.Errorf("expected empty result (sent via edit-in-place), got %q", result)
	}
	if newSID != "sess-123" {
		t.Errorf("expected session ID sess-123, got %q", newSID)
	}
	if ctxInfo.ContextWindow != 200000 {
		t.Errorf("expected context window 200000, got %d", ctxInfo.ContextWindow)
	}

	// Should have sent exactly one message (the initial send)
	msgs := mc.getMessages()
	var nonEdit []sentMessage
	for _, m := range msgs {
		if !m.IsEdit {
			nonEdit = append(nonEdit, m)
		}
	}
	if len(nonEdit) != 1 {
		t.Errorf("expected 1 initial message, got %d", len(nonEdit))
	}
	if len(nonEdit) > 0 && !contains(nonEdit[0].Body, "Hello from Claude!") {
		t.Errorf("expected message body to contain 'Hello from Claude!', got %q", nonEdit[0].Body)
	}

	// Verify invocation args
	invocations := mci.getInvocations()
	if len(invocations) != 1 {
		t.Fatalf("expected 1 invocation, got %d", len(invocations))
	}
	inv := invocations[0]
	if !containsStr(inv.Args, "-p") {
		t.Error("expected -p in args")
	}
	if !containsStr(inv.Args, "--output-format") {
		t.Error("expected --output-format in args")
	}
}

func TestInvokeClaude_MultiSectionEditInPlace(t *testing.T) {
	b, mc, mci := newTestBridge(t)
	ctx := context.Background()
	roomID := id.RoomID("!test:example.com")
	mc.roomNames[roomID] = "test-room"

	// Queue multi-section response: text → tool → text → result
	mci.QueueResponse(
		claudeAssistantMsg("sess-456", "Let me check that for you."),
		claudeToolMsg("sess-456", map[string]interface{}{
			"name":  "Read",
			"input": map[string]interface{}{"file_path": "/tmp/test.go"},
		}),
		claudeAssistantMsg("sess-456", "Here's what I found."),
		claudeResultMsg("sess-456", "Here's what I found.", 200000),
	)

	_, newSID, _, _, err := b.invokeClaude(ctx, roomID, "Check something")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if newSID != "sess-456" {
		t.Errorf("expected session ID sess-456, got %q", newSID)
	}

	msgs := mc.getMessages()

	// Should have initial send + at least 2 edits (tool section, then thinking→final reply)
	var sends, edits int
	for _, m := range msgs {
		if m.IsEdit {
			edits++
		} else {
			sends++
		}
	}
	if sends != 1 {
		t.Errorf("expected 1 initial send, got %d", sends)
	}
	if edits < 2 {
		t.Errorf("expected at least 2 edits, got %d", edits)
	}

	// The final edit should not contain the working indicator
	lastEdit := msgs[len(msgs)-1]
	if contains(lastEdit.Body, "[Agent is ") && contains(lastEdit.Body, "...]*") {
		t.Error("final edit should not contain working indicator")
	}
}

func TestInvokeClaude_WorkingIndicatorOnIntermediateEdits(t *testing.T) {
	b, mc, mci := newTestBridge(t)
	ctx := context.Background()
	roomID := id.RoomID("!test:example.com")
	mc.roomNames[roomID] = "test-room"

	// Text → tool → text → result (the tool message triggers the trailer)
	mci.QueueResponse(
		claudeAssistantMixed("sess-789", "Starting work...", "Bash", map[string]interface{}{"command": "ls"}),
		claudeAssistantMsg("sess-789", "All done."),
		claudeResultMsg("sess-789", "All done.", 200000),
	)

	_, _, _, _, err := b.invokeClaude(ctx, roomID, "Do work")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	msgs := mc.getMessages()
	// Look for intermediate edits that contain the working indicator
	var hasTrailer bool
	for i, m := range msgs {
		if m.IsEdit && contains(m.Body, "[Agent is ") && contains(m.Body, "...]*") {
			hasTrailer = true
			// Ensure it's not the last message
			if i == len(msgs)-1 {
				t.Error("working indicator should not appear on final message")
			}
		}
	}
	if !hasTrailer {
		t.Error("expected at least one intermediate edit with working indicator")
	}
}

func TestInvokeClaude_SessionResume(t *testing.T) {
	b, mc, mci := newTestBridge(t)
	ctx := context.Background()
	roomID := id.RoomID("!test:example.com")
	mc.roomNames[roomID] = "test-room"

	// Set up existing session with a stored system prompt file
	b.sessions.Set(roomID, "existing-sess")
	b.sessions.MarkInvoked("existing-sess")
	storedPromptFile := filepath.Join(b.dataDir, "system-prompts", "test-room_2025-01-01_00-00-00.md")
	os.MkdirAll(filepath.Dir(storedPromptFile), 0755)
	os.WriteFile(storedPromptFile, []byte("# Test System Prompt"), 0644)
	b.sessions.SetSystemPromptFile(roomID, storedPromptFile)

	mci.QueueResponse(
		claudeAssistantMsg("existing-sess", "Resumed!"),
		claudeResultMsg("existing-sess", "Resumed!", 200000),
	)

	_, _, _, _, err := b.invokeClaude(ctx, roomID, "Continue")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Should have passed --resume with the existing session ID
	inv := mci.getInvocations()[0]
	foundResume := false
	foundPromptFile := false
	for i, arg := range inv.Args {
		if arg == "--resume" && i+1 < len(inv.Args) && inv.Args[i+1] == "existing-sess" {
			foundResume = true
		}
		if arg == "--append-system-prompt-file" && i+1 < len(inv.Args) && inv.Args[i+1] == storedPromptFile {
			foundPromptFile = true
		}
	}
	if !foundResume {
		t.Errorf("expected --resume existing-sess in args: %v", inv.Args)
	}
	if !foundPromptFile {
		t.Errorf("expected --append-system-prompt-file %s in args: %v", storedPromptFile, inv.Args)
	}
}

func TestInvokeClaude_FreshSessionNoResume(t *testing.T) {
	b, mc, mci := newTestBridge(t)
	ctx := context.Background()
	roomID := id.RoomID("!test:example.com")
	mc.roomNames[roomID] = "test-room"

	// No session set — should be fresh
	mci.QueueResponse(
		claudeAssistantMsg("new-sess", "Hello!"),
		claudeResultMsg("new-sess", "Hello!", 200000),
	)

	_, newSID, _, _, err := b.invokeClaude(ctx, roomID, "Hello")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if newSID != "new-sess" {
		t.Errorf("expected new-sess, got %q", newSID)
	}

	// Should NOT have --resume
	inv := mci.getInvocations()[0]
	for _, arg := range inv.Args {
		if arg == "--resume" {
			t.Error("fresh session should not pass --resume")
		}
	}
}

func TestInvokeClaude_ContextInfoExtracted(t *testing.T) {
	b, mc, mci := newTestBridge(t)
	ctx := context.Background()
	roomID := id.RoomID("!test:example.com")
	mc.roomNames[roomID] = "test-room"

	mci.QueueResponse(
		claudeAssistantMsg("sess-ctx", "Response"),
		claudeResultMsg("sess-ctx", "Response", 180000),
	)

	_, _, ctxInfo, _, err := b.invokeClaude(ctx, roomID, "test")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if ctxInfo.ContextWindow != 180000 {
		t.Errorf("expected context window 180000, got %d", ctxInfo.ContextWindow)
	}
	if ctxInfo.UsedTokens == 0 {
		t.Error("expected non-zero used tokens")
	}
}

func TestInvokeClaude_ThinkingFormatting(t *testing.T) {
	b, mc, mci := newTestBridge(t)
	ctx := context.Background()
	roomID := id.RoomID("!test:example.com")
	mc.roomNames[roomID] = "test-room"

	// text → tool → text(thinking) → result
	// The text after a tool should be thinking-formatted, but the last text
	// section gets reverted to plain since it's the real reply.
	mci.QueueResponse(
		claudeAssistantMsg("sess-think", "Initial response"),
		claudeToolMsg("sess-think", map[string]interface{}{
			"name":  "Bash",
			"input": map[string]interface{}{"command": "echo hello"},
		}),
		claudeAssistantMsg("sess-think", "Final answer after tool"),
		claudeResultMsg("sess-think", "Final answer after tool", 200000),
	)

	_, _, _, _, err := b.invokeClaude(ctx, roomID, "test thinking")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// The last message should contain the final answer in plain text (not italic/blockquoted)
	msgs := mc.getMessages()
	lastMsg := msgs[len(msgs)-1]
	if contains(lastMsg.Body, "> *Final answer") {
		t.Error("final reply should not be thinking-formatted")
	}
	if !contains(lastMsg.Body, "Final answer after tool") {
		t.Errorf("expected final answer in last message, got %q", lastMsg.Body)
	}
}

func TestInvokeClaude_EnvVarsSet(t *testing.T) {
	b, mc, mci := newTestBridge(t)
	ctx := context.Background()
	roomID := id.RoomID("!test:example.com")
	mc.roomNames[roomID] = "test-room"

	mci.QueueResponse(
		claudeAssistantMsg("sess-env", "ok"),
		claudeResultMsg("sess-env", "ok", 200000),
	)

	_, _, _, _, err := b.invokeClaude(ctx, roomID, "test")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	inv := mci.getInvocations()[0]
	hasRoomID := false
	hasSessionID := false
	for _, e := range inv.Env {
		if e == "CRANIUM_ROOM_ID=!test:example.com" {
			hasRoomID = true
		}
		if strings.HasPrefix(e, "CRANIUM_SESSION_ID=") {
			hasSessionID = true
		}
	}
	if !hasRoomID {
		t.Errorf("expected CRANIUM_ROOM_ID in env, got %v", inv.Env)
	}
	if !hasSessionID {
		t.Errorf("expected CRANIUM_SESSION_ID in env, got %v", inv.Env)
	}
}

func TestInvokeClaude_HandoffLoadedOnFreshSession(t *testing.T) {
	b, mc, mci := newTestBridge(t)
	ctx := context.Background()
	roomID := id.RoomID("!test:example.com")
	mc.roomNames[roomID] = "test-room"

	// Create a handoff file
	handoffDir := filepath.Join(b.dataDir, "handoffs", "test-room")
	os.MkdirAll(handoffDir, 0755)
	os.WriteFile(filepath.Join(handoffDir, "2026-02-12_10-00-00.md"), []byte("Previous handoff content"), 0644)

	mci.QueueResponse(
		claudeAssistantMsg("sess-ho2", "Got it!"),
		claudeResultMsg("sess-ho2", "Got it!", 200000),
	)

	_, _, _, _, err := b.invokeClaude(ctx, roomID, "Hello again")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	inv := mci.getInvocations()[0]
	// Fresh session should use --append-system-prompt-file pointing to a file with handoff content
	var promptFilePath string
	for i, arg := range inv.Args {
		if arg == "--append-system-prompt-file" && i+1 < len(inv.Args) {
			promptFilePath = inv.Args[i+1]
		}
	}
	if promptFilePath == "" {
		t.Fatalf("expected --append-system-prompt-file in args: %v", inv.Args)
	}
	promptContent, err := os.ReadFile(promptFilePath)
	if err != nil {
		t.Fatalf("failed to read system prompt file %s: %v", promptFilePath, err)
	}
	if !contains(string(promptContent), "Previous handoff content") {
		t.Errorf("system prompt file missing handoff content: %s", string(promptContent))
	}
}

func TestInvokeClaude_ResumedSessionReusesSystemPromptFile(t *testing.T) {
	b, mc, mci := newTestBridge(t)
	ctx := context.Background()
	roomID := id.RoomID("!test:example.com")
	mc.roomNames[roomID] = "test-room"

	// Set system prompt content so a file is written on fresh session
	b.systemPromptContent = "# Identity\nYou are EXO."

	// Turn 1: fresh session — should write and store the system prompt file
	mci.QueueResponse(
		claudeAssistantMsg("sess-reuse", "Hello!"),
		claudeResultMsg("sess-reuse", "Hello!", 200000),
	)

	_, newSID, _, _, err := b.invokeClaude(ctx, roomID, "Hi")
	if err != nil {
		t.Fatalf("turn 1: unexpected error: %v", err)
	}
	b.sessions.Set(roomID, newSID)

	// Verify the file was stored
	storedPath, ok := b.sessions.GetSystemPromptFile(roomID)
	if !ok {
		t.Fatal("expected system prompt file to be stored after fresh session")
	}

	// Turn 2: resumed session — should reuse the stored file
	mci.QueueResponse(
		claudeAssistantMsg("sess-reuse", "Resumed!"),
		claudeResultMsg("sess-reuse", "Resumed!", 200000),
	)

	_, _, _, _, err = b.invokeClaude(ctx, roomID, "Continue")
	if err != nil {
		t.Fatalf("turn 2: unexpected error: %v", err)
	}

	// The second invocation should pass both --resume and --append-system-prompt-file
	inv := mci.getInvocations()[1]
	foundResume := false
	foundPromptFile := false
	for i, arg := range inv.Args {
		if arg == "--resume" && i+1 < len(inv.Args) && inv.Args[i+1] == "sess-reuse" {
			foundResume = true
		}
		if arg == "--append-system-prompt-file" && i+1 < len(inv.Args) && inv.Args[i+1] == storedPath {
			foundPromptFile = true
		}
	}
	if !foundResume {
		t.Errorf("turn 2: expected --resume in args: %v", inv.Args)
	}
	if !foundPromptFile {
		t.Errorf("turn 2: expected --append-system-prompt-file %s in args: %v", storedPath, inv.Args)
	}
}

// bigText generates a string of approximately n bytes.
func bigText(n int) string {
	return strings.Repeat("x", n)
}

func TestInvokeClaude_ProactiveSplitOnLargeMessage(t *testing.T) {
	b, mc, mci := newTestBridge(t)
	ctx := context.Background()
	roomID := id.RoomID("!test:example.com")
	mc.roomNames[roomID] = "test-room"

	// Generate sections that together exceed the 50KB threshold.
	// First section: 30KB, second section (tool): small, third section: 25KB.
	// Total > 50KB, so the third section should trigger a split.
	chunk1 := bigText(30 * 1024)
	chunk2 := bigText(25 * 1024)

	mci.QueueResponse(
		claudeAssistantMsg("sess-split", chunk1),
		claudeToolMsg("sess-split", map[string]interface{}{
			"name":  "Bash",
			"input": map[string]interface{}{"command": "echo test"},
		}),
		claudeAssistantMsg("sess-split", chunk2),
		claudeResultMsg("sess-split", chunk2, 200000),
	)

	_, _, _, _, err := b.invokeClaude(ctx, roomID, "do big work")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	msgs := mc.getMessages()

	// Count distinct initial sends (non-edit messages)
	var sends int
	for _, m := range msgs {
		if !m.IsEdit {
			sends++
		}
	}
	if sends < 2 {
		t.Errorf("expected at least 2 initial sends (message was split), got %d", sends)
	}

	// The final message should not contain the working indicator
	lastMsg := msgs[len(msgs)-1]
	if contains(lastMsg.Body, "[Agent is ") && contains(lastMsg.Body, "...]*") {
		t.Error("final message should not contain working indicator")
	}
}

func TestInvokeClaude_ProactiveSplitCarriesContent(t *testing.T) {
	b, mc, mci := newTestBridge(t)
	ctx := context.Background()
	roomID := id.RoomID("!test:example.com")
	mc.roomNames[roomID] = "test-room"

	// The triggering section (chunk2) must appear in the NEW message,
	// not silently dropped or baked into the old (oversized) message.
	chunk1 := bigText(40 * 1024)
	chunk2marker := "CARRIED_OVER_MARKER_" + bigText(15*1024)

	mci.QueueResponse(
		claudeAssistantMsg("sess-carry", chunk1),
		claudeAssistantMsg("sess-carry", chunk2marker),
		claudeResultMsg("sess-carry", chunk2marker, 200000),
	)

	_, _, _, _, err := b.invokeClaude(ctx, roomID, "test carry")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	msgs := mc.getMessages()

	// Find the last non-edit send — this is the fresh message after the split
	var lastSend sentMessage
	for _, m := range msgs {
		if !m.IsEdit {
			lastSend = m
		}
	}

	// The carried-over content must appear in the new message
	if !contains(lastSend.Body, "CARRIED_OVER_MARKER_") {
		t.Errorf("expected the split-triggering section to appear in the new message, but it was lost")
	}

	// The first message (finalized) should NOT contain the marker
	var firstSend sentMessage
	for _, m := range msgs {
		if !m.IsEdit {
			firstSend = m
			break
		}
	}
	if contains(firstSend.Body, "CARRIED_OVER_MARKER_") {
		t.Errorf("expected the split-triggering section to NOT be in the old message (it should have been carried to the new one)")
	}
}

func TestInvokeClaude_FallbackSplitOnEditError(t *testing.T) {
	b, mc, mci := newTestBridge(t)
	ctx := context.Background()
	roomID := id.RoomID("!test:example.com")
	mc.roomNames[roomID] = "test-room"

	// Set a low edit error threshold to simulate M_TOO_LARGE on the second edit.
	// The first section sends OK, the tool edit succeeds (small), but a
	// subsequent larger edit triggers the error.
	mc.editErrorAfterBytes = 200

	mci.QueueResponse(
		claudeAssistantMsg("sess-fallback", "short initial"),
		claudeToolMsg("sess-fallback", map[string]interface{}{
			"name":  "Bash",
			"input": map[string]interface{}{"command": "ls"},
		}),
		claudeAssistantMsg("sess-fallback", bigText(300)),
		claudeResultMsg("sess-fallback", "done", 200000),
	)

	_, _, _, _, err := b.invokeClaude(ctx, roomID, "trigger fallback")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	msgs := mc.getMessages()

	// Should have at least 2 initial sends due to error-triggered split
	var sends int
	for _, m := range msgs {
		if !m.IsEdit {
			sends++
		}
	}
	if sends < 2 {
		t.Errorf("expected at least 2 initial sends (fallback split), got %d", sends)
	}
}

func TestBuildInterruptedSummary(t *testing.T) {
	tests := []struct {
		name      string
		sections  []string
		maxChars  int
		wantEmpty bool
		wantTrunc bool
	}{
		{
			name:      "empty sections",
			sections:  []string{},
			maxChars:  100,
			wantEmpty: true,
		},
		{
			name:     "short summary",
			sections: []string{"Section 1", "Section 2"},
			maxChars: 100,
		},
		{
			name:      "long summary gets truncated",
			sections:  []string{strings.Repeat("x", 100), strings.Repeat("y", 100)},
			maxChars:  150,
			wantTrunc: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := buildInterruptedSummary(tt.sections, tt.maxChars)
			if tt.wantEmpty {
				if result != "" {
					t.Errorf("expected empty, got %q", result)
				}
				return
			}
			if tt.wantTrunc {
				if len(result) > tt.maxChars+len("\n\n[...output truncated...]") {
					t.Errorf("result too long: %d chars, max %d", len(result), tt.maxChars)
				}
				if !strings.Contains(result, "[...output truncated...]") {
					t.Error("expected truncation marker")
				}
			} else {
				expected := strings.Join(tt.sections, "\n\n")
				if result != expected {
					t.Errorf("got %q, want %q", result, expected)
				}
			}
		})
	}
}
