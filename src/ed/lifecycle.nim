## Object lifecycle: ownership Lifetimes, the partial-replica evictor's byte
## accounting, and the reaping of ORC-reclaimed refs/proxies. Split out of
## `types.nim` so that file stays types + serialization. The `=destroy` hooks
## themselves must remain in `types.nim` (Nim binds a custom destructor where the
## type is, and it must be in scope wherever the handle is reclaimed); they just
## record the death into the globals `types` holds, and the draining/cleanup
## logic lives here.

import std/[tables, sets, atomics, random, sysrand, sequtils]
import ed/[core, types {.all.}]
import ed/zens/private
import ed/utils/logging

# --- eviction byte accounting (partial replicas; docs/partial-replicas.md) ----

const Unbounded* = high(int)
  ## `mem_limit = Unbounded` means never evict -- an unlimited cache. The top of
  ## the byte-budget range, so the value stays an honest, monotonic size.

const DEFAULT_MEM_LIMIT* = 16 * 1024 * 1024
  ## A context's default cache budget (16 MB). Moot on a full clone/authority
  ## (they never evict); a small default cache for partial replicas.

proc evicts*(self: EdContext): bool {.inline.} =
  ## Reclaims memory under pressure: a partial replica with a finite limit. A
  ## full clone / authority, and an `Unbounded` limit, never evict.
  self.sync_mode != FULL and self.mem_limit < Unbounded

proc has_budget*(self: EdContext): bool {.inline.} =
  ## Tracks per-body bytes against a finite cap. No-cache (0) and `Unbounded`
  ## skip the accounting -- there's nothing to compare a running total against.
  self.evicts and self.mem_limit > 0

proc set_body_bytes*(self: EdContext, body: ref EdBodyBase, n: int) =
  ## Record a body's resident wire-size and keep `used_bytes` in step. Called
  ## where we already have the serialized form (publish/fill); drift between
  ## those points is harmless -- the total only gates *when* the limit trips,
  ## and LRU ordering doesn't use bytes at all. Only the finite-budget mode
  ## needs accounting; no-cache and Unbounded skip it.
  if not self.has_budget:
    return
  self.used_bytes += n - body.bytes
  body.bytes = n

proc forget_body_bytes*(self: EdContext, body: ref EdBodyBase) =
  ## Remove a body's bytes from the running total (on unregister/evict).
  if not self.has_budget:
    return
  self.used_bytes -= body.bytes
  body.bytes = 0

proc set_key_bytes*(
    self: EdContext, body: ref EdBodyBase, key_bin: string, n: int
) =
  ## Account a table entry's wire size, keyed so it can be subtracted exactly on
  ## per-key evict. An update replaces the previous figure (no double-count).
  if not self.has_budget or key_bin.len == 0:
    return
  let prev = body.key_bytes.get_or_default(key_bin, 0)
  self.set_body_bytes(body, body.bytes + n - prev)
  body.key_bytes[key_bin] = n

proc forget_key_bytes*(self: EdContext, body: ref EdBodyBase, key_bin: string) =
  ## Drop a per-key entry's accounting on evict/release: its recency and its
  ## bytes. Called from `evict_key` (so every eviction site cleans both parallel
  ## tables -- they can't drift) and on UNASSIGN. `del` of a missing key is a
  ## no-op, so recency is cleared even if bytes were never accounted.
  if not self.has_budget:
    return
  body.key_last_read.del key_bin
  if key_bin notin body.key_bytes:
    return
  self.set_body_bytes(body, max(0, body.bytes - body.key_bytes[key_bin]))
  body.key_bytes.del key_bin

# --- proxy/ref reaping + closures --------------------------------------------

proc release_closures*(body: ref EdBodyBase) =
  ## Mark the body as leaving the registry: every caller removes it from
  ## `objects` right after. mint, untrack_zid, sweep_gen and publish_create then
  ## no longer run on it. (The sync procs capture nothing -- see BodyOps -- so
  ## there's no cycle to break; the name is from when they did.)
  privileged
  body.released = true

proc drop_nested_bodies*(self: EdContext, nested: seq[string]) =
  ## Unregister the nested container bodies an evicted entry carried (a paged-
  ## out chunk's delta seq): the registry releases its strong hold, so the
  ## memory frees once any remaining holder drops, and the id resolves fresh
  ## on re-page-in. Local only -- eviction never destroys upstream data.
  for id in nested:
    if id in self.objects:
      let body = self.objects[id]
      if body != nil:
        if body.owner_id.len > 0 and body.owner_id in self.owned_by:
          self.owned_by[body.owner_id].excl id
        self.forget_body_bytes(body)
        body.release_closures
      self.objects.del id

