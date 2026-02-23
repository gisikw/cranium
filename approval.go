package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"strings"
	"time"

	"maunium.net/go/mautrix/event"
)

// AutoApproveConfig is loaded from a sidecar file on each request
type AutoApproveConfig struct {
	Allow []string `json:"allow"`
	Deny  []string `json:"deny"`
}

func loadAutoApproveConfig(path string) *AutoApproveConfig {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var config AutoApproveConfig
	if err := json.Unmarshal(data, &config); err != nil {
		log.Printf("Failed to parse auto-approve config: %v", err)
		return nil
	}
	return &config
}

// matchesRule checks if a tool call matches an approval rule pattern.
// Simple tool name match (e.g. "Read", "Glob", "WebSearch") or
// Tool(specifier) match (e.g. "Bash(git *)").
func matchesRule(rule string, toolName string, input map[string]interface{}) bool {
	// Simple tool name match
	if !strings.Contains(rule, "(") {
		return rule == toolName
	}

	// Tool(specifier) match
	parenIdx := strings.Index(rule, "(")
	if !strings.HasSuffix(rule, ")") {
		return false
	}
	ruleTool := rule[:parenIdx]
	ruleSpec := rule[parenIdx+1 : len(rule)-1]

	if ruleTool != toolName {
		return false
	}

	// For Bash, match the specifier against the command
	if toolName == "Bash" {
		cmd, _ := input["command"].(string)
		if cmd == "" {
			return false
		}
		return matchWildcard(ruleSpec, cmd)
	}

	// For Read/Edit, match against file_path
	if toolName == "Read" || toolName == "Edit" || toolName == "Write" {
		path, _ := input["file_path"].(string)
		if path == "" {
			return false
		}
		return matchWildcard(ruleSpec, path)
	}

	return false
}

// matchWildcard does simple glob matching where * matches any substring
func matchWildcard(pattern, value string) bool {
	// No wildcard — exact match
	if !strings.Contains(pattern, "*") {
		return pattern == value
	}

	parts := strings.Split(pattern, "*")

	// Check prefix
	if !strings.HasPrefix(value, parts[0]) {
		return false
	}

	// Walk through the parts, finding each in sequence
	pos := len(parts[0])
	for i := 1; i < len(parts); i++ {
		if parts[i] == "" {
			continue
		}
		idx := strings.Index(value[pos:], parts[i])
		if idx < 0 {
			return false
		}
		pos += idx + len(parts[i])
	}

	// If the last part is non-empty, value must end with it
	if last := parts[len(parts)-1]; last != "" {
		return strings.HasSuffix(value, last)
	}

	return true
}

// checkAutoApprove applies auto-approve rules to a tool call.
// Returns "allow", "deny", or "" (no match).
func checkAutoApprove(config *AutoApproveConfig, toolName string, input map[string]interface{}) string {
	if config == nil {
		return ""
	}
	// Deny rules take precedence
	for _, rule := range config.Deny {
		if matchesRule(rule, toolName, input) {
			return "deny"
		}
	}
	for _, rule := range config.Allow {
		if matchesRule(rule, toolName, input) {
			return "allow"
		}
	}
	return ""
}

// normalizeEmoji strips Unicode variation selectors (U+FE0E, U+FE0F) from an emoji.
func normalizeEmoji(emoji string) string {
	return strings.TrimRight(emoji, "\ufe0e\ufe0f")
}

// mapEmojiToApproval maps a normalized emoji to an ApprovalResponse.
// Returns the response and whether the emoji was recognized.
func mapEmojiToApproval(emoji string) (ApprovalResponse, bool) {
	switch emoji {
	case "👍", "✅":
		return ApprovalResponse{Decision: "allow"}, true
	case "👎":
		return ApprovalResponse{Decision: "deny", Message: "User denied the request"}, true
	case "🛑", "⛔":
		return ApprovalResponse{Decision: "deny", Message: "STOP"}, true
	default:
		return ApprovalResponse{}, false
	}
}

// handleReaction processes emoji reactions for pending approvals and stop signals
func (b *Bridge) handleReaction(ctx context.Context, evt *event.Event) {
	content := evt.Content.AsReaction()
	if content == nil {
		return
	}

	// Ignore our own reactions
	if evt.Sender == b.userID {
		return
	}

	// Check for stop emoji — cancels the active invocation in this room
	emoji := normalizeEmoji(content.RelatesTo.Key)
	if emoji == "🛑" || emoji == "⛔" {
		if cancelVal, ok := b.roomCancels.Load(evt.RoomID); ok {
			cancelFn := cancelVal.(context.CancelFunc)
			log.Printf("Stop emoji received in room %s — cancelling active invocation", evt.RoomID)
			cancelFn()
			return
		}
	}

	// Look up the pending approval for this event
	relatesTo := content.RelatesTo.EventID
	val, ok := b.pendingApprovals.Load(relatesTo)
	if !ok {
		log.Printf("No pending approval for event %s", relatesTo)
		return
	}
	pending := val.(*pendingApproval)
	log.Printf("Found pending approval for event %s", relatesTo)

	log.Printf("Reaction received: %s on %s", emoji, relatesTo)

	response, recognized := mapEmojiToApproval(emoji)
	if !recognized {
		log.Printf("Ignoring unknown reaction: %q", emoji)
		return
	}

	// Send response and clean up
	b.pendingApprovals.Delete(relatesTo)
	log.Printf("Sending approval response to channel: %s", response.Decision)
	select {
	case pending.response <- response:
		log.Printf("Response sent to channel successfully")
	default:
		log.Printf("WARNING: Channel not ready to receive")
	}
}

