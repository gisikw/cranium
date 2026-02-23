Feature: Graceful Upgrade and Drain
  The bridge supports zero-downtime upgrades via SIGUSR1 graceful drain
  and a resume breadcrumb system.

  Background:
    Given the bridge is running and connected to Matrix

  # --- Drain ---

  Scenario: SIGUSR1 initiates graceful drain
    When the bridge receives SIGUSR1
    Then the bridge enters drain mode
    And new messages are silently dropped
    And a drain announcement is posted to #ops

  Scenario: Drain completes when active invocations finish
    Given the bridge is draining
    And room "general" has an active invocation (the triggering room)
    And room "infra" has an active invocation
    When the "infra" invocation completes
    Then the bridge considers drain complete (1 remaining = triggering room)
    And the bridge shuts down

  Scenario: Drain times out after 30 seconds
    Given the bridge is draining
    And active invocations have not completed
    When 30 seconds have elapsed
    Then the bridge shuts down with a timeout warning

  # --- Resume breadcrumb ---

  Scenario: Upgrade script writes a resume breadcrumb
    Given a Claude session triggered the upgrade from room "infra"
    When the upgrade script runs
    Then .cranium-resume is written with the room ID and a resume message

  Scenario: New bridge reads and deletes the resume breadcrumb
    Given .cranium-resume exists with room "infra" and a message
    When the bridge starts up
    Then it reads the breadcrumb file
    And deletes the breadcrumb file immediately
    And resumes the session in "infra" with the message
    And the response is sent to "infra"

  Scenario: Stale working indicator is cleaned up on resume
    Given the previous bridge left a message with "[Agent is still working...]"
    When the new bridge resumes the session
    Then the stale working indicator is edited out of the previous message

  # --- Startup ---

  Scenario: Bridge announces startup in ops
    When the bridge starts and connects to Matrix
    Then it posts "cranium online: <version>" to #ops
