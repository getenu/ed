# Interest Tiers — live vs cache (Option 2)

> Status: **stage 1 (whole-object) built** (ed). Stage 2 = per-key tiers + enu
> voxel wiring. Solves: a downstream's cache must not force its upstream to
> retain data the upstream doesn't want and may not have room for.

## The problem

`interest` conflated two things: "hold this because it's **live** (I'm using
it)" and "hold this because I **cached** it (haven't evicted yet)." Interest
auto-propagates upward, so a downstream with a large `mem_limit` — caching
freely, never under pressure — pinned its upstream forever. The upstream *must*
hold what's live on a client, but *should not* be obligated by what a client
merely cached.

## The model

A subscriber's interest splits into two tiers (`Subscription.interest` +
`interest_cache ⊆ interest`):

- **Live interest** (`interest − interest_cache`): mandatory. The upstream must
  hold and stream it; it protects the object from eviction.
- **Cache interest** (`interest_cache`): the subscriber holds it cached, not
  live. It **still streams** (the cache stays current), but it does **not**
  protect against eviction. The upstream may reclaim it under *its own* memory
  pressure and invalidate the subscriber.

So an upstream is bounded by `live(subtree) + its own cache budget` — never by a
downstream's `mem_limit`.

## The signals

A node reconciles each sweep (`reconcile_tier`, cache mode only). `is_live_here`
= it holds a live proxy, the object is a piece of a live owner, or some
downstream holds *live* interest. When that flips for an object we follow from
upstream (`up_tier` set on materialize):

- non-live now, was live → **demote** (`INTEREST demote=true`) upstream.
- live again, was cache → **promote** (`INTEREST demote=false`) upstream.

Full **retract** still happens only when our *own* budget evicts the cached body
(whole-object `RELEASE`). Evicting a cache-tier body also sends `RELEASE` to any
downstream **cache holders** (invalidation — they drop their orphaned cache).

Propagation is recursive: when a hub's downstreams all demote X, the hub's
`is_live_here(X)` goes false, so the hub demotes X to *its* upstream on the next
sweep. No special hub logic — the per-node reconcile cascades.

`INTEREST` is a new lightweight `MessageKind` (object_id + `demote: bool`, no
data). `mem_limit < 0` (never-evict: authority, full clones) never reconciles —
it always holds everything live, the prior behavior.

## 3-host trace (A ← H ← L)

1. L renders X → live → H.interest{X} live → A streams X→H→L.
2. L un-renders X but caches it (big limit) → L demotes → H moves X to
   cache-tier-for-L. H keeps streaming X (L's cache stays current).
3. H over its own budget, X now unprotected → H evicts X, invalidates L (L drops
   its cache), retracts from A. **H was never pinned by L's cache.**
4. L re-renders X → promote (instant if H still had it) or refetch (if H
   invalidated).

## Stage 2 — per-key caching hub (built, ed)

The voxel bulk is per-key entries in LAZY tables, which the whole-object passes
skip. With the node ctx in no-cache mode (mem_limit 0) the leaf *releases*
out-of-view keys (it never caches them, so never demotes per-key). So the hub
just needs to **cache on retract instead of shedding**:

- A caching hub (mem_limit > 0) receiving a per-key RELEASE does NOT shed —
  the key becomes cache-tier (no live downstream wants it), stays current via
  the stream, and a **per-key LRU** (least-recently-served first) sheds it only
  under the hub's own budget, retracting upstream as it goes. A no-cache hub
  (mem_limit 0) sheds immediately, as before.
- `key_last_read` (per-key recency) is stamped on serve (last in-view) and on
  update. The per-key pass runs after the whole-object passes in `evict_sweep`.

So a client worker (mem_limit 16 MB) keeps recently-viewed chunks cached: a
player stepping back into an area is served from the worker, no refetch to the
server, until the worker's own budget forces the stalest out.

### enu wiring

The worker ctx (the partial replica) does all client-side memory management:
whole-object eviction + the per-key voxel cache, `mem_limit = 16 MB`. The **node
ctx never evicts** — it's a full clone (see the guard below); `mem_limit = 0`
there was tried and broke live sync round-trips.

## Only partial replicas evict (safety guard)

`evict_sweep` returns early unless the context is a **partial replica**
(`partial_replica`, set on a `partial = true` subscribe). A full clone mirrors
everything its upstream has, so there is no safe residue to drop — anything it
holds is synced state something may read back. Evicting on a full clone breaks
live round-trips: an enu **node ctx** (the render/main thread, a full clone)
given `mem_limit = 0` intermittently hung the bot test mid-sync and hung godot
on shutdown. So a full clone **ignores mem_limit** entirely. Memory on a client
is managed at the **worker** (the partial replica): full whole-object eviction +
per-key voxel cache, on its own thread with orderly teardown.
