package main

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
)

// Spec: tool_approval.feature — "Hook falls back when bridge socket is unavailable"
// (Tested as socket round-trip via net.Pipe)

func TestBridge_SocketApproval_RoundTrip(t *testing.T) {
	// End-to-end: hook sends JSON over socket → bridge processes → hook gets response
	b, mc, _ := newTestBridge(t)
	ctx := context.Background()
	roomID := id.RoomID("!test:example.com")
	b.sessions.Set(roomID, "sess-socket")

	// Use net.Pipe for in-process testing
	hookConn, bridgeConn := net.Pipe()

	// Start socket handler in background
	go b.handleSocketConnection(ctx, bridgeConn)

	// Simulate a reaction to approve (need to do this after prompt is sent)
	go func() {
		time.Sleep(100 * time.Millisecond)
		msgs := mc.getMessages()
		if len(msgs) == 0 {
			return
		}
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
				Key:     "\U0001f44d", // 👍
			},
		}
		b.handleReaction(ctx, reactionEvt)
	}()

	// Send approval request as the hook would
	req := SocketRequest{
		Type:      "approval",
		SessionID: "sess-socket",
		ToolName:  "Bash",
		ToolInput: map[string]interface{}{"command": "echo hello"},
	}
	json.NewEncoder(hookConn).Encode(req)

	// Read response
	var resp ApprovalResponse
	if err := json.NewDecoder(hookConn).Decode(&resp); err != nil {
		t.Fatalf("failed to decode response: %v", err)
	}
	hookConn.Close()

	if resp.Decision != "allow" {
		t.Errorf("expected 'allow', got %q", resp.Decision)
	}
}

func TestBridge_SocketApproval_AutoApproveBypass(t *testing.T) {
	// Auto-approved tools should return immediately without prompting
	b, mc, _ := newTestBridge(t)
	ctx := context.Background()
	roomID := id.RoomID("!test:example.com")
	b.sessions.Set(roomID, "sess-auto")

	// Write auto-approve config
	config := AutoApproveConfig{Allow: []string{"Read"}}
	data, _ := json.Marshal(config)
	os.WriteFile(b.autoApprovePath, data, 0600)
	defer os.Remove(b.autoApprovePath)

	hookConn, bridgeConn := net.Pipe()
	go b.handleSocketConnection(ctx, bridgeConn)

	req := SocketRequest{
		Type:      "approval",
		SessionID: "sess-auto",
		ToolName:  "Read",
		ToolInput: map[string]interface{}{"file_path": "/tmp/test"},
	}
	json.NewEncoder(hookConn).Encode(req)

	var resp ApprovalResponse
	if err := json.NewDecoder(hookConn).Decode(&resp); err != nil {
		t.Fatalf("failed to decode response: %v", err)
	}
	hookConn.Close()

	if resp.Decision != "allow" {
		t.Errorf("expected 'allow', got %q", resp.Decision)
	}

	// No prompt should have been sent
	msgs := mc.getMessages()
	if len(msgs) != 0 {
		t.Errorf("expected no messages for auto-approved tool, got %d", len(msgs))
	}
}

func TestBridge_SocketConnection_InvalidJSON(t *testing.T) {
	b, _, _ := newTestBridge(t)
	ctx := context.Background()

	hookConn, bridgeConn := net.Pipe()
	go b.handleSocketConnection(ctx, bridgeConn)

	// Send garbage
	hookConn.Write([]byte("not json\n"))

	var resp map[string]string
	json.NewDecoder(hookConn).Decode(&resp)
	hookConn.Close()

	if resp["error"] != "invalid request" {
		t.Errorf("expected 'invalid request' error, got %+v", resp)
	}
}

func TestBridge_SocketConnection_UnknownType(t *testing.T) {
	b, _, _ := newTestBridge(t)
	ctx := context.Background()

	hookConn, bridgeConn := net.Pipe()
	go b.handleSocketConnection(ctx, bridgeConn)

	req := SocketRequest{Type: "bogus"}
	json.NewEncoder(hookConn).Encode(req)

	var resp map[string]string
	json.NewDecoder(hookConn).Decode(&resp)
	hookConn.Close()

	if resp["error"] != "unknown request type" {
		t.Errorf("expected 'unknown request type', got %+v", resp)
	}
}

