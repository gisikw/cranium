Feature: Edit-in-Place Streaming
  Rather than sending many individual messages during a Claude turn, the bridge
  sends one message and edits it as new content arrives, providing a live-updating
  experience in Matrix.

  Background:
    Given the bridge is connected to Matrix as @exo
    And room "general" has an active session

  Scenario: First content section sends a new message
    When Claude's response stream emits the first text section
    Then a new message is sent to "general" with that text
    And the message includes a "[Exo is still working...]" trailer

  Scenario: Subsequent content edits the existing message
    Given the initial message has been sent with event ID "evt-001"
    When Claude's response stream emits a second text section
    Then event "evt-001" is edited with both sections concatenated
    And the working trailer is preserved

  Scenario: Tool calls are rendered as blockquoted summaries
    Given the initial message has been sent
    When Claude's response stream emits a tool call for "Bash" with command "git status"
    Then the message is edited to append:
      """
      > **Bash** `git status`
      """

  Scenario: Working trailer is removed on final edit
    When Claude's response stream ends
    Then the message is edited one final time
    And the "[Exo is still working...]" trailer is removed

  Scenario: Thinking text is formatted as blockquoted italics
    Given Claude has just executed a tool call
    When the next text section arrives (before turn end)
    Then it is formatted as "> *thinking text*"

  Scenario: Final reply section reverts from thinking to plain format
    Given intermediate text was formatted as thinking
    When the response stream ends
    Then the last text section is reformatted as plain text (not blockquoted)

  Scenario: HTML entities are escaped in rendered output
    When tool detail text contains characters like <, >, &, or "
    Then those characters are escaped to their HTML entity equivalents
    And the output is safe for embedding in Matrix HTML messages
