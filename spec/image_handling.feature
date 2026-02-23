Feature: Image Handling
  The bridge downloads Matrix images (encrypted or unencrypted), saves them to
  notes/attachments/ with timestamped filenames, and formats a prompt for Claude
  referencing the saved image path.

  Background:
    Given the bridge is connected to Matrix as @agent
    And room "general" has an active session

  # --- Encrypted vs Unencrypted ---

  Scenario: Encrypted images are decrypted before saving
    When @alice sends an encrypted image in "general"
    Then the bridge detects content.File is not nil
    And the bridge extracts the MXC URL from content.File.URL
    And the bridge downloads the encrypted image bytes
    And the bridge decrypts the bytes using content.File.DecryptInPlace()
    And the decrypted image is saved to notes/attachments/

  Scenario: Unencrypted images are downloaded directly
    When @alice sends an unencrypted image in "general"
    Then the bridge detects content.File is nil
    And the bridge extracts the MXC URL from content.URL
    And the bridge downloads the image bytes directly
    And the image is saved to notes/attachments/ without decryption

  # --- MIME Type Detection and Extension Mapping ---

  Scenario: Extension is extracted from original filename when available
    When @alice sends an image with filename "screenshot.png"
    Then the saved file uses extension ".png" from the original filename
    And MIME type detection is not used

  Scenario: Extension is determined from MIME type when filename has no extension
    When @alice sends an image with filename "IMG_1234" and MIME type "image/jpeg"
    Then the saved file uses extension ".jpg" from the MIME type

  Scenario: Supported MIME types are mapped to extensions
    When the MIME type is "image/png" then the extension is ".png"
    And when the MIME type is "image/jpeg" then the extension is ".jpg"
    And when the MIME type is "image/gif" then the extension is ".gif"
    And when the MIME type is "image/webp" then the extension is ".webp"

  Scenario: Unknown MIME types default to .png extension
    When @alice sends an image with no filename extension and MIME type "image/tiff"
    Then the saved file uses extension ".png" as the default

  # --- Filename Format ---

  Scenario: Saved filename includes timestamp and original name
    Given the current time is 2026-02-16 15:04:05
    When @alice sends an image with filename "screenshot.png"
    Then the saved filename is "2026-02-16_15-04-05_screenshot.png"
    And the file is saved to notes/attachments/

  Scenario: Timestamp format is consistent
    When an image is saved
    Then the timestamp portion follows the format "YYYY-MM-DD_HH-MM-SS"

  Scenario: Original filename is preserved without original extension
    Given the current time is 2026-02-16 15:04:05
    When @alice sends an image with filename "my-diagram.jpg" but MIME type "image/png"
    Then the saved filename is "2026-02-16_15-04-05_my-diagram.png"

  # --- Prompt Formatting ---

  Scenario: Image prompt includes path and caption
    Given an image is saved to "notes/attachments/2026-02-16_15-04-05_img.png"
    When the caption is "check this out"
    Then the prompt sent to Claude is:
      """
      [Image attached: notes/attachments/2026-02-16_15-04-05_img.png]

      check this out
      """

  Scenario: Image prompt without caption includes only path
    Given an image is saved to "notes/attachments/2026-02-16_15-04-05_img.png"
    When the caption is empty
    Then the prompt sent to Claude is "[Image attached: notes/attachments/2026-02-16_15-04-05_img.png]"

  # --- Error Handling ---

  Scenario: Download failures are reported to the user
    When @alice sends an image in "general"
    And the image download fails with an error
    Then the bridge sends an error message to "general"
    And no Claude invocation occurs

  Scenario: Decryption failures are reported to the user
    When @alice sends an encrypted image in "general"
    And the decryption fails with an error
    Then the bridge sends an error message to "general"
    And no Claude invocation occurs

  # --- Known Limitations ---

  # NOTE: The following behaviors are known gaps with low risk, documented for completeness:
  #
  # - Non-image attachments (files, audio, video) are dropped by isSupportedMessageType
  # - No size limit check on images (very large images could cause memory issues)
  # - If original filename has no extension AND MIME type is empty/unexpected,
  #   defaults to .png (could produce misnamed files, e.g., a .png-named JPEG)