func TestBridge_SocketResume_RejectedWhileDraining(t *testing.T) {
	b, _, _ := newTestBridge(t)
	ctx := context.Background()

	b.draining.Store(true)

	hookConn, bridgeConn := net.Pipe()
	go b.handleSocketConnection(ctx, bridgeConn)

	req := SocketRequest{Type: "resume", RoomID: "!test:example.com", Message: "resume please"}
	json.NewEncoder(hookConn).Encode(req)

	var resp map[string]string
	json.NewDecoder(hookConn).Decode(&resp)
	hookConn.Close()

	if resp["status"] != "draining" {
		t.Errorf("expected 'draining' status, got %+v", resp)
	}
}

// --- Integration tests: resume breadcrumb ---
// Spec: upgrade_drain.feature — "New bridge reads and deletes the resume breadcrumb"

func TestCheckResumeBreadcrumb_NoBreadcrumb(t *testing.T) {
	b, mc, _ := newTestBridge(t)
	ctx := context.Background()

	// No breadcrumb file — should be a no-op
	b.checkResumeBreadcrumb(ctx)

	msgs := mc.getMessages()
	if len(msgs) != 0 {
		t.Errorf("expected no messages when no breadcrumb exists, got %d", len(msgs))
	}
}

func TestCheckResumeBreadcrumb_EmptyFile(t *testing.T) {
	b, mc, _ := newTestBridge(t)
	ctx := context.Background()

	// Write an empty breadcrumb
	resumePath := filepath.Join(b.dataDir, ".cranium-resume")
	os.WriteFile(resumePath, []byte(""), 0644)

	b.checkResumeBreadcrumb(ctx)

	msgs := mc.getMessages()
	if len(msgs) != 0 {
		t.Errorf("expected no messages for empty breadcrumb, got %d", len(msgs))
	}

	// File should still be deleted
	if _, err := os.Stat(resumePath); !os.IsNotExist(err) {
		t.Error("breadcrumb file should have been deleted")
	}
}

func TestCheckResumeBreadcrumb_RoomIDOnly(t *testing.T) {
	b, _, mci := newTestBridge(t)
	ctx := context.Background()
	roomID := "!infra:matrix.example.com"

	// Queue a Claude response for the resume invocation
	mci.QueueResponse(
		claudeAssistantMsg("sess-resume", "Resumed successfully!"),
		claudeResultMsg("sess-resume", "Resumed successfully!", 200000),
	)

	// Write breadcrumb with just room ID
	resumePath := filepath.Join(b.dataDir, ".cranium-resume")
	os.WriteFile(resumePath, []byte(roomID+"\n"), 0644)

	b.checkResumeBreadcrumb(ctx)

	// File should be deleted immediately
	if _, err := os.Stat(resumePath); !os.IsNotExist(err) {
		t.Error("breadcrumb file should have been deleted")
	}

	// Wait for the goroutine to invoke Claude
	time.Sleep(200 * time.Millisecond)

	invocations := mci.getInvocations()
	if len(invocations) != 1 {
		t.Fatalf("expected 1 Claude invocation, got %d", len(invocations))
	}

	// Should use the default resume message
	args := strings.Join(invocations[0].Args, " ")
	if !contains(args, "cranium bridge was restarted") {
		t.Errorf("expected default resume message in args, got: %v", invocations[0].Args)
	}
}

func TestCheckResumeBreadcrumb_WithCustomMessage(t *testing.T) {
	b, _, mci := newTestBridge(t)
	ctx := context.Background()
	roomID := "!infra:matrix.example.com"
	customMsg := "<system-reminder>Custom upgrade message</system-reminder>"

	mci.QueueResponse(
		claudeAssistantMsg("sess-resume2", "Back online!"),
		claudeResultMsg("sess-resume2", "Back online!", 200000),
	)

	// Write breadcrumb with room ID and custom message
	resumePath := filepath.Join(b.dataDir, ".cranium-resume")
	os.WriteFile(resumePath, []byte(roomID+"\n"+customMsg+"\n"), 0644)

	b.checkResumeBreadcrumb(ctx)
	time.Sleep(200 * time.Millisecond)

	invocations := mci.getInvocations()
	if len(invocations) != 1 {
		t.Fatalf("expected 1 Claude invocation, got %d", len(invocations))
	}

	// Should use the custom message, not the default
	args := strings.Join(invocations[0].Args, " ")
	if !contains(args, "Custom upgrade message") {
		t.Errorf("expected custom message in args, got: %v", invocations[0].Args)
	}
}

