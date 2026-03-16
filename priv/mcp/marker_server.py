#!/usr/bin/env python3
"""
Minimal MCP stdio server exposing cranium marker tools.

Tools: show, show_code, play_audio

All tool calls return {"success": true}. Cranium detects marker calls
by parsing CC's stream-json output; this server just needs to exist
so CC knows the tools are available.
"""

import json
import sys

TOOLS = [
    {
        "name": "show",
        "description": "Display an image or media item inline in the conversation.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "url": {"type": "string", "description": "URL or path to the media item"}
            }
        }
    },
    {
        "name": "show_code",
        "description": "Display a code block with syntax highlighting.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "code": {"type": "string", "description": "The code to display"},
                "language": {"type": "string", "description": "Programming language for highlighting"}
            }
        }
    },
    {
        "name": "play_audio",
        "description": "Play an audio clip inline in the conversation.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "url": {"type": "string", "description": "URL or path to the audio file"}
            }
        }
    }
]

SERVER_INFO = {
    "name": "cranium-markers",
    "version": "1.0.0"
}


def handle_request(request):
    method = request.get("method", "")

    if method == "initialize":
        return {
            "protocolVersion": "2024-11-05",
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": SERVER_INFO
        }

    if method == "tools/list":
        return {"tools": TOOLS}

    if method == "tools/call":
        return {"content": [{"type": "text", "text": json.dumps({"success": True})}]}

    # Notifications (initialized, etc.) — no response needed
    if "id" not in request:
        return None

    return {"error": {"code": -32601, "message": f"Method not found: {method}"}}


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

        try:
            request = json.loads(line)
        except json.JSONDecodeError:
            continue

        result = handle_request(request)

        # Notifications don't get responses
        if result is None:
            continue

        response = {"jsonrpc": "2.0", "id": request.get("id"), "result": result}

        # If it's an error response, restructure
        if "error" in result:
            response = {"jsonrpc": "2.0", "id": request.get("id"), "error": result["error"]}

        sys.stdout.write(json.dumps(response) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
