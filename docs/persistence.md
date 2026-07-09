# Persistence — Durable Log, Snapshots, Replay

How an authority makes its canonical op stream durable, compacts it with
snapshots, restores after a restart, and materializes historical views. The
consistency model it rides on is in `consistency.md`; the roadmap that called
for it is `consistency-and-partial-sync-plan.md` (Phase 2).

## The store

`open_store(ctx, path, snapshot_every = 0, durability = FlushPerTick,
retain_snapshots = 2)` attaches a durable store to an **authority** context —
a post-init call, like `subscribe`, made before anything subscribes and before
the context holds objects. Followers never persist; they replicate from the
authority. Layout:

```
<path>/
  HEAD                              # atomic-rename hint; recovery never trusts it blindly
  log/000002-000000000000042.jsonl  # <epoch>-<after_lsn>; new segment per open + per snapshot
  snapshots/000000000000042/        # <watermark lsn>, written as tmp-* then renamed
    manifest.json                   # written last = the snapshot's commit marker
    obj-000001-<oid>.json           # one CREATE-shaped entry per object, full contents
```

The layout is **git-shaped on purpose**: rotated segments are immutable
appends, a snapshot is per-object files sealed by a manifest, and the store
directory is a future repo working tree. The intended endgame is "an ed
project is a git repo" — git supplies durability and distribution (cold
worlds, late-joiner catch-up, forking/sharing, deep history), the mesh stays
the live sync layer, and a host-claim ref gives first-joiner authority a CAS.
None of that is built; the format just doesn't fight it.

Entries are JSONL: one op per line, `Message` fields projected explicitly
(*not* `Message.to_flatty` — that layout varies with `ed_trace`, and explicit
fields keep the log greppable), payload bins base64'd, and a `crc` field last,
computed over the raw line prefix, so torn writes are detectable without
canonical-JSON games. `v`/`txn`/`commit`/`schema` are reserved slots (format
version, future atomic batches, TypeSchema version); `codec` names the payload
encoding so a human-readable codec can take over from flatty later (the
single-serializer cutover — see `decentralization-and-scaling.md`). The
manifest records platform (endianness, int width) — flatty is native-endian —
and refuses a mismatch. Session-coupled fields (`source`, `id_mappings`)
never persist.

## What gets logged, and where

Ordered ops append **at the stamp point** (`publish_changes` /
`publish_destroy`), between `stamp_lsn` and fanout — an op's durable form is
exactly what fans out, and no LSN is ever visible to a peer in an order the
log doesn't have. The store behaves like a permanently-eligible subscriber:
with a store open, build/stamp/append run even with zero subscribers (the
headless authority is the primary durability case) and even when the only
subscriber originated the op. Ops for objects with no SYNC flag are skipped —
declared-ephemeral data doesn't persist — and the snapshot applies the same
predicate, so snapshot ≡ replay(log).

CREATE is unordered (lsn 0) and has no single publish point, so it's logged at
the **creation event** instead: once in `defaults` (the CREATE bin is the
default value; initial content follows as the stamped ops `Ed.init` produces),
and once at placeholder-fill (`relay_fill`) for objects whose CREATE arrived
after something referenced them. Never in `publish_create`, which re-fires per
subscriber. PACKED logs as one entry — `handle_packed` advances the frontier
on the envelope LSN, so splitting it would make replay drop everything after
the first sub-op.

## The commit point

`EdStore.commit` is the single durability decision: appends buffer into the
segment `File`, and *when* they become durable is policy —
`FlushPerTick` (default), `FsyncPerTick`, `FsyncPerOp`. Future rungs (quorum
replication) extend commit, not the append path. Under `FlushPerTick` a hard
crash can lose ops that already fanned out to followers; the epoch reset
(below) is what makes that window safe, so the default stays fast.

## Restore and replay

Restore = newest fully-valid snapshot (manifest crc + every object file crc;
a damaged snapshot falls back to the previous one) + the log tail from its
watermark. With **no** valid snapshot, the log must reach back to LSN 0 or
restore raises `StoreError` — retention prunes early segments once a snapshot
covers them, and silently replaying just the surviving tail would canonize a
near-empty world. Everything is fed through `process_message` — the same idempotent,
frontier-guarded apply engine live sync uses, which also rebuilds `owned_by`,
`ref_pool`, and link wiring for free. `ctx.replaying` is set for the duration
and does exactly three things:

- bypasses the loopback guard and the **own-op superseded rule** — logged
  entries carry our own origin, and the delta short-circuit would otherwise
  silently drop every collection op the authority ever originated. The LSN
  stale-drop stays active; it's what makes double-covered segments (a crash
  between snapshot and rotation) idempotent.
- suppresses publish/stamp/append (`publish_changes`/`publish_destroy` return
  early) — nothing new is happening. A replayed DESTROY would otherwise
  re-enter `publish_destroy` via `change_receiver` and re-stamp/re-append on
  every restart.

Restore runs before anything subscribes or tracks, on the context's home
thread. Snapshot objects materialize in reverse manifest order (children
first, so parent bins link real containers), then the registry is re-ordered
back to manifest order — `add_subscriber` pushes newest-first, and a
post-restart subscriber must still receive children before parents.
Placeholders are never snapshotted (a parent's bin re-mints them; persisting
one would restore a real-but-empty object). Pre-watermark segments are never
replayed: their lsn-0 CREATEs bypass the frontier and would resurrect
create/destroy pairs the snapshot already resolved.

