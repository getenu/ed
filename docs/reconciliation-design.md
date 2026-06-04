# Ed Reconciliation Design — state-based forward correction

> How optimistic local writes are reconciled to canonical (leader-ordered) state.
> Chosen model: **authority-driven forward correction**, not client-side rollback.
> Companion to `phase-1-keystone-spike.md` (resolves its "optimism crux") and
> `consistency-and-partial-sync-plan.md`.

## The model

The authority (leader) is the source of truth. Reconciliation happens by the
authority pushing **forward corrections** — a fresh assign carrying the canonical
value, or a create to restore a wrongly-deleted object. **Clients never roll
back; they apply what arrives.** This is *state-based* replication (send the
value/state) rather than *operation-based* (replay the delta), which makes
corrections naturally idempotent and convergent.

This dissolves the register-vs-collection "skip vs re-apply own op" dilemma with
one rule:

> **The authority never echoes your op back for you to replay — it sends you the
> canonical value/state.** You apply optimistically for instant feedback; the
> authority's later message *is* the correction (matching → no-op; differing →
> snap forward).

### Traffic reality (drives the emphasis)

Registers are the majority of Enu *objects*, but **the bulk of Enu *traffic* is
voxel updates — seqs and tables** (`chunk_deltas: EdTable[Vector3,
EdSeq[DeltaUpdate]]`, `packed_chunks`). So collection reconciliation is the
**performance-critical hot path**, not an edge case. Consequences:

- The hot path reconciles via **idempotent *delta* application** (op-id dedup),
  never full-state resend.
- **Full-state snapshot** is reserved for resync / backpressure / new-subscriber
  catch-up — which mirrors Enu's existing `MAX_DELTAS_BEFORE_SNAPSHOT`
  snapshot+delta compaction. Our model reuses a pattern Enu already trusts.

## Per-container reconciliation

### `EdValue` (register) — the easy, idempotent case

- An assign carries `(value, lsn)`. Apply iff `lsn > object's last-applied lsn`.
  Idempotent; a stale lower-LSN value can't clobber a newer one.
- Loser reconciliation = the authority's forward assign with the canonical value.
  No rollback. (Coalesced delivery — below — makes this flicker-free.)
- Registers therefore nearly fall out of the LSN frontier we already built.

### `EdSeq` / `EdTable` / `EdSet` (collections) — the hot path

- **Apply each distinct op exactly once, in LSN order**, via **op-id dedup**: an
  op whose `op_id` you've already applied (your own optimistic op, or a
  redelivery) advances the frontier but does **not** re-run the effect (so no
  double-add). This is delta-based and cheap — required for voxel traffic.
- **Resync path:** when a receiver is too far behind / a new subscriber joins /
  backpressure trips, the authority sends a **state snapshot** (coalesced latest)
  instead of replaying the delta backlog — reusing the voxel snapshot+delta
  pattern. (Same mechanism as fanout queue-compaction; see spike doc.)
- **Conflict semantics:** voxel cells are LWW-per-cell, resolved when deltas
  compact into a snapshot; `EdSeq` index order is guaranteed only within a tick
  (per the main plan). Add-vs-remove of the same element resolves by LSN order.

## Register own-op handling: the op_id-superseded rule

A naive "re-apply your own echo by LSN" is correct for *convergence* but makes a
continuously-writing entity (player movement) **snap back** to its own stale
echoes — an old position update echoes from the authority ~1 RTT later and
overwrites the entity's newer optimistic position. (Cross-thread the RTT is ~0 so
it's invisible; over the network it's visible jitter.)

The fix — for **registers** — is to skip your own echo *only when a later write
of your own supersedes it*:

- Each originated write gets a per-context `op_id`; we record `latest_op_id`
  per object.
- On a register op we originated (`origin == self`): if `op_id < latest_op_id[obj]`
  it's **stale** (we've written newer) → advance the frontier, skip the effect →
  *no snap-back*. If `op_id == latest_op_id[obj]` it's our **latest** → apply it →
  a contended register still **converges** to the canonical value.
- Other-origin ops are always applied — an **authoritative override** (e.g. a
  script teleport) is accepted, and the entity re-bases onto it.

