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
*Limitation, unless the register is `REJECT_STALE`:* a write already in flight
when an override lands gets a higher LSN, so it wins. If the writer writes again
after applying the override, that write is based on the override and supersedes
the stale one (a brief flicker). If the stale write was its last, the override
is lost everywhere: the writer applies the override and then its own latest
echo, and the authority holds the stale value too.

**Rejecting stale register writes (`REJECT_STALE`).** A conditional write
whose condition is implicit: the writer had seen the latest write from anyone
else. Every write (ASSIGN or TOUCH) carries `base_lsn`, how far its originator
had read the authority's order when it wrote; forwards keep the originator's. Delivery is LSN-ordered, so a base at
or past an op means the writer had seen it. The authority records the LSN and
origin of each register's latest write, and drops a write from a different
origin whose base is older: the writer hadn't seen the latest write, which is
already on its way to it. It also resends its state to the writer, in case the
writer's base was just behind. Writes from one origin never conflict with each
other, so a continuously-writing body keeps flowing. The result is
first-committer-wins for concurrent writers instead of last-writer-wins, which
is why it's opt-in per object.

A writer's base is `max(applied_lsn, base_hint)`. `base_hint` covers what
stamps can't:
- a CREATE carries its sender's base, so a fresh subscriber's first write
  isn't judged stale before any ordered op reaches it;
- a relay (a non-authority context with an upstream) doesn't forward an op that
  changes nothing it holds, so each tick it has read further it sends its
  downstream a `PROGRESS` with its base. Without it, a context below a relay
  could have every write dropped.

The flag must never quietly fall back to last-writer-wins, so every place it
can't hold is loud:
- `REJECT_STALE` on a collection fails at creation (only registers are checked);
- a register write that would be packed fails (packed ops lose their origin and
  base; one register write is one message, so this is a bug if it happens), and
  an authority that receives a packed op for a `REJECT_STALE` register logs an
  error;
- a write from a context with no authority above it (none known from
  subscribe, no stamp or base received) logs an error once per object. Nothing
  orders or checks its writes, so replicas can disagree for good; what to do
  about that is an open question in `decentralization-and-scaling.md`.

**Collections** take the simpler path: an op we originated is always skipped on
echo (it was applied optimistically; re-applying a `seq.add` would duplicate).
There's no whole-value snap-back for element-level adds/removes, so no `op_id`
comparison is needed; the `delta` flag distinguishes the two paths.

**Frontier & delete/restore.** Receivers track one global frontier,
`applied_lsn`, the highest LSN applied; an op at or below it is a no-op.
Coalesced and filtered delivery skip LSNs, so it's a high-water mark, not a
contiguous count. There's no per-object frontier. Optimistic deletes forward to the authority; if canonical
says deleted it confirms with an ordered DESTROY, if alive it sends a create/state
to restore — forward correction, a restore is just a higher-LSN op. Coalesced
delivery (latest canonical value per object per tick) removes optimistic flicker
*and* is the fanout/backpressure win — one mechanism.

*Not built:* ack/commit callback (the `op_id` plumbing
exists; #10), snapshot-vs-delta resync threshold, stricter delete-vs-update policy.
The ordered stream is now also **durable** on the authority — log, snapshots,
restart-restore, replay — see `persistence.md`.

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

**Since 0.32, the wire catches structural changes at subscribe.** SUBSCRIBE
carries a compile-time structural hash of each registered type and container
(`utils/layouts.nim`); the authority compares the types both sides know and
refuses a mismatch with a `NAK`, so a mixed-build peer fails at connect instead
of reading garbage. The tid itself is still name-only.

*Not built:* the same structural check for the durable store (its gate is still
the manual `ED_SCHEMA_VERSION`, `persistence.md`), and `TypeSchema`-on-wire
(graceful cross-version evolution, rather than refusal, + durable-log reads);
range-checked enum deserialization; a session nonce in SUBSCRIBE/ACK (rejects
same-version wrong-session traffic); relaying unknown types at the authority (it
can stamp an LSN and forward opaque bytes without understanding the type); a
two-tier version scheme (Ed envelope hard-gate + an app-version policy hook).
