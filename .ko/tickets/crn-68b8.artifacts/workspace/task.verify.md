warning: Git tree '/home/dev/Projects/cranium' is dirty
cranium dev shell
  just test    — run tests
  just build   — build binary
  just deploy  — build + upgrade
go test -tags goolm -v -count=1 ./...
=== RUN   TestBridge_HandleReaction_Approve
2026/03/01 06:12:29 Found pending approval for event $approval-1
2026/03/01 06:12:29 Reaction received: 👍 on $approval-1
2026/03/01 06:12:29 Sending approval response to channel: allow
2026/03/01 06:12:29 Response sent to channel successfully
--- PASS: TestBridge_HandleReaction_Approve (0.00s)
=== RUN   TestBridge_HandleReaction_Deny
2026/03/01 06:12:29 Found pending approval for event $approval-2
2026/03/01 06:12:29 Reaction received: 👎 on $approval-2
2026/03/01 06:12:29 Sending approval response to channel: deny
2026/03/01 06:12:29 Response sent to channel successfully
--- PASS: TestBridge_HandleReaction_Deny (0.00s)
=== RUN   TestBridge_HandleReaction_Stop
2026/03/01 06:12:29 Found pending approval for event $approval-3
2026/03/01 06:12:29 Reaction received: 🛑 on $approval-3
2026/03/01 06:12:29 Sending approval response to channel: deny
2026/03/01 06:12:29 Response sent to channel successfully
--- PASS: TestBridge_HandleReaction_Stop (0.00s)
=== RUN   TestBridge_HandleReaction_IgnoresSelfReaction
--- PASS: TestBridge_HandleReaction_IgnoresSelfReaction (0.10s)
=== RUN   TestBridge_HandleReaction_UnknownEmoji
2026/03/01 06:12:29 Found pending approval for event $approval-5
2026/03/01 06:12:29 Reaction received: 🎉 on $approval-5
2026/03/01 06:12:29 Ignoring unknown reaction: "🎉"
--- PASS: TestBridge_HandleReaction_UnknownEmoji (0.10s)
=== RUN   TestBridge_RequestApproval_AutoApprove
2026/03/01 06:12:29 Auto-allow: Read (matched rule)
2026/03/01 06:12:29 Auto-deny: Bash (matched rule)
--- PASS: TestBridge_RequestApproval_AutoApprove (0.00s)
=== RUN   TestBridge_RequestApproval_InteractivePrompt
2026/03/01 06:12:29 Waiting for reaction on event $mock-1
2026/03/01 06:12:29 Found pending approval for event $mock-1
2026/03/01 06:12:29 Reaction received: 👍 on $mock-1
2026/03/01 06:12:29 Sending approval response to channel: allow
2026/03/01 06:12:29 Response sent to channel successfully
2026/03/01 06:12:29 Received response from channel: allow
--- PASS: TestBridge_RequestApproval_InteractivePrompt (0.05s)
=== RUN   TestBridge_RequestApproval_InteractiveDeny
2026/03/01 06:12:29 Waiting for reaction on event $mock-1
2026/03/01 06:12:29 Found pending approval for event $mock-1
2026/03/01 06:12:29 Reaction received: 👎 on $mock-1
2026/03/01 06:12:29 Sending approval response to channel: deny
2026/03/01 06:12:29 Response sent to channel successfully
2026/03/01 06:12:29 Received response from channel: deny
--- PASS: TestBridge_RequestApproval_InteractiveDeny (0.05s)
=== RUN   TestBridge_RequestApproval_ContextCancellation
2026/03/01 06:12:29 Waiting for reaction on event $mock-1
--- PASS: TestBridge_RequestApproval_ContextCancellation (0.05s)
=== RUN   TestBridge_RequestApproval_NoSession
2026/03/01 06:12:29 No room found for session unknown-session, deferring to CC permissions
--- PASS: TestBridge_RequestApproval_NoSession (0.00s)
=== RUN   TestBridge_RequestApproval_MessageFormatting
=== RUN   TestBridge_RequestApproval_MessageFormatting/command_field
2026/03/01 06:12:29 Waiting for reaction on event $mock-1
=== RUN   TestBridge_RequestApproval_MessageFormatting/description_field
2026/03/01 06:12:29 Waiting for reaction on event $mock-1
=== RUN   TestBridge_RequestApproval_MessageFormatting/other_fields
2026/03/01 06:12:29 Waiting for reaction on event $mock-1
--- PASS: TestBridge_RequestApproval_MessageFormatting (0.30s)
    --- PASS: TestBridge_RequestApproval_MessageFormatting/command_field (0.10s)
    --- PASS: TestBridge_RequestApproval_MessageFormatting/description_field (0.10s)
    --- PASS: TestBridge_RequestApproval_MessageFormatting/other_fields (0.10s)
=== RUN   TestMatchWildcard
=== RUN   TestMatchWildcard/git_status_vs_git_status
=== RUN   TestMatchWildcard/git_status_vs_git_push
=== RUN   TestMatchWildcard/git_*_vs_git_status
=== RUN   TestMatchWildcard/git_*_vs_git_push_--force
=== RUN   TestMatchWildcard/git_*_vs_curl_example.com
=== RUN   TestMatchWildcard/*.txt_vs_readme.txt
=== RUN   TestMatchWildcard/*.txt_vs_readme.md
=== RUN   TestMatchWildcard//home/*/file.txt_vs_/home/dev/file.txt
=== RUN   TestMatchWildcard//home/*/file.txt_vs_/home/dev/Projects/file.txt
=== RUN   TestMatchWildcard//home/*/Projects/*.go_vs_/home/dev/Projects/main.go
=== RUN   TestMatchWildcard/exact_vs_exact
=== RUN   TestMatchWildcard/exact_vs_other
--- PASS: TestMatchWildcard (0.00s)
    --- PASS: TestMatchWildcard/git_status_vs_git_status (0.00s)
    --- PASS: TestMatchWildcard/git_status_vs_git_push (0.00s)
    --- PASS: TestMatchWildcard/git_*_vs_git_status (0.00s)
    --- PASS: TestMatchWildcard/git_*_vs_git_push_--force (0.00s)
    --- PASS: TestMatchWildcard/git_*_vs_curl_example.com (0.00s)
    --- PASS: TestMatchWildcard/*.txt_vs_readme.txt (0.00s)
    --- PASS: TestMatchWildcard/*.txt_vs_readme.md (0.00s)
    --- PASS: TestMatchWildcard//home/*/file.txt_vs_/home/dev/file.txt (0.00s)
    --- PASS: TestMatchWildcard//home/*/file.txt_vs_/home/dev/Projects/file.txt (0.00s)
    --- PASS: TestMatchWildcard//home/*/Projects/*.go_vs_/home/dev/Projects/main.go (0.00s)
    --- PASS: TestMatchWildcard/exact_vs_exact (0.00s)
    --- PASS: TestMatchWildcard/exact_vs_other (0.00s)
=== RUN   TestMatchesRule
=== RUN   TestMatchesRule/simple_tool_name_match
=== RUN   TestMatchesRule/simple_tool_name_mismatch
=== RUN   TestMatchesRule/bash_command_with_wildcard
=== RUN   TestMatchesRule/bash_command_mismatch
=== RUN   TestMatchesRule/read_with_path_wildcard
=== RUN   TestMatchesRule/read_with_path_mismatch
=== RUN   TestMatchesRule/write_with_path_wildcard
=== RUN   TestMatchesRule/edit_with_path_wildcard
=== RUN   TestMatchesRule/malformed_rule_(no_closing_paren)
=== RUN   TestMatchesRule/bash_with_empty_command
--- PASS: TestMatchesRule (0.00s)
    --- PASS: TestMatchesRule/simple_tool_name_match (0.00s)
    --- PASS: TestMatchesRule/simple_tool_name_mismatch (0.00s)
    --- PASS: TestMatchesRule/bash_command_with_wildcard (0.00s)
    --- PASS: TestMatchesRule/bash_command_mismatch (0.00s)
    --- PASS: TestMatchesRule/read_with_path_wildcard (0.00s)
    --- PASS: TestMatchesRule/read_with_path_mismatch (0.00s)
    --- PASS: TestMatchesRule/write_with_path_wildcard (0.00s)
    --- PASS: TestMatchesRule/edit_with_path_wildcard (0.00s)
    --- PASS: TestMatchesRule/malformed_rule_(no_closing_paren) (0.00s)
    --- PASS: TestMatchesRule/bash_with_empty_command (0.00s)
=== RUN   TestCheckAutoApprove
=== RUN   TestCheckAutoApprove/allow_match
=== RUN   TestCheckAutoApprove/deny_match
=== RUN   TestCheckAutoApprove/deny_takes_precedence_over_allow
=== RUN   TestCheckAutoApprove/no_match_returns_empty
=== RUN   TestCheckAutoApprove/empty_config_returns_empty
--- PASS: TestCheckAutoApprove (0.00s)
    --- PASS: TestCheckAutoApprove/allow_match (0.00s)
    --- PASS: TestCheckAutoApprove/deny_match (0.00s)
    --- PASS: TestCheckAutoApprove/deny_takes_precedence_over_allow (0.00s)
    --- PASS: TestCheckAutoApprove/no_match_returns_empty (0.00s)
    --- PASS: TestCheckAutoApprove/empty_config_returns_empty (0.00s)
=== RUN   TestFormatToolDetail
=== RUN   TestFormatToolDetail/bash_command
=== RUN   TestFormatToolDetail/read_file
=== RUN   TestFormatToolDetail/write_file
=== RUN   TestFormatToolDetail/edit_file
=== RUN   TestFormatToolDetail/glob_pattern
=== RUN   TestFormatToolDetail/grep_pattern
=== RUN   TestFormatToolDetail/web_search
=== RUN   TestFormatToolDetail/web_fetch
=== RUN   TestFormatToolDetail/task_description
=== RUN   TestFormatToolDetail/ask_user_question
=== RUN   TestFormatToolDetail/ask_user_question_without_description
=== RUN   TestFormatToolDetail/unknown_tool
--- PASS: TestFormatToolDetail (0.00s)
    --- PASS: TestFormatToolDetail/bash_command (0.00s)
    --- PASS: TestFormatToolDetail/read_file (0.00s)
    --- PASS: TestFormatToolDetail/write_file (0.00s)
    --- PASS: TestFormatToolDetail/edit_file (0.00s)
    --- PASS: TestFormatToolDetail/glob_pattern (0.00s)
    --- PASS: TestFormatToolDetail/grep_pattern (0.00s)
    --- PASS: TestFormatToolDetail/web_search (0.00s)
    --- PASS: TestFormatToolDetail/web_fetch (0.00s)
    --- PASS: TestFormatToolDetail/task_description (0.00s)
    --- PASS: TestFormatToolDetail/ask_user_question (0.00s)
    --- PASS: TestFormatToolDetail/ask_user_question_without_description (0.00s)
    --- PASS: TestFormatToolDetail/unknown_tool (0.00s)