func TestCheckResumeBreadcrumb_SetsSessionID(t *testing.T) {
	b, _, mci := newTestBridge(t)
	ctx := context.Background()
	roomID := id.RoomID("!infra:matrix.example.com")

	mci.QueueResponse(
		claudeAssistantMsg("sess-new-resume", "Ready!"),
		claudeResultMsg("sess-new-resume", "Ready!", 200000),
	)

	resumePath := filepath.Join(b.dataDir, ".cranium-resume")
	os.WriteFile(resumePath, []byte(string(roomID)+"\n"), 0644)

	b.checkResumeBreadcrumb(ctx)
	time.Sleep(200 * time.Millisecond)

	// Session should be updated with the new session ID
	if got, ok := b.sessions.Get(roomID); !ok || got != "sess-new-resume" {
		t.Errorf("session ID = %q (ok=%v), want %q", got, ok, "sess-new-resume")
	}
}

func TestCheckResumeBreadcrumb_SendsResponse(t *testing.T) {
	b, mc, mci := newTestBridge(t)
	ctx := context.Background()
	roomID := id.RoomID("!infra:matrix.example.com")

	mci.QueueResponse(
		claudeAssistantMsg("sess-resp", "I'm back and ready!"),
		claudeResultMsg("sess-resp", "I'm back and ready!", 200000),
	)

	resumePath := filepath.Join(b.dataDir, ".cranium-resume")
	os.WriteFile(resumePath, []byte(string(roomID)+"\n"), 0644)

	b.checkResumeBreadcrumb(ctx)
	time.Sleep(200 * time.Millisecond)

	msgs := mc.getMessages()
	foundResponse := false
	for _, msg := range msgs {
		if msg.RoomID == roomID && contains(msg.Body, "I'm back and ready!") {
			foundResponse = true
		}
	}
	if !foundResponse {
		t.Errorf("expected response message in room %s, got messages: %+v", roomID, msgs)
	}
}

// Spec: upgrade_drain.feature — "Stale working indicator is cleaned up on resume"

func TestCheckResumeBreadcrumb_CleansUpStaleIndicator(t *testing.T) {
	b, mc, mci := newTestBridge(t)
	ctx := context.Background()
	roomID := id.RoomID("!infra:matrix.example.com")

	// Simulate a stale last message from the interrupted session
	b.sessions.SetLastMessage(roomID, "$stale-evt-123", "Previous response\n\n[Agent is still working...]")

	mci.QueueResponse(
		claudeAssistantMsg("sess-cleanup", "Resumed!"),
		claudeResultMsg("sess-cleanup", "Resumed!", 200000),
	)

	resumePath := filepath.Join(b.dataDir, ".cranium-resume")
	os.WriteFile(resumePath, []byte(string(roomID)+"\n"), 0644)

	b.checkResumeBreadcrumb(ctx)
	time.Sleep(200 * time.Millisecond)

	// Should have sent an edit to clean up the stale indicator
	msgs := mc.getMessages()
	foundEdit := false
	for _, msg := range msgs {
		if msg.IsEdit && msg.EventID == "$stale-evt-123" {
			foundEdit = true
		}
	}
	if !foundEdit {
		t.Error("expected an edit to clean up stale working indicator")
	}

	// The stale event ID should no longer be the last message — the resume
	// invocation sets a fresh one via invokeClaude's streaming path.
	if eid, _, ok := b.sessions.GetLastMessage(roomID); ok && eid == "$stale-evt-123" {
		t.Error("stale event ID should have been replaced after resume")
	}
}

func TestCheckResumeBreadcrumb_SkipsWhenRoomActive(t *testing.T) {
	b, _, mci := newTestBridge(t)
	ctx := context.Background()
	roomID := id.RoomID("!infra:matrix.example.com")

	// Mark room as already active
	b.activeRooms.Store(roomID, true)

	mci.QueueResponse(
		claudeAssistantMsg("sess-skip", "Should not happen"),
		claudeResultMsg("sess-skip", "Should not happen", 200000),
	)

	resumePath := filepath.Join(b.dataDir, ".cranium-resume")
	os.WriteFile(resumePath, []byte(string(roomID)+"\n"), 0644)

	b.checkResumeBreadcrumb(ctx)
	time.Sleep(200 * time.Millisecond)

	invocations := mci.getInvocations()
	if len(invocations) != 0 {
		t.Errorf("expected no Claude invocations when room is already active, got %d", len(invocations))
	}
}

