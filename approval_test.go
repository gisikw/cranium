package main

import (
	"testing"
)

// --- matchWildcard ---
// Spec: tool_approval.feature - "Wildcard matching in specifiers"

func TestMatchWildcard(t *testing.T) {
	tests := []struct {
		pattern string
		value   string
		match   bool
	}{
		// Exact match
		{"git status", "git status", true},
		{"git status", "git push", false},

		// Trailing wildcard
		{"git *", "git status", true},
		{"git *", "git push --force", true},
		{"git *", "curl example.com", false},

		// Leading wildcard
		{"*.txt", "readme.txt", true},
		{"*.txt", "readme.md", false},

		// Middle wildcard
		{"/home/*/file.txt", "/home/dev/file.txt", true},
		{"/home/*/file.txt", "/home/dev/Projects/file.txt", true},

		// Multiple wildcards
		{"/home/*/Projects/*.go", "/home/dev/Projects/main.go", true},

		// No wildcard
		{"exact", "exact", true},
		{"exact", "other", false},
	}
	for _, tt := range tests {
		t.Run(tt.pattern+"_vs_"+tt.value, func(t *testing.T) {
			got := matchWildcard(tt.pattern, tt.value)
			if got != tt.match {
				t.Errorf("matchWildcard(%q, %q) = %v, want %v", tt.pattern, tt.value, got, tt.match)
			}
		})
	}
}

// --- matchesRule ---
// Spec: tool_approval.feature - auto-approve rules

func TestMatchesRule(t *testing.T) {
	tests := []struct {
		name     string
		rule     string
		toolName string
		input    map[string]interface{}
		match    bool
	}{
		{
			"simple tool name match",
			"Read", "Read",
			map[string]interface{}{"file_path": "/any/path"},
			true,
		},
		{
			"simple tool name mismatch",
			"Read", "Write",
			map[string]interface{}{"file_path": "/any/path"},
			false,
		},
		{
			"bash command with wildcard",
			"Bash(git *)", "Bash",
			map[string]interface{}{"command": "git status"},
			true,
		},
		{
			"bash command mismatch",
			"Bash(git *)", "Bash",
			map[string]interface{}{"command": "rm -rf /"},
			false,
		},
		{
			"read with path wildcard",
			"Read(/home/dev/*)", "Read",
			map[string]interface{}{"file_path": "/home/dev/Projects/file.txt"},
			true,
		},
		{
			"read with path mismatch",
			"Read(/home/dev/*)", "Read",
			map[string]interface{}{"file_path": "/etc/passwd"},
			false,
		},
		{
			"write with path wildcard",
			"Write(/home/dev/*)", "Write",
			map[string]interface{}{"file_path": "/home/dev/test.txt"},
			true,
		},
		{
			"edit with path wildcard",
			"Edit(/home/dev/*)", "Edit",
			map[string]interface{}{"file_path": "/home/dev/main.go"},
			true,
		},
		{
			"malformed rule (no closing paren)",
			"Bash(git *", "Bash",
			map[string]interface{}{"command": "git status"},
			false,
		},
		{
			"bash with empty command",
			"Bash(git *)", "Bash",
			map[string]interface{}{},
			false,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := matchesRule(tt.rule, tt.toolName, tt.input)
			if got != tt.match {
				t.Errorf("matchesRule(%q, %q, ...) = %v, want %v", tt.rule, tt.toolName, got, tt.match)
			}
		})
	}
}

// --- checkAutoApprove ---
// Spec: tool_approval.feature - "Deny rules take precedence over allow rules"

func TestCheckAutoApprove(t *testing.T) {
	tests := []struct {
		name     string
		config   AutoApproveConfig
		toolName string
		input    map[string]interface{}
		want     string
	}{
		{
			"allow match",
			AutoApproveConfig{Allow: []string{"Read"}},
			"Read",
			map[string]interface{}{"file_path": "/any"},
			"allow",
		},
		{
			"deny match",
			AutoApproveConfig{Deny: []string{"Bash(rm *)"}},
			"Bash",
			map[string]interface{}{"command": "rm -rf /"},
			"deny",
		},
		{
			"deny takes precedence over allow",
			AutoApproveConfig{
				Allow: []string{"Bash(*)"},
				Deny:  []string{"Bash(rm *)"},
			},
			"Bash",
			map[string]interface{}{"command": "rm -rf /"},
			"deny",
		},
		{
			"no match returns empty",
			AutoApproveConfig{Allow: []string{"Read"}},
			"Bash",
			map[string]interface{}{"command": "ls"},
			"",
		},
		{
			"empty config returns empty",
			AutoApproveConfig{},
			"Read",
			map[string]interface{}{"file_path": "/any"},
			"",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := checkAutoApprove(&tt.config, tt.toolName, tt.input)
			if got != tt.want {
				t.Errorf("checkAutoApprove(..., %q, ...) = %q, want %q", tt.toolName, got, tt.want)
			}
		})
	}
}

// --- formatToolDetail ---
// Spec: edit_in_place.feature - "Tool calls are rendered as blockquoted summaries"

