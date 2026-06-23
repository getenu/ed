import std/[typetraits, macros, macrocache, monotimes, times]
import ed/[core, components/private/tracking]
import ed/components/private/global_state
import ed/types {.all.}, ed/zens/[operations, contexts, private]
import ed/lifecycle
import ed/utils/misc # ZenError

# `quote do` (in create_initializer) expands to code referencing `new_ident_node`,
# so it must be in scope here. Re-exported so it also resolves at `Ed.bootstrap`
# expansion sites. Deprecated alias of `ident`; suppress the notice rather than
# rewrite the macro to gen_ast for 0.3.
{.push warning[Deprecated]: off.}
export new_ident_node
{.pop.}

# Per-type registration statements collected at compile time (one per
# instantiated `Ed[T,O]`), emitted by `Ed.bootstrap`. Each is a trivial call --
# `register_initializer(tid, cast[pointer](materialize_received[T,O]))` -- that
# references a NAMED top-level proc, never an inline proc literal. That's what
# lets `Ed.bootstrap` (hence `connect`) expand inside a `unittest test` block: an
# inline `quote do` materializer carries gensym'd params the C codegen drops when
# expanded inside a template.
const INITIALIZERS = CacheSeq"INITIALIZERS"

# Materializers keyed by `Ed[T,O].tid`, stored as raw code pointers (subscribe
# casts back to CreateInitializer).
var type_initializers: Table[int, pointer]

proc ctx(): EdContext =
  Ed.thread_ctx

proc relay_fill*[T, O](item: Ed[T, O], op_ctx: OperationContext) =
  ## Re-broadcast a just-filled placeholder to our own subscribers: they hold
  ## the same id as a placeholder (minted from the same inline ref), and the
  ## relayed CREATE fills theirs and clears their flag -- `loaded` then means
  ## the same thing on every hop. Exported because the generated type
  ## initializer expands at the `Ed.bootstrap` call site, where the private
  ## `publish_create` field isn't reachable.
  privileged
  # The immediate fill runs inside the receive path's owner scope
  # (`msg.owner_id.own:`), but the placeholder was minted ownerless and the
  # post-materialize stamp hasn't run yet -- stamp before relaying, or second
  # hops receive the fill unowned (same window as the create-relay fix). The
  # deferred (subscribe-time) fill runs after the stamp, so `owner_id` is
  # already set there and `current_owner_id` is empty -- both paths covered.
  if current_owner_id.len > 0 and item.owner_id != current_owner_id:
    item.owner_id = current_owner_id
    item.ctx.owned_by.mget_or_put(current_owner_id, init_hash_set[string]()).incl(
      item.id
    )
  item.publish_create(broadcast = true, op_ctx = op_ctx)

proc register_initializer*(ed_type_id: int, p: pointer) =
  ## The single, non-generic home for the `type_initializers` global write.
  ## `subscribe` reads the table from worker threads, so it's GC-shared; the
  ## `{.cast(gcsafe).}` is the same guard `subscribe` uses.
  {.cast(gcsafe).}:
    type_initializers[ed_type_id] = p

proc materialize_received*[T, O](
    bin: string,
    ctx: EdContext,
    id: string,
    flags: set[EdFlags],
    op_ctx: OperationContext,
) =
  ## Materialize or restore a received object of this concrete type. It is
  ## (legitimately) not gcsafe -- it reaches from_flatty/`value=`, which aren't --
  ## and that's fine: it only ever runs via `subscribe`, which guards the call.
  ## `create_initializer` references it through `cast[pointer]`, which launders
  ## the effect so the reference can't poison the gcsafe defaults/init chain.
  if bin != "":
    debug "creating received object", id
    if not ctx.subscribing and id notin ctx:
      var value = bin.from_flatty(T, ctx)
      let item = Ed.init(value, ctx = ctx, id = id, flags = flags, op_ctx)
      ctx.set_body_bytes(item.body, bin.len) # evictor accounting
    elif not ctx.subscribing:
      debug "restoring received object", id
      var value = bin.from_flatty(T, ctx)
      let item = Ed[T, O](ctx[id])
      let was_placeholder = item.placeholder
      let prev_filling = ctx.filling # save: `value=` may nest a fill
      ctx.filling = was_placeholder # fill of a placeholder -> tag Fill
      item.placeholder = false # fill: real state arrived
      `value=`(item, value, op_ctx = op_ctx)
      ctx.filling = prev_filling # restore (not unconditionally false)
      ctx.set_body_bytes(item.body, bin.len) # evictor accounting
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
        let prev_filling = ctx.filling # save: `value=` may nest a fill
        ctx.filling = was_placeholder # fill of a placeholder -> tag Fill
        item.placeholder = false # fill: real state arrived
        `value=`(item, value, op_ctx = op_ctx)
        ctx.filling = prev_filling # restore (not unconditionally false)
        ctx.set_body_bytes(item.body, bin.len) # evictor accounting
        if was_placeholder:
          relay_fill(item, op_ctx)
      ctx.value_initializers.add(initializer)
  elif id notin ctx:
    discard Ed[T, O].init(ctx = ctx, id = id, flags = flags, op_ctx)
    if LAZY in flags:
      # A LAZY container's empty-body CREATE is a *handle*, not a fill:
      # contents arrive per-key (request/release). Placeholder keeps
      # `loaded` false; touch skips LAZY, so reads never materialize the
      # whole table by accident.
      Ed[T, O](ctx[id]).placeholder = true
  else:
    # Empty-body CREATE for an object we were holding as a placeholder:
    # it exists for real now, just with no value yet. LAZY excepted -- its
    # empty-body CREATE is a handle push and says nothing about contents.
    if LAZY notin flags:
      Ed[T, O](ctx[id]).placeholder = false

