Feature: Invocation Cancellation
  Users can cancel active Claude invocations by reacting with stop emoji.
  The cancellation is room-scoped and terminates the top-level Claude process.

  Background:
    Given the bridge is connected to Matrix as @exo

  # --- Stop emoji cancellation ---

  Scenario: Stop-sign emoji cancels active invocation
    Given room "general" has an active Claude invocation
    When @alice reacts with 🛑 to any message in "general"
    Then the Claude process receives a cancellation signal
    And the working indicator is removed from the last message
    And the bridge sends "*Stopped.*" to "general"
    And the session ID is preserved for resumption
    And the room is no longer marked as active

  Scenario: No-entry emoji also cancels active invocation
    Given room "general" has an active Claude invocation
    When @alice reacts with ⛔ to any message in "general"
    Then the Claude process receives a cancellation signal
    And the bridge sends "*Stopped.*" to "general"

  Scenario: Emoji variant selectors are normalized
    Given room "general" has an active Claude invocation
    When @alice reacts with "🛑\uFE0F" (stop sign with variant selector)
    Then the invocation is cancelled as if reacting with 🛑

  Scenario: Stop emoji is room-scoped not message-scoped
    Given room "general" has an active Claude invocation
    And the room contains messages "$msg-1", "$msg-2", and "$msg-3"
    When @alice reacts with 🛑 to "$msg-1"
    Then the invocation is cancelled regardless of which message was targeted

  # --- No active invocation ---

  Scenario: Stop emoji with no active invocation falls through to approval
    Given room "general" has no active invocation
    And an approval prompt is pending for event "$approval-evt"
    When @alice reacts with 🛑 to event "$approval-evt"
    Then the bridge responds to exo-hook with "deny" and message "STOP"
    And no cancellation occurs

  Scenario: Stop emoji with no active invocation and no pending approval is ignored
    Given room "general" has no active invocation
    And no approval prompts are pending
    When @alice reacts with 🛑 to any message
    Then the reaction is silently ignored

  # --- Edge cases ---

  Scenario: Multiple stop emoji reactions are idempotent
    Given room "general" has an active Claude invocation
    When @alice reacts with 🛑 to message "$msg-1"
    And @alice reacts with ⛔ to message "$msg-2"
    Then the invocation is cancelled once
    And subsequent stop reactions have no additional effect

  Scenario: Stop emoji during tool approval denies and cancels
    Given room "general" has an active invocation
    And an approval prompt is pending for event "$approval-evt"
    When @alice reacts with 🛑 to event "$approval-evt"
    Then the approval is denied with message "STOP"
    And the active invocation is also cancelled

  # --- Known limitations ---

  Scenario: Subprocesses may not be terminated (exo-yx9q)
    Given room "general" has an active invocation
    And Claude has spawned a subprocess (e.g., "ko build")
    When @alice reacts with 🛑
    Then the top-level Claude process is terminated
    But subprocesses may continue running (orphaned)
    # NOTE: This is a known limitation. The current implementation uses
    # exec.CommandContext without process group management, so SIGKILL
    # only reaches the top-level process. Fix tracked in exo-yx9q.

  # --- Process termination details ---

  Scenario: Cancellation terminates the Claude process
    Given room "general" has an active invocation using session "sess-123"
    When @alice reacts with 🛑
    Then the invocation context is cancelled
    And the Claude process receives SIGKILL (via exec.CommandContext cancellation)
    And invokeClaude detects context.Err() != nil
    And the stopped state is handled in the message handler

  Scenario: Session is preserved after cancellation for resumption
    Given room "general" has an active invocation using session "sess-456"
    When @alice reacts with 🛑
    And the invocation is stopped
    And the bridge sends "*Stopped.*"
    Then the session ID "sess-456" is still stored for room "general"
    And the next message to "general" can resume from "sess-456"

  # --- Cross-references ---

  # See tool_approval.feature line 51-54 for stop emoji approval denial behavior
  # See exo-6de5 for partial context preservation after stop
  # See exo-yx9q for subprocess orphaning issue and fix
