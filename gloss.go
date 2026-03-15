package main

import (
	"encoding/json"
	"fmt"
	"log"
	"os/exec"
	"strings"
)

// glossMatch represents a single term match from gloss scan.
type glossMatch struct {
	Term       string `json:"term"`
	Confidence int    `json:"confidence"`
	Version    int    `json:"version"`
	Summary    string `json:"summary"`
	Detail     string `json:"detail"`
}

// glossResult is the JSON output from gloss scan.
type glossResult struct {
	Matches []glossMatch `json:"matches"`
}

// scanGloss calls `gloss scan --session <id> --message <msg>` and returns
// formatted context for injection, or empty string if no matches.
func scanGloss(sessionID, message string) string {
	if sessionID == "" || message == "" {
		return ""
	}

	cmd := exec.Command("gloss", "scan", "--session", sessionID, "--message", message)
	out, err := cmd.Output()
	if err != nil {
		log.Printf("gloss scan failed: %v", err)
		return ""
	}

	var result glossResult
	if err := json.Unmarshal(out, &result); err != nil {
		log.Printf("gloss scan: failed to parse output: %v", err)
		return ""
	}

	if len(result.Matches) == 0 {
		return ""
	}

	var summaries []string
	for _, m := range result.Matches {
		summaries = append(summaries, fmt.Sprintf("- %s", m.Summary))
	}

	return strings.Join(summaries, "\n")
}

// formatGlossContext wraps gloss summaries in <gloss> tags for prompt injection.
func formatGlossContext(glossContext string) string {
	if glossContext == "" {
		return ""
	}
	return fmt.Sprintf("<gloss>\n%s\n</gloss>", glossContext)
}