=== RUN   TestFormatToolDetail_LongCommand
--- PASS: TestFormatToolDetail_LongCommand (0.00s)
=== RUN   TestFormatToolDetail_LongAskUserQuestion
--- PASS: TestFormatToolDetail_LongAskUserQuestion (0.00s)
=== RUN   TestHtmlEscape
=== RUN   TestHtmlEscape/hello
=== RUN   TestHtmlEscape/<script>
=== RUN   TestHtmlEscape/"quoted"
=== RUN   TestHtmlEscape/a_&_b
=== RUN   TestHtmlEscape/<a_href="x">
--- PASS: TestHtmlEscape (0.00s)
    --- PASS: TestHtmlEscape/hello (0.00s)
    --- PASS: TestHtmlEscape/<script> (0.00s)
    --- PASS: TestHtmlEscape/"quoted" (0.00s)
    --- PASS: TestHtmlEscape/a_&_b (0.00s)
    --- PASS: TestHtmlEscape/<a_href="x"> (0.00s)
=== RUN   TestNormalizeEmoji
=== RUN   TestNormalizeEmoji/👍
=== RUN   TestNormalizeEmoji/👍#01
=== RUN   TestNormalizeEmoji/👍#02
=== RUN   TestNormalizeEmoji/✅
--- PASS: TestNormalizeEmoji (0.00s)
    --- PASS: TestNormalizeEmoji/👍 (0.00s)
    --- PASS: TestNormalizeEmoji/👍#01 (0.00s)
    --- PASS: TestNormalizeEmoji/👍#02 (0.00s)
    --- PASS: TestNormalizeEmoji/✅ (0.00s)
=== RUN   TestMapEmojiToApproval
=== RUN   TestMapEmojiToApproval/👍
=== RUN   TestMapEmojiToApproval/✅
=== RUN   TestMapEmojiToApproval/👎
=== RUN   TestMapEmojiToApproval/🛑
=== RUN   TestMapEmojiToApproval/⛔
=== RUN   TestMapEmojiToApproval/❤️
=== RUN   TestMapEmojiToApproval/🎉
--- PASS: TestMapEmojiToApproval (0.00s)
    --- PASS: TestMapEmojiToApproval/👍 (0.00s)
    --- PASS: TestMapEmojiToApproval/✅ (0.00s)
    --- PASS: TestMapEmojiToApproval/👎 (0.00s)
    --- PASS: TestMapEmojiToApproval/🛑 (0.00s)
    --- PASS: TestMapEmojiToApproval/⛔ (0.00s)
    --- PASS: TestMapEmojiToApproval/❤️ (0.00s)
    --- PASS: TestMapEmojiToApproval/🎉 (0.00s)
=== RUN   TestMapEmojiToApproval_StopHasMessage
--- PASS: TestMapEmojiToApproval_StopHasMessage (0.00s)
=== RUN   TestSlugify
=== RUN   TestSlugify/general
=== RUN   TestSlugify/My_Cool_Room
=== RUN   TestSlugify/project-website
=== RUN   TestSlugify/ops
=== RUN   TestSlugify/Room_With__Multiple___Spaces
=== RUN   TestSlugify/CamelCaseRoom
=== RUN   TestSlugify/room!@#$%special
=== RUN   TestSlugify/__leading-trailing__
=== RUN   TestSlugify/123-numeric
--- PASS: TestSlugify (0.00s)
    --- PASS: TestSlugify/general (0.00s)
    --- PASS: TestSlugify/My_Cool_Room (0.00s)
    --- PASS: TestSlugify/project-website (0.00s)
    --- PASS: TestSlugify/ops (0.00s)
    --- PASS: TestSlugify/Room_With__Multiple___Spaces (0.00s)
    --- PASS: TestSlugify/CamelCaseRoom (0.00s)
    --- PASS: TestSlugify/room!@#$%special (0.00s)
    --- PASS: TestSlugify/__leading-trailing__ (0.00s)
    --- PASS: TestSlugify/123-numeric (0.00s)
=== RUN   TestIsExcludedRoomName
=== RUN   TestIsExcludedRoomName/ops
=== RUN   TestIsExcludedRoomName/project-website
=== RUN   TestIsExcludedRoomName/project-
=== RUN   TestIsExcludedRoomName/project-foo-bar
=== RUN   TestIsExcludedRoomName/general
=== RUN   TestIsExcludedRoomName/#00
=== RUN   TestIsExcludedRoomName/operations
=== RUN   TestIsExcludedRoomName/my-project
=== RUN   TestIsExcludedRoomName/OPS
--- PASS: TestIsExcludedRoomName (0.00s)
    --- PASS: TestIsExcludedRoomName/ops (0.00s)
    --- PASS: TestIsExcludedRoomName/project-website (0.00s)
    --- PASS: TestIsExcludedRoomName/project- (0.00s)
    --- PASS: TestIsExcludedRoomName/project-foo-bar (0.00s)
    --- PASS: TestIsExcludedRoomName/general (0.00s)
    --- PASS: TestIsExcludedRoomName/#00 (0.00s)
    --- PASS: TestIsExcludedRoomName/operations (0.00s)
    --- PASS: TestIsExcludedRoomName/my-project (0.00s)
    --- PASS: TestIsExcludedRoomName/OPS (0.00s)
=== RUN   TestParseCommand
=== RUN   TestParseCommand/!clear
=== RUN   TestParseCommand//clear
=== RUN   TestParseCommand/!new_my-room
=== RUN   TestParseCommand//new_my-room
=== RUN   TestParseCommand/!new___spaced-room__
=== RUN   TestParseCommand/!new
=== RUN   TestParseCommand/hello
=== RUN   TestParseCommand/!clearfoo
=== RUN   TestParseCommand/!clearing_things
=== RUN   TestParseCommand//newfoo
=== RUN   TestParseCommand/clear
=== RUN   TestParseCommand/!Clear
--- PASS: TestParseCommand (0.00s)
    --- PASS: TestParseCommand/!clear (0.00s)
    --- PASS: TestParseCommand//clear (0.00s)
    --- PASS: TestParseCommand/!new_my-room (0.00s)
    --- PASS: TestParseCommand//new_my-room (0.00s)
    --- PASS: TestParseCommand/!new___spaced-room__ (0.00s)
    --- PASS: TestParseCommand/!new (0.00s)
    --- PASS: TestParseCommand/hello (0.00s)
    --- PASS: TestParseCommand/!clearfoo (0.00s)
    --- PASS: TestParseCommand/!clearing_things (0.00s)
    --- PASS: TestParseCommand//newfoo (0.00s)
    --- PASS: TestParseCommand/clear (0.00s)
    --- PASS: TestParseCommand/!Clear (0.00s)
=== RUN   TestFormatImagePrompt
=== RUN   TestFormatImagePrompt/with_caption
=== RUN   TestFormatImagePrompt/without_caption
--- PASS: TestFormatImagePrompt (0.00s)
    --- PASS: TestFormatImagePrompt/with_caption (0.00s)
    --- PASS: TestFormatImagePrompt/without_caption (0.00s)
=== RUN   TestFormatAudioPrompt
=== RUN   TestFormatAudioPrompt/transcription_only
=== RUN   TestFormatAudioPrompt/with_caption
--- PASS: TestFormatAudioPrompt (0.00s)
    --- PASS: TestFormatAudioPrompt/transcription_only (0.00s)
    --- PASS: TestFormatAudioPrompt/with_caption (0.00s)
=== RUN   TestFormatTranscriptEcho
=== RUN   TestFormatTranscriptEcho/single_line
=== RUN   TestFormatTranscriptEcho/multi_line
=== RUN   TestFormatTranscriptEcho/empty_string
--- PASS: TestFormatTranscriptEcho (0.00s)
    --- PASS: TestFormatTranscriptEcho/single_line (0.00s)
    --- PASS: TestFormatTranscriptEcho/multi_line (0.00s)
    --- PASS: TestFormatTranscriptEcho/empty_string (0.00s)
=== RUN   TestIsSupportedMessageType
=== RUN   TestIsSupportedMessageType/m.text
=== RUN   TestIsSupportedMessageType/m.image
=== RUN   TestIsSupportedMessageType/m.audio
=== RUN   TestIsSupportedMessageType/m.video
=== RUN   TestIsSupportedMessageType/m.file
=== RUN   TestIsSupportedMessageType/m.notice
=== RUN   TestIsSupportedMessageType/m.emote
--- PASS: TestIsSupportedMessageType (0.00s)
    --- PASS: TestIsSupportedMessageType/m.text (0.00s)
    --- PASS: TestIsSupportedMessageType/m.image (0.00s)
    --- PASS: TestIsSupportedMessageType/m.audio (0.00s)
    --- PASS: TestIsSupportedMessageType/m.video (0.00s)
    --- PASS: TestIsSupportedMessageType/m.file (0.00s)
    --- PASS: TestIsSupportedMessageType/m.notice (0.00s)
    --- PASS: TestIsSupportedMessageType/m.emote (0.00s)
=== RUN   TestIsMessageAfterStartup
=== RUN   TestIsMessageAfterStartup/before_startup
=== RUN   TestIsMessageAfterStartup/at_startup
=== RUN   TestIsMessageAfterStartup/after_startup
=== RUN   TestIsMessageAfterStartup/well_after_startup
--- PASS: TestIsMessageAfterStartup (0.00s)
    --- PASS: TestIsMessageAfterStartup/before_startup (0.00s)
    --- PASS: TestIsMessageAfterStartup/at_startup (0.00s)
    --- PASS: TestIsMessageAfterStartup/after_startup (0.00s)
    --- PASS: TestIsMessageAfterStartup/well_after_startup (0.00s)
