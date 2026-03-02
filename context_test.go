package main

import (
	"fmt"
	"testing"
	"time"
)

// --- ContextInfo.Saturation ---
// Spec: context_saturation.feature

func TestSaturation(t *testing.T) {
	tests := []struct {
		name   string
		used   int
		window int
		want   int
	}{
		{"zero window returns 0", 1000, 0, 0},
		{"empty context", 0, 200000, 0},
		{"50 percent", 100000, 200000, 50},
		{"75 percent", 150000, 200000, 75},
		{"100 percent", 200000, 200000, 100},
		{"real-world usage", 85432, 200000, 42},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ci := ContextInfo{UsedTokens: tt.used, ContextWindow: tt.window}
			if got := ci.Saturation(); got != tt.want {
				t.Errorf("Saturation() = %d, want %d", got, tt.want)
			}
		})
	}
}

// --- contextSaturationAdvice ---
// Spec: context_saturation.feature - "Escalating advice"

func TestContextSaturationAdvice(t *testing.T) {
	tests := []struct {
		pct      int
		contains string
	}{
		{80, "suggest a !clear"},
		{85, "suggest a !clear"},
		{95, "suggest a !clear"},
		{70, "Start wrapping up"},
		{75, "Start wrapping up"},
		{60, "Be mindful of scope"},
		{65, "Be mindful of scope"},
		{50, "past halfway"},
		{55, "past halfway"},
	}
	for _, tt := range tests {
		t.Run(tt.contains, func(t *testing.T) {
			got := contextSaturationAdvice(tt.pct)
			if got == "" {
				t.Fatalf("contextSaturationAdvice(%d) returned empty string", tt.pct)
			}
			if !contains(got, tt.contains) {
				t.Errorf("contextSaturationAdvice(%d) = %q, want it to contain %q", tt.pct, got, tt.contains)
			}
		})
	}
}

// --- formatDuration ---
// Spec: time_awareness.feature

func TestShouldInjectTimeGap(t *testing.T) {
	tests := []struct {
		elapsed time.Duration
		want    bool
	}{
		{15 * time.Minute, false},
		{30 * time.Minute, false},
		{31 * time.Minute, true},
		{2 * time.Hour, true},
		{0, false},
	}
	for _, tt := range tests {
		t.Run(tt.elapsed.String(), func(t *testing.T) {
			got := shouldInjectTimeGap(tt.elapsed)
			if got != tt.want {
				t.Errorf("shouldInjectTimeGap(%v) = %v, want %v", tt.elapsed, got, tt.want)
			}
		})
	}
}

func TestFormatTimeGap(t *testing.T) {
	now := time.Date(2026, 2, 12, 14, 30, 0, 0, time.UTC)

	// Without landscape
	got := formatTimeGap(45*time.Minute, now, "")
	if !contains(got, "about 45 minutes") || !contains(got, "Thu Feb 12, 2:30 PM") {
		t.Errorf("formatTimeGap without landscape = %q", got)
	}

	// With landscape
	got = formatTimeGap(2*time.Hour, now, "Here's what's happening in your other rooms:\n- **infra**: debugging")
	if !contains(got, "about 2 hours") || !contains(got, "other rooms") {
		t.Errorf("formatTimeGap with landscape = %q", got)
	}
}

func TestTimeGapMaxAge(t *testing.T) {
	tests := []struct {
		elapsed time.Duration
		want    time.Duration
	}{
		{1 * time.Hour, 2 * time.Hour},
		{6 * time.Hour, 12 * time.Hour},
		{13 * time.Hour, 24 * time.Hour}, // capped at 24h
		{48 * time.Hour, 24 * time.Hour}, // capped at 24h
	}
	for _, tt := range tests {
		t.Run(tt.elapsed.String(), func(t *testing.T) {
			got := timeGapMaxAge(tt.elapsed)
			if got != tt.want {
				t.Errorf("timeGapMaxAge(%v) = %v, want %v", tt.elapsed, got, tt.want)
			}
		})
	}
}

// --- Saturation reminder ---
// Spec: context_saturation.feature - "Saturation reminder is injected at 5% threshold crossings"

