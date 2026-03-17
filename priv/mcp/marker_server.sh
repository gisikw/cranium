#!/usr/bin/env bash
#
# Minimal MCP stdio server exposing cranium marker tools.
#
# Tools: show, show_code, play_audio
#
# All tool calls return {"success": true}. Cranium detects marker calls
# by parsing CC's stream-json output; this server just needs to exist
# so CC knows the tools are available.
#
# Replaces marker_server.py — no python3 dependency.

set -euo pipefail

TOOLS='[{"name":"show","description":"Display an image or media item inline in the conversation.","inputSchema":{"type":"object","properties":{"url":{"type":"string","description":"URL or path to the media item"}}}},{"name":"show_code","description":"Display a code block with syntax highlighting.","inputSchema":{"type":"object","properties":{"code":{"type":"string","description":"The code to display"},"language":{"type":"string","description":"Programming language for highlighting"}}}},{"name":"play_audio","description":"Play an audio clip inline in the conversation.","inputSchema":{"type":"object","properties":{"url":{"type":"string","description":"URL or path to the audio file"}}}}]'

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
