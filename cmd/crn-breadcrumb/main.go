package main

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
)

// Usage: crn-breadcrumb <room-id>
// Requests an enriched resume breadcrumb message from cranium.

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintf(os.Stderr, "Usage: %s <room-id>\n", os.Args[0])
		os.Exit(1)
	}

	roomID := os.Args[1]
	socketPath := os.Getenv("CRANIUM_SOCKET")
	if socketPath == "" {
		socketPath = "/tmp/cranium.sock"
	}

	conn, err := net.Dial("unix", socketPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to connect to cranium socket: %v\n", err)
		os.Exit(1)
	}
	defer conn.Close()

	req := map[string]string{
		"type":    "breadcrumb",
		"room_id": roomID,
	}

	if err := json.NewEncoder(conn).Encode(req); err != nil {
		fmt.Fprintf(os.Stderr, "Failed to send request: %v\n", err)
		os.Exit(1)
	}

	var resp struct {
		Status  string `json:"status"`
		Message string `json:"message"`
		Error   string `json:"error,omitempty"`
	}
	if err := json.NewDecoder(conn).Decode(&resp); err != nil {
		fmt.Fprintf(os.Stderr, "Failed to decode response: %v\n", err)
		os.Exit(1)
	}

	if resp.Error != "" {
		fmt.Fprintf(os.Stderr, "Cranium returned error: %s\n", resp.Error)
		os.Exit(1)
	}

	if resp.Status != "ok" {
		fmt.Fprintf(os.Stderr, "Unexpected status: %s\n", resp.Status)
		os.Exit(1)
	}

	fmt.Print(resp.Message)
}