func TestShouldInjectSaturationReminder(t *testing.T) {
	tests := []struct {
		name               string
		lastPct            int
		lastReminderBucket int
		want               bool
	}{
		{"below 50 — no", 45, 0, false},
		{"at 50, no prior reminder — yes", 52, 0, true},
		{"at 52, already reminded at 50 — no", 52, 50, false},
		{"at 56, reminded at 50 — yes (crosses 55)", 56, 50, true},
		{"at 82, reminded at 75 — yes (crosses 80)", 82, 75, true},
		{"at 82, reminded at 80 — no", 82, 80, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := shouldInjectSaturationReminder(tt.lastPct, tt.lastReminderBucket)
			if got != tt.want {
				t.Errorf("shouldInjectSaturationReminder(%d, %d) = %v, want %v",
					tt.lastPct, tt.lastReminderBucket, got, tt.want)
			}
		})
	}
}

func TestSaturationBucket(t *testing.T) {
	tests := []struct {
		pct  int
		want int
	}{
		{52, 50}, {55, 55}, {59, 55}, {60, 60}, {78, 75}, {80, 80}, {99, 95},
	}
	for _, tt := range tests {
		t.Run(fmt.Sprintf("%d", tt.pct), func(t *testing.T) {
			got := saturationBucket(tt.pct)
			if got != tt.want {
				t.Errorf("saturationBucket(%d) = %d, want %d", tt.pct, got, tt.want)
			}
		})
	}
}

// --- Prompt building ---
// Spec: message_routing.feature, session_lifecycle.feature, time_awareness.feature

func TestBuildFreshSessionPrompt(t *testing.T) {
	got := buildFreshSessionPrompt("general", "hello")
	if got != "[Matrix room: general]\n\nhello" {
		t.Errorf("buildFreshSessionPrompt with name = %q", got)
	}

	got = buildFreshSessionPrompt("", "hello")
	if got != "hello" {
		t.Errorf("buildFreshSessionPrompt without name = %q", got)
	}
}

func TestBuildAppendSystemPrompt(t *testing.T) {
	now := time.Date(2026, 3, 2, 12, 0, 0, 0, time.UTC)

	// Both handoff and landscape
	got := buildAppendSystemPrompt("handoff text", "landscape text", now)
	if !contains(got, "<room-handoff>") || !contains(got, "<cross-room-context>") {
		t.Errorf("both = %q", got)
	}
	if !contains(got, "canary:handoff=") || !contains(got, "canary:landscape=") {
		t.Errorf("missing canary values: %q", got)
	}

	// Handoff only
	got = buildAppendSystemPrompt("handoff text", "", now)
	if !contains(got, "<room-handoff>") || contains(got, "<cross-room-context>") {
		t.Errorf("handoff only = %q", got)
	}

	// Landscape only
	got = buildAppendSystemPrompt("", "landscape text", now)
	if contains(got, "<room-handoff>") || !contains(got, "<cross-room-context>") {
		t.Errorf("landscape only = %q", got)
	}

	// Neither
	got = buildAppendSystemPrompt("", "", now)
	if got != "" {
		t.Errorf("neither = %q, want empty", got)
	}

	// Canaries are deterministic for the same date
	a := buildAppendSystemPrompt("x", "y", now)
	b := buildAppendSystemPrompt("x", "y", now)
	if a != b {
		t.Errorf("canaries should be deterministic for the same date")
	}

	// Canaries differ across dates
	tomorrow := now.Add(24 * time.Hour)
	c := buildAppendSystemPrompt("x", "y", tomorrow)
	if a == c {
		t.Errorf("canaries should differ across dates")
	}
}

func TestBuildCLIArgs(t *testing.T) {
	// Fresh session: prompt should come after "--" sentinel
	args := buildCLIArgs("hello", "", "")
	if args[len(args)-1] != "hello" || args[len(args)-2] != "--" {
		t.Errorf("fresh session args should end with [\"--\", \"hello\"], got %v", args)
	}
	if args[0] != "-p" {
		t.Errorf("first arg should be -p, got %v", args[0])
	}

	// Resume session
	args = buildCLIArgs("hello", "sess-123", "")
	found := false
	for i, a := range args {
		if a == "--resume" && i+1 < len(args) && args[i+1] == "sess-123" {
			found = true
		}
	}
	if !found {
		t.Errorf("resume args missing --resume sess-123: %v", args)
	}
	// Prompt still at the end after "--"
	if args[len(args)-1] != "hello" || args[len(args)-2] != "--" {
		t.Errorf("resume args should end with [\"--\", \"hello\"], got %v", args)
	}

	// With system prompt file
	args = buildCLIArgs("hello", "", "/tmp/prompt.md")
	found = false
	for i, a := range args {
		if a == "--append-system-prompt-file" && i+1 < len(args) && args[i+1] == "/tmp/prompt.md" {
			found = true
		}
	}
	if !found {
		t.Errorf("append args missing --append-system-prompt-file: %v", args)
	}

	// Message starting with dash — the original crash scenario
	args = buildCLIArgs("- bullet point", "", "")
	if args[len(args)-1] != "- bullet point" || args[len(args)-2] != "--" {
		t.Errorf("dash message should be safe after \"--\" sentinel, got %v", args)
	}

	// Message starting with double dash
	args = buildCLIArgs("--verbose is a flag", "sess-123", "")
	if args[len(args)-1] != "--verbose is a flag" || args[len(args)-2] != "--" {
		t.Errorf("double-dash message should be safe after \"--\" sentinel, got %v", args)
	}
}

