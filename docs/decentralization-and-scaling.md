# Decentralization, Scaling & Serialization — the road to distributed enu

> Status: **living design doc.** Sets direction; commits to little now. Companion
> to `consistency-and-partial-sync-plan.md` (the data-layer mechanics — roles,
> reconciliation, partial sync) and `persistence.md` (the durable store). This
> doc is the layer *above* those: how enu goes from a single host to distributed,
> community-hosted, long-lived worlds, and what that path implies for trust,
> network topology, and serialization.

## The end goal (decided)

enu worlds become **git-hosted and long-lived**: an ed project is a git repo,
git is the durability + distribution layer (cold worlds sit in the repo; a joiner
pulls the latest and claims authority), and the mesh is the live-sync layer.
Worlds outlive the code that made them. Scale target is **hundreds to low
thousands** of concurrent players in a large level, reached with **relay trees**
(distribution) + **spatial interest management** (relevance) — the latter an enu
concern, not an ed one. Trust is **cooperative**: we defend against malformed
input (security) but not against authorized players gaining game advantage
(cheating). The authority model targets **Model 1** (single sequencer, but
replaceable / serverless) with **Model 2** (federated per-object authority) left
open as a later stop; Models 3–4 are rejected (below).

## Three independent dials, not one "P2P" switch

"Trustless P2P" bundles three *separable* choices. enu wants a different setting
on each, and conflating them is what makes decentralization sound scarier — and
more DX-damaging — than it is.

1. **Deployment** — dedicated always-on server ↔ serverless (any peer, or a git
   repo, can host). *"Do I need a box?"*
2. **Ordering / authority** — one global sequencer ↔ per-object owners ↔ no global
   order (leaderless). *"Who's the referee?"*
3. **Trust** — cooperative (believe messages) ↔ authenticated (verify identity) ↔
   Byzantine (assume lies, prove everything). *"Do I trust the other players?"*

The DX fear — "won't P2P break the cross-object ordering enu depends on?" — lives
**only on dial 2, only at its far end.** You can go serverless (dial 1) while
keeping a single global order (dial 2 near end). Losing ordering is a *separate*
choice from losing the server. That decoupling is the load-bearing insight of
this whole doc.

## Authority & trust models

Built on the four separable roles from the plan doc (write-authority, sequencer,
durable-log, script-execution). Single-host is the degenerate case where all four
sit on one node.

| Model | Referee (ordering) | Server needed? | Cheating stance | enu fit |
|---|---|---|---|---|
| **0. Single host** (today) | one host, global LSN | yes, dedicated | host validates all | *is* enu |
| **1. Failover / git-hosted** | one host at a time, global LSN | no — any peer or a git repo | host validates | drops in, mostly reserved |
| **2. Federated** | per-object owners; host still sequences | host as sequencer only | trust peers re: their own objects | moderate, bounded |
| **3. Leaderless (CRDT)** | no global order; per-object causal | none | cooperative | **major rethink** |
| **4. Byzantine** | consensus, trust no one | none | cryptographically enforced | different genre |

**Model 1 is the target.** Still one authority with a global LSN at any moment —
so cross-object order stays free and every enu dependency (ref-graph
parent-before-child, script snapshot reads, per-tick collection order) is
untouched. What changes is that the authority is *replaceable*: peers detect a
dropped host, deterministically pick a successor, and the `epoch` (shipped in
Phase 2) bumps so a returning zombie host can't corrupt anyone. The git variant
*is* the git-hosting goal — the repo is the durable log, first joiner claims
authority via a ref-CAS. Assumptions changed vs today: "authority is fixed" →
"authority is replaceable," plus liveness detection and rollback of in-flight ops
past the new host's frontier. See the plan doc's Host-failover section for the
mechanics. **Fits without app changes.**

**Model 2 is the later stop, kept open, not built.** Peers own the *writes* to
their own objects (a client owns its avatar/bots) while ops still flow through the
host for the global LSN and durability — "federated," host as timeline-keeper not
decider. Global order, transactions, and time-travel all survive. The plan doc's
four reserve-now items (`authority_of(obj)` indirection, deterministic
reconciliation, attribute-ops-to-authority, keep sequencer/authority roles
separate) are what keep this a *loosened constraint* rather than a rewrite.
**Important correction:** Model 2 does **not** relieve the sequencer — the host
still stamps every ordered op. It relieves *compute* (validation is per-owner) and
improves *DX* (local ownership). Don't reach for it expecting a throughput win;
reach for it for ownership.

**Models 3–4 are rejected.** Leaderless (3) is exactly the DX-killer the ordering
intuition fears: you lose free global cross-object order, transactions need 2PC,
data types are constrained to commutative CRDTs, and memory runs 2–4× — all to buy
leaderless convergence enu doesn't need because it has a host. Byzantine (4) is a
different genre (signed ops, consensus latency, huge complexity) for a cooperative
sandbox; even the far-future marketplace would answer cheating with host
validation, not consensus.

## Trust posture (decided: cooperative)