proc prune_dead_refs*(self: EdContext) =
  ## Remove from `ref_pool` the entries whose instances ORC has reclaimed (see
  ## `pending_dead_refs`). Must run before any `ref_pool` identity lookup so a
  ## dangling cursor is never read, and on tick to keep the pool tidy. Idempotent;
  ## cheap when nothing is pending.
  privileged
  {.cast(gcsafe).}:
    let epoch = dead_ref_epoch.load # lock-free skip when nothing died (see proxies)
    if epoch == self.last_ref_prune_epoch:
      return
    var dead: seq[(string, int64)]
    dead_handles_lock.acquire()
    if self.uid in pending_dead_refs:
      dead = pending_dead_refs[self.uid]
      pending_dead_refs.del(self.uid)
    dead_handles_lock.release()
    self.last_ref_prune_epoch = epoch
    if dead.len > 0:
      self.sweep_dirty = true
    for (ref_id, incarnation) in dead:
      # Only if the entry is still the reclaimed instance's: a successor under
      # the same id may have taken it over.
      if ref_id in self.ref_pool and
          self.ref_pool[ref_id].incarnation == incarnation:
        self.ref_pool.del(ref_id)

proc prune_dead_proxies*(self: EdContext) =
  ## Clear body->proxy backrefs whose proxies ORC has reclaimed. Must run before
  ## any backref read so a dangling cursor is never returned; `gen` ensures a
  ## late prune can't clear a *newer* proxy minted after the death was recorded.
  privileged
  {.cast(gcsafe).}:
    # Lock-free fast path: if no proxy has died anywhere since our last prune,
    # there's nothing for us to drain -- skip the global lock entirely. (A death
    # in another context can cost us one redundant lock; a tick with no deaths
    # costs none.)
    let epoch = dead_proxy_epoch.load
    if epoch == self.last_proxy_prune_epoch:
      return
    var dead: seq[(string, int)]
    dead_handles_lock.acquire()
    if self.uid in pending_dead_proxies:
      dead = pending_dead_proxies[self.uid]
      pending_dead_proxies.del(self.uid)
    dead_handles_lock.release()
    self.last_proxy_prune_epoch = epoch
    if dead.len > 0:
      self.sweep_dirty = true # a liveness flip -> the next sweep must reconcile
    for (object_id, gen) in dead:
      if object_id in self.objects and self.objects[object_id] != nil and
          self.objects[object_id].proxy_gen == gen:
        let body = self.objects[object_id]
        body.proxy = nil
        # The dead proxy's callbacks die with it -- registered through it,
        # cleaned when it goes (the sentinel model). Deterministic: next
        # prune, not cycle-collector cadence.
        if body.ops != nil and not body.released:
          for zid in body.ops.sweep_gen(body, gen):
            self.close_index.del(zid)

proc resolve_proxy*(self: EdContext, body: ref EdBodyBase): ref EdBase =
  ## The identity map: the one live proxy for `body`, minting if none. Two
  ## resolutions of the same id are reference-equal while anything holds the
  ## proxy -- honest `ref` identity (docs/proxy-body.md).
  privileged
  if body == nil:
    return nil
  self.prune_dead_proxies
  if body.proxy != nil:
    return body.proxy
  if body.ops != nil and not body.released:
    return body.ops.mint(body)
  # A registered body always carries its typed `mint` (wired in `defaults`), so
  # one of the branches above returns. Reaching here means a released or
  # malformed body slipped into an identity read -- a bug, surfaced rather than
  # silently returning nil. nil is safe to limp past in release.
  invariant(false, "resolve_proxy: body " & body.id & " has neither proxy nor mint")

# --- Lifetime: owner-bound teardown ------------------------------------------

proc new_lifetime*(): Lifetime =
  Lifetime()

proc add*(self: Lifetime, cleanup: proc() {.gcsafe.}): int {.discardable.} =
  ## Register a teardown action, returning a key for `remove`. If the Lifetime
  ## has already finished, the action runs immediately (so binding to a dead
  ## Lifetime can't leak) and the key is 0.
  privileged
  if self.finished:
    cleanup()
  else:
    self.next_key.inc
    result = self.next_key
    self.cleanups.add (result, cleanup)

proc remove*(self: Lifetime, key: int) =
  ## Drop a teardown action without running it.
  privileged
  for i, entry in self.cleanups:
    if entry.key == key:
      self.cleanups.delete i
      return

proc finish*(self: Lifetime) =
  ## Run every registered teardown action, once. Idempotent.
  privileged
  if self.finished:
    return
  self.finished = true
  let cleanups = self.cleanups
  self.cleanups = @[]
  for entry in cleanups:
    entry.cleanup()

proc finished*(self: Lifetime): bool =
  privileged
  self.finished

var current_lifetime* {.threadvar.}: Lifetime
  ## The lifetime an open `own` scope binds *callbacks* to (thread-local; nil = no
  ## scope). `track` consults it: a callback registered inside `self.own:` untracks
  ## when `self.lifetime.finish` runs. nil outside a scope -> no auto-binding.

