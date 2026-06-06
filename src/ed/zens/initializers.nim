import std/[typetraits, macros, macrocache]
import ed/[core, components/private/tracking]
import ed/components/private/global_state
import ed/types {.all.}, ed/zens/[validations, operations, contexts, private]

export new_ident_node

const INITIALIZERS = CacheSeq"INITIALIZERS"
var type_initializers: Table[int, CreateInitializer]
var initialized = false

proc ctx(): EdContext =
  Ed.thread_ctx

proc relay_fill*[T, O](item: Ed[T, O], op_ctx: OperationContext) =
  ## Re-broadcast a just-filled placeholder to our own subscribers: they hold
  ## the same id as a placeholder (minted from the same inline ref), and the
  ## relayed CREATE fills theirs and clears their flag — `loaded` then means
  ## the same thing on every hop. Exported because the generated type
  ## initializer expands at the `Ed.bootstrap` call site, where the private
  ## `publish_create` field isn't reachable.
  privileged
  # The immediate fill runs inside the receive path's owner scope
  # (`msg.owner_id.own:`), but the placeholder was minted ownerless and the
  # post-materialize stamp hasn't run yet — stamp before relaying, or second
  # hops receive the fill unowned (same window as the create-relay fix). The
  # deferred (subscribe-time) fill runs after the stamp, so `owner_id` is
  # already set there and `current_owner_id` is empty — both paths covered.
  if current_owner_id.len > 0 and item.owner_id != current_owner_id:
    item.owner_id = current_owner_id
    item.ctx.owned_by.mgetOrPut(current_owner_id, initHashSet[string]()).incl(
      item.id
    )
  item.publish_create(broadcast = true, op_ctx = op_ctx)

proc create_initializer[T, O](self: Ed[T, O]) =
  const ed_type_id = self.type.tid

  static:
    INITIALIZERS.add quote do:
      type_initializers[ed_type_id] = proc(
          bin: string,
          ctx: EdContext,
          id: string,
          flags: set[EdFlags],
          op_ctx: OperationContext,
      ) =
        mixin new_ident_node
        if bin != "":
          debug "creating received object", id
          if not ctx.subscribing and id notin ctx:
            var value = bin.from_flatty(T, ctx)
            discard Ed.init(value, ctx = ctx, id = id, flags = flags, op_ctx)
          elif not ctx.subscribing:
            debug "restoring received object", id
            var value = bin.from_flatty(T, ctx)
            let item = Ed[T, O](ctx[id])
            let was_placeholder = item.placeholder
            ctx.filling = was_placeholder # fill of a placeholder → tag Fill
            item.placeholder = false # fill: real state arrived
            `value=`(item, value, op_ctx = op_ctx)
            ctx.filling = false
            if was_placeholder:
              relay_fill(item, op_ctx)
          else:
            if id notin ctx:
              discard Ed[T, O].init(ctx = ctx, id = id, flags = flags, op_ctx)

            let initializer = proc() =
              debug "deferred restore of received object value", id
              {.gcsafe.}:
                let value = bin.from_flatty(T, ctx)
              let item = Ed[T, O](ctx[id])
              let was_placeholder = item.placeholder
              ctx.filling = was_placeholder # fill of a placeholder → tag Fill
              item.placeholder = false # fill: real state arrived
              `value=`(item, value, op_ctx = op_ctx)
              ctx.filling = false
              if was_placeholder:
                relay_fill(item, op_ctx)
            ctx.value_initializers.add(initializer)
        elif id notin ctx:
          discard Ed[T, O].init(ctx = ctx, id = id, flags = flags, op_ctx)
        else:
          # Empty-body CREATE for an object we were holding as a placeholder:
          # it exists for real now, just with no value yet.
          Ed[T, O](ctx[id]).placeholder = false

