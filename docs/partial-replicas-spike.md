# Partial Replicas — Design Spike

> A context should only hold the objects it actually uses. Nested `Ed` objects
> (e.g. the `EdTable`s inside an `EdSeq[EdTable]`) shouldn't exist in memory until
> reached, and should materialize on access. This is Phase 3 of
> `consistency-and-partial-sync-plan.md`. Eviction (dropping idle objects) is a
> later phase — it needs a durable backing; plain partial sync does not.

## How sync works today (the things partial replicas must change)

- **Full push on subscribe.** `add_subscriber` (`subscriptions.nim`) iterates
  **every** object in the context and `publish_create`s it to the new subscriber
  (minus ones it says it already has). A new subscriber gets the whole world.
- **Nested `Ed` objects are independent, id-referenced objects.** An
  `EdSeq[EdTable]`'s elements are separate `Ed` objects in `ctx.objects`, keyed by
  id; the seq's ops reference them by `change_object_id`, and each element syncs
  as its own object (its own `CREATE` + ops). So the *entire object graph* syncs
  eagerly.
- **Presence is asserted, not fetched.** `change_receiver`'s nested paths require
  the referenced object to be resident:
  - `when O is Ed:` → `assert object_id in self.ctx` (`initializers.nim:177`).
  - `when O is Pair[auto, Ed]:` → looks up the value by `change_object_id`
    (`initializers.nim:194`).
  We relaxed *some* missing-object/unknown-type sites to **skip** (the robustness
  pass); partial sync turns those skips into **materialize/fetch** hooks.
- **Fanout goes to all subscribers** (`publish_changes` → `fanout` over
  `self.ctx.subscribers`). No per-object filtering.

## The model: reference-driven lazy materialization

Per the original framing: not explicit interest lists, but **the reference graph**
drives what's held. A context syncs a few **roots**; nested `Ed` references are
**lazy handles** (id + type, not resident) until reached; accessing one
**fetches** it (current state + subscribe to its future ops). Your "interest set"
is implicitly *what you've reached and not yet dropped*. Fits Enu's graph
(GameState → units → builds → chunks) and matches the voxel snapshot+delta load.

A handle is **typed** for free: the element type is the container's `O`, so a
not-yet-materialized `EdSeq[EdTable]` element is a placeholder `EdTable` with a
known id — no schema needed. (The parked `EdDynamic`/`create_dynamic_placeholder`
work is the *placeholder-without-broadcast* mechanism to reuse here; only its
unknown-type schema part is unneeded, since `O` gives the type.)

## The pieces (and where they plug in)

| Piece | What / where |
|---|---|
| **Per-subscriber interest set** | A `HashSet[string]` of object ids on each `Subscription` — what that subscriber holds/wants. The authority consults it for both the initial push and ongoing op delivery. |
| **Roots / bootstrap** | `add_subscriber` pushes only a designated **root set** (explicitly-subscribed/created objects), not all objects. The reference graph discovers the rest. A client needs ≥1 root to start. |
| **Op delivery filtering** | `fanout` (and `add_subscriber`) send an object's ops only to subscribers whose interest set contains its `object_id`. The hot change for "only sync what you use." |
| **Lazy handle** | On receiving a container op that references a non-resident nested `Ed` (`change_object_id`), create a typed placeholder (`O` with that id, not broadcast) instead of asserting — the `assert object_id in self.ctx` sites become handle-or-fetch. |
| **Fetch protocol** | New message exchange: subscriber → authority **REQUEST(object_id)**; authority → subscriber the object's `CREATE` + current state, and adds it to that sub's interest set so future ops flow. Mirrors the existing SUBSCRIBE/ACK handshake. |
| **Materialize-on-access** | The container's access paths (`items`/`[]`) detect a lazy handle and kick off a fetch **once**; the handle fills in asynchronously and fires a change. |

## Implementation status (this session)

**Done & tested** (opt-in, non-breaking — default is still a full replica):

