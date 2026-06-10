import std/[typetraits, macros, macrocache, tables]
import pkg/flatty
import ed/[core, components/private/tracking, types {.all.}]
import ./[contexts, validations, private]

proc untrack_all*[T, O](self: Ed[T, O]) =
  privileged
  assert self.valid
  self.trigger_callbacks(@[Change.init(O, {CLOSED})])
  let body = self.typed_body
  for zid, _ in body.changed_callbacks.pairs:
    self.ctx.close_index.del(zid)

  for zid in self.bound_eids:
    self.ctx.untrack(zid)

  body.changed_callbacks.clear
  body.callback_gens.clear

proc untrack*(ctx: EdContext, zid: EID) =
  private_access EdContext
  private_access EdBodyBase

  if zid in ctx.close_index:
    let object_id = ctx.close_index[zid]
    ctx.close_index.del(zid)
    if object_id in ctx.objects and ctx.objects[object_id] != nil:
      let body = ctx.objects[object_id]
      if body.untrack_zid != nil:
        body.untrack_zid(zid)
  else:
    debug "No close index entry for zid", zid = zid

proc contains*[T, O](self: Ed[T, O], child: O): bool =
  privileged
  assert self.valid
  child in self.tracked

proc contains*[K, V](self: EdTable[K, V], key: K): bool =
  privileged
  assert self.valid
  key in self.tracked

proc contains*[T, O](self: Ed[T, O], children: set[O] | seq[O]): bool =
  assert self.valid
  result = true
  for child in children:
    if child notin self:
      return false

template materialize_for_write(self: untyped) =
  ## A local mutation of an unmaterialized placeholder materializes it first
  ## (under `ctx.blocking`: pumps I/O until filled) so the in-flight fill
  ## can't clobber the write — a placeholder's tracked state is about to be
  ## replaced wholesale by its CREATE. Unlike `touch_placeholder` this skips
  ## `touch_read`: a write must not reset the evictor's updates-since-read
  ## churn counter.
  privileged
  if self.placeholder and LAZY notin self.flags and self.ctx.materialize != nil:
    self.ctx.materialize(self.ctx, self.id)

template materialize_for_write(self: untyped, op_ctx: untyped) =
  ## Gated variant for accessors the receive path also calls (via
  ## change_receiver): a received op carries a non-empty source and is
  ## replicated state, not local intent — and materializing inside message
  ## processing would re-enter the pump.
  if op_ctx.source.len == 0:
    self.materialize_for_write

proc clear*[T, O](self: Ed[T, O]) =
  assert self.valid
  self.materialize_for_write
  mutate(OperationContext(source: [self.ctx.id].toHashSet)):
    self.tracked = T.default

proc `value=`*[T, O](self: Ed[T, O], value: T, op_ctx = OperationContext()) =
  ## Set the container's value. Triggers change callbacks and sync.
  privileged
  assert self.valid
  self.materialize_for_write(op_ctx)
  self.ctx.setup_op_ctx
  if self.tracked != value:
    mutate(op_ctx):
      self.tracked = value

proc loaded*(self: ref EdBase): bool =
  ## False while this object is an unmaterialized placeholder (a partial replica
  ## holds the reference but not the contents yet). Lets a caller distinguish
  ## "exists but not loaded" from "exists and is genuinely empty".
  not self.placeholder

template touch_read(self: untyped) =
  ## Coarse eviction touch: mark the body as recently used and reset its churn
  ## counter. Every read accessor runs this (it precedes `touch_placeholder`),
  ## so the evictor's LRU clock and "updates since read" both advance on real
  ## use — and never on the hot voxel render path, which doesn't read through
  ## these accessors. Only meaningful on a context with a memory limit.
  if self.ctx != nil and self.ctx.has_budget:
    self.body.last_read = get_mono_time()
    self.body.updates = 0

