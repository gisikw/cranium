package main

import (
	"context"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"

	"strings"
	"sync"
	"sync/atomic"
	"time"

	"maunium.net/go/mautrix"
	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
)

// MatrixClient abstracts the subset of mautrix.Client that Bridge uses.
// Production code passes the real *mautrix.Client; tests use a recording stub.
type MatrixClient interface {
	JoinedRooms(ctx context.Context) (resp *mautrix.RespJoinedRooms, err error)
	UserTyping(ctx context.Context, roomID id.RoomID, typing bool, timeout time.Duration) (resp *mautrix.RespTyping, err error)
	MarkRead(ctx context.Context, roomID id.RoomID, eventID id.EventID) error
	StateEvent(ctx context.Context, roomID id.RoomID, eventType event.Type, stateKey string, outContent interface{}) error
	SendMessageEvent(ctx context.Context, roomID id.RoomID, eventType event.Type, contentJSON interface{}, extra ...mautrix.ReqSendEvent) (resp *mautrix.RespSendEvent, err error)
	SendStateEvent(ctx context.Context, roomID id.RoomID, eventType event.Type, stateKey string, contentJSON any, extra ...mautrix.ReqSendEvent) (resp *mautrix.RespSendEvent, err error)
	RedactEvent(ctx context.Context, roomID id.RoomID, eventID id.EventID, extra ...mautrix.ReqRedact) (resp *mautrix.RespSendEvent, err error)
	DownloadBytes(ctx context.Context, mxcURL id.ContentURI) ([]byte, error)
	UploadBytesWithName(ctx context.Context, data []byte, contentType, fileName string) (*mautrix.RespMediaUpload, error)
	CreateRoom(ctx context.Context, req *mautrix.ReqCreateRoom) (resp *mautrix.RespCreateRoom, err error)
	JoinRoomByID(ctx context.Context, roomID id.RoomID) (resp *mautrix.RespJoinRoom, err error)
	SendText(ctx context.Context, roomID id.RoomID, text string) (*mautrix.RespSendEvent, error)
	Messages(ctx context.Context, roomID id.RoomID, from string, to string, dir mautrix.Direction, filter *mautrix.FilterPart, limit int) (*mautrix.RespMessages, error)
}

// ClaudeProcess represents a running Claude CLI process.
// Callers read stdout for stream-json output, read stderr for diagnostics,
// and call Wait to block until the process exits.
type ClaudeProcess interface {
	Stdout() io.ReadCloser
	Stderr() io.ReadCloser
	Wait() error
}

// ClaudeInvoker abstracts the Claude CLI invocation.
// Production code uses execClaudeInvoker; tests use mockClaudeInvoker.
type ClaudeInvoker interface {
	Start(ctx context.Context, args []string, dir string, env []string) (ClaudeProcess, error)
}

// execClaudeProcess wraps a real exec.Cmd.
type execClaudeProcess struct {
	cmd    *exec.Cmd
	stdout io.ReadCloser
	stderr io.ReadCloser
}

func (p *execClaudeProcess) Stdout() io.ReadCloser { return p.stdout }
func (p *execClaudeProcess) Stderr() io.ReadCloser { return p.stderr }
func (p *execClaudeProcess) Wait() error           { return p.cmd.Wait() }

// execClaudeInvoker is the production implementation that shells out to claude.
type execClaudeInvoker struct{}

func (e *execClaudeInvoker) Start(ctx context.Context, args []string, dir string, env []string) (ClaudeProcess, error) {
	cmd := exec.CommandContext(ctx, "claude", args...)
	cmd.Dir = dir
	if len(env) > 0 {
		cmd.Env = append(os.Environ(), env...)
	}

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, fmt.Errorf("stdout pipe: %w", err)
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return nil, fmt.Errorf("stderr pipe: %w", err)
	}

	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("start claude: %w", err)
	}

	return &execClaudeProcess{cmd: cmd, stdout: stdout, stderr: stderr}, nil
}

// ContextInfo holds context window saturation data from a Claude invocation
type ContextInfo struct {
	UsedTokens    int
	ContextWindow int
}

// Saturation returns the context usage as a percentage (0-100)
func (ci ContextInfo) Saturation() int {
	if ci.ContextWindow == 0 {
		return 0
	}
	return int(float64(ci.UsedTokens) / float64(ci.ContextWindow) * 100)
}

