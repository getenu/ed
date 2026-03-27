import
  std/[
    importutils, tables, sets, sequtils, algorithm, intsets, locks, math, times,
    strutils, macros,
  ]

import pkg/threading/channels {.all.}
import pkg/[flatty, supersnappy]

import
  ed/[core, types {.all.}],
  ed/zens/[contexts, private, initializers {.all.}]

import ed/components/[private/global_state]

import ./type_registry

var flatty_ctx {.threadvar.}: EdContext

type FlatRef = tuple[tid: int, ref_id: string, item: string]

type ZenFlattyInfo = tuple[object_id: string, tid: int]

privileged

# Short ID helpers for source field optimization

proc get_or_assign_short_id(sub: Subscription, full_id: string): uint8 =
  ## Get existing short ID or assign a new one for this connection.
  if full_id in sub.id_to_short:
    result = sub.id_to_short[full_id]
  else:
    result = sub.next_short_id
    inc sub.next_short_id
    sub.id_to_short[full_id] = result
    sub.short_to_id[result] = full_id

proc encode_source(
    sub: Subscription, source: HashSet[string]
): tuple[source: seq[uint8], mappings: seq[IdMapping]] =
  ## Convert source HashSet to short IDs, returning new mappings for unknown IDs.
  for full_id in source:
    let is_new = full_id notin sub.id_to_short
    let short_id = sub.get_or_assign_short_id(full_id)
    result.source.add short_id
    if is_new:
      result.mappings.add (short_id, full_id)

proc register_mappings(sub: Subscription, mappings: seq[IdMapping]) =
  ## Register new ID mappings from an incoming message.
  for (short_id, full_id) in mappings:
    if short_id notin sub.short_to_id:
      sub.short_to_id[short_id] = full_id
      sub.id_to_short[full_id] = short_id
      # Update next_short_id to avoid conflicts
      if short_id >= sub.next_short_id:
        sub.next_short_id = short_id + 1

proc decode_source(sub: Subscription, source: seq[uint8]): HashSet[string] =
  ## Convert short IDs back to full context ID HashSet.
  for short_id in source:
    if short_id in sub.short_to_id:
      result.incl sub.short_to_id[short_id]
    else:
      result.incl "unknown:" & $short_id

proc `$`*(self: Subscription): string =
  \"{self.kind} subscription for {self.ctx_id}"

proc tick*(
  self: EdContext,
  messages = int.high,
  max_duration = self.max_recv_duration,
  min_duration = self.min_recv_duration,
  blocking = self.blocking_recv,
  poll = true,
) {.gcsafe.}

proc to_flatty*[T: ref RootObj](s: var string, x: T) =
  when x is ref EdBase:
    s.to_flatty not ?x
    if ?x:
      s.to_flatty ZenFlattyInfo((x.id, x.type.tid))
  else:
    var registered_type: RegisteredType
    when compiles(x.id):
      if ?x and x.lookup_type(registered_type):
        s.to_flatty true
        let obj: FlatRef = (
          tid: registered_type.tid,
          ref_id: x.ref_id,
          item: registered_type.stringify(x),
        )

        flatty.to_flatty(s, obj)
        return
    s.to_flatty false
    s.to_flatty not ?x
    if ?x:
      flatty.to_flatty(s, x)

proc from_flatty*[T: ref RootObj](s: string, i: var int, value: var T) =
  privileged

  when value is ref EdBase:
    var is_nil: bool
    s.from_flatty(i, is_nil)
    if not is_nil:
      var info: ZenFlattyInfo
      s.from_flatty(i, info)
      # :(
      if info.object_id in flatty_ctx:
        value = value.type()(flatty_ctx.objects[info.object_id])
  else:
    var is_registered: bool
    s.from_flatty(i, is_registered)
    if is_registered:
      var val: FlatRef
      flatty.from_flatty(s, i, val)

      if val.ref_id in flatty_ctx.ref_pool:
        value = value.type()(flatty_ctx.ref_pool[val.ref_id].obj)
      else:
        var registered_type: RegisteredType
        do_assert lookup_type(val.tid, registered_type)
        value = value.type()(registered_type.parse(flatty_ctx, val.item))
    else:
      var is_nil: bool
      s.from_flatty(i, is_nil)
      if not is_nil:
        value = value.type()()
        value[] = flatty.from_flatty(s, value[].type)

