# Partial Replicas

A context should hold only the objects it uses. Nested `Ed` objects (the
`EdTable`s inside an `EdSeq[EdTable]`, etc.) don't exist in memory until reached,
and materialize on access. Opt-in and non-breaking: the default is still a full
replica (full push on subscribe, every op fanned out), byte-identical to before.

## Model — reference-driven lazy materialization

A partial subscriber declares a few **root** ids; the authority pushes only those.
The reference graph discovers the rest: a container op that references a
non-resident nested `Ed` (`change_object_id`) mints a typed **placeholder** (an
empty stand-in with the right id and type — `O` gives the type for free, no schema
needed) instead of asserting presence. Reading a placeholder **fetches** it. A
subscriber's interest set is implicitly "what it has reached and not yet dropped."

The pieces:

- **Per-subscriber interest** (`Subscription.partial` + `interest: HashSet[string]`).
  The authority filters every send path against it — initial push
  (`add_subscriber`), ongoing ops (`fanout`/`publish_changes`), and new-object
  broadcasts (`publish_create`). A partial client's *own* created objects auto-join
  its interest so its writes get return-to-source/convergence. DESTROY bypasses the
  filter (a peer may hold self-minted placeholder ids the authority never learned).
- **Fetch protocol.** `REQUEST(object_id)` → the authority adds the id to that
  sub's interest and `publish_create`s it; future ops then follow. `EdContext.fetch`
  drives it. Mirrors the SUBSCRIBE/ACK handshake.
- **Placeholder primitive.** `EdBodyBase.placeholder` + the `loaded` predicate
  (distinguishes "exists but not loaded" from "exists and genuinely empty");
  `Ed.init_placeholder` is the non-broadcasting constructor. A fill clears the bit
  in every restore path and on `from_flatty` of a pre-populated parent (so a
  partial replica receiving a populated parent gets correct cardinality, and a full
  replica that sees a parent before its child fills the placeholder when the child's
  CREATE lands).
- **Materialize-on-access.** `EdContext.materialize` (wired at subscribe time —
  it needs `fetch`/`tick`) is called by the read accessors via `touch_placeholder`.

## Capability handshake

A subscriber advertises its materializable type-ids (its registered
`type_initializers`) on SUBSCRIBE; the authority skips any object whose `type_id`
it isn't in `capabilities`, so a peer **never receives an object it can't
construct** (which would crash or silently corrupt on deserialize — flatty is
positional). `type_id == 0` (DESTROY/control) is exempt. An empty set means
unfiltered — a same-build/local peer or one with no handshake — preserving the
full-replica default.

This depends on the rule that **synced `ref object` payloads must be registered**
with `Ed.register(T)` (value types never need it). An unregistered ref fails late,
on a peer, with a misleading error or silently; the handshake turns that into a
clean "I can't hold this type, don't send it." *(Future: derive capabilities from
the types a consumer actually accesses, not just every tid it can construct — a
tighter interest signal; research only.)*

## The crux: access is synchronous, fetch is asynchronous

A read happens now; a fetch is a round-trip (cross-thread tick or network RTT).
The two consumer modes (see `SyncMode`):

- **`PARTIAL_ASYNC` — placeholder-then-fill (game loop).** Access returns the empty
  placeholder immediately and kicks a fetch; when it lands the placeholder fills and
  a change fires (tagged `Fill`, via the `ctx.filling` flag read in
  `trigger_callbacks`). The standard lazy-load pattern; matches enu's chunk
  snapshot/delta loading.
- **`PARTIAL` — blocking (request/response: MCP, scripts).** A read inside a
  `blocking` scope pumps `tick` until the object fills, **bounded by a 5s deadline**
  so a gone authority can't hang the caller (then it falls back to the empty
  placeholder).

**Silent materialize** keeps the blocking read clean: it applies *only* the fetched
object, silently — `ctx.silent` makes `trigger_callbacks` defer to
`ctx.pending_fills`, and the pump buffers every non-target message to
`ctx.pending_msgs`. Both replay at the start of the next explicit `tick`, so nothing
application-visible happens mid-read (clean reentrancy; deterministic single-thread
tests). `parse_remote` is shared by `tick` and the pump, so the wire decode lives in
one place (no `tick` receive/process split was needed).

