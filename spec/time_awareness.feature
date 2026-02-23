Feature: Time-Gap Awareness
  When a conversation resumes after a period of silence, the bridge injects
  temporal context so the Claude session knows how much time has passed and
  what time it is.

  Background:
    Given the bridge is connected to Matrix as @agent
    And room "general" has an active session "sess-123"

  Scenario: Message after a 45-minute gap gets a time reminder
    Given the last invocation for "sess-123" was 45 minutes ago
    When @alice sends "hey, back" in "general"
    Then the message is prepended with a <system-reminder> containing:
      | field                | pattern                          |
      | elapsed time         | "It's been about 45 minutes"     |
      | current time         | current time in Central timezone  |

  Scenario: Message after a 3-hour gap gets a time reminder
    Given the last invocation for "sess-123" was 3 hours ago
    When @alice sends "picking this up again" in "general"
    Then the message is prepended with a <system-reminder> containing:
      | field                | pattern                    |
      | elapsed time         | "It's been about 3 hours"  |
      | current time         | current time in Central    |

  Scenario: Message within 30 minutes does not get a time reminder
    Given the last invocation for "sess-123" was 15 minutes ago
    When @alice sends "one more thing" in "general"
    Then the message is NOT prepended with a time reminder

  Scenario: Time-gap reminder includes cross-room landscape
    Given the last invocation for "sess-123" was 2 hours ago
    And room "infra" has a summary "Debugging NixOS deploy" from 1 hour ago
    And room "personal" has a summary "Planning weekend trip" from 30 minutes ago
    When @alice sends "back" in "general"
    Then the time reminder includes summaries from "infra" and "personal"
    And the summaries are filtered to max age of 4 hours (2x elapsed)

  Scenario: Fresh session with no prior invocation does not get a time reminder
    Given room "new-room" has no session ID
    When @alice sends "hello" in "new-room"
    Then the message is NOT prepended with a time reminder
