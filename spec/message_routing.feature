Feature: Message Routing
  Messages from Matrix are routed through the bridge to Claude Code sessions.
  The bridge manages per-room sessions, deduplication, and exclusion rules.

  Background:
    Given the bridge is connected to Matrix as @agent
    And the bridge is not draining

  # --- Basic routing ---

  Scenario: A text message in a non-excluded room invokes Claude
    Given the room "general" has no active invocation
    When @alice sends "hello" in "general"
    Then a Claude session is invoked for room "general" with the message "hello"
    And the response is sent back to "general"

  Scenario: An image message is saved and described to Claude
    Given the room "general" has no active invocation
    When @alice sends an image with caption "check this out" in "general"
    Then the image is saved to notes/attachments/ with a timestamped filename
    And Claude is invoked with a prompt referencing the saved image path and caption

  Scenario: An audio message is transcribed and forwarded to Claude
    Given the room "general" has no active invocation
    And the STT service returns "Hello from voice" for the audio
    When @alice sends an audio message in "general"
    Then the transcription "Hello from voice" is echoed as a threaded reply to the audio message before agent dispatch
    And Claude is invoked with a prompt containing the transcription

  Scenario: An empty audio transcription is not echoed
    Given the room "general" has no active invocation
    And the STT service returns "" for the audio
    When @alice sends an audio message in "general"
    Then no transcript echo is sent to the room
    And Claude is still invoked with the (empty) transcription prompt

  Scenario: Non-text, non-image, non-audio message types are dropped
    When @alice sends a video message in "general"
    Then no Claude invocation occurs

  Scenario: Messages from the bot itself are ignored
    When @agent sends "hello" in "general"
    Then no Claude invocation occurs

  # --- Session continuity ---

  Scenario: Subsequent messages in a room resume the existing session
    Given room "general" has session ID "sess-123"
    When @alice sends "follow up" in "general"
    Then Claude is invoked with --resume "sess-123"

  Scenario: First message in a room starts a fresh session
    Given room "general" has no session ID
    When @alice sends "hello" in "general"
    Then Claude is invoked without --resume
    And the room prompt is prefixed with "[Matrix room: general]"

  # --- Deduplication ---

  Scenario: Duplicate Matrix events are dropped
    Given event "evt-abc" has already been processed
    When event "evt-abc" arrives again
    Then no Claude invocation occurs

  Scenario: Concurrent messages in the same room are dropped
    Given room "general" has an active invocation
    When @alice sends "another message" in "general"
    Then no Claude invocation occurs
    And the message is logged as skipped

  # --- Exclusion ---

  Scenario: Messages in the ops room are ignored
    When @alice sends "hello" in "ops"
    Then no Claude invocation occurs

  Scenario: Messages in project rooms are ignored
    When @alice sends "hello" in "project-website"
    Then no Claude invocation occurs

  Scenario: Messages in rooms without a name are not excluded
    Given the room has no display name
    When @alice sends "hello" in that room
    Then a Claude session is invoked

  # --- Drain ---

  Scenario: Messages during drain are silently dropped
    Given the bridge is draining
    When @alice sends "hello" in "general"
    Then no Claude invocation occurs

  # --- Old message filtering ---

  Scenario: Messages from before bridge startup are discarded
    Given the bridge started at 10:00:00
    When a message with timestamp 09:59:59 arrives
    Then no Claude invocation occurs
