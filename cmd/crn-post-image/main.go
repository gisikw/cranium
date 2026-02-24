package main

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
)

// Usage: crn-post-image <room-name> <image-path>

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintf(os.Stderr, "Usage: %s <room-name> <image-path>\n", os.Args[0])
		os.Exit(1)
	}

	room := os.Args[1]
	path := os.Args[2]
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
		"type": "post_image",
		"room": room,
		"path": path,
	}

	if err := json.NewEncoder(conn).Encode(req); err != nil {
		fmt.Fprintf(os.Stderr, "Failed to send request: %v\n", err)
		os.Exit(1)
	}

	var resp struct {
		Status  string `json:"status"`
		EventID string `json:"event_id,omitempty"`
		Error   string `json:"error,omitempty"`
	}
	if err := json.NewDecoder(conn).Decode(&resp); err != nil {
		fmt.Fprintf(os.Stderr, "Failed to decode response: %v\n", err)
		os.Exit(1)
	}

	if resp.Error != "" {
		fmt.Fprintf(os.Stderr, "Error: %s\n", resp.Error)
		os.Exit(1)
	}

	if resp.Status != "ok" {
		fmt.Fprintf(os.Stderr, "Unexpected status: %s\n", resp.Status)
		os.Exit(1)
	}

	fmt.Printf("Image posted: %s\n", resp.EventID)
}
