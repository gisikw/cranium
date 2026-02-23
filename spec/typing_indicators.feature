Feature: Typing Indicators
  The bridge provides responsive feedback while Claude is processing,
  including read receipts and typing indicators.

  Background:
    Given the bridge is connected to Matrix as @agent

  Scenario: Read receipt is sent before typing begins
    When @alice sends a message in "general"
    Then a read receipt is sent after approximately 800ms
    And a typing indicator starts after approximately 1000ms

  Scenario: Typing indicator is renewed every 15 seconds
    Given Claude is processing a response for "general"
    When 15 seconds have elapsed since the last typing indicator
    Then the typing indicator is renewed with a 30-second timeout

  Scenario: Typing indicator is cancelled when Claude responds
    Given a typing indicator is active for "general"
    When Claude finishes responding
    Then the typing indicator is turned off
