package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"
	"time"
)

// eventLogWatcher tails a KO_EVENT_LOG file and calls onLine for each new line.
// Stops when the done channel is closed. If the file doesn't exist yet, retries
// opening it on each poll cycle until it appears or done is closed.
func eventLogWatcher(path string, done <-chan struct{}, onLine func(string)) {
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()

	// Snapshot the file size at watcher start. If the file already exists,
	// we skip past its current content (stale events from prior invocations).
	// If it doesn't exist yet, we read from the beginning when it appears.
	var skipBytes int64
	if info, err := os.Stat(path); err == nil {
		skipBytes = info.Size()
	}

	var f *os.File
	var reader *bufio.Reader

	defer func() {
		if f != nil {
			f.Close()
		}
	}()

	for {
		select {
		case <-done:
			return
		case <-ticker.C:
			// Try to open the file if we haven't yet
			if f == nil {
				var err error
				f, err = os.Open(path)
				if err != nil {
					continue // file doesn't exist yet, try again next tick
				}
				if skipBytes > 0 {
					f.Seek(skipBytes, io.SeekStart)
				}
				reader = bufio.NewReader(f)
			}

			// Read any new lines
			for {
				line, err := reader.ReadString('\n')
				line = strings.TrimSpace(line)
				if line != "" {
					onLine(line)
				}
				if err != nil {
					break // EOF or error — wait for next tick
				}
			}
		}
	}
}

// formatEventLogLine converts a JSONL event line into a human-readable string
// for display in Matrix. Returns empty string if the event should be suppressed.
// startTime is the reference point for elapsed timestamps; if zero, timestamps are omitted.
func formatEventLogLine(line string, startTime time.Time) string {
	var evt map[string]interface{}
	if err := json.Unmarshal([]byte(line), &evt); err != nil {
		return ""
	}

	eventType, _ := evt["event"].(string)
	ticket, _ := evt["ticket"].(string)

	// Compute elapsed timestamp prefix
	prefix := "`[ko]`"
	if !startTime.IsZero() {
		if tsStr, ok := evt["ts"].(string); ok {
			if ts, err := time.Parse(time.RFC3339, tsStr); err == nil {
				elapsed := ts.Sub(startTime)
				if elapsed < 0 {
					elapsed = 0
				}
				mins := int(elapsed.Minutes())
				secs := int(elapsed.Seconds()) % 60
				prefix = fmt.Sprintf("`[ko %02d:%02d]`", mins, secs)
			}
		}
	}

	switch eventType {
	case "workflow_start":
		workflow, _ := evt["workflow"].(string)
		return fmt.Sprintf("%s %s: starting workflow **%s**", prefix, ticket, workflow)

	case "node_start":
		node, _ := evt["node"].(string)
		return fmt.Sprintf("%s %s: %s...", prefix, ticket, node)

	case "node_complete":
		node, _ := evt["node"].(string)
		result, _ := evt["result"].(string)
		icon := "→"
		if result == "error" {
			icon = "✗"
		}
		return fmt.Sprintf("%s %s: %s %s %s", prefix, ticket, node, icon, result)

	case "workflow_complete":
		outcome, _ := evt["outcome"].(string)
		icon := outcomeIcon(outcome)
		return fmt.Sprintf("%s %s %s **%s**", prefix, icon, ticket, strings.ToUpper(outcome))

	case "loop_ticket_start":
		title, _ := evt["title"].(string)
		return fmt.Sprintf("%s building %s — %s", prefix, ticket, title)

	case "loop_ticket_complete":
		outcome, _ := evt["outcome"].(string)
		icon := outcomeIcon(outcome)
		return fmt.Sprintf("%s %s %s %s", prefix, icon, ticket, strings.ToUpper(outcome))

	case "loop_summary":
		processed, _ := evt["processed"].(float64)
		succeeded, _ := evt["succeeded"].(float64)
		failed, _ := evt["failed"].(float64)
		blocked, _ := evt["blocked"].(float64)
		stopReason, _ := evt["stop_reason"].(string)
		return fmt.Sprintf("%s loop complete: %.0f processed (%.0f succeeded, %.0f failed, %.0f blocked) — stopped: %s",
			prefix, processed, succeeded, failed, blocked, stopReason)

	default:
		return ""
	}
}

func outcomeIcon(outcome string) string {
	switch outcome {
	case "succeed":
		return "✅"
	case "fail":
		return "❌"
	case "blocked":
		return "🚧"
	case "decompose":
		return "🔀"
	default:
		return "•"
	}
}
