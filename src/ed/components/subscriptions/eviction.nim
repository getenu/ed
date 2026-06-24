## The partial-replica evictor: interest/liveness predicates, the live/cache
## tier reconciliation, and the LRU-to-budget sweep that reclaims dormant or
## over-budget bodies. Builds on `wire`/`publish`.

import std/[importutils, tables, sets, heapqueue]
import ed/[core, types {.all.}], ed/zens/[contexts, private]
import ed/components/private/global_state
import ed/lifecycle
import ./wire

privileged
proc any_interest*(self: EdContext, object_id: string): bool =
  ## Does any subscriber below us still hold *live* interest in this object --
  ## directly or via a key? Cache-tier interest (`interest_cache`) does NOT
  ## count: the subscriber only has it cached, so we may evict it and
  ## invalidate them (Option 2). Interest auto-propagates downward, so "no live
  ## interest" means nothing live in the whole subtree beneath us.
  for s in self.subscribers:
    if s.ctx_id in self.upstream_ctx_ids:
      continue # the reverse link to our upstream is not downstream interest
    if object_id in s.interest and object_id notin s.interest_cache:
      return true
    if object_id in s.key_interest:
      return true
  result = false

proc cache_holders(self: EdContext, object_id: string): seq[Subscription] =
  ## Subscribers holding `object_id` at cache tier -- they need an invalidation
  ## when we evict it, so they drop their now-orphaned cache.
  for s in self.subscribers:
    if s.ctx_id in self.upstream_ctx_ids:
      continue
    if object_id in s.interest_cache:
      result.add s

proc evict_body*(self: EdContext, object_id: string) =
  ## Reclaim a dormant, unclaimed body: drop it locally and retract our
  ## interest upstream so its ops stop flowing (otherwise the next op would
  ## just re-materialize it). No downstream relay -- by the candidate gate
  ## nobody below us wants it. The data is safe on the authority; a later
  ## access re-fetches. Partial replicas only.
  if object_id notin self.objects or self.objects[object_id] == nil:
    return
  let body = self.objects[object_id]
  # Retract upstream: a whole-object RELEASE (empty key batch) tells our
  # source to stop following it for us.
  let msg = Message(kind: RELEASE, object_id: object_id)
  for sub in self.subscribers:
    if sub.ctx_id in self.upstream_ctx_ids:
      self.send(sub, msg, OperationContext(), DEFAULT_FLAGS)
  # Invalidate any downstream cache holders: the body's gone, so the cache they
  # hold of it is orphaned (a whole-object RELEASE from us = eviction notice).
  for holder in self.cache_holders(object_id):
    holder.interest.excl object_id
    holder.interest_cache.excl object_id
    self.send(holder, msg, OperationContext(), DEFAULT_FLAGS)
  # Stop following it ourselves, drop ownership-index + bytes, unregister.
  if body.owner_id.len > 0 and body.owner_id in self.owned_by:
    self.owned_by[body.owner_id].excl object_id
  self.forget_body_bytes(body)
  body.release_closures
  self.objects.del object_id
  self.objects_need_packing = true
  self.tick_reactor

proc is_live_here(self: EdContext, body: ref EdBodyBase): bool =
  ## Is this object live at our node -- actively used, not merely cached?
  ## True when we hold a live proxy, it's a piece of a live owner, or some
  ## downstream holds *live* interest. Drives the interest tier we report
  ## upstream (live vs cache) and the eviction gate.
  if body == nil:
    return false
  if body.proxy != nil:
    return true
  if body.owner_id.len > 0 and body.owner_id in self.objects and
      self.objects[body.owner_id] != nil and self.objects[body.owner_id].proxy != nil:
    return true
  if self.any_interest(body.id): # any_interest is live-only (Option 2)
    return true
  result = false

proc evict_candidate(self: EdContext, body: ref EdBodyBase): bool =
  ## Eligible for eviction: not live here (no live use, nobody below wants it
  ## live), and it actually holds data worth reclaiming. Placeholders and LAZY
  ## handles are never candidates (no resident data; LAZY is paged per-key).
  if body == nil or body.placeholder or LAZY in body.flags:
    return false
  result = not self.is_live_here(body)

const up_live* = 1
const up_cache = 2

proc reconcile_tier(self: EdContext, body: ref EdBodyBase) =
  ## Tell our upstream whether we hold this object live or merely cached, when
  ## that flips (Option 2). Only for objects we follow from upstream (up_tier
  ## set on materialize); our own creations are left alone. A demote lets the
  ## upstream reclaim it under *its* pressure; a promote re-protects it.
  if body == nil or body.up_tier == 0:
    return
  let live = self.is_live_here(body)
  if not live and body.up_tier != up_cache:
    body.up_tier = up_cache
    let msg = Message(kind: INTEREST, object_id: body.id, demote: true)
    for sub in self.subscribers:
      if sub.ctx_id in self.upstream_ctx_ids:
        self.send(sub, msg, OperationContext(), DEFAULT_FLAGS)
  elif live and body.up_tier == up_cache:
    body.up_tier = up_live
    let msg = Message(kind: INTEREST, object_id: body.id, demote: false)
    for sub in self.subscribers:
      if sub.ctx_id in self.upstream_ctx_ids:
        self.send(sub, msg, OperationContext(), DEFAULT_FLAGS)

