package main

import (
	"testing"
	"time"

	"maunium.net/go/mautrix/id"
)

// --- Unit tests: eviction logic ---
// Spec: message_routing.feature — dedup uses seenEvents which needs eviction to prevent unbounded growth

func TestBridge_EvictStaleEntries_RemovesOldSeenEvents(t *testing.T) {
	b, _, _ := newTestBridge(t)

	now := time.Date(2025, 1, 15, 12, 0, 0, 0, time.UTC)
	b.clock = func() time.Time { return now }

	// Add some events: one old (25h ago), one recent (1h ago)
	oldEvent := id.EventID("$old")
	recentEvent := id.EventID("$recent")

	b.seenEvents.Store(oldEvent, now.Add(-25*time.Hour))
	b.seenEvents.Store(recentEvent, now.Add(-1*time.Hour))

	// Run eviction
	b.evictStaleEntries()

	// Old event should be gone
	if _, exists := b.seenEvents.Load(oldEvent); exists {
		t.Error("expected old event to be evicted")
	}

	// Recent event should still be there
	if _, exists := b.seenEvents.Load(recentEvent); !exists {
		t.Error("expected recent event to remain")
	}
}

func TestBridge_EvictStaleEntries_RemovesOldDeniedCache(t *testing.T) {
	b, _, _ := newTestBridge(t)

	now := time.Date(2025, 1, 15, 12, 0, 0, 0, time.UTC)
	b.clock = func() time.Time { return now }

	// Add some denied tool calls
	oldHash := "hash-old"
	recentHash := "hash-recent"

	b.deniedCache.Store(oldHash, now.Add(-25*time.Hour))
	b.deniedCache.Store(recentHash, now.Add(-1*time.Hour))

	// Run eviction
	b.evictStaleEntries()

	// Old entry should be gone
	if _, exists := b.deniedCache.Load(oldHash); exists {
		t.Error("expected old denied cache entry to be evicted")
	}

	// Recent entry should still be there
	if _, exists := b.deniedCache.Load(recentHash); !exists {
		t.Error("expected recent denied cache entry to remain")
	}
}

func TestBridge_EvictStaleEntries_NoOpWhenEmpty(t *testing.T) {
	b, _, _ := newTestBridge(t)

	// Should not panic or error when maps are empty
	b.evictStaleEntries()
}

func TestBridge_EvictStaleEntries_NoOpWhenAllRecent(t *testing.T) {
	b, _, _ := newTestBridge(t)

	now := time.Date(2025, 1, 15, 12, 0, 0, 0, time.UTC)
	b.clock = func() time.Time { return now }

	// Add only recent events
	event1 := id.EventID("$event1")
	event2 := id.EventID("$event2")

	b.seenEvents.Store(event1, now.Add(-1*time.Hour))
	b.seenEvents.Store(event2, now.Add(-2*time.Hour))

	// Run eviction
	b.evictStaleEntries()

	// Both should still be there
	if _, exists := b.seenEvents.Load(event1); !exists {
		t.Error("expected event1 to remain")
	}
	if _, exists := b.seenEvents.Load(event2); !exists {
		t.Error("expected event2 to remain")
	}
}

func TestBridge_EvictStaleEntries_HandlesExactCutoff(t *testing.T) {
	b, _, _ := newTestBridge(t)

	now := time.Date(2025, 1, 15, 12, 0, 0, 0, time.UTC)
	b.clock = func() time.Time { return now }

	// Event exactly at the cutoff (24h ago)
	cutoffEvent := id.EventID("$cutoff")
	b.seenEvents.Store(cutoffEvent, now.Add(-24*time.Hour))

	// Event just before cutoff (23h59m ago) — should be kept
	justBeforeEvent := id.EventID("$justbefore")
	b.seenEvents.Store(justBeforeEvent, now.Add(-23*time.Hour).Add(-59*time.Minute))

	// Event just after cutoff (24h1m ago) — should be evicted
	justAfterEvent := id.EventID("$justafter")
	b.seenEvents.Store(justAfterEvent, now.Add(-24*time.Hour).Add(-1*time.Minute))

	// Run eviction
	b.evictStaleEntries()

	// Cutoff event (exactly 24h) should be kept (Before is exclusive)
	if _, exists := b.seenEvents.Load(cutoffEvent); !exists {
		t.Error("expected cutoff event to remain (cutoff is exclusive)")
	}

	// Just before should be kept
	if _, exists := b.seenEvents.Load(justBeforeEvent); !exists {
		t.Error("expected just-before event to remain")
	}

	// Just after should be evicted
	if _, exists := b.seenEvents.Load(justAfterEvent); exists {
		t.Error("expected just-after event to be evicted")
	}
}