=== RUN   TestBridge_FindRoomByName
--- PASS: TestBridge_FindRoomByName (0.00s)
=== RUN   TestBridge_AnnounceStartup
2026/03/01 06:12:29 Posted startup announcement to ops: dev
--- PASS: TestBridge_AnnounceStartup (0.00s)
=== RUN   TestBridge_AnnounceStartup_NoOpsRoom
--- PASS: TestBridge_AnnounceStartup_NoOpsRoom (0.00s)
=== RUN   TestBridge_AnnounceDrain
2026/03/01 06:12:29 Posted drain announcement to ops
--- PASS: TestBridge_AnnounceDrain (0.00s)
=== RUN   TestBridge_AnnounceDrain_NoOpsRoom
--- PASS: TestBridge_AnnounceDrain_NoOpsRoom (0.00s)
=== RUN   TestBridge_ActiveRoomCount
--- PASS: TestBridge_ActiveRoomCount (0.00s)
=== RUN   TestBridge_DrainingPreventsNewMessages
2026/03/01 06:12:29 Event received: type=m.room.message sender=@alice:example.com room=!test:example.com id=$evt-1770890460000000000 ts=1770890460000
2026/03/01 06:12:29 Draining — ignoring message from @alice:example.com
--- PASS: TestBridge_DrainingPreventsNewMessages (0.00s)
=== RUN   TestBridge_DrainCompletesWhenRoomsDropToOne
--- PASS: TestBridge_DrainCompletesWhenRoomsDropToOne (0.00s)
=== RUN   TestBridge_DrainCompletesWhenAllRoomsFinish
--- PASS: TestBridge_DrainCompletesWhenAllRoomsFinish (0.00s)
=== RUN   TestBridge_ActiveRoomTracking_ThroughInvocation
2026/03/01 06:12:29 Event received: type=m.room.message sender=@alice:example.com room=!test:example.com id=$evt-1770890460000000000 ts=1770890460000
2026/03/01 06:12:29 [!test:example.com] @alice:example.com: test
2026/03/01 06:12:29 Invoking claude with args: [-p --output-format stream-json --verbose --dangerously-skip-permissions -- test]
2026/03/01 06:12:29 Claude output line: {"message":{"content":[{"text":"Done!","type":"text"}],"usage":{"input_tokens":100,"output_tokens":50}},"session_id":"sess-drain","type":"assistant"}
2026/03/01 06:12:29 Sent/edited with text content
2026/03/01 06:12:29 Sent initial message: $mock-1
2026/03/01 06:12:29 Claude output line: {"modelUsage":{"default":{"contextWindow":200000}},"result":"Done!","session_id":"sess-drain","type":"result"}
2026/03/01 06:12:29 Context saturation for room !test:example.com: 0% (0k / 200k tokens)
--- PASS: TestBridge_ActiveRoomTracking_ThroughInvocation (0.10s)
=== RUN   TestBridge_DrainMode_SetsAtomicFlag
--- PASS: TestBridge_DrainMode_SetsAtomicFlag (0.00s)
=== RUN   TestInvokeClaude_SimpleResponse
2026/03/01 06:12:29 Invoking claude with args: [-p --output-format stream-json --verbose --dangerously-skip-permissions -- [Matrix room: test-room]

Hi there]
2026/03/01 06:12:29 Claude output line: {"message":{"content":[{"text":"Hello from Claude!","type":"text"}],"usage":{"input_tokens":100,"output_tokens":50}},"session_id":"sess-123","type":"assistant"}
2026/03/01 06:12:29 Sent/edited with text content
2026/03/01 06:12:29 Sent initial message: $mock-1
2026/03/01 06:12:29 Claude output line: {"modelUsage":{"default":{"contextWindow":200000}},"result":"Hello from Claude!","session_id":"sess-123","type":"result"}
--- PASS: TestInvokeClaude_SimpleResponse (0.00s)
=== RUN   TestInvokeClaude_MultiSectionEditInPlace
2026/03/01 06:12:29 Invoking claude with args: [-p --output-format stream-json --verbose --dangerously-skip-permissions -- [Matrix room: test-room]

Check something]
2026/03/01 06:12:29 Claude output line: {"message":{"content":[{"text":"Let me check that for you.","type":"text"}],"usage":{"input_tokens":100,"output_tokens":50}},"session_id":"sess-456","type":"assistant"}
2026/03/01 06:12:29 Sent/edited with text content
2026/03/01 06:12:29 Sent initial message: $mock-1
2026/03/01 06:12:29 Claude output line: {"message":{"content":[{"input":{"file_path":"/tmp/test.go"},"name":"Read","type":"tool_use"}],"usage":{"input_tokens":100,"output_tokens":50}},"session_id":"sess-456","type":"assistant"}
2026/03/01 06:12:29 Edited message: $mock-1
2026/03/01 06:12:29 Sent/edited with tool call: Read
2026/03/01 06:12:29 Claude output line: {"message":{"content":[{"text":"Here's what I found.","type":"text"}],"usage":{"input_tokens":100,"output_tokens":50}},"session_id":"sess-456","type":"assistant"}
2026/03/01 06:12:29 Sent/edited with text content (thinking)
2026/03/01 06:12:29 Edited message: $mock-1
2026/03/01 06:12:29 Claude output line: {"modelUsage":{"default":{"contextWindow":200000}},"result":"Here's what I found.","session_id":"sess-456","type":"result"}
2026/03/01 06:12:29 Reverted last section from thinking to plain text
2026/03/01 06:12:29 Edited message: $mock-1
2026/03/01 06:12:29 Final edit: removed working indicator
--- PASS: TestInvokeClaude_MultiSectionEditInPlace (0.00s)
=== RUN   TestInvokeClaude_WorkingIndicatorOnIntermediateEdits
2026/03/01 06:12:29 Invoking claude with args: [-p --output-format stream-json --verbose --dangerously-skip-permissions -- [Matrix room: test-room]

Do work]
2026/03/01 06:12:29 Claude output line: {"message":{"content":[{"text":"Starting work...","type":"text"},{"input":{"command":"ls"},"name":"Bash","type":"tool_use"}],"usage":{"input_tokens":100,"output_tokens":50}},"session_id":"sess-789","t
2026/03/01 06:12:29 Sent/edited with text content
2026/03/01 06:12:29 Sent initial message: $mock-1
2026/03/01 06:12:29 Edited message: $mock-1
2026/03/01 06:12:29 Sent/edited with tool call: Bash
2026/03/01 06:12:29 Claude output line: {"message":{"content":[{"text":"All done.","type":"text"}],"usage":{"input_tokens":100,"output_tokens":50}},"session_id":"sess-789","type":"assistant"}
2026/03/01 06:12:29 Sent/edited with text content (thinking)
2026/03/01 06:12:29 Edited message: $mock-1
2026/03/01 06:12:29 Claude output line: {"modelUsage":{"default":{"contextWindow":200000}},"result":"All done.","session_id":"sess-789","type":"result"}
2026/03/01 06:12:29 Reverted last section from thinking to plain text
2026/03/01 06:12:29 Edited message: $mock-1
2026/03/01 06:12:29 Final edit: removed working indicator
--- PASS: TestInvokeClaude_WorkingIndicatorOnIntermediateEdits (0.00s)
=== RUN   TestInvokeClaude_SessionResume
2026/03/01 06:12:29 Invoking claude with args: [-p --output-format stream-json --verbose --dangerously-skip-permissions --resume existing-sess -- Continue]
2026/03/01 06:12:29 Claude output line: {"message":{"content":[{"text":"Resumed!","type":"text"}],"usage":{"input_tokens":100,"output_tokens":50}},"session_id":"existing-sess","type":"assistant"}
2026/03/01 06:12:29 Sent/edited with text content
2026/03/01 06:12:29 Sent initial message: $mock-1
2026/03/01 06:12:29 Claude output line: {"modelUsage":{"default":{"contextWindow":200000}},"result":"Resumed!","session_id":"existing-sess","type":"result"}
--- PASS: TestInvokeClaude_SessionResume (0.00s)
=== RUN   TestInvokeClaude_FreshSessionNoResume
2026/03/01 06:12:29 Invoking claude with args: [-p --output-format stream-json --verbose --dangerously-skip-permissions -- [Matrix room: test-room]

Hello]
2026/03/01 06:12:29 Claude output line: {"message":{"content":[{"text":"Hello!","type":"text"}],"usage":{"input_tokens":100,"output_tokens":50}},"session_id":"new-sess","type":"assistant"}
2026/03/01 06:12:29 Sent/edited with text content
2026/03/01 06:12:29 Sent initial message: $mock-1
2026/03/01 06:12:29 Claude output line: {"modelUsage":{"default":{"contextWindow":200000}},"result":"Hello!","session_id":"new-sess","type":"result"}
--- PASS: TestInvokeClaude_FreshSessionNoResume (0.00s)
=== RUN   TestInvokeClaude_ContextInfoExtracted
2026/03/01 06:12:29 Invoking claude with args: [-p --output-format stream-json --verbose --dangerously-skip-permissions -- [Matrix room: test-room]

test]
2026/03/01 06:12:29 Claude output line: {"message":{"content":[{"text":"Response","type":"text"}],"usage":{"input_tokens":100,"output_tokens":50}},"session_id":"sess-ctx","type":"assistant"}
2026/03/01 06:12:29 Sent/edited with text content
2026/03/01 06:12:29 Sent initial message: $mock-1
2026/03/01 06:12:29 Claude output line: {"modelUsage":{"default":{"contextWindow":180000}},"result":"Response","session_id":"sess-ctx","type":"result"}
--- PASS: TestInvokeClaude_ContextInfoExtracted (0.00s)
=== RUN   TestInvokeClaude_ThinkingFormatting
2026/03/01 06:12:29 Invoking claude with args: [-p --output-format stream-json --verbose --dangerously-skip-permissions -- [Matrix room: test-room]

test thinking]
2026/03/01 06:12:29 Claude output line: {"message":{"content":[{"text":"Initial response","type":"text"}],"usage":{"input_tokens":100,"output_tokens":50}},"session_id":"sess-think","type":"assistant"}
2026/03/01 06:12:29 Sent/edited with text content
2026/03/01 06:12:29 Sent initial message: $mock-1
2026/03/01 06:12:29 Claude output line: {"message":{"content":[{"input":{"command":"echo hello"},"name":"Bash","type":"tool_use"}],"usage":{"input_tokens":100,"output_tokens":50}},"session_id":"sess-think","type":"assistant"}
2026/03/01 06:12:29 Edited message: $mock-1
2026/03/01 06:12:29 Sent/edited with tool call: Bash
2026/03/01 06:12:29 Claude output line: {"message":{"content":[{"text":"Final answer after tool","type":"text"}],"usage":{"input_tokens":100,"output_tokens":50}},"session_id":"sess-think","type":"assistant"}
2026/03/01 06:12:29 Sent/edited with text content (thinking)
2026/03/01 06:12:29 Edited message: $mock-1
2026/03/01 06:12:29 Claude output line: {"modelUsage":{"default":{"contextWindow":200000}},"result":"Final answer after tool","session_id":"sess-think","type":"result"}
2026/03/01 06:12:29 Reverted last section from thinking to plain text
2026/03/01 06:12:29 Edited message: $mock-1
2026/03/01 06:12:29 Final edit: removed working indicator
--- PASS: TestInvokeClaude_ThinkingFormatting (0.00s)
=== RUN   TestInvokeClaude_EnvVarsSet
2026/03/01 06:12:29 Invoking claude with args: [-p --output-format stream-json --verbose --dangerously-skip-permissions -- [Matrix room: test-room]

test]
2026/03/01 06:12:29 Claude output line: {"message":{"content":[{"text":"ok","type":"text"}],"usage":{"input_tokens":100,"output_tokens":50}},"session_id":"sess-env","type":"assistant"}
2026/03/01 06:12:29 Sent/edited with text content
2026/03/01 06:12:29 Sent initial message: $mock-1
2026/03/01 06:12:29 Claude output line: {"modelUsage":{"default":{"contextWindow":200000}},"result":"ok","session_id":"sess-env","type":"result"}
--- PASS: TestInvokeClaude_EnvVarsSet (0.00s)
=== RUN   TestInvokeClaude_HandoffLoadedOnFreshSession
2026/03/01 06:12:29 Loaded handoff for room "test-room" from /tmp/nix-shell.z0B0es/TestInvokeClaude_HandoffLoadedOnFreshSession1654639518/001/handoffs/test-room/2026-02-12_10-00-00.md (24 bytes)
2026/03/01 06:12:29 Invoking claude with args: [-p --output-format stream-json --verbose --dangerously-skip-permissions --append-system-prompt <room-handoff>
This is the handoff from your previous session in this room. Use it for context but don't reference it explicitly unless asked.

Previous handoff content
</room-handoff> -- [Matrix room: test-room]

Hello again]
2026/03/01 06:12:29 Claude output line: {"message":{"content":[{"text":"Got it!","type":"text"}],"usage":{"input_tokens":100,"output_tokens":50}},"session_id":"sess-ho2","type":"assistant"}
2026/03/01 06:12:29 Sent/edited with text content
2026/03/01 06:12:29 Sent initial message: $mock-1
2026/03/01 06:12:29 Claude output line: {"modelUsage":{"default":{"contextWindow":200000}},"result":"Got it!","session_id":"sess-ho2","type":"result"}
--- PASS: TestInvokeClaude_HandoffLoadedOnFreshSession (0.00s)
=== RUN   TestInvokeClaude_ProactiveSplitOnLargeMessage
2026/03/01 06:12:29 Invoking claude with args: [-p --output-format stream-json --verbose --dangerously-skip-permissions -- [Matrix room: test-room]

do big work]
2026/03/01 06:12:29 Claude output line: {"message":{"content":[{"text":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
2026/03/01 06:12:29 Sent/edited with text content
2026/03/01 06:12:29 Sent initial message: $mock-1
2026/03/01 06:12:29 Claude output line: {"message":{"content":[{"input":{"command":"echo test"},"name":"Bash","type":"tool_use"}],"usage":{"input_tokens":100,"output_tokens":50}},"session_id":"sess-split","type":"assistant"}
2026/03/01 06:12:29 Edited message: $mock-1
2026/03/01 06:12:29 Sent/edited with tool call: Bash
2026/03/01 06:12:29 Claude output line: {"message":{"content":[{"text":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
2026/03/01 06:12:29 Sent/edited with text content (thinking)
2026/03/01 06:12:29 Split: finalized message $mock-1 (30744 bytes), starting fresh
2026/03/01 06:12:29 Sent initial message: $mock-4
2026/03/01 06:12:29 Claude output line: {"modelUsage":{"default":{"contextWindow":200000}},"result":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
2026/03/01 06:12:29 Reverted last section from thinking to plain text
--- PASS: TestInvokeClaude_ProactiveSplitOnLargeMessage (0.00s)
=== RUN   TestInvokeClaude_ProactiveSplitCarriesContent
2026/03/01 06:12:29 Invoking claude with args: [-p --output-format stream-json --verbose --dangerously-skip-permissions -- [Matrix room: test-room]

test carry]
2026/03/01 06:12:29 Claude output line: {"message":{"content":[{"text":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
2026/03/01 06:12:29 Sent/edited with text content
2026/03/01 06:12:29 Sent initial message: $mock-1
2026/03/01 06:12:29 Claude output line: {"message":{"content":[{"text":"CARRIED_OVER_MARKER_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
2026/03/01 06:12:29 Sent/edited with text content
2026/03/01 06:12:29 Split: finalized message $mock-1 (40960 bytes), starting fresh
2026/03/01 06:12:29 Sent initial message: $mock-3
2026/03/01 06:12:29 Claude output line: {"modelUsage":{"default":{"contextWindow":200000}},"result":"CARRIED_OVER_MARKER_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
--- PASS: TestInvokeClaude_ProactiveSplitCarriesContent (0.00s)
=== RUN   TestInvokeClaude_FallbackSplitOnEditError
2026/03/01 06:12:29 Invoking claude with args: [-p --output-format stream-json --verbose --dangerously-skip-permissions -- [Matrix room: test-room]

trigger fallback]
2026/03/01 06:12:29 Claude output line: {"message":{"content":[{"text":"short initial","type":"text"}],"usage":{"input_tokens":100,"output_tokens":50}},"session_id":"sess-fallback","type":"assistant"}
2026/03/01 06:12:29 Sent/edited with text content
2026/03/01 06:12:29 Sent initial message: $mock-1
2026/03/01 06:12:29 Claude output line: {"message":{"content":[{"input":{"command":"ls"},"name":"Bash","type":"tool_use"}],"usage":{"input_tokens":100,"output_tokens":50}},"session_id":"sess-fallback","type":"assistant"}
2026/03/01 06:12:29 Edited message: $mock-1
2026/03/01 06:12:29 Sent/edited with tool call: Bash
2026/03/01 06:12:29 Claude output line: {"message":{"content":[{"text":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
2026/03/01 06:12:29 Sent/edited with text content (thinking)
2026/03/01 06:12:29 Failed to edit message $mock-1 in !test:example.com: M_TOO_LARGE (HTTP 413): event too large
2026/03/01 06:12:29 Edit failed, splitting to fresh message: M_TOO_LARGE (HTTP 413): event too large
2026/03/01 06:12:29 Split: finalized message $mock-1 (30 bytes), starting fresh
2026/03/01 06:12:29 Sent fallback message: $mock-5
2026/03/01 06:12:29 Claude output line: {"modelUsage":{"default":{"contextWindow":200000}},"result":"done","session_id":"sess-fallback","type":"result"}
2026/03/01 06:12:29 Reverted last section from thinking to plain text
--- PASS: TestInvokeClaude_FallbackSplitOnEditError (0.00s)
=== RUN   TestBuildInterruptedSummary
=== RUN   TestBuildInterruptedSummary/empty_sections
=== RUN   TestBuildInterruptedSummary/short_summary
=== RUN   TestBuildInterruptedSummary/long_summary_gets_truncated
--- PASS: TestBuildInterruptedSummary (0.00s)
    --- PASS: TestBuildInterruptedSummary/empty_sections (0.00s)
    --- PASS: TestBuildInterruptedSummary/short_summary (0.00s)
    --- PASS: TestBuildInterruptedSummary/long_summary_gets_truncated (0.00s)
=== RUN   TestLoadCraniumConfig_FullConfig
--- PASS: TestLoadCraniumConfig_FullConfig (0.00s)
=== RUN   TestLoadCraniumConfig_Defaults
--- PASS: TestLoadCraniumConfig_Defaults (0.00s)
=== RUN   TestLoadCraniumConfig_MissingRequired
=== RUN   TestLoadCraniumConfig_MissingRequired/missing_homeserver
=== RUN   TestLoadCraniumConfig_MissingRequired/missing_username
=== RUN   TestLoadCraniumConfig_MissingRequired/missing_password_file
=== RUN   TestLoadCraniumConfig_MissingRequired/missing_identity_file
--- PASS: TestLoadCraniumConfig_MissingRequired (0.00s)
    --- PASS: TestLoadCraniumConfig_MissingRequired/missing_homeserver (0.00s)
    --- PASS: TestLoadCraniumConfig_MissingRequired/missing_username (0.00s)
    --- PASS: TestLoadCraniumConfig_MissingRequired/missing_password_file (0.00s)
    --- PASS: TestLoadCraniumConfig_MissingRequired/missing_identity_file (0.00s)
=== RUN   TestLoadCraniumConfig_FileNotFound
--- PASS: TestLoadCraniumConfig_FileNotFound (0.00s)
=== RUN   TestLoadIdentityConfig_FullConfig
--- PASS: TestLoadIdentityConfig_FullConfig (0.00s)
=== RUN   TestLoadIdentityConfig_Defaults
--- PASS: TestLoadIdentityConfig_Defaults (0.00s)
=== RUN   TestLoadIdentityConfig_MissingRequired
=== RUN   TestLoadIdentityConfig_MissingRequired/missing_system_prompt_file
=== RUN   TestLoadIdentityConfig_MissingRequired/missing_data_dir
--- PASS: TestLoadIdentityConfig_MissingRequired (0.00s)
    --- PASS: TestLoadIdentityConfig_MissingRequired/missing_system_prompt_file (0.00s)
    --- PASS: TestLoadIdentityConfig_MissingRequired/missing_data_dir (0.00s)
=== RUN   TestLoadIdentityConfig_FileNotFound
--- PASS: TestLoadIdentityConfig_FileNotFound (0.00s)
=== RUN   TestLoadCraniumConfig_InvalidYAML
--- PASS: TestLoadCraniumConfig_InvalidYAML (0.00s)
=== RUN   TestLoadIdentityConfig_InvalidYAML
--- PASS: TestLoadIdentityConfig_InvalidYAML (0.00s)
=== RUN   TestSaturation
=== RUN   TestSaturation/zero_window_returns_0
=== RUN   TestSaturation/empty_context
=== RUN   TestSaturation/50_percent
=== RUN   TestSaturation/75_percent
=== RUN   TestSaturation/100_percent
=== RUN   TestSaturation/real-world_usage
--- PASS: TestSaturation (0.00s)
    --- PASS: TestSaturation/zero_window_returns_0 (0.00s)
    --- PASS: TestSaturation/empty_context (0.00s)
    --- PASS: TestSaturation/50_percent (0.00s)
    --- PASS: TestSaturation/75_percent (0.00s)
    --- PASS: TestSaturation/100_percent (0.00s)
    --- PASS: TestSaturation/real-world_usage (0.00s)
=== RUN   TestContextSaturationAdvice
=== RUN   TestContextSaturationAdvice/suggest_a_!clear
=== RUN   TestContextSaturationAdvice/suggest_a_!clear#01
=== RUN   TestContextSaturationAdvice/suggest_a_!clear#02
=== RUN   TestContextSaturationAdvice/Start_wrapping_up
=== RUN   TestContextSaturationAdvice/Start_wrapping_up#01
=== RUN   TestContextSaturationAdvice/Be_mindful_of_scope
=== RUN   TestContextSaturationAdvice/Be_mindful_of_scope#01
=== RUN   TestContextSaturationAdvice/past_halfway
=== RUN   TestContextSaturationAdvice/past_halfway#01
--- PASS: TestContextSaturationAdvice (0.00s)
    --- PASS: TestContextSaturationAdvice/suggest_a_!clear (0.00s)
    --- PASS: TestContextSaturationAdvice/suggest_a_!clear#01 (0.00s)
    --- PASS: TestContextSaturationAdvice/suggest_a_!clear#02 (0.00s)
    --- PASS: TestContextSaturationAdvice/Start_wrapping_up (0.00s)
    --- PASS: TestContextSaturationAdvice/Start_wrapping_up#01 (0.00s)
    --- PASS: TestContextSaturationAdvice/Be_mindful_of_scope (0.00s)
    --- PASS: TestContextSaturationAdvice/Be_mindful_of_scope#01 (0.00s)
    --- PASS: TestContextSaturationAdvice/past_halfway (0.00s)
    --- PASS: TestContextSaturationAdvice/past_halfway#01 (0.00s)
=== RUN   TestShouldInjectTimeGap
=== RUN   TestShouldInjectTimeGap/15m0s
=== RUN   TestShouldInjectTimeGap/30m0s
=== RUN   TestShouldInjectTimeGap/31m0s
=== RUN   TestShouldInjectTimeGap/2h0m0s
=== RUN   TestShouldInjectTimeGap/0s
--- PASS: TestShouldInjectTimeGap (0.00s)
    --- PASS: TestShouldInjectTimeGap/15m0s (0.00s)
    --- PASS: TestShouldInjectTimeGap/30m0s (0.00s)
    --- PASS: TestShouldInjectTimeGap/31m0s (0.00s)
    --- PASS: TestShouldInjectTimeGap/2h0m0s (0.00s)
    --- PASS: TestShouldInjectTimeGap/0s (0.00s)
=== RUN   TestFormatTimeGap
--- PASS: TestFormatTimeGap (0.00s)
=== RUN   TestTimeGapMaxAge
=== RUN   TestTimeGapMaxAge/1h0m0s
=== RUN   TestTimeGapMaxAge/6h0m0s
=== RUN   TestTimeGapMaxAge/13h0m0s
=== RUN   TestTimeGapMaxAge/48h0m0s
--- PASS: TestTimeGapMaxAge (0.00s)
    --- PASS: TestTimeGapMaxAge/1h0m0s (0.00s)
    --- PASS: TestTimeGapMaxAge/6h0m0s (0.00s)
    --- PASS: TestTimeGapMaxAge/13h0m0s (0.00s)
    --- PASS: TestTimeGapMaxAge/48h0m0s (0.00s)
=== RUN   TestShouldInjectSaturationReminder
=== RUN   TestShouldInjectSaturationReminder/below_50_—_no
=== RUN   TestShouldInjectSaturationReminder/at_50,_no_prior_reminder_—_yes
=== RUN   TestShouldInjectSaturationReminder/at_52,_already_reminded_at_50_—_no
=== RUN   TestShouldInjectSaturationReminder/at_56,_reminded_at_50_—_yes_(crosses_55)
=== RUN   TestShouldInjectSaturationReminder/at_82,_reminded_at_75_—_yes_(crosses_80)
=== RUN   TestShouldInjectSaturationReminder/at_82,_reminded_at_80_—_no
--- PASS: TestShouldInjectSaturationReminder (0.00s)
    --- PASS: TestShouldInjectSaturationReminder/below_50_—_no (0.00s)
    --- PASS: TestShouldInjectSaturationReminder/at_50,_no_prior_reminder_—_yes (0.00s)
    --- PASS: TestShouldInjectSaturationReminder/at_52,_already_reminded_at_50_—_no (0.00s)
    --- PASS: TestShouldInjectSaturationReminder/at_56,_reminded_at_50_—_yes_(crosses_55) (0.00s)
    --- PASS: TestShouldInjectSaturationReminder/at_82,_reminded_at_75_—_yes_(crosses_80) (0.00s)
    --- PASS: TestShouldInjectSaturationReminder/at_82,_reminded_at_80_—_no (0.00s)
=== RUN   TestSaturationBucket
=== RUN   TestSaturationBucket/52
=== RUN   TestSaturationBucket/55
=== RUN   TestSaturationBucket/59
=== RUN   TestSaturationBucket/60
=== RUN   TestSaturationBucket/78
=== RUN   TestSaturationBucket/80
=== RUN   TestSaturationBucket/99
--- PASS: TestSaturationBucket (0.00s)
    --- PASS: TestSaturationBucket/52 (0.00s)
    --- PASS: TestSaturationBucket/55 (0.00s)
    --- PASS: TestSaturationBucket/59 (0.00s)
    --- PASS: TestSaturationBucket/60 (0.00s)
    --- PASS: TestSaturationBucket/78 (0.00s)
    --- PASS: TestSaturationBucket/80 (0.00s)
    --- PASS: TestSaturationBucket/99 (0.00s)
=== RUN   TestBuildFreshSessionPrompt
--- PASS: TestBuildFreshSessionPrompt (0.00s)
=== RUN   TestBuildAppendSystemPrompt
--- PASS: TestBuildAppendSystemPrompt (0.00s)
=== RUN   TestBuildCLIArgs
--- PASS: TestBuildCLIArgs (0.00s)
=== RUN   TestFormatDuration
=== RUN   TestFormatDuration/minutes_only
=== RUN   TestFormatDuration/one_hour_exact
=== RUN   TestFormatDuration/hours_and_minutes
=== RUN   TestFormatDuration/hours_exact
=== RUN   TestFormatDuration/one_day
=== RUN   TestFormatDuration/multiple_days
=== RUN   TestFormatDuration/zero_minutes
--- PASS: TestFormatDuration (0.00s)
    --- PASS: TestFormatDuration/minutes_only (0.00s)
    --- PASS: TestFormatDuration/one_hour_exact (0.00s)
    --- PASS: TestFormatDuration/hours_and_minutes (0.00s)
    --- PASS: TestFormatDuration/hours_exact (0.00s)
    --- PASS: TestFormatDuration/one_day (0.00s)
    --- PASS: TestFormatDuration/multiple_days (0.00s)
    --- PASS: TestFormatDuration/zero_minutes (0.00s)
=== RUN   TestFormatSaturationReminder
--- PASS: TestFormatSaturationReminder (0.00s)
=== RUN   TestPrependSystemReminder
--- PASS: TestPrependSystemReminder (0.00s)
=== RUN   TestBuildInvocationPlan_FreshSession
--- PASS: TestBuildInvocationPlan_FreshSession (0.00s)
=== RUN   TestBuildInvocationPlan_ExistingSession
--- PASS: TestBuildInvocationPlan_ExistingSession (0.00s)
=== RUN   TestBuildInvocationPlan_TimeGapInjection
--- PASS: TestBuildInvocationPlan_TimeGapInjection (0.00s)
=== RUN   TestBuildInvocationPlan_SaturationReminder
--- PASS: TestBuildInvocationPlan_SaturationReminder (0.00s)
=== RUN   TestBuildInvocationPlan_NoSaturationReminderBelowThreshold
--- PASS: TestBuildInvocationPlan_NoSaturationReminderBelowThreshold (0.00s)
=== RUN   TestBuildInvocationPlan_CombinedTimeGapAndSaturation
--- PASS: TestBuildInvocationPlan_CombinedTimeGapAndSaturation (0.00s)
=== RUN   TestBuildInvocationPlan_InterruptedContext
--- PASS: TestBuildInvocationPlan_InterruptedContext (0.00s)
=== RUN   TestBuildInvocationPlan_ProjectDir
--- PASS: TestBuildInvocationPlan_ProjectDir (0.00s)
=== RUN   TestBuildInvocationPlan_NoProjectDir
--- PASS: TestBuildInvocationPlan_NoProjectDir (0.00s)
=== RUN   TestBuildInvocationPlan_SystemPromptAlwaysInjected
--- PASS: TestBuildInvocationPlan_SystemPromptAlwaysInjected (0.00s)
=== RUN   TestBuildInvocationPlan_NoInterruptedContextForFreshSession
--- PASS: TestBuildInvocationPlan_NoInterruptedContextForFreshSession (0.00s)
=== RUN   TestBridge_EvictStaleEntries_RemovesOldSeenEvents
2026/03/01 06:12:29 Eviction: removed 1 seenEvents, 0 deniedCache entries older than 24h0m0s
--- PASS: TestBridge_EvictStaleEntries_RemovesOldSeenEvents (0.00s)
=== RUN   TestBridge_EvictStaleEntries_RemovesOldDeniedCache
2026/03/01 06:12:29 Eviction: removed 0 seenEvents, 1 deniedCache entries older than 24h0m0s
--- PASS: TestBridge_EvictStaleEntries_RemovesOldDeniedCache (0.00s)
=== RUN   TestBridge_EvictStaleEntries_NoOpWhenEmpty
--- PASS: TestBridge_EvictStaleEntries_NoOpWhenEmpty (0.00s)
=== RUN   TestBridge_EvictStaleEntries_NoOpWhenAllRecent
--- PASS: TestBridge_EvictStaleEntries_NoOpWhenAllRecent (0.00s)
=== RUN   TestBridge_EvictStaleEntries_HandlesExactCutoff
2026/03/01 06:12:29 Eviction: removed 1 seenEvents, 0 deniedCache entries older than 24h0m0s
--- PASS: TestBridge_EvictStaleEntries_HandlesExactCutoff (0.00s)
=== RUN   TestBridge_HandleMessage_IgnoresOwnMessages
2026/03/01 06:12:29 Event received: type=m.room.message sender=@agent:example.com room=!test:example.com id=$evt-1770890460000000000 ts=1770890460000
2026/03/01 06:12:29 Ignoring own message
--- PASS: TestBridge_HandleMessage_IgnoresOwnMessages (0.00s)
=== RUN   TestBridge_HandleMessage_IgnoresOldMessages
2026/03/01 06:12:29 Event received: type=m.room.message sender=@alice:example.com room=!test:example.com id=$evt-1770890340000000000 ts=1770890340000
2026/03/01 06:12:29 Ignoring old message (before bridge start)
--- PASS: TestBridge_HandleMessage_IgnoresOldMessages (0.00s)
=== RUN   TestBridge_HandleMessage_IgnoresDuplicateEvents
2026/03/01 06:12:29 Event received: type=m.room.message sender=@alice:example.com room=!test:example.com id=$evt-1770890460000000000 ts=1770890460000
2026/03/01 06:12:29 Ignoring duplicate event $evt-1770890460000000000
--- PASS: TestBridge_HandleMessage_IgnoresDuplicateEvents (0.00s)
=== RUN   TestBridge_HandleMessage_IgnoresWhileDraining
2026/03/01 06:12:29 Event received: type=m.room.message sender=@alice:example.com room=!test:example.com id=$evt-1770890460000000000 ts=1770890460000
2026/03/01 06:12:29 Draining — ignoring message from @alice:example.com
--- PASS: TestBridge_HandleMessage_IgnoresWhileDraining (0.00s)
=== RUN   TestBridge_HandleMessage_IgnoresExcludedRooms
2026/03/01 06:12:29 Event received: type=m.room.message sender=@alice:example.com room=!ops:example.com id=$evt-1770890460000000000 ts=1770890460000
2026/03/01 06:12:29 Ignoring message in excluded room !ops:example.com
--- PASS: TestBridge_HandleMessage_IgnoresExcludedRooms (0.00s)
=== RUN   TestBridge_HandleMessage_ClearNoSession
2026/03/01 06:12:29 Event received: type=m.room.message sender=@alice:example.com room=!test:example.com id=$evt-1770890460000000000 ts=1770890460000
2026/03/01 06:12:29 [!test:example.com] @alice:example.com: !clear
--- PASS: TestBridge_HandleMessage_ClearNoSession (0.10s)
=== RUN   TestBridge_HandleMessage_ClearDuringActiveInvocation
2026/03/01 06:12:29 Event received: type=m.room.message sender=@alice:example.com room=!test:example.com id=$evt-1770890460000000000 ts=1770890460000
2026/03/01 06:12:29 [!test:example.com] @alice:example.com: !clear
--- PASS: TestBridge_HandleMessage_ClearDuringActiveInvocation (0.05s)
=== RUN   TestBridge_HandleMessage_NewRoom
2026/03/01 06:12:30 Event received: type=m.room.message sender=@alice:example.com room=!test:example.com id=$evt-1770890460000000000 ts=1770890460000
2026/03/01 06:12:30 [!test:example.com] @alice:example.com: !new test-room
2026/03/01 06:12:30 Created room "test-room" (!new-room:example.com), invited @alice:example.com
--- PASS: TestBridge_HandleMessage_NewRoom (0.10s)
=== RUN   TestBridge_HandleMessage_NewRoomNoName
2026/03/01 06:12:30 Event received: type=m.room.message sender=@alice:example.com room=!test:example.com id=$evt-1770890460000000000 ts=1770890460000
2026/03/01 06:12:30 [!test:example.com] @alice:example.com: !new
--- PASS: TestBridge_HandleMessage_NewRoomNoName (0.05s)
=== RUN   TestBridge_TypingIndicator_ReadReceiptAndTypingFired
2026/03/01 06:12:30 Event received: type=m.room.message sender=@alice:example.com room=!test:example.com id=$evt-1770890460000000000 ts=1770890460000
2026/03/01 06:12:30 [!test:example.com] @alice:example.com: test
2026/03/01 06:12:30 Invoking claude with args: [-p --output-format stream-json --verbose --dangerously-skip-permissions -- test]
2026/03/01 06:12:30 Claude output line: {"message":{"content":[{"text":"Done!","type":"text"}],"usage":{"input_tokens":100,"output_tokens":50}},"session_id":"sess-typing","type":"assistant"}
2026/03/01 06:12:30 Sent/edited with text content
2026/03/01 06:12:30 Sent initial message: $mock-1
2026/03/01 06:12:30 Claude output line: {"modelUsage":{"default":{"contextWindow":200000}},"result":"Done!","session_id":"sess-typing","type":"result"}
2026/03/01 06:12:30 Context saturation for room !test:example.com: 0% (0k / 200k tokens)
--- PASS: TestBridge_TypingIndicator_ReadReceiptAndTypingFired (0.10s)
=== RUN   TestBridge_TypingIndicator_CancelledOnResponse
2026/03/01 06:12:30 Event received: type=m.room.message sender=@alice:example.com room=!test:example.com id=$evt-1770890460000000000 ts=1770890460000
2026/03/01 06:12:30 [!test:example.com] @alice:example.com: hello
2026/03/01 06:12:30 Invoking claude with args: [-p --output-format stream-json --verbose --dangerously-skip-permissions -- hello]
2026/03/01 06:12:30 Claude output line: {"message":{"content":[{"text":"Quick response","type":"text"}],"usage":{"input_tokens":100,"output_tokens":50}},"session_id":"sess-cancel","type":"assistant"}
2026/03/01 06:12:30 Sent/edited with text content
2026/03/01 06:12:30 Sent initial message: $mock-1
2026/03/01 06:12:30 Claude output line: {"modelUsage":{"default":{"contextWindow":200000}},"result":"Quick response","session_id":"sess-cancel","type":"result"}
2026/03/01 06:12:30 Context saturation for room !test:example.com: 0% (0k / 200k tokens)
--- PASS: TestBridge_TypingIndicator_CancelledOnResponse (0.05s)
=== RUN   TestBridge_TypingIndicator_LastCallIsCancellation
2026/03/01 06:12:30 Event received: type=m.room.message sender=@alice:example.com room=!test:example.com id=$evt-1770890460000000000 ts=1770890460000
2026/03/01 06:12:30 [!test:example.com] @alice:example.com: test
2026/03/01 06:12:30 Invoking claude with args: [-p --output-format stream-json --verbose --dangerously-skip-permissions -- test]
2026/03/01 06:12:30 Claude output line: {"message":{"content":[{"text":"Response","type":"text"}],"usage":{"input_tokens":100,"output_tokens":50}},"session_id":"sess-last","type":"assistant"}
2026/03/01 06:12:30 Sent/edited with text content
2026/03/01 06:12:30 Sent initial message: $mock-1
2026/03/01 06:12:30 Claude output line: {"modelUsage":{"default":{"contextWindow":200000}},"result":"Response","session_id":"sess-last","type":"result"}
2026/03/01 06:12:30 Context saturation for room !test:example.com: 0% (0k / 200k tokens)
--- PASS: TestBridge_TypingIndicator_LastCallIsCancellation (0.05s)
=== RUN   TestBridge_TypingIndicator_NotStartedForExcludedRoom
2026/03/01 06:12:30 Event received: type=m.room.message sender=@alice:example.com room=!ops:example.com id=$evt-1770890460000000000 ts=1770890460000
2026/03/01 06:12:30 Ignoring message in excluded room !ops:example.com
--- PASS: TestBridge_TypingIndicator_NotStartedForExcludedRoom (0.10s)
=== RUN   TestBridge_TypingIndicator_NotStartedWhileDraining
2026/03/01 06:12:30 Event received: type=m.room.message sender=@alice:example.com room=!test:example.com id=$evt-1770890460000000000 ts=1770890460000
2026/03/01 06:12:30 Draining — ignoring message from @alice:example.com
--- PASS: TestBridge_TypingIndicator_NotStartedWhileDraining (0.10s)
=== RUN   TestBridge_StopEmoji_CancelsActiveInvocation
2026/03/01 06:12:30 Event received: type=m.room.message sender=@alice:example.com room=!test:example.com id=$evt-1770890460000000000 ts=1770890460000
2026/03/01 06:12:30 [!test:example.com] @alice:example.com: do something slow
2026/03/01 06:12:30 Invoking claude with args: [-p --output-format stream-json --verbose --dangerously-skip-permissions -- do something slow]
2026/03/01 06:12:30 Stop emoji received in room !test:example.com — cancelling active invocation
2026/03/01 06:12:31 Claude output line: {"message":{"content":[{"text":"This should be interrupted","type":"text"}],"usage":{"input_tokens":100,"output_tokens":50}},"session_id":"sess-stop","type":"assistant"}
2026/03/01 06:12:31 Sent/edited with text content
2026/03/01 06:12:31 Sent initial message: $mock-1
2026/03/01 06:12:31 Claude output line: {"modelUsage":{"default":{"contextWindow":200000}},"result":"This should be interrupted","session_id":"sess-stop","type":"result"}
2026/03/01 06:12:31 Invocation in room !test:example.com was stopped via emoji
2026/03/01 06:12:31 Captured interrupted context for room !test:example.com (1 sections, 26 chars)
--- PASS: TestBridge_StopEmoji_CancelsActiveInvocation (0.50s)
=== RUN   TestBridge_StopEmoji_NoActiveInvocation_FallsThrough
2026/03/01 06:12:31 Found pending approval for event $approval-stop-fallthrough
2026/03/01 06:12:31 Reaction received: 🛑 on $approval-stop-fallthrough
2026/03/01 06:12:31 Sending approval response to channel: deny
2026/03/01 06:12:31 Response sent to channel successfully
--- PASS: TestBridge_StopEmoji_NoActiveInvocation_FallsThrough (0.00s)
=== RUN   TestBridge_HandleMessage_AudioEchoesTranscript
2026/03/01 06:12:31 Event received: type=m.room.message sender=@alice:example.com room=!test:example.com id=$audio-echo-test ts=1770890460000
2026/03/01 06:12:31 Saved audio to /tmp/nix-shell.z0B0es/TestBridge_HandleMessage_AudioEchoesTranscript624851817/001/notes/attachments/2026-03-01_06-12-31_voice.ogg (15 bytes)
2026/03/01 06:12:31 Transcribing audio from /tmp/nix-shell.z0B0es/TestBridge_HandleMessage_AudioEchoesTranscript624851817/001/notes/attachments/2026-03-01_06-12-31_voice.ogg via http://127.0.0.1:44793
2026/03/01 06:12:31 [!test:example.com] @alice:example.com: [Transcribed from audio]

Hello from voice
2026/03/01 06:12:31 Invoking claude with args: [-p --output-format stream-json --verbose --dangerously-skip-permissions -- [Transcribed from audio]

Hello from voice]
2026/03/01 06:12:31 Claude output line: {"message":{"content":[{"text":"Got it!","type":"text"}],"usage":{"input_tokens":100,"output_tokens":50}},"session_id":"sess-stt","type":"assistant"}
2026/03/01 06:12:31 Sent/edited with text content
2026/03/01 06:12:31 Sent initial message: $mock-2
2026/03/01 06:12:31 Claude output line: {"modelUsage":{"default":{"contextWindow":200000}},"result":"Got it!","session_id":"sess-stt","type":"result"}
2026/03/01 06:12:31 Context saturation for room !test:example.com: 0% (0k / 200k tokens)
--- PASS: TestBridge_HandleMessage_AudioEchoesTranscript (0.00s)
=== RUN   TestGenerateHandoff_WritesFile
2026/03/01 06:12:31 Wrote handoff for room "test-room" to /tmp/nix-shell.z0B0es/TestGenerateHandoff_WritesFile1154192457/001/handoffs/test-room/2026-03-01_06-12-31.md (32 bytes)
--- PASS: TestGenerateHandoff_WritesFile (0.00s)
=== RUN   TestGenerateHandoff_EmptyResultErrors
--- PASS: TestGenerateHandoff_EmptyResultErrors (0.00s)
=== RUN   TestGenerateHandoff_ArgsCorrect
2026/03/01 06:12:31 Wrote handoff for room "test-room" to /tmp/nix-shell.z0B0es/TestGenerateHandoff_ArgsCorrect1675292649/001/handoffs/test-room/2026-03-01_06-12-31.md (15 bytes)
--- PASS: TestGenerateHandoff_ArgsCorrect (0.00s)
=== RUN   TestFormatRecentMessages_Empty
--- PASS: TestFormatRecentMessages_Empty (0.00s)
=== RUN   TestFormatRecentMessages_TextMessages
--- PASS: TestFormatRecentMessages_TextMessages (0.00s)
=== RUN   TestFormatRecentMessages_Limit
--- PASS: TestFormatRecentMessages_Limit (0.00s)
=== RUN   TestFormatRecentMessages_LongMessage
--- PASS: TestFormatRecentMessages_LongMessage (0.00s)
=== RUN   TestFormatRecentMessages_NonTextMessages
--- PASS: TestFormatRecentMessages_NonTextMessages (0.00s)
=== RUN   TestExtractLocalpart
--- PASS: TestExtractLocalpart (0.00s)
=== RUN   TestBuildResumeMessage_WithMessages
--- PASS: TestBuildResumeMessage_WithMessages (0.00s)
=== RUN   TestBuildResumeMessage_WithoutMessages
--- PASS: TestBuildResumeMessage_WithoutMessages (0.00s)
=== RUN   TestAudioExtFromMime
=== RUN   TestAudioExtFromMime/audio/mpeg
=== RUN   TestAudioExtFromMime/audio/wav
=== RUN   TestAudioExtFromMime/audio/ogg
=== RUN   TestAudioExtFromMime/audio/flac
=== RUN   TestAudioExtFromMime/audio/mp4
=== RUN   TestAudioExtFromMime/audio/aac
=== RUN   TestAudioExtFromMime/audio/opus
=== RUN   TestAudioExtFromMime/audio/webm
=== RUN   TestAudioExtFromMime/audio/unknown
=== RUN   TestAudioExtFromMime/#00
--- PASS: TestAudioExtFromMime (0.00s)
    --- PASS: TestAudioExtFromMime/audio/mpeg (0.00s)
    --- PASS: TestAudioExtFromMime/audio/wav (0.00s)
    --- PASS: TestAudioExtFromMime/audio/ogg (0.00s)
    --- PASS: TestAudioExtFromMime/audio/flac (0.00s)
    --- PASS: TestAudioExtFromMime/audio/mp4 (0.00s)
    --- PASS: TestAudioExtFromMime/audio/aac (0.00s)
    --- PASS: TestAudioExtFromMime/audio/opus (0.00s)
    --- PASS: TestAudioExtFromMime/audio/webm (0.00s)
    --- PASS: TestAudioExtFromMime/audio/unknown (0.00s)
    --- PASS: TestAudioExtFromMime/#00 (0.00s)
=== RUN   TestBridge_SendMessage
--- PASS: TestBridge_SendMessage (0.00s)
=== RUN   TestBridge_EditMessage
--- PASS: TestBridge_EditMessage (0.00s)
=== RUN   TestBridge_ContextPinLifecycle
2026/03/01 06:12:31 Created context pin $mock-1 in room !test:example.com at 60%
2026/03/01 06:12:31 Cleared context pin in room !test:example.com
--- PASS: TestBridge_ContextPinLifecycle (0.05s)
=== RUN   TestBridge_PinPermissionAlert
2026/03/01 06:12:31 Failed to pin context indicator in !test:example.com (need Moderator power level): M_FORBIDDEN: You don't have permission to send this state event
2026/03/01 06:12:31 Created context pin $mock-1 in room !test:example.com at 60%
--- PASS: TestBridge_PinPermissionAlert (0.05s)
=== RUN   TestBridge_HandleNewRoom
2026/03/01 06:12:31 Created room "my-project" (!new-room:example.com), invited @alice:example.com
--- PASS: TestBridge_HandleNewRoom (0.00s)
=== RUN   TestBridge_HandleInvite
2026/03/01 06:12:31 Invited to room !invited:example.com by @alice:example.com
2026/03/01 06:12:31 Joined room !invited:example.com
--- PASS: TestBridge_HandleInvite (0.00s)
=== RUN   TestBridge_HandleInvite_LowPowerNudge
2026/03/01 06:12:31 Invited to room !invited:example.com by @alice:example.com
2026/03/01 06:12:31 Joined room !invited:example.com
2026/03/01 06:12:31 Insufficient power level (0) in room !invited:example.com, sending nudge
--- PASS: TestBridge_HandleInvite_LowPowerNudge (0.00s)
=== RUN   TestSessionStore_BasicOperations
--- PASS: TestSessionStore_BasicOperations (0.05s)
=== RUN   TestSessionStore_LastMessage
--- PASS: TestSessionStore_LastMessage (0.05s)
=== RUN   TestSessionStore_Invocation
--- PASS: TestSessionStore_Invocation (0.05s)
=== RUN   TestSessionStore_Saturation
--- PASS: TestSessionStore_Saturation (0.00s)
=== RUN   TestSessionStore_Turns
--- PASS: TestSessionStore_Turns (0.00s)
=== RUN   TestSessionStore_PinnedEvent
--- PASS: TestSessionStore_PinnedEvent (0.05s)
=== RUN   TestSessionStore_Persistence
--- PASS: TestSessionStore_Persistence (0.10s)
=== RUN   TestSessionStore_OldFormatMigration
--- PASS: TestSessionStore_OldFormatMigration (0.00s)
=== RUN   TestSessionStore_InterruptedContext
--- PASS: TestSessionStore_InterruptedContext (0.05s)
=== RUN   TestSessionStore_InterruptedContextPersistsAcrossReload
--- PASS: TestSessionStore_InterruptedContextPersistsAcrossReload (0.10s)
=== RUN   TestBridge_SocketApproval_RoundTrip
2026/03/01 06:12:31 Approval request: session=sess-socket tool=Bash
2026/03/01 06:12:31 Waiting for reaction on event $mock-1
2026/03/01 06:12:31 Found pending approval for event $mock-1
2026/03/01 06:12:31 Reaction received: 👍 on $mock-1
2026/03/01 06:12:31 Sending approval response to channel: allow
2026/03/01 06:12:31 Response sent to channel successfully
2026/03/01 06:12:31 Received response from channel: allow
2026/03/01 06:12:31 Approval response: decision=allow message=
--- PASS: TestBridge_SocketApproval_RoundTrip (0.10s)
=== RUN   TestBridge_SocketApproval_AutoApproveBypass
2026/03/01 06:12:31 Approval request: session=sess-auto tool=Read
2026/03/01 06:12:31 Auto-allow: Read (matched rule)
2026/03/01 06:12:31 Approval response: decision=allow message=
--- PASS: TestBridge_SocketApproval_AutoApproveBypass (0.00s)
=== RUN   TestBridge_SocketConnection_InvalidJSON
2026/03/01 06:12:31 Failed to decode socket request: invalid character 'o' in literal null (expecting 'u')
--- PASS: TestBridge_SocketConnection_InvalidJSON (0.00s)
=== RUN   TestBridge_SocketConnection_UnknownType
2026/03/01 06:12:31 Unknown socket request type: bogus
--- PASS: TestBridge_SocketConnection_UnknownType (0.00s)
=== RUN   TestBridge_SocketResume_RejectedWhileDraining
2026/03/01 06:12:31 Resume request rejected — bridge is draining
--- PASS: TestBridge_SocketResume_RejectedWhileDraining (0.00s)
=== RUN   TestCheckResumeBreadcrumb_NoBreadcrumb
--- PASS: TestCheckResumeBreadcrumb_NoBreadcrumb (0.00s)
=== RUN   TestCheckResumeBreadcrumb_EmptyFile
2026/03/01 06:12:31 Resume breadcrumb was empty, ignoring
--- PASS: TestCheckResumeBreadcrumb_EmptyFile (0.00s)
=== RUN   TestCheckResumeBreadcrumb_RoomIDOnly
2026/03/01 06:12:31 Found resume breadcrumb for room !infra:matrix.example.com — triggering resume
2026/03/01 06:12:31 Invoking claude with args: [-p --output-format stream-json --verbose --dangerously-skip-permissions -- <system-reminder>IMPORTANT: The cranium bridge was restarted. The world may have changed while you were away — tasks you initiated (including ko build pipelines) may have completed. Before continuing, reorient: check whether your in-flight work already landed. Do not assume the state is the same as when you last acted.</system-reminder>]
2026/03/01 06:12:31 Claude output line: {"message":{"content":[{"text":"Resumed successfully!","type":"text"}],"usage":{"input_tokens":100,"output_tokens":50}},"session_id":"sess-resume","type":"assistant"}
2026/03/01 06:12:31 Sent/edited with text content
2026/03/01 06:12:31 Sent initial message: $mock-1
2026/03/01 06:12:31 Claude output line: {"modelUsage":{"default":{"contextWindow":200000}},"result":"Resumed successfully!","session_id":"sess-resume","type":"result"}
2026/03/01 06:12:31 Resume invoke complete for room !infra:matrix.example.com
--- PASS: TestCheckResumeBreadcrumb_RoomIDOnly (0.20s)
=== RUN   TestCheckResumeBreadcrumb_WithCustomMessage
2026/03/01 06:12:31 Found resume breadcrumb for room !infra:matrix.example.com — triggering resume
2026/03/01 06:12:31 Invoking claude with args: [-p --output-format stream-json --verbose --dangerously-skip-permissions -- <system-reminder>Custom upgrade message</system-reminder>]
2026/03/01 06:12:31 Claude output line: {"message":{"content":[{"text":"Back online!","type":"text"}],"usage":{"input_tokens":100,"output_tokens":50}},"session_id":"sess-resume2","type":"assistant"}
2026/03/01 06:12:31 Sent/edited with text content
2026/03/01 06:12:31 Sent initial message: $mock-1
2026/03/01 06:12:31 Claude output line: {"modelUsage":{"default":{"contextWindow":200000}},"result":"Back online!","session_id":"sess-resume2","type":"result"}
2026/03/01 06:12:31 Resume invoke complete for room !infra:matrix.example.com
--- PASS: TestCheckResumeBreadcrumb_WithCustomMessage (0.20s)
=== RUN   TestCheckResumeBreadcrumb_SetsSessionID
2026/03/01 06:12:32 Found resume breadcrumb for room !infra:matrix.example.com — triggering resume
2026/03/01 06:12:32 Invoking claude with args: [-p --output-format stream-json --verbose --dangerously-skip-permissions -- <system-reminder>IMPORTANT: The cranium bridge was restarted. The world may have changed while you were away — tasks you initiated (including ko build pipelines) may have completed. Before continuing, reorient: check whether your in-flight work already landed. Do not assume the state is the same as when you last acted.</system-reminder>]
2026/03/01 06:12:32 Claude output line: {"message":{"content":[{"text":"Ready!","type":"text"}],"usage":{"input_tokens":100,"output_tokens":50}},"session_id":"sess-new-resume","type":"assistant"}
2026/03/01 06:12:32 Sent/edited with text content
2026/03/01 06:12:32 Sent initial message: $mock-1
2026/03/01 06:12:32 Claude output line: {"modelUsage":{"default":{"contextWindow":200000}},"result":"Ready!","session_id":"sess-new-resume","type":"result"}
2026/03/01 06:12:32 Resume invoke complete for room !infra:matrix.example.com
--- PASS: TestCheckResumeBreadcrumb_SetsSessionID (0.20s)
=== RUN   TestCheckResumeBreadcrumb_SendsResponse
2026/03/01 06:12:32 Found resume breadcrumb for room !infra:matrix.example.com — triggering resume
2026/03/01 06:12:32 Invoking claude with args: [-p --output-format stream-json --verbose --dangerously-skip-permissions -- <system-reminder>IMPORTANT: The cranium bridge was restarted. The world may have changed while you were away — tasks you initiated (including ko build pipelines) may have completed. Before continuing, reorient: check whether your in-flight work already landed. Do not assume the state is the same as when you last acted.</system-reminder>]
2026/03/01 06:12:32 Claude output line: {"message":{"content":[{"text":"I'm back and ready!","type":"text"}],"usage":{"input_tokens":100,"output_tokens":50}},"session_id":"sess-resp","type":"assistant"}
2026/03/01 06:12:32 Sent/edited with text content
2026/03/01 06:12:32 Sent initial message: $mock-1
2026/03/01 06:12:32 Claude output line: {"modelUsage":{"default":{"contextWindow":200000}},"result":"I'm back and ready!","session_id":"sess-resp","type":"result"}
2026/03/01 06:12:32 Resume invoke complete for room !infra:matrix.example.com
--- PASS: TestCheckResumeBreadcrumb_SendsResponse (0.20s)
=== RUN   TestCheckResumeBreadcrumb_CleansUpStaleIndicator
2026/03/01 06:12:32 Found resume breadcrumb for room !infra:matrix.example.com — triggering resume
2026/03/01 06:12:32 Cleaning up stale working indicator on event $stale-evt-123
2026/03/01 06:12:32 Invoking claude with args: [-p --output-format stream-json --verbose --dangerously-skip-permissions -- <system-reminder>IMPORTANT: The cranium bridge was restarted. The world may have changed while you were away — tasks you initiated (including ko build pipelines) may have completed. Before continuing, reorient: check whether your in-flight work already landed. Do not assume the state is the same as when you last acted.</system-reminder>]
2026/03/01 06:12:32 Claude output line: {"message":{"content":[{"text":"Resumed!","type":"text"}],"usage":{"input_tokens":100,"output_tokens":50}},"session_id":"sess-cleanup","type":"assistant"}
2026/03/01 06:12:32 Sent/edited with text content
2026/03/01 06:12:32 Sent initial message: $mock-2
2026/03/01 06:12:32 Claude output line: {"modelUsage":{"default":{"contextWindow":200000}},"result":"Resumed!","session_id":"sess-cleanup","type":"result"}
2026/03/01 06:12:32 Resume invoke complete for room !infra:matrix.example.com
--- PASS: TestCheckResumeBreadcrumb_CleansUpStaleIndicator (0.20s)
=== RUN   TestCheckResumeBreadcrumb_SkipsWhenRoomActive
2026/03/01 06:12:32 Found resume breadcrumb for room !infra:matrix.example.com — triggering resume
2026/03/01 06:12:32 Room !infra:matrix.example.com already has active invocation, skipping resume
--- PASS: TestCheckResumeBreadcrumb_SkipsWhenRoomActive (0.20s)
=== RUN   TestMimeFromExtension
--- PASS: TestMimeFromExtension (0.00s)
=== RUN   TestBridge_PostImage_Success
2026/03/01 06:12:32 Posted image test-image.png to room nerve (!nerve:matrix.example.com): event $mock-1
--- PASS: TestBridge_PostImage_Success (0.00s)
=== RUN   TestBridge_PostImage_MissingRoom
2026/03/01 06:12:32 Post image request missing room name
--- PASS: TestBridge_PostImage_MissingRoom (0.00s)
=== RUN   TestBridge_PostImage_MissingPath
2026/03/01 06:12:32 Post image request missing file path
--- PASS: TestBridge_PostImage_MissingPath (0.00s)
=== RUN   TestBridge_PostImage_UnsupportedFormat
2026/03/01 06:12:32 Post image: unsupported format ".pdf"
--- PASS: TestBridge_PostImage_UnsupportedFormat (0.00s)
=== RUN   TestBridge_PostImage_RoomNotFound
2026/03/01 06:12:32 Post image: room "nonexistent" not found
--- PASS: TestBridge_PostImage_RoomNotFound (0.00s)
=== RUN   TestBridge_PostImage_FileNotFound
2026/03/01 06:12:32 Post image: failed to read file /tmp/no-such-file-29387.png: open /tmp/no-such-file-29387.png: no such file or directory
--- PASS: TestBridge_PostImage_FileNotFound (0.00s)
=== RUN   TestBridge_PostAudio_Success
2026/03/01 06:12:32 Posted audio test-audio.mp3 to room nerve (!nerve:matrix.example.com): event $mock-1
--- PASS: TestBridge_PostAudio_Success (0.00s)
=== RUN   TestBridge_PostAudio_MissingRoom
2026/03/01 06:12:32 Post audio request missing room name
--- PASS: TestBridge_PostAudio_MissingRoom (0.00s)
=== RUN   TestBridge_PostAudio_MissingPath
2026/03/01 06:12:32 Post audio request missing file path
--- PASS: TestBridge_PostAudio_MissingPath (0.00s)
=== RUN   TestBridge_PostAudio_UnsupportedFormat
2026/03/01 06:12:32 Post audio: unsupported format ".pdf"
--- PASS: TestBridge_PostAudio_UnsupportedFormat (0.00s)
=== RUN   TestBridge_PostAudio_RoomNotFound
2026/03/01 06:12:32 Post audio: room "nonexistent" not found
--- PASS: TestBridge_PostAudio_RoomNotFound (0.00s)
=== RUN   TestBridge_PostAudio_FileNotFound
2026/03/01 06:12:32 Post audio: failed to read file /tmp/no-such-file-29387.mp3: open /tmp/no-such-file-29387.mp3: no such file or directory
--- PASS: TestBridge_PostAudio_FileNotFound (0.00s)
=== RUN   TestShouldGenerateSummary
=== RUN   TestShouldGenerateSummary/turns=9_threshold=10
=== RUN   TestShouldGenerateSummary/turns=10_threshold=10
=== RUN   TestShouldGenerateSummary/turns=11_threshold=10
=== RUN   TestShouldGenerateSummary/turns=0_threshold=10
=== RUN   TestShouldGenerateSummary/turns=5_threshold=5
--- PASS: TestShouldGenerateSummary (0.00s)
    --- PASS: TestShouldGenerateSummary/turns=9_threshold=10 (0.00s)
    --- PASS: TestShouldGenerateSummary/turns=10_threshold=10 (0.00s)
    --- PASS: TestShouldGenerateSummary/turns=11_threshold=10 (0.00s)
    --- PASS: TestShouldGenerateSummary/turns=0_threshold=10 (0.00s)
    --- PASS: TestShouldGenerateSummary/turns=5_threshold=5 (0.00s)
=== RUN   TestDetectCompaction
=== RUN   TestDetectCompaction/large_drop_with_pin_—_compaction
=== RUN   TestDetectCompaction/large_drop_without_pin_—_no_compaction
=== RUN   TestDetectCompaction/small_drop_with_pin_—_no_compaction_(hysteresis)
=== RUN   TestDetectCompaction/at_60_with_pin_—_no_compaction
=== RUN   TestDetectCompaction/above_60_with_pin_—_no_compaction
=== RUN   TestDetectCompaction/exactly_10_point_drop_below_60_—_no_compaction_(boundary)
=== RUN   TestDetectCompaction/11_point_drop_below_60_—_compaction
=== RUN   TestDetectCompaction/drop_to_0_from_high_—_compaction
--- PASS: TestDetectCompaction (0.00s)
    --- PASS: TestDetectCompaction/large_drop_with_pin_—_compaction (0.00s)
    --- PASS: TestDetectCompaction/large_drop_without_pin_—_no_compaction (0.00s)
    --- PASS: TestDetectCompaction/small_drop_with_pin_—_no_compaction_(hysteresis) (0.00s)
    --- PASS: TestDetectCompaction/at_60_with_pin_—_no_compaction (0.00s)
    --- PASS: TestDetectCompaction/above_60_with_pin_—_no_compaction (0.00s)
    --- PASS: TestDetectCompaction/exactly_10_point_drop_below_60_—_no_compaction_(boundary) (0.00s)
    --- PASS: TestDetectCompaction/11_point_drop_below_60_—_compaction (0.00s)
    --- PASS: TestDetectCompaction/drop_to_0_from_high_—_compaction (0.00s)
=== RUN   TestFilterAndFormatSummaries
--- PASS: TestFilterAndFormatSummaries (0.00s)
=== RUN   TestDeriveSlug
=== RUN   TestDeriveSlug/normal_room
=== RUN   TestDeriveSlug/room_with_spaces
=== RUN   TestDeriveSlug/empty_name_uses_room_ID
=== RUN   TestDeriveSlug/empty_name_truncates_long_ID
--- PASS: TestDeriveSlug (0.00s)
    --- PASS: TestDeriveSlug/normal_room (0.00s)
    --- PASS: TestDeriveSlug/room_with_spaces (0.00s)
    --- PASS: TestDeriveSlug/empty_name_uses_room_ID (0.00s)
    --- PASS: TestDeriveSlug/empty_name_truncates_long_ID (0.00s)
=== RUN   TestGenerateSummary_WritesSummaryFile
2026/03/01 06:12:32 Generated summary for room "test-room" (75 bytes)
--- PASS: TestGenerateSummary_WritesSummaryFile (0.00s)
=== RUN   TestGenerateSummary_ResetsTurns
2026/03/01 06:12:32 Generated summary for room "test-room" (12 bytes)
--- PASS: TestGenerateSummary_ResetsTurns (0.00s)
=== RUN   TestGenerateSummary_ForkSessionArgs
2026/03/01 06:12:32 Generated summary for room "test-room" (7 bytes)
--- PASS: TestGenerateSummary_ForkSessionArgs (0.00s)
=== RUN   TestGenerateSummary_NoSessionSkips
2026/03/01 06:12:32 No session for room !test:example.com, skipping summary generation
--- PASS: TestGenerateSummary_NoSessionSkips (0.00s)
PASS
ok  	github.com/gisikw/cranium	3.869s
?   	github.com/gisikw/cranium/cmd/crn-breadcrumb	[no test files]
?   	github.com/gisikw/cranium/cmd/crn-post-audio	[no test files]
?   	github.com/gisikw/cranium/cmd/crn-post-image	[no test files]
