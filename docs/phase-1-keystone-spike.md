# Phase 1 Keystone — Design Spike

> Reconnaissance of Ed's current sync internals and where the Phase 1 keystone
> (global LSN + appointed leader + ordered apply + reconciliation) plugs in.
> Companion to `consistency-and-partial-sync-plan.md`. Scope: **cross-thread
> first** (deterministic, no netty), per that plan's de-risking note.

## How sync works today

**Topology — symmetric peer mesh, no leader.** `EdContext.subscribe(ctx)`
(`subscriptions.nim:384`) is bidirectional: each context adds a `LOCAL`
`Subscription` holding the *other* context's inbox channel. Every context
self-publishes its own changes directly to all subscribers. There is **no
sequencer and no global order.**

**Transport.**
- Local (cross-thread): each `EdContext` has an inbox `chan: Chan[Message]`
  (`pkg/threading/channels`); a `LOCAL` subscription holds the target's `chan`
  (`types.nim:111`, `130`). Reliable, FIFO per sender, no partitions.
- Remote: netty `Reactor` + per-sub `Connection`; flatty + snappy on the wire.

**Mutation → message flow.**
1. App mutates an `Ed` → `publish_changes` / `publish_create` / `publish_destroy`.
2. `publish_changes` (`subscriptions.nim:306`) builds `Message`s via
   `obj.build_message`, packs them, and for each subscriber **not** in
   `op_ctx.source` calls `ctx.send(...)` (`:342-345`).
3. `send` (`:178`) sets `msg.source_set` (echo-prevention) and for `LOCAL` subs
   does `sub.chan.send(msg)` → pushes into the target's inbox.
4. Target's `tick()` drains its `chan` via `try_recv` → `process_message(msg)`
   (`:670-674`). Remote messages are uncompressed/deserialized and funnel to the
   **same** `process_message` (`:776`).
5. `process_message` (`:470`) decodes source and applies: `CREATE` → type
   initializer; otherwise `obj.change_receiver(obj, msg, op_ctx)` (`:547-555`).

**Echo prevention.** `OperationContext.source` is a `HashSet[string]` of context
ids the change has already visited; a subscriber whose `ctx_id` is in `source` is
skipped, and `source` grows as the op propagates through the mesh.

**Ordering today — essentially none.** Channels give per-sender FIFO, but across
senders/paths there is no global or per-object order, and **no conflict
resolution** — whichever message is processed last clobbers (the "lost update"
the old CRDT plan complained about). There *is* latent scaffolding:
- `EdContext.last_msg_id` / `last_received_id` (`types.nim:132-133`) — per-peer
  counters.
- `Message.id` (`types.nim:64`) — assigned from `last_msg_id` in `send`
  (`:187-192`) but **only under `-d:ed_trace`**, and per-destination, not global.
- A receiver-side sequence check in `process_message` exists but is **commented
  out**.

So the bones of per-source sequencing exist; Phase 1 promotes them to a
first-class, leader-assigned, global LSN and adds the apply-side ordering.

## Insertion points (reserve-now primitive → where)

| Primitive | Where |
|---|---|
| **`(epoch, lsn)` + `op_id` on every op** | add fields to `Message` (`types.nim:51`); wire into the custom `to_flatty`/`from_flatty(Message)` in `types.nim` (un-gate from `ed_trace`). Promote the `last_msg_id` idea into a real per-object LSN assigned by the authority. |
| **Appointed leader / sequencer** | new `EdContext` state: `is_authority: bool` (or a `leader_id`), and an `authority_of(obj) -> ctx_id` indirection (constant = leader for now). Enu: the **worker-thread context** is the leader. |
| **Ordered apply + dedup-by-LSN (frontier)** | `process_message` (`subscriptions.nim:470`) — the single apply point. Add per-object `applied_lsn`; `lsn <= applied_lsn` ⇒ idempotent no-op; `== applied_lsn+1` ⇒ apply; `> +1` ⇒ gap → buffer + request replay. |
| **Reconciliation (snap-to-correct)** | also `process_message`: when an ordered op supersedes an optimistic local value, apply the authority value through the existing `change_receiver` path, gated by LSN + "is this my own op coming back?" (`op_id`). |
| **Ack / commit callback** | originator tracks `pending_ops` by `op_id`; in `process_message`, after apply, if `msg.op_id` is pending, fire callback with outcome **confirmed-as-is vs corrected-to(X)**. |
| **Durable log + persist** | Phase 2 — leader appends ordered ops; out of scope here. |

## The one real design fork: routing model

How does a non-leader write acquire its LSN?

- **(a) Route-to-leader-first (the `confirmed` path):** the writer sends the op to
  the authority, which assigns `(epoch, lsn)` and broadcasts the ordered op to
  everyone (incl. the originator). The originator applies only on the ordered
  echo. No flicker, 1 round-trip latency.
