---
id: cv2-a4cf
status: closed
deps: []
created: 2026-03-06T02:27:12Z
type: task
priority: 2
---
# Incremental manifest population: wire Egress to push segments to Manifest as chunks arrive instead of batch-populating after inference completes. Currently the HTTP transport Task waits for Epoch.submit to finish, then adds the entire output as a single utterance. For real streaming, Egress should call Manifest.add_utterance as each chunk is finalized by the Chunker, so clients polling the manifest see segments appear incrementally.
