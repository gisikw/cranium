Feature: Session Lifecycle
  Sessions are managed per-room. They can be cleared (with handoff generation),
  and new rooms can be created.

  Background:
    Given the bridge is connected to Matrix as @exo

  # --- !clear ---

  Scenario: !clear generates a handoff and resets the session
    Given room "general" has session "sess-123"
    And no active invocation is running in "general"
    When @alice sends "!clear" in "general"
    Then a transient "Reloading..." notice is sent and pinned
    And a handoff document is generated from session "sess-123"
    And the handoff is saved to handoffs/general/<timestamp>.md
    And the session ID for "general" is cleared
    And the context indicator is unpinned
    And the transient notice is redacted and unpinned

  Scenario: !clear is rejected during active invocation
    Given room "general" has an active invocation
    When @alice sends "!clear" in "general"
    Then a message is sent: "Can't clear while a response is in progress"
    And the session is NOT cleared

  Scenario: !clear with no existing session skips handoff
    Given room "general" has no session ID
    When @alice sends "!clear" in "general"
    Then a transient "Reloading..." notice is sent and pinned
    And no handoff generation occurs
    And the session ID for "general" is cleared
    And the transient notice is redacted and unpinned

  # --- Handoff generation ---

  Scenario: Handoff document captures session state
    When handoff generation runs for session "sess-123" in room "general"
    Then Claude is invoked with --resume "sess-123"
    And the invocation uses --no-session-persistence
    And the invocation uses --tools "" to disable tool use
    And the response is written to handoffs/general/<timestamp>.md

  # --- Handoff loading ---

  Scenario: Fresh session loads the most recent handoff
    Given handoffs/general/ contains:
      | file                          |
      | 2026-02-10_14-30-00.md        |
      | 2026-02-11_09-15-00.md        |
    When a fresh session starts in "general"
    Then the content of 2026-02-11_09-15-00.md is injected via --append-system-prompt
    And it is wrapped in a <room-handoff> block

  Scenario: Fresh session with no handoffs starts clean
    Given no handoff directory exists for room "new-room"
    When a fresh session starts in "new-room"
    Then no handoff content is injected

  # --- Persistence ---

  Scenario: Session data persists across bridge restarts
    Given room "general" has session "sess-123" with pinned event "$pin-001"
    And the last message sent was event "evt-789" with body "test message"
    When the bridge restarts and reloads the session store
    Then room "general" still has session "sess-123"
    And the pinned event is still "$pin-001"
    And the last message is still "evt-789" / "test message"

  Scenario: Session store migrates old format transparently
    Given the session store file contains the old format (map of room ID to session ID)
    When the bridge loads the session store
    Then all rooms have their correct session IDs
    And the store operates normally with the new format

  # --- !new ---

  Scenario: !new creates a room and invites the sender
    When @alice sends "!new my-project" in "general"
    Then a new Matrix room is created with name "my-project"
    And @alice is invited to the new room
    And both @exo and @alice have admin power level (100)
    And a confirmation is sent in "general" with the new room name