proc create_initializer[T, O](self: Ed[T, O]) =
  ## Collect this concrete type's registration at COMPILE TIME (the `static`
  ## block runs when `Ed[T, O]` is instantiated). The runtime body is empty, so
  ## this proc -- and its caller `defaults`/`init` -- stay gcsafe. `Ed.bootstrap`
  ## emits the collected statements at its call site.
  ##
  ## The collected statement references the named `materialize_received[T, O]`
  ## via `cast[pointer]` (subscribe casts back). Storing a raw pointer keeps the
  ## emitted code a trivial call -- template-safe, where an inline proc literal's
  ## gensym params would break codegen inside `unittest test` blocks.
  const ed_type_id = self.type.tid
  static:
    INITIALIZERS.add quote do:
      register_initializer(
        ed_type_id, cast[pointer](materialize_received[T, O])
      )

proc defaults[T, O](
    self: Ed[T, O],
    ctx: EdContext,
    id: string,
    op_ctx: OperationContext,
    broadcast = true,
    flags = DEFAULT_FLAGS,
    placeholder = false,
): Ed[T, O] =
  privileged
  log_defaults

  # The proxy/body split: the body carries the data + sync state; field access
  # on the proxy forwards to it (types.nim templates). Minted here -- before
  # anything reads a forwarded field -- since object construction can no longer
  # set what are now body fields.
  let body = EdBody[T, O](flags: flags, placeholder: placeholder)
  self.body = body

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
  # The registry owns the body; the proxy is reachable through the backref +
  # mint (resolve_proxy). `ctx_uid` by value so the handle's destructor never
  # dereferences the context.
  ctx.objects[self.id] = body
  let ctx_uid = ctx.uid
  body.mint = proc(): ref EdBase {.gcsafe.} =
    let proxy = Ed[T, O](body: body)
    inc body.proxy_gen
    proxy.proxy_handle = ProxyHandle(
      ctx_uid: ctx_uid, object_id: body.id, gen: body.proxy_gen
    )
    body.proxy = proxy
    proxy
  body.untrack_zid = proc(zid: EID) {.gcsafe.} =
    # Context-level untrack: only meaningful while a proxy is live -- a dead
    # proxy's callbacks died with it. Prune first so the backref read is safe.
    if body.ctx != nil:
      body.ctx.prune_dead_proxies
    if zid in body.changed_callbacks:
      # Mirrors proxy-level `untrack` (defined downstream in subscriptions --
      # not importable here): CLOSED notification, then drop the callback.
      # `it` is the live proxy or nil -- callbacks are body-side now.
      let callback = body.changed_callbacks[zid]
      if zid notin body.paused_eids:
        callback(@[Change.init(O, {CLOSED})], body.proxy)
      body.changed_callbacks.del(zid)
      body.callback_gens.del(zid)
  body.sweep_gen = proc(gen: int): seq[EID] {.gcsafe.} =
    for zid, g in tables.pairs(body.callback_gens):
      if g == gen:
        result.add zid
    for zid in result:
      body.changed_callbacks.del(zid)
      body.callback_gens.del(zid)
  body.proxy_gen = 1
  body.proxy = self
  self.proxy_handle =
    ProxyHandle(ctx_uid: ctx_uid, object_id: self.id, gen: 1)

  # If created inside an `own` scope, record the owner: bake its id into the
  # container and index it, so the owner's `destroy_owned` can tear this down in
  # any context (container teardown is ownership-driven; the lifetime carries
  # callbacks). No scope open -> unowned.
  {.gcsafe.}:
    if current_owner_id.len > 0:
      self.owner_id = current_owner_id
      ctx.owned_by.mget_or_put(current_owner_id, init_hash_set[string]()).incl(self.id)

  self.body.publish_create = proc(
      sub: Subscription,
      broadcast: bool,
      op_ctx = OperationContext(),
      contents = true,
  ) =
    log_defaults "ed publishing"
    trace "publish_create", sub

    {.gcsafe.}:
      # `contents = false` sends a handle: an empty-body CREATE (id + flags,
      # no data). Used to push LAZY containers to partial subscribers -- the
      # receiver registers a placeholder and pulls entries per-key.
      let bin = if contents: body.tracked.to_flatty else: ""
    let id = body.id
    let owner_id = body.owner_id
    let flags = body.flags

    template send_msg(src_ctx, sub) =
      const ed_type_id = Ed[T, O].tid

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
          sub, msg, op_ctx, flags = body.flags & {SYNC_ALL_NO_OVERWRITE}
        )

    if sub.kind != BLANK:
      ctx.send_msg(sub)
    if broadcast:
      for sub in ctx.subscribers:
        if sub.ctx_id notin op_ctx.source and
            not (sub.partial and id notin sub.interest):
          ctx.send_msg(sub)
    ctx.tick_reactor

  self.body.build_message = proc(
      body: ref EdBodyBase, change: BaseChange, id, trace: string
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
    when change.item is Pair:
      # Sender-side per-key filter tag (LAZY tables / key interest) -- blanked
      # from the remote body, so it costs nothing on the wire.
      {.gcsafe.}:
        msg.key_bin = change.item.key.to_flatty
    when change.item is Ed:
      msg.change_object_id = change.item.id
    elif change.item is Pair[auto, Ed]:
      # EdTable whose value is an Ed container (e.g. EdTable[Vector3, EdSeq]):
      # the value syncs by id, the key by value. Ref-typed keys aren't supported
      # here -- `to_flatty` nils refs, so the key wouldn't round-trip.
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

  self.body.change_receiver = proc(
      body: ref EdBodyBase, msg: Message, op_ctx: OperationContext
  ) =
    # Resolve (minting if none is live) the typed proxy: assign/unassign and
    # callback triggering run through it. A fresh mint simply has no app
    # callbacks to fire.
    let self = Ed[T, O](body.ctx.resolve_proxy(body))

    if msg.kind == DESTROY:
      # Forward the upstream op-source so the re-broadcast (relay) filters the
      # contexts this DESTROY already visited -- otherwise it echoes back to its
      # origin and, out of order with the reload stream, can kill a same-id
      # recreate.
      self.destroy(op_ctx = op_ctx)
      return

    when O is Ed:
      let object_id = msg.change_object_id
      if object_id notin self.ctx:
        # Nested object not materialized yet -- stand in with a non-broadcasting
        # placeholder so the container op applies and cardinality is correct.
        # Reading the placeholder later triggers a fetch (materialize-on-access).
        discard O.init_placeholder(self.ctx, object_id)
      let item = O(self.ctx.resolve_proxy(self.ctx.objects[object_id]))
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
        # Value object not materialized yet -- placeholder it (see above).
        discard V.init_placeholder(self.ctx, msg.change_object_id)
      let value = V(self.ctx.resolve_proxy(self.ctx.objects[msg.change_object_id]))
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
              # Unknown ref type -- can't parse the item, so skip this change
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

  self.body.publish_key = proc(
      body: ref EdBodyBase, key_bin: string
  ): tuple[found: bool, msg: Message, nested: seq[string]] {.gcsafe.} =
    # Per-key fetch: build the ADD op for one entry so a partial subscriber can
    # pull it without the whole table. `nested` carries the ids of Ed
    # containers inside the value (a chunk's delta seq) so the caller can
    # publish them ahead of the entry -- per-key deep. Only meaningful for
    # table containers.
    when O is Pair:
      let self = Ed[T, O](body.ctx.resolve_proxy(body))
      type K = generic_params(O.default.type).get(0)
      {.gcsafe.}:
        let key = key_bin.from_flatty(K, self.ctx)
      if key in self.tracked:
        let pair = O(key: key, value: self.tracked[key])
        var nested: seq[string]
        when pair.value is Ed:
          if ?pair.value:
            nested.add pair.value.id
        elif pair.value is ref:
          if ?pair.value:
            for _, field in pair.value[].field_pairs:
              when field is Ed:
                if ?field:
                  nested.add field.id
        let change = Change[O](changes: {ADDED}, item: pair)
        result = (
          found: true,
          msg: self.build_message(self, change, self.id, ""),
          nested: nested,
        )
    else:
      discard

  self.body.evict_key = proc(
      body: ref EdBodyBase, key_bin: string
  ): tuple[found: bool, nested: seq[string]] {.gcsafe.} =
    # Per-key eviction: drop the entry locally (REMOVED callbacks fire so
    # watchers un-render; nothing publishes -- the authority keeps the data) and
    # report nested Ed containers so the caller can shed them. The local half
    # of `release` and the receiving half of an eviction notice.
    when O is Pair:
      let self = Ed[T, O](body.ctx.resolve_proxy(body))
      type K = generic_params(O.default.type).get(0)
      {.gcsafe.}:
        let key = key_bin.from_flatty(K, self.ctx)
      if key in self.tracked:
        let pair = O(key: key, value: self.tracked[key])
        var nested: seq[string]
        when pair.value is Ed:
          if ?pair.value:
            nested.add pair.value.id
        elif pair.value is ref:
          if ?pair.value:
            for _, field in pair.value[].field_pairs:
              when field is Ed:
                if ?field:
                  nested.add field.id
        self.tracked.del key
        body.ctx.forget_key_bytes(body, key_bin) # shrink used_bytes on evict
        self.trigger_callbacks(@[Change[O](changes: {REMOVED}, item: pair)])
        result = (found: true, nested: nested)
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
  result = Ed[T, O]().defaults(
    ctx, id, OperationContext(), broadcast = false, placeholder = true
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
  T().defaults(ctx, id, op_ctx, flags = flags)

proc init*(
    _: type,
    T: type[string],
    flags = DEFAULT_FLAGS,
    ctx = ctx(),
    id = "",
    op_ctx = OperationContext(),
): Ed[string, string] =
  ctx.setup_op_ctx
  result = Ed[string, string]().defaults(ctx, id, op_ctx, flags = flags)

proc init*(
    _: type Ed,
    T: type[ref | object | array | SomeOrdinal | SomeNumber],
    flags = DEFAULT_FLAGS,
    ctx = ctx(),
    id = "",
    op_ctx = OperationContext(),
): Ed[T, T] =
  ctx.setup_op_ctx
  result = Ed[T, T]().defaults(ctx, id, op_ctx, flags = flags)

proc init*[T: ref | object | tuple | array | SomeOrdinal | SomeNumber | string | ptr](
    _: type Ed,
    tracked: T,
    flags = DEFAULT_FLAGS,
    ctx = ctx(),
    id = "",
    op_ctx = OperationContext(),
): Ed[T, T] =
  ctx.setup_op_ctx
  var self = Ed[T, T]().defaults(ctx, id, op_ctx, flags = flags)

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
  var self = Ed[set[O], O]().defaults(ctx, id, op_ctx, flags = flags)

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
  var self = EdTable[K, V]().defaults(ctx, id, op_ctx, flags = flags)

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
  var self = Ed[seq[O], O]().defaults(ctx, id, op_ctx, flags = flags)

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
  result = Ed[seq[O], O]().defaults(ctx, id, op_ctx, flags = flags)

proc init*[O](
    _: type Ed,
    T: type set[O],
    flags = DEFAULT_FLAGS,
    ctx = ctx(),
    id = "",
    op_ctx = OperationContext(),
): Ed[set[O], O] =
  ctx.setup_op_ctx
  result = Ed[set[O], O]().defaults(ctx, id, op_ctx, flags = flags)

proc init*[K, V](
    _: type Ed,
    T: type Table[K, V],
    flags = DEFAULT_FLAGS,
    ctx = ctx(),
    id = "",
    op_ctx = OperationContext(),
): Ed[Table[K, V], Pair[K, V]] =
  ctx.setup_op_ctx
  result = Ed[Table[K, V], Pair[K, V]]().defaults(ctx, id, op_ctx, flags = flags)

proc init*(
    _: type Ed,
    K, V: type,
    flags = DEFAULT_FLAGS,
    ctx = ctx(),
    id = "",
    op_ctx = OperationContext(),
): EdTable[K, V] =
  ctx.setup_op_ctx
  result = EdTable[K, V]().defaults(ctx, id, op_ctx, flags = flags)

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
  ## Emit the per-type registrations collected at compile time. Expanded by
  ## `connect`, so apps never name it. Each emitted statement is a trivial
  ## `register_initializer(...)` call (see `create_initializer`), so it expands
  ## cleanly inside a `unittest test` block.
  result = new_stmt_list()
  for initializer in INITIALIZERS:
    result.add initializer
