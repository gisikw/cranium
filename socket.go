package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"os"
	"path/filepath"
	"strings"

	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
)

// SocketRequest is the envelope for all socket messages
type SocketRequest struct {
	Type string `json:"type"` // "approval", "resume", "breadcrumb", "post_image", or "post_audio"

	// Approval fields
	SessionID string                 `json:"session_id,omitempty"`
	ToolName  string                 `json:"tool_name,omitempty"`
	ToolInput map[string]interface{} `json:"tool_input,omitempty"`

	// Resume fields
	RoomID  string `json:"room_id,omitempty"`
	Message string `json:"message,omitempty"`

	// Post image fields
	Room string `json:"room,omitempty"` // room name (not ID)
	Path string `json:"path,omitempty"` // local file path
}

// startSocketListener starts the unix socket for hook requests
func (b *Bridge) startSocketListener(ctx context.Context) error {
	// Remove existing socket
	os.Remove(b.socketPath)

	listener, err := net.Listen("unix", b.socketPath)
	if err != nil {
		return fmt.Errorf("failed to listen on socket: %w", err)
	}

	// Make socket world-writable so hook can connect
	os.Chmod(b.socketPath, 0666)

	log.Printf("Listening on %s", b.socketPath)

	go func() {
		<-ctx.Done()
		listener.Close()
		os.Remove(b.socketPath)
	}()

	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				if ctx.Err() != nil {
					return
				}
				log.Printf("Socket accept error: %v", err)
				continue
			}
			go b.handleSocketConnection(ctx, conn)
		}
	}()

	return nil
}

// handleSocketConnection handles a single hook connection
func (b *Bridge) handleSocketConnection(ctx context.Context, conn net.Conn) {
	defer conn.Close()

	decoder := json.NewDecoder(conn)
	var req SocketRequest
	if err := decoder.Decode(&req); err != nil {
		log.Printf("Failed to decode socket request: %v", err)
		json.NewEncoder(conn).Encode(map[string]string{"error": "invalid request"})
		return
	}

	// Default type is "approval" for backwards compatibility with older hook clients
	if req.Type == "" || req.Type == "approval" {
		approvalReq := ApprovalRequest{
			SessionID: req.SessionID,
			ToolName:  req.ToolName,
			ToolInput: req.ToolInput,
		}
		log.Printf("Approval request: session=%s tool=%s", approvalReq.SessionID, approvalReq.ToolName)

		response := b.requestApproval(ctx, approvalReq)
		log.Printf("Approval response: decision=%s message=%s", response.Decision, response.Message)

		if err := json.NewEncoder(conn).Encode(response); err != nil {
			log.Printf("Failed to send socket response: %v", err)
		}
		return
	}

	if req.Type == "resume" {
		if b.draining.Load() {
			log.Printf("Resume request rejected — bridge is draining")
			json.NewEncoder(conn).Encode(map[string]string{"status": "draining"})
			return
		}
		b.handleResumeRequest(ctx, conn, req)
		return
	}

	if req.Type == "breadcrumb" {
		b.handleBreadcrumbRequest(ctx, conn, req)
		return
	}

	if req.Type == "post_image" {
		b.handlePostImageRequest(ctx, conn, req)
		return
	}

	if req.Type == "post_audio" {
		b.handlePostAudioRequest(ctx, conn, req)
		return
	}

	log.Printf("Unknown socket request type: %s", req.Type)
	json.NewEncoder(conn).Encode(map[string]string{"error": "unknown request type"})
}

// handleResumeRequest synthesizes a message to re-invoke Claude for a room
func (b *Bridge) handleResumeRequest(ctx context.Context, conn net.Conn, req SocketRequest) {
	roomID := id.RoomID(req.RoomID)
	if roomID == "" {
		log.Printf("Resume request missing room_id")
		json.NewEncoder(conn).Encode(map[string]string{"error": "missing room_id"})
		return
	}

	message := req.Message
	if message == "" {
		message = buildResumeMessage("")
	}

	// Skip if there's already an active invocation for this room
	if _, active := b.activeRooms.Load(roomID); active {
		log.Printf("Resume request skipped — room %s already has active invocation", roomID)
		json.NewEncoder(conn).Encode(map[string]string{"status": "skipped", "reason": "room already active"})
		return
	}

	log.Printf("Resume request for room %s", roomID)
	json.NewEncoder(conn).Encode(map[string]string{"status": "accepted"})

	b.invokeResumeInBackground(ctx, roomID, message)
}

