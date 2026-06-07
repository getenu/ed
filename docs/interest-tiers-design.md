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

## Stage 2 (next)

- **Per-key tiers** for LAZY tables (`key_interest_cache`): a voxel chunk demotes
  when it leaves view but stays cached + current; the leaf's LRU does the full
  release.
- **enu wiring**: `on_block_unloaded` demotes the chunk key (keep data) instead
  of releasing; give the node ctx a `mem_limit` so it demotes out-of-view chunks
  (currently never-evict → would pin the worker).
