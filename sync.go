package main

import (
	"context"
	"time"

	"maunium.net/go/mautrix"
)

// fastSync is a replacement for client.Sync() with a configurable poll timeout.
// mautrix hardcodes a 30s long-poll timeout, which means worst-case 30s message
// delivery latency. For a bridge on the same box as the homeserver, this is absurd.
func fastSync(ctx context.Context, client *mautrix.Client, timeoutMs int) error {
	nextBatch, err := client.Store.LoadNextBatch(ctx, client.UserID)
	if err != nil {
		return err
	}
	filterID, err := client.Store.LoadFilterID(ctx, client.UserID)
	if err != nil {
		return err
	}
	if filterID == "" {
		filterJSON := client.Syncer.GetFilterJSON(client.UserID)
		resFilter, err := client.CreateFilter(ctx, filterJSON)
		if err != nil {
			return err
		}
		filterID = resFilter.FilterID
		if err := client.Store.SaveFilterID(ctx, client.UserID, filterID); err != nil {
			return err
		}
	}

	// First sync with timeout=0 to catch up immediately
	isFailing := true
	for {
		timeout := timeoutMs
		if isFailing || nextBatch == "" {
			timeout = 0
		}

		resp, err := client.FullSyncRequest(ctx, mautrix.ReqSync{
			Timeout:     timeout,
			Since:       nextBatch,
			FilterID:    filterID,
			FullState:   false,
			SetPresence: client.SyncPresence,
		})
		if err != nil {
			isFailing = true
			if ctx.Err() != nil {
				return ctx.Err()
			}
			duration, err2 := client.Syncer.OnFailedSync(resp, err)
			if err2 != nil {
				return err2
			}
			if duration <= 0 {
				continue
			}
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(duration):
				continue
			}
		}
		isFailing = false

		if err := client.Store.SaveNextBatch(ctx, client.UserID, resp.NextBatch); err != nil {
			return err
		}
		if err := client.Syncer.ProcessResponse(ctx, resp, nextBatch); err != nil {
			return err
		}
		nextBatch = resp.NextBatch

		if ctx.Err() != nil {
			return ctx.Err()
		}
	}
}