proc to_flatty*(s: var string, x: proc) =
  discard

proc from_flatty*(s: string, i: var int, p: proc) =
  discard

proc to_flatty*(s: var string, p: ptr) =
  s.to_flatty(cast[int](p))

proc to_flatty*(s: var string, p: pointer) =
  discard

proc from_flatty*(s: string, i: var int, p: pointer) =
  discard

proc from_flatty*(s: string, i: var int, p: var ptr) =
  var val: int
  s.from_flatty(i, val)
  p = cast[p.type](val)

proc from_flatty*(bin: string, T: type, ctx: EdContext): T =
  flatty_ctx = ctx
  result = flatty.from_flatty(bin, T)

proc send_or_buffer(sub: Subscription, msg: sink Message, buffer: bool) =
  if buffer and (sub.chan_buffer.len > 0 or sub.chan.full):
    sub.chan_buffer.add msg
  else:
    sub.chan.send(msg)

proc flush_buffers*(self: EdContext) =
  for sub in self.subscribers:
    if sub.kind == LOCAL and sub.chan_buffer.len > 0 and not sub.chan.full:
      let buffer = sub.chan_buffer
      sub.chan_buffer.set_len(0)
      for msg in buffer:
        sub.send_or_buffer(msg, true)

proc send*(
    self: EdContext,
    sub: Subscription,
    msg: sink Message,
    op_ctx = OperationContext(),
    flags = DEFAULT_FLAGS,
) =
  log_defaults("ed networking")
  sent_message_counter.inc(label_values = [self.metrics_label])
  when defined(ed_trace):
    if sub.ctx_id notin self.last_msg_id:
      self.last_msg_id[sub.ctx_id] = 1
    else:
      self.last_msg_id[sub.ctx_id] += 1
    msg.id = self.last_msg_id[sub.ctx_id]

  when defined(dump_ed_objects):
    self.counts[msg.kind] += 1

  # Build source set
  var source = op_ctx.source
  if source.len == 0:
    source.incl self.id

  debug "sending message", msg

  var msg = msg
  if sub.kind == LOCAL and SYNC_LOCAL in flags:
    # Local: just use the HashSet, no encoding needed
    msg.source_set = source
    sub.send_or_buffer(msg, self.buffer)
  elif sub.kind == LOCAL and SYNC_ALL_NO_OVERWRITE in flags:
    msg.source_set = source
    msg.obj = ""
    sub.send_or_buffer(msg, self.buffer)
  elif sub.kind == REMOTE and SYNC_REMOTE in flags:
    # Remote: encode source to short IDs
    let (encoded_source, new_mappings) = sub.encode_source(source)
    msg.source = encoded_source
    msg.id_mappings = new_mappings
    when defined(zen_debug_messages):
      inc self.messages_sent
      inc self.messages_sent_by_kind[msg.kind]
      self.obj_bytes_sent += msg.obj.len
      inc self.messages_by_kind[msg.kind]
      self.obj_bytes_sent_by_kind[msg.kind] += msg.obj.len
      if msg.object_id != "":
        if msg.object_id notin self.obj_bytes_by_id:
          self.obj_bytes_by_id[msg.object_id] = 0
        self.obj_bytes_by_id[msg.object_id] += msg.obj.len
      if msg.type_id != 0:
        if msg.type_id notin self.obj_bytes_by_type:
          self.obj_bytes_by_type[msg.type_id] = 0
        self.obj_bytes_by_type[msg.type_id] += msg.obj.len
    let serialized = msg.to_flatty
    when defined(zen_debug_messages):
      self.pre_compression_bytes += serialized.len
    let data = serialized.compress
    self.bytes_sent += data.len
    self.reactor.send(sub.connection, data)
    sub.last_sent_time = epoch_time()
  elif sub.kind == REMOTE and SYNC_ALL_NO_OVERWRITE in flags:
    # Remote: encode source to short IDs
    let (encoded_source, new_mappings) = sub.encode_source(source)
    msg.source = encoded_source
    msg.id_mappings = new_mappings
    when defined(zen_debug_messages):
      inc self.messages_sent
      inc self.messages_sent_by_kind[msg.kind]
      # obj is empty for NoOverwrite, track 0 bytes
      inc self.messages_by_kind[msg.kind]
    msg.obj = ""
    let serialized = msg.to_flatty
    when defined(zen_debug_messages):
      self.pre_compression_bytes += serialized.len
    let data = serialized.compress
    self.bytes_sent += data.len
    self.reactor.send(sub.connection, data)
    sub.last_sent_time = epoch_time()