template touch_placeholder(self: untyped) =
  ## Materialize-on-access: if `self` is an unmaterialized placeholder, ask its
  ## context to materialize it (kick a fetch; block until filled when
  ## `ctx.blocking`). No-op for a loaded object or a context without the hook.
  ## LAZY containers are exempt: they're pull-only by design — entries arrive
  ## per-key (`request`), so reading one must never materialize the whole table.
  self.touch_read
  if self.placeholder and LAZY notin self.flags and self.ctx.materialize != nil:
    self.ctx.materialize(self.ctx, self.id)

proc value*[T, O](self: Ed[T, O]): T =
  ## Get the container's current value.
  privileged
  assert self.valid
  self.touch_placeholder
  self.tracked

proc `[]`*[K, V](self: Ed[Table[K, V], Pair[K, V]], index: K): V =
  privileged
  assert self.valid
  self.touch_placeholder
  self.tracked[index]

proc loaded*[K, V](self: EdTable[K, V], key: K): bool =
  ## Whether this key's value is materialized locally. Distinct from
  ## `key in self` (shape: whether the key exists at all, once shape sync lands).
  privileged
  assert self.valid
  key in self.tracked

proc request*[K, V](self: EdTable[K, V], key: K) =
  ## Queue a per-key fetch from the authority. Batched and sent on the next
  ## `tick` (a frame's worth of requests collapse into one message per table);
  ## the value arrives as an ADDED change, so existing `track`/`watch` handlers
  ## render it. No-op if the key is already loaded.
  privileged
  assert self.valid
  if key notin self.tracked:
    self.ctx.pending_key_requests.mgetOrPut(self.id, @[]).add key.to_flatty

proc request*[K, V](self: EdTable[K, V], keys: openArray[K]) =
  for key in keys:
    self.request(key)

proc release*[K, V](self: EdTable[K, V], key: K) =
  ## Drop a locally-materialized entry to free memory (paging out). Never
  ## deletes on the authority; `request(key)` re-fetches. Three effects:
  ## evict locally (REMOVED fires, watches un-render), retract our per-key
  ## interest upstream (ops for this key stop flowing), and notify downstream
  ## clones so they evict too — all via one batched RELEASE on the next tick.
  ## Also retracts a pending interest in a key that never loaded (a requested
  ## empty-space chunk).
  privileged
  assert self.valid
  let key_bin = key.to_flatty
  if key in self.tracked:
    let evicted = self.evict_key(self, key_bin)
    # The entry's nested containers (a chunk's delta seq) leave the registry
    # too — paging out actually frees their memory (proxy/body phase 3).
    self.ctx.drop_nested_bodies(evicted.nested)
  self.ctx.pending_key_releases.mgetOrPut(self.id, @[]).add key_bin

proc release*[K, V](self: EdTable[K, V], keys: openArray[K]) =
  for key in keys:
    self.release(key)

proc `[]`*[T](self: EdSeq[T], index: SomeOrdinal | BackwardsIndex): T =
  privileged
  assert self.valid
  self.touch_placeholder
  self.tracked[index]

proc `[]=`*[K, V](
    self: EdTable[K, V], key: K, value: V, op_ctx = OperationContext()
) =
  self.materialize_for_write(op_ctx)
  self.ctx.setup_op_ctx
  self.put(key, value, touch = false, op_ctx)

proc `[]=`*[T](
    self: EdSeq[T], index: SomeOrdinal, value: T, op_ctx = OperationContext()
) =
  self.materialize_for_write(op_ctx)
  self.ctx.setup_op_ctx
  assert self.valid
  mutate(op_ctx):
    self.tracked[index] = value

proc add*[T, O](self: Ed[T, O], value: O, op_ctx = OperationContext()) =
  ## Add an item to a sequence container.
  privileged
  self.materialize_for_write(op_ctx)
  self.ctx.setup_op_ctx
  when O is Ed:
    assert self.valid(value)
  else:
    assert self.valid
  self.tracked.add value
  let added = @[Change.init(value, {ADDED})]
  self.link_or_unlink(added, true)
  when O isnot Ed and O is ref:
    self.ctx.ref_count(added, self.id)

  self.publish_changes(added, op_ctx)
  self.trigger_callbacks(added)