- **P3a — interest sets + filtered delivery.** `Subscription.partial` +
  `interest`. The filter is applied in all three send paths: `add_subscriber`
  (initial push), `fanout`/`publish_changes` (ongoing ops), and `publish_create`
  (new-object broadcasts). `subscribe(ctx, partial = true, roots = @[...])`.
- **P3b — fetch protocol.** `REQUEST` message + `EdContext.fetch(id)`; the
  authority adds the id to that subscriber's interest and `publish_create`s it.
- **Gap fixes:** post-subscribe creations are filtered (not just the initial
  push); a partial client's **own** created objects auto-join its interest on the
  authority, so its writes get return-to-source/convergence.

So a context can now subscribe to a subset, receive only that subset's ops, and
**explicitly** pull more on demand with `fetch` — the core of partial replicas.

**Done & tested (later session) — capability handshake + materialize-on-access:**

- **TID capability handshake** (`Subscription.capabilities: HashSet[int]`). On
  subscribe a peer advertises its registered `type_initializers` tids; the
  authority filters every send (`publish_create` send_msg + `fanout`) so a peer
  **never receives an object it can't construct**. type_id == 0 (DESTROY/control)
  is exempt. Empty set = unfiltered (same-build/local/older peer). See
  `ref-registration.md` for the crash this prevents. (`capability_tests.nim`)
- **Placeholder primitive.** `EdBase.placeholder` + `loaded` predicate (option-1
  model: empty stand-in, queryable loaded-bit). `Ed.init_placeholder` — a
  non-broadcasting typed constructor (`defaults(..., broadcast = false)`). The two
  `assert object_id in self.ctx` deserialize sites (`when O is Ed` / `Pair[auto,
  Ed]`) now create a placeholder instead of asserting. Fill clears the bit in all
  restore paths. `fetch` no longer early-returns on an unloaded placeholder.
- **Materialize-on-access.** `EdContext.materialize` proc field, wired at subscribe
  time (it needs `fetch`/`tick`); the read accessors (`value`/`items`/`pairs`/`[]`)
  call it via `touch_placeholder`. Non-blocking: kicks a `fetch`, returns empty
  now, fills on a later tick. Blocking: `EdContext.blocking` flag + `blocking:`
  template (manages the flag; settable by hand) — the accessor pumps `tick` until
  the object fills, **bounded by a 5s deadline** so a gone authority can't hang the
  caller. (`materialize_tests.nim`)

**Done & tested — silent materialize + change tagging:**

- **`Change.reason: ChangeReason` (Normal | Initial | Fill)** (decision 5, renamed
  from `trigger` to avoid confusion with `triggered_by`). A placeholder fill is
  tagged `Fill` via a `ctx.filling` flag read in `trigger_callbacks`. `Initial`
  reserved (track-time replay not built).
- **Silent materialize** (decision 4). A `blocking:` read now applies **only the
  fetched object**, silently: `ctx.silent` makes `trigger_callbacks` defer its
  callbacks to `ctx.pending_fills`, and the pump buffers every non-target message
  to `ctx.pending_msgs`. Both are replayed at the start of the next explicit
  `tick`, so nothing application-visible happens mid-read (clean reentrancy, and a
  deterministic single-threaded test). (`materialize_tests.nim`)

**Done & tested — remote partial replicas (full network path):**

- **Remote partial subscribe.** `subscribe(address, partial = ..., roots = ...)`;
  the SUBSCRIBE message carries `(capabilities, partial, roots)` and the authority
  builds a filtered subscription from it. Mirrors the local subscribe.
- **Placeholders on initial push.** `from_flatty` for a nested `Ed` ref now
  placeholders a non-resident child instead of leaving it nil — so a partial
  replica receiving a **pre-populated** parent (the real enu_mcp `root_units` case)
  gets correct cardinality, and a full replica that gets a parent before its child
  fills the placeholder when the child's CREATE arrives.