proc publish_destroy*[T, O](self: Ed[T, O], op_ctx: OperationContext) =
  privileged
  log_defaults("ed publishing")

  debug "publishing destroy", ed_id = self.id
  for sub in self.ctx.subscribers:
    if sub.ctx_id notin op_ctx.source:
      when defined(ed_trace):
        self.ctx.send(
          sub,
          Message(
            kind: DESTROY,
            object_id: self.id,
            trace: \"{get_stack_trace()}\n\nop:\n{op_ctx.trace}",
          ),
          op_ctx,
          self.flags,
        )
      else:
        self.ctx.send(
          sub, Message(kind: DESTROY, object_id: self.id), op_ctx, self.flags
        )

  self.ctx.tick_reactor

proc pack_messages(msgs: seq[Message]): seq[Message] =
  if msgs.len > 1:
    var packed_msg =
      Message(kind: PACKED, source: msgs[0].source, flags: msgs[0].flags)
    var ops: seq[PackedMessageOperation]

    for msg in msgs:
      if msg.object_id != "":
        assert packed_msg.object_id == "" or
          packed_msg.object_id == msg.object_id

        packed_msg.object_id = msg.object_id
      if msg.type_id != 0:
        assert packed_msg.type_id == 0 or packed_msg.type_id == msg.type_id

        packed_msg.type_id = msg.type_id
      ops.add (msg.kind, msg.ref_id, msg.change_object_id, msg.obj)

    packed_msg.obj = ops.to_flatty
    result = @[packed_msg]
  else:
    result = msgs

proc publish_changes*[T, O](
    self: Ed[T, O], changes: seq[Change[O]], op_ctx: OperationContext
) =
  privileged
  log_defaults("ed publishing")
  debug "publish_changes", op_ctx
  if self.ctx.subscribers.len > 0:
    var msgs: seq[Message]
    let id = self.id
    assert id in self.ctx
    let obj = self.ctx.objects[id]

    for change in changes:
      if [ADDED, REMOVED, CREATED, TOUCHED].any_it(it in change.changes):
        if REMOVED in change.changes and MODIFIED in change.changes:
          # An assign will trigger both an assign and an unassign on the other
          # side. We only want to send a Removed message when an item is
          # removed from a collection.
          debug "skipping changes"
          continue
        let trace =
          when defined(ed_trace):
            \"{get_stack_trace()}\n\nop:\n{op_ctx.trace}"
          else:
            ""
        msgs.add obj.build_message(obj, change, id, trace)

    msgs = pack_messages(msgs)

    for sub in self.ctx.subscribers:
      if sub.ctx_id notin op_ctx.source:
        for msg in msgs:
          self.ctx.send(sub, msg, op_ctx, self.flags)

    self.ctx.tick_reactor