This preserves convergence in all cases (the accept-override variant did **not** —
it could leave two writers permanently divergent). It's a state-based form of
**client-side prediction + server reconciliation** (game netcode; Replicache-style
sync engines), valid here because we ship values over a single LSN-ordered stream.

**Known limitation (accepted):** a forward write already *in flight* when an
authoritative override lands gets a higher LSN than the override, so **observers**
briefly see the stale position before the writer's re-based write supersedes it
(one or a few self-correcting frames). The writer's own client is unaffected.
Fully eliminating the observer glitch needs **versioned / conditional writes**
(OCC — the authority rejects a write whose base was superseded); deferred as
optional, since the case is rare and self-correcting.

**Precondition:** the rule needs each object's ops delivered in its authority's
LSN order — provided by the single-leader star topology (one upstream per leaf).
It generalizes to per-object authority (per-object frontiers + `authority_of`);
multi-path meshes would additionally need the deferred reorder buffer.

Collections keep the simpler rule below (own delta ops always skipped — no
whole-value snap-back exists for element-level adds/removes).

## Own-op handling (the load-bearing rule)

1. Originator applies optimistically (instant local feedback — unchanged from
   today).
2. Originator tags the op with a client-generated `op_id`, records it in a small
   `pending` set, and sends it to the authority.
3. Authority assigns the LSN and broadcasts the canonical op/value to everyone.
4. On receiving an op whose `op_id` is in `pending`: **advance the frontier, drop
   from `pending`, fire the ack (deferred, #10) — do NOT re-run the effect.** The
   effect is already applied optimistically; the canonical truth either matches
   (no-op) or a *later* higher-LSN op corrects it forward.

This needs `op_id` on every op (the field exists) + a per-context `pending` set.

## Ordering & frontier

- Global LSN assigned by the authority (already built). Receivers track a
  **per-object last-applied LSN** (derivable from global LSN + `object_id`),
  because coalesced/snapshot delivery skips intermediate LSNs, so a single
  contiguous counter no longer fits.
- Stale guard: apply a value/op only if its `lsn` exceeds the object's
  last-applied LSN.

## Delete / restore flow

- Optimistic delete on a client → forwarded to the authority.
- Canonical says **deleted** → authority confirms (ordered `DESTROY`; the frontier
  is the tombstone — ops `≤ N` are no-ops).
- Canonical says **alive** (delete lost/rejected per the delete-vs-update policy in
  the spike doc) → authority sends a **create/state to restore** the object on the
  deleter. Forward correction, no rollback. A restore is just a higher-LSN op.

## Optimistic flicker & coalescing

- Naive per-op delivery: the loser briefly sees an intermediate value
  (`b → a → b`). **Coalesced delivery** (send the latest canonical value/state per
  object) removes the flicker *and* is the fanout/backpressure win — one
  mechanism. Recommended default for the correction path.

## Relationship to other work

- Builds on increments 1–2 (LSN stamping, frontier, ordered `DESTROY`).
- Reuses Enu's snapshot+delta voxel pattern for collection resync.
- `op_id` ties into the deferred ack-callback (#10).
- Per-object frontier is the partial-sync-ready direction noted in the spike's
  LSN-granularity section.

## Open decisions

- **Collection conflict policy details** (cell-LWW timing; seq order per-tick).
- **Snapshot-vs-delta threshold** for resync (reuse the `MAX_DELTAS` idea).
- **delete-vs-update policy** (LSN-last-wins default vs versioned/CAS) — from the
  spike doc.

## Implementation increments

- **3a — own-op dedup + `pending` set.** `op_id` assignment, `pending` tracking,
  the "don't re-run own op" rule. Makes registers correct under contention with no
  rollback. (Enables return-to-source safely.)
- **3b — collection delta-idempotent apply.** op-id effect-dedup for
  seq/table/set — the voxel hot path.
- **3c — forward correction + coalescing.** Authority sends canonical value/state
  to losers; coalesced (flicker-free) delivery.
- **3d — delete → restore flow.** Authority restores objects whose delete lost.
