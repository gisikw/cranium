package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"

	"maunium.net/go/mautrix"
	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
)

// handleNewRoom creates an unencrypted room, invites the requesting user, and confirms.
func (b *Bridge) handleNewRoom(ctx context.Context, fromRoom id.RoomID, sender id.UserID, name string) {
	resp, err := b.client.CreateRoom(ctx, &mautrix.ReqCreateRoom{
		Name:   name,
		Preset: "private_chat",
		Invite: []id.UserID{sender},
		PowerLevelOverride: &event.PowerLevelsEventContent{
			Users: map[id.UserID]int{
				b.userID: 100, // retain creator power for pinning, topic, etc.
				sender:   100, // give the invitee full admin too
			},
		},
	})
	if err != nil {
		log.Printf("Failed to create room %q: %v", name, err)
		b.sendMessage(ctx, fromRoom, fmt.Sprintf("Failed to create room: %v", err))
		return
	}
	log.Printf("Created room %q (%s), invited %s", name, resp.RoomID, sender)
	b.sendMessage(ctx, fromRoom, fmt.Sprintf("Created **%s** and sent you an invite.", name))
}

func (b *Bridge) handleInvite(ctx context.Context, evt *event.Event) {
	log.Printf("Invited to room %s by %s", evt.RoomID, evt.Sender)

	// Auto-join all rooms
	_, err := b.client.JoinRoomByID(ctx, evt.RoomID)
	if err != nil {
		log.Printf("Failed to join room %s: %v", evt.RoomID, err)
		return
	}
	log.Printf("Joined room %s", evt.RoomID)

	// Check if we have moderator power (PL 50+) for pinning messages.
	// Rooms created via /new set this automatically; manually-created rooms may not.
	var pl event.PowerLevelsEventContent
	if err := b.client.StateEvent(ctx, evt.RoomID, event.StatePowerLevels, "", &pl); err != nil {
		log.Printf("Failed to check power levels in %s: %v", evt.RoomID, err)
		return
	}
	myPower := pl.GetUserLevel(b.userID)
	if myPower < 50 {
		log.Printf("Insufficient power level (%d) in room %s, sending nudge", myPower, evt.RoomID)
		b.sendMessage(ctx, evt.RoomID, "Heads up: I need **Moderator** (power level 50+) in this room to pin context-window indicators. You can set this in room settings → Roles & Permissions.")
	}
}

// saveMatrixImage downloads an image from Matrix and saves it to notes/attachments/
func (b *Bridge) saveMatrixImage(ctx context.Context, content *event.MessageEventContent) (string, error) {
	var imageBytes []byte

	if content.File != nil {
		// Encrypted attachment: URL is in File, data needs decryption
		mxcURL, err := content.File.URL.Parse()
		if err != nil {
			return "", fmt.Errorf("failed to parse encrypted MXC URL: %w", err)
		}
		imageBytes, err = b.client.DownloadBytes(ctx, mxcURL)
		if err != nil {
			return "", fmt.Errorf("failed to download encrypted image: %w", err)
		}
		if err := content.File.DecryptInPlace(imageBytes); err != nil {
			return "", fmt.Errorf("failed to decrypt image: %w", err)
		}
	} else {
		// Unencrypted attachment
		mxcURL, err := content.URL.Parse()
		if err != nil {
			return "", fmt.Errorf("failed to parse MXC URL: %w", err)
		}
		imageBytes, err = b.client.DownloadBytes(ctx, mxcURL)
		if err != nil {
			return "", fmt.Errorf("failed to download image: %w", err)
		}
	}

	// Determine file extension from MIME type or original filename
	origName := content.GetFileName()
	ext := filepath.Ext(origName)
	if ext == "" && content.Info != nil {
		switch content.Info.MimeType {
		case "image/png":
			ext = ".png"
		case "image/jpeg":
			ext = ".jpg"
		case "image/gif":
			ext = ".gif"
		case "image/webp":
			ext = ".webp"
		default:
			ext = ".png"
		}
	}

	// Save to attachments directory
	attachDir := b.attachmentsDir
	os.MkdirAll(attachDir, 0755)

	filename := fmt.Sprintf("%s_%s%s",
		time.Now().Format("2006-01-02_15-04-05"),
		strings.TrimSuffix(origName, filepath.Ext(origName)),
		ext,
	)
	savePath := filepath.Join(attachDir, filename)

	if err := os.WriteFile(savePath, imageBytes, 0644); err != nil {
		return "", fmt.Errorf("failed to write image: %w", err)
	}

	log.Printf("Saved image to %s (%d bytes)", savePath, len(imageBytes))
	return savePath, nil
}