proc add_subscriber*(
    self: EdContext,
    sub: Subscription,
    push_all: bool,
    remote_objects: HashSet[string],
) =
  self.pack_objects
  debug "adding subscriber", sub
  self.subscribers.add sub
  for id in self.objects.keys.to_seq.reversed:
    if id notin remote_objects or push_all:
      debug "sending object on subscribe",
        from_ctx = self.id, to_ctx = sub.ctx_id, ed_id = id

      let zen = self.objects[id]
      zen.publish_create sub
    else:
      debug "not sending object because remote ctx already has it",
        from_ctx = self.id, to_ctx = sub.ctx_id, ed_id = id

proc unsubscribe*(self: EdContext, sub: Subscription) =
  if sub.kind == REMOTE:
    self.reactor.disconnect(sub.connection)
  else:
    # ???
    discard
  self.subscribers.delete self.subscribers.find(sub)
  self.unsubscribed.add sub.ctx_id

proc process_value_initializers(self: EdContext) =
  debug "running deferred initializers", ctx = self.id
  for initializer in self.value_initializers:
    initializer()
  self.value_initializers = @[]

proc subscribe*(self: EdContext, ctx: EdContext, bidirectional = true) =
  ## Subscribe to another local context for cross-thread sync.
  privileged
  debug "local subscribe", ctx = self.id
  self.pack_objects
  var remote_objects: HashSet[string]
  for id in self.objects.keys:
    remote_objects.incl id
  self.subscribing = true
  ctx.add_subscriber(
    Subscription(kind: LOCAL, chan: self.chan, ctx_id: self.id),
    push_all = bidirectional,
    remote_objects,
  )

  self.tick(blocking = false, min_duration = Duration.default)
  self.subscribing = false
  self.process_value_initializers

  if bidirectional:
    ctx.subscribe(self, bidirectional = false)

proc subscribe*(
    self: EdContext,
    address: string,
    bidirectional = true,
    callback: proc() {.gcsafe.} = nil,
) =
  ## Subscribe to a remote context for network sync. Address format: "host" or "host:port".
  var address = address
  var port = 9632

  debug "remote subscribe", address
  if not ?self.reactor:
    self.reactor = new_reactor()
  self.subscribing = true
  let parts = address.split(":")
  assert parts.len in [1, 2],
    "subscription address must be in the format " &
      "`hostname` or `hostname:port`"

  if parts.len == 2:
    address = parts[0]
    port = parts[1].parse_int

  let connection = self.reactor.connect(address, port)
  self.send(
    Subscription(
      kind: REMOTE,
      ctx_id: "temp",
      connection: connection,
      last_sent_time: epoch_time(),
    ),
    Message(kind: SUBSCRIBE),
  )

  var ctx_id = ""
  var received_objects: HashSet[string]
  var finished = false
  var remote_objects: HashSet[string]
  while not finished:
    self.reactor.tick
    self.dead_connections &= self.reactor.dead_connections
    for conn in self.dead_connections:
      if connection == conn:
        raise ConnectionError.init(\"Unable to connect to {address}:{port}")

    for msg in self.reactor.messages:
      self.bytes_received += msg.data.len
      if msg.data.starts_with("ACK:"):
        if bidirectional:
          let pieces = msg.data.split(":")
          ctx_id = pieces[1]
          for id in pieces[2 ..^ 1]:
            remote_objects.incl id

        finished = true
      else:
        self.remote_messages &= msg
    if callback != nil:
      callback()

  # Create bidirectional subscription BEFORE processing messages so mappings get registered
  var bi_sub: Subscription = nil
  if bidirectional:
    bi_sub = Subscription(
      kind: REMOTE,
      connection: connection,
      ctx_id: ctx_id,
      last_sent_time: epoch_time(),
    )
    self.add_subscriber(bi_sub, push_all = false, remote_objects)

  self.tick(poll = false)
  self.subscribing = false
  self.process_value_initializers

  self.tick(blocking = false)