func TestFormatDuration(t *testing.T) {
	tests := []struct {
		name     string
		d        time.Duration
		expected string
	}{
		{"minutes only", 45 * time.Minute, "about 45 minutes"},
		{"one hour exact", 60 * time.Minute, "about 1 hours"},
		{"hours and minutes", 2*time.Hour + 30*time.Minute, "2h30m"},
		{"hours exact", 3 * time.Hour, "about 3 hours"},
		{"one day", 24 * time.Hour, "about a day"},
		{"multiple days", 72 * time.Hour, "about 3 days"},
		{"zero minutes", 0, "about 0 minutes"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := formatDuration(tt.d)
			if got != tt.expected {
				t.Errorf("formatDuration(%v) = %q, want %q", tt.d, got, tt.expected)
			}
		})
	}
}

// --- formatSaturationReminder ---
// Spec: context_saturation.feature - saturation reminder injection

func TestFormatSaturationReminder(t *testing.T) {
	got := formatSaturationReminder(75)
	if !contains(got, "75%") {
		t.Errorf("expected percentage in output, got %q", got)
	}
	if !contains(got, "system-reminder") {
		t.Errorf("expected system-reminder tags, got %q", got)
	}
	if !contains(got, "Start wrapping up") {
		t.Errorf("expected advice text, got %q", got)
	}
}

// --- Integration tests: prependSystemReminder ---
// Spec: time_awareness.feature, context_saturation.feature

func TestPrependSystemReminder(t *testing.T) {
	got := prependSystemReminder("Hello world", "user prompt")
	if !contains(got, "<system-reminder>Hello world</system-reminder>") {
		t.Errorf("missing system-reminder tags: %q", got)
	}
	if !contains(got, "user prompt") {
		t.Errorf("missing user prompt: %q", got)
	}
}

// --- buildInvocationPlan ---
// Spec: session_lifecycle.feature, time_awareness.feature, context_saturation.feature
// Pure decision function that makes all invocation decisions without I/O

func TestBuildInvocationPlan_FreshSession(t *testing.T) {
	ctx := SessionContext{
		SessionID:      "",
		HasSession:     false,
		RoomName:       "general",
		Message:        "hello",
		HandoffContent: "previous context",
		Landscape:      "other rooms active",
	}

	plan := buildInvocationPlan(ctx)

	// Fresh session should prepend room name
	if !contains(plan.Prompt, "[Matrix room: general]") {
		t.Errorf("fresh session prompt missing room name: %q", plan.Prompt)
	}
	if !contains(plan.Prompt, "hello") {
		t.Errorf("fresh session prompt missing message: %q", plan.Prompt)
	}

	// Fresh session should have append-system-prompt with handoff and landscape
	if !contains(plan.AppendSystemPrompt, "previous context") {
		t.Errorf("fresh session missing handoff in append-system-prompt: %q", plan.AppendSystemPrompt)
	}
	if !contains(plan.AppendSystemPrompt, "other rooms active") {
		t.Errorf("fresh session missing landscape in append-system-prompt: %q", plan.AppendSystemPrompt)
	}

	// Fresh session should not mark as invoked
	if plan.ShouldMarkInvoked {
		t.Errorf("fresh session should not mark as invoked")
	}

	// Fresh session should have empty session ID
	if plan.SessionID != "" {
		t.Errorf("fresh session should have empty session ID, got %q", plan.SessionID)
	}

	// AppendSystemPrompt should be non-empty (caller writes to file and passes via --append-system-prompt-file)
	if plan.AppendSystemPrompt == "" {
		t.Errorf("fresh session should have non-empty AppendSystemPrompt")
	}
}

