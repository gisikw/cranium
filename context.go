package main

import (
	"fmt"
	"strings"
	"time"
)

// contextSaturationAdvice returns guidance text based on context usage percentage
func contextSaturationAdvice(pct int) string {
	switch {
	case pct >= 80:
		return "Context is getting full. Wrap up current work, capture any loose threads as tickets, and suggest a !clear."
	case pct >= 70:
		return "Context is filling up. Start wrapping up — finish current task, note open threads."
	case pct >= 60:
		return "Context is past halfway. Be mindful of scope — avoid starting large new tasks."
	default:
		return "Context is past halfway."
	}
}

// shouldInjectTimeGap returns true if enough time has elapsed since the last
// invocation to warrant a time-awareness reminder.
func shouldInjectTimeGap(elapsed time.Duration) bool {
	return elapsed > 30*time.Minute
}

// formatTimeGap constructs the time-gap system-reminder text.
func formatTimeGap(elapsed time.Duration, now time.Time, landscape string) string {
	gap := formatDuration(elapsed)
	text := fmt.Sprintf("It's been %s since the last message in this conversation. The current time is %s.",
		gap, now.Format("Mon Jan 2, 3:04 PM"))
	if landscape != "" {
		text += "\n\n" + landscape
	}
	return text
}

// timeGapMaxAge returns the max summary age for cross-room landscape in a
// time-gap injection: 2x the elapsed time, capped at 24 hours.
func timeGapMaxAge(elapsed time.Duration) time.Duration {
	maxAge := elapsed * 2
	if maxAge > 24*time.Hour {
		maxAge = 24 * time.Hour
	}
	return maxAge
}

// shouldInjectSaturationReminder returns true if we should inject a context
// saturation system-reminder. Uses rising-edge detection: only fires when
// crossing into a new 5% bucket above 50%.
func shouldInjectSaturationReminder(lastPct, lastReminderBucket int) bool {
	if lastPct < 50 {
		return false
	}
	currentBucket := lastPct / 5 * 5
	return currentBucket > lastReminderBucket
}

// saturationBucket returns the 5%-aligned bucket for a saturation percentage.
func saturationBucket(pct int) int {
	return pct / 5 * 5
}

// formatSaturationReminder constructs the saturation system-reminder text.
func formatSaturationReminder(pct int) string {
	return fmt.Sprintf("<system-reminder>Context window saturation: %d%%. %s</system-reminder>",
		pct, contextSaturationAdvice(pct))
}

// prependSystemReminder wraps text in system-reminder tags and prepends it to a prompt.
func prependSystemReminder(reminder, prompt string) string {
	return fmt.Sprintf("<system-reminder>%s</system-reminder>\n\n%s", reminder, prompt)
}

// buildFreshSessionPrompt prepends the room name to a message for fresh sessions.
func buildFreshSessionPrompt(roomName, message string) string {
	if roomName == "" {
		return message
	}
	return fmt.Sprintf("[Matrix room: %s]\n\n%s", roomName, message)
}

// buildAppendSystemPrompt constructs the --append-system-prompt value from
// handoff content and cross-room landscape. Canary values are embedded for
// delivery verification — ask the agent "what is the handoff/landscape canary?"
func buildAppendSystemPrompt(handoffContent, landscape string, now time.Time) string {
	dateSeed := now.Format("2006-01-02")
	var parts []string
	if handoffContent != "" {
		canary := fmt.Sprintf("%x", hashCanary("handoff", dateSeed))
		parts = append(parts, fmt.Sprintf("<room-handoff>\ncanary:handoff=%s\nThis is the handoff from your previous session in this room. Use it for context but don't reference it explicitly unless asked.\n\n%s\n</room-handoff>", canary, handoffContent))
	}
	if landscape != "" {
		canary := fmt.Sprintf("%x", hashCanary("landscape", dateSeed))
		parts = append(parts, fmt.Sprintf("<cross-room-context>\ncanary:landscape=%s\n%s\n</cross-room-context>", canary, landscape))
	}
	return strings.Join(parts, "\n\n")
}

// hashCanary produces a short deterministic canary value from a label and date seed.
func hashCanary(label, dateSeed string) uint32 {
	h := uint32(2166136261) // FNV-1a offset basis
	for _, b := range []byte(label + ":" + dateSeed) {
		h ^= uint32(b)
		h *= 16777619
	}
	return h
}

// buildCLIArgs constructs the Claude CLI argument list.
// The "--" sentinel separates flags from the positional prompt argument,
// preventing messages that start with "-" from being parsed as flags.
// If systemPromptFile is set, uses --append-system-prompt-file instead of inline.
func buildCLIArgs(prompt, sessionID, systemPromptFile string) []string {
	args := []string{"-p", "--output-format", "stream-json", "--verbose", "--dangerously-skip-permissions"}
	if systemPromptFile != "" {
		args = append(args, "--append-system-prompt-file", systemPromptFile)
	}
	if sessionID != "" {
		args = append(args, "--resume", sessionID)
	}
	args = append(args, "--", prompt)
	return args
}