proc defaults[T, O](
    self: Ed[T, O],
    ctx: EdContext,
    id: string,
    op_ctx: OperationContext,
    broadcast = true,
): Ed[T, O] =
  privileged
  log_defaults

  create_initializer(self)

  # Register the Ed type name for debugging
  const ed_type_id = Ed[T, O].tid
  const ed_type_name = $Ed[T, O]
  {.gcsafe.}:
    if ed_type_id notin global_type_name_registry[]:
      global_type_name_registry[][ed_type_id] = ed_type_name

  self.id =
    if id == "":
      generate_id()
    else:
      id

  debug "creating zen object", id = self.id

  if self.id in ctx.objects and not ?ctx.objects[self.id]:
    ctx.pack_objects
  ctx.objects[self.id] = self

  # If created inside an `own` scope, record the owner: bake its id into the
  # container and index it, so the owner's `destroy_owned` can tear this down in
  # any context (container teardown is ownership-driven; the lifetime carries
  # callbacks). No scope open → unowned.
  {.gcsafe.}:
    if current_owner_id.len > 0:
      self.owner_id = current_owner_id
      ctx.owned_by.mgetOrPut(current_owner_id, initHashSet[string]()).incl(self.id)

  self.publish_create = proc(
      sub: Subscription, broadcast: bool, op_ctx = OperationContext()
  ) =
    log_defaults "ed publishing"
    trace "publish_create", sub

    {.gcsafe.}:
      let bin = self.tracked.to_flatty
    let id = self.id
    let owner_id = self.owner_id
    let flags = self.flags

    template send_msg(src_ctx, sub) =
      const ed_type_id = self.type.tid

      # Capability filter: don't send an object to a peer that can't materialize
      # its type. Empty `capabilities` = unfiltered (same-build / no handshake).
      if sub.capabilities.len == 0 or ed_type_id in sub.capabilities:
        var msg = Message(
          kind: CREATE,
          obj: bin,
          flags: flags,
          type_id: ed_type_id,
          object_id: id,
          owner_id: owner_id,  # synced ownership (see EdBase.owner_id)
          # source is set by send() based on subscription type
        )

        when defined(ed_trace):
          msg.trace = get_stack_trace()

        src_ctx.send(
          sub, msg, op_ctx, flags = self.flags & {SYNC_ALL_NO_OVERWRITE}
        )

    if sub.kind != BLANK:
      ctx.send_msg(sub)
    if broadcast:
      for sub in ctx.subscribers:
        if sub.ctx_id notin op_ctx.source and
            not (sub.partial and id notin sub.interest):
          ctx.send_msg(sub)
    ctx.tick_reactor

  self.build_message = proc(
      self: ref EdBase, change: BaseChange, id, trace: string
  ): Message =
    var msg = Message(object_id: id, type_id: Ed[T, O].tid)
    # Collections (change object O differs from tracked T) are delta /
    # non-idempotent ops; registers (O is T) are whole-value and idempotent.
    when O isnot T:
      msg.delta = true
    when defined(ed_trace):
      msg.trace = trace
    assert ADDED in change.changes or REMOVED in change.changes or
      TOUCHED in change.changes
    let change = Change[O](change)
    when change.item is Ed:
      msg.change_object_id = change.item.id
    elif change.item is Pair[auto, Ed]:
      # TODO: Properly sync ref keys
      {.gcsafe.}:
        msg.obj = change.item.key.to_flatty
      msg.change_object_id = change.item.value.id
    else:
      var item = ""
      block registered:
        when change.item is ref RootObj:
          if ?change.item:
            var registered_type: RegisteredType
            if change.item.lookup_type(registered_type):
              msg.ref_id = registered_type.tid
              item = registered_type.stringify(change.item)
              break registered
            else:
              debug "type not registered", type_name = change.item.base_type

        {.gcsafe.}:
          item = change.item.to_flatty
      msg.obj = item

    msg.kind =
      if TOUCHED in change.changes:
        TOUCH
      elif ADDED in change.changes:
        ASSIGN
      elif REMOVED in change.changes:
        UNASSIGN
      else:
        fail "Can't build message for changes " & $change.changes
    result = msg

  self.change_receiver = proc(
      self: ref EdBase, msg: Message, op_ctx: OperationContext
  ) =
    assert self of Ed[T, O]
    let self = Ed[T, O](self)

    if msg.kind == DESTROY:
      self.destroy
      return

    when O is Ed:
      let object_id = msg.change_object_id
      if object_id notin self.ctx:
        # Nested object not materialized yet — stand in with a non-broadcasting
        # placeholder so the container op applies and cardinality is correct.
        # Reading the placeholder later triggers a fetch (materialize-on-access).
        discard O.init_placeholder(self.ctx, object_id)
      let item = O(self.ctx.objects[object_id])
    elif O is Pair[auto, Ed]:
      # Workaround for compile issue. This should be `O`, not `O.default.type`.
      type K = generic_params(O.default.type).get(0)
      type V = generic_params(O.default.type).get(1)
      if msg.object_id notin self.ctx:
        when defined(ed_trace):
          echo msg.trace
        # Change for an object we don't have (version skew / not yet
        # materialized). Skip rather than abort, matching the non-Pair path.
        debug "skipping change for missing object", object_id = msg.object_id
        return

      if msg.change_object_id notin self.ctx:
        if msg.kind == UNASSIGN:
          debug "can't find ", obj = msg.change_object_id
          return
        # Value object not materialized yet — placeholder it (see above).
        discard V.init_placeholder(self.ctx, msg.change_object_id)
      let value = V(self.ctx.objects[msg.change_object_id])
      {.gcsafe.}:
        let item = O(key: msg.obj.from_flatty(K, self.ctx), value: value)
    else:
      var item: O
      when item is ref RootObj:
        if msg.obj != "":
          if msg.ref_id != 0:
            var registered_type: RegisteredType
            if lookup_type(msg.ref_id, registered_type):
              item = type(item)(registered_type.parse(self.ctx, msg.obj))
              if not self.ctx.find_ref(item):
                debug "item restored (not found)",
                  item = item.type.name, ref_id = item.ref_id
              else:
                debug "item found (not restored)",
                  item = item.type.name, ref_id = item.ref_id
            else:
              # Unknown ref type — can't parse the item, so skip this change
              # rather than aborting. Forgiving on payload.
              debug "skipping change for unknown ref type", ref_tid = msg.ref_id
              return
          else:
            {.gcsafe.}:
              item = msg.obj.from_flatty(O, self.ctx)
      else:
        {.gcsafe.}:
          item = msg.obj.from_flatty(O, self.ctx)

    if msg.kind == ASSIGN:
      self.assign(item, op_ctx = op_ctx)
    elif msg.kind == UNASSIGN:
      self.unassign(item, op_ctx = op_ctx)
    elif msg.kind == TOUCH:
      self.touch(item, op_ctx = op_ctx)
    else:
      fail "Can't handle message " & $msg.kind

  self.publish_key = proc(
      self: ref EdBase, key_bin: string
  ): tuple[found: bool, msg: Message] {.gcsafe.} =
    # Per-key fetch: build the ADD op for one entry so a partial subscriber can
    # pull it without the whole table. Only meaningful for table containers.
    when O is Pair:
      let self = Ed[T, O](self)
      type K = generic_params(O.default.type).get(0)
      {.gcsafe.}:
        let key = key_bin.from_flatty(K, self.ctx)
      if key in self.tracked:
        let pair = O(key: key, value: self.tracked[key])
        let change = Change[O](changes: {ADDED}, item: pair)
        result = (found: true, msg: self.build_message(self, change, self.id, ""))
    else:
      discard

  assert self.ctx == nil
  self.ctx = ctx

  if broadcast:
    self.publish_create(broadcast = true, op_ctx = op_ctx)
  self