func TestBuildInvocationPlan_ExistingSession(t *testing.T) {
	ctx := SessionContext{
		SessionID:      "sess-123",
		HasSession:     true,
		RoomName:       "general",
		Message:        "hello again",
		TimeSinceLast:  10 * time.Minute, // under threshold
		LastSaturation: 45,               // under 50%
	}

	plan := buildInvocationPlan(ctx)

	// Existing session should not prepend room name
	if contains(plan.Prompt, "[Matrix room:") {
		t.Errorf("existing session should not prepend room name: %q", plan.Prompt)
	}
	if plan.Prompt != "hello again" {
		t.Errorf("existing session prompt = %q, want %q", plan.Prompt, "hello again")
	}

	// Existing session should not have append-system-prompt
	if plan.AppendSystemPrompt != "" {
		t.Errorf("existing session should have empty append-system-prompt, got %q", plan.AppendSystemPrompt)
	}

	// Existing session should mark as invoked
	if !plan.ShouldMarkInvoked {
		t.Errorf("existing session should mark as invoked")
	}

	// Existing session should use session ID
	if plan.SessionID != "sess-123" {
		t.Errorf("existing session ID = %q, want %q", plan.SessionID, "sess-123")
	}

	// SessionID should be set (caller passes via --resume)
	if plan.SessionID != "sess-123" {
		t.Errorf("existing session plan.SessionID = %q, want %q", plan.SessionID, "sess-123")
	}
}

func TestBuildInvocationPlan_TimeGapInjection(t *testing.T) {
	ctx := SessionContext{
		SessionID:     "sess-123",
		HasSession:    true,
		RoomName:      "general",
		Message:       "hello",
		TimeSinceLast: 45 * time.Minute, // over 30min threshold
		Landscape:     "**infra**: debugging",
		Now:           time.Date(2026, 2, 17, 14, 0, 0, 0, time.UTC),
	}

	plan := buildInvocationPlan(ctx)

	// Should inject time gap reminder
	if !contains(plan.Prompt, "<system-reminder>") {
		t.Errorf("time gap should inject system-reminder: %q", plan.Prompt)
	}
	if !contains(plan.Prompt, "about 45 minutes") {
		t.Errorf("time gap should include elapsed time: %q", plan.Prompt)
	}
	if !contains(plan.Prompt, "**infra**: debugging") {
		t.Errorf("time gap should include landscape: %q", plan.Prompt)
	}
	if !contains(plan.Prompt, "hello") {
		t.Errorf("time gap should still include original message: %q", plan.Prompt)
	}
}

func TestBuildInvocationPlan_SaturationReminder(t *testing.T) {
	ctx := SessionContext{
		SessionID:      "sess-123",
		HasSession:     true,
		RoomName:       "general",
		Message:        "hello",
		LastSaturation: 76, // in 75% bucket
		LastReminderAt: 70, // last reminded at 70%, should trigger at 75
	}

	plan := buildInvocationPlan(ctx)

	// Should inject saturation reminder
	if !contains(plan.Prompt, "76%") {
		t.Errorf("saturation reminder should include percentage: %q", plan.Prompt)
	}
	if !contains(plan.Prompt, "Start wrapping up") {
		t.Errorf("saturation reminder should include advice: %q", plan.Prompt)
	}

	// Should set reminder update fields
	if !plan.ShouldUpdateReminderAt {
		t.Errorf("plan should indicate reminder update needed")
	}
	if plan.ReminderBucket != 75 {
		t.Errorf("reminder bucket = %d, want 75", plan.ReminderBucket)
	}
}

func TestBuildInvocationPlan_NoSaturationReminderBelowThreshold(t *testing.T) {
	ctx := SessionContext{
		SessionID:      "sess-123",
		HasSession:     true,
		RoomName:       "general",
		Message:        "hello",
		LastSaturation: 45, // below 50%
	}

	plan := buildInvocationPlan(ctx)

	// Should not inject saturation reminder
	if contains(plan.Prompt, "system-reminder") && contains(plan.Prompt, "Context window saturation") {
		t.Errorf("should not inject saturation reminder below 50%%: %q", plan.Prompt)
	}

	// Should not set reminder update fields
	if plan.ShouldUpdateReminderAt {
		t.Errorf("plan should not indicate reminder update for saturation below threshold")
	}
}