func TestFormatToolDetail(t *testing.T) {
	tests := []struct {
		name     string
		toolName string
		input    map[string]interface{}
		expected string
	}{
		{"bash command", "Bash", map[string]interface{}{"command": "git status"}, "git status"},
		{"read file", "Read", map[string]interface{}{"file_path": "/home/dev/file.txt"}, "/home/dev/file.txt"},
		{"write file", "Write", map[string]interface{}{"file_path": "/home/dev/out.txt"}, "/home/dev/out.txt"},
		{"edit file", "Edit", map[string]interface{}{"file_path": "/home/dev/main.go"}, "/home/dev/main.go"},
		{"glob pattern", "Glob", map[string]interface{}{"pattern": "**/*.go"}, "**/*.go"},
		{"grep pattern", "Grep", map[string]interface{}{"pattern": "TODO"}, "TODO"},
		{"web search", "WebSearch", map[string]interface{}{"query": "golang testing"}, "golang testing"},
		{"web fetch", "WebFetch", map[string]interface{}{"url": "https://example.com"}, "https://example.com"},
		{"task description", "Task", map[string]interface{}{"description": "explore code"}, "explore code"},
		{
			"ask user question",
			"AskUserQuestion",
			map[string]interface{}{
				"questions": []interface{}{
					map[string]interface{}{
						"question": "Which approach should we use?",
						"header":   "Approach",
						"options": []interface{}{
							map[string]interface{}{
								"label":       "Option 1",
								"description": "Use the simple approach",
							},
							map[string]interface{}{
								"label":       "Option 2",
								"description": "Use the complex approach",
							},
						},
					},
				},
			},
			"(auto-answered) Q: Which approach should we use? | A: Option 1 — Use the simple approach",
		},
		{
			"ask user question without description",
			"AskUserQuestion",
			map[string]interface{}{
				"questions": []interface{}{
					map[string]interface{}{
						"question": "Continue?",
						"header":   "Action",
						"options": []interface{}{
							map[string]interface{}{
								"label":       "Yes",
								"description": "",
							},
						},
					},
				},
			},
			"(auto-answered) Q: Continue? | A: Yes",
		},
		{"unknown tool", "Unknown", map[string]interface{}{"foo": "bar"}, `{"foo":"bar"}`},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := formatToolDetail(tt.toolName, tt.input)
			if got != tt.expected {
				t.Errorf("formatToolDetail(%q, ...) = %q, want %q", tt.toolName, got, tt.expected)
			}
		})
	}
}

func TestFormatToolDetail_LongCommand(t *testing.T) {
	// Bash commands over 200 chars should be truncated
	longCmd := ""
	for i := 0; i < 250; i++ {
		longCmd += "x"
	}
	got := formatToolDetail("Bash", map[string]interface{}{"command": longCmd})
	if len(got) != 203 { // 200 + "..."
		t.Errorf("expected truncated length 203, got %d", len(got))
	}
	if got[200:] != "..." {
		t.Errorf("expected trailing '...', got %q", got[200:])
	}
}

func TestFormatToolDetail_LongAskUserQuestion(t *testing.T) {
	// AskUserQuestion responses over 200 chars should be truncated
	longQuestion := ""
	for i := 0; i < 100; i++ {
		longQuestion += "x"
	}
	longLabel := ""
	for i := 0; i < 100; i++ {
		longLabel += "y"
	}
	got := formatToolDetail("AskUserQuestion", map[string]interface{}{
		"questions": []interface{}{
			map[string]interface{}{
				"question": longQuestion,
				"options": []interface{}{
					map[string]interface{}{
						"label":       longLabel,
						"description": "desc",
					},
				},
			},
		},
	})
	if len(got) != 203 { // 200 + "..."
		t.Errorf("expected truncated length 203, got %d", len(got))
	}
	if got[200:] != "..." {
		t.Errorf("expected trailing '...', got %q", got[200:])
	}
}

// --- htmlEscape ---
// Spec: edit_in_place.feature - "HTML entities are escaped in rendered output"

func TestHtmlEscape(t *testing.T) {
	tests := []struct {
		input    string
		expected string
	}{
		{"hello", "hello"},
		{"<script>", "&lt;script&gt;"},
		{`"quoted"`, "&quot;quoted&quot;"},
		{"a & b", "a &amp; b"},
		{"<a href=\"x\">", "&lt;a href=&quot;x&quot;&gt;"},
	}
	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			got := htmlEscape(tt.input)
			if got != tt.expected {
				t.Errorf("htmlEscape(%q) = %q, want %q", tt.input, got, tt.expected)
			}
		})
	}
}

// --- normalizeEmoji / mapEmojiToApproval ---
// Spec: tool_approval.feature - reactions

func TestNormalizeEmoji(t *testing.T) {
	tests := []struct {
		input    string
		expected string
	}{
		{"👍", "👍"},
		{"👍\ufe0f", "👍"},  // with variation selector
		{"👍\ufe0e", "👍"},  // with text variation selector
		{"✅", "✅"},
	}
	for _, tt := range tests {
		t.Run(tt.expected, func(t *testing.T) {
			got := normalizeEmoji(tt.input)
			if got != tt.expected {
				t.Errorf("normalizeEmoji(%q) = %q, want %q", tt.input, got, tt.expected)
			}
		})
	}
}

func TestMapEmojiToApproval(t *testing.T) {
	tests := []struct {
		emoji      string
		decision   string
		recognized bool
	}{
		{"👍", "allow", true},
		{"✅", "allow", true},
		{"👎", "deny", true},
		{"🛑", "deny", true},
		{"⛔", "deny", true},
		{"❤️", "", false},
		{"🎉", "", false},
	}
	for _, tt := range tests {
		t.Run(tt.emoji, func(t *testing.T) {
			resp, ok := mapEmojiToApproval(tt.emoji)
			if ok != tt.recognized {
				t.Errorf("mapEmojiToApproval(%q) recognized = %v, want %v", tt.emoji, ok, tt.recognized)
			}
			if ok && resp.Decision != tt.decision {
				t.Errorf("mapEmojiToApproval(%q) decision = %q, want %q", tt.emoji, resp.Decision, tt.decision)
			}
		})
	}
}

func TestMapEmojiToApproval_StopHasMessage(t *testing.T) {
	resp, ok := mapEmojiToApproval("🛑")
	if !ok || resp.Message != "STOP" {
		t.Errorf("stop sign should produce STOP message, got %q", resp.Message)
	}
}