- **Remote silent pump.** `parse_remote` extracted (shared by `tick` and the
  pump — no duplicated wire decode, no `tick` split); the silent pump drains both
  transports and resolves source eagerly so deferred messages process sub-less.
- **End-to-end test:** a remote partial replica subscribes over UDP, gets a
  placeholder for an out-of-interest child, and `blocking:`-materializes it against
  a threaded authority. Stable across repeated runs. (`materialize_tests.nim`)

**Still open:**

- **EdTable shape + per-key access** — `keys`/`loaded`/`unloaded` views (O(1)
  membership), per-key `request`/`release` (release = tree), in-flight dedup.
  Per-key fetch landed; shape sync is the next build. Voxel value types are flat
  (`SnapshotData`/`DeltaUpdate` = `{data}`), so fetch depth ≤ 2.
- **Unmaterialized-handle semantics (revised — see `object-lifecycle-design.md`).**
  Supersedes the earlier `[]` → `Unmaterialized`-on-access plan: object-returning
  access (`ctx[id]`, Ed-valued `table[key]`) returns the handle even when
  unmaterialized; `?obj` = usable; reading the data throws; **listeners are allowed
  on unmaterialized handles** (read not). Materialization fires `ADDED` +
  `reason == Fill`. Value-returning access (`EdTable[_, SnapshotData][key]`) keeps
  loaded / `get(): Option` / blocking. This rides the proxy/body split.
- **`tick` receive/process split** (decision 3) — deliberately *not* done;
  `parse_remote` got the de-duplication win without refactoring `tick`'s hot path.
- **`Initial` reason** — track-time replay of current contents.

## Decisions log (for review)

Resolved with Scott, or gut-calls made during implementation (flagged ⚙️):

1. **Opt-in, non-breaking.** Partial sync is gated; default stays full-push, so
   Enu and existing tests are unaffected. Enabled per-subscription (a partial
   subscribe) and/or a context flag.
2. **Two consumer modes, both plain sync (no async/chronos).**
   - *Game loop:* **placeholder-then-fill** — access returns a handle now, fetch
     in the background, fill fires a change.
   - *Request/response (MCP server, scripts):* **`blocking:` scope** — accesses
     inside it wait for materialization. This matches what `agent.query` already
     does (tick-until-`MCP_DONE`).
3. **`tick` semantics are unchanged.** Split `tick` internals into **receive**
   (pump transport → buffer; no side effects) and **process** (apply buffer → fire
   `changes`, re-broadcast, flush). `tick` = receive + process.
4. **Blocking fetch = receive + *silent* materialize.** Send the fetch request,
   pump I/O into the buffer until the response arrives, apply **only that object**
   silently (no callbacks, no re-broadcast). Everything else — buffered messages,
   the **Fill** callback for the materialized object, outgoing — waits for the next
   explicit `tick`. So nothing application-visible happens outside an explicit
   `tick`; re-entrant blocking access only does I/O.
5. **Initial / Fill callbacks + `Change.trigger`.** On `track`, optionally replay
   current contents as synthetic changes (`Initial`); on materialize, replay as
   `Fill`. `EdValue` fires even for `nil`; an empty collection fires nothing (it
   has no contents to replay). New `Change.trigger: Normal | Initial | Fill`,
   orthogonal to `changes: set[ChangeKind]`. Builds on the existing `changes(bool)`
   initial flag.
6. ⚙️ **Fetch protocol.** New `MessageKind` `REQUEST` (subscriber → authority,
   carries the requested `object_id`); the response is a normal `CREATE` for that
   object (its initializer materializes it), and the authority adds the id to the
   subscriber's interest set so future ops flow. Mirrors SUBSCRIBE/ACK.
7. ⚙️ **Interest is grows-only until eviction (Phase 4).** A partial subscriber's
   interest set only accumulates (roots + fetched ids). No shedding yet, so a long
   session drifts back toward a full replica — acceptable for a first cut.
