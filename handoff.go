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
	"time"

	"maunium.net/go/mautrix/id"
)

// deriveSlug returns a filesystem slug for a room, falling back to the room ID
// if the room name produces an empty slug.
func deriveSlug(roomName string, roomID string) string {
	slug := slugify(roomName)
	if slug != "" {
		return slug
	}
	// Fallback: use last segment of room ID
	s := roomID
	if idx := strings.LastIndex(s, ":"); idx > 0 {
		s = s[:idx]
	}
	if len(s) > 20 {
		s = s[len(s)-20:]
	}
	return slugify(s)
}

func (b *Bridge) generateHandoff(ctx context.Context, roomID id.RoomID, sessionID string) error {
	roomName := b.getRoomName(ctx, roomID)
	slug := deriveSlug(roomName, string(roomID))

	prompt := `Write a handoff document for this room's conversation. This will be injected as context into your next fresh session in this room after a clear.

Include:
- What was being worked on or discussed
- Current state and any open threads
- Key decisions made
- Anything the next session needs to know to pick up smoothly

Be concise but complete. Write in markdown. Do not use any tools — just respond with the handoff text directly.`

	args := []string{
		"-p", prompt,
		"--resume", sessionID,
		"--output-format", "stream-json",
		"--verbose",
		"--no-session-persistence",
		"--tools", "",
	}

	// Use the project directory if the room matches one, since the session
	// was created there and --resume needs the same cwd.
	workDir := b.exocortexDir
	if roomName != "" {
		candidate := filepath.Join(os.Getenv("HOME"), "Projects", slugify(roomName))
		if info, err := os.Stat(candidate); err == nil && info.IsDir() {
			workDir = candidate
		}
	}

	proc, err := b.claude.Start(ctx, args, workDir, nil)
	if err != nil {
		return fmt.Errorf("handoff: start: %w", err)
	}

	go func() {
		stderrBytes, _ := io.ReadAll(proc.Stderr())
		if len(stderrBytes) > 0 {
			log.Printf("Handoff stderr: %s", string(stderrBytes))
		}
	}()

	var finalResult string
	scanner := bufio.NewScanner(proc.Stdout())
	buf := make([]byte, 0, 64*1024)
	scanner.Buffer(buf, 1024*1024)

	for scanner.Scan() {
		line := scanner.Text()
		var msg map[string]interface{}
		if err := json.Unmarshal([]byte(line), &msg); err != nil {
			continue
		}
		if msgType, _ := msg["type"].(string); msgType == "result" {
			if result, ok := msg["result"].(string); ok {
				finalResult = result
			}
		}
	}

	if err := proc.Wait(); err != nil {
		return fmt.Errorf("handoff: claude exited: %w", err)
	}

	if finalResult == "" {
		return fmt.Errorf("handoff: empty result from Claude")
	}

	handoffDir := filepath.Join(b.exocortexDir, "handoffs", slug)
	if err := os.MkdirAll(handoffDir, 0755); err != nil {
		return fmt.Errorf("handoff: mkdir: %w", err)
	}
	timestamp := time.Now().Format("2006-01-02_15-04-05")
	handoffPath := filepath.Join(handoffDir, timestamp+".md")
	if err := os.WriteFile(handoffPath, []byte(finalResult), 0644); err != nil {
		return fmt.Errorf("handoff: write: %w", err)
	}

	log.Printf("Wrote handoff for room %q to %s (%d bytes)", roomName, handoffPath, len(finalResult))
	return nil
}
