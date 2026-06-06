import std/[typetraits, macros, macrocache, tables]
import pkg/flatty
import ed/[core, components/private/tracking, types {.all.}]
import ./[contexts, validations, private]

proc untrack_all*[T, O](self: Ed[T, O]) =
  private_access EdObject[T, O]
  private_access EdBase
  private_access EdContext
  assert self.valid
  self.trigger_callbacks(@[Change.init(O, {CLOSED})])
  for zid, _ in self.changed_callbacks.pairs:
    self.ctx.close_procs.del(zid)

  for zid in self.bound_eids:
    self.ctx.untrack(zid)

  self.changed_callbacks.clear

proc untrack*(ctx: EdContext, zid: EID) =
  private_access EdContext

  # :(
  if zid in ctx.close_procs:
    ctx.close_procs[zid]()
    debug "deleting close proc", zid
    ctx.close_procs.del(zid)
  else:
    debug "No close proc for zid", zid = zid

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

proc clear*[T, O](self: Ed[T, O]) =
  assert self.valid
  mutate(OperationContext(source: [self.ctx.id].toHashSet)):
    self.tracked = T.default

proc `value=`*[T, O](self: Ed[T, O], value: T, op_ctx = OperationContext()) =
  ## Set the container's value. Triggers change callbacks and sync.
  privileged
  assert self.valid
  self.ctx.setup_op_ctx
  if self.tracked != value:
    mutate(op_ctx):
      self.tracked = value

proc loaded*(self: ref EdBase): bool =
  ## False while this object is an unmaterialized placeholder (a partial replica
  ## holds the reference but not the contents yet). Lets a caller distinguish
  ## "exists but not loaded" from "exists and is genuinely empty".
  not self.placeholder

template touch_placeholder(self: untyped) =
  ## Materialize-on-access: if `self` is an unmaterialized placeholder, ask its
  ## context to materialize it (kick a fetch; block until filled when
  ## `ctx.blocking`). No-op for a loaded object or a context without the hook.
  if self.placeholder and self.ctx.materialize != nil:
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
  ## Drop a locally-materialized entry to free memory (eviction). Local only —
  ## fires a REMOVED change (so watches un-render) but does NOT delete on the
  ## authority; `request(key)` re-fetches it. No-op if not loaded.
  privileged
  assert self.valid
  if key in self.tracked:
    let pair = Pair[K, V](key: key, value: self.tracked[key])
    self.tracked.del key
    self.trigger_callbacks(@[Change[Pair[K, V]](changes: {REMOVED}, item: pair)])

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
  self.ctx.setup_op_ctx
  self.put(key, value, touch = false, op_ctx)

proc `[]=`*[T](
    self: EdSeq[T], index: SomeOrdinal, value: T, op_ctx = OperationContext()
) =
  self.ctx.setup_op_ctx
  assert self.valid
  mutate(op_ctx):
    self.tracked[index] = value

proc add*[T, O](self: Ed[T, O], value: O, op_ctx = OperationContext()) =
  ## Add an item to a sequence container.
  privileged
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
  self.ctx.setup_op_ctx
  assert self.valid
  if value in self.tracked:
    remove(self, value, value, del, op_ctx)

proc del*[K, V](self: EdTable[K, V], key: K, op_ctx = OperationContext()) =
  privileged
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

  self.ctx.setup_op_ctx
  assert self.valid
  if index < self.tracked.len:
    remove(self, index, self.tracked[index], del, op_ctx)

proc delete*[T, O](self: Ed[T, O], value: O) =
  assert self.valid
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
  if index < self.tracked.len:
    remove(
      self, index, self.tracked[index], delete, op_ctx = OperationContext()
    )

proc touch*[K, V](
    self: EdTable[K, V], pair: Pair[K, V], op_ctx: OperationContext
) =
  assert self.valid
  self.put(pair.key, pair.value, touch = true, op_ctx = op_ctx)

proc touch*[T, O](
    self: EdTable[T, O], key: T, value: O, op_ctx = OperationContext()
) =
  assert self.valid
  self.put(key, value, touch = true, op_ctx = op_ctx)