// Bridge handles the Matrix-Claude integration
type Bridge struct {
	client           MatrixClient
	claude           ClaudeInvoker
	sessions         *SessionStore
	dataDir          string
	autoApprovePath  string
	userID           id.UserID
	startTime        time.Time
	clock            func() time.Time // injectable clock; defaults to time.Now
	pendingApprovals     sync.Map // map[id.EventID]*pendingApproval
	deniedCache          sync.Map // map[string]time.Time - tool call hashes we've denied
	seenEvents           sync.Map // map[id.EventID]time.Time — dedup against duplicate event delivery
	summaryLocks         sync.Map // map[id.RoomID]*atomic.Bool — per-room summary generation lock
	pinPermissionAlerted sync.Map // map[id.RoomID]bool — rooms where we've alerted about missing pin permissions

	// Identity-derived configuration
	displayName        string // for working indicator text (default: "Agent")
	attachmentsDir     string // where to save Matrix images (default: dataDir/notes/attachments)
	projectsDir        string // base dir for room→project matching (default: ~/Projects)
	summaryThreshold   int    // turns before triggering cross-room summary (default: 10)
	excludeRooms       []string // room name prefixes to exclude from Claude sessions
	systemPromptContent string // contents of identity file, injected via --append-system-prompt
	socketPath          string // unix socket path for hook requests

	// Typing indicator delays (configurable for testing)
	typingReadDelay  time.Duration // delay before sending read receipt (default 800ms)
	typingStartDelay time.Duration // delay between read receipt and typing=true (default 200ms)

	// Graceful drain support
	draining          atomic.Bool
	activeInvocations sync.WaitGroup
	activeRooms       sync.Map // map[id.RoomID]bool — rooms with active Claude invocations
	roomCancels       sync.Map // map[id.RoomID]context.CancelFunc — per-room invocation cancel
	opsRoomID         id.RoomID
}

// ApprovalRequest is sent by the hook to request tool approval
type ApprovalRequest struct {
	SessionID string                 `json:"session_id"`
	ToolName  string                 `json:"tool_name"`
	ToolInput map[string]interface{} `json:"tool_input"`
}

// ApprovalResponse is sent back to the hook
type ApprovalResponse struct {
	Decision string `json:"decision"` // "allow", "deny", or "ask"
	Message  string `json:"message,omitempty"`
}

// pendingApproval tracks a message waiting for reaction
type pendingApproval struct {
	eventID  id.EventID
	roomID   id.RoomID
	response chan ApprovalResponse
}

// BridgeConfig holds the configurable parameters for constructing a Bridge.
type BridgeConfig struct {
	DisplayName      string
	AttachmentsDir   string
	ProjectsDir      string
	SummaryThreshold int
	ExcludeRooms     []string
	SocketPath       string
}

func NewBridge(client MatrixClient, sessions *SessionStore, dataDir string, cfg BridgeConfig) *Bridge {
	// Apply defaults for zero values
	if cfg.DisplayName == "" {
		cfg.DisplayName = "Agent"
	}
	if cfg.AttachmentsDir == "" {
		cfg.AttachmentsDir = filepath.Join(dataDir, "notes", "attachments")
	}
	if cfg.ProjectsDir == "" {
		cfg.ProjectsDir = filepath.Join(os.Getenv("HOME"), "Projects")
	}
	if cfg.SummaryThreshold == 0 {
		cfg.SummaryThreshold = 10
	}
	if cfg.ExcludeRooms == nil {
		cfg.ExcludeRooms = []string{"project-"}
	}
	if cfg.SocketPath == "" {
		cfg.SocketPath = "/tmp/cranium.sock"
	}

	return &Bridge{
		client:           client,
		claude:           &execClaudeInvoker{},
		sessions:         sessions,
		dataDir:          dataDir,
		autoApprovePath:  filepath.Join(dataDir, ".cranium-approvals.json"),
		startTime:        time.Now(),
		clock:            time.Now,
		displayName:      cfg.DisplayName,
		attachmentsDir:   cfg.AttachmentsDir,
		projectsDir:      cfg.ProjectsDir,
		summaryThreshold: cfg.SummaryThreshold,
		excludeRooms:     cfg.ExcludeRooms,
		socketPath:       cfg.SocketPath,
		typingReadDelay:  800 * time.Millisecond,
		typingStartDelay: 200 * time.Millisecond,
	}
}

// now returns the current time via the injectable clock.
func (b *Bridge) now() time.Time {
	return b.clock()
}

// findRoomByName returns the room ID for a room with the given name
func (b *Bridge) findRoomByName(ctx context.Context, name string) id.RoomID {
	resp, err := b.client.JoinedRooms(ctx)
	if err != nil {
		log.Printf("Failed to list joined rooms: %v", err)
		return ""
	}
	for _, roomID := range resp.JoinedRooms {
		if roomName := b.getRoomName(ctx, roomID); roomName == name {
			return roomID
		}
	}
	return ""
}

