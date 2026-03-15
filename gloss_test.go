package main

import (
	"testing"
)

func TestFormatGlossContext(t *testing.T) {
	// Empty input returns empty
	if got := formatGlossContext(""); got != "" {
		t.Errorf("formatGlossContext(\"\") = %q, want empty", got)
	}

	// Single summary
	got := formatGlossContext("- Zayna Shahzad has been Kevin's boss at Calendly since April of 2025")
	want := "<gloss>\n- Zayna Shahzad has been Kevin's boss at Calendly since April of 2025\n</gloss>"
	if got != want {
		t.Errorf("formatGlossContext() = %q, want %q", got, want)
	}

	// Multiple summaries
	got = formatGlossContext("- Zayna is Kevin's boss\n- Ash is Kevin's wife")
	if !contains(got, "<gloss>") || !contains(got, "</gloss>") {
		t.Errorf("formatGlossContext() missing tags: %q", got)
	}
	if !contains(got, "Zayna") || !contains(got, "Ash") {
		t.Errorf("formatGlossContext() missing summaries: %q", got)
	}
}

func TestScanGloss_EmptyInputs(t *testing.T) {
	// Empty session ID returns empty
	if got := scanGloss("", "hello"); got != "" {
		t.Errorf("scanGloss with empty session = %q, want empty", got)
	}

	// Empty message returns empty
	if got := scanGloss("sess-123", ""); got != "" {
		t.Errorf("scanGloss with empty message = %q, want empty", got)
	}
}

func TestBuildInvocationPlan_GlossContext(t *testing.T) {
	ctx := SessionContext{
		SessionID:    "sess-123",
		HasSession:   true,
		RoomName:     "general",
		Message:      "How is Zayna doing?",
		GlossContext: "- Zayna Shahzad has been Kevin's boss at Calendly since April of 2025",
	}

	plan := buildInvocationPlan(ctx)

	// Should inject gloss tags
	if !contains(plan.Prompt, "<gloss>") {
		t.Errorf("gloss context should inject <gloss> tag: %q", plan.Prompt)
	}
	if !contains(plan.Prompt, "</gloss>") {
		t.Errorf("gloss context should inject </gloss> tag: %q", plan.Prompt)
	}
	if !contains(plan.Prompt, "Zayna Shahzad") {
		t.Errorf("gloss context should include summary: %q", plan.Prompt)
	}
	// Original message should still be present
	if !contains(plan.Prompt, "How is Zayna doing?") {
		t.Errorf("gloss context should preserve original message: %q", plan.Prompt)
	}
}

func TestBuildInvocationPlan_NoGlossOnFreshSession(t *testing.T) {
	ctx := SessionContext{
		HasSession:   false,
		RoomName:     "general",
		Message:      "How is Zayna doing?",
		GlossContext: "- Zayna Shahzad has been Kevin's boss",
	}

	plan := buildInvocationPlan(ctx)

	// Fresh sessions should not inject gloss (no session ID = no gloss scan)
	if contains(plan.Prompt, "<gloss>") {
		t.Errorf("fresh session should not inject gloss: %q", plan.Prompt)
	}
}

func TestBuildInvocationPlan_EmptyGlossContext(t *testing.T) {
	ctx := SessionContext{
		SessionID:    "sess-123",
		HasSession:   true,
		RoomName:     "general",
		Message:      "hello",
		GlossContext: "",
	}

	plan := buildInvocationPlan(ctx)

	// No gloss tags when context is empty
	if contains(plan.Prompt, "<gloss>") {
		t.Errorf("empty gloss context should not inject tags: %q", plan.Prompt)
	}
	if plan.Prompt != "hello" {
		t.Errorf("prompt should be unchanged, got %q", plan.Prompt)
	}
}