proc del*[T, O](self: Ed[T, O], value: O, op_ctx = OperationContext()) =
  privileged
  self.materialize_for_write(op_ctx)
  self.ctx.setup_op_ctx
  assert self.valid
  if value in self.tracked:
    remove(self, value, value, del, op_ctx)

proc del*[K, V](self: EdTable[K, V], key: K, op_ctx = OperationContext()) =
  privileged
  self.materialize_for_write(op_ctx)
  self.ctx.setup_op_ctx
  assert self.valid
  if key in self.tracked:
    remove(
      self, key, Pair[K, V](key: key, value: self.tracked[key]), del, op_ctx
    )

proc del*[T: seq, O](
    self: Ed[T, O], index: SomeOrdinal, op_ctx = OperationContext()
) =
  privileged
  self.materialize_for_write(op_ctx)
  self.ctx.setup_op_ctx
  assert self.valid
  if index < self.tracked.len:
    remove(self, index, self.tracked[index], del, op_ctx)

proc delete*[T, O](self: Ed[T, O], value: O) =
  assert self.valid
  self.materialize_for_write
  if value in self.tracked:
    remove(
      self,
      value,
      value,
      delete,
      op_ctx = OperationContext(source: [self.ctx.id].toHashSet),
    )

proc delete*[K, V](self: EdTable[K, V], key: K) =
  assert self.valid
  self.materialize_for_write
  if key in self.tracked:
    remove(
      self,
      key,
      Pair[K, V](key: key, value: self.tracked[key]),
      delete,
      op_ctx = OperationContext(),
    )

proc delete*[T: seq, O](self: Ed[T, O], index: SomeOrdinal) =
  assert self.valid
  self.materialize_for_write
  if index < self.tracked.len:
    remove(
      self, index, self.tracked[index], delete, op_ctx = OperationContext()
    )

proc touch*[K, V](
    self: EdTable[K, V], pair: Pair[K, V], op_ctx: OperationContext
) =
  assert self.valid
  self.materialize_for_write(op_ctx)
  self.put(pair.key, pair.value, touch = true, op_ctx = op_ctx)

proc touch*[T, O](
    self: EdTable[T, O], key: T, value: O, op_ctx = OperationContext()
) =
  assert self.valid
  self.materialize_for_write(op_ctx)
  self.put(key, value, touch = true, op_ctx = op_ctx)

proc touch*[T: set, O](self: Ed[T, O], value: O, op_ctx = OperationContext()) =
  assert self.valid
  self.materialize_for_write(op_ctx)
  self.change_and_touch({value}, true, op_ctx = op_ctx)

proc touch*[T: seq, O](self: Ed[T, O], value: O, op_ctx = OperationContext()) =
  assert self.valid
  self.materialize_for_write(op_ctx)
  self.change_and_touch(@[value], true, op_ctx = op_ctx)

proc touch*[T, O](self: Ed[T, O], value: T, op_ctx = OperationContext()) =
  assert self.valid
  self.materialize_for_write(op_ctx)
  self.change_and_touch(value, true, op_ctx = op_ctx)

proc touch*[T](self: EdValue[T], value: T, op_ctx = OperationContext()) =
  assert self.valid
  self.materialize_for_write(op_ctx)
  mutate_and_touch(touch = true, op_ctx):
    self.tracked = value

proc len*(self: Ed): int =
  privileged
  assert self.valid
  self.tracked.len

proc `+`*[O](self, other: EdSet[O]): set[O] =
  privileged
  self.tracked + other.tracked

proc `+=`*[T, O](self: Ed[T, O], value: T) =
  assert self.valid
  self.materialize_for_write
  self.change(value, true, op_ctx = OperationContext())

proc `+=`*[O](self: EdSet[O], value: O) =
  assert self.valid
  self.materialize_for_write
  self.change({value}, true, op_ctx = OperationContext())

proc `+=`*[T: seq, O](self: Ed[T, O], value: O) =
  assert self.valid
  self.add(value)

proc `+=`*[T, O](self: EdTable[T, O], other: Table[T, O]) =
  assert self.valid
  self.materialize_for_write
  self.put_all(other, touch = false, op_ctx = OperationContext())