// requestApproval sends a tool approval request to Matrix and waits for reaction
func (b *Bridge) requestApproval(ctx context.Context, req ApprovalRequest) ApprovalResponse {
	// Check auto-approve rules (re-read from disk each time)
	config := loadAutoApproveConfig(b.autoApprovePath)
	if decision := checkAutoApprove(config, req.ToolName, req.ToolInput); decision != "" {
		log.Printf("Auto-%s: %s (matched rule)", decision, req.ToolName)
		return ApprovalResponse{Decision: decision}
	}

	// Look up room for this session
	roomID, ok := b.sessions.GetRoomBySession(req.SessionID)
	if !ok {
		log.Printf("No room found for session %s, deferring to CC permissions", req.SessionID)
		return ApprovalResponse{Decision: "ask", Message: "Unknown session"}
	}

	// Format the approval message
	var inputStr string
	if cmd, ok := req.ToolInput["command"].(string); ok {
		inputStr = fmt.Sprintf("`%s`", cmd)
	} else if desc, ok := req.ToolInput["description"].(string); ok {
		inputStr = desc
	} else {
		inputBytes, _ := json.Marshal(req.ToolInput)
		inputStr = string(inputBytes)
		if len(inputStr) > 200 {
			inputStr = inputStr[:200] + "..."
		}
	}

	msg := fmt.Sprintf("🔧 **%s**: %s\n\n👍 allow | 👎 deny | 🛑 stop", req.ToolName, inputStr)

	// Send the message
	resp, err := b.client.SendText(ctx, roomID, msg)
	if err != nil {
		log.Printf("Failed to send approval request: %v", err)
		return ApprovalResponse{Decision: "deny", Message: "Failed to send approval request"}
	}

	// Set up pending approval
	pending := &pendingApproval{
		eventID:  resp.EventID,
		roomID:   roomID,
		response: make(chan ApprovalResponse, 1),
	}
	b.pendingApprovals.Store(resp.EventID, pending)

	// Wait for reaction with timeout
	log.Printf("Waiting for reaction on event %s", resp.EventID)
	timeout := 5 * time.Minute
	select {
	case response := <-pending.response:
		log.Printf("Received response from channel: %s", response.Decision)
		return response
	case <-time.After(timeout):
		b.pendingApprovals.Delete(resp.EventID)
		return ApprovalResponse{Decision: "deny", Message: "Approval timed out"}
	case <-ctx.Done():
		b.pendingApprovals.Delete(resp.EventID)
		return ApprovalResponse{Decision: "deny", Message: "Context cancelled"}
	}
}

// formatToolDetail extracts a human-readable summary from tool call input
func formatToolDetail(name string, input map[string]interface{}) string {
	switch name {
	case "Bash":
		if cmd, ok := input["command"].(string); ok {
			// For multi-line commands (heredocs, chained), show only the first line
			if idx := strings.IndexByte(cmd, '\n'); idx >= 0 {
				cmd = cmd[:idx] + "..."
			}
			if len(cmd) > 200 {
				cmd = cmd[:200] + "..."
			}
			return cmd
		}
	case "Read":
		if path, ok := input["file_path"].(string); ok {
			return path
		}
	case "Write":
		if path, ok := input["file_path"].(string); ok {
			return path
		}
	case "Edit":
		if path, ok := input["file_path"].(string); ok {
			return path
		}
	case "Glob":
		if pattern, ok := input["pattern"].(string); ok {
			return pattern
		}
	case "Grep":
		if pattern, ok := input["pattern"].(string); ok {
			return pattern
		}
	case "WebSearch":
		if query, ok := input["query"].(string); ok {
			return query
		}
	case "WebFetch":
		if url, ok := input["url"].(string); ok {
			return url
		}
	case "Task":
		if desc, ok := input["description"].(string); ok {
			return desc
		}
	case "AskUserQuestion":
		// Extract the first question and its recommended option (first in array)
		if questions, ok := input["questions"].([]interface{}); ok && len(questions) > 0 {
			if q, ok := questions[0].(map[string]interface{}); ok {
				question, _ := q["question"].(string)
				if options, ok := q["options"].([]interface{}); ok && len(options) > 0 {
					if opt, ok := options[0].(map[string]interface{}); ok {
						label, _ := opt["label"].(string)
						desc, _ := opt["description"].(string)
						// Format: (auto-answered) Q: [question] | A: [label] — [description]
						result := fmt.Sprintf("(auto-answered) Q: %s | A: %s", question, label)
						if desc != "" {
							result += " — " + desc
						}
						if len(result) > 200 {
							result = result[:200] + "..."
						}
						return result
					}
				}
			}
		}
	}
	// Fallback: JSON summary
	data, _ := json.Marshal(input)
	s := string(data)
	if len(s) > 200 {
		s = s[:200] + "..."
	}
	return s
}