// handleBreadcrumbRequest generates an enriched resume message for a room.
// This is called by the upgrade script to get context-aware resume messages.
func (b *Bridge) handleBreadcrumbRequest(ctx context.Context, conn net.Conn, req SocketRequest) {
	roomID := id.RoomID(req.RoomID)
	if roomID == "" {
		log.Printf("Breadcrumb request missing room_id")
		json.NewEncoder(conn).Encode(map[string]string{"error": "missing room_id"})
		return
	}

	log.Printf("Breadcrumb request for room %s — fetching recent messages", roomID)
	message := b.buildEnrichedResumeBreadcrumb(ctx, roomID)

	response := map[string]string{
		"status":  "ok",
		"message": message,
	}

	if err := json.NewEncoder(conn).Encode(response); err != nil {
		log.Printf("Failed to send breadcrumb response: %v", err)
	}
}

// checkResumeBreadcrumb looks for a .cranium-resume file left by the upgrade
// script and, if found, triggers a resume invocation for the specified room.
func (b *Bridge) checkResumeBreadcrumb(ctx context.Context) {
	resumePath := filepath.Join(b.dataDir, ".cranium-resume")
	data, err := os.ReadFile(resumePath)
	if err != nil {
		return // no breadcrumb, nothing to do
	}
	os.Remove(resumePath)

	lines := strings.SplitN(string(data), "\n", 2)
	if len(lines) < 1 || lines[0] == "" {
		log.Printf("Resume breadcrumb was empty, ignoring")
		return
	}

	roomID := id.RoomID(strings.TrimSpace(lines[0]))
	message := buildResumeMessage("")
	if len(lines) > 1 && strings.TrimSpace(lines[1]) != "" {
		message = strings.TrimSpace(lines[1])
	}

	log.Printf("Found resume breadcrumb for room %s — triggering resume", roomID)

	// Clean up stale working indicator from the interrupted message
	if lastEventID, lastMsg, ok := b.sessions.GetLastMessage(roomID); ok && lastEventID != "" {
		log.Printf("Cleaning up stale working indicator on event %s", lastEventID)
		b.editMessage(ctx, roomID, id.EventID(lastEventID), lastMsg)
		b.sessions.ClearLastMessage(roomID)
	}

	b.invokeResumeInBackground(ctx, roomID, message)
}

// mimeFromExtension returns the MIME type for a given file extension.
// Returns empty string for unsupported extensions.
func mimeFromExtension(ext string) string {
	switch strings.ToLower(ext) {
	case ".png":
		return "image/png"
	case ".jpg", ".jpeg":
		return "image/jpeg"
	case ".gif":
		return "image/gif"
	case ".webp":
		return "image/webp"
	default:
		return ""
	}
}

// handlePostImageRequest uploads a local image file and sends it to a Matrix room.
func (b *Bridge) handlePostImageRequest(ctx context.Context, conn net.Conn, req SocketRequest) {
	if req.Room == "" {
		log.Printf("Post image request missing room name")
		json.NewEncoder(conn).Encode(map[string]string{"error": "missing room name"})
		return
	}
	if req.Path == "" {
		log.Printf("Post image request missing file path")
		json.NewEncoder(conn).Encode(map[string]string{"error": "missing file path"})
		return
	}

	// Validate file extension before reading
	ext := filepath.Ext(req.Path)
	contentType := mimeFromExtension(ext)
	if contentType == "" {
		log.Printf("Post image: unsupported format %q", ext)
		json.NewEncoder(conn).Encode(map[string]string{"error": fmt.Sprintf("unsupported image format: %s", ext)})
		return
	}

	// Look up room by name
	roomID := b.findRoomByName(ctx, req.Room)
	if roomID == "" {
		log.Printf("Post image: room %q not found", req.Room)
		json.NewEncoder(conn).Encode(map[string]string{"error": fmt.Sprintf("room not found: %s", req.Room)})
		return
	}

	// Read file from disk
	imageBytes, err := os.ReadFile(req.Path)
	if err != nil {
		log.Printf("Post image: failed to read file %s: %v", req.Path, err)
		json.NewEncoder(conn).Encode(map[string]string{"error": fmt.Sprintf("failed to read file: %v", err)})
		return
	}

	// Upload to Matrix
	fileName := filepath.Base(req.Path)
	uploadResp, err := b.client.UploadBytesWithName(ctx, imageBytes, contentType, fileName)
	if err != nil {
		log.Printf("Post image: upload failed: %v", err)
		json.NewEncoder(conn).Encode(map[string]string{"error": fmt.Sprintf("upload failed: %v", err)})
		return
	}

	// Send m.image event
	content := map[string]interface{}{
		"msgtype": "m.image",
		"body":    fileName,
		"url":     uploadResp.ContentURI.CUString(),
		"info": map[string]interface{}{
			"mimetype": contentType,
			"size":     len(imageBytes),
		},
	}

	resp, err := b.client.SendMessageEvent(ctx, roomID, event.EventMessage, content)
	if err != nil {
		log.Printf("Post image: failed to send event: %v", err)
		json.NewEncoder(conn).Encode(map[string]string{"error": fmt.Sprintf("failed to send image: %v", err)})
		return
	}

	log.Printf("Posted image %s to room %s (%s): event %s", fileName, req.Room, roomID, resp.EventID)
	json.NewEncoder(conn).Encode(map[string]string{
		"status":   "ok",
		"event_id": string(resp.EventID),
	})
}

