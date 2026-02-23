package main

import (
	"encoding/json"
	"log"
	"os"
	"sync"
	"time"

	"maunium.net/go/mautrix/id"
)

// SessionStore tracks Claude session IDs per Matrix room
type SessionStore struct {
	mu                 sync.RWMutex
	sessions           map[id.RoomID]string
	lastEventIDs       map[id.RoomID]string // room -> last sent event ID
	lastMessages       map[id.RoomID]string // room -> last sent message content (without trailer)
	lastInvoked        map[string]time.Time // session_id -> last invocation time
	pinnedEventIDs     map[id.RoomID]string // room -> pinned context indicator event ID
	lastSaturation     map[id.RoomID]int    // room -> last known saturation %
	lastReminderAt     map[id.RoomID]int    // room -> last threshold we injected a system-reminder at
	turnsSinceSummary  map[id.RoomID]int    // room -> turns since last summary generation
	interruptedContext map[id.RoomID]string // room -> partial output summary from stopped invocation
	path               string
	clock              func() time.Time // injectable clock; defaults to time.Now
	syncSave           bool             // when true, save() runs synchronously (for tests)
}

func NewSessionStore(path string, clock func() time.Time) *SessionStore {
	if clock == nil {
		clock = time.Now
	}
	store := &SessionStore{
		sessions:           make(map[id.RoomID]string),
		lastEventIDs:       make(map[id.RoomID]string),
		lastMessages:       make(map[id.RoomID]string),
		lastInvoked:        make(map[string]time.Time),
		pinnedEventIDs:     make(map[id.RoomID]string),
		lastSaturation:     make(map[id.RoomID]int),
		lastReminderAt:     make(map[id.RoomID]int),
		turnsSinceSummary:  make(map[id.RoomID]int),
		interruptedContext: make(map[id.RoomID]string),
		path:               path,
		clock:              clock,
	}
	store.load()
	return store
}

// sessionData is the per-room persistent state
type sessionData struct {
	SessionID          string `json:"session_id"`
	LastEventID        string `json:"last_event_id,omitempty"`
	LastMessage        string `json:"last_message,omitempty"`
	PinnedEventID      string `json:"pinned_event_id,omitempty"`
	LastInvokedAt      int64  `json:"last_invoked_at,omitempty"`
	InterruptedContext string `json:"interrupted_context,omitempty"`
}

func (s *SessionStore) load() {
	data, err := os.ReadFile(s.path)
	if err != nil {
		return
	}

	// Try new format first (map of sessionData objects)
	var newFormat map[string]sessionData
	if err := json.Unmarshal(data, &newFormat); err == nil {
		// Check if it's actually new format by seeing if any value has session_id
		for roomID, sd := range newFormat {
			if sd.SessionID != "" {
				s.sessions[id.RoomID(roomID)] = sd.SessionID
				if sd.LastEventID != "" {
					s.lastEventIDs[id.RoomID(roomID)] = sd.LastEventID
				}
				if sd.LastMessage != "" {
					s.lastMessages[id.RoomID(roomID)] = sd.LastMessage
				}
				if sd.PinnedEventID != "" {
					s.pinnedEventIDs[id.RoomID(roomID)] = sd.PinnedEventID
				}
				if sd.LastInvokedAt > 0 {
					s.lastInvoked[sd.SessionID] = time.Unix(sd.LastInvokedAt, 0)
				}
				if sd.InterruptedContext != "" {
					s.interruptedContext[id.RoomID(roomID)] = sd.InterruptedContext
				}
			}
		}
		if len(newFormat) > 0 {
			return
		}
	}

	// Fall back to old format (map of strings)
	var oldFormat map[string]string
	if err := json.Unmarshal(data, &oldFormat); err != nil {
		return
	}
	for roomID, sessionID := range oldFormat {
		s.sessions[id.RoomID(roomID)] = sessionID
	}
}

func (s *SessionStore) save() {
	s.mu.RLock()
	defer s.mu.RUnlock()

	store := make(map[string]sessionData)
	for roomID, sessionID := range s.sessions {
		sd := sessionData{SessionID: sessionID}
		if eid, ok := s.lastEventIDs[roomID]; ok {
			sd.LastEventID = eid
		}
		if msg, ok := s.lastMessages[roomID]; ok {
			sd.LastMessage = msg
		}
		if pid, ok := s.pinnedEventIDs[roomID]; ok {
			sd.PinnedEventID = pid
		}
		if t, ok := s.lastInvoked[sessionID]; ok {
			sd.LastInvokedAt = t.Unix()
		}
		if ictx, ok := s.interruptedContext[roomID]; ok {
			sd.InterruptedContext = ictx
		}
		store[string(roomID)] = sd
	}

	data, err := json.MarshalIndent(store, "", "  ")
	if err != nil {
		log.Printf("Failed to marshal sessions: %v", err)
		return
	}
	if err := os.WriteFile(s.path, data, 0600); err != nil {
		log.Printf("Failed to save sessions: %v", err)
	}
}

