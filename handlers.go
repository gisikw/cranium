package main

import (
	"context"
	"fmt"
	"log"
	"time"

	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
)

func (b *Bridge) handleMessage(ctx context.Context, evt *event.Event) {
	log.Printf("Event received: type=%s sender=%s room=%s id=%s ts=%d", evt.Type.String(), evt.Sender, evt.RoomID, evt.ID, evt.Timestamp)

	// Deduplicate — Matrix syncer sometimes delivers the same event twice
	if _, seen := b.seenEvents.LoadOrStore(evt.ID, b.now()); seen {
		log.Printf("Ignoring duplicate event %s", evt.ID)
		return
	}

	// Ignore messages from before bridge started (prevents replaying history on connect)
	msgTime := time.UnixMilli(evt.Timestamp)
	if !isMessageAfterStartup(msgTime, b.startTime) {
		log.Printf("Ignoring old message (before bridge start)")
		return
	}

	// Ignore our own messages
	if evt.Sender == b.userID {
		log.Printf("Ignoring own message")
		return
	}

	// Don't accept new work while draining
	if b.draining.Load() {
		log.Printf("Draining — ignoring message from %s", evt.Sender)
		return
	}

	content := evt.Content.AsMessage()
	if content == nil {
		log.Printf("Failed to parse message content")
		return
	}

	roomID := evt.RoomID

	// Skip Claude invocation for excluded rooms (ops, project-*)
	if b.isExcludedRoom(ctx, roomID) {
		log.Printf("Ignoring message in excluded room %s", roomID)
		return
	}

	message := content.Body

	// Handle image messages: download and reference in prompt
	if content.MsgType == event.MsgImage {
		imagePath, err := b.saveMatrixImage(ctx, content)
		if err != nil {
			log.Printf("Failed to save image: %v", err)
			b.sendMessage(ctx, roomID, fmt.Sprintf("Failed to download image: %v", err))
			return
		}
		message = formatImagePrompt(imagePath, content.GetCaption())
	}

	// Handle audio messages: download, transcribe via STT, forward text
	if content.MsgType == event.MsgAudio {
		if b.sttURL == "" {
			log.Printf("Audio message received but no stt_url configured — ignoring")
			b.sendMessage(ctx, roomID, "Audio messages aren't supported yet (no STT service configured).")
			return
		}
		audioPath, err := b.saveMatrixAudio(ctx, content)
		if err != nil {
			log.Printf("Failed to save audio: %v", err)
			b.sendMessage(ctx, roomID, fmt.Sprintf("Failed to download audio: %v", err))
			return
		}
		log.Printf("Transcribing audio from %s via %s", audioPath, b.sttURL)
		transcription, err := transcribeAudio(b.sttURL, audioPath)
		if err != nil {
			log.Printf("Failed to transcribe audio: %v", err)
			b.sendMessage(ctx, roomID, fmt.Sprintf("Failed to transcribe audio: %v", err))
			return
		}
		if transcription != "" {
			b.sendThreadReply(ctx, roomID, evt.ID, formatTranscriptEcho(transcription))
		}
		message = formatAudioPrompt(transcription, content.GetCaption())
	}

	// Only handle text, image, and audio messages
	if !isSupportedMessageType(content.MsgType) {
		log.Printf("Ignoring unsupported message type: %s", content.MsgType)
		return
	}

	log.Printf("[%s] %s: %s", roomID, evt.Sender, message)

	// Handle special commands
	if cmd, args, isCmd := parseCommand(message); isCmd {
		switch cmd {
		case "clear":
			if _, active := b.activeRooms.Load(roomID); active {
				b.sendMessage(ctx, roomID, "Can't clear while a response is in progress. Try again in a moment.")
				return
			}
			sessionID, hasSession := b.sessions.Get(roomID)

			// Send a transient "Reloading..." notice and pin it
			transientID := b.sendNotice(ctx, roomID, "Reloading...")
			b.pinMessage(ctx, roomID, transientID)

			// Generate handoff if we have a session
			if hasSession && sessionID != "" {
				if err := b.generateHandoff(ctx, roomID, sessionID); err != nil {
					log.Printf("Handoff generation failed: %v", err)
					// On error, update the transient message briefly before cleanup
					b.editNotice(ctx, roomID, transientID, fmt.Sprintf("Handoff failed (%v), clearing anyway.", err))
					time.Sleep(2 * time.Second)
				}
			}

			// Unpin the context indicator (separate from transient message)
			b.unpinContext(ctx, roomID)

			// Clear session state
			b.sessions.Set(roomID, "")
			b.sessions.ClearLastMessage(roomID)
			b.sessions.ClearSystemPromptFile(roomID)
			b.sessions.ResetTurns(roomID)

			// Remove the transient message
			b.unpinMessage(ctx, roomID)
			b.redactMessage(ctx, roomID, transientID)
			return
		case "new":
			if args == "" {
				b.sendMessage(ctx, roomID, "Usage: `!new <room-name>`")
				return
			}
			b.handleNewRoom(ctx, roomID, evt.Sender, args)
			return
		case "usage":
			go b.handleUsageCommand(ctx, roomID)
			return
		}
	}

	// Skip if there's already an active invocation for this room
	if _, active := b.activeRooms.Load(roomID); active {
		log.Printf("Skipping duplicate message — room %s already has active invocation", roomID)
		return
	}

	// Fire off read receipt and start a typing indicator loop that renews
	// every 15s until Claude responds. This ensures the indicator stays
	// visible even during long cold starts (~30s+).
	typingDone := make(chan struct{})
	go func() {
		select {
		case <-typingDone:
			return
		case <-time.After(b.typingReadDelay):
		}
		b.client.MarkRead(ctx, roomID, evt.ID)
		select {
		case <-typingDone:
			return
		case <-time.After(b.typingStartDelay):
		}

		if _, err := b.client.UserTyping(ctx, roomID, true, 30*time.Second); err != nil {
			log.Printf("Typing indicator failed for %s: %v", roomID, err)
		}

		ticker := time.NewTicker(15 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-typingDone:
				return
			case <-ticker.C:
				if _, err := b.client.UserTyping(ctx, roomID, true, 30*time.Second); err != nil {
					log.Printf("Typing indicator renewal failed for %s: %v", roomID, err)
				}
			}
		}
	}()

	// Track active invocations for graceful drain and room-level dedup
	b.activeInvocations.Add(1)
	b.activeRooms.Store(roomID, true)
	invokeCtx, invokeCancel := context.WithCancel(ctx)
	b.roomCancels.Store(roomID, invokeCancel)
	defer func() {
		invokeCancel()
		b.roomCancels.Delete(roomID)
		b.activeRooms.Delete(roomID)
		b.activeInvocations.Done()
	}()

	// Invoke Claude
	response, newSessionID, ctxInfo, partialSections, err := b.invokeClaude(invokeCtx, roomID, message)

	// Stop typing indicator
	close(typingDone)
	b.client.UserTyping(ctx, roomID, false, 0)

	stopped := invokeCtx.Err() != nil

	if stopped {
		log.Printf("Invocation in room %s was stopped via emoji", roomID)
		// Clean up the working indicator from the last edit-in-place message
		if lastEventID, lastMsg, ok := b.sessions.GetLastMessage(roomID); ok && lastEventID != "" {
			b.editMessage(ctx, roomID, id.EventID(lastEventID), lastMsg)
			b.sessions.ClearLastMessage(roomID)
		}
		b.sendMessage(ctx, roomID, "*Stopped.*")
		// Capture partial output for next invocation
		if len(partialSections) > 0 {
			summary := buildInterruptedSummary(partialSections, 2000)
			b.sessions.SetInterruptedContext(roomID, summary)
			log.Printf("Captured interrupted context for room %s (%d sections, %d chars)", roomID, len(partialSections), len(summary))
		}
		// Still save the session ID so we can resume later
		if newSessionID != "" {
			b.sessions.Set(roomID, newSessionID)
			b.sessions.MarkInvoked(newSessionID)
		}
		return
	}

	if err != nil {
		log.Printf("Claude error: %v", err)
		b.sendMessage(ctx, roomID, fmt.Sprintf("Error: %v", err))
		return
	}

	// Update session ID if we got a new one
	if newSessionID != "" {
		b.sessions.Set(roomID, newSessionID)
		b.sessions.MarkInvoked(newSessionID)
	}

	// Send response (if invokeClaude didn't already stream it)
	if response != "" {
		b.sendMessage(ctx, roomID, response)
	}

	// Track turns for summary generation (cross-room awareness)
	turns := b.sessions.IncrementTurns(roomID)
	if shouldGenerateSummary(turns, b.summaryThreshold) {
		log.Printf("Room %s reached %d turns — triggering summary generation", roomID, turns)
		go b.generateSummary(ctx, roomID)
	}

	// Update last-message timestamp in summary file (best-effort)
	go func() {
		roomName := b.getRoomName(ctx, roomID)
		slug := slugify(roomName)
		if slug == "" {
			return
		}
		if existing, err := b.loadRoomSummary(slug); err == nil {
			existing.LastMessageTS = time.Now().Unix()
			existing.TurnsSinceSummary = b.sessions.GetTurns(roomID)
			b.saveRoomSummary(slug, existing)
		}
	}()

	// Context window saturation tracking and indicator
	if ctxInfo.ContextWindow > 0 {
		saturation := ctxInfo.Saturation()
		usedK := ctxInfo.UsedTokens / 1000
		totalK := ctxInfo.ContextWindow / 1000
		prevSaturation := b.sessions.GetLastSaturation(roomID)
		log.Printf("Context saturation for room %s: %d%% (%dk / %dk tokens)", roomID, saturation, usedK, totalK)

		// Detect compaction: saturation dropped significantly while we had a pin
		_, hasPinned := b.sessions.GetPinnedEvent(roomID)
		if detectCompaction(prevSaturation, saturation, hasPinned) {
			log.Printf("Compaction detected in room %s: saturation dropped from %d%% to %d%%", roomID, prevSaturation, saturation)
			b.unpinContext(ctx, roomID)
			b.sendMessage(ctx, roomID, fmt.Sprintf("Heads up: context was auto-compacted (dropped from %d%% to %d%%). Some earlier context may have been summarized or lost. Consider `!clear` for a clean handoff if things feel off.", prevSaturation, saturation))
		}

		b.sessions.SetLastSaturation(roomID, saturation)
		b.updateContextPin(ctx, roomID, saturation, usedK, totalK)
	}
}