// --- Post image tests ---

func TestMimeFromExtension(t *testing.T) {
	tests := []struct {
		ext  string
		want string
	}{
		{".png", "image/png"},
		{".PNG", "image/png"},
		{".jpg", "image/jpeg"},
		{".jpeg", "image/jpeg"},
		{".gif", "image/gif"},
		{".webp", "image/webp"},
		{".bmp", ""},
		{".txt", ""},
		{"", ""},
	}
	for _, tc := range tests {
		if got := mimeFromExtension(tc.ext); got != tc.want {
			t.Errorf("mimeFromExtension(%q) = %q, want %q", tc.ext, got, tc.want)
		}
	}
}

func TestBridge_PostImage_Success(t *testing.T) {
	b, mc, _ := newTestBridge(t)
	ctx := context.Background()

	// Set up room name lookup
	roomID := id.RoomID("!nerve:matrix.example.com")
	mc.joinedRooms = []id.RoomID{roomID}
	mc.roomNames[roomID] = "nerve"

	// Write a test image file
	imgPath := filepath.Join(b.dataDir, "test-image.png")
	os.WriteFile(imgPath, []byte("fake-png-data"), 0644)

	hookConn, bridgeConn := net.Pipe()
	go b.handleSocketConnection(ctx, bridgeConn)

	req := SocketRequest{Type: "post_image", Room: "nerve", Path: imgPath}
	json.NewEncoder(hookConn).Encode(req)

	var resp map[string]string
	json.NewDecoder(hookConn).Decode(&resp)
	hookConn.Close()

	if resp["status"] != "ok" {
		t.Fatalf("expected status=ok, got %+v", resp)
	}
	if resp["event_id"] == "" {
		t.Error("expected non-empty event_id")
	}

	// Verify a message was sent to the room
	msgs := mc.getMessages()
	found := false
	for _, msg := range msgs {
		if msg.RoomID == roomID {
			found = true
		}
	}
	if !found {
		t.Error("expected a message sent to the nerve room")
	}
}

func TestBridge_PostImage_MissingRoom(t *testing.T) {
	b, _, _ := newTestBridge(t)
	ctx := context.Background()

	hookConn, bridgeConn := net.Pipe()
	go b.handleSocketConnection(ctx, bridgeConn)

	req := SocketRequest{Type: "post_image", Room: "", Path: "/tmp/img.png"}
	json.NewEncoder(hookConn).Encode(req)

	var resp map[string]string
	json.NewDecoder(hookConn).Decode(&resp)
	hookConn.Close()

	if resp["error"] != "missing room name" {
		t.Errorf("expected 'missing room name', got %+v", resp)
	}
}

func TestBridge_PostImage_MissingPath(t *testing.T) {
	b, _, _ := newTestBridge(t)
	ctx := context.Background()

	hookConn, bridgeConn := net.Pipe()
	go b.handleSocketConnection(ctx, bridgeConn)

	req := SocketRequest{Type: "post_image", Room: "nerve", Path: ""}
	json.NewEncoder(hookConn).Encode(req)

	var resp map[string]string
	json.NewDecoder(hookConn).Decode(&resp)
	hookConn.Close()

	if resp["error"] != "missing file path" {
		t.Errorf("expected 'missing file path', got %+v", resp)
	}
}

func TestBridge_PostImage_UnsupportedFormat(t *testing.T) {
	b, _, _ := newTestBridge(t)
	ctx := context.Background()

	hookConn, bridgeConn := net.Pipe()
	go b.handleSocketConnection(ctx, bridgeConn)

	req := SocketRequest{Type: "post_image", Room: "nerve", Path: "/tmp/doc.pdf"}
	json.NewEncoder(hookConn).Encode(req)

	var resp map[string]string
	json.NewDecoder(hookConn).Decode(&resp)
	hookConn.Close()

	if !strings.Contains(resp["error"], "unsupported image format") {
		t.Errorf("expected unsupported format error, got %+v", resp)
	}
}

