Feature: Tool Approval
  The bridge mediates Claude Code tool permissions via a Unix socket protocol
  and Matrix reactions for interactive approval.

  Background:
    Given the bridge is listening on /tmp/exo-bridge.sock
    And room "general" has an active Claude session

  # --- Auto-approve ---

  Scenario: Tool matching an allow rule is automatically approved
    Given the auto-approve config contains allow rule "Read"
    When exo-hook requests approval for tool "Read" with path "/home/dev/file.txt"
    Then the bridge responds with "allow"

  Scenario: Tool matching a deny rule is automatically denied
    Given the auto-approve config contains deny rule "Bash(rm *)"
    When exo-hook requests approval for tool "Bash" with command "rm -rf /"
    Then the bridge responds with "deny"

  Scenario: Deny rules take precedence over allow rules
    Given the auto-approve config contains allow rule "Bash(*)"
    And the auto-approve config contains deny rule "Bash(rm *)"
    When exo-hook requests approval for tool "Bash" with command "rm -rf /"
    Then the bridge responds with "deny"

  Scenario: Wildcard matching in specifiers
    Given the auto-approve config contains allow rule "Read(/home/dev/*)"
    When exo-hook requests approval for tool "Read" with path "/home/dev/Projects/file.txt"
    Then the bridge responds with "allow"

  # --- Interactive approval ---

  Scenario: Unmatched tool request prompts the user
    Given no auto-approve rule matches tool "Bash" with command "curl example.com"
    When exo-hook requests approval for that tool
    Then the bridge sends an approval prompt to the Matrix room
    And the prompt includes the tool name and command details
    And the bridge waits for a reaction

  Scenario: Thumbs-up reaction approves the tool
    Given an approval prompt is pending for tool "Bash"
    When @alice reacts with thumbs-up
    Then the bridge responds to exo-hook with "allow"

  Scenario: Thumbs-down reaction denies the tool
    Given an approval prompt is pending for tool "Bash"
    When @alice reacts with thumbs-down
    Then the bridge responds to exo-hook with "deny"

  Scenario: Stop-sign reaction denies with interrupt
    Given an approval prompt is pending for tool "Bash"
    When @alice reacts with a stop sign
    Then the bridge responds to exo-hook with "deny" and message "STOP"

  Scenario: Approval times out after 5 minutes
    Given an approval prompt is pending for tool "Bash"
    When 5 minutes elapse with no reaction
    Then the bridge responds to exo-hook with "deny"

  # --- Hook fallback ---

  Scenario: Hook falls back when bridge socket is unavailable
    Given the bridge socket at /tmp/exo-bridge.sock is not available
    When exo-hook receives a tool approval request
    Then it returns "ask" to defer to Claude Code's native permission model
