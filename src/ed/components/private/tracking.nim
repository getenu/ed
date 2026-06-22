import
  std/[importutils, tables, sets, sequtils, algorithm, intsets, locks, sugar]

import pkg/[flatty, supersnappy, threading/channels {.all.}]
import
  ed/
    [core, components/type_registry, zens/contexts, zens/private, types {.all.}]

proc `-`*[T](a, b: seq[T]): seq[T] =
  a.filter proc(it: T): bool =
    it notin b

template `&`*[T](a, b: set[T]): set[T] =
  a + b

proc trigger_callbacks*[T, O](self: Ed[T, O], changes: seq[Change[O]]) =
  private_access EdObject[T, O]
  private_access EdBase

  if changes.len > 0:
    let callbacks = self.changed_callbacks.dup
    for zid, callback in callbacks.pairs:
      if zid in self.changed_callbacks and zid notin self.paused_eids:
        callback(changes)

proc link_child*[K, V](
    self: EdTable[K, V], child, obj: Pair[K, V], field_name = ""
) =
  proc link[S, K, V, T, O](self: S, pair: Pair[K, V], child: Ed[T, O]) =
    private_access EdBase
    log_defaults
    child.link_eid = child.track proc(changes: seq[Change[O]]) =
      if changes.len == 1 and changes[0].changes == {CLOSED}:
        # Don't propagate CLOSED changes
        return
      let change = Change.init(pair, {MODIFIED})
      change.triggered_by = cast[seq[BaseChange]](changes)
      change.triggered_by_type = $O
      self.trigger_callbacks(@[change])
    debug "linking zen",
      child = ($child.type, $child.id), self = ($self.type, $self.id)

  if ?child.value:
    self.link(child, child.value)

proc link_child*[T, O, L](self: EdSeq[T], child: O, obj: L, field_name = "") =
  let
    field_name = field_name
    self = self
    obj = obj
  proc link[T, O](child: Ed[T, O]) =
    private_access EdBase
    log_defaults
    child.link_eid = child.track proc(changes: seq[Change[O]]) =
      if changes.len == 1 and changes[0].changes == {CLOSED}:
        # Don't propagate CLOSED changes
        return

      let change = Change.init(obj, {MODIFIED}, field_name = field_name)
      change.triggered_by = cast[seq[BaseChange]](changes)
      change.triggered_by_type = $O
      self.trigger_callbacks(@[change])
    debug "linking zen",
      child = ($child.type, $child.id),
      self = ($self.type, $self.id),
      zid = child.link_eid,
      child_addr = cast[int](unsafe_addr child[]).to_hex

  if ?child:
    link(child)

proc unlink*(self: Ed) =
  private_access EdBase
  log_defaults
  debug "unlinking", id = self.id, zid = self.link_eid
  self.untrack(self.link_eid)
  self.link_eid = 0

proc unlink*[T: Pair](pair: T) =
  log_defaults
  debug "unlinking", id = pair.value.id, zid = pair.value.link_eid
  pair.value.untrack(pair.value.link_eid)
  pair.value.link_eid = 0

proc link_or_unlink*[T, O](self: Ed[T, O], change: Change[O], link: bool) =
  log_defaults
  template value(change: Change[Pair]): untyped =
    change.item.value

  template value(change: not Change[Pair]): untyped =
    change.item

  if TRACK_CHILDREN in self.flags:
    if link:
      when change.value is Ed:
        self.link_child(change.item, change.item)
      elif change.value is object or change.value is ref:
        for name, val in change.value.deref.field_pairs:
          when val is Ed:
            if ?val:
              debug "linking field", field = name, type = $change.value.type
              self.link_child(val, change.item, name)
    else:
      when change.value is Ed:
        if ?change.value:
          change.value.unlink
      elif change.value is object or change.value is ref:
        for n, field in change.value.deref.field_pairs:
          when field is Ed:
            if ?field and not field.destroyed:
              field.unlink

proc link_or_unlink*[T, O](
    self: Ed[T, O], changes: seq[Change[O]], link: bool
) =
  if TRACK_CHILDREN in self.flags:
    for change in changes:
      self.link_or_unlink(change, link)