The security-vs-cheating line is Ed's existing "strict on the envelope, forgiving
on the payload" principle, extended one layer up. The two threats live at
different layers, so the defenses do too:

- **Security — defend (already done).** A client sending *malformed bytes*
  (hostile length prefixes, version-skewed packets, garbage that could crash or
  corrupt). Covered by the wire hardening: magic+version gate, bounds-checked
  decode, drop-the-connection, and the `epoch` upstream-gate. Keep all of it.
- **Cheating — ignore.** A client sending *well-formed but game-illegal* ops
  (teleport, spawn an item). We believe it. No server re-validation, no
  re-simulation, no sandboxing of client script output.

**What cooperative trust unlocks — the traffic split.** Trusting clients lets
high-frequency traffic bypass the central path entirely, which is the single
biggest scaling lever after interest management:

- **Sequenced shared core** — genuinely contended, multi-writer state (two people
  editing the same voxel cell, shared counters, unique claims, structural changes
  to the units list). Needs global order → flows through the host sequencer. Lower
  frequency.
- **Trusted client-owned ephemera** — avatar movement, transient effects, your own
  bots. *Single-writer* (you own them) → no write conflict to order, just converge
  and deliver. Because you're trusted, these can flow owner → relay/neighbors with
  the sequencer **out of the loop** — no central validation to launder through.

The second class is the bulk of high-frequency traffic. Ed doesn't do this bypass
today (everything routes through the authority for its LSN); trust is the
precondition that makes adding an "unordered, owner-distributed" object class
*viable* rather than reckless. Building it is future work.

**What cooperative trust does NOT remove:** input hardening (above); admission
control at the session boundary (*which* clients are let in — a separate mechanism
from anti-cheat, still needed); and the `from_upstream` / epoch upstream-gates —
which are **correctness**, not anti-cheat: they answer "who is *authoritative* over
this object's state," keeping convergence well-defined and stopping accidental /
malformed clobbering regardless of trust.

**What it takes off the table:** signatures/identity on ops, cryptographic state
proofs (→ confirms SSZ stays out, below), server re-validation of client moves
(thinner host), and sandboxing client script output (→ "scripts on all clients"
gets much cheaper — client compute is simply trusted).

## Scaling & topology

**Sequencing is cheap; distribution is the wall.** Assigning an LSN is an integer
increment + rebroadcast — one node orders millions/s; it will never be the
bottleneck. The bottleneck is *distributing* each op to every interested
subscriber. `fanout` already serializes a body once and reuses it, so the
authority's *CPU* is fine; its *uplink* saturates. Worst case is quadratic — 100
clustered players moving at 30 Hz, each relayed to ~99 others at ~100 B ≈ **30 MB/s
uplink** — which no home connection hosts. Everything below attacks that number.

Two escape hatches, both already latent in Ed:

- **Spatial interest (relevance) — an enu concern.** Players in different areas
  don't need each other's ops. Ed's partial replicas + interest sets are the
  substrate; the *spatial policy* (subscribe to what's near me, drop what's far, as
  I move) is app-level and lives in enu. Turns fanout from O(all players) into
  O(neighbors). **Highest-leverage unbuilt feature; the substrate is ready.**