func TestBridge_PostImage_RoomNotFound(t *testing.T) {
	b, mc, _ := newTestBridge(t)
	ctx := context.Background()

	mc.joinedRooms = []id.RoomID{} // no rooms

	hookConn, bridgeConn := net.Pipe()
	go b.handleSocketConnection(ctx, bridgeConn)

	req := SocketRequest{Type: "post_image", Room: "nonexistent", Path: "/tmp/img.png"}
	json.NewEncoder(hookConn).Encode(req)

	var resp map[string]string
	json.NewDecoder(hookConn).Decode(&resp)
	hookConn.Close()

	if !strings.Contains(resp["error"], "room not found") {
		t.Errorf("expected room not found error, got %+v", resp)
	}
}

func TestBridge_PostImage_FileNotFound(t *testing.T) {
	b, mc, _ := newTestBridge(t)
	ctx := context.Background()

	roomID := id.RoomID("!nerve:matrix.example.com")
	mc.joinedRooms = []id.RoomID{roomID}
	mc.roomNames[roomID] = "nerve"

	hookConn, bridgeConn := net.Pipe()
	go b.handleSocketConnection(ctx, bridgeConn)

	req := SocketRequest{Type: "post_image", Room: "nerve", Path: "/tmp/no-such-file-29387.png"}
	json.NewEncoder(hookConn).Encode(req)

	var resp map[string]string
	json.NewDecoder(hookConn).Decode(&resp)
	hookConn.Close()

	if !strings.Contains(resp["error"], "failed to read file") {
		t.Errorf("expected file read error, got %+v", resp)
	}
}

func TestBridge_PostAudio_Success(t *testing.T) {
	b, mc, _ := newTestBridge(t)
	ctx := context.Background()

	roomID := id.RoomID("!nerve:matrix.example.com")
	mc.joinedRooms = []id.RoomID{roomID}
	mc.roomNames[roomID] = "nerve"

	audioPath := filepath.Join(b.dataDir, "test-audio.mp3")
	os.WriteFile(audioPath, []byte("fake-mp3-data"), 0644)

	hookConn, bridgeConn := net.Pipe()
	go b.handleSocketConnection(ctx, bridgeConn)

	req := SocketRequest{Type: "post_audio", Room: "nerve", Path: audioPath}
	json.NewEncoder(hookConn).Encode(req)

	var resp map[string]string
	json.NewDecoder(hookConn).Decode(&resp)
	hookConn.Close()

	if resp["status"] != "ok" {
		t.Fatalf("expected status=ok, got %+v", resp)
	}
	if resp["event_id"] == "" {
		t.Error("expected non-empty event_id")
	}

	msgs := mc.getMessages()
	found := false
	for _, msg := range msgs {
		if msg.RoomID == roomID {
			found = true
		}
	}
	if !found {
		t.Error("expected a message sent to the nerve room")
	}
}

func TestBridge_PostAudio_MissingRoom(t *testing.T) {
	b, _, _ := newTestBridge(t)
	ctx := context.Background()

	hookConn, bridgeConn := net.Pipe()
	go b.handleSocketConnection(ctx, bridgeConn)

	req := SocketRequest{Type: "post_audio", Room: "", Path: "/tmp/audio.mp3"}
	json.NewEncoder(hookConn).Encode(req)

	var resp map[string]string
	json.NewDecoder(hookConn).Decode(&resp)
	hookConn.Close()

	if resp["error"] != "missing room name" {
		t.Errorf("expected 'missing room name', got %+v", resp)
	}
}

func TestBridge_PostAudio_MissingPath(t *testing.T) {
	b, _, _ := newTestBridge(t)
	ctx := context.Background()

	hookConn, bridgeConn := net.Pipe()
	go b.handleSocketConnection(ctx, bridgeConn)

	req := SocketRequest{Type: "post_audio", Room: "nerve", Path: ""}
	json.NewEncoder(hookConn).Encode(req)

	var resp map[string]string
	json.NewDecoder(hookConn).Decode(&resp)
	hookConn.Close()

	if resp["error"] != "missing file path" {
		t.Errorf("expected 'missing file path', got %+v", resp)
	}
}