// audioMimeFromExtension returns the MIME type for a given audio file extension.
// Returns empty string for unsupported extensions.
func audioMimeFromExtension(ext string) string {
	switch strings.ToLower(ext) {
	case ".mp3":
		return "audio/mpeg"
	case ".wav":
		return "audio/wav"
	case ".ogg", ".oga":
		return "audio/ogg"
	case ".flac":
		return "audio/flac"
	case ".m4a", ".aac":
		return "audio/mp4"
	case ".opus":
		return "audio/opus"
	case ".webm":
		return "audio/webm"
	default:
		return ""
	}
}

// handlePostAudioRequest uploads a local audio file and sends it to a Matrix room.
func (b *Bridge) handlePostAudioRequest(ctx context.Context, conn net.Conn, req SocketRequest) {
	if req.Room == "" {
		log.Printf("Post audio request missing room name")
		json.NewEncoder(conn).Encode(map[string]string{"error": "missing room name"})
		return
	}
	if req.Path == "" {
		log.Printf("Post audio request missing file path")
		json.NewEncoder(conn).Encode(map[string]string{"error": "missing file path"})
		return
	}

	// Validate file extension before reading
	ext := filepath.Ext(req.Path)
	contentType := audioMimeFromExtension(ext)
	if contentType == "" {
		log.Printf("Post audio: unsupported format %q", ext)
		json.NewEncoder(conn).Encode(map[string]string{"error": fmt.Sprintf("unsupported audio format: %s", ext)})
		return
	}

	// Look up room by name
	roomID := b.findRoomByName(ctx, req.Room)
	if roomID == "" {
		log.Printf("Post audio: room %q not found", req.Room)
		json.NewEncoder(conn).Encode(map[string]string{"error": fmt.Sprintf("room not found: %s", req.Room)})
		return
	}

	// Read file from disk
	audioBytes, err := os.ReadFile(req.Path)
	if err != nil {
		log.Printf("Post audio: failed to read file %s: %v", req.Path, err)
		json.NewEncoder(conn).Encode(map[string]string{"error": fmt.Sprintf("failed to read file: %v", err)})
		return
	}

	// Upload to Matrix
	fileName := filepath.Base(req.Path)
	uploadResp, err := b.client.UploadBytesWithName(ctx, audioBytes, contentType, fileName)
	if err != nil {
		log.Printf("Post audio: upload failed: %v", err)
		json.NewEncoder(conn).Encode(map[string]string{"error": fmt.Sprintf("upload failed: %v", err)})
		return
	}

	// Send m.audio event
	content := map[string]interface{}{
		"msgtype": "m.audio",
		"body":    fileName,
		"url":     uploadResp.ContentURI.CUString(),
		"info": map[string]interface{}{
			"mimetype": contentType,
			"size":     len(audioBytes),
		},
	}

	resp, err := b.client.SendMessageEvent(ctx, roomID, event.EventMessage, content)
	if err != nil {
		log.Printf("Post audio: failed to send event: %v", err)
		json.NewEncoder(conn).Encode(map[string]string{"error": fmt.Sprintf("failed to send audio: %v", err)})
		return
	}

	log.Printf("Posted audio %s to room %s (%s): event %s", fileName, req.Room, roomID, resp.EventID)
	json.NewEncoder(conn).Encode(map[string]string{
		"status":   "ok",
		"event_id": string(resp.EventID),
	})
}

// invokeResumeInBackground launches a Claude invocation for a resume request.
// It handles room activation tracking, session management, and response delivery.
func (b *Bridge) invokeResumeInBackground(ctx context.Context, roomID id.RoomID, message string) {
	go func() {
		if _, alreadyActive := b.activeRooms.LoadOrStore(roomID, true); alreadyActive {
			log.Printf("Room %s already has active invocation, skipping resume", roomID)
			return
		}
		b.activeInvocations.Add(1)
		defer func() {
			b.activeRooms.Delete(roomID)
			b.activeInvocations.Done()
		}()

		response, newSessionID, _, _, err := b.invokeClaude(ctx, roomID, message)
		b.client.UserTyping(ctx, roomID, false, 0)

		if err != nil {
			log.Printf("Resume invoke error: %v", err)
			b.sendMessage(ctx, roomID, fmt.Sprintf("Error resuming: %v", err))
			return
		}

		if newSessionID != "" {
			b.sessions.Set(roomID, newSessionID)
			b.sessions.MarkInvoked(newSessionID)
		}

		if response != "" {
			b.sendMessage(ctx, roomID, response)
		}

		log.Printf("Resume invoke complete for room %s", roomID)
	}()
}