proc process_message(self: EdContext, msg: Message, sub: Subscription = nil) =
  privileged
  log_defaults("ed publishing")

  # Get source: either from source_set (Local) or decode from source (Remote)
  let source =
    if msg.source_set.len > 0:
      # Local message - source_set is already populated
      msg.source_set
    elif sub != nil:
      # Remote message - decode from short IDs
      sub.decode_source(msg.source)
    else:
      # Fallback - shouldn't normally happen
      var fallback: HashSet[string]
      for id in msg.source:
        fallback.incl $id
      fallback

  assert self.id notin source

  received_message_counter.inc(label_values = [self.metrics_label])
  # when defined(ed_trace):
  #   let src = self.name & "-" & source_str
  #   if src in self.last_received_id:
  #     if msg.id != self.last_received_id[src] + 1:
  #       raise_check &"src={src} msg.id={msg.id} " &
  #           &"last={self.last_received_id[src]}. Should be msg.id - 1"
  #   self.last_received_id[src] = msg.id
  debug "receiving", msg, topics = "networking"

  if msg.kind == PACKED:
    let ops = msg.obj.from_flatty(seq[PackedMessageOperation])
    for op in ops:
      var new_msg = Message(
        kind: op.kind,
        object_id: msg.object_id,
        type_id: msg.type_id,
        ref_id: op.ref_id,
        change_object_id: op.change_object_id,
        obj: op.obj,
        flags: msg.flags,
        source: msg.source,
        source_set: msg.source_set,
        id_mappings: msg.id_mappings,
      )

      self.process_message(new_msg, sub)
  elif msg.kind == CREATE:
    {.gcsafe.}:
      if msg.type_id notin type_initializers:
        when defined(ed_partial_subscriber):
          return
        else:
          print msg
          fail "No type initializer for type {msg.type_id}"

    {.gcsafe.}:
      let fn = type_initializers[msg.type_id]
      fn(
        msg.obj,
        self,
        msg.object_id,
        msg.flags,
        OperationContext.init(source = source, ctx = self),
      )
      # :(
  elif msg.kind != BLANK:
    if msg.object_id notin self:
      # :( this should throw an error
      debug "missing object", object_id = msg.object_id
      return
    let obj = self.objects[msg.object_id]
    obj.change_receiver(
      obj, msg, op_ctx = OperationContext.init(source = source, ctx = self)
    )
  else:
    fail "Can't recv a blank message"

proc untrack*[T, O](self: Ed[T, O], zid: EID) =
  privileged
  log_defaults
  assert self.valid

  # :(
  if zid in self.changed_callbacks:
    let callback = self.changed_callbacks[zid]
    if zid notin self.paused_eids:
      callback(@[Change.init(O, {CLOSED})])
    self.ctx.close_procs.del(zid)
    debug "removing close proc", zid
    self.changed_callbacks.del(zid)
  else:
    error "no change callback for zid", zid = zid

proc track*[T, O](
    self: Ed[T, O], callback: proc(changes: seq[Change[O]]) {.gcsafe.}
): EID {.discardable.} =
  ## Register a callback to be called when the container changes. Returns an EID
  ## that can be used to untrack the callback later.
  privileged
  log_defaults

  assert self.valid
  inc self.ctx.changed_callback_eid
  let zid = self.ctx.changed_callback_eid
  self.changed_callbacks[zid] = callback
  debug "adding close proc", zid
  self.ctx.close_procs[zid] = proc() =
    self.untrack(zid)
  result = zid

proc track*[T, O](
    self: Ed[T, O],
    callback: proc(changes: seq[Change[O]], zid: EID) {.gcsafe.},
): EID {.discardable.} =
  assert self.valid
  var zid: EID
  zid = self.track proc(changes: seq[Change[O]]) {.gcsafe.} =
    callback(changes, zid)

  result = zid

proc untrack_on_destroy*(self: ref EdBase, zid: EID) =
  self.bound_eids.add(zid)