// triggerSave fires a save, synchronously in test mode and asynchronously in production.
func (s *SessionStore) triggerSave() {
	if s.syncSave {
		s.save()
	} else {
		go s.save()
	}
}

func (s *SessionStore) Get(roomID id.RoomID) (string, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	sessionID, ok := s.sessions[roomID]
	return sessionID, ok
}

func (s *SessionStore) Set(roomID id.RoomID, sessionID string) {
	s.mu.Lock()
	s.sessions[roomID] = sessionID
	s.mu.Unlock()
	s.triggerSave()
}

// SetLastMessage records the last sent event ID and message content for a room
func (s *SessionStore) SetLastMessage(roomID id.RoomID, eventID string, message string) {
	s.mu.Lock()
	s.lastEventIDs[roomID] = eventID
	s.lastMessages[roomID] = message
	s.mu.Unlock()
	s.triggerSave()
}

// GetLastMessage returns the last sent event ID and message content for a room
func (s *SessionStore) GetLastMessage(roomID id.RoomID) (string, string, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	eid, ok := s.lastEventIDs[roomID]
	if !ok {
		return "", "", false
	}
	msg := s.lastMessages[roomID]
	return eid, msg, true
}

// ClearLastMessage removes the last message tracking for a room
func (s *SessionStore) ClearLastMessage(roomID id.RoomID) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.lastEventIDs, roomID)
	delete(s.lastMessages, roomID)
}

// GetRoomBySession returns the room ID for a given session ID (reverse lookup)
func (s *SessionStore) GetRoomBySession(sessionID string) (id.RoomID, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	for roomID, sid := range s.sessions {
		if sid == sessionID {
			return roomID, true
		}
	}
	return "", false
}

// MarkInvoked records that we just invoked Claude for this session
func (s *SessionStore) MarkInvoked(sessionID string) {
	s.mu.Lock()
	s.lastInvoked[sessionID] = s.clock()
	s.mu.Unlock()
	s.triggerSave()
}

// IsRecentlyInvoked returns true if the session was invoked within the timeout
func (s *SessionStore) IsRecentlyInvoked(sessionID string, timeout time.Duration) bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if t, ok := s.lastInvoked[sessionID]; ok {
		return time.Since(t) < timeout
	}
	return false
}

// TimeSinceLastInvoked returns the duration since the last invocation for a session.
// Returns 0 and false if the session has never been invoked.
func (s *SessionStore) TimeSinceLastInvoked(sessionID string) (time.Duration, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if t, ok := s.lastInvoked[sessionID]; ok {
		return time.Since(t), true
	}
	return 0, false
}

func (s *SessionStore) SetPinnedEvent(roomID id.RoomID, eventID string) {
	s.mu.Lock()
	s.pinnedEventIDs[roomID] = eventID
	s.mu.Unlock()
	s.triggerSave()
}

func (s *SessionStore) GetPinnedEvent(roomID id.RoomID) (string, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	eid, ok := s.pinnedEventIDs[roomID]
	return eid, ok && eid != ""
}

func (s *SessionStore) ClearPinnedEvent(roomID id.RoomID) {
	s.mu.Lock()
	delete(s.pinnedEventIDs, roomID)
	delete(s.lastSaturation, roomID)
	delete(s.lastReminderAt, roomID)
	s.mu.Unlock()
	s.triggerSave()
}

func (s *SessionStore) GetLastSaturation(roomID id.RoomID) int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.lastSaturation[roomID]
}

func (s *SessionStore) SetLastSaturation(roomID id.RoomID, pct int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.lastSaturation[roomID] = pct
}

func (s *SessionStore) GetLastReminderAt(roomID id.RoomID) int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.lastReminderAt[roomID]
}

func (s *SessionStore) SetLastReminderAt(roomID id.RoomID, threshold int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.lastReminderAt[roomID] = threshold
}

func (s *SessionStore) IncrementTurns(roomID id.RoomID) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.turnsSinceSummary[roomID]++
	return s.turnsSinceSummary[roomID]
}

func (s *SessionStore) ResetTurns(roomID id.RoomID) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.turnsSinceSummary[roomID] = 0
}

func (s *SessionStore) GetTurns(roomID id.RoomID) int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.turnsSinceSummary[roomID]
}

func (s *SessionStore) SetInterruptedContext(roomID id.RoomID, context string) {
	s.mu.Lock()
	s.interruptedContext[roomID] = context
	s.mu.Unlock()
	s.triggerSave()
}

func (s *SessionStore) GetInterruptedContext(roomID id.RoomID) (string, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	ctx, ok := s.interruptedContext[roomID]
	return ctx, ok
}

func (s *SessionStore) ClearInterruptedContext(roomID id.RoomID) {
	s.mu.Lock()
	delete(s.interruptedContext, roomID)
	s.mu.Unlock()
	s.triggerSave()
}