var current_owner_id* {.threadvar.}: string
  ## The id of the EdRef an open `own` scope attributes new *containers* to. A
  ## container created inside the scope records it (`owner_id` + the `owned_by`
  ## index); the owner's `destroy_owned` then tears those containers down. So
  ## `lifetime` carries callbacks while container ownership is the baked-in
  ## `owner_id`. "" outside a scope -> containers are unowned.

template own*(owner_id: string, body: untyped) =
  ## Like `self.own:`, but keyed by an owner *id* -- for construction, where you
  ## have the id but the owner object doesn't exist yet. Every Ed container created
  ## in the block (including by procs it calls -- the scope is dynamic) records
  ## `owner_id`. No lifetime is set; callbacks bind via the `EdRef` form once the
  ## owner exists.
  let prev_owner_id = current_owner_id
  current_owner_id = owner_id
  try:
    body
  finally:
    current_owner_id = prev_owner_id

template own*[T: EdRef](self: T, body: untyped) =
  ## Within this scope, every Ed container created records `self` as its owner
  ## (so `self`'s teardown destroys them via `destroy_owned`), and every callback
  ## tracked binds its untrack to `self.lifetime` (lazily created). Generic on the
  ## concrete type so `self.id` resolves (EdRef has no `id` of its own). Scopes
  ## nest by save/restore -- innermost wins, control returns to the enclosing owner
  ## on exit. It's a *dynamic* scope: things constructed in procs called from the
  ## body attribute here too, so keep blocks tight.
  if self.lifetime.is_nil:
    self.lifetime = new_lifetime()
  let prev_lifetime = current_lifetime
  let prev_owner_id = current_owner_id
  current_lifetime = self.lifetime
  current_owner_id = self.id
  try:
    body
  finally:
    current_lifetime = prev_lifetime
    current_owner_id = prev_owner_id

# --- Incarnations and destroy listeners --------------------------------------

var incarnation_rand {.threadvar.}: Rand
var incarnation_rand_ready {.threadvar.}: bool

proc ensure_incarnation*(self: EdRef) =
  ## Give `self` its incarnation if it has none yet (see `EdRef.incarnation`).
  ## Everything that sends or indexes a ref calls this first, so a copy never
  ## leaves without one.
  if self.incarnation == 0:
    if not incarnation_rand_ready:
      var seed: array[8, byte]
      if not urandom(seed):
        raise OSError.new_exception("no system randomness for ed incarnations")
      incarnation_rand = init_rand(cast[int64](seed))
      incarnation_rand_ready = true
    while self.incarnation == 0:
      self.incarnation = cast[int64](incarnation_rand.next)

proc add_destroy_listener*[T: EdRef](
    self: T, callback: proc(it: T) {.gcsafe.}, until: Lifetime = nil
) =
  ## `on_destroy` without the sugar. Runs `callback` once when `self` is
  ## destroyed in this context -- by a local `destroy`, or by the destroy of the
  ## same object arriving from another context. Not on removal from a
  ## collection: a moved object isn't destroyed. With `until`, the listener is
  ## dropped if that lifetime finishes first (the listener's own owner going
  ## away).
  privileged
  assert not self.destroyed, "on_destroy on an object already destroyed"
  let cancelled = new bool
  if not until.is_nil:
    until.add proc() =
      cancelled[] = true
  # Drop listeners whose owners are gone, so a long-lived object watched by
  # many short-lived ones doesn't grow without bound.
  self.destroy_listeners.keep_it_if(not it.cancelled[])
  self.destroy_listeners.add DestroyListener(
    callback: proc(it: EdRef) {.gcsafe.} =
      callback(T(it)),
    cancelled: cancelled,
  )

template on_destroy*(self: EdRef, until: untyped, body: untyped) =
  ## `thing.on_destroy(node.lifetime): ...` -- `it` is the object being
  ## destroyed. Use `it`, not the watched variable, so the listener doesn't keep
  ## the object alive. (`until` is untyped so this overload never type-checks
  ## the body of a call meant for the one below, where `it` isn't declared.)
  block:
    let target = self
    let listener = proc(it {.inject.}: typeof(target)) {.gcsafe.} =
      body
    add_destroy_listener(target, listener, until)

template on_destroy*(self: EdRef, body: untyped) =
  block:
    let target = self
    let listener = proc(it {.inject.}: typeof(target)) {.gcsafe.} =
      body
    add_destroy_listener(target, listener)

var ref_destroy_source* {.threadvar.}: HashSet[string]
  ## While a received REF_DESTROY runs `destroy`: the contexts it has already
  ## visited, so the relay doesn't send it back to them.

var publish_ref_destroy_hook*: proc(
  ctx: EdContext, self: EdRef, source: HashSet[string]
) {.nimcall, gcsafe.}
  ## Set by the subscriptions layer, which `destroy` can't import.

proc run_destroy_listeners*(self: EdRef) =
  ## Fire and clear `self`'s `on_destroy` listeners. Called by `destroy`.
  privileged
  let listeners = move self.destroy_listeners
  for listener in listeners:
    if not listener.cancelled[]:
      listener.callback(self)
