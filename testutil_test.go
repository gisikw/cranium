package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"maunium.net/go/mautrix"
	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
)

// --- Helpers ---

// helper
func contains(s, substr string) bool {
	return len(s) >= len(substr) && (s == substr || len(s) > 0 && containsHelper(s, substr))
}

func containsHelper(s, substr string) bool {
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}

// containsStr checks if a string slice contains a given string.
func containsStr(ss []string, target string) bool {
	for _, s := range ss {
		if s == target {
			return true
		}
	}
	return false
}

// --- Mock MatrixClient ---

// sentMessage records a message sent or edited via the mock client
type sentMessage struct {
	RoomID       id.RoomID
	EventID      id.EventID        // non-empty for edits
	Body         string            // plain text body
	MsgType      event.MessageType // MsgText, MsgNotice, etc.
	IsEdit       bool
	IsState      bool
	ThreadParent id.EventID // non-empty for threaded replies
}

// typingCall records a UserTyping invocation
type typingCall struct {
	RoomID  id.RoomID
	Typing  bool
	Timeout time.Duration
}

// mockMatrixClient implements MatrixClient for testing.
type mockMatrixClient struct {
	mu            sync.Mutex
	messages      []sentMessage
	typingCalls   []typingCall
	readReceipts  []id.EventID
	redactions    []id.EventID
	joinedRooms   []id.RoomID
	roomNames     map[id.RoomID]string
	eventCounter  int
	createdRooms  []string // room names passed to CreateRoom
	joinedByID    []id.RoomID
	powerLevels   map[id.RoomID]int // userID power level per room

	// editErrorAfterBytes causes edits to fail with M_TOO_LARGE when the
	// message body exceeds this byte count. 0 means no limit.
	editErrorAfterBytes int

	// pinErrorRooms is a set of room IDs where SendStateEvent should fail
	// with M_FORBIDDEN to simulate missing pin permissions.
	pinErrorRooms map[id.RoomID]bool
}

func newMockClient() *mockMatrixClient {
	return &mockMatrixClient{
		roomNames:     make(map[id.RoomID]string),
		powerLevels:   make(map[id.RoomID]int),
		pinErrorRooms: make(map[id.RoomID]bool),
	}
}

func (m *mockMatrixClient) nextEventID() id.EventID {
	m.eventCounter++
	return id.EventID(fmt.Sprintf("$mock-%d", m.eventCounter))
}

func (m *mockMatrixClient) JoinedRooms(_ context.Context) (*mautrix.RespJoinedRooms, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return &mautrix.RespJoinedRooms{JoinedRooms: m.joinedRooms}, nil
}

func (m *mockMatrixClient) UserTyping(_ context.Context, roomID id.RoomID, typing bool, timeout time.Duration) (*mautrix.RespTyping, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.typingCalls = append(m.typingCalls, typingCall{roomID, typing, timeout})
	return &mautrix.RespTyping{}, nil
}

func (m *mockMatrixClient) MarkRead(_ context.Context, _ id.RoomID, eventID id.EventID) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.readReceipts = append(m.readReceipts, eventID)
	return nil
}

func (m *mockMatrixClient) StateEvent(_ context.Context, roomID id.RoomID, eventType event.Type, _ string, outContent interface{}) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if eventType == event.StateRoomName {
		if name, ok := m.roomNames[roomID]; ok {
			if nc, ok := outContent.(*event.RoomNameEventContent); ok {
				nc.Name = name
			}
		}
	}
	if eventType == event.StatePowerLevels {
		if pl, ok := outContent.(*event.PowerLevelsEventContent); ok {
			if level, exists := m.powerLevels[roomID]; exists {
				pl.Users = map[id.UserID]int{"@agent:example.com": level}
			}
		}
	}
	return nil
}