Counter hygiene: `lsn_counter` restores to the maximum stamped LSN *scanned*,
not the frontier — replay legitimately drops some ops (a destroyed object's
tail) without advancing `applied_lsn`, and a reused LSN would be stale-dropped
by every surviving follower forever. `op_id_counter`/`latest_op_id` rebuild
from the manifest + own-origin tail entries.

**Type registration:** a restoring process must instantiate the store's Ed
types (compile an `Ed[T,O].init` for each) so `Ed.bootstrap` registers their
materializers — the same rule as any subscriber (it's what the capability
handshake enforces on the wire). An unknown tid in the log is skipped, like an
unknown type from a peer.

`EdContext.replay(path, to_lsn)` is the time-travel view: a fresh
non-authority context restored to a positional cut — the newest snapshot at or
below `to_lsn`, replayed forward through the entry stamped `to_lsn` (CREATEs
carry no LSN; file position is their order). Read-only store, no epoch bump,
no segment: it coexists with the live authority on the same directory, and
writes on the view are local-only.

## Snapshots, rotation, retention

`ctx.snapshot()` (or `snapshot_every` appended entries, checked at tick)
writes per-object files + manifest into a tmp dir, fsyncs, renames, then
rotates the segment at the watermark — so every non-active segment is
immutable. A valid snapshot already at the current watermark is **kept**, not
replaced (anything since it is lsn-0 CREATEs, which replay as tail): a
delete-then-rewrite would open a crash window where the only retained
snapshot is gone and its covered segments already pruned. The watermark is `lsn_counter` (the authority applies its own
writes synchronously and appends at stamp time; `applied_lsn` never advances
for its own stamps). Retention keeps the newest `retain_snapshots` snapshot
dirs and drops segments fully covered by the oldest kept watermark; replay_to
below the horizon raises `StoreError`. Time-travel depth = retention depth
(`int.high` = keep everything, the future git mode where history lives in
commits).

Torn final line of a segment = a mid-write crash: dropped with a notice. A bad
line anywhere else is real corruption and raises `StoreError` — silently
skipping history would be data loss.

## Epoch

`EdContext.epoch` is stamped onto every ordered op (`stamp_lsn`) and bumps to
`max(seen) + 1` on every store open — the first real use of `Message.epoch`.
A follower that sees a stamped op with a higher epoch than any before it —
**from an upstream** — resets its frontier (`applied_lsn`, `latest_op_id`):
the restarted authority may legitimately reissue LSNs its predecessor fanned
out but never made durable, and without the reset the follower would
stale-drop the new timeline forever. The upstream gate matters: epoch is a
bare wire field, and letting any peer zero the frontier would re-open
non-idempotent delta ops to double-application. Within one store, LSNs stay monotonic across epochs (restore trusts
the scanned maximum), so epoch mostly disambiguates *which incarnation* wrote
an entry — and buys zombie-writer hygiene for the eventual failover work.

## Guarded footguns

`ctx.clear` raises `StoreError` while a writable store is open (a wiped
registry with no messages would silently desync log from state — there is no
CLEAR op). `ctx.close` detaches the store along with the reactor.
Re-`init`ing a live id on a logging authority is likewise unsupported: the
log would carry two CREATEs for one id and replay keeps the first incarnation.

## Schema gate

The manifest's `schema` slot carries `ED_SCHEMA_VERSION` (a manual constant in
`store/format.nim`), and `open_store`/`replay` refuse a store whose slot differs
from the running build's — a `StoreError`, overridable with
`allow_schema_mismatch = true`. **Bump `ED_SCHEMA_VERSION` whenever a persisted
type changes shape** (a field added/removed/reordered, an enum value added):
`tid = hash($T)` is name-only, so without the bump a mismatched build would
deserialize such a store's objects as garbage *silently* — the gate turns that
into a clean refusal. This is the **manual** half of schema safety until
structure-aware tids land, at which point the same slot gains automatic
structural detection (see `decentralization-and-scaling.md` for the serializer +
schema-evolution plan). `schema == 0` means legacy/unset and skips the check; a
store with only a log and no snapshot yet has no manifest to gate, so the check
engages once the first snapshot is written.

## Not built (deferred deliberately)

Serving fetch/REQUEST misses from the log (the authority never evicts today —
this lands with authority eviction); an opt-in `PERSIST` flag to replace the
current persist-iff-synced rule (so a consumer marks exactly what's durable —
needed because a synced object isn't necessarily one to save; the enu adoption
depends on it); structure-aware tids / full TypeSchema (the gate above is
version-level, not per-type structural — `tid = hash($T)` still can't detect a
struct/enum change on its own, see `consistency.md`); the ack/commit callback
(op_id plumbing ready); git integration itself. Known
pre-existing gap surfaced by this work, not fixed here: with a single subscriber
that originated the op, `has_eligible` is false and the echo never returns to
the writer (a return-to-source violation) — capture is unaffected, the echo half
is a follow-up.
