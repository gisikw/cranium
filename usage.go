package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"maunium.net/go/mautrix/id"
)

// usageResponse matches the /api/oauth/usage API response
type usageResponse struct {
	FiveHour *usageBucket `json:"five_hour"`
	SevenDay *usageBucket `json:"seven_day"`
	SevenDaySonnet *usageBucket `json:"seven_day_sonnet"`
	ExtraUsage *extraUsage `json:"extra_usage"`
}

type usageBucket struct {
	Utilization float64 `json:"utilization"`
	ResetsAt    string  `json:"resets_at"`
}

type extraUsage struct {
	IsEnabled    bool    `json:"is_enabled"`
	MonthlyLimit int     `json:"monthly_limit"`
	UsedCredits  float64 `json:"used_credits"`
	Utilization  float64 `json:"utilization"`
}

// credentialsFile matches ~/.claude/.credentials.json
type credentialsFile struct {
	ClaudeAiOauth struct {
		AccessToken string `json:"accessToken"`
	} `json:"claudeAiOauth"`
}

// fetchUsage calls the Anthropic usage API with the stored OAuth token.
func fetchUsage() (*usageResponse, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, fmt.Errorf("home dir: %w", err)
	}

	credsPath := filepath.Join(home, ".claude", ".credentials.json")
	data, err := os.ReadFile(credsPath)
	if err != nil {
		return nil, fmt.Errorf("read credentials: %w", err)
	}

	var creds credentialsFile
	if err := json.Unmarshal(data, &creds); err != nil {
		return nil, fmt.Errorf("parse credentials: %w", err)
	}
	if creds.ClaudeAiOauth.AccessToken == "" {
		return nil, fmt.Errorf("no access token in credentials")
	}

	req, err := http.NewRequest("GET", "https://api.anthropic.com/api/oauth/usage", nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+creds.ClaudeAiOauth.AccessToken)
	req.Header.Set("anthropic-beta", "oauth-2025-04-20")
	req.Header.Set("User-Agent", "claude-code/2.1.37")

	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("API request: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("read response: %w", err)
	}

	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("API returned %d: %s", resp.StatusCode, string(body))
	}

	var usage usageResponse
	if err := json.Unmarshal(body, &usage); err != nil {
		return nil, fmt.Errorf("parse response: %w", err)
	}

	return &usage, nil
}

// formatUsage renders a usageResponse as a human-readable message.
func formatUsage(u *usageResponse) string {
	msg := "**Usage**\n"

	if u.FiveHour != nil {
		resetStr := formatResetTime(u.FiveHour.ResetsAt)
		msg += fmt.Sprintf("- 5hr window: **%.0f%%** (resets %s)\n", u.FiveHour.Utilization, resetStr)
	}
	if u.SevenDay != nil {
		resetStr := formatResetTime(u.SevenDay.ResetsAt)
		msg += fmt.Sprintf("- 7-day Opus: **%.0f%%** (resets %s)\n", u.SevenDay.Utilization, resetStr)
	}
	if u.SevenDaySonnet != nil {
		resetStr := formatResetTime(u.SevenDaySonnet.ResetsAt)
		msg += fmt.Sprintf("- 7-day Sonnet: **%.0f%%** (resets %s)\n", u.SevenDaySonnet.Utilization, resetStr)
	}
	if u.ExtraUsage != nil && u.ExtraUsage.IsEnabled {
		msg += fmt.Sprintf("- Extra usage: **$%.0f** / $%d (%.0f%%)\n",
			u.ExtraUsage.UsedCredits, u.ExtraUsage.MonthlyLimit, u.ExtraUsage.Utilization)
	}

	return msg
}

// formatResetTime parses an ISO timestamp and returns a relative description.
func formatResetTime(ts string) string {
	t, err := time.Parse(time.RFC3339, ts)
	if err != nil {
		return ts
	}
	until := time.Until(t)
	if until < 0 {
		return "now"
	}
	hours := int(until.Hours())
	minutes := int(until.Minutes()) % 60
	if hours >= 24 {
		days := hours / 24
		return fmt.Sprintf("in %dd %dh", days, hours%24)
	}
	if hours > 0 {
		return fmt.Sprintf("in %dh %dm", hours, minutes)
	}
	return fmt.Sprintf("in %dm", minutes)
}

// handleUsageCommand fetches and posts subscription usage to the room.
func (b *Bridge) handleUsageCommand(ctx context.Context, roomID id.RoomID) {
	usage, err := fetchUsage()
	if err != nil {
		log.Printf("Usage fetch failed: %v", err)
		b.sendMessage(ctx, roomID, fmt.Sprintf("Failed to fetch usage: %v", err))
		return
	}

	msg := formatUsage(usage)
	b.sendMessage(ctx, roomID, msg)
}
