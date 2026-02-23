package main

import (
	"log"
	"time"
)

// evictionTTL is the time after which an entry should be evicted
const evictionTTL = 24 * time.Hour

// evictionInterval is how often the eviction goroutine runs
const evictionInterval = 1 * time.Hour

// startEvictionLoop runs a background goroutine that periodically evicts stale
// entries from seenEvents and deniedCache. Stops when done is closed.
func (b *Bridge) startEvictionLoop(done <-chan struct{}) {
	ticker := time.NewTicker(evictionInterval)
	go func() {
		defer ticker.Stop()
		for {
			select {
			case <-done:
				return
			case <-ticker.C:
				b.evictStaleEntries()
			}
		}
	}()
}

// evictStaleEntries removes entries from seenEvents and deniedCache that are
// older than evictionTTL. This is a pure housekeeping operation — the maps
// are used for deduplication, not durability, so evicting old entries is safe.
func (b *Bridge) evictStaleEntries() {
	now := b.now()
	cutoff := now.Add(-evictionTTL)

	seenCount := 0
	deniedCount := 0

	// Evict from seenEvents
	b.seenEvents.Range(func(key, value any) bool {
		if ts, ok := value.(time.Time); ok && ts.Before(cutoff) {
			b.seenEvents.Delete(key)
			seenCount++
		}
		return true
	})

	// Evict from deniedCache
	b.deniedCache.Range(func(key, value any) bool {
		if ts, ok := value.(time.Time); ok && ts.Before(cutoff) {
			b.deniedCache.Delete(key)
			deniedCount++
		}
		return true
	})

	if seenCount > 0 || deniedCount > 0 {
		log.Printf("Eviction: removed %d seenEvents, %d deniedCache entries older than %s", seenCount, deniedCount, evictionTTL)
	}
}