proc tick*(
    self: EdContext,
    messages = int.high,
    max_duration = self.max_recv_duration,
    min_duration = self.min_recv_duration,
    blocking = self.blocking_recv,
    poll = true,
) {.gcsafe.} =
  ## Process incoming messages from subscribed contexts. Call regularly to receive updates.
  ticks_counter.inc(label_values = [self.metrics_label])

  pressure_gauge.set(self.pressure, label_values = [self.metrics_label])
  object_pool_gauge.set(
    float self.objects.len, label_values = [self.metrics_label]
  )

  ref_pool_gauge.set(
    float self.ref_pool.len, label_values = [self.metrics_label]
  )

  buffer_gauge.set(
    float self.subscribers.map_it(
      if it.kind == LOCAL: it.chan_buffer.len else: 0
    ).sum,
    label_values = [self.metrics_label],
  )

  chan_remaining_gauge.set(
    float self.chan.remaining, label_values = [self.metrics_label]
  )

  # Always try to send keepalives when booping
  self.tick_keepalives()

  var msg: Message
  self.unsubscribed = @[]
  var count = 0
  self.free_refs
  let timeout =
    if not ?max_duration:
      MonoTime.high
    else:
      get_mono_time() + max_duration
  let recv_until =
    if not ?min_duration:
      MonoTime.low
    else:
      get_mono_time() + min_duration

  self.flush_buffers
  while true:
    if poll:
      while get_mono_time() < timeout and self.chan.try_recv(msg):
        self.process_message(msg)
        inc count

    if ?self.reactor:
      if poll:
        self.tick_reactor

      let messages = self.remote_messages
      self.remote_messages = @[]

      for conn in self.dead_connections:
        let subs = self.subscribers
        for sub in subs:
          if sub.kind == REMOTE and sub.connection == conn:
            self.unsubscribe(sub)

      self.dead_connections = @[]

      for raw_msg in messages:
        inc count
        # Handle keepalive pings - just ignore them (receiving updates lastActiveTime in netty)
        if raw_msg.data == "PING":
          continue
        var msg = raw_msg.data.uncompress.from_flatty(Message, self)
        when defined(zen_debug_messages):
          inc self.messages_received
          self.obj_bytes_received += msg.obj.len
          inc self.messages_by_kind[msg.kind]
          self.obj_bytes_recv_by_kind[msg.kind] += msg.obj.len

        # Find subscription for this connection to decode source
        var sub: Subscription = nil
        for s in self.subscribers:
          if s.kind == REMOTE and s.connection == raw_msg.conn:
            sub = s
            break

        if msg.kind == SUBSCRIBE:
          # New subscriber - create subscription and extract their ID from mappings
          var source_str = ""
          if msg.id_mappings.len > 0 and msg.source.len > 0:
            # First mapping with matching short ID is the sender's ID
            for (short_id, full_id) in msg.id_mappings:
              if msg.source.len > 0 and short_id == msg.source[0]:
                source_str = full_id
                break
          if source_str == "":
            source_str = "unknown"

          var new_sub = Subscription(
            kind: REMOTE,
            connection: raw_msg.conn,
            ctx_id: source_str,
            last_sent_time: epoch_time(),
          )
          # Register all mappings from the subscribe message
          new_sub.register_mappings(msg.id_mappings)

          var remote: HashSet[string]
          self.add_subscriber(new_sub, push_all = true, remote)

          self.pack_objects
          var objects = self.objects.keys.to_seq.join(":")

          let ack_data = "ACK:" & self.id & ":" & objects
          self.bytes_sent += ack_data.len
          self.reactor.send(raw_msg.conn, ack_data)
          sent_message_counter.inc(label_values = [self.metrics_label])
          self.reactor.tick
          self.dead_connections &= self.reactor.dead_connections
          for msg in self.reactor.messages:
            self.bytes_received += msg.data.len
          self.remote_messages &= self.reactor.messages
        else:
          # Regular message - decode source using subscription's mappings
          if sub != nil:
            sub.register_mappings(msg.id_mappings)
          self.process_message(msg, sub)

    if poll == false or
        ((count > 0 or not blocking) and get_mono_time() > recv_until):
      break

proc find_bare_return(n: NimNode): NimNode =
  if n.kind == nnkReturnStmt:
    return n
  if n.kind in {nnkProcDef, nnkFuncDef, nnkLambda, nnkDo}:
    return nil
  for child in n:
    let found = find_bare_return(child)
    if found != nil:
      return found

