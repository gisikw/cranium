package main

import (
	"strings"
	"testing"
	"time"

	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
)

// Helper to create a properly formatted text event
func makeTextEvent(sender string, timestamp time.Time, body string) *event.Event {
	evt := &event.Event{
		Sender:    id.UserID(sender),
		Timestamp: timestamp.UnixMilli(),
		Content: event.Content{
			Parsed: &event.MessageEventContent{
				MsgType: event.MsgText,
				Body:    body,
			},
		},
	}
	return evt
}

// Helper to create an event with specific message type
func makeMessageEvent(sender string, timestamp time.Time, msgType event.MessageType, body string) *event.Event {
	evt := &event.Event{
		Sender:    id.UserID(sender),
		Timestamp: timestamp.UnixMilli(),
		Content: event.Content{
			Parsed: &event.MessageEventContent{
				MsgType: msgType,
				Body:    body,
			},
		},
	}
	return evt
}

func TestFormatRecentMessages_Empty(t *testing.T) {
	result := formatRecentMessages([]*event.Event{}, 10)
	if result != "" {
		t.Errorf("Expected empty string for empty events, got %q", result)
	}
}

func TestFormatRecentMessages_TextMessages(t *testing.T) {
	now := time.Now()
	events := []*event.Event{
		makeTextEvent("@alice:example.com", now, "deploy the bridge"),
		makeTextEvent("@agent:example.com", now.Add(-1*time.Minute), "Starting deploy..."),
	}

	result := formatRecentMessages(events, 10)

	if result == "" {
		t.Fatal("Expected non-empty result")
	}

	lines := strings.Split(result, "\n")
	if len(lines) != 2 {
		t.Errorf("Expected 2 lines, got %d", len(lines))
	}

	// Check that timestamps are formatted
	if !strings.Contains(lines[0], "[") || !strings.Contains(lines[0], "]") {
		t.Errorf("Expected timestamp in first line: %q", lines[0])
	}

	// Check that sender names are extracted
	if !strings.Contains(lines[0], "kevin:") {
		t.Errorf("Expected 'kevin:' in first line: %q", lines[0])
	}

	if !strings.Contains(lines[1], "exo:") {
		t.Errorf("Expected 'exo:' in second line: %q", lines[1])
	}

	// Check that message bodies are present
	if !strings.Contains(result, "deploy the bridge") {
		t.Errorf("Expected 'deploy the bridge' in result")
	}

	if !strings.Contains(result, "Starting deploy...") {
		t.Errorf("Expected 'Starting deploy...' in result")
	}
}

func TestFormatRecentMessages_Limit(t *testing.T) {
	now := time.Now()
	events := make([]*event.Event, 5)
	for i := 0; i < 5; i++ {
		events[i] = makeTextEvent("@user:example.com", now.Add(time.Duration(-i)*time.Minute), "message")
	}

	result := formatRecentMessages(events, 3)
	lines := strings.Split(result, "\n")

	if len(lines) != 3 {
		t.Errorf("Expected limit of 3 messages, got %d", len(lines))
	}
}

func TestFormatRecentMessages_LongMessage(t *testing.T) {
	now := time.Now()
	longBody := strings.Repeat("a", 300)
	events := []*event.Event{
		makeTextEvent("@user:example.com", now, longBody),
	}

	result := formatRecentMessages(events, 10)

	if !strings.Contains(result, "...") {
		t.Error("Expected long message to be truncated with '...'")
	}

	// Find the message body part (after the timestamp and sender)
	parts := strings.SplitN(result, ": ", 2)
	if len(parts) == 2 && len(parts[1]) > 200 {
		t.Errorf("Expected truncated message to be <= 200 chars, got %d", len(parts[1]))
	}
}

func TestFormatRecentMessages_NonTextMessages(t *testing.T) {
	now := time.Now()
	events := []*event.Event{
		makeMessageEvent("@user:example.com", now, event.MsgImage, "screenshot.png"),
		makeMessageEvent("@user:example.com", now.Add(-1*time.Minute), event.MsgFile, "document.pdf"),
	}

	result := formatRecentMessages(events, 10)

	if !strings.Contains(result, "[Image]") {
		t.Error("Expected '[Image]' for image message")
	}

	if !strings.Contains(result, "[File]") {
		t.Error("Expected '[File]' for file message")
	}
}

func TestExtractLocalpart(t *testing.T) {
	tests := []struct {
		input    id.UserID
		expected string
	}{
		{id.UserID("@alice:example.com"), "kevin"},
		{id.UserID("@agent:example.com"), "exo"},
		{id.UserID("@user:example.com"), "user"},
		{id.UserID("invalid"), "invalid"},
	}

	for _, test := range tests {
		result := extractLocalpart(test.input)
		if result != test.expected {
			t.Errorf("extractLocalpart(%q) = %q, want %q", test.input, result, test.expected)
		}
	}
}

func TestBuildResumeMessage_WithMessages(t *testing.T) {
	recentMessages := "[12:34] kevin: deploy the bridge\n[12:33] exo: Starting..."

	result := buildResumeMessage(recentMessages)

	if !strings.Contains(result, "<system-reminder>") {
		t.Error("Expected system-reminder tag")
	}

	if !strings.Contains(result, recentMessages) {
		t.Error("Expected recent messages to be included")
	}

	if !strings.Contains(result, "HISTORICAL CONTEXT") {
		t.Error("Expected historical context framing")
	}
}

func TestBuildResumeMessage_WithoutMessages(t *testing.T) {
	result := buildResumeMessage("")

	if !strings.Contains(result, "<system-reminder>") {
		t.Error("Expected system-reminder tag")
	}

	if strings.Contains(result, "most recent messages") {
		t.Error("Should not mention messages when none provided")
	}
}