proc `-=`*[T, O](self: Ed[T, O], value: T) =
  assert self.valid
  self.materialize_for_write
  self.change(value, false, op_ctx = OperationContext())

proc `-=`*[T: set, O](self: Ed[T, O], value: O) =
  assert self.valid
  self.materialize_for_write
  self.change({value}, false, op_ctx = OperationContext())

proc `-=`*[T: seq, O](self: Ed[T, O], value: O) =
  assert self.valid
  self.materialize_for_write
  self.change(@[value], false, op_ctx = OperationContext())

proc `&=`*[T, O](self: Ed[T, O], value: O) =
  assert self.valid
  self.value = self.value & value

proc `==`*(a, b: Ed): bool =
  privileged
  a.is_nil == b.is_nil and a.destroyed == b.destroyed and a.tracked == b.tracked and
    a.id == b.id

proc pause_changes*(self: Ed, eids: varargs[EID]) =
  ## Pause change callbacks. Pass specific EIDs or none to pause all.
  privileged
  assert self.valid
  if eids.len == 0:
    for eid in self.typed_body.changed_callbacks.keys:
      self.typed_body.paused_eids.incl(eid)
  else:
    for eid in eids:
      self.typed_body.paused_eids.incl(eid)

proc resume_changes*(self: Ed, eids: varargs[EID]) =
  ## Resume change callbacks. Pass specific EIDs or none to resume all.
  privileged
  assert self.valid
  if eids.len == 0:
    self.typed_body.paused_eids = {}
  else:
    for eid in eids:
      self.typed_body.paused_eids.excl(eid)

template pause_impl(self: Ed, eids: untyped, body: untyped) =
  privileged

  let previous = self.typed_body.paused_eids
  for eid in eids:
    self.typed_body.paused_eids.incl(eid)
  try:
    body
  finally:
    self.typed_body.paused_eids = previous

template pause*(self: Ed, eids: varargs[EID], body: untyped) =
  mixin valid
  assert self.valid
  pause_impl(self, eids, body)

template pause*(self: Ed, body: untyped) =
  privileged
  mixin valid
  assert self.valid
  pause_impl(self, self.typed_body.changed_callbacks.keys, body)

proc destroy*[T, O](self: Ed[T, O], publish = true, op_ctx = OperationContext()) =
  ## Destroy the container and remove it from its context. `op_ctx` carries the
  ## source of the op that triggered this — for a *received* DESTROY (re-broadcast
  ## by `change_receiver` so it relays past this hop) it's the upstream source, so
  ## the re-broadcast filters the contexts the op already visited and never echoes
  ## back to its origin. Empty (a local destroy) ⇒ just this context's id.
  log_defaults
  debug "destroying", unit = self.id, stack = get_stack_trace()
  assert self.valid
  self.untrack_all
  self.destroyed = true
  self.ctx.forget_body_bytes(self.body) # evictor accounting
  self.body.release_closures # break body self-captures (no cycle GC)
  self.ctx.objects[self.id] = nil
  self.ctx.objects_need_packing = true
  self.ctx.latest_op_id.del(self.id)  # drop own-op reconciliation state
  # Keep the ownership index tidy: drop ourselves from our owner's owned-set,
  # and drop any member index keyed under our own id (an ownerless OWNS_MEMBERS
  # collection indexes its members that way).
  if self.owner_id.len > 0 and self.owner_id in self.ctx.owned_by:
    self.ctx.owned_by[self.owner_id].excl(self.id)
  if self.id in self.ctx.owned_by:
    self.ctx.owned_by.del(self.id)

  if publish:
    self.publish_destroy OperationContext(source: op_ctx.source + [self.ctx.id].toHashSet)

method destroy*(self: EdRef) {.base, gcsafe.}
  # Forward declaration: destroy_owned cascades into owned members through it.

