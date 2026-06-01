# Ed: Consistency & Partial Sync — Design Course

> Status: **draft / living document.** Plots a general course toward two large
> features. We are not committing to build all of this, or any of it, now.
> Supersedes the CRDT-leaning `DISTRIBUTED_CONSISTENCY_PLAN.md` on the old
> `comprehensive-crdt-implementation` branch.

## Goals

Two features we want Ed to grow into:

1. **Partial / lazy sync.** A context should only hold the objects it actually
   uses. Referenced-but-unaccessed objects (e.g. the `EdTable`s inside an
   `EdSeq[EdTable]`) should not exist in memory until accessed, materialize on
   access, and stop syncing after a period of disuse (eviction).

2. **Eventual consistency.** All clients converge on an agreed state. On
   divergence, the authoritative value is assigned ("snap to correct value").
   Time-travel/replay through history is desirable.

## Headline decision: one foundation, not two features

Both features are consumers of a single missing primitive:

> **A totally-ordered, durable operation log produced by a single sequencer
> (the host), where every operation carries a global monotonic sequence number
> (LSN).**

Ed already reifies every mutation as a `Message` (CREATE/ASSIGN/UNASSIGN/
TOUCH/DESTROY). The messages are not *ordered* or *retained*. Add LSNs + a
durable log and:

- **Consistency** = apply ops in LSN order; on gap/divergence, replay and let
  the authority's value win.
- **Time-travel** = replay the log to LSN `T` (full replicas only — see below).
- **Lazy/partial sync** = the log is the durable source you materialize *from*,
  and the thing that makes eviction *safe* (you can always re-fetch).

Feature 1 therefore **depends on** Feature 2's log: without a durable backing, an
object nobody has touched gets evicted everywhere → data loss. **Build the
ordered log first.**

## Why not CRDTs

The old `comprehensive-crdt-implementation` branch went all-in on Y-CRDT (Yrs)
via futhark FFI: a 1.9 MB `libyrs.dylib`, ~8,300 lines, vector clocks. Its own
plan doc admitted the costs: 2–4× memory, "no traditional transactions," and
sequence CRDTs (RGA/Logoot) as a multi-month long pole. CRDTs buy *leaderless*
convergence — which we don't need, because Enu has a host. Decision: **drop
CRDTs.** Keep one cheap idea from that world — the **LWW register** — as the
reconciliation rule for scalar values (below). Mine the old branch for ideas,
not code.

## Model: per-object authority + per-object mode

Everything reduces to a little per-object metadata, alongside the existing
`EdFlags`:

```
{ authority: peer_id,  mode: optimistic | confirmed }
```

### Authority

- Each object has an **authority** peer that sequences/validates its writes.
- **Today:** Enu has a single obvious host. For shared/world state, authority =
  host. The host runs scripts, saves data, hosts the durable log + snapshots.
- **Future (door left open, not built now):** per-object authority/ownership so
  clients can own their own objects and the host stops being central. This is
  the standard game-networking ownership model. Introducing `authority` as a
  field now (even when it is always the host) keeps this path open.
- **Handoff:** on authority disconnect, reassign deterministically (oldest
  remaining connection / fall back to host). Cheap; not real consensus.

### Mode (per object)

- **Optimistic (default):** apply locally immediately, broadcast, let the
  authority assign canonical order; if the local value drifts from canonical,
  snap to it.
- **Confirmed:** the local write stays tentative until the authority acks an
  order, then commits. Reserve for the few things that must not double-count or
  briefly show a wrong value.

Reconciliation differs by data shape:

- **`EdValue[T]` (register):** drift correction is a whole-value overwrite —
  i.e. **last-writer-wins**. Cheap, no metadata. Can even resolve leaderless via
  deterministic tiebreak `(timestamp, peer_id)`.
- **`EdSeq`/`EdTable`/`EdSet` (deltas):** reconciliation is "re-apply ops in the
  authority's canonical order." Commutative ops (two adds) don't care; add-vs-
  remove of the same element does, and the authority decides.

### Sequence ordering semantics (decided)

> **`EdSeq` index positions are guaranteed only within a single tick. They may
> change on the next tick.**