func TestBridge_PostAudio_UnsupportedFormat(t *testing.T) {
	b, _, _ := newTestBridge(t)
	ctx := context.Background()

	hookConn, bridgeConn := net.Pipe()
	go b.handleSocketConnection(ctx, bridgeConn)

	req := SocketRequest{Type: "post_audio", Room: "nerve", Path: "/tmp/doc.pdf"}
	json.NewEncoder(hookConn).Encode(req)

	var resp map[string]string
	json.NewDecoder(hookConn).Decode(&resp)
	hookConn.Close()

	if !strings.Contains(resp["error"], "unsupported audio format") {
		t.Errorf("expected unsupported format error, got %+v", resp)
	}
}

func TestBridge_PostAudio_RoomNotFound(t *testing.T) {
	b, mc, _ := newTestBridge(t)
	ctx := context.Background()

	mc.joinedRooms = []id.RoomID{}

	hookConn, bridgeConn := net.Pipe()
	go b.handleSocketConnection(ctx, bridgeConn)

	req := SocketRequest{Type: "post_audio", Room: "nonexistent", Path: "/tmp/audio.mp3"}
	json.NewEncoder(hookConn).Encode(req)

	var resp map[string]string
	json.NewDecoder(hookConn).Decode(&resp)
	hookConn.Close()

	if !strings.Contains(resp["error"], "room not found") {
		t.Errorf("expected room not found error, got %+v", resp)
	}
}

func TestBridge_PostAudio_FileNotFound(t *testing.T) {
	b, mc, _ := newTestBridge(t)
	ctx := context.Background()

	roomID := id.RoomID("!nerve:matrix.example.com")
	mc.joinedRooms = []id.RoomID{roomID}
	mc.roomNames[roomID] = "nerve"

	hookConn, bridgeConn := net.Pipe()
	go b.handleSocketConnection(ctx, bridgeConn)

	req := SocketRequest{Type: "post_audio", Room: "nerve", Path: "/tmp/no-such-file-29387.mp3"}
	json.NewEncoder(hookConn).Encode(req)

	var resp map[string]string
	json.NewDecoder(hookConn).Decode(&resp)
	hookConn.Close()

	if !strings.Contains(resp["error"], "failed to read file") {
		t.Errorf("expected file read error, got %+v", resp)
	}
}

// --- TTS tests ---

func TestBridge_TTS_Success(t *testing.T) {
	b, mc, _ := newTestBridge(t)
	ctx := context.Background()

	roomID := id.RoomID("!nerve:matrix.example.com")
	mc.joinedRooms = []id.RoomID{roomID}
	mc.roomNames[roomID] = "nerve"

	// Point config to a nonexistent path so hardcoded defaults are used
	origConfigPath := ttsConfigPath
	ttsConfigPath = func() string { return filepath.Join(b.dataDir, "no-such-tts.json") }
	defer func() { ttsConfigPath = origConfigPath }()

	// Set up a mock TTS server
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			t.Errorf("expected POST, got %s", r.Method)
		}
		if r.Header.Get("Content-Type") != "application/json" {
			t.Errorf("expected application/json content-type, got %s", r.Header.Get("Content-Type"))
		}
		var body map[string]string
		json.NewDecoder(r.Body).Decode(&body)
		if body["text"] != "Hello world" {
			t.Errorf("expected text 'Hello world', got %q", body["text"])
		}
		if body["voice"] != "af_nicole" {
			t.Errorf("expected voice 'af_nicole', got %q", body["voice"])
		}
		if body["format"] != "mp3" {
			t.Errorf("expected format 'mp3', got %q", body["format"])
		}
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("fake-audio-bytes"))
	}))
	defer ts.Close()

	origEndpoint := ttsEndpoint
	ttsEndpoint = ts.URL
	defer func() { ttsEndpoint = origEndpoint }()

	hookConn, bridgeConn := net.Pipe()
	go b.handleSocketConnection(ctx, bridgeConn)

	req := SocketRequest{Type: "tts", Room: "nerve", Text: "Hello world"}
	json.NewEncoder(hookConn).Encode(req)

	var resp map[string]string
	json.NewDecoder(hookConn).Decode(&resp)
	hookConn.Close()

	if resp["status"] != "ok" {
		t.Fatalf("expected status=ok, got %+v", resp)
	}
	if resp["event_id"] == "" {
		t.Error("expected non-empty event_id")
	}

	msgs := mc.getMessages()
	found := false
	for _, msg := range msgs {
		if msg.RoomID == roomID {
			found = true
		}
	}
	if !found {
		t.Error("expected a message sent to the nerve room")
	}
}