const churn_limit = 8
  ## Arriving ops on a dormant body before we evict it: holding it costs that
  ## much traffic, and refill is a single fetch. A see-it-work default.

proc evict_sweep*(self: EdContext) =
  ## Partial-replica eviction (docs/partial-replicas.md), by mode (see
  ## EdContext.mem_limit): 0 evict every unclaimed body now; finite n churn +
  ## LRU-to-budget; Unbounded never evict. All eviction is gated on
  ## `evict_candidate`.
  ##
  ## ONLY partial replicas evict (`evicts`). A full clone (sync_mode FULL)
  ## mirrors everything its upstream has -- there's no safe "residue" to drop,
  ## because anything it holds is synced state something may read back.
  ## Evicting on a full clone breaks live round-trips, so `mem_limit` is ignored
  ## there.
  if not self.evicts:
    return
  self.prune_dead_proxies
  # Idle fast path: nothing an eviction would act on has changed since the last
  # sweep, and we're within budget -- so there's nothing to reconcile, churn, or
  # shed. Skip the O(objects) scans entirely (a calm context pays ~nothing per
  # tick). prune_dead_proxies above may have set sweep_dirty (a liveness flip).
  if not self.sweep_dirty and self.used_bytes <= self.mem_limit:
    return
  self.sweep_dirty = false # we're doing the work now
  if self.mem_limit == 0:
    # No cache: shed everything that isn't live, this tick. No byte accounting.
    var gone: seq[string]
    for id, body in self.objects:
      if self.evict_candidate(body):
        gone.add id
    for id in gone:
      debug "evicting (no-cache)", object_id = id
      self.evict_body(id)
    return
  # Cache mode (mem_limit > 0). One scan does both: reconcile interest tiers (an
  # object gone non-live here demotes upstream so it can reclaim it under its own
  # pressure; one back live re-promotes) and collect churn candidates (a dormant
  # body that keeps taking ops costs more than a refetch). What we shed is, by
  # definition, cache tier.
  var churned: seq[string]
  for id, body in self.objects:
    if body == nil:
      continue
    self.reconcile_tier(body)
    if body.updates >= churn_limit and self.evict_candidate(body):
      churned.add id
  for id in churned:
    debug "evicting (churn)", object_id = id, updates = self.objects[id].updates
    self.evict_body(id)
  # Pressure pass -- only when over budget. LRU: oldest read goes first. A heap
  # (O(n) build, O(k log n) to pop the k we actually evict) avoids sorting the
  # whole candidate set just to drop a few off the cold end.
  if self.used_bytes <= self.mem_limit:
    return
  var cands: seq[(MonoTime, string)]
  for id, body in self.objects:
    if self.evict_candidate(body):
      cands.add (body.last_read, id)
  var cand_heap = cands.to_heap_queue # min by last_read: least-recently-read first
  while self.used_bytes > self.mem_limit and cand_heap.len > 0:
    let (_, id) = cand_heap.pop
    debug "evicting (pressure)",
      object_id = id, used = self.used_bytes, limit = self.mem_limit
    self.evict_body(id)
  # Per-key cache pass -- the bulk of a paging client's memory is in LAZY tables
  # (voxel chunks), which the whole-object passes skip. If still over budget,
  # shed cache-tier keys (no live downstream interest) least-recently-served
  # first, retracting each upstream so its stream stops too.
  if self.used_bytes <= self.mem_limit:
    return
  var keyed: seq[(MonoTime, string, string)] # (recency, object_id, key_bin)
  for id, body in self.objects:
    if body == nil or LAZY notin body.flags:
      continue
    for key_bin in body.key_bytes.keys:
      var live = false
      for s in self.subscribers:
        if s.ctx_id in self.upstream_ctx_ids:
          continue
        if id in s.key_interest and key_bin in s.key_interest[id]:
          live = true
          break
      if not live:
        keyed.add (body.key_last_read.get_or_default(key_bin), id, key_bin)
  var key_heap = keyed.to_heap_queue # min by recency: least-recently-served first
  while self.used_bytes > self.mem_limit and key_heap.len > 0:
    let (_, id, key_bin) = key_heap.pop
    debug "evicting key (pressure)", object_id = id
    let obj = self.objects[id]
    if obj != nil and obj.evict_key != nil:
      let evicted = obj.evict_key(obj, key_bin) # evict_key -> forget_key_bytes
      self.drop_nested_bodies(evicted.nested)    # ...clears key_last_read too
    self.pending_key_releases.mget_or_put(id, @[]).add key_bin # retract upstream

