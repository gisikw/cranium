Feature: Cross-Room Awareness
  The bridge maintains per-room conversation summaries so that sessions in
  one room have awareness of activity in other rooms.

  Background:
    Given the bridge is connected to Matrix as @exo

  # --- Summary generation ---

  Scenario: Summary is generated after 10 turns
    Given room "general" has an active session
    And 9 turns have occurred since the last summary
    When @alice sends a message and Claude responds (turn 10)
    Then a summary is generated asynchronously for room "general"

  Scenario: Summary is not generated before 10 turns
    Given room "general" has an active session
    And 5 turns have occurred since the last summary
    When @alice sends a message and Claude responds (turn 6)
    Then no summary generation is triggered

  Scenario: Summary generation uses a forked session
    When summary generation triggers for room "general" with session "sess-123"
    Then Claude is invoked with --resume "sess-123" --fork-session
    And the invocation uses --no-session-persistence
    And the invocation uses --tools "" to disable tool use

  Scenario: Concurrent summary generation for the same room is prevented
    Given summary generation is already running for room "general"
    When summary generation triggers again for room "general"
    Then the second generation is skipped

  # --- Summary storage ---

  Scenario: Generated summary is persisted to disk
    When summary generation completes for room "general"
    Then a JSON file is written to summaries/general.json
    And it contains the room name, summary text, and timestamp

  # --- Summary injection on fresh session ---

  Scenario: New session receives cross-room context
    Given room "general" has no session ID
    And room "infra" has a summary "Working on bridge tests"
    And room "personal" has a summary "Discussing weekend plans"
    When @alice starts a conversation in "general"
    Then the session is created with --append-system-prompt
    And the system prompt includes a <cross-room-context> block
    And the block includes summaries from "infra" and "personal"
    But does not include a summary from "general" itself

  # --- Summary freshness filtering ---

  Scenario: Stale summaries are excluded from time-gap injection
    Given room "infra" has a summary from 25 hours ago
    And the time gap for the current session is 2 hours
    Then the summary from "infra" is excluded (max age = 4 hours)

  Scenario: All summaries are included for fresh sessions
    Given room "infra" has a summary from 3 days ago
    When a fresh session starts in "general"
    Then the summary from "infra" is included (no max age filter)