proc process_changes*[T](
    self: Ed[T, T], initial: sink T, op_ctx: OperationContext, touch = false
) =
  private_access EdObject[T, T]
  if initial != self.tracked:
    var add_flags = {ADDED, MODIFIED}
    var del_flags = {REMOVED, MODIFIED}
    if touch:
      add_flags.incl TOUCHED

    let changes =
      @[Change.init(initial, del_flags), Change.init(self.tracked, add_flags)]
    when T isnot Ed and T is ref:
      self.ctx.ref_count(changes, self.id)

    self.publish_changes(changes, op_ctx)
    self.trigger_callbacks(changes)
  elif touch:
    let changes = @[Change.init(self.tracked, {TOUCHED})]
    when T isnot Ed and T is ref:
      self.ctx.ref_count(changes, self.id)

    self.publish_changes(changes, op_ctx)
    self.trigger_callbacks(changes)

proc process_changes*[T: seq | set, O](
    self: Ed[T, O],
    initial: sink T,
    op_ctx: OperationContext,
    touch = T.default,
) =
  private_access EdObject

  let added = (self.tracked - initial).map_it:
    let changes =
      if it in touch:
        {TOUCHED}
      else:
        {}
    Change.init(it, {ADDED} + changes)
  let removed = (initial - self.tracked).map_it Change.init(it, {REMOVED})

  var touched: seq[Change[O]]
  for item in touch:
    if item in initial:
      touched.add Change.init(item, {TOUCHED})

  self.link_or_unlink(removed, false)
  self.link_or_unlink(added, true)

  let changes = removed & added & touched
  when O isnot Ed and O is ref:
    self.ctx.ref_count(changes, self.id)

  self.publish_changes(changes, op_ctx)
  self.trigger_callbacks(changes)

proc process_changes*[K, V](
    self: Ed[Table[K, V], Pair[K, V]],
    initial_table: sink Table[K, V],
    op_ctx: OperationContext,
) =
  private_access EdObject
  let
    tracked: seq[Pair[K, V]] = collect:
      for key, value in self.tracked.pairs:
        Pair[K, V](key: key, value: value)
    initial: seq[Pair[K, V]] = collect:
      for key, value in initial_table.pairs:
        Pair[K, V](key: key, value: value)
    added = (tracked - initial).map_it:
      var changes = {ADDED}
      if it.key in initial_table:
        changes.incl MODIFIED
      Change.init(it, changes)

    removed = (initial - tracked).map_it:
      var changes = {REMOVED}
      if it.key in self.tracked:
        changes.incl MODIFIED
      Change.init(it, changes)

  self.link_or_unlink(removed, false)
  self.link_or_unlink(added, true)
  let changes = removed & added
  when V isnot Ed and V is ref:
    self.ctx.ref_count(changes, self.id)

  self.publish_changes(changes, op_ctx)
  self.trigger_callbacks(changes)

template mutate_and_touch*(touch, op_ctx, body: untyped) =
  private_access EdObject
  when self.tracked is Ed:
    let initial_values = self.tracked[]
  elif self.tracked is ref:
    let initial_values = self.tracked
  else:
    let initial_values = self.tracked.dup

  {.line.}:
    body
    self.process_changes(initial_values, op_ctx, touch)

template mutate*(op_ctx: OperationContext, body: untyped) =
  private_access EdObject
  mixin dup
  when self.tracked is Ed:
    let initial_values = self.tracked[]
  elif self.tracked is ref:
    let initial_values = self.tracked
  else:
    let initial_values = self.tracked.dup

  {.line.}:
    body
    self.process_changes(initial_values, op_ctx)

proc change*[T, O](
    self: Ed[T, O], items: T, add: bool, op_ctx: OperationContext
) =
  mutate(op_ctx):
    if add:
      self.tracked = self.tracked & items
    else:
      self.tracked = self.tracked - items