proc init_placeholder*[T, O](
    _: typedesc[Ed[T, O]], ctx: EdContext, id: string
): Ed[T, O] =
  ## A non-broadcasting stand-in for a not-yet-materialized object. Registered in
  ## `ctx.objects` under `id` and marked `placeholder`; no CREATE goes out.
  ## Reading it triggers a fetch; the real state fills it in later.
  # `op_ctx` is only consulted by defaults' broadcast, which we skip.
  result = Ed[T, O](flags: DEFAULT_FLAGS, placeholder: true).defaults(
    ctx, id, OperationContext(), broadcast = false
  )

proc init*(
    T: type Ed,
    flags = DEFAULT_FLAGS,
    ctx = ctx(),
    id = "",
    op_ctx = OperationContext(),
): T =
  ## Initialize an empty `Ed` container of the given type.
  ctx.setup_op_ctx
  T(flags: flags).defaults(ctx, id, op_ctx)

proc init*(
    _: type,
    T: type[string],
    flags = DEFAULT_FLAGS,
    ctx = ctx(),
    id = "",
    op_ctx = OperationContext(),
): Ed[string, string] =
  ctx.setup_op_ctx
  result = Ed[string, string](flags: flags).defaults(ctx, id, op_ctx)

proc init*(
    _: type Ed,
    T: type[ref | object | array | SomeOrdinal | SomeNumber],
    flags = DEFAULT_FLAGS,
    ctx = ctx(),
    id = "",
    op_ctx = OperationContext(),
): Ed[T, T] =
  ctx.setup_op_ctx
  result = Ed[T, T](flags: flags).defaults(ctx, id, op_ctx)