func (m *mockMatrixClient) SendMessageEvent(_ context.Context, roomID id.RoomID, _ event.Type, contentJSON interface{}, _ ...mautrix.ReqSendEvent) (*mautrix.RespSendEvent, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	eid := m.nextEventID()

	msg := sentMessage{RoomID: roomID, EventID: eid}

	// Extract body and detect edits from the content
	switch c := contentJSON.(type) {
	case event.MessageEventContent:
		msg.Body = c.Body
		msg.MsgType = c.MsgType
		if c.RelatesTo != nil && c.RelatesTo.Type == event.RelReplace {
			msg.IsEdit = true
			msg.EventID = c.RelatesTo.EventID
		}
		if c.RelatesTo != nil && c.RelatesTo.Type == event.RelThread {
			msg.ThreadParent = c.RelatesTo.EventID
		}
	case *event.MessageEventContent:
		msg.Body = c.Body
		msg.MsgType = c.MsgType
		if c.RelatesTo != nil && c.RelatesTo.Type == event.RelReplace {
			msg.IsEdit = true
			msg.EventID = c.RelatesTo.EventID
		}
		if c.RelatesTo != nil && c.RelatesTo.Type == event.RelThread {
			msg.ThreadParent = c.RelatesTo.EventID
		}
	}

	// Simulate M_TOO_LARGE for edits exceeding the byte threshold
	if msg.IsEdit && m.editErrorAfterBytes > 0 && len(msg.Body) > m.editErrorAfterBytes {
		return nil, fmt.Errorf("M_TOO_LARGE (HTTP 413): event too large")
	}

	m.messages = append(m.messages, msg)
	return &mautrix.RespSendEvent{EventID: eid}, nil
}

func (m *mockMatrixClient) SendStateEvent(_ context.Context, roomID id.RoomID, _ event.Type, _ string, _ any, _ ...mautrix.ReqSendEvent) (*mautrix.RespSendEvent, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	// Simulate permission error for rooms in pinErrorRooms
	if m.pinErrorRooms[roomID] {
		return nil, fmt.Errorf("M_FORBIDDEN: You don't have permission to send this state event")
	}

	eid := m.nextEventID()
	m.messages = append(m.messages, sentMessage{RoomID: roomID, EventID: eid, IsState: true})
	return &mautrix.RespSendEvent{EventID: eid}, nil
}

func (m *mockMatrixClient) RedactEvent(_ context.Context, _ id.RoomID, eventID id.EventID, _ ...mautrix.ReqRedact) (*mautrix.RespSendEvent, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.redactions = append(m.redactions, eventID)
	return &mautrix.RespSendEvent{EventID: m.nextEventID()}, nil
}

func (m *mockMatrixClient) DownloadBytes(_ context.Context, _ id.ContentURI) ([]byte, error) {
	return []byte("fake-image-data"), nil
}

func (m *mockMatrixClient) UploadBytesWithName(_ context.Context, _ []byte, _ string, _ string) (*mautrix.RespMediaUpload, error) {
	return &mautrix.RespMediaUpload{
		ContentURI: id.MustParseContentURI("mxc://matrix.example.com/fake-upload-id"),
	}, nil
}

func (m *mockMatrixClient) CreateRoom(_ context.Context, req *mautrix.ReqCreateRoom) (*mautrix.RespCreateRoom, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.createdRooms = append(m.createdRooms, req.Name)
	return &mautrix.RespCreateRoom{RoomID: id.RoomID("!new-room:example.com")}, nil
}

func (m *mockMatrixClient) JoinRoomByID(_ context.Context, roomID id.RoomID) (*mautrix.RespJoinRoom, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.joinedByID = append(m.joinedByID, roomID)
	return &mautrix.RespJoinRoom{RoomID: roomID}, nil
}

func (m *mockMatrixClient) SendText(_ context.Context, roomID id.RoomID, text string) (*mautrix.RespSendEvent, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	eid := m.nextEventID()
	m.messages = append(m.messages, sentMessage{RoomID: roomID, EventID: eid, Body: text})
	return &mautrix.RespSendEvent{EventID: eid}, nil
}

func (m *mockMatrixClient) Messages(_ context.Context, _ id.RoomID, _, _ string, _ mautrix.Direction, _ *mautrix.FilterPart, _ int) (*mautrix.RespMessages, error) {
	// Mock implementation returns empty for now
	// Tests that need specific messages can override this
	return &mautrix.RespMessages{Chunk: []*event.Event{}}, nil
}