- **(b) Optimistic local apply + leader re-stamp (the `optimistic` path):** the
  writer applies locally and broadcasts now (≈ today's flow); the authority, on
  receipt, assigns the canonical LSN and re-broadcasts the ordered version;
  others reconcile/snap. Fast, may flicker.

These are exactly the two **per-object modes** from the plan. Recommendation:
**implement (b) first** (it's the primary "fast local + snap-to-correct" pattern
and the smaller delta from today's optimistic broadcast), but lay the message +
leader plumbing so **(a) slots in** for `confirmed` objects by selecting routing
off the object's `mode`.

## Routing & fanout — current behavior and plan

The leader model **concentrates** all fanout at the host, so the existing fanout
costs must be addressed alongside Phase 1, not after.

### Blocking points (today)

- **Local send blocks the producer.** `send_or_buffer` (`subscriptions.nim:160`)
  with `buffer=false` — the `EdContext` **default** — calls `sub.chan.send`,
  which blocks when the target inbox `Chan` (size **100**) is full → a slow
  consumer thread stalls every producer feeding it. `buffer=true` instead grows an
  **unbounded** in-memory `chan_buffer`.
- **Remote connect spins.** `subscribe(address)` blocks in
  `while not finished: reactor.tick` until ACK (`:444`).
- **Subscribe pushes all state synchronously.** `add_subscriber` (`:349`)
  `publish_create`s **every object** inline — an O(objects) serialize-and-send
  burst per join.

### Netty under backpressure

Defaults: **492 B** UDP payload, **25 KB** max in-flight/connection, **250 ms**
ack/retransmit, **10 s** timeout.

- `send`/`divideAndSend` only queues parts into `conn.sendParts` — **never
  blocks, never drops, unbounded queue.**
- `tick`/`sendNeededParts` pushes ≤25 KB in-flight then flags `saturated` and
  stops for that conn; unacked parts retransmit every 250 ms; `deleteAckedParts`
  frees only a *contiguous acked prefix* → one early loss head-of-line-blocks the
  whole queue.
- Slow client ⇒ unbounded host-memory backlog + throughput capped at ~25 KB/RTT +
  constant retransmits, until the 10 s timeout drops it.
- netty exposes `saturated` / `inQueue` / throughput stats — **Ed reads none of
  them.** No backpressure feedback into publishing.

### The fanout cost (the bottleneck)

`publish_changes` loops subscribers → `send` per sub → `send` runs
`msg.to_flatty` + `.compress` **per subscriber** (`:232-237`). N clients ⇒ N×
serialize + N× compress of an essentially identical payload. Only the source
short-id header is genuinely per-sub.

### Plan

1. **Serialize/compress once (PR 1).** Split a `Message` into a sub-independent
   **body** (payload + `epoch`/`lsn`, flatty'd + snappy'd **once**) and a tiny
   per-sub **header** (source short-ids). Biggest single fanout win; lives in the
   same `send`/`publish_changes` code as the LSN format change.
2. **Per-subscription delivery state (Phase 2; design now).** Give each
   `Subscription` a mode: `op_stream` vs `resyncing`. Read netty
   `saturated`/`inQueue` + local chan depth; a far-behind sub switches to
   **snapshot@LSN + tail** instead of replaying the op backlog — reuses the
   durable-log/snapshot capability. (Backpressure handling and snapshot-resync are
   the same mechanism.)
3. **LSN queue compaction (Phase 2/3).** Per-object LSN lets a slow sub's queued
   `ASSIGN`s collapse to last-value-wins per object.
4. **Relay topology (later).** The parked forwarding partial subscriber → host →
   relays → clients, turning host fanout O(N) into O(relays).

## Proposed PR 1 — "LSN + appointed leader ordering (cross-thread)"

Bounded, testable, minimal product-behavior change:

1. Add `epoch`, `lsn`, `op_id` to `Message` + serializers (un-gate from
   `ed_trace`).
2. `EdContext`: `is_authority`/`leader_id`, `authority_of(obj)` (constant),
   per-object `applied_lsn`, `pending_ops` for acks.
3. Leader stamps `lsn` on its ordered broadcast; non-leader optimistic writes get
   ordered at the leader and re-broadcast (model **b**).
4. Apply side: LSN-ordered apply + dedup in `process_message`; reconciliation
   snaps to authority value.
5. Commit-callback plumbing (op_id echo → callback, with outcome).
6. **Serialize/compress once per change** — split `Message` into a sub-independent
   body (serialized + compressed a single time, carrying payload + `epoch`/`lsn`)
   and a per-sub source header; the per-subscriber `send` loop only varies the
   header, never re-runs `to_flatty`/`compress` on the body.

**Tests (in-process, two contexts, one leader):**
- Concurrent writes to the same `EdValue` from two contexts → both converge to
  the leader-ordered value.
- Ack callback fires with `confirmed-as-is` for the winner, `corrected-to` for
  the loser.
- Re-delivering an already-applied LSN is a no-op (idempotency).
- A collection (`EdSeq`) with concurrent adds → both present, order = leader order.
- **Fanout serializes/compresses the body once regardless of subscriber count**
  (assert a single serialize/compress per change across N subscribers).

## Risks / unknowns to resolve while building

- **`PACKED` messages** (`subscriptions.nim:283`, `501`) batch multiple ops — LSN
  assignment must handle a batch (one LSN per inner op, or per batch?).
- **`SYNC_ALL_NO_OVERWRITE`** path and the subscribe-time bulk `publish_create`
  (`add_subscriber`, `:349`) emit many CREATEs — ensure these get sensible LSNs
  (initial snapshot vs live ops).
- **Where exactly is the leader hop** for cross-thread, given the mesh has no
  routing layer — likely: non-leader `send` to the leader sub only; leader
  rebroadcasts. Need to confirm the cleanest splice into `publish_changes`/`send`.
- **`op_ctx.source` interaction** — the new ordered re-broadcast must not be
  suppressed by echo-prevention when it returns to the originator (it *must* come
  back to drive the ack/snap). Reconcile LSN logic with the `source` skip.
- **Per-object vs per-context LSN space** — per-object is cleaner for partial sync
  later; per-context is simpler now. Decide early (leaning per-object).