// updateContextPin creates or updates the pinned context saturation indicator.
// First pin at 60%; subsequent turns edit the pinned message silently.
func (b *Bridge) updateContextPin(ctx context.Context, roomID id.RoomID, saturation, usedK, totalK int) {
	if saturation < 60 {
		return
	}

	body := fmt.Sprintf("Context: %d%% (%dk / %dk tokens)", saturation, usedK, totalK)

	pinnedID, hasPinned := b.sessions.GetPinnedEvent(roomID)
	if hasPinned {
		// Edit existing pinned message (silent — no notification)
		content := event.MessageEventContent{
			MsgType: event.MsgNotice,
			Body:    body,
		}
		content.SetEdit(id.EventID(pinnedID))
		_, err := b.client.SendMessageEvent(ctx, roomID, event.EventMessage, content)
		if err != nil {
			log.Printf("Failed to edit context pin in %s: %v", roomID, err)
		}
		return
	}

	// Send a new notice and pin it
	content := event.MessageEventContent{
		MsgType: event.MsgNotice,
		Body:    body,
	}
	resp, err := b.client.SendMessageEvent(ctx, roomID, event.EventMessage, content)
	if err != nil {
		log.Printf("Failed to send context indicator to %s: %v", roomID, err)
		return
	}

	// Pin the message
	_, err = b.client.SendStateEvent(ctx, roomID, event.StatePinnedEvents, "", map[string]interface{}{
		"pinned": []string{string(resp.EventID)},
	})
	if err != nil {
		log.Printf("Failed to pin context indicator in %s (need Moderator power level): %v", roomID, err)
		// Check if this is a permission error and alert the user
		errStr := strings.ToLower(err.Error())
		if strings.Contains(errStr, "forbidden") {
			// Only alert once per room per bridge lifetime
			if _, alerted := b.pinPermissionAlerted.Load(roomID); !alerted {
				b.sendMessage(ctx, roomID, "Heads up: I need **Moderator** (power level 50+) in this room to pin context-window indicators. You can set this in room settings → Roles & Permissions.")
				b.pinPermissionAlerted.Store(roomID, true)
			}
		}
		// Still track the event ID so we can edit it even if pinning failed
	}
	b.sessions.SetPinnedEvent(roomID, string(resp.EventID))
	log.Printf("Created context pin %s in room %s at %d%%", resp.EventID, roomID, saturation)
}

// unpinContext removes the pinned context indicator on session clear.
func (b *Bridge) unpinContext(ctx context.Context, roomID id.RoomID) {
	pinnedID, hasPinned := b.sessions.GetPinnedEvent(roomID)
	if !hasPinned {
		return
	}

	// Unpin by setting empty pinned list
	_, err := b.client.SendStateEvent(ctx, roomID, event.StatePinnedEvents, "", map[string]interface{}{
		"pinned": []string{},
	})
	if err != nil {
		log.Printf("Failed to unpin context indicator in %s: %v", roomID, err)
		// Check if this is a permission error and alert the user
		errStr := strings.ToLower(err.Error())
		if strings.Contains(errStr, "forbidden") {
			// Only alert once per room per bridge lifetime
			if _, alerted := b.pinPermissionAlerted.Load(roomID); !alerted {
				b.sendMessage(ctx, roomID, "Heads up: I need **Moderator** (power level 50+) in this room to pin context-window indicators. You can set this in room settings → Roles & Permissions.")
				b.pinPermissionAlerted.Store(roomID, true)
			}
		}
	}

	// Redact the indicator message
	_, err = b.client.RedactEvent(ctx, roomID, id.EventID(pinnedID))
	if err != nil {
		log.Printf("Failed to redact context indicator %s in %s: %v", pinnedID, roomID, err)
	}

	b.sessions.ClearPinnedEvent(roomID)
	log.Printf("Cleared context pin in room %s", roomID)
}