// getMessages returns a snapshot of all sent messages (thread-safe)
func (m *mockMatrixClient) getMessages() []sentMessage {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]sentMessage, len(m.messages))
	copy(out, m.messages)
	return out
}

// getTypingCalls returns a snapshot of all typing calls (thread-safe)
func (m *mockMatrixClient) getTypingCalls() []typingCall {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]typingCall, len(m.typingCalls))
	copy(out, m.typingCalls)
	return out
}

// getRedactions returns a snapshot of all redacted event IDs (thread-safe)
func (m *mockMatrixClient) getRedactions() []id.EventID {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]id.EventID, len(m.redactions))
	copy(out, m.redactions)
	return out
}

// --- Mock Claude Invoker ---

// mockClaudeProcess delivers canned stdout lines and empty stderr.
type mockClaudeProcess struct {
	stdout io.ReadCloser
	stderr io.ReadCloser
}

func (p *mockClaudeProcess) Stdout() io.ReadCloser { return p.stdout }
func (p *mockClaudeProcess) Stderr() io.ReadCloser { return p.stderr }
func (p *mockClaudeProcess) Wait() error           { return nil }

// delayedReader wraps a reader with a one-time delay before the first read,
// simulating Claude taking time to produce output.
type delayedReader struct {
	r     io.Reader
	delay time.Duration
	once  sync.Once
}

func (d *delayedReader) Read(p []byte) (int, error) {
	d.once.Do(func() { time.Sleep(d.delay) })
	return d.r.Read(p)
}

// claudeInvocation records the arguments of a single Start call.
type claudeInvocation struct {
	Args []string
	Dir  string
	Env  []string
}

// mockClaudeInvoker implements ClaudeInvoker for testing.
// Queue canned responses with QueueResponse; each Start call pops the next one.
type mockClaudeInvoker struct {
	mu          sync.Mutex
	invocations []claudeInvocation
	responses   []string         // newline-delimited JSON strings to emit on stdout
	delayed     []queuedResponse // responses with delays (consumed first)
}

func newMockClaude() *mockClaudeInvoker {
	return &mockClaudeInvoker{}
}

// queuedResponse holds a canned response with an optional delay.
type queuedResponse struct {
	payload string
	delay   time.Duration
}

// QueueResponse adds a canned stdout payload (newline-delimited JSON lines).
func (m *mockClaudeInvoker) QueueResponse(lines ...string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.responses = append(m.responses, strings.Join(lines, "\n"))
}

// QueueDelayedResponse adds a response that blocks before producing output.
func (m *mockClaudeInvoker) QueueDelayedResponse(delay time.Duration, lines ...string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.delayed = append(m.delayed, queuedResponse{
		payload: strings.Join(lines, "\n"),
		delay:   delay,
	})
}

func (m *mockClaudeInvoker) Start(_ context.Context, args []string, dir string, env []string) (ClaudeProcess, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.invocations = append(m.invocations, claudeInvocation{Args: args, Dir: dir, Env: env})

	var payload string
	var delay time.Duration
	if len(m.delayed) > 0 {
		qr := m.delayed[0]
		m.delayed = m.delayed[1:]
		payload = qr.payload
		delay = qr.delay
	} else if len(m.responses) > 0 {
		payload = m.responses[0]
		m.responses = m.responses[1:]
	}

	var stdout io.ReadCloser
	if delay > 0 {
		stdout = io.NopCloser(&delayedReader{r: strings.NewReader(payload), delay: delay})
	} else {
		stdout = io.NopCloser(strings.NewReader(payload))
	}
	stderr := io.NopCloser(strings.NewReader(""))
	return &mockClaudeProcess{stdout: stdout, stderr: stderr}, nil
}

// getInvocations returns a snapshot of all recorded invocations.
func (m *mockClaudeInvoker) getInvocations() []claudeInvocation {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]claudeInvocation, len(m.invocations))
	copy(out, m.invocations)
	return out
}

// --- Test Bridge Factory ---

