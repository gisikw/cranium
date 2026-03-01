package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	_ "github.com/mattn/go-sqlite3"
	"maunium.net/go/mautrix"
	"maunium.net/go/mautrix/crypto/cryptohelper"
	"maunium.net/go/mautrix/event"
)

// Set via ldflags at build time
var version = "dev"

func main() {
	// Load cranium config
	configPath := os.Getenv("CRANIUM_CONFIG")
	if configPath == "" {
		configPath = "cranium.yaml"
	}
	craniumCfg, err := LoadCraniumConfig(configPath)
	if err != nil {
		log.Fatalf("Failed to load cranium config: %v", err)
	}

	// Load identity config
	identityCfg, err := LoadIdentityConfig(craniumCfg.IdentityFile)
	if err != nil {
		log.Fatalf("Failed to load identity config: %v", err)
	}

	log.Printf("Using data directory: %s", identityCfg.DataDir)

	// Load password
	passwordBytes, err := os.ReadFile(craniumCfg.Matrix.PasswordFile)
	if err != nil {
		log.Fatalf("Failed to read password file: %v", err)
	}
	password := strings.TrimSpace(string(passwordBytes))

	// Load system prompt content
	var systemPromptContent string
	if data, err := os.ReadFile(identityCfg.SystemPromptFile); err == nil && len(data) > 0 {
		systemPromptContent = string(data)
	} else if err != nil {
		log.Printf("Warning: could not read system prompt file at %s: %v", identityCfg.SystemPromptFile, err)
	}

	// Initialize session store
	sessionsPath := filepath.Join(identityCfg.DataDir, ".cranium-sessions.json")
	sessions := NewSessionStore(sessionsPath, time.Now)

	// Create Matrix client
	client, err := mautrix.NewClient(craniumCfg.Matrix.Homeserver, "", "")
	if err != nil {
		log.Fatalf("Failed to create client: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Set up crypto helper (handles login and E2EE)
	log.Printf("Logging in as %s...", craniumCfg.Matrix.Username)
	cryptoHelper, err := cryptohelper.NewCryptoHelper(client, []byte(password),
		filepath.Join(identityCfg.DataDir, ".cranium-crypto.db"))
	if err != nil {
		log.Fatalf("Failed to create crypto helper: %v", err)
	}
	cryptoHelper.LoginAs = &mautrix.ReqLogin{
		Type: mautrix.AuthTypePassword,
		Identifier: mautrix.UserIdentifier{
			Type: mautrix.IdentifierTypeUser,
			User: craniumCfg.Matrix.Username,
		},
		Password: password,
	}
	if err := cryptoHelper.Init(ctx); err != nil {
		log.Fatalf("Failed to init crypto: %v", err)
	}
	client.Crypto = cryptoHelper
	log.Printf("Logged in as %s (device %s, E2EE enabled)", client.UserID, client.DeviceID)

	// Build exclude list: ops room + configured exclude patterns
	excludeRooms := append([]string{craniumCfg.OpsRoom}, craniumCfg.ExcludeRooms...)

	// Create bridge
	bridge := NewBridge(client, sessions, identityCfg.DataDir, BridgeConfig{
		DisplayName:      identityCfg.DisplayName,
		AttachmentsDir:   identityCfg.AttachmentsDir,
		ProjectsDir:      identityCfg.ProjectsDir,
		SummaryThreshold: identityCfg.SummaryTurnThreshold,
		ExcludeRooms:     excludeRooms,
		SocketPath:       craniumCfg.SocketPath,
		STTURL:           craniumCfg.STTURL,
	})
	bridge.userID = client.UserID
	bridge.systemPromptContent = systemPromptContent

	// Find ops room for announcements
	bridge.opsRoomID = bridge.findRoomByName(ctx, craniumCfg.OpsRoom)
	if bridge.opsRoomID != "" {
		log.Printf("Found ops room: %s", bridge.opsRoomID)
	} else {
		log.Printf("No ops room found — startup/drain announcements disabled")
	}

	// Start eviction loop for seenEvents and deniedCache
	evictionDone := make(chan struct{})
	bridge.startEvictionLoop(evictionDone)
	defer close(evictionDone)

	// Set up event handlers
	syncer := client.Syncer.(*mautrix.DefaultSyncer)

	// Debug: log ALL events
	syncer.OnEvent(func(ctx context.Context, evt *event.Event) {
		log.Printf("DEBUG: Event type=%s class=%d room=%s sender=%s",
			evt.Type.String(), evt.Type.Class, evt.RoomID, evt.Sender)
	})

	syncer.OnEventType(event.EventMessage, func(ctx context.Context, evt *event.Event) {
		// Run in goroutine so we don't block the syncer
		// (handleMessage waits for Claude, which may wait for reactions)
		go bridge.handleMessage(ctx, evt)
	})

	syncer.OnEventType(event.StateMember, func(ctx context.Context, evt *event.Event) {
		if evt.GetStateKey() == string(client.UserID) {
			content, ok := evt.Content.Parsed.(*event.MemberEventContent)
			if ok && content.Membership == event.MembershipInvite {
				bridge.handleInvite(ctx, evt)
			}
		}
	})

	syncer.OnEventType(event.EventReaction, func(ctx context.Context, evt *event.Event) {
		bridge.handleReaction(ctx, evt)
	})

	// Start socket listener for hook requests
	if err := bridge.startSocketListener(ctx); err != nil {
		log.Fatalf("Failed to start socket listener: %v", err)
	}

	// Handle shutdown and drain signals
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM, syscall.SIGUSR1)

	go func() {
		for sig := range sigChan {
			if sig == syscall.SIGUSR1 {
				// Graceful drain: stop accepting new work, wait for active invocations
				log.Println("SIGUSR1 received — draining...")
				bridge.draining.Store(true)
				bridge.announceDrain(ctx)

				// Wait for active invocations to finish. If only 1 remains,
				// it's the session that triggered the upgrade — safe to exit.
				deadline := time.After(30 * time.Second)
				for {
					remaining := bridge.activeRoomCount()
					if remaining <= 1 {
						log.Printf("Drain complete (%d remaining — upgrade initiator at most)", remaining)
						break
					}
					select {
					case <-deadline:
						log.Printf("Drain timeout (30s) — %d rooms still active, exiting anyway", remaining)
						goto drainDone
					case <-time.After(250 * time.Millisecond):
						// poll again
					}
				}
			drainDone:

				client.StopSync()
				cancel()
				return
			}
			// SIGINT/SIGTERM: immediate shutdown
			log.Println("Shutting down...")
			client.StopSync()
			cancel()
			return
		}
	}()

	// Start syncing with fast poll (2s timeout instead of mautrix default 30s).
	// On the same box as the homeserver, 30s long-poll adds up to 30s message latency.
	log.Printf("Starting sync (version %s)...", version)

	// Announce startup after sync is established (slight delay for sync to catch up)
	// Also check for a resume breadcrumb left by the upgrade script.
	go func() {
		time.Sleep(3 * time.Second)
		bridge.announceStartup(ctx)
		bridge.checkResumeBreadcrumb(ctx)
	}()

	if err := fastSync(ctx, client, 2000); err != nil && ctx.Err() == nil {
		log.Fatalf("Sync error: %v", err)
	}
	if err := cryptoHelper.Close(); err != nil {
		log.Printf("Error closing crypto helper: %v", err)
	}
	log.Println("Sync stopped, exiting")
}