func TestBuildInvocationPlan_CombinedTimeGapAndSaturation(t *testing.T) {
	ctx := SessionContext{
		SessionID:      "sess-123",
		HasSession:     true,
		RoomName:       "general",
		Message:        "hello",
		TimeSinceLast:  45 * time.Minute,
		LastSaturation: 76,
		LastReminderAt: 70,
		Landscape:      "other activity",
	}

	plan := buildInvocationPlan(ctx)

	// Should inject both reminders
	if !contains(plan.Prompt, "about 45 minutes") {
		t.Errorf("should include time gap: %q", plan.Prompt)
	}
	if !contains(plan.Prompt, "76%") {
		t.Errorf("should include saturation: %q", plan.Prompt)
	}
}

func TestBuildInvocationPlan_InterruptedContext(t *testing.T) {
	ctx := SessionContext{
		SessionID:          "sess-123",
		HasSession:         true,
		Message:            "continue from where we were",
		InterruptedContext: "Some partial output\n\n> **Read** file.txt\n\nMore work...",
	}

	plan := buildInvocationPlan(ctx)

	// Should inject interrupted context as system-reminder
	if !contains(plan.Prompt, "Your previous turn was interrupted") {
		t.Errorf("should include interrupted context marker: %q", plan.Prompt)
	}
	if !contains(plan.Prompt, "Some partial output") {
		t.Errorf("should include partial output content: %q", plan.Prompt)
	}
	if !contains(plan.Prompt, "stop emoji") {
		t.Errorf("should mention stop emoji: %q", plan.Prompt)
	}
}

func TestBuildInvocationPlan_ProjectDir(t *testing.T) {
	ctx := SessionContext{
		SessionID:    "",
		HasSession:   false,
		RoomName:     "knockout",
		Message:      "hello",
		ProjectDir:   "/home/dev/Projects/knockout",
		SystemPromptContent: "# System Prompt\nBoot context here.",
	}

	plan := buildInvocationPlan(ctx)

	// Should set WorkDir to project directory
	if plan.WorkDir != "/home/dev/Projects/knockout" {
		t.Errorf("plan.WorkDir = %q, want %q", plan.WorkDir, "/home/dev/Projects/knockout")
	}

	// Should include IDENTITY.md content in append-system-prompt
	if !contains(plan.AppendSystemPrompt, "# System Prompt") {
		t.Errorf("append-system-prompt missing IDENTITY.md content: %q", plan.AppendSystemPrompt)
	}
}

func TestBuildInvocationPlan_NoProjectDir(t *testing.T) {
	ctx := SessionContext{
		SessionID:    "",
		HasSession:   false,
		RoomName:     "general",
		Message:      "hello",
		ProjectDir:   "", // no matching project
		SystemPromptContent: "# System Prompt\nBoot context here.",
	}

	plan := buildInvocationPlan(ctx)

	// WorkDir should be empty (caller defaults to dataDir)
	if plan.WorkDir != "" {
		t.Errorf("plan.WorkDir should be empty when no project dir, got %q", plan.WorkDir)
	}

	// Should still include IDENTITY.md content in append-system-prompt
	if !contains(plan.AppendSystemPrompt, "# System Prompt") {
		t.Errorf("append-system-prompt missing IDENTITY.md content without project dir: %q", plan.AppendSystemPrompt)
	}
}

func TestBuildInvocationPlan_ResumedSessionOmitsSystemPrompt(t *testing.T) {
	// Resumed sessions don't build new system prompt content in the plan.
	// The caller (invokeClaude) reuses the file written at session creation.
	ctx := SessionContext{
		SessionID:           "sess-123",
		HasSession:          true,
		RoomName:            "general",
		Message:             "hello",
		SystemPromptContent: "# System Prompt\nBoot context.",
	}

	plan := buildInvocationPlan(ctx)

	if plan.AppendSystemPrompt != "" {
		t.Errorf("resumed session should have empty append-system-prompt, got %q", plan.AppendSystemPrompt)
	}
}

func TestBuildInvocationPlan_NoInterruptedContextForFreshSession(t *testing.T) {
	ctx := SessionContext{
		HasSession:         false,
		RoomName:           "test-room",
		Message:            "new message",
		InterruptedContext: "This should be ignored for fresh sessions",
	}

	plan := buildInvocationPlan(ctx)

	// Fresh session should not inject interrupted context
	if contains(plan.Prompt, "interrupted") {
		t.Errorf("fresh session should not inject interrupted context: %q", plan.Prompt)
	}
}