func TestBridge_TTS_CustomVoiceAndFormat(t *testing.T) {
	b, mc, _ := newTestBridge(t)
	ctx := context.Background()

	roomID := id.RoomID("!nerve:matrix.example.com")
	mc.joinedRooms = []id.RoomID{roomID}
	mc.roomNames[roomID] = "nerve"

	var gotVoice, gotFormat string
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]string
		json.NewDecoder(r.Body).Decode(&body)
		gotVoice = body["voice"]
		gotFormat = body["format"]
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("fake-wav-bytes"))
	}))
	defer ts.Close()

	origEndpoint := ttsEndpoint
	ttsEndpoint = ts.URL
	defer func() { ttsEndpoint = origEndpoint }()

	hookConn, bridgeConn := net.Pipe()
	go b.handleSocketConnection(ctx, bridgeConn)

	req := SocketRequest{Type: "tts", Room: "nerve", Text: "Test", Voice: "bf_emma", Format: "wav"}
	json.NewEncoder(hookConn).Encode(req)

	var resp map[string]string
	json.NewDecoder(hookConn).Decode(&resp)
	hookConn.Close()

	if resp["status"] != "ok" {
		t.Fatalf("expected status=ok, got %+v", resp)
	}
	if gotVoice != "bf_emma" {
		t.Errorf("expected voice 'bf_emma', got %q", gotVoice)
	}
	if gotFormat != "wav" {
		t.Errorf("expected format 'wav', got %q", gotFormat)
	}
}

func TestBridge_TTS_MissingRoom(t *testing.T) {
	b, _, _ := newTestBridge(t)
	ctx := context.Background()

	hookConn, bridgeConn := net.Pipe()
	go b.handleSocketConnection(ctx, bridgeConn)

	req := SocketRequest{Type: "tts", Room: "", Text: "Hello"}
	json.NewEncoder(hookConn).Encode(req)

	var resp map[string]string
	json.NewDecoder(hookConn).Decode(&resp)
	hookConn.Close()

	if resp["error"] != "missing room name" {
		t.Errorf("expected 'missing room name', got %+v", resp)
	}
}

func TestBridge_TTS_MissingText(t *testing.T) {
	b, _, _ := newTestBridge(t)
	ctx := context.Background()

	hookConn, bridgeConn := net.Pipe()
	go b.handleSocketConnection(ctx, bridgeConn)

	req := SocketRequest{Type: "tts", Room: "nerve", Text: ""}
	json.NewEncoder(hookConn).Encode(req)

	var resp map[string]string
	json.NewDecoder(hookConn).Decode(&resp)
	hookConn.Close()

	if resp["error"] != "missing text" {
		t.Errorf("expected 'missing text', got %+v", resp)
	}
}

func TestBridge_TTS_RoomNotFound(t *testing.T) {
	b, mc, _ := newTestBridge(t)
	ctx := context.Background()

	mc.joinedRooms = []id.RoomID{}

	hookConn, bridgeConn := net.Pipe()
	go b.handleSocketConnection(ctx, bridgeConn)

	req := SocketRequest{Type: "tts", Room: "nonexistent", Text: "Hello"}
	json.NewEncoder(hookConn).Encode(req)

	var resp map[string]string
	json.NewDecoder(hookConn).Decode(&resp)
	hookConn.Close()

	if !strings.Contains(resp["error"], "room not found") {
		t.Errorf("expected room not found error, got %+v", resp)
	}
}