## Fetch handles, deep fetch, and per-key paging

`EdContext.fetch` returns a `Fetch` handle that resolves on a later tick — `Found`
(with `obj` linking the container) or `NotFound` (the authority NACKed; it didn't
exist *at fetch time*, but with `follow` it still arrives if something creates it).
A **deep** fetch also pulls everything the id *owns* (the synced-ownership closure,
recursively), so an owner id — a unit, which has no container of its own — pulls
its whole owned subtree in one request; for `OWNS_MEMBERS` collections the member
closures are pushed *before* the collection so the receiver's parse links members
to real containers instead of husks.

**Per-key paging (LAZY tables).** A big table (voxel chunks) is marked `LAZY` and
arrives as an empty handle; the replica pulls individual entries with `request(key)`
and drops them with `release(key)` (`loaded(key)` reports per-key residency).
Requests and releases are batched — a frame's worth collapses into one REQUEST /
RELEASE per table. A requested key streams its future ops even if it was missing at
request time (an empty-space chunk someone later builds in). Ed-valued entries (a
chunk's delta seq) are sent *before* the entry and followed, so their ops stream too
(per-key deep).

**Request chaining (hubs).** A hub that can't serve a request forwards it upstream
(becoming the requester there) and remembers who asked; the answer — data or
NOT_FOUND — relays back hop by hop. Only misses forward, and only the first want per
id/key does; the authority never forwards (its miss is the real NOT_FOUND), which
also terminates any forwarding cycle. A hub never serves a request from its *own*
upstream (its copy is a stale subset). A no-cache partial hub that loses the last
downstream interest in a key sheds its own copy and chains the release upstream.

## Notes

- Builds on the relaxed validation (a replica already tolerates ops for objects it
  doesn't hold) and the per-object reconciliation frontier (delivery is already
  per-object). See `consistency.md`.

## Eviction & interest tiers

Only a **partial replica** evicts. A full clone mirrors everything its upstream
has — there's no safe residue to drop, and evicting one breaks live round-trips
(an enu node ctx, a full clone, given `mem_limit = 0` intermittently hung the bot
test and godot shutdown), so a full clone ignores `mem_limit` entirely. Client
memory is managed at the **worker** (the partial replica), on its own thread with
orderly teardown.

`mem_limit` is an honest byte budget: `0` = no cache (evict the moment something
isn't live; negatives clamp here), `0 < n < Unbounded` = cache to `n` bytes then
shed LRU, `Unbounded` (= `int.high`) = never evict (authority, full clones). Two
predicates centralize the decode: `evicts` (partial + finite limit) and
`has_budget` (evicts + positive → tracks per-body bytes). The sweep
(`evict_sweep`) is the safety/policy split from `proxy-body.md`: a body is a
candidate only with **no live proxy** (safety) and outside live interest (policy);
cold/over-budget candidates drop, retracting interest upstream so the stream stops.

**Interest tiers (live vs cache).** `interest` conflated "hold because I'm using
it" with "hold because I cached it"; since interest propagates upward, a downstream
caching freely pinned its upstream forever. So interest splits: live
(`interest − interest_cache`, mandatory — the upstream must hold and stream it, and
it protects against eviction) vs cache (`interest_cache`, still streamed so the
cache stays current, but *not* eviction-protecting — the upstream may reclaim it
under its own pressure and invalidate the holder). Each sweep `reconcile_tier`
sends a lightweight `INTEREST` op (`demote`/`promote`) upstream when an object's
local liveness (`is_live_here`) flips. So an upstream is bounded by
`live(subtree) + its own budget`, never by a downstream's `mem_limit`; propagation
cascades through hubs with no special-casing. A caching hub keeps released per-key
entries as cache-tier and sheds them by per-key LRU under its own budget (a player
stepping back into an area is served locally, no refetch).