proc touch*[T: set, O](self: Ed[T, O], value: O, op_ctx = OperationContext()) =
  assert self.valid
  self.change_and_touch({value}, true, op_ctx = op_ctx)

proc touch*[T: seq, O](self: Ed[T, O], value: O, op_ctx = OperationContext()) =
  assert self.valid
  self.change_and_touch(@[value], true, op_ctx = op_ctx)

proc touch*[T, O](self: Ed[T, O], value: T, op_ctx = OperationContext()) =
  assert self.valid
  self.change_and_touch(value, true, op_ctx = op_ctx)

proc touch*[T](self: EdValue[T], value: T, op_ctx = OperationContext()) =
  assert self.valid
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
  self.change(value, true, op_ctx = OperationContext())

proc `+=`*[O](self: EdSet[O], value: O) =
  assert self.valid
  self.change({value}, true, op_ctx = OperationContext())

proc `+=`*[T: seq, O](self: Ed[T, O], value: O) =
  assert self.valid
  self.add(value)

proc `+=`*[T, O](self: EdTable[T, O], other: Table[T, O]) =
  assert self.valid
  self.put_all(other, touch = false, op_ctx = OperationContext())

proc `-=`*[T, O](self: Ed[T, O], value: T) =
  assert self.valid
  self.change(value, false, op_ctx = OperationContext())

proc `-=`*[T: set, O](self: Ed[T, O], value: O) =
  assert self.valid
  self.change({value}, false, op_ctx = OperationContext())

proc `-=`*[T: seq, O](self: Ed[T, O], value: O) =
  assert self.valid
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
  assert self.valid
  if eids.len == 0:
    for eid in self.changed_callbacks.keys:
      self.paused_eids.incl(eid)
  else:
    for eid in eids:
      self.paused_eids.incl(eid)

proc resume_changes*(self: Ed, eids: varargs[EID]) =
  ## Resume change callbacks. Pass specific EIDs or none to resume all.
  assert self.valid
  if eids.len == 0:
    self.paused_eids = {}
  else:
    for eid in eids:
      self.paused_eids.excl(eid)

template pause_impl(self: Ed, eids: untyped, body: untyped) =
  private_access EdBase

  let previous = self.paused_eids
  for eid in eids:
    self.paused_eids.incl(eid)
  try:
    body
  finally:
    self.paused_eids = previous

template pause*(self: Ed, eids: varargs[EID], body: untyped) =
  mixin valid
  assert self.valid
  pause_impl(self, eids, body)

template pause*(self: Ed, body: untyped) =
  private_access EdObject
  mixin valid
  assert self.valid
  pause_impl(self, self.changed_callbacks.keys, body)

proc destroy*[T, O](self: Ed[T, O], publish = true) =
  ## Destroy the container and remove it from its context.
  log_defaults
  debug "destroying", unit = self.id, stack = get_stack_trace()
  assert self.valid
  self.untrack_all
  self.destroyed = true
  self.ctx.objects[self.id] = nil
  self.ctx.objects_need_packing = true
  self.ctx.latest_op_id.del(self.id)  # drop own-op reconciliation state

  if publish:
    self.publish_destroy OperationContext(source: [self.ctx.id].toHashSet)

proc destroy_fields*[T: EdRef](self: T) =
  ## Destroy every Ed *container* field of `self` (the owner-cascade): each fires
  ## its CLOSED and drops out of `ctx.objects`. Raw ref fields (`parent`,
  ## `clone_of`, …) aren't `Ed`, so they're skipped — only owned-in-place
  ## containers are torn down, never referenced objects. Generic over the
  ## concrete type so `fields` sees the derived fields. Unlike the `own` scope
  ## (which only catches containers built inside its block), this works whether
  ## the container was built locally or arrived via sync — so it's the right
  ## teardown for replicas, whose units skip `init_unit`.
  for field in self[].fields:
    when field is Ed:
      if ?field and not field.destroyed:
        field.destroy

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