func TestBridge_TTS_EndpointError(t *testing.T) {
	b, mc, _ := newTestBridge(t)
	ctx := context.Background()

	roomID := id.RoomID("!nerve:matrix.example.com")
	mc.joinedRooms = []id.RoomID{roomID}
	mc.roomNames[roomID] = "nerve"

	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		w.Write([]byte("model unavailable"))
	}))
	defer ts.Close()

	origEndpoint := ttsEndpoint
	ttsEndpoint = ts.URL
	defer func() { ttsEndpoint = origEndpoint }()

	hookConn, bridgeConn := net.Pipe()
	go b.handleSocketConnection(ctx, bridgeConn)

	req := SocketRequest{Type: "tts", Room: "nerve", Text: "Hello"}
	json.NewEncoder(hookConn).Encode(req)

	var resp map[string]string
	json.NewDecoder(hookConn).Decode(&resp)
	hookConn.Close()

	if !strings.Contains(resp["error"], "synthesis returned 500") {
		t.Errorf("expected synthesis error, got %+v", resp)
	}
}

func TestBridge_TTS_ConfigFileOverridesDefault(t *testing.T) {
	b, mc, _ := newTestBridge(t)
	ctx := context.Background()

	roomID := id.RoomID("!nerve:matrix.example.com")
	mc.joinedRooms = []id.RoomID{roomID}
	mc.roomNames[roomID] = "nerve"

	// Write a TTS config file
	configDir := filepath.Join(b.dataDir, "tts-config")
	os.MkdirAll(configDir, 0755)
	configPath := filepath.Join(configDir, "tts.json")
	os.WriteFile(configPath, []byte(`{"voice":"af_kore","format":"wav"}`), 0644)

	origConfigPath := ttsConfigPath
	ttsConfigPath = func() string { return configPath }
	defer func() { ttsConfigPath = origConfigPath }()

	var gotVoice, gotFormat string
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]string
		json.NewDecoder(r.Body).Decode(&body)
		gotVoice = body["voice"]
		gotFormat = body["format"]
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("fake-audio"))
	}))
	defer ts.Close()

	origEndpoint := ttsEndpoint
	ttsEndpoint = ts.URL
	defer func() { ttsEndpoint = origEndpoint }()

	hookConn, bridgeConn := net.Pipe()
	go b.handleSocketConnection(ctx, bridgeConn)

	// No voice/format specified — should come from config file
	req := SocketRequest{Type: "tts", Room: "nerve", Text: "Test config"}
	json.NewEncoder(hookConn).Encode(req)

	var resp map[string]string
	json.NewDecoder(hookConn).Decode(&resp)
	hookConn.Close()

	if resp["status"] != "ok" {
		t.Fatalf("expected status=ok, got %+v", resp)
	}
	if gotVoice != "af_kore" {
		t.Errorf("expected voice 'af_kore' from config, got %q", gotVoice)
	}
	if gotFormat != "wav" {
		t.Errorf("expected format 'wav' from config, got %q", gotFormat)
	}
}

func TestBridge_TTS_ExplicitArgOverridesConfig(t *testing.T) {
	b, mc, _ := newTestBridge(t)
	ctx := context.Background()

	roomID := id.RoomID("!nerve:matrix.example.com")
	mc.joinedRooms = []id.RoomID{roomID}
	mc.roomNames[roomID] = "nerve"

	// Config says af_kore, but the request will specify bf_emma
	configDir := filepath.Join(b.dataDir, "tts-config")
	os.MkdirAll(configDir, 0755)
	configPath := filepath.Join(configDir, "tts.json")
	os.WriteFile(configPath, []byte(`{"voice":"af_kore"}`), 0644)

	origConfigPath := ttsConfigPath
	ttsConfigPath = func() string { return configPath }
	defer func() { ttsConfigPath = origConfigPath }()

	var gotVoice string
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]string
		json.NewDecoder(r.Body).Decode(&body)
		gotVoice = body["voice"]
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("fake-audio"))
	}))
	defer ts.Close()

	origEndpoint := ttsEndpoint
	ttsEndpoint = ts.URL
	defer func() { ttsEndpoint = origEndpoint }()

	hookConn, bridgeConn := net.Pipe()
	go b.handleSocketConnection(ctx, bridgeConn)

	req := SocketRequest{Type: "tts", Room: "nerve", Text: "Test", Voice: "bf_emma"}
	json.NewEncoder(hookConn).Encode(req)

	var resp map[string]string
	json.NewDecoder(hookConn).Decode(&resp)
	hookConn.Close()

	if resp["status"] != "ok" {
		t.Fatalf("expected status=ok, got %+v", resp)
	}
	if gotVoice != "bf_emma" {
		t.Errorf("expected explicit voice 'bf_emma' to override config, got %q", gotVoice)
	}
}
