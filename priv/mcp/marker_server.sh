#!/usr/bin/env bash
#
# Minimal MCP stdio server exposing cranium marker and meta-tools.
#
# Tools: show, show_code, play_audio, clear_context
#
# All tool calls return {"success": true}. Cranium detects calls
# by parsing CC's stream-json output; this server just needs to exist
# so CC knows the tools are available.
#
# Replaces marker_server.py — no python3 dependency.

set -euo pipefail

TOOLS='[
  {"name":"show","description":"Display an image or media item inline in the conversation.","inputSchema":{"type":"object","properties":{"url":{"type":"string","description":"URL or path to the media item"}}}},
  {"name":"show_code","description":"Display a code block with syntax highlighting.","inputSchema":{"type":"object","properties":{"code":{"type":"string","description":"The code to display"},"language":{"type":"string","description":"Programming language for highlighting"}}}},
  {"name":"play_audio","description":"Play an audio clip inline in the conversation.","inputSchema":{"type":"object","properties":{"url":{"type":"string","description":"URL or path to the audio file"}}}},
  {"name":"clear_context","description":"Clear the current context and start a fresh epoch. Use when context is getting full or you want to reset conversation state. A handoff document will be generated to preserve important context. If you provide a continuation, that instruction executes automatically after handoff completes.","inputSchema":{"type":"object","properties":{"continuation":{"type":"string","description":"Optional instruction to execute after context is cleared and handoff completes. Keep this BRIEF (1-2 sentences) — a detailed handoff document from the outgoing session is automatically injected into the new session, so do NOT repeat conversation context here. Use this only to guide the resumption tone or next action (e.g., 'continue the conversation' or 'pick up where we left off on the work topic')."}}}}
]'

while IFS= read -r line; do
  [ -z "$line" ] && continue

  method=$(echo "$line" | jq -r '.method // empty' 2>/dev/null) || continue
  id=$(echo "$line" | jq '.id // empty' 2>/dev/null) || continue

  # Notifications (no id) don't get responses
  [ -z "$id" ] && continue

  case "$method" in
    initialize)
      jq -nc --argjson id "$id" '{jsonrpc:"2.0",id:$id,result:{protocolVersion:"2024-11-05",capabilities:{tools:{listChanged:false}},serverInfo:{name:"cranium-markers",version:"1.0.0"}}}'
      ;;
    tools/list)
      jq -nc --argjson id "$id" --argjson tools "$TOOLS" '{jsonrpc:"2.0",id:$id,result:{tools:$tools}}'
      ;;
    tools/call)
      jq -nc --argjson id "$id" '{jsonrpc:"2.0",id:$id,result:{content:[{type:"text",text:"{\"success\":true}"}]}}'
      ;;
    *)
      jq -nc --argjson id "$id" --arg method "$method" '{jsonrpc:"2.0",id:$id,error:{code:-32601,message:("Method not found: "+$method)}}'
      ;;
  esac
done
