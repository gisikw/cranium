Feature: Context Window Saturation Awareness
  The bridge tracks how full the Claude session's context window is and
  provides escalating guidance as it fills up.

  Background:
    Given the bridge is connected to Matrix as @agent
    And room "general" has an active session

  # --- Threshold-based reminders ---

  Scenario Outline: Saturation reminder is injected at 5% threshold crossings
    Given the previous saturation for "general" was <previous>%
    When a Claude response reports saturation at <current>%
    And the next message is sent
    Then a <system-reminder> <injected> with context saturation advice

    Examples:
      | previous | current | injected       |
      | 45       | 52      | is injected    |
      | 52       | 54      | is not injected|
      | 54       | 56      | is injected    |
      | 78       | 82      | is injected    |

  Scenario: No reminder below 50%
    Given the current saturation for "general" is 48%
    When @alice sends a message in "general"
    Then no saturation reminder is injected

  # --- Escalating advice ---

  Scenario: Advice at 60% suggests scope awareness
    When saturation crosses 60%
    Then the advice includes "Be mindful of scope"

  Scenario: Advice at 70% suggests wrapping up
    When saturation crosses 70%
    Then the advice includes "Start wrapping up"

  Scenario: Advice at 80% suggests clearing
    When saturation crosses 80%
    Then the advice includes "suggest a !clear"

  # --- Pinned context indicator ---

  Scenario: Context indicator is pinned at 60%
    Given no context indicator is pinned for "general"
    When saturation reaches 60%
    Then a notice message is sent with token usage details
    And the message is pinned in the room

  Scenario: Pinned indicator is updated silently on subsequent changes
    Given a context indicator is already pinned for "general"
    When saturation changes
    Then the pinned message is edited with the new percentage
    And no notification is generated

  # --- Permission handling ---

  Scenario: Pin failure due to missing permissions triggers alert
    Given @agent does not have Moderator permissions in "general"
    When saturation reaches 60% and pin attempt fails
    Then a notice is sent explaining the Moderator requirement
    And the notice is only sent once per room

  Scenario: Pin failure due to other errors does not trigger permission alert
    Given a pin attempt fails due to network error
    Then no permission alert is sent

  # --- Compaction detection ---

  Scenario: Context compaction is detected and announced
    Given the last known saturation for "general" was 75%
    And a context indicator is pinned
    When a Claude response reports saturation at 40%
    Then the context indicator is unpinned
    And a message is sent: "context was auto-compacted"
    And the message includes the drop from 75% to 40%