proc init*[T: ref | object | tuple | array | SomeOrdinal | SomeNumber | string | ptr](
    _: type Ed,
    tracked: T,
    flags = DEFAULT_FLAGS,
    ctx = ctx(),
    id = "",
    op_ctx = OperationContext(),
): Ed[T, T] =
  ctx.setup_op_ctx
  var self = Ed[T, T](flags: flags).defaults(ctx, id, op_ctx)

  mutate(op_ctx):
    self.tracked = tracked
  result = self

proc init*[O](
    _: type Ed,
    tracked: set[O],
    flags = DEFAULT_FLAGS,
    ctx = ctx(),
    id = "",
    op_ctx = OperationContext(),
): Ed[set[O], O] =
  ctx.setup_op_ctx
  var self = Ed[set[O], O](flags: flags).defaults(ctx, id, op_ctx)

  mutate(op_ctx):
    self.tracked = tracked
  result = self

proc init*[K, V](
    _: type Ed,
    tracked: Table[K, V],
    flags = DEFAULT_FLAGS,
    ctx = ctx(),
    id = "",
    op_ctx = OperationContext(),
): EdTable[K, V] =
  ctx.setup_op_ctx
  var self = EdTable[K, V](flags: flags).defaults(ctx, id, op_ctx)

  mutate(op_ctx):
    self.tracked = tracked
  result = self

proc init*[O](
    _: type Ed,
    tracked: seq[O],
    flags = DEFAULT_FLAGS,
    ctx = ctx(),
    id = "",
    op_ctx = OperationContext(),
): Ed[seq[O], O] =
  ctx.setup_op_ctx
  var self = Ed[seq[O], O](flags: flags).defaults(ctx, id, op_ctx)

  mutate(op_ctx):
    self.tracked = tracked
  result = self

proc init*[O](
    _: type Ed,
    T: type seq[O],
    flags = DEFAULT_FLAGS,
    ctx = ctx(),
    id = "",
    op_ctx = OperationContext(),
): Ed[seq[O], O] =
  ctx.setup_op_ctx
  result = Ed[seq[O], O](flags: flags).defaults(ctx, id, op_ctx)

proc init*[O](
    _: type Ed,
    T: type set[O],
    flags = DEFAULT_FLAGS,
    ctx = ctx(),
    id = "",
    op_ctx = OperationContext(),
): Ed[set[O], O] =
  ctx.setup_op_ctx
  result = Ed[set[O], O](flags: flags).defaults(ctx, id, op_ctx)

proc init*[K, V](
    _: type Ed,
    T: type Table[K, V],
    flags = DEFAULT_FLAGS,
    ctx = ctx(),
    id = "",
    op_ctx = OperationContext(),
): Ed[Table[K, V], Pair[K, V]] =
  ctx.setup_op_ctx
  result = Ed[Table[K, V], Pair[K, V]](flags: flags).defaults(ctx, id, op_ctx)

proc init*(
    _: type Ed,
    K, V: type,
    flags = DEFAULT_FLAGS,
    ctx = ctx(),
    id = "",
    op_ctx = OperationContext(),
): EdTable[K, V] =
  ctx.setup_op_ctx
  result = EdTable[K, V](flags: flags).defaults(ctx, id, op_ctx)

proc init*[T, O](
    self: var Ed[T, O],
    flags = DEFAULT_FLAGS,
    ctx = ctx(),
    id = "",
    op_ctx = OperationContext(),
) =
  self = Ed[T, O].init(ctx = ctx, flags = flags, id = id, op_ctx = op_ctx)

proc init_ed_fields*[T: object or ref](
    self: T, flags = DEFAULT_FLAGS, ctx = ctx()
): T {.discardable.} =
  ## Initialize all `Ed` fields on an object. Call after creating an object with `Ed` fields.
  result = self
  for field in fields(self.deref):
    when field is Ed:
      field.init(ctx = ctx, flags = flags)

proc init_from*[T: object or ref](
    _: type T, src: T, ctx = ctx()
): T {.discardable.} =
  ## Create an object by looking up `Ed` fields from a source object in a different context.
  result = T()
  for src, dest in fields(src.deref, result.deref):
    when dest is Ed:
      dest = ctx[src]

proc ed*[T](value: T): EdValue[T] =
  ## Convenience constructor for `EdValue`. Creates an `Ed` container holding the given value.
  ## Example: `let name = ed("hello")`
  result = EdValue[T].init(value)

macro bootstrap*(_: type Ed): untyped =
  ## Initialize the `Ed` runtime. Call once at application startup before creating `Ed` containers.
  result = new_stmt_list()
  for initializer in INITIALIZERS:
    result.add initializer
