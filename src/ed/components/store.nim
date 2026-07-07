## The durable store: an authority appends its canonical op stream to
## append-only JSONL log segments and periodically snapshots full state, so a
## restart restores from snapshot + tail and `EdContext.replay` materializes
## historical views (docs/persistence.md). Split into parts under `store/`
## (format -> log -> {snapshot, restore}); this facade re-exports the public
## API. Import `ed/components/store`.

import ./store/[format, log, snapshot, restore]
export format, log, snapshot, restore