// getRoomName fetches the display name for a room
func (b *Bridge) getRoomName(ctx context.Context, roomID id.RoomID) string {
	var nameEvent event.RoomNameEventContent
	err := b.client.StateEvent(ctx, roomID, event.StateRoomName, "", &nameEvent)
	if err == nil && nameEvent.Name != "" {
		return nameEvent.Name
	}
	return ""
}

// isExcludedRoomName returns true if a room name indicates it should not trigger
// Claude sessions. Pure decision function — no I/O. Matches exact names or
// prefix patterns from the exclude list.
func isExcludedRoomName(name string, excludeRooms []string) bool {
	if name == "" {
		return false
	}
	for _, pattern := range excludeRooms {
		if name == pattern || strings.HasPrefix(name, pattern) {
			return true
		}
	}
	return false
}

// isExcludedRoom returns true if this room should not trigger Claude sessions
func (b *Bridge) isExcludedRoom(ctx context.Context, roomID id.RoomID) bool {
	name := b.getRoomName(ctx, roomID)
	return isExcludedRoomName(name, b.excludeRooms)
}

// activeRoomCount returns the number of rooms with active Claude invocations
func (b *Bridge) activeRoomCount() int {
	count := 0
	b.activeRooms.Range(func(key, value any) bool {
		count++
		return true
	})
	return count
}

// announceStartup posts a version message to the ops channel
func (b *Bridge) announceStartup(ctx context.Context) {
	if b.opsRoomID == "" {
		return
	}
	msg := fmt.Sprintf("cranium online: `%s`", version)
	b.sendMessage(ctx, b.opsRoomID, msg)
	log.Printf("Posted startup announcement to ops: %s", version)
}

// announceDrain posts an upgrading message to the ops channel
func (b *Bridge) announceDrain(ctx context.Context) {
	if b.opsRoomID == "" {
		return
	}
	b.sendMessage(ctx, b.opsRoomID, "cranium upgrading...")
	log.Printf("Posted drain announcement to ops")
}

// parseCommand extracts a command and arguments from a message.
// Returns the command name ("clear", "new", "usage"), arguments, and whether it's a command.
func parseCommand(message string) (command string, args string, isCommand bool) {
	for _, prefix := range []string{"!", "/"} {
		for _, cmd := range []string{"clear", "new", "usage"} {
			full := prefix + cmd
			if message == full {
				return cmd, "", true
			}
			if strings.HasPrefix(message, full+" ") {
				return cmd, strings.TrimSpace(message[len(full)+1:]), true
			}
		}
	}
	return "", "", false
}

// formatImagePrompt constructs the Claude prompt for an image message.
func formatImagePrompt(imagePath, caption string) string {
	if caption != "" {
		return fmt.Sprintf("[Image attached: %s]\n\n%s", imagePath, caption)
	}
	return fmt.Sprintf("[Image attached: %s]", imagePath)
}

// isSupportedMessageType returns true if the message type is one the bridge handles.
func isSupportedMessageType(msgType event.MessageType) bool {
	return msgType == event.MsgText || msgType == event.MsgImage
}

// isMessageAfterStartup returns true if the message timestamp is at or after the bridge start time.
func isMessageAfterStartup(messageTime, startTime time.Time) bool {
	return !messageTime.Before(startTime)
}

// shouldGenerateSummary returns true if enough turns have elapsed to trigger
// cross-room summary generation.
func shouldGenerateSummary(turns, threshold int) bool {
	return turns >= threshold
}

// detectCompaction returns true if context saturation dropped significantly
// while a pin was active, indicating auto-compaction occurred. Requires a
// drop of more than 10 percentage points to avoid false positives from
// small token-count fluctuations (e.g. 60% → 59%).
func detectCompaction(prevSaturation, saturation int, hasPinnedEvent bool) bool {
	return hasPinnedEvent && saturation < 60 && (prevSaturation-saturation) > 10
}

// slugify converts a room display name to a kebab-case filename slug.
func slugify(name string) string {
	name = strings.ToLower(name)
	var b strings.Builder
	prevHyphen := false
	for _, r := range name {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
			prevHyphen = false
		} else if !prevHyphen {
			b.WriteRune('-')
			prevHyphen = true
		}
	}
	return strings.Trim(b.String(), "-")
}

// formatDuration returns a human-friendly description of a duration
func formatDuration(d time.Duration) string {
	hours := int(d.Hours())
	minutes := int(d.Minutes()) % 60
	if hours >= 24 {
		days := hours / 24
		if days == 1 {
			return "about a day"
		}
		return fmt.Sprintf("about %d days", days)
	}
	if hours > 0 {
		if minutes > 0 {
			return fmt.Sprintf("%dh%dm", hours, minutes)
		}
		return fmt.Sprintf("about %d hours", hours)
	}
	return fmt.Sprintf("about %d minutes", minutes)
}
