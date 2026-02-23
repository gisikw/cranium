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
	"sync/atomic"
	"time"

	"maunium.net/go/mautrix/id"
)

// RoomSummary is the per-room summary cache for cross-room awareness
type RoomSummary struct {
	RoomID            string `json:"room_id"`
	RoomName          string `json:"room_name"`
	Summary           string `json:"summary"`
	LastMessageTS     int64  `json:"last_message_ts"`
	LastSummaryTS     int64  `json:"last_summary_ts"`
	TurnsSinceSummary int    `json:"turns_since_summary"`
}

const summaryThreshold = 10

func (b *Bridge) loadRoomSummary(slug string) (*RoomSummary, error) {
	path := filepath.Join(b.dataDir, "summaries", slug+".json")
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var s RoomSummary
	if err := json.Unmarshal(data, &s); err != nil {
		return nil, err
	}
	return &s, nil
}

func (b *Bridge) saveRoomSummary(slug string, s *RoomSummary) error {
	dir := filepath.Join(b.dataDir, "summaries")
	if err := os.MkdirAll(dir, 0755); err != nil {
		return fmt.Errorf("summaries mkdir: %w", err)
	}
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(dir, slug+".json"), data, 0644)
}

func (b *Bridge) loadAllSummaries() []RoomSummary {
	dir := filepath.Join(b.dataDir, "summaries")
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var summaries []RoomSummary
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		data, err := os.ReadFile(filepath.Join(dir, e.Name()))
		if err != nil {
			log.Printf("Failed to read summary %s: %v", e.Name(), err)
			continue
		}
		var s RoomSummary
		if err := json.Unmarshal(data, &s); err != nil {
			log.Printf("Failed to parse summary %s: %v", e.Name(), err)
			continue
		}
		summaries = append(summaries, s)
	}
	return summaries
}

// filterAndFormatSummaries builds cross-room awareness text from a slice of summaries.
// Pure function — no I/O. Excludes the specified room and filters by maxAge (0 = no filter).
func filterAndFormatSummaries(summaries []RoomSummary, excludeRoomID string, maxAge time.Duration, now time.Time) string {
	var lines []string
	for _, s := range summaries {
		if s.RoomID == excludeRoomID {
			continue
		}
		if maxAge > 0 {
			age := now.Sub(time.Unix(s.LastMessageTS, 0))
			if age > maxAge {
				continue
			}
		}
		age := formatDuration(now.Sub(time.Unix(s.LastMessageTS, 0)))
		lines = append(lines, fmt.Sprintf("- **%s** (last active %s ago): %s", s.RoomName, age, s.Summary))
	}

	if len(lines) == 0 {
		return ""
	}
	return "Here's what's happening in your other rooms:\n\n" + strings.Join(lines, "\n")
}

// formatSummaryLandscape builds a cross-room awareness block.
// Loads summaries from disk and delegates to the pure filterAndFormatSummaries.
func (b *Bridge) formatSummaryLandscape(excludeRoomID id.RoomID, maxAge time.Duration) string {
	summaries := b.loadAllSummaries()
	return filterAndFormatSummaries(summaries, string(excludeRoomID), maxAge, b.now())
}

// generateSummary forks a room's session to produce a cross-room awareness summary.
// Runs asynchronously. Per-room atomic bool prevents concurrent generation.
func (b *Bridge) generateSummary(ctx context.Context, roomID id.RoomID) {
	// Per-room lock
	lockVal, _ := b.summaryLocks.LoadOrStore(roomID, &atomic.Bool{})
	lock := lockVal.(*atomic.Bool)
	if !lock.CompareAndSwap(false, true) {
		log.Printf("Summary generation already in progress for room %s, skipping", roomID)
		return
	}
	defer lock.Store(false)

	sessionID, ok := b.sessions.Get(roomID)
	if !ok || sessionID == "" {
		log.Printf("No session for room %s, skipping summary generation", roomID)
		return
	}

	roomName := b.getRoomName(ctx, roomID)
	slug := slugify(roomName)
	if slug == "" {
		log.Printf("Cannot slugify room name for %s, skipping summary", roomID)
		return
	}

	prompt := `SYSTEM TASK: You are being invoked as a forked snapshot of an active session. Ignore the previous conversational flow and respond ONLY to this instruction.

Write a 2-4 sentence summary of what this room's conversation has been about. This summary will be shown to your other instances in different rooms for cross-room awareness. Focus on: what's being worked on, key decisions made, and current state. Respond with ONLY the summary text — no commentary, no meta-discussion, no tools.`

	args := []string{
		"-p", prompt,
		"--resume", sessionID,
		"--fork-session",
		"--no-session-persistence",
		"--output-format", "stream-json",
		"--verbose",
		"--tools", "",
	}

	// Use the project directory if the room matches one, since the session
	// was created there and --resume needs the same cwd.
	workDir := b.dataDir
	if roomName != "" {
		candidate := filepath.Join(os.Getenv("HOME"), "Projects", slugify(roomName))
		if info, err := os.Stat(candidate); err == nil && info.IsDir() {
			workDir = candidate
		}
	}

	proc, err := b.claude.Start(ctx, args, workDir, nil)
	if err != nil {
		log.Printf("Summary: start error: %v", err)
		return
	}

	go func() {
		stderrBytes, _ := io.ReadAll(proc.Stderr())
		if len(stderrBytes) > 0 {
			log.Printf("Summary stderr for %s: %s", roomName, string(stderrBytes))
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
		log.Printf("Summary: claude exited with error for %s: %v", roomName, err)
		return
	}

	if finalResult == "" {
		log.Printf("Summary: empty result from Claude for room %s", roomName)
		return
	}

	now := b.now()
	summary := &RoomSummary{
		RoomID:            string(roomID),
		RoomName:          roomName,
		Summary:           strings.TrimSpace(finalResult),
		LastMessageTS:     now.Unix(),
		LastSummaryTS:     now.Unix(),
		TurnsSinceSummary: 0,
	}

	if err := b.saveRoomSummary(slug, summary); err != nil {
		log.Printf("Summary: failed to save for room %s: %v", roomName, err)
		return
	}

	b.sessions.ResetTurns(roomID)
	log.Printf("Generated summary for room %q (%d bytes)", roomName, len(finalResult))
}