Verified safe against Enu: `units` is an `EdSeq[Unit]` used almost entirely via
iteration / `find_first`; the only positional access is `units[0]` ("first
unit"). Tables are keyed by generated ids. Nothing depends on stable indices
across ticks. This rule lets the authority reorder concurrent inserts freely.

## The CAP reality (why election stays simple)

You **cannot** have invisible + reliable + single-leader + stay-writable-during-
a-partition. Real consensus (Raft/Paxos) avoids split-brain by *refusing writes
in the minority partition* — for a game that means "you can't place a block
until the network heals." That is the opposite of what Enu wants.

**Enu wants AP:** stay available, tolerate divergence, reconcile on merge.
Therefore:

- Use **simple deterministic authority** (host today; "oldest connection /
  lowest peer-id," bully-style re-election later). **Do not** build Raft — it
  would actively hurt the "keep playing through a hiccup" goal.
- Spend the "aim high" budget on the things that actually make p2p feel good:
  1. **Seamless authority handoff** on disconnect.
  2. **Good reconciliation** — auto-resolve where safe (LWW / op-replay),
     escalate to a "pick the winner" prompt only for genuine conflicts on
     `confirmed` objects.
  3. **Per-object modes** so the rare critical object can be strict while the
     world stays loose and fast.

Tolerable: higher-than-average data loss; throwing an error / prompting "pick
the winner" on an irreconcilable split.

## Single stream vs per-object streams (decided)

Keep **one logical order (one sequencer, global LSNs) with filtered delivery.**
Each op carries its global LSN; a client subscribed to objects {A,B} receives
only A's and B's ops, each still globally LSN-tagged, and tracks a *frontier*
(highest LSN with complete coverage of its subscription set).

| | single physical stream | per-object streams | **global order + filtered delivery** |
|---|---|---|---|
| Partial sync | no | yes | **yes** |
| Transactions | trivial | hard (2PC / vector clocks) | **atomic LSN batch at authority** |
| Global time-travel | yes | no common clock | **full replica only; scoped for partial clients** |

Do **not** physically fragment into independent per-object logs — it makes
transactions and global time-travel require vector clocks / distributed
snapshots, sliding back toward CRDT-grade complexity.

## What is impossible / reconsidered

- **Full global time-travel on a thin client** is not a thing — you can only
  replay history for objects you hold (or fetch). **Decision (accepted):**
  global time-travel/replay is a **full-replica (host) capability** only.
  Partial clients get scoped history at most.
- **Leaderless + transactions + simple** can't coexist (CAP). Resolved by
  choosing AP + host authority.

## Serious tradeoffs to watch

- **Optimistic flicker vs confirmed latency** — handled by per-object `mode`.
- **Log growth** — needs snapshotting/compaction; time-travel depth bounded by
  retention.
- **Access-tracking overhead for eviction** — pervasive instrumentation on the
  read hot path (`value` getter, `[]`, iteration). Needs measurement.
- **Presence assertions are the #1 code obstacle.** `change_receiver` does
  `assert object_id in self.ctx`; `process_message` requires resident objects.
  Partial/lazy sync means an op can legitimately reference a non-resident
  object. Every such site must become a **lazy-fetch-or-defer hook**.

## Where the schema work fits

The in-flight `TypeSchema` work was aimed at partial subscribers. Its real
justification is **log durability / versioning**: a persisted log outlives the
code that wrote it, so reading old entries whose types have since changed needs
a schema. Re-aim it at the log format (Phase 2), not as a partial-subscriber
band-aid.

The **forwarding partial subscriber** stays useful as a Phase 0 relay primitive
(a relay is the degenerate partial replica).

## Path from single-host to per-object authority

Single-host is a **degenerate case** of per-object authority, not a different
architecture. The host plays four **separable** roles; per-object authority only
decentralizes the first:

| Role | Single-host today | Under per-object authority |
|---|---|---|
| (a) **Write authority** — owns/validates writes, decides conflicts | host, for everything | **per object** (the change) |
| (b) **Sequencer** — assigns global LSNs / total order | host | *can stay host* |
| (c) **Durable log + snapshots** | host | *can stay host* |
| (d) **Script execution** | host | moves to clients later (Enu-specific) |

Key insight: **(a) can decentralize while (b) and (c) stay central.** That
intermediate stop — peers own their objects' *writes*, but ops still flow
through the host for global ordering + durability — is **"federated," not pure
p2p.** It keeps transactions + global time-travel working and is a far smaller
step than full decentralization. It is almost certainly the right next stop for
Enu, and probably far enough for a long time.

**The fork you eventually hit** is whether global order survives:

- **Federated (recommended next stop):** host stays sequencer + log forever — it
  becomes "the timeline keeper," not "the decider." Peers get write authority;
  ops still get a global LSN from the host. Transactions + global time-travel
  survive. Small step.
- **Fully decentralized (later, maybe never):** per-object LSN streams, no global
  order. True p2p, but transactions + global time-travel degrade to scoped/
  best-effort. Big step.

**Four "cheap insurance" moves to bake into Phase 1** so the federated step is a
loosened constraint, not a rewrite:

1. **Model `authority` as per-object metadata from day one**, even though it is
   always the host. Route writes through `authority_of(obj)` (currently returns
   the host) — never hardcode "the host." Phase 6 = changing what that returns.
2. **Make reconciliation deterministic**, not "host decides arbitrarily": LWW
   with `(timestamp, peer_id)` tiebreak for values; canonical op-replay for
   collections. Then it converges the same whether host or a peer decides.
3. **Attribute ops to their authority** in the message/source layer, so trust is
   "authorized by the object's authority," not "came from the host."
4. **Keep the sequencer role and the authority role separate in code**, even
   though one peer plays both now.

## Host failover (host drops, ≥1 full replica)

Semi-automatic failover is viable; surviving clients adopt the new host's state.

- **Detection:** peers heartbeat the host; timeout ⇒ considered gone. Timeout
  tuning trades failover speed against false positives (a slow host treated as
  dead → split brain).
- **Successor selection:** deterministic among full replicas. Tension between
  *simplest* ("oldest connection / lowest peer-id") and *least data loss*
  ("highest applied LSN"). Likely highest-LSN with id as tiebreak.
- **State adoption + rollback wrinkle:** the new host's log is canonical. A
  replica that optimistically applied ops *past* the new host's frontier (ops
  the dead host sequenced but did not finish broadcasting) must **truncate/roll
  back** to the new host's last LSN. So clients adopt the new host's state, with
  possible loss of the last few in-flight ops (acceptable under our tolerance) —
  but the rollback machinery must exist.
- **Epoch/term (the one piece of consensus hygiene worth stealing):** bump a
  monotonic `epoch` on every host change; tag every op with `(epoch, lsn)`;
  higher epoch wins. Prevents a **zombie host** (slow host returns and resumes
  sequencing) from corrupting everyone. Cheap now, painful to retrofit.

### Failover & reconciliation policy (pluggable) — *decided*

Resolution is **hookable**, with **auto-resolution by default** and a manual
"pick the winner" prompt only as a **last resort** when no automatic winner can
be determined — *not* on every network blip.

- **Two hook points, one policy interface:**
  - **Successor selection** (host dropped → choose new leader): usually no data
    conflict, just pick who leads. (Subsumes the old "successor rule" question.)
  - **Split-brain merge** (two diverged histories rejoin): real conflicting
    writes — this is where "undecidable → escalate to user" lives.
- **Canned policies:** oldest-connection-wins, most-activity/most-writes-wins,
  highest-LSN / longest-log-wins (least data loss), lowest-peer-id (deterministic
  tiebreak), and **escalate-to-user** as an explicit fallback a policy may return.
- **Custom hook:** app supplies a resolver `(candidates) -> winner | undecidable`
  over inputs like epoch, applied-LSN / log length, connection age, activity
  metrics, peer id.
- **Default:** auto-resolve; surface a prompt only when the resolver returns
  *undecidable*.
- **Open sub-decision — granularity:** does the winner decide **per partition**
  (whole losing history discarded — simpler, loses more) or **per object**
  (object-by-object merge — saves more, more undecidable cases)? The interface can
  support either; we still need to pick a default. Plausibly per-object for
  optimistic data, per-partition escalation only for `confirmed` objects.

## Sync scopes — where consistency applies

Correction to an earlier oversimplification: `SYNC_LOCAL` is **not** "outside
consistency scope." The flags choose *which transports an object syncs over*, and
**both** synced scopes need consistency:

| Flags | Scope | Consistency? | Transport |
|---|---|---|---|
| neither | thread-local | **No** — the only exempt class | n/a (single thread) |
| `SYNC_LOCAL` | cross-thread, intra-process | **Yes** — two threads can race the same object | reliable, ordered (channels); no partitions |
| `SYNC_REMOTE` (usually + `SYNC_LOCAL`) | cross-network | **Yes** | lossy, reorderable, partitionable (netty) |

Implications:

- **Consistency machinery should be scope-agnostic** — the same LSN / log /
  authority model applies whether "peers" are threads in a process or machines on
  a network. A thread is just a peer with a cheaper, more reliable transport.
- **CAP only bites at the network scope.** Cross-thread has ordered delivery and
  no partitions, so it is the *easy* case — but still multi-writer, so it still
  needs ordering + reconciliation.
- **Authority generalizes to two levels.** *Decided (short term):* the local
  authority is an **appointed leader thread**. For Enu the leader is the **worker
  thread** (it runs the scripts that produce the authoritative simulation) and it
  **wins conflicts**. The two levels compose: a `SYNC_REMOTE` object's global
  authority is the **host's leader thread**; a `SYNC_LOCAL`-only object is
  sequenced by the **local** leader thread. A write routes to that authority, gets
  its LSN, then propagates out across threads and network from there.
- **"Always appoint a leader thread" is a short-term simplification, not a model
  constraint.** Other applications could have thread contexts as **true peers**
  with no appointed leader. The design must keep this door open: treat *"does a
  sequencer exist for this object's authority group?"* as the pivotal property,
  resolved via `authority_of(obj)` — do **not** hardcode "local always has a
  leader." A leaderless scope needs the same **convergence** primitives we already
  plan (LWW-with-tiebreak, op-replay) but loses the single global LSN unless it
  runs distributed ordering. So the peer-thread case is the **local-scope analog
  of full p2p decentralization** — the same global-order-vs-per-object-convergence
  fork. **Key relief:** even peer-threads **don't partition**, so they need
  ordering/convergence but **not** partition tolerance / split-brain.
- **Under the short-term assumption, election/failover is purely a network-scope
  concern** — cross-thread has an appointed leader and no partitions, so all the
  hard availability machinery stays on the network side. Treat this as an
  implementation simplification we build first, with abstractions kept
  **leader-agnostic** so a leaderless/peer scope can be added later.
- **Implementation insight (de-risking):** Phase 1 (LSN + sequencer +
  reconciliation) can be built and tested **entirely cross-thread first** —
  deterministic, no netty — before adding the network's loss/partition
  complications.

## Consistency & durability levels (per object)

These are **two different axes** we had been conflating:

- **Consistency** = ordering/visibility/atomicity guarantees across replicas.
- **Durability** = once acked, does the write survive a crash?

Both become a per-object **ladder**, generalizing `mode` from a bool into a small
enum:

| Level | Consistency | Durability | Cost |
|---|---|---|---|
| 1. Optimistic, memory (default) | may snap back; flicker | lost if host crashes pre-save | fast, lossy |
| 2. Confirmed | authority orders before ack; single-object linearizable, no flicker | loses uncommitted tail on crash | 1 round-trip |
| 3. Confirmed + durable | as above | fsync before ack → survives host *restart* | + disk latency |
| 4. Confirmed + replicated (quorum) | survives host *loss* with no data loss (**CP** for this object) | replicated to k replicas before ack | + round-trips, **blocks under partition** |

Level 4 is **"AP by default, CP opt-in per object."** It also closes the failover
data-loss gap: a quorum-replicated object loses nothing on host loss.

**Reserve now:** make the **commit/ack point first-class** on the write path
("ack after order" vs "after persist" vs "after replicate" = policy on one path),
and make `mode` an extensible level, not a bool.

## Data scenarios (grounded in Enu)

| # | Scenario | Needs | Breaks under |
|---|---|---|---|
| A | Per-player avatar / my-bot edits | optimistic; authority = player | nothing |
| B | Two players recolor the same block | LWW register + deterministic tiebreak | nothing (flicker ok) |
| C | Two players add units to a shared `EdSeq` | op-replay in canonical order | stable-index assumptions (excluded) |
| D | **Shared counter** (score, currency, resource count) | **serialized read-modify-write** at authority | plain LWW → **lost update** (10+1, 10+1 = 11) |
| E | **Transfer** (item inventory A→B) | **atomic multi-object transaction** | non-atomic → item duplicated/vanishes |
| F | **Claim a unique artifact / one-key door** | **serializable** (or single-object compare-and-set) | weaker → **write skew**: two players both claim |
| G | **World invariant** (no two units per cell; total resources = N) | **serializable** transactions | weaker → invariant violated |
| H | **A script reads many objects** (esp. once scripts move to clients) | **snapshot isolation** (consistent view as of one LSN) | weaker → script sees torn state |

- **Requires serializable:** F and G (the **write-skew** anomaly — two txns each
  individually valid, jointly violating a constraint). D needs serialized RMW,
  not full serializability. E needs atomicity + isolation; **snapshot isolation**
  usually suffices.
- **H is the sleeper:** given the goal of clients running scripts, snapshot-
  isolated reads matter — and they are *cheap* if you can reconstruct state as of
  an LSN.
- **Strategic insight:** with a single host sequencer, **serializable is nearly
  free for the host-authoritative subset** (total order already exists). It gets
  expensive only after authority decentralizes (cross-authority serializable
  needs 2PC). ⇒ **Keep must-be-serializable objects (F, G) host-authoritative
  even after per-object authority arrives.**
- **Object exchange without transactions (the inventory case).** Model ownership
  as a **single `owner` field on the owned object**, not as membership in two
  separate inventory collections — inventories become *queries* ("items where
  `owner == me`"). Then a one-way **give = a single-object authorized
  compare-and-set on `owner`** — scenario **F**, not E: the item's authority
  serializes it, so no duplication / double-spend and **no transaction**. Only a
  true **atomic barter** (A↔B swap that must be both-or-neither) needs a real
  transaction (two owner-flips committed together). Most exchange is one-way gives
  or sequential accepts, so transactions stay *nice-to-have*, not required.

### Enu object inventory (current — with caveats)

Caveat: today's Enu is **not** representative of the target. Notably there is no
in-game inventory yet (coming), and Ed is also intended as a **general data
layer** beyond Enu (see next section). So this inventory validates the *model*
but under-samples the harder scenarios (D/F/G), which arrive later.

**Headline finding:** Enu **already event-sources its voxel world** —
`voxels.nim` keeps `packed_chunks` (snapshots) + `chunk_deltas`
(`EdTable[Vector3, EdSeq[DeltaUpdate]]`, an append-only delta log per chunk) and
compacts to a new snapshot at `MAX_DELTAS_BEFORE_SNAPSHOT`. The global-log
direction generalizes a pattern Enu already trusts. `chunk_deltas` is also a
concrete **nested-Ed / lazy-materialization** case (table of seqs you don't want
all resident).

Classification of the reactive fields found:

| Class | Examples (current) | Treatment |
|---|---|---|
| **Cross-thread only** (`SYNC_LOCAL`) | `Unit.collisions`, `Unit.sight_query`, `Unit.eval`, `*.local_flags`, `Player.block_log_entries`; likely the `net_*`/`voxel_tasks` telemetry | **still needs cross-thread consistency** — just not network sync. Truly exempt = objects with *neither* flag (see Sync scopes). |
| **Plain optimistic LWW registers** (the fast-snap majority) | `Unit.{code,velocity,transform,glow,shared}`; `GameState.{player,open_unit,config,tool,open_sign,level_name,queued_action,status_message,...}`; `Player.input_direction` | optimistic, snap-to-correct. **This is most data.** |
| **Collections** (op-replay, per-tick order) | `GameState.units : EdSeq[Unit]`; `console.log : EdSeq[string]`; `packed_chunks`/`chunk_deltas`; `*_flags` sets | op-replay in canonical order; id/position-keyed. `chunk_deltas` is the concurrency hotspot (two builders, same chunk → LWW per voxel cell). |
| **Counters (D)** | none genuinely shared today (`voxel_tasks`/`net_*` look local/derived) | expect with inventory/economy (currency, scores, resource counts). |
| **Unique-claim (F)** | `Unit.owner` / sign ownership (`players.nim`); `open_unit`/`open_sign` as an edit lock | host-arbitrated today; the F candidates. |
| **Invariants (G)** | none hard today (voxel occupancy is LWW-per-cell, not a transaction) | expect with richer game/app rules. |
| **Snapshot-iso reads (H)** | script execution (`worker.nim`, `host_bridge`) reads `units` + world state | the future-critical one once scripts move to clients. |

Takeaways: (1) the **optimistic LWW + per-tick collections** model covers the
overwhelming majority of *current* Enu state; (2) `SYNC_LOCAL` fields still need
**cross-thread** consistency — only *no-flag* objects are exempt; (3) the genuinely
hard scenarios (D/F/G) are mostly *future*, driven by inventory + the general-
data-layer goal, not present today; (4) the voxel delta-log is both prior art for
the global log and the first real concurrency hotspot.

### Planned near-term features — first-pass classification

All vague, all confirmed **not** transaction-hairy. Classification:

| Feature | Data / writer | Trips | Treatment |
|---|---|---|---|
| **Script persistence** (0.3 course progress) — KV maps on a unit, one `SYNC_LOCAL` + one `SYNC_REMOTE` | per-unit KV; **single writer** (the unit's script on the leader thread) | none — even a `map["x"] += 1` is safe (single writer, no contention) | **optimistic, but durability-sensitive.** The real need is *don't lose progress* (durability), not consistency. First near-term feature that wants durable persistence. Maybe servable incrementally on Enu's **existing save path** + an `EdTable`, independent of the big refactor. Nested-Ed (table on a unit) → relevant to partial sync. |
| **Games** (multiplayer tic-tac-toe, tetris) — host owns data; other scripts update but there is always a clear owner/winner | host-authoritative game state | **F** (claim a cell / spot), occasionally **D** (shared counters e.g. tetris garbage), all **host-serialized** | **host-authoritative optimistic + per-cell CAS.** This is exactly the single-authority model. "Clear owner/winner" = host arbitration → serializable-for-free. **First real use of `confirmed` mode = "make a move"** (don't render an unaccepted/illegal move). No transactions. |
| **Action loops → AI agents / NPCs** (e.g. bot notified on script error, suggests a fix) | per-agent state-machine state (single writer); error/events (single producer, fan-out) | none typically; **F** if agents contend for a resource (owner-CAS) | **optimistic + reactive events** (the existing `track` mechanism). Reinforces **H** (snapshot reads) *once agents run off the leader thread*. No transactions. |
| **(Long-term) Roblox-like ecosystem** — sell assets, publish worlds | balances, asset ownership, sales | **D + F + E** (real transactions) | the genuine future transaction driver (marketplace). Aligns with #11: **reserve, don't build.** ~20% of the way there. |

**What this means for the design:**

1. **No near-term feature needs transactions** — confirmed. They stay Phase 5+.
2. **Durability, not consistency, is the first hard near-term requirement**
   (script persistence): single-writer, optimistic, but must-not-lose. ⇒ the
   **durability ladder + persistence (Phase 2)** earns near-term priority; the
   conflict/reconciliation machinery is *less* urgent because near-term
   contention is low and host-arbitrated. (Persistence may even land incrementally
   on the existing save path, unblocking 0.3 without the full refactor.)
3. **CAS-on-a-field (F) is the workhorse** for every "exactly one winner/owner"
   case — game cells, item ownership, resource claims — not transactions.
4. **`confirmed` mode's first concrete use is game moves.**
5. **H (snapshot isolation) recurs**, always gated on compute moving *off* the
   leader thread (agents/scripts on clients) — medium-term.

## Ed beyond Enu (general data layer)

Ed is intended to be a reasonable data layer for non-game apps too (eventually
web apps), with — in the very distant future — a **read-only SQL interface** for
visibility. Implications for *this* design:

- **Multi-instance app servers map cleanly onto the model:** N app-server
  instances = full replicas; the "host" generalizes to a **primary**. The
  consistency/durability ladder and failover story carry over unchanged.
- **Don't over-fit to game semantics.** General apps make D/F/G first-class:
  shared counters (likes, balances), uniqueness constraints (usernames, slugs),
  multi-object invariants. ⇒ **Transactions are a real eventual requirement, not
  "maybe never"** — keep the Phase-5 framing reserved from the start.
- **SQL read interface ⇒ two things we already want:** (a) **snapshot-isolated
  reads** (a consistent view as of one LSN) — reinforces "state-as-of-LSN is
  first-class"; (b) **runtime type/schema introspection** — a *third*
  justification for the `TypeSchema` work (after partial-subscriber forwarding
  and log versioning).

## Optimistic write lifecycle & ack callback

The two primary patterns are **fast local (optimistic, snap-to-correct)** for
most data, and **slow fully-ack'd (confirmed)** for the few critical objects.
For the fast pattern we also want to **know when an optimistic local write has
been ack'd / become canonical** — a commit callback.

Design notes:

- This is distinct from the existing `track`/change callbacks (which fire on
  *value change*). It fires on **commit outcome** for a specific write.
- The outcome is richer than a bare ack — report **confirmed-as-is** vs
  **corrected-to(X)** (your optimistic value held, vs it was superseded/snapped
  to another value). That distinction is exactly what a UI wants ("saved" vs
  "your edit was overridden").
- **Reserve now:** every optimistic op carries a **client-generated op id**; the
  authority echoes it back in the ordered/committed message so the originator can
  correlate the ack and fire the callback. Correlation can also key off "the LSN
  that subsumes my op reached my frontier." Cheap to add to the op/message format
  now; annoying to retrofit.
- API shape is open (a handle returned from the setter? `set(x, on_commit=...)`?
  a per-object `track_commits`?) — see open questions.

## CAP & database tradeoffs — reserve-now checklist

The axes worth holding in mind, each with a now/later verdict:

1. **CAP** — *decided:* AP default, CP opt-in per object. Reserve the mechanism
   (epoch + future quorum); defer quorum itself.
2. **PACELC** — even with no partition, stronger consistency costs **latency**.
   Optimistic = "else latency," confirmed = "else consistency." Confirms the
   per-object knob is the right shape.
3. **Consistency model** (distinct from isolation): eventual → causal →
   sequential → linearizable. Host-as-sequencer gives **sequential consistency
   for free** on the ordered subset. *Now-relevant:* **causal delivery at the
   partial boundary** — a partial replica could receive op B (references op A's
   object) without A. *Reserve the rule:* never apply an op referencing state
   past your LSN frontier; hold it pending.
4. **Durability spectrum** — memory / fsync / quorum (the ladder above). *Now:*
   first-class commit point.
5. **Delivery semantics** — the LSN gives **idempotent-by-LSN apply** (re-applying
   LSN N is a no-op), making replay-on-reconnect and failover-truncation safe.
   *Now:* design every op idempotent under replay; record applied LSN.
6. **Clocks** — wall-clock LWW tiebreak invites **clock-skew bugs**. *Now:* LSN
   (logical order) is the **ordering truth**; wall-clock is only a tiebreak hint,
   never the ordering authority. (HLC exists if wall-clock-meaningful causal
   order is ever needed — likely never, with a sequencer.)
7. **Membership / failure detection** — heartbeats + epochs. *Now:* epoch on host
   identity (see Failover).
8. **Compaction / snapshots** — bounds memory + time-travel depth. *Now:* design
   the snapshot format alongside the log.
9. **Schema evolution** — persisted log outlives code (the `TypeSchema` work's
   real home).

### Consolidated "reserve now" set (cheap now, expensive to retrofit)

1. **`(epoch, lsn)` on every op and log entry** — failover hygiene + ordering truth.
2. **First-class commit/ack point** (order → persist → replicate as policy on one
   path); `mode` as an extensible level, not a bool.
3. **Idempotent-by-LSN apply** — replay & rollback safety.
4. **Log entry reserves `txn_id` + commit marker + schema version** — future
   atomic transactions and schema evolution.
5. **State-as-of-LSN reconstructable** — snapshot isolation, time-travel, and
   failover truncation all need it.
6. **LSN = ordering truth; wall-clock only a tiebreak hint.**
7. **`authority_of(obj)` indirection**; keep must-be-serializable objects (F, G)
   host-authoritative even post-decentralization.
8. **Frontier rule:** never apply an op referencing state past your frontier
   (causal safety at the partial boundary).
9. **Client-generated op id on every op**, echoed back by the authority on
   commit — enables the optimistic-write **ack/commit callback** (confirmed-as-is
   vs corrected-to). Reuse for idempotent-by-LSN correlation.

## Roadmap (order matters)

- **Phase 0 — Plumbing (now, low risk).** Rebase `fix/changes-return-detection`
  onto main (currently ~16 behind). Land forwarding partial subscriber. Defer /
  re-aim the schema work.
- **Phase 1 — Keystone: global LSN + sequencer.** Host stamps monotonic LSNs;
  ordered in-memory log; gap-detection + replay request; reconciliation (LWW
  snap for values, op-replay for collections). Add per-object `mode`
  (optimistic/confirmed) and `authority` (always = host for now). Delivers
  eventual consistency + "snap to correct value."
- **Phase 2 — Durable log + snapshots.** Persist the ordered stream; snapshot
  for compaction; schema-versioned log format. Full-replica time-travel/replay
  falls out — prototype early as a debug/replay tool to validate the design.
- **Phase 3 — Interest-based partial sync.** Subscribe to subsets; filtered,
  LSN-tagged delivery; convert presence assertions → lazy-fetch hooks;
  materialize-on-access.
- **Phase 4 — Eviction.** Access tracking + TTL/LRU + unsubscribe. Safe only
  because Phases 1–2 give a durable backing; re-access re-materializes.
- **Phase 5 — Transactions (future).** Atomic LSN batches / commit records at
  the authority; each client applies the slice touching its objects.
- **Phase 6 — Per-object authority / p2p (future).** Generalize `authority`
  beyond the host; ownership transfer; bully-style re-election. Opt-in
  `confirmed`/transactional objects route through a coordinator when present.

## Open questions / research

1. **Optimistic vs confirmed boundary** — *near-term answer (resolved):*
   optimistic-dominant. The only stricter near-term needs are (a) **durability**
   for script persistence and (b) **`confirmed`/CAS** for game moves and
   ownership. No transactions short-term. Revisit when features get concrete.
   (See "Planned near-term features.")
2. **Persistence/snapshot format + schema evolution** — the home for the schema
   work.
3. **Reference/causal integrity across the partial boundary** — exact semantics
   for "op references an object I don't hold" (fetch? defer? drop?).
4. **Access-tracking cost** — measure before committing to eviction design.
5. **Authority handoff protocol** — detection + deterministic reassignment;
   what state must transfer.

### Decisions still needed from Scott (before/early in capture → build)

6. **Split-brain merge policy** — *resolved:* pluggable policy, auto-resolve by
   default, escalate to user only when undecidable (see Failover & reconciliation
   policy). *Remaining:* per-object vs per-partition granularity + the default.
7. **Failover UX (seamlessness)** — must failover be seamless (game keeps running,
   needs tentative-state buffering) or is a brief "reconnecting…" pause
   acceptable? (The *resolution* half is resolved; this *liveness* half is open.)
8. **Concrete Enu object inventory** — *first pass done* (see "Planned near-term
   features"): near-term work is optimistic + a little F/durability; D/G/E are
   long-term (marketplace). *Remaining:* re-classify each feature as it gets
   concrete, especially `confirmed` boundaries for games.
9. **Successor selection rule** — *folded into* the pluggable policy (canned:
   oldest / most-activity / highest-LSN / lowest-id). *Remaining:* pick the
   default canned policy.
10. **Ack/commit callback API shape** — handle returned from the setter vs
    `set(x, on_commit = ...)` vs a per-object `track_commits`; and how it reports
    confirmed-as-is vs corrected-to(X).
11. **General-data-layer priorities** — *resolved:* far off / low priority. Do
    **not** build transactions now; only avoid *precluding* them — keep the
    reserve-now items (`txn_id` + commit record + schema version). Object exchange
    (inventory) is handled by single-object `owner` CAS (scenario F), so no
    short-term feature requires transactions. Stays Phase 5+.