- **Relay trees — distribution as a tree.** The hub / request-chaining primitive
  (a hub that can't serve a request forwards upstream and relays the answer) is the
  seed. The authority sends to a handful of full-clone relays, each fanning to a
  subset; its uplink becomes O(relays), not O(clients). The sequencer role stays
  central (global order intact) while *distribution* fans out. Primitive exists; a
  full relay tier is unbuilt.

**Ceilings (order-of-magnitude):** star + home host ≈ low **hundreds** spread out;
star + cloud uplink ≈ low **thousands**; relay tree (host still sequences) ≈
**thousands+**, at which point the ceiling shifts to the *sequencer's ordered-write
rate* — kept high by keeping globally-ordered state small (client-owned and
LWW-per-cell state don't need it). Beyond that you **shard the sequencer**
(per-region authority, independent LSN streams) — the plan doc's stated trigger
"write throughput hits the single sequencer's ceiling." The one limit no topology
fixes: **dense clustering is inherently N²** (500 players in one room all see each
other); the answer is *degradation* (distance-based update-rate scaling, network
LOD), not routing. Per-tick coalescing already does part of it.

## State roots without SSZ

We want cheap **integrity**, whole-state **equality** ("do two replicas agree?"),
and localized **divergence** detection — but *not* the one thing SSZ uniquely adds
(cryptographic inclusion proofs), because that's only worth its cost under
Byzantine trust (Model 4), which we've ruled out. SSZ also fights Ed's ref-graph /
placeholder object model. So: **no SSZ.**

Instead, build on one primitive — a **stable per-object content hash** (the hash of
an object's serialized bytes, under whatever serializer):

- **Whole-state root:** combine per-object hashes into one digest, maintained
  incrementally at the op choke point (XOR is the cheap trick: `root ^= old ^ new`
  per mutation — order-independent, O(1), no re-scan). Compare one number for
  "are these replicas identical." *Caveat:* XOR catches **accidental** divergence
  (our actual threat model), not an adversary crafting collisions.
- **Localized divergence:** an `id → content_hash` map; a mismatch points at the
  exact object — the granularity Ed already reconciles at, simpler than a tree.
- **Whole-snapshot integrity + content-addressing:** git already Merkle-hashes the
  committed snapshot directory — the tree SHA *is* the snapshot's root, for free,
  once the git layer lands. crc32 stays for torn-write detection.
- **Upgrade path if ever needed:** an id-keyed Merkle tree over the per-object
  hashes you already maintain — a small addition, not a format rewrite — reached
  only if the trust model changes (same fork that would justify SSZ).

## Serialization & schema evolution

**Decision: a single serializer, and flatty retires at the cutover.** flatty is
fine as a compact positional codec but wrong as a *durable/evolving* format
(positional + name-hashed `tid` → a type change silently corrupts or safe-fails
with loss). The forcing function is the end goal: git-hosted **long-lived** worlds
outlive the code, so schema evolution moves from "nice, defer" to *eventually
mandatory*. We adopt **nim-serialization** (already partly in the tree via
`json_serialization`; designed for "one type, many wire formats") for the durable
path, and at that same cutover move the hot path onto it too rather than straddle
two serializers. **Contingency (the only reason to keep a second codec):** validate
nim-serialization's binary backend meets the voxel hot path's compactness/speed at
cutover; only if it can't — not expected — would a compact codec survive there.

**Keep and extend the type registry — it is the asset.** It does four jobs; only
one is flatty-coupled:

1. **Ed-field semantics** — nil non-synced refs/ptrs/procs, blank `ed_ignore`,
   relink Ed-fields *by id*, and `revive`/converge. Irreplaceable, codec-independent.
2. **Type dispatch** — reconstruct the right concrete type from a `tid` + bytes.
3. **Capability negotiation** — which `tid`s a peer can materialize.
4. **Codec calls** — the only flatty-coupled part; swap the `to_flatty`/`from_flatty`
   inside stringify/parse for nim-serialization.

So the registry survives as "Ed-semantics + schema + dispatch, delegating raw bytes
to the codec," and becomes the natural home for a **per-type field descriptor** (the
schema). The `tid = hash(name)` structure-blindness is a `tid` defect, fixed by
having the registry emit that descriptor — not a reason to drop the registry.

**What the schema (TypeSchema) unlocks**, priority order:

| Use case | Need |
|---|---|
| Saved worlds survive enu updates (a v2 build reads a v1 world) | **needed** — direct consequence of git-hosted long-lived worlds; without it every type change breaks saved worlds |
| Mixed-version / rolling play (v1 and v2 clients interoperate) | **needed-ish** — community-hosted worlds are never version-synchronized |
| Human-readable, git-diffable persisted state | nice; strong DX + git-vision fit; uses the store's reserved `codec` seam |
| Introspection / tooling / eventual read-only SQL view | nice, later |
| Cross-language / non-Nim clients | far future (general-data-layer ambition) |

The top two aren't speculative — they fall directly out of the end goal. That's why
the switch is *eventually mandatory* rather than optional.

**Timing.** Cheap safety half **now**, independent of the switch: stamp a
schema/build fingerprint into the manifest's reserved `schema` slot and have
`open_store` refuse-or-warn on mismatch, so Phase 2 fails *clearly* instead of
silently dropping objects. The full nim-serialization + field-schema cutover is
triggered by the durable need — when saved worlds start breaking across updates, or
mixed-version play becomes real — and drops flatty in one move.

## Sequenced roadmap

Ordered by dependency and trigger, not calendar.

1. **Now / cheap, no trigger:** manifest schema-fingerprint gate (safe-fail on
   incompatible store); keep the reserve-now items from the plan doc honored.
2. **Model 1 — failover / git-hosting.** Liveness detection, deterministic
   successor, frontier-rollback, git-as-log + ref-CAS host claim. Delivers the
   serverless goal; ordering + DX untouched. The next big infrastructure step.
3. **Scaling tier.** Spatial interest management (enu-side, substrate ready — do
   first, highest leverage) + relay tree (ed-side, hub primitive exists). Together:
   thousands of players.
4. **Serializer cutover.** nim-serialization for durable path + hot path, flatty
   retired, registry extended with the field schema. Triggered by schema-evolution
   need (long-lived worlds breaking across updates / mixed-version play).
5. **Traffic split.** An "unordered, owner-distributed" object class so trusted
   client-owned ephemera (movement, effects) bypasses the sequencer — the big
   headroom win, safe only under cooperative trust.
6. **Model 2 — federated authority (if/when needed).** Per-object write authority
   for ownership DX and distributed compute; sequencer stays central. Reach for it
   for ownership, not throughput.
7. **Sequencer sharding (far / maybe never).** Per-region authority when a single
   world's ordered-write rate is the wall.

State roots (per-object content hash + XOR digest + id-map) slot in wherever
divergence detection or snapshot integrity first pays off — cheap, incremental,
serializer-agnostic.
