package main

import (
	"bytes"
	"context"
	"log"
	"math/rand"
	"strings"
	"sync"
	"time"

	"github.com/yuin/goldmark"
	"github.com/yuin/goldmark/extension"
	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
)

var (
	rng          = rand.New(rand.NewSource(time.Now().UnixNano()))
	markdown     = goldmark.New(goldmark.WithExtensions(extension.Table))
	markdownLock sync.Mutex // protects concurrent access to markdown.Convert
)

// htmlEscape escapes special characters for HTML
func htmlEscape(s string) string {
	s = strings.ReplaceAll(s, "&", "&amp;")
	s = strings.ReplaceAll(s, "<", "&lt;")
	s = strings.ReplaceAll(s, ">", "&gt;")
	s = strings.ReplaceAll(s, "\"", "&quot;")
	return s
}

// renderMarkdown converts markdown text to HTML using goldmark
// Thread-safe: uses markdownLock to protect concurrent access to the shared markdown instance
func renderMarkdown(md string) string {
	var buf bytes.Buffer
	markdownLock.Lock()
	err := markdown.Convert([]byte(md), &buf)
	markdownLock.Unlock()
	if err != nil {
		// Fallback: wrap in <p> with escaping
		return "<p>" + htmlEscape(md) + "</p>"
	}
	return buf.String()
}

// sendMessage sends a markdown-rendered message to a Matrix room, returns the event ID
func (b *Bridge) sendMessage(ctx context.Context, roomID id.RoomID, message string) id.EventID {
	content := event.MessageEventContent{
		MsgType:       event.MsgText,
		Body:          message,
		Format:        event.FormatHTML,
		FormattedBody: renderMarkdown(message),
	}
	resp, err := b.client.SendMessageEvent(ctx, roomID, event.EventMessage, content)
	if err != nil {
		log.Printf("Failed to send message to %s: %v", roomID, err)
		return ""
	}
	return resp.EventID
}

// editMessage edits an existing message with new content (markdown-rendered).
// Returns an error if the edit fails (e.g. M_TOO_LARGE / HTTP 413).
func (b *Bridge) editMessage(ctx context.Context, roomID id.RoomID, eventID id.EventID, message string) error {
	content := event.MessageEventContent{
		MsgType:       event.MsgText,
		Body:          message,
		Format:        event.FormatHTML,
		FormattedBody: renderMarkdown(message),
	}
	content.SetEdit(eventID)
	_, err := b.client.SendMessageEvent(ctx, roomID, event.EventMessage, content)
	if err != nil {
		log.Printf("Failed to edit message %s in %s: %v", eventID, roomID, err)
	}
	return err
}

// sendNotice sends a notice message (no notification, plain text).
func (b *Bridge) sendNotice(ctx context.Context, roomID id.RoomID, message string) id.EventID {
	content := event.MessageEventContent{
		MsgType: event.MsgNotice,
		Body:    message,
	}
	resp, err := b.client.SendMessageEvent(ctx, roomID, event.EventMessage, content)
	if err != nil {
		log.Printf("Failed to send notice to %s: %v", roomID, err)
		return ""
	}
	return resp.EventID
}

// editNotice edits an existing notice message (plain text, no markdown).
func (b *Bridge) editNotice(ctx context.Context, roomID id.RoomID, eventID id.EventID, message string) {
	content := event.MessageEventContent{
		MsgType: event.MsgNotice,
		Body:    message,
	}
	content.SetEdit(eventID)
	_, err := b.client.SendMessageEvent(ctx, roomID, event.EventMessage, content)
	if err != nil {
		log.Printf("Failed to edit notice %s in %s: %v", eventID, roomID, err)
	}
}

// pinMessage pins a single message in the room.
func (b *Bridge) pinMessage(ctx context.Context, roomID id.RoomID, eventID id.EventID) {
	_, err := b.client.SendStateEvent(ctx, roomID, event.StatePinnedEvents, "", map[string]interface{}{
		"pinned": []string{string(eventID)},
	})
	if err != nil {
		log.Printf("Failed to pin message %s in %s: %v", eventID, roomID, err)
	}
}

// unpinMessage removes all pinned messages from the room.
func (b *Bridge) unpinMessage(ctx context.Context, roomID id.RoomID) {
	_, err := b.client.SendStateEvent(ctx, roomID, event.StatePinnedEvents, "", map[string]interface{}{
		"pinned": []string{},
	})
	if err != nil {
		log.Printf("Failed to unpin messages in %s: %v", roomID, err)
	}
}

// redactMessage deletes a message from the room.
func (b *Bridge) redactMessage(ctx context.Context, roomID id.RoomID, eventID id.EventID) {
	_, err := b.client.RedactEvent(ctx, roomID, eventID)
	if err != nil {
		log.Printf("Failed to redact message %s in %s: %v", eventID, roomID, err)
	}
}

// buildInterruptedSummary formats accumulated sections as a plain-text summary,
// truncated to maxChars. This is a pure function — no I/O, testable in isolation.
func buildInterruptedSummary(sections []string, maxChars int) string {
	if len(sections) == 0 {
		return ""
	}
	summary := strings.Join(sections, "\n\n")
	if len(summary) > maxChars {
		summary = summary[:maxChars] + "\n\n[...output truncated...]"
	}
	return summary
}