proc change_and_touch*[T, O](
    self: Ed[T, O], items: T, add: bool, op_ctx: OperationContext
) =
  mutate_and_touch(touch = items, op_ctx):
    if add:
      self.tracked = self.tracked & items
    else:
      self.tracked = self.tracked - items

proc assign*[O](self: EdSeq[O], value: O, op_ctx: OperationContext) =
  self.add(value, op_ctx = op_ctx)

proc assign*[O](self: EdSeq[O], values: seq[O], op_ctx: OperationContext) =
  for value in values:
    self.add(value, op_ctx = op_ctx)

proc assign*[O](self: EdSet[O], value: O, op_ctx: OperationContext) =
  self.change({value}, add = true, op_ctx = op_ctx)

proc assign*[K, V](
    self: EdTable[K, V], pair: Pair[K, V], op_ctx: OperationContext
) =
  self.`[]=`(pair.key, pair.value, op_ctx = op_ctx)

proc assign*[T, O](self: Ed[T, O], value: O, op_ctx: OperationContext) =
  self.`value=`(value, op_ctx)

proc unassign*[O](self: EdSeq[O], value: O, op_ctx: OperationContext) =
  self.change(@[value], false, op_ctx = op_ctx)

proc unassign*[O](self: EdSet[O], value: O, op_ctx: OperationContext) =
  self.change({value}, false, op_ctx = op_ctx)

proc unassign*[K, V](
    self: EdTable[K, V], pair: Pair[K, V], op_ctx: OperationContext
) =
  self.del(pair.key, op_ctx = op_ctx)

proc unassign*[T, O](self: Ed[T, O], value: O, op_ctx: OperationContext) =
  discard

proc build_changes[K, V](
    self: EdTable[K, V], key: K, value: V, touch: bool
): seq[Change[Pair[K, V]]] =
  private_access EdObject
  assert self.valid

  var changes: seq[Change[Pair[K, V]]]

  if key in self.tracked and self.tracked[key] != value:
    let removed = Change.init(
      Pair[K, V](key: key, value: self.tracked[key]), {REMOVED, MODIFIED}
    )

    var flags = {ADDED, MODIFIED}
    if touch:
      flags.incl TOUCHED
    let added = Change.init(Pair[K, V](key: key, value: value), flags)
    when value is Ed:
      if ?removed.item.value:
        self.link_or_unlink(removed, false)
      self.link_or_unlink(added, true)
    self.tracked[key] = value
    changes = @[removed, added]
  elif key in self.tracked and touch:
    changes.add Change.init(Pair[K, V](key: key, value: value), {TOUCHED})
  elif key notin self.tracked:
    let added = Change.init(Pair[K, V](key: key, value: value), {ADDED})
    when value is Ed:
      self.link_or_unlink(added, true)
    self.tracked[key] = value
    changes = @[added]

  result = changes

proc put_all*[K, V](
    self: EdTable[K, V],
    other: Table[K, V],
    touch: bool,
    op_ctx: OperationContext,
) =
  var changes: seq[Change[Pair[K, V]]] = @[]
  for key, value in other:
    changes.add self.build_changes(key, value, touch)

  when V isnot Ed and V is ref:
    self.ctx.ref_count(changes, self.id)

  self.publish_changes changes, op_ctx
  self.trigger_callbacks changes

proc put*[K, V](
    self: EdTable[K, V],
    key: K,
    value: V,
    touch: bool,
    op_ctx: OperationContext,
) =
  private_access EdObject
  assert self.valid

  let changes = self.build_changes(key, value, touch)

  when V isnot Ed and V is ref:
    self.ctx.ref_count(changes, self.id)

  self.publish_changes changes, op_ctx
  self.trigger_callbacks changes

template remove*(self, key, item_exp, fun, op_ctx) =
  let obj = item_exp
  self.tracked.fun key
  let removed = @[Change.init(obj, {REMOVED})]
  self.link_or_unlink(removed, false)
  when obj isnot Ed and obj is ref:
    self.ctx.ref_count(removed, self.id)

  self.publish_changes(removed, op_ctx)
  self.trigger_callbacks(removed)
