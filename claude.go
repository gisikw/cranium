package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"maunium.net/go/mautrix/id"
)

func (b *Bridge) invokeClaude(ctx context.Context, roomID id.RoomID, message string) (string, string, ContextInfo, []string, error) {
	// Gather data for invocation plan
	sessionID, hasSession := b.sessions.Get(roomID)
	isFreshSession := !hasSession || sessionID == ""
	roomName := b.getRoomName(ctx, roomID)

	// Load handoff content for fresh sessions (I/O, not part of pure decision logic)
	var handoffContent string
	if isFreshSession && roomName != "" {
		slug := slugify(roomName)
		handoffDir := filepath.Join(b.dataDir, "handoffs", slug)
		if entries, err := os.ReadDir(handoffDir); err == nil {
			var latest string
			for _, e := range entries {
				if !e.IsDir() && strings.HasSuffix(e.Name(), ".md") {
					if e.Name() > latest {
						latest = e.Name()
					}
				}
			}
			if latest != "" {
				handoffPath := filepath.Join(handoffDir, latest)
				if data, err := os.ReadFile(handoffPath); err == nil && len(data) > 0 {
					handoffContent = string(data)
					log.Printf("Loaded handoff for room %q from %s (%d bytes)", roomName, handoffPath, len(handoffContent))
				}
			}
		}
	}

	// Compute landscape for time gap or fresh session
	var timeSinceLast time.Duration
	var landscape string
	if !isFreshSession {
		if elapsed, ok := b.sessions.TimeSinceLastInvoked(sessionID); ok {
			timeSinceLast = elapsed
			if shouldInjectTimeGap(elapsed) {
				landscape = b.formatSummaryLandscape(roomID, timeGapMaxAge(elapsed))
			}
		}
	} else {
		landscape = b.formatSummaryLandscape(roomID, 0)
		if landscape != "" {
			log.Printf("Injected cross-room context for fresh session in room %s", roomID)
		}
	}

	// Load interrupted context (if any) and clear it (one-shot usage)
	var interruptedContext string
	if ictx, hasInterrupted := b.sessions.GetInterruptedContext(roomID); hasInterrupted {
		interruptedContext = ictx
		b.sessions.ClearInterruptedContext(roomID)
		log.Printf("Loaded interrupted context for room %s (%d chars)", roomID, len(interruptedContext))
	}

	// Check if room name matches a project directory
	var projectDir string
	if roomName != "" && b.projectsDir != "" {
		slug := slugify(roomName)
		candidate := filepath.Join(b.projectsDir, slug)
		if info, err := os.Stat(candidate); err == nil && info.IsDir() {
			projectDir = candidate
			log.Printf("Matched room %q to project directory: %s", roomName, projectDir)
		}
	}

	// Build pure invocation plan
	plan := buildInvocationPlan(SessionContext{
		SessionID:          sessionID,
		HasSession:         hasSession,
		RoomName:           roomName,
		Message:            message,
		HandoffContent:     handoffContent,
		LastSaturation:     b.sessions.GetLastSaturation(roomID),
		LastReminderAt:     b.sessions.GetLastReminderAt(roomID),
		TimeSinceLast:      timeSinceLast,
		Landscape:          landscape,
		InterruptedContext: interruptedContext,
		Now:                b.now(),
		ProjectDir:         projectDir,
		SystemPromptContent: b.systemPromptContent,
	})

	// Apply side effects from the plan
	if plan.ShouldMarkInvoked {
		b.sessions.MarkInvoked(sessionID)
	}
	if plan.ShouldUpdateReminderAt {
		b.sessions.SetLastReminderAt(roomID, plan.ReminderBucket)
	}

	args := plan.CLIArgs

	log.Printf("Invoking claude with args: %v", args)

	// Determine event log path for this room
	eventLogSlug := slugify(b.getRoomName(ctx, roomID))
	if eventLogSlug == "" {
		eventLogSlug = string(roomID)
	}
	eventLogPath := filepath.Join(os.TempDir(), "ko-events-"+eventLogSlug+".jsonl")

	env := []string{
		"CRANIUM_ROOM_ID=" + string(roomID),
		"CRANIUM_SESSION_ID=" + sessionID,
		"KO_EVENT_LOG=" + eventLogPath,
	}
	workDir := b.dataDir
	if plan.WorkDir != "" {
		workDir = plan.WorkDir
	}
	proc, err := b.claude.Start(ctx, args, workDir, env)
	if err != nil {
		return "", "", ContextInfo{}, nil, fmt.Errorf("failed to start claude: %w", err)
	}

	// Log stderr in background
	go func() {
		stderrBytes, _ := io.ReadAll(proc.Stderr())
		if len(stderrBytes) > 0 {
			log.Printf("Claude stderr: %s", string(stderrBytes))
		}
	}()

	var finalResult string
	var newSessionID string
	var ctxInfo ContextInfo

	// Edit-in-place state: accumulate content into a single message
	var mu sync.Mutex // protects sections, currentEventID, editCount
	var currentEventID id.EventID
	var sections []string // accumulated content sections
	var editCount int     // how many times we've edited the message

	workingIndicator := func() string {
		messages := []string{
			"constructing additional pylons",
			"reticulating splines",
			"spinning up hamster wheels",
			"consulting the oracle",
			"rearranging bits",
			"untangling quantum threads",
			"brewing fresh coffee",
			"negotiating with electrons",
			"calibrating reality anchors",
			"summoning photons",
			"optimizing flux capacitors",
			"polishing neurons",
			"defragmenting synapses",
			"warming up the thinking apparatus",
		}
		msg := messages[rng.Intn(len(messages))]
		return "\n\n---\n*[" + b.displayName + " is " + msg + "...]*"
	}

	// Proactive message splitting: Synapse's default max event size is ~64KB.
	// We split to a fresh message before hitting the limit to avoid M_TOO_LARGE (413).
	const maxMessageBytes = 50 * 1024 // 50KB threshold (leaves headroom for HTML rendering + event envelope)

	// Helper to build the full message from sections
	buildMessage := func(withTrailer bool) string {
		msg := strings.Join(sections, "\n\n")
		if withTrailer {
			msg += workingIndicator()
		}
		return msg
	}

	// startFreshMessage finalizes the current message (removing trailer) and
	// resets state so the next sendOrEdit creates a new Matrix event.
	// Caller must set sections to the carry-forward content before or after.
	startFreshMessage := func() {
		if currentEventID != "" {
			// Remove working indicator from the previous message
			msg := buildMessage(false)
			if err := b.editMessage(ctx, roomID, currentEventID, msg); err != nil {
				log.Printf("Split: final edit of %s failed (content may be truncated): %v", currentEventID, err)
			}
			b.sessions.SetLastMessage(roomID, string(currentEventID), msg)
			log.Printf("Split: finalized message %s (%d bytes), starting fresh", currentEventID, len(msg))
		}
		currentEventID = ""
		sections = nil
		editCount = 0
	}

	// Helper to send or edit the accumulated message.
	// The trailer is only shown on edits (not the initial send) to avoid
	// a flicker on simple single-response messages.
	sendOrEdit := func(withTrailer bool) {
		// Proactive split: if the next edit would exceed the size threshold,
		// pull the overflowing sections out, finalize the current message,
		// then carry them forward into the fresh message.
		if currentEventID != "" && len(buildMessage(withTrailer)) > maxMessageBytes {
			// Find the split point: walk backwards to find sections added since
			// the message was last under the limit. At minimum, move the last
			// section to the new message (it's the one that pushed us over).
			var carry []string
			for len(sections) > 0 {
				carry = append([]string{sections[len(sections)-1]}, carry...)
				sections = sections[:len(sections)-1]
				if len(buildMessage(false)) <= maxMessageBytes {
					break
				}
			}
			startFreshMessage()
			sections = carry
		}

		if currentEventID == "" {
			// First send — never include trailer (avoids flicker on simple responses)
			msg := buildMessage(false)
			b.client.UserTyping(ctx, roomID, false, 0)
			currentEventID = b.sendMessage(ctx, roomID, msg)
			log.Printf("Sent initial message: %s", currentEventID)
		} else {
			// Edit existing message — include trailer if more work is expected
			msg := buildMessage(withTrailer)
			if err := b.editMessage(ctx, roomID, currentEventID, msg); err != nil {
				// Fallback: if the edit fails (e.g. 413), start a fresh message.
				// Pull the last section to carry forward (it caused the overflow).
				log.Printf("Edit failed, splitting to fresh message: %v", err)
				var carry []string
				if len(sections) > 0 {
					carry = append(carry, sections[len(sections)-1])
					sections = sections[:len(sections)-1]
				}
				startFreshMessage()
				sections = carry
				msg = buildMessage(false)
				b.client.UserTyping(ctx, roomID, false, 0)
				currentEventID = b.sendMessage(ctx, roomID, msg)
				log.Printf("Sent fallback message: %s", currentEventID)
			} else {
				editCount++
				log.Printf("Edited message: %s", currentEventID)
			}
		}
		// Persist incrementally so a mid-stream kill still has the right event to clean up
		if currentEventID != "" {
			b.sessions.SetLastMessage(roomID, string(currentEventID), buildMessage(false))
		}
	}

	// Start event log watcher — tails KO_EVENT_LOG and appends formatted
	// lines to the message. Runs concurrently with the scanner loop below.
	// watcherStop is closed when the process exits to stop the watcher.
	watcherStop := make(chan struct{})
	watcherDone := make(chan struct{})
	go func() {
		defer close(watcherDone)
		var buildStart time.Time
		eventLogWatcher(eventLogPath, watcherStop, func(line string) {
			// Capture the first event's timestamp as the build start reference
			if buildStart.IsZero() {
				var evt map[string]interface{}
				if err := json.Unmarshal([]byte(line), &evt); err == nil {
					if tsStr, ok := evt["ts"].(string); ok {
						if ts, err := time.Parse(time.RFC3339, tsStr); err == nil {
							buildStart = ts
						}
					}
				}
			}
			formatted := formatEventLogLine(line, buildStart)
			if formatted == "" {
				return
			}
			mu.Lock()
			defer mu.Unlock()
			sections = append(sections, formatted)
			sendOrEdit(true)
			log.Printf("Event log: appended ko event")
		})
	}()

	scanner := bufio.NewScanner(proc.Stdout())
	// Increase buffer size for potentially large responses
	buf := make([]byte, 0, 64*1024)
	scanner.Buffer(buf, 1024*1024)

	type toolCall struct {
		name  string
		input map[string]interface{}
	}

	// formatThinking wraps text as blockquoted italic (for thinking monologue)
	formatThinking := func(text string) string {
		lines := strings.Split(text, "\n")
		for i, line := range lines {
			trimmed := strings.TrimSpace(line)
			if trimmed != "" {
				lines[i] = "> *" + trimmed + "*"
			} else {
				lines[i] = ">"
			}
		}
		return strings.Join(lines, "\n")
	}

	// Thinking detection: text preceded by a tool call is "thinking."
	// On turn end, the last text section gets reverted to plain (it's the real reply).
	var lastSectionWasTool bool

	for scanner.Scan() {
		line := scanner.Text()
		log.Printf("Claude output line: %s", line[:min(len(line), 200)])

		var msg map[string]interface{}
		if err := json.Unmarshal([]byte(line), &msg); err != nil {
			log.Printf("Failed to parse JSON: %v", err)
			continue
		}

		msgType, _ := msg["type"].(string)

		// Extract session ID from any message that has one
		if sid, ok := msg["session_id"].(string); ok && sid != "" {
			newSessionID = sid
		}

		// Handle assistant messages — extract text and tool_use from content blocks
		if msgType == "assistant" {
			message, ok := msg["message"].(map[string]interface{})
			if !ok {
				continue
			}

			// Extract per-turn usage to track context window saturation
			if usage, ok := message["usage"].(map[string]interface{}); ok {
				inputTokens, _ := usage["input_tokens"].(float64)
				outputTokens, _ := usage["output_tokens"].(float64)
				cacheRead, _ := usage["cache_read_input_tokens"].(float64)
				cacheCreation, _ := usage["cache_creation_input_tokens"].(float64)
				// Total input for this API call = non-cached + cached tokens
				ctxInfo.UsedTokens = int(inputTokens + outputTokens + cacheRead + cacheCreation)
			}
			contentArr, ok := message["content"].([]interface{})
			if !ok {
				continue
			}

			var texts []string
			var tools []toolCall

			for _, block := range contentArr {
				blockMap, ok := block.(map[string]interface{})
				if !ok {
					continue
				}
				blockType, _ := blockMap["type"].(string)
				if blockType == "text" {
					if text, ok := blockMap["text"].(string); ok && text != "" {
						texts = append(texts, text)
					}
				}
				if blockType == "tool_use" {
					tc := toolCall{}
					tc.name, _ = blockMap["name"].(string)
					if input, ok := blockMap["input"].(map[string]interface{}); ok {
						tc.input = input
					}
					tools = append(tools, tc)
				}
			}

			combined := ""
			if len(texts) > 0 {
				combined = strings.TrimSpace(strings.Join(texts, "\n"))
			}

			mu.Lock()
			if combined != "" {
				if lastSectionWasTool {
					// Text preceded by a tool call — it's thinking
					sections = append(sections, formatThinking(combined))
					log.Printf("Sent/edited with text content (thinking)")
				} else {
					sections = append(sections, combined)
					log.Printf("Sent/edited with text content")
				}
				sendOrEdit(len(tools) > 0)
				lastSectionWasTool = false
			}

			if len(tools) > 0 {
				for _, tc := range tools {
					detail := formatToolDetail(tc.name, tc.input)
					toolLine := fmt.Sprintf("> **%s** `%s`", tc.name, detail)
					sections = append(sections, toolLine)
					sendOrEdit(true)
					log.Printf("Sent/edited with tool call: %s", tc.name)

					// Log auto-answered AskUserQuestion details
					if tc.name == "AskUserQuestion" {
						if questions, ok := tc.input["questions"].([]interface{}); ok && len(questions) > 0 {
							if q, ok := questions[0].(map[string]interface{}); ok {
								question, _ := q["question"].(string)
								if options, ok := q["options"].([]interface{}); ok && len(options) > 0 {
									if opt, ok := options[0].(map[string]interface{}); ok {
										label, _ := opt["label"].(string)
										log.Printf("Auto-answered AskUserQuestion: %s -> %s", question, label)
									}
								}
							}
						}
					}
				}
				lastSectionWasTool = true
			}
			mu.Unlock()
		}

		if msgType == "result" {
			if result, ok := msg["result"].(string); ok {
				finalResult = result
			}
			// Extract context window size from modelUsage
			if modelUsage, ok := msg["modelUsage"].(map[string]interface{}); ok {
				for _, usage := range modelUsage {
					if u, ok := usage.(map[string]interface{}); ok {
						contextWindow, _ := u["contextWindow"].(float64)
						ctxInfo.ContextWindow = int(contextWindow)
					}
				}
			}
		}
	}

	if err := proc.Wait(); err != nil {
		close(watcherStop)
		// If the context was cancelled (stop emoji), capture partial sections before returning
		if ctx.Err() != nil {
			mu.Lock()
			partialSections := make([]string, len(sections))
			copy(partialSections, sections)
			mu.Unlock()
			return "", newSessionID, ctxInfo, partialSections, fmt.Errorf("claude exited with error: %w", err)
		}
		return "", "", ctxInfo, nil, fmt.Errorf("claude exited with error: %w", err)
	}

	// Stop the watcher and let it drain any final events
	close(watcherStop)
	select {
	case <-watcherDone:
	case <-time.After(1 * time.Second):
	}

	mu.Lock()
	// End of turn: if the last text section was thinking-formatted, revert it —
	// the final text in a turn is the real reply, not thinking.
	if len(sections) > 0 && strings.HasPrefix(sections[len(sections)-1], "> *") && !strings.HasPrefix(sections[len(sections)-1], "> **") {
		formatted := sections[len(sections)-1]
		lines := strings.Split(formatted, "\n")
		for i, line := range lines {
			line = strings.TrimPrefix(line, "> ")
			if line == ">" {
				lines[i] = ""
			} else {
				line = strings.TrimPrefix(line, "*")
				line = strings.TrimSuffix(line, "*")
				lines[i] = line
			}
		}
		sections[len(sections)-1] = strings.Join(lines, "\n")
		log.Printf("Reverted last section from thinking to plain text")
	}

	// Final edit: remove the working indicator (only if we actually edited)
	if currentEventID != "" {
		if editCount > 0 {
			sendOrEdit(false)
			log.Printf("Final edit: removed working indicator")
		}
		// Capture sections before unlocking (for interrupted context)
		partialSections := make([]string, len(sections))
		copy(partialSections, sections)
		mu.Unlock()
		return "", newSessionID, ctxInfo, partialSections, nil
	}
	mu.Unlock()

	return strings.TrimSpace(finalResult), newSessionID, ctxInfo, nil, nil
}