macro check_no_return*(body: untyped): untyped =
  ## Passthrough macro: emits a compile error if body contains a bare return.
  ## Use inside changes bodies — return exits the callback proc, not the
  ## enclosing proc, and skips remaining changes in the seq.
  let ret = find_bare_return(body)
  if ret != nil:
    error(
      "return is not valid inside a changes body; " &
        "use if/else instead of early return",
      ret,
    )
  result = body

template changes*[T, O](self: Ed[T, O], pause_me, body) =
  let zen = self
  make_discardable block:
    {.line.}:
      zen.track proc(changes: seq[Change[O]], zid {.inject.}: EID) {.gcsafe.} =
        let pause_zid = if pause_me: zid else: 0
        zen.pause(pause_zid):
          for change {.inject.} in changes:
            template added(): bool =
              ADDED in change.changes

            template added(obj: O): bool =
              change.item == obj and added()

            template removed(): bool =
              REMOVED in change.changes

            template removed(obj: O): bool =
              change.item == obj and removed()

            template modified(): bool =
              MODIFIED in change.changes

            template modified(obj: O): bool =
              change.item == obj and modified()

            template touched(): bool =
              TOUCHED in change.changes

            template touched(obj: O): bool =
              change.item == obj and touched()

            template closed(): bool =
              CLOSED in change.changes

            {.line.}:
              check_no_return(body)

template changes*[T, O](self: Ed[T, O], body) =
  changes(self, true, body)

when defined(zen_debug_messages):
  proc get_type_name(tid: int): string =
    {.gcsafe.}:
      if tid in global_type_name_registry[]:
        result = global_type_name_registry[][tid]
      else:
        result = "type_" & $tid

  proc dump_message_stats*(self: ZenContext, label = "") =
    ## Dump message statistics for debugging network sync issues.
    echo "=== ZenContext Message Stats ", label, " ==="
    echo "  bytes_sent: ", self.bytes_sent
    echo "  bytes_received: ", self.bytes_received
    echo "  messages_sent: ", self.messages_sent
    echo "  messages_received: ", self.messages_received
    echo "  obj_bytes_sent: ", self.obj_bytes_sent
    echo "  obj_bytes_received: ", self.obj_bytes_received
    echo "  pre_compression_bytes: ", self.pre_compression_bytes
    echo ""
    echo "  Messages SENT by kind:"
    for kind in MessageKind:
      if self.messages_sent_by_kind[kind] > 0:
        echo "    ",
          kind,
          ": ",
          self.messages_sent_by_kind[kind],
          " msgs, ",
          self.obj_bytes_sent_by_kind[kind],
          " bytes"
    echo ""
    echo "  Messages by kind (total sent+recv):"
    for kind in MessageKind:
      if self.messages_by_kind[kind] > 0:
        echo "    ",
          kind,
          ": ",
          self.messages_by_kind[kind],
          " msgs, sent=",
          self.obj_bytes_sent_by_kind[kind],
          " recv=",
          self.obj_bytes_recv_by_kind[kind]
    echo ""
    echo "  Top objects by bytes sent:"
    var pairs: seq[(string, int)]
    for id, bytes in self.obj_bytes_by_id:
      pairs.add (id, bytes)
    pairs.sort proc(a, b: (string, int)): int =
      b[1] - a[1]
    for i, (id, bytes) in pairs:
      if i >= 20:
        break
      echo "    ", id, ": ", bytes, " bytes"
    echo ""
    echo "  Bytes by type:"
    var type_pairs: seq[(string, int)]
    for tid, bytes in self.obj_bytes_by_type:
      if bytes > 0:
        type_pairs.add (get_type_name(tid), bytes)
    type_pairs.sort proc(a, b: (string, int)): int =
      b[1] - a[1]
    for (name, bytes) in type_pairs:
      echo "    ", name, ": ", bytes, " bytes"
    echo "=== End Stats ==="
