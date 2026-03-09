package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

// Usage:
//   crn-summarize <room-name>            # echo existing summary
//   crn-summarize --refresh <room-name>  # refresh via session fork, then echo

type roomSummary struct {
	RoomID            string `json:"room_id"`
	RoomName          string `json:"room_name"`
	Summary           string `json:"summary"`
	LastMessageTS     int64  `json:"last_message_ts"`
	LastSummaryTS     int64  `json:"last_summary_ts"`
	TurnsSinceSummary int    `json:"turns_since_summary"`
}

type sessionData struct {
	SessionID string `json:"session_id"`
}

func main() {
	args := os.Args[1:]
	refresh := false

	// Parse --refresh flag
	var filtered []string
	for _, a := range args {
		if a == "--refresh" {
			refresh = true
		} else {
			filtered = append(filtered, a)
		}
	}

	if len(filtered) != 1 {
		fmt.Fprintf(os.Stderr, "Usage: crn-summarize [--refresh] <room-name>\n")
		os.Exit(1)
	}

	roomName := filtered[0]
	slug := slugify(roomName)

	dataDir, projectsDir := resolveConfig()
	summaryPath := filepath.Join(dataDir, "summaries", slug+".json")

	if refresh {
		if err := refreshSummary(dataDir, projectsDir, slug, roomName, summaryPath); err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}
	}

	// Echo
	data, err := os.ReadFile(summaryPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "No summary found for %q\n", roomName)
		os.Exit(1)
	}

	var s roomSummary
	if err := json.Unmarshal(data, &s); err != nil {
		fmt.Fprintf(os.Stderr, "Failed to parse summary: %v\n", err)
		os.Exit(1)
	}

	now := time.Now()
	summaryAge := now.Sub(time.Unix(s.LastSummaryTS, 0))
	messageAge := now.Sub(time.Unix(s.LastMessageTS, 0))

	fmt.Printf("Room:       %s\n", s.RoomName)
	fmt.Printf("Summary:    %s ago (%d turns since)\n", formatDuration(summaryAge), s.TurnsSinceSummary)
	fmt.Printf("Last msg:   %s ago\n", formatDuration(messageAge))
	fmt.Printf("\n%s\n", s.Summary)
}

func refreshSummary(dataDir, projectsDir, slug, roomName, summaryPath string) error {
	sessionsPath := filepath.Join(dataDir, ".cranium-sessions.json")
	sessionsData, err := os.ReadFile(sessionsPath)
	if err != nil {
		return fmt.Errorf("read sessions: %w", err)
	}

	// Load existing summary to get room ID
	summaryData, err := os.ReadFile(summaryPath)
	if err != nil {
		return fmt.Errorf("no existing summary for %q — need at least one prior summary to know the room ID", slug)
	}
	var existing roomSummary
	if err := json.Unmarshal(summaryData, &existing); err != nil {
		return fmt.Errorf("parse existing summary: %w", err)
	}
	if existing.RoomID == "" {
		return fmt.Errorf("existing summary has no room_id")
	}

	// Look up session ID
	var sessions map[string]sessionData
	if err := json.Unmarshal(sessionsData, &sessions); err != nil {
		return fmt.Errorf("parse sessions: %w", err)
	}
	sd, ok := sessions[existing.RoomID]
	if !ok || sd.SessionID == "" {
		return fmt.Errorf("no active session for room %s", existing.RoomID)
	}

	// Determine working directory
	workDir := dataDir
	if projectsDir != "" {
		candidate := filepath.Join(projectsDir, slug)
		if info, err := os.Stat(candidate); err == nil && info.IsDir() {
			workDir = candidate
		}
	}

	prompt := `SYSTEM TASK: You are being invoked as a forked snapshot of an active session. Ignore the previous conversational flow and respond ONLY to this instruction.

Write a 2-4 sentence summary of what this room's conversation has been about. This summary will be shown to your other instances in different rooms for cross-room awareness. Focus on: what's being worked on, key decisions made, and current state. Respond with ONLY the summary text — no commentary, no meta-discussion, no tools.`

	fmt.Fprintf(os.Stderr, "Refreshing summary for %s (session %s)...\n", roomName, sd.SessionID[:8])

	cmd := exec.Command("claude", "-p", prompt,
		"--resume", sd.SessionID,
		"--fork-session",
		"--no-session-persistence",
		"--tools", "")
	cmd.Dir = workDir
	out, err := cmd.Output()
	if err != nil {
		return fmt.Errorf("claude fork: %w", err)
	}

	result := strings.TrimSpace(string(out))
	if result == "" {
		return fmt.Errorf("empty result from Claude")
	}

	now := time.Now().Unix()
	s := roomSummary{
		RoomID:            existing.RoomID,
		RoomName:          existing.RoomName,
		Summary:           result,
		LastMessageTS:     existing.LastMessageTS, // preserve — we don't know if new messages arrived
		LastSummaryTS:     now,
		TurnsSinceSummary: 0,
	}

	os.MkdirAll(filepath.Dir(summaryPath), 0755)
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal summary: %w", err)
	}
	return os.WriteFile(summaryPath, data, 0644)
}

func resolveConfig() (dataDir, projectsDir string) {
	configPath := os.Getenv("CRANIUM_CONFIG")
	if configPath == "" {
		// Try repo-relative
		if ex, err := os.Executable(); err == nil {
			candidate := filepath.Join(filepath.Dir(ex), "cranium.yaml")
			if _, err := os.Stat(candidate); err == nil {
				configPath = candidate
			}
		}
		if configPath == "" {
			configPath = "cranium.yaml"
		}
	}

	craniumData, err := os.ReadFile(configPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Cannot read cranium config at %s: %v\n", configPath, err)
		os.Exit(1)
	}

	var craniumCfg struct {
		IdentityFile string `yaml:"identity_file"`
	}
	if err := yaml.Unmarshal(craniumData, &craniumCfg); err != nil {
		fmt.Fprintf(os.Stderr, "Cannot parse cranium config: %v\n", err)
		os.Exit(1)
	}

	identityData, err := os.ReadFile(craniumCfg.IdentityFile)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Cannot read identity config at %s: %v\n", craniumCfg.IdentityFile, err)
		os.Exit(1)
	}

	var identityCfg struct {
		DataDir     string `yaml:"data_dir"`
		ProjectsDir string `yaml:"projects_dir"`
	}
	if err := yaml.Unmarshal(identityData, &identityCfg); err != nil {
		fmt.Fprintf(os.Stderr, "Cannot parse identity config: %v\n", err)
		os.Exit(1)
	}

	return identityCfg.DataDir, identityCfg.ProjectsDir
}

func slugify(name string) string {
	name = strings.ToLower(name)
	var b strings.Builder
	prevHyphen := false
	for _, r := range name {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
			prevHyphen = false
		} else if !prevHyphen {
			b.WriteRune('-')
			prevHyphen = true
		}
	}
	return strings.Trim(b.String(), "-")
}

func formatDuration(d time.Duration) string {
	hours := int(d.Hours())
	minutes := int(d.Minutes()) % 60
	if hours >= 24 {
		days := hours / 24
		if days == 1 {
			return "about a day"
		}
		return fmt.Sprintf("about %d days", days)
	}
	if hours > 0 {
		if minutes > 0 {
			return fmt.Sprintf("%dh%dm", hours, minutes)
		}
		return fmt.Sprintf("about %d hours", hours)
	}
	return fmt.Sprintf("about %d minutes", minutes)
}