proc set_owner*(ctx: EdContext, obj: EdRef, owner_id: string) =
  ## Attribute a standalone EdRef to `owner_id`, so `destroy_owned(owner_id)`
  ## tears it down (cascading through its own `destroy`). Unlike a container's
  ## baked-in, synced `owner_id`, this ownership isn't sent as data — it's
  ## re-derived locally on each context, exactly like OWNS_MEMBERS membership
  ## (`type_registry`): call it wherever the ref is created/adopted, on every
  ## context, and the index lands the same everywhere with no extra sync.
  privileged
  # Index by the ref_pool key ("tid:id" — `ref_id` in type_registry), matching
  # the OWNS_MEMBERS member index: destroy_owned's member pass resolves owned
  # ids through ctx.ref_pool, and a bare id never matches a pool key — the ref
  # would silently escape the cascade (and leak everything *it* owns).
  ctx.owned_by.mgetOrPut(owner_id, initHashSet[string]()).incl(
    $obj.type_id & ":" & obj.id
  )

proc destroy_owned*(ctx: EdContext, owner_id: string) =
  ## Destroy everything owned by `owner_id` (per the `owned_by` index). Two
  ## passes: first owned EdRef *members* (an OWNS_MEMBERS collection's children)
  ## — cascaded through their `destroy` method while the containers they unlink
  ## themselves from are still alive — then the owned containers, each firing
  ## its CLOSED, dropping from `ctx.objects`, and broadcasting DESTROY so
  ## replicas tear down their mirrors. Works in *any* context — including one
  ## that didn't construct the object — because ownership is synced, not derived
  ## from the constructing context. The owner's `lifetime.finish` handles its
  ## callbacks separately. Containers are type-erased here (`ref EdBase`), so
  ## they're destroyed via their `change_receiver` (the same path a received
  ## DESTROY takes); members are ref_pool keys, dispatched via `EdRef.destroy`.
  privileged
  private_access EdBase
  ctx.prune_dead_refs() # cursor safety before reading ref_pool entries
  if owner_id in ctx.owned_by:
    # Snapshot: each destroy excls itself from the set we're iterating.
    let owned = ctx.owned_by[owner_id]
    for id in owned:
      if id notin ctx.objects and id in ctx.ref_pool:
        let member = ctx.ref_pool[id].obj
        if not member.is_nil and member of EdRef and not EdRef(member).destroyed:
          EdRef(member).destroy()
    for id in owned:
      if id in ctx.objects and ?ctx.objects[id]:
        let obj = ctx.objects[id]
        if not obj.change_receiver.is_nil:
          obj.change_receiver(obj, Message(kind: DESTROY), OperationContext())
    ctx.owned_by.del(owner_id)

method destroy*(self: EdRef) {.base, gcsafe.} =
  ## Generic teardown for a registered ref: finish its callback lifetime, tear
  ## down everything it owns — containers, and owned members recursively — then
  ## latch `destroyed`. Subclasses override with their type-specific cleanup and
  ## call this last (enu: unlink from the parent, clear globals, then here).
  ## Deliberately unguarded: an overriding destroy latches `destroyed` at its
  ## *top* (removal watchers re-enter synchronously) and still needs this body
  ## to run afterwards.
  if not self.lifetime.is_nil:
    self.lifetime.finish()
  # The context this ref lives in (stamped on ref_pool add). Fall back to
  # thread_ctx only for a ref that never entered a ref_pool — i.e. created and
  # destroyed without ever being added to a collection, where it was minted on
  # the current thread anyway.
  let ctx = if self.ctx != nil: self.ctx else: Ed.thread_ctx
  ctx.destroy_owned(self.id)
  self.destroyed = true

iterator items*[T](self: EdSet[T] | EdSeq[T]): T =
  privileged
  assert self.valid
  self.touch_placeholder
  for item in self.tracked.items:
    yield item

iterator items*[K, V](self: EdTable[K, V]): Pair[K, V] =
  privileged
  assert self.valid
  self.touch_placeholder
  for key, value in self.tracked.pairs:
    yield Pair[K, V](key: key, value: value)

iterator pairs*[K, V](self: EdTable[K, V]): (K, V) =
  privileged
  assert self.valid
  self.touch_placeholder
  for pair in self.tracked.pairs:
    yield pair