// InvocationPlan contains all decisions made before invoking Claude.
// Separates decision logic from I/O operations per INVARIANTS.md.
type InvocationPlan struct {
	Prompt                   string
	SessionID                string
	AppendSystemPrompt       string // content to write to file; empty means don't pass --append-system-prompt-file
	ShouldMarkInvoked        bool
	ShouldUpdateReminderAt   bool
	ReminderBucket           int
	WorkDir                  string // project dir if matched, otherwise empty (caller defaults to dataDir)
}

// SessionContext holds all input data needed to plan a Claude invocation.
type SessionContext struct {
	SessionID          string
	HasSession         bool
	RoomName           string
	Message            string
	HandoffContent     string
	LastSaturation     int
	LastReminderAt     int
	TimeSinceLast      time.Duration
	Landscape          string
	InterruptedContext string
	Now                time.Time
	ProjectDir         string // ~/Projects/<slug> if it exists as a directory
	SystemPromptContent string // contents of identity file, always injected via --append-system-prompt
	GlossContext       string // formatted gloss summaries for first-mention term injection
}

// buildInvocationPlan is a pure function that makes all invocation decisions.
// Takes session context in, returns an invocation plan out. No I/O, no side effects.
func buildInvocationPlan(ctx SessionContext) InvocationPlan {
	isFreshSession := !ctx.HasSession || ctx.SessionID == ""
	prompt := ctx.Message

	// For fresh sessions, prepend room context
	if isFreshSession {
		prompt = buildFreshSessionPrompt(ctx.RoomName, ctx.Message)
	}

	// For existing sessions: inject time gap reminder if needed
	if !isFreshSession && shouldInjectTimeGap(ctx.TimeSinceLast) {
		ct, _ := time.LoadLocation("America/Chicago")
		now := ctx.Now.In(ct)
		// Use provided landscape (caller computed with correct maxAge via timeGapMaxAge)
		landscape := ctx.Landscape
		gapText := formatTimeGap(ctx.TimeSinceLast, now, landscape)
		prompt = prependSystemReminder(gapText, prompt)
	}

	// For existing sessions: inject interrupted context if present
	if !isFreshSession && ctx.InterruptedContext != "" {
		interruptedReminder := fmt.Sprintf("Your previous turn was interrupted by the user (stop emoji). Here's what you were doing when stopped:\n\n%s\n\nThe user stopped you — pick up from here or ask what they'd like instead.", ctx.InterruptedContext)
		prompt = prependSystemReminder(interruptedReminder, prompt)
	}

	// For existing sessions: inject gloss context for first-mention terms
	if !isFreshSession && ctx.GlossContext != "" {
		prompt = formatGlossContext(ctx.GlossContext) + "\n\n" + prompt
	}

	// For existing sessions: inject saturation reminder if threshold crossed
	shouldUpdateReminder := false
	reminderBucket := 0
	if !isFreshSession && shouldInjectSaturationReminder(ctx.LastSaturation, ctx.LastReminderAt) {
		prompt = formatSaturationReminder(ctx.LastSaturation) + "\n\n" + prompt
		shouldUpdateReminder = true
		reminderBucket = saturationBucket(ctx.LastSaturation)
	}

	// Build append-system-prompt content: only for fresh sessions.
	// Resumed sessions reuse the file written at creation (handled in invokeClaude)
	// rather than rebuilding content here, preserving the original handoff/landscape.
	var appendSystemPrompt string
	if isFreshSession {
		var appendParts []string
		if ctx.SystemPromptContent != "" {
			appendParts = append(appendParts, ctx.SystemPromptContent)
		}
		if extra := buildAppendSystemPrompt(ctx.HandoffContent, ctx.Landscape, ctx.Now); extra != "" {
			appendParts = append(appendParts, extra)
		}
		appendSystemPrompt = strings.Join(appendParts, "\n\n")
	}

	// Determine effective session ID and whether to mark as invoked
	effectiveSessionID := ""
	shouldMarkInvoked := false
	if !isFreshSession {
		effectiveSessionID = ctx.SessionID
		shouldMarkInvoked = true
	}

	// When a project dir is matched, always use it as working directory.
	// Fresh sessions start there; resumed sessions need to return to the
	// same cwd they were created in.
	var workDir string
	if ctx.ProjectDir != "" {
		workDir = ctx.ProjectDir
	}

	return InvocationPlan{
		Prompt:                 prompt,
		SessionID:              effectiveSessionID,
		AppendSystemPrompt:     appendSystemPrompt,
		ShouldMarkInvoked:      shouldMarkInvoked,
		ShouldUpdateReminderAt: shouldUpdateReminder,
		ReminderBucket:         reminderBucket,
		WorkDir:                workDir,
	}
}
