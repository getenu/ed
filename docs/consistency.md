# Consistency — Ordering, Reconciliation, Transport

How Ed gives concurrent writers a single convergent order, how followers apply it,
and how it keeps stray/incompatible peers from corrupting a context. The wider
(partly-unbuilt) roadmap lives in `consistency-and-partial-sync-plan.md`.

## Global ordering

One context is the **authority** (`EdContext.is_authority`); it owns a single
global **LSN** counter. Writes are **optimistic**: a writer applies locally and
broadcasts immediately, the authority stamps the canonical LSN and re-broadcasts
the ordered op to everyone — *including the originator* — and followers reconcile
forward (below). Apply is idempotent and ordered in `process_message`: each op
carries `(epoch, lsn, op_id)`; an op at or below the `applied_lsn` frontier is a
no-op, so re-delivery and superseded echoes drop. `lsn == 0` is unordered (CREATE,
control) and always applies.

Why these choices:

- **Return-to-source is mandatory.** An optimistic writer must learn the LSN its
  own op got, or replicas diverge: with two writers A and B on object X, if B
  never hears its own write's LSN it can't tell its value is newer than A's
  returning op and clobbers itself. So the re-broadcast reaches the originator too.
- **DESTROY is ordered; CREATE is not.** Delete-vs-update is a real conflict, so
  DESTROY is stamped and sequenced like ASSIGN (on partition heal the frontier is
  the tombstone — late ops are no-ops). CREATE is deferrable: ids are unique,
  "exists" is monotonic, and `id notin ctx` guards make concurrent creates
  idempotent. Concurrent *same-id* creation is out of scope.
- **Global LSN, not per-object.** One counter per authority, with `object_id` on
  every op so per-object frontiers are derivable later. Global gives cross-object
  causal order (A-before-B, which matters for Ed's ref-heavy graph) for free;
  per-object can't produce a global order without a global counter anyway. The
  seam to per-object stays open via an `authority_of(obj)` indirection (constant
  today). Revisit toward per-object if: two independent worlds want one server,
  peers want to sequence their own objects, or write throughput hits the single
  sequencer's ceiling.

## Reconciliation — state-based forward correction

The authority is the source of truth and corrects followers by pushing **forward
corrections** — a fresh assign with the canonical value, or a create to restore a
wrongly-deleted object. **Clients never roll back; they apply what arrives.** This
is state-based (send the value), not operation-based (replay the delta), so
corrections are idempotent and convergent. The one rule that dissolves the
register-vs-collection "skip vs re-apply my own op" dilemma:

> The authority never echoes your op back to replay — it sends the canonical
> value. You apply optimistically for instant feedback; its later message *is* the
> correction (matching → no-op; differing → snap forward).

**Traffic shape drives the emphasis.** Registers are most *objects*, but the bulk
of *traffic* is voxel updates (`EdSeq`/`EdTable` deltas). So collection
reconciliation is the hot path: it applies via idempotent delta dedup, never
full-state resend. Full-state snapshot is reserved for resync / new-subscriber
catch-up / backpressure (mirroring enu's `MAX_DELTAS_BEFORE_SNAPSHOT`).

**Register own-op handling — the `op_id`-superseded rule.** Naively re-applying
your own echo by LSN converges but makes a continuously-writing entity (player
movement) **snap back** to its own stale echoes ~1 RTT later. The fix, for
registers: each originated write gets a per-context `op_id` and we record
`latest_op_id` per object. For an op we originated (`origin == self`): `op_id <
latest_op_id[obj]` is stale → advance frontier, skip effect (no snap-back); `op_id
== latest_op_id[obj]` is our latest → apply it (a contended register still
converges). Other-origin ops always apply (an authoritative override — a script
teleport — is accepted and the entity re-bases). This is client-side prediction +
server reconciliation, valid because values ship over one LSN-ordered stream.
*Accepted limitation:* a write already in flight when an override lands gets a
higher LSN, so observers briefly see the stale value before the writer's re-based
write supersedes it (self-correcting; eliminating it needs OCC / conditional
writes — deferred).

**Collections** take the simpler path: an op we originated is always skipped on
echo (it was applied optimistically; re-applying a `seq.add` would duplicate).
There's no whole-value snap-back for element-level adds/removes, so no `op_id`
comparison is needed; the `delta` flag distinguishes the two paths.

**Frontier & delete/restore.** Receivers track a per-object last-applied LSN
(coalesced/snapshot delivery skips intermediate LSNs, so a single contiguous
counter doesn't fit). Optimistic deletes forward to the authority; if canonical
says deleted it confirms with an ordered DESTROY, if alive it sends a create/state
to restore — forward correction, a restore is just a higher-LSN op. Coalesced
delivery (latest canonical value per object per tick) removes optimistic flicker
*and* is the fanout/backpressure win — one mechanism.

*Not built:* OCC/versioned writes, ack/commit callback (the `op_id` plumbing
exists; #10), snapshot-vs-delta resync threshold, stricter delete-vs-update policy.

## Transport & schema compatibility

A UDP socket receives any datagram sent to its port — unrelated processes, a stale
prior run, or a **version-skewed peer**. flatty is positional, so foreign bytes
can decode cleanly into wrong-typed fields and crash or corrupt deep in
processing. The governing principle:

> **Strict on the envelope, forgiving on the payload.** Framing/version is the one
> place a hard fail is right (you literally can't parse). Once a message parses, an
> unfamiliar type or value is logged-and-skipped, not fatal.

This relaxation is *safe now* because the consistency layer gives independent
correctness — a single weird object is no longer evidence of systemic failure, so
the old "blow up on anything unexpected" posture is retired.

Shipped: a `wire_header` magic+version on every remote packet (rejected before
deserializing); try/except around remote decode (drop packet, don't crash);
log-and-skip for unknown `type_id` / unregistered ref tid.

**Two compatibility axes — don't conflate them.** The wire version protects the
*envelope* (Message field layout, source encoding, PACKED format, handshake) —
rare, global, bump only when an old peer would misparse *every* message. It does
**not** cover the *application schema* (the bytes inside `msg.obj`). Critical
gotcha: `tid(T) = hash($T)` — the type *name*, not its structure. So adding a new
type or `EdSet[NewEnum]` is safe (new name → new tid → old peers see an unknown
type and skip it), but **adding a value to an existing enum, or a field to an
existing type, changes neither the name nor the tid** — an old peer deserializes
happily and reads garbage, silently. Bumping the envelope version does not catch
this.

*Not built (the real gap):* structure-aware tids (hash field layout + enum
members, so a structural change → unknown type → safe failure) and/or
`TypeSchema`-on-wire (graceful cross-version evolution + durable-log reads);
range-checked enum deserialization; a session nonce in SUBSCRIBE/ACK (rejects
same-version wrong-session traffic); relaying unknown types at the authority (it
can stamp an LSN and forward opaque bytes without understanding the type); a
two-tier version scheme (Ed envelope hard-gate + an app-version policy hook).
