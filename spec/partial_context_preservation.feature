Feature: Partial context preservation after stop emoji

  When a stop emoji cancels an active invocation, the partial output accumulated
  during that turn is preserved and injected into the next invocation as context,
  so Claude knows what it was doing when interrupted.

  Background:
    Given an active Claude session in a Matrix room

  Scenario: Stop emoji captures partial output for next turn
    Given an invocation is in progress that has produced partial output
    When the user sends a stop emoji reaction
    Then the invocation is cancelled
    And the partial output is stored in the session store keyed by room ID
    And "*Stopped.*" is sent to the room

  Scenario: Next invocation receives interrupted context as system-reminder
    Given a previous invocation was stopped with partial output "Working on the task..."
    When the user sends a new message
    Then the interrupted context is injected as a system-reminder
    And the reminder contains "Your previous turn was interrupted"
    And the reminder contains the partial output text

  Scenario: Interrupted context is cleared after use (one-shot)
    Given a previous invocation was stopped with partial output
    When the user sends a new message (consuming the interrupted context)
    And the user sends another message
    Then the second message does not include the interrupted context reminder

  Scenario: Empty partial output on immediate stop does not break anything
    Given an invocation is in progress that has produced no output yet
    When the user sends a stop emoji reaction immediately
    Then the invocation is cancelled
    And "*Stopped.*" is sent to the room
    And no interrupted context is stored

  Scenario: Tool calls in partial output are formatted as name + brief description
    Given an invocation has called tool "Read" with file_path "/tmp/test.go"
    When the user sends a stop emoji reaction
    Then the stored interrupted context contains "Read" and a brief description
    And the stored interrupted context does not contain full JSON input

  Scenario: Interrupted context is truncated to prevent context bloat
    Given an invocation produced more than 2000 characters of partial output
    When the user sends a stop emoji reaction
    Then the stored interrupted context is at most 2000 characters plus a truncation marker

  Scenario: Interrupted context survives bridge restart
    Given an invocation was stopped with partial output
    And the bridge is restarted
    When the user sends a new message
    Then the interrupted context is still available and injected as a system-reminder

  Scenario: Stop emoji on fresh session does not inject interrupted context
    Given there is no active session for the room
    And a previous invocation was stopped with partial output
    When the room session is cleared (via !clear)
    And the user starts a fresh session
    Then the interrupted context is NOT injected (fresh session ignores it)