8. ⚙️ **Bootstrap via explicit roots.** A partial subscriber declares root ids it
   wants; `add_subscriber` pushes those (and, for now, nothing else). The
   reference graph + fetch-on-access pull the rest.
9. ⚙️ **Fetch granularity.** Start one-object-per-request; subtree/region fetch
   (a `Unit` is a ref + several Ed-field objects, so it's really a subtree) is a
   follow-up optimization — flagged by the MCP `Unit` access pattern.

## The crux: access is synchronous, fetch is asynchronous

A game loop reads objects synchronously, but a fetch is a round-trip (cross-thread
tick or network RTT). You **cannot block** the main thread on access. Options:

1. **Placeholder-then-fill (recommended).** Access returns the handle immediately
   (empty/default state) and triggers an async fetch; when it lands, the handle
   populates and a `track` callback fires. The app sees "empty, then real" — the
   standard lazy-load pattern, and it matches Enu's existing chunk
   snapshot/delta loading (a chunk pops in).
2. **Prefetch a region/depth.** Eagerly fetch objects reachable within N hops of a
   root (or within a spatial region) so they're usually resident by access time;
   lazy beyond. Less "pure" but hides latency for hot data.
3. **Blocking fetch.** Simple, but stalls the caller for an RTT — unacceptable on
   the main thread.

Recommendation: **(1) as the default**, with **(2)** as an optional prefetch
policy for hot regions. This is the single most important UX decision — flag for
Scott.

## What this builds on / doesn't need

- **Builds on:** the relaxed validation (a partial replica already tolerates ops
  for objects it doesn't hold) and per-object reconciliation/frontier (delivery is
  already per-object). The parked placeholder mechanism.
- **Does *not* need:** the durable log (Phase 2). The authority is the full replica
  and serves subsets from memory. The durable log is required only for **eviction**
  (dropping objects + guaranteeing re-fetch) and persistence.

## Key decisions to resolve

1. **Async-access model** — placeholder-then-fill vs prefetch-region (above). *The
   big one.*
2. **Roots / bootstrap** — what does a fresh partial client get pushed? (Its own
   objects? A designated shared root the authority always sends?)
3. **Fetch granularity** — fetch one object per access, or a subtree/region per
   request (fewer round-trips for graph-y data like a chunk + its deltas)?
4. **Interest lifetime without eviction** — until eviction exists, does interest
   only grow (never shed)? If so, a long session converges back toward a full
   replica. Acceptable as a first step; eviction (Phase 4) sheds it.
5. **Reference integrity** — an op references object B you don't hold and haven't
   reached: drop (current), create a handle, or fetch? (Probably *handle* — keep
   the structure, fetch on access.)
6. **Authority-side memory** — the authority tracks an interest set per subscriber;
   for many clients with disjoint interests this is the cost of the feature.

## Proposed implementation phases

- **P3a — Per-subscriber interest + filtered delivery.** Interest set on
  `Subscription`; `add_subscriber` pushes roots only; `fanout`/`add_subscriber`
  filter by interest. (Without lazy handles yet — a client explicitly subscribes
  to a known root set and gets exactly that subgraph if it's pushed transitively.)
- **P3b — Lazy handles + fetch protocol.** Typed placeholders for non-resident
  nested `Ed`; REQUEST/response messages; presence asserts → handle-or-fetch.
- **P3c — Materialize-on-access.** Container access kicks off the fetch
  (placeholder-then-fill); change fires on populate.
- **P3d — (later) Prefetch policy** and then **eviction** (Phase 4, needs durable
  backing).

## Risks / unknowns

- The **async-access API** is the hard part — how the app sees "not loaded yet"
  without blocking. Get this shape right first.
- **Reference cycles** and re-entrant fetch (A references B references A).
- **Interest churn** as a player moves (subscribe/unsubscribe storms); needs
  hysteresis/regioning eventually.
- **Bootstrap**: the first root must arrive for the graph to unfold — define how.
- Cross-thread vs network fetch have different latencies but the same protocol;
  validate cross-thread first (per the keystone pattern).