// newTestBridge creates a Bridge with mock client, mock Claude, and temp directories.
func newTestBridge(t *testing.T) (*Bridge, *mockMatrixClient, *mockClaudeInvoker) {
	t.Helper()
	tmp := t.TempDir()
	mc := newMockClient()
	mci := newMockClaude()
	sessionsPath := filepath.Join(tmp, "sessions.json")
	sessions := NewSessionStore(sessionsPath, time.Now)

	sessions.syncSave = true

	b := NewBridge(mc, sessions, tmp, BridgeConfig{
		DisplayName:      "Agent",
		AttachmentsDir:   filepath.Join(tmp, "notes", "attachments"),
		ProjectsDir:      filepath.Join(tmp, "Projects"),
		SummaryThreshold: 10,
		ExcludeRooms:     []string{"ops", "project-"},
	})
	b.claude = mci
	b.userID = "@agent:example.com"
	b.startTime = time.Date(2026, 2, 12, 10, 0, 0, 0, time.UTC)
	return b, mc, mci
}

// makeEvent constructs a minimal *event.Event for testing handleMessage.
func makeEvent(sender id.UserID, roomID id.RoomID, body string, ts time.Time) *event.Event {
	content := event.MessageEventContent{
		MsgType: event.MsgText,
		Body:    body,
	}
	evt := &event.Event{
		Sender:    sender,
		RoomID:    roomID,
		ID:        id.EventID(fmt.Sprintf("$evt-%d", ts.UnixNano())),
		Timestamp: ts.UnixMilli(),
		Type:      event.EventMessage,
	}
	evt.Content.Parsed = &content
	return evt
}

// --- Claude stream-json test helpers ---

// claudeAssistantMsg builds a stream-json line for an assistant message with text content.
func claudeAssistantMsg(sessionID string, texts ...string) string {
	var blocks []map[string]interface{}
	for _, t := range texts {
		blocks = append(blocks, map[string]interface{}{"type": "text", "text": t})
	}
	msg := map[string]interface{}{
		"type":       "assistant",
		"session_id": sessionID,
		"message": map[string]interface{}{
			"content": blocks,
			"usage":   map[string]interface{}{"input_tokens": 100.0, "output_tokens": 50.0},
		},
	}
	b, _ := json.Marshal(msg)
	return string(b)
}

// claudeToolMsg builds a stream-json line for an assistant message with tool_use blocks.
func claudeToolMsg(sessionID string, tools ...map[string]interface{}) string {
	var blocks []map[string]interface{}
	for _, tc := range tools {
		blocks = append(blocks, map[string]interface{}{
			"type":  "tool_use",
			"name":  tc["name"],
			"input": tc["input"],
		})
	}
	msg := map[string]interface{}{
		"type":       "assistant",
		"session_id": sessionID,
		"message": map[string]interface{}{
			"content": blocks,
			"usage":   map[string]interface{}{"input_tokens": 100.0, "output_tokens": 50.0},
		},
	}
	b, _ := json.Marshal(msg)
	return string(b)
}

// claudeAssistantMixed builds a stream-json line with both text and tool_use blocks.
func claudeAssistantMixed(sessionID string, text string, toolName string, toolInput map[string]interface{}) string {
	msg := map[string]interface{}{
		"type":       "assistant",
		"session_id": sessionID,
		"message": map[string]interface{}{
			"content": []map[string]interface{}{
				{"type": "text", "text": text},
				{"type": "tool_use", "name": toolName, "input": toolInput},
			},
			"usage": map[string]interface{}{"input_tokens": 100.0, "output_tokens": 50.0},
		},
	}
	b, _ := json.Marshal(msg)
	return string(b)
}

// claudeResultMsg builds a stream-json line for the final result.
func claudeResultMsg(sessionID, result string, contextWindow int) string {
	msg := map[string]interface{}{
		"type":       "result",
		"session_id": sessionID,
		"result":     result,
		"modelUsage": map[string]interface{}{
			"default": map[string]interface{}{
				"contextWindow": float64(contextWindow),
			},
		},
	}
	b, _ := json.Marshal(msg)
	return string(b)
}
