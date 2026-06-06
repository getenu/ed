import
  std/[
    importutils, isolation, tables, sets, sequtils, algorithm, intsets, locks,
    math, times, strutils, macros, os,
  ]

import pkg/threading/channels {.all.}
import pkg/[flatty, supersnappy]

import
  ed/[core, types {.all.}], ed/zens/[contexts, private, initializers {.all.}]

import ed/components/[private/global_state]

import ./type_registry

var flatty_ctx {.threadvar.}: EdContext

type FlatRef = tuple[tid: int, ref_id: string, item: string]

type ZenFlattyInfo = tuple[object_id: string, tid: int]

privileged

# Short ID helpers for source field optimization

proc get_or_assign_short_id(sub: Subscription, full_id: string): uint8 =
  ## Get existing short ID or assign a new one for our outgoing encoding.
  ## Touches only the outgoing namespace — incoming shorts are tracked
  ## separately in incoming_short_to_id.
  if full_id in sub.id_to_short:
    result = sub.id_to_short[full_id]
  else:
    result = sub.next_short_id
    inc sub.next_short_id
    sub.id_to_short[full_id] = result
    sub.outgoing_short_to_id[result] = full_id

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
  ## Register new ID mappings from an incoming message into the *incoming*
  ## namespace. The peer chose these short IDs independently of ours, so we
  ## must not let them interact with our outgoing allocation.
  for (short_id, full_id) in mappings:
    sub.incoming_short_to_id[short_id] = full_id

proc decode_source(sub: Subscription, source: seq[uint8]): HashSet[string] =
  ## Convert short IDs back to full context ID HashSet.
  for short_id in source:
    if short_id in sub.incoming_short_to_id:
      result.incl sub.incoming_short_to_id[short_id]
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
        # A nested Ed reference we don't hold (a partial replica receiving a
        # pre-populated parent, or a parent that arrived before its child).
        # Stand it in with a placeholder rather than leaving the ref nil; reading
        # it later materializes it (or its own CREATE fills it when it arrives).
        value = value.type.init_placeholder(flatty_ctx, info.object_id)
  else:
    var is_registered: bool
    s.from_flatty(i, is_registered)
    if is_registered:
      var val: FlatRef
      flatty.from_flatty(s, i, val)

      # Prune reclaimed instances before the dedup read so the cursor we reuse
      # can't be dangling (see prune_dead_refs / RefHandle).
      flatty_ctx.prune_dead_refs()
      if val.ref_id in flatty_ctx.ref_pool:
        value = value.type()(flatty_ctx.ref_pool[val.ref_id].obj)
      else:
        var registered_type: RegisteredType
        if lookup_type(val.tid, registered_type):
          value = value.type()(registered_type.parse(flatty_ctx, val.item))
        else:
          # Unknown ref type (version skew / type not compiled here). Leave the
          # ref nil and carry on rather than aborting — forgiving on payload,
          # strict only on the envelope.
          debug "skipping ref for unknown type", ref_tid = val.tid
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

proc to_flatty*(s: var string, x: Lifetime) =
  ## A Lifetime is thread-local handle state (a set of cleanup closures), never
  ## part of the synced value. Skip it — flatty can't serialize `seq[proc]`, and
  ## the receiver mints its own. Mirrors the `proc` override above.
  discard

proc from_flatty*(s: string, i: var int, x: var Lifetime) =
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
  if not buffer:
    sub.chan.send(msg)
  elif sub.chan_buffer.len > 0:
    sub.chan_buffer.add msg
  else:
    var iso = isolate(msg)
    if not sub.chan.try_take(iso):
      sub.chan_buffer.add iso.extract()

proc flush_buffers*(self: EdContext) =
  for sub in self.subscribers:
    if sub.kind == LOCAL and sub.chan_buffer.len > 0:
      let buffer = sub.chan_buffer
      sub.chan_buffer.set_len(0)
      for msg in buffer:
        sub.send_or_buffer(msg, true)

template ed_compress(s: string): string =
  ## Pass-through under `-d:ed_no_compress` — supersnappy's snappy fast-path
  ## over-reads within an allocation, which trips AddressSanitizer (it's a benign
  ## third-party over-read, not our bug). The sanitizer build defines the flag so
  ## ASan can focus on Ed's own memory behaviour; in-process sync uses one build,
  ## so both sides agree on the (un)compressed wire format.
  when defined(ed_no_compress): s else: s.compress

template ed_uncompress(s: string): string =
  when defined(ed_no_compress): s else: s.uncompress

proc remote_body(msg: Message, no_overwrite: bool): string =
  ## The shared, compressed wire body for a remote message — identical across
  ## subscribers (source / id_mappings travel per-subscriber, outside it), so a
  ## fanout serializes + compresses it once.
  var body_msg = msg
  body_msg.source = @[]
  body_msg.id_mappings = @[]
  if no_overwrite:
    body_msg.obj = ""
  result = body_msg.to_flatty.ed_compress

proc send_remote(
    self: EdContext, sub: Subscription, source: HashSet[string], body: string
) =
  ## One remote packet: a small per-subscriber header (source short-ids + any
  ## new mappings) followed by the shared compressed body.
  let (encoded_source, new_mappings) = sub.encode_source(source)
  let packet = (encoded_source, new_mappings, body).to_flatty
  self.bytes_sent += packet.len
  self.reactor.send(sub.connection, packet)
  sub.last_sent_time = epoch_time()
  sent_message_counter.inc(label_values = [self.metrics_label])

proc send*(
    self: EdContext,
    sub: Subscription,
    msg: sink Message,
    op_ctx = OperationContext(),
    flags = DEFAULT_FLAGS,
) =
  log_defaults("ed networking")
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
    sent_message_counter.inc(label_values = [self.metrics_label])
  elif sub.kind == LOCAL and SYNC_ALL_NO_OVERWRITE in flags:
    msg.source_set = source
    msg.obj = ""
    sub.send_or_buffer(msg, self.buffer)
    sent_message_counter.inc(label_values = [self.metrics_label])
  elif sub.kind == REMOTE and SYNC_REMOTE in flags:
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
    self.send_remote(sub, source, remote_body(msg, no_overwrite = false))
  elif sub.kind == REMOTE and SYNC_ALL_NO_OVERWRITE in flags:
    when defined(zen_debug_messages):
      inc self.messages_sent
      inc self.messages_sent_by_kind[msg.kind]
      inc self.messages_by_kind[msg.kind]
    self.send_remote(sub, source, remote_body(msg, no_overwrite = true))

proc fanout(
    self: EdContext,
    msg: sink Message,
    op_ctx: OperationContext,
    flags: set[EdFlags],
    targets: seq[Subscription],
) =
  ## Send `msg` to many subscribers, serializing + compressing the shared remote
  ## body only **once** across the fanout. Local subscribers get the struct (no
  ## serialization). The caller pre-filters `targets` for source/skip rules.
  var source = op_ctx.source
  if source.len == 0:
    source.incl self.id
  var body, body_no_overwrite: string
  for sub in targets:
    if sub.partial and msg.object_id notin sub.interest:
      continue  # partial subscriber: only ops for objects it's interested in
    if sub.capabilities.len > 0 and msg.type_id != 0 and
        msg.type_id notin sub.capabilities:
      # Peer can't materialize this type — never send its ops. type_id == 0
      # (DESTROY / control) isn't type-gated; it's a no-op on a peer that never
      # got the CREATE, and must reach a peer that did.
      continue
    if sub.kind == LOCAL:
      self.send(sub, msg, op_ctx, flags)
    elif sub.kind == REMOTE and SYNC_REMOTE in flags:
      if body.len == 0:
        body = remote_body(msg, no_overwrite = false)
      self.send_remote(sub, source, body)
    elif sub.kind == REMOTE and SYNC_ALL_NO_OVERWRITE in flags:
      if body_no_overwrite.len == 0:
        body_no_overwrite = remote_body(msg, no_overwrite = true)
      self.send_remote(sub, source, body_no_overwrite)

proc publish_destroy*[T, O](self: Ed[T, O], op_ctx: OperationContext) =
  privileged
  log_defaults("ed publishing")

  trace "publishing destroy", ed_id = self.id
  # Build the DESTROY once and stamp it with the global LSN (authority only),
  # so every subscriber receives the same ordered op. DESTROY is ordered like
  # ASSIGN — delete-vs-update is a real conflict (see spike doc).
  var msg = Message(kind: DESTROY, object_id: self.id)
  msg.origin =
    if op_ctx.origin != "":
      op_ctx.origin
    else:
      self.ctx.id
  msg.op_id =
    if op_ctx.op_id != 0: op_ctx.op_id else: self.ctx.next_op_id
  when defined(ed_trace):
    msg.trace = \"{get_stack_trace()}\n\nop:\n{op_ctx.trace}"
  self.ctx.stamp_lsn(msg)

  let targets = self.ctx.subscribers.filter_it(it.ctx_id notin op_ctx.source)
  self.ctx.fanout(msg, op_ctx, self.flags, targets)

  self.ctx.tick_reactor

proc publish_closure(
    self: EdContext, s: Subscription, root_id: string, follow = true
): bool {.discardable.} =
  ## Serve an ownership closure to `s`: BFS from `root_id` over `owned_by`,
  ## publishing every container and following member keys (tid:id) into the
  ## members' own owned sets. Used to serve deep fetches, and to push an
  ## OWNS_MEMBERS collection's member closures *before* the collection itself —
  ## so a partial subscriber's parse links member fields to real containers
  ## instead of minting unregistered husks. Returns whether anything was found.
  ## With `follow`, everything published joins `s.interest` so future ops flow.
  privileged
  var ids = @[root_id]
  var to_publish: seq[string]
  var i = 0
  while i < ids.len:
    let id = ids[i]
    inc i
    if id in self:
      result = true
      to_publish.add id
    if id in self.owned_by:
      result = true
      for owned_id in self.owned_by[id]:
        if owned_id notin ids:
          ids.add owned_id
    let colon = id.find(':')
    if colon > 0:
      let plain = id[colon + 1 .. ^1]
      if plain notin ids:
        ids.add plain
  # Publish deepest-first (reverse BFS): a subscribing context defers value
  # restoration and replays it in arrival order, so a collection's restore —
  # which fires the app's ADDED watchers — must come *after* its members'
  # containers have their values, or the watchers read empty state. Mirrors
  # add_subscriber's newest-first iteration, which is what full replicas rely
  # on for the same reason.
  for j in countdown(to_publish.high, 0):
    let id = to_publish[j]
    if follow:
      s.interest.incl id
    self.objects[id].publish_create(s)

proc serve_key_wants(self: EdContext, object_id: string) =
  ## Serve chained per-key wants that can now be answered — entries for
  ## `object_id` may have just arrived (see forward_request).
  privileged
  if object_id notin self.pending_key_wants or object_id notin self:
    return
  let obj = self.objects[object_id]
  var done: seq[string]
  for key_bin, waiters in self.pending_key_wants[object_id]:
    let reply = obj.publish_key(obj, key_bin)
    if reply.found:
      for waiter in waiters:
        self.send(waiter, reply.msg, OperationContext(), DEFAULT_FLAGS)
      done.add key_bin
  for key_bin in done:
    self.pending_key_wants[object_id].del key_bin
  if self.pending_key_wants[object_id].len == 0:
    self.pending_key_wants.del object_id

proc forward_request(self: EdContext, requester: Subscription, msg: Message) =
  ## Chain a request we can't serve: send it to our other peers (upstream).
  ## The forward makes *us* the requester there, so the answer lands here and
  ## the want-serving hooks relay it back to the original asker. The authority
  ## never forwards (its miss is a real NOT_FOUND), which also terminates any
  ## forwarding cycle in a bidirectional pair.
  var fwd = msg
  fwd.source = @[]
  fwd.id_mappings = @[]
  for sub in self.subscribers:
    if sub.ctx_id == requester.ctx_id:
      continue
    self.send(sub, fwd, OperationContext(), DEFAULT_FLAGS)

proc add_obj_want(self: EdContext, requester: Subscription, msg: Message) =
  ## Remember + chain a whole-object want. Dedup: only the first want for an
  ## id forwards upstream; later askers just join the waiters.
  if msg.object_id in self.pending_obj_wants:
    for want in self.pending_obj_wants[msg.object_id]:
      if want.sub.ctx_id == requester.ctx_id:
        return
    self.pending_obj_wants[msg.object_id].add (requester, msg.deep, msg.follow)
  else:
    self.pending_obj_wants[msg.object_id] = @[(requester, msg.deep, msg.follow)]
    self.forward_request(requester, msg)

proc pack_messages(msgs: seq[Message]): seq[Message] =
  if msgs.len > 1:
    var packed_msg = Message(
      kind: PACKED,
      source: msgs[0].source,
      flags: msgs[0].flags,
      delta: msgs[0].delta,
    )
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
  trace "publish_changes", op_ctx
  if self.ctx.subscribers.len > 0:
    var has_eligible = false
    for sub in self.ctx.subscribers:
      if sub.ctx_id notin op_ctx.source:
        has_eligible = true
        break

    if has_eligible:
      var msgs: seq[Message]
      let id = self.id
      assert id in self.ctx
      let obj = self.ctx.objects[id]

      # OWNS_MEMBERS + partial: a newly added member must arrive *after* its
      # ownership closure, or the subscriber's parse mints husks for the
      # member's container fields. Push the closure to each interested partial
      # target now — these CREATEs are sent immediately, ahead of the ADD ops
      # fanned out below.
      when O is ref:
        if OWNS_MEMBERS in self.flags:
          for sub in self.ctx.subscribers:
            if sub.partial and sub.deep and sub.ctx_id notin op_ctx.source and
                id in sub.interest:
              for change in changes:
                if ADDED in change.changes and ?change.item:
                  let item = RootRef(change.item)
                  if item of EdRef:
                    self.ctx.publish_closure(sub, EdRef(item).id)

      for change in changes:
        if [ADDED, REMOVED, CREATED, TOUCHED].any_it(it in change.changes):
          if REMOVED in change.changes and MODIFIED in change.changes:
            # An assign will trigger both an assign and an unassign on the other
            # side. We only want to send a Removed message when an item is
            # removed from a collection.
            trace "skipping changes"
            continue
          let trace =
            when defined(ed_trace):
              \"{get_stack_trace()}\n\nop:\n{op_ctx.trace}"
            else:
              ""
          msgs.add obj.build_message(obj, change, id, trace)

      msgs = pack_messages(msgs)

      # Tag each op with its origin (the original writer) so writers can dedup
      # their own returned delta ops. Forwards preserve the incoming origin;
      # original mutations stamp our own id.
      let out_origin =
        if op_ctx.origin != "":
          op_ctx.origin
        else:
          self.ctx.id

      # op id identifies the originating write. Forwards preserve the incoming
      # one; an original mutation allocates a fresh id and records it as our
      # latest for this object (used to skip our own superseded echoes).
      let originating = op_ctx.op_id == 0
      let out_op_id =
        if originating: self.ctx.next_op_id else: op_ctx.op_id

      # Authority stamps each ordered op with its global LSN, once, before
      # fanout so every subscriber receives the same LSN.
      for msg in msgs.mitems:
        msg.origin = out_origin
        msg.op_id = out_op_id
        if originating:
          self.ctx.latest_op_id[msg.object_id] = out_op_id
        self.ctx.stamp_lsn(msg)

      if self.ctx.is_authority:
        # Canonical ops originate from the authority. Re-origin the source to us
        # and deliver to ALL subscribers — including the original writer
        # (return-to-source) — so writers learn the canonical order/value and
        # converge. LSN dedup in process_message keeps this idempotent and
        # loop-free (receivers won't echo back to us: we're in their source).
        let canon_ctx = OperationContext.init(source = [self.ctx.id].toHashSet)
        for msg in msgs:
          self.ctx.fanout(msg, canon_ctx, self.flags, self.ctx.subscribers)
      else:
        let targets =
          self.ctx.subscribers.filter_it(it.ctx_id notin op_ctx.source)
        for msg in msgs:
          self.ctx.fanout(msg, op_ctx, self.flags, targets)

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
    if sub.partial and id notin sub.interest:
      continue  # partial subscriber: only push objects it's interested in
    if id notin remote_objects or push_all:
      debug "sending object on subscribe",
        from_ctx = self.id, to_ctx = sub.ctx_id, ed_id = id

      let zen = self.objects[id]
      if sub.partial and sub.deep and OWNS_MEMBERS in zen.flags:
        # Push the members' closures before the collection itself, so the
        # subscriber's parse links member fields to real containers (no husks).
        # Members are indexed under the collection's owner — or under the
        # collection's own id when it's ownerless (the root units list).
        let member_owner = if zen.owner_id.len > 0: zen.owner_id else: id
        self.publish_closure(sub, member_owner)
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
  # Purge the subscriber's chained wants so nothing is served to a dead sub.
  var empty_ids: seq[string]
  for id, wants in self.pending_obj_wants.mpairs:
    wants = wants.filter_it(it.sub.ctx_id != sub.ctx_id)
    if wants.len == 0:
      empty_ids.add id
  for id in empty_ids:
    self.pending_obj_wants.del id
  var empty_objs: seq[string]
  for id, keys in self.pending_key_wants.mpairs:
    var empty_keys: seq[string]
    for key_bin, waiters in keys.mpairs:
      waiters = waiters.filter_it(it.ctx_id != sub.ctx_id)
      if waiters.len == 0:
        empty_keys.add key_bin
    for key_bin in empty_keys:
      keys.del key_bin
    if keys.len == 0:
      empty_objs.add id
  for id in empty_objs:
    self.pending_key_wants.del id

# Defined after `tick` (which it pumps); forward-declared so `subscribe` can wire
# it onto each subscribing context.
proc materialize_impl(self: EdContext, id: string) {.gcsafe.}

proc process_value_initializers(self: EdContext) =
  debug "running deferred initializers", ctx = self.id
  for initializer in self.value_initializers:
    initializer()
  self.value_initializers = @[]

proc subscribe*(
    self: EdContext,
    ctx: EdContext,
    bidirectional = true,
    partial = false,
    fetch: open_array[string] = [],
    deep = false,
) =
  ## Subscribe to another local context for cross-thread sync. When `partial`,
  ## we only receive the objects in `fetch` (and ids we `fetch` later) — the
  ## authority→us direction is filtered; our own writes still flow to it. The
  ## fetched ids land in the registry, so `ctx[id]` works for them afterwards.
  privileged
  debug "local subscribe", ctx = self.id
  self.materialize = materialize_impl # enable materialize-on-access
  self.pack_objects
  var remote_objects: HashSet[string]
  for id in self.objects.keys:
    remote_objects.incl id
  self.subscribing = true
  ctx.add_subscriber(
    Subscription(
      kind: LOCAL,
      chan: self.chan,
      ctx_id: self.id,
      partial: partial,
      deep: deep,
      interest: fetch.toHashSet,
    ),
    push_all = bidirectional,
    remote_objects,
  )

  self.tick(blocking = false, min_duration = Duration.default)
  self.subscribing = false
  self.process_value_initializers

  if bidirectional:
    # Reverse direction (us → authority) stays full: we push our own writes.
    ctx.subscribe(self, bidirectional = false)

proc fetch*(
    self: EdContext, object_id: string, deep = false, follow = true
): Fetch {.discardable.} =
  ## Ask the authority for `object_id`. Returns a handle that resolves on a
  ## later tick: `Found` (with `obj` linking the container) when it arrives, or
  ## `NotFound` if the authority NACKs. Already holding it loaded resolves
  ## immediately; fetching an id already in flight returns the same handle.
  ##
  ## `follow` (default) registers interest with the authority, so future ops
  ## follow — and a *missing* id is delivered whenever something creates it
  ## (the handle still resolves NotFound for "not there right now").
  ## `follow = false` is a snapshot: current state only, nothing afterwards.
  ##
  ## `deep` also fetches everything the id *owns* (the synced-ownership closure,
  ## recursively) — so an owner id (a unit, which isn't itself a container) pulls
  ## its whole owned state in one request. The already-loaded short-circuit is
  ## skipped for deep fetches: holding the root says nothing about the closure.
  if not deep and object_id in self and not self.objects[object_id].placeholder:
    return Fetch(id: object_id, state: Found, obj: self.objects[object_id])
  if object_id in self.fetches and self.fetches[object_id].state == Pending:
    return self.fetches[object_id]
  result = Fetch(id: object_id, state: Pending)
  self.fetches[object_id] = result
  var msg =
    Message(kind: REQUEST, object_id: object_id, deep: deep, follow: follow)
  for sub in self.subscribers:
    self.send(sub, msg, OperationContext(), DEFAULT_FLAGS)
  self.tick_reactor

proc flush_key_requests(self: EdContext) =
  ## Send the per-key fetches buffered since the last tick — one REQUEST per
  ## table, carrying the batch of serialized keys in `obj`. The authority replies
  ## with an ADD op per found key (see the REQUEST handler).
  if self.pending_key_requests.len == 0:
    return
  let pending = self.pending_key_requests
  self.pending_key_requests.clear
  for object_id, keys in pending:
    let msg = Message(kind: REQUEST, object_id: object_id, obj: keys.to_flatty)
    for sub in self.subscribers:
      self.send(sub, msg, OperationContext(), DEFAULT_FLAGS)
  self.tick_reactor

proc subscribe*(
    self: EdContext,
    address: string,
    bidirectional = true,
    partial = false,
    fetch: open_array[string] = [],
    deep = false,
    callback: proc() {.gcsafe.} = nil,
) =
  ## Subscribe to a remote context for network sync. Address format: "host" or
  ## "host:port". When `partial`, the authority only sends the objects in `fetch`
  ## (and ids fetched later); the reference graph + materialize-on-access pull the
  ## rest. Mirrors the local `subscribe(partial = ..., fetch = ...)`.
  var address = address
  var port = 9632

  debug "remote subscribe", address
  self.materialize = materialize_impl # enable materialize-on-access
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
  # The SUBSCRIBE carries, in `obj`, the subscriber's handshake: the type-ids it
  # can materialize (capability filter; see ref-registration.md) plus its
  # partial-replica interest (partial flag + root ids). The authority applies all
  # three to the subscription it creates for us.
  let type_ids = block:
    {.gcsafe.}:
      toSeq(type_initializers.keys)
  let handshake = (type_ids, partial, @fetch, deep).to_flatty
  self.send(
    Subscription(
      kind: REMOTE,
      ctx_id: "temp",
      connection: connection,
      last_sent_time: epoch_time(),
    ),
    Message(kind: SUBSCRIBE, obj: handshake),
  )

  var ctx_id = ""
  var received_objects: HashSet[string]
  var finished = false
  var remote_objects: HashSet[string]
  var last_progress = epoch_time()
  while not finished:
    self.reactor.tick
    self.dead_connections &= self.reactor.dead_connections
    for conn in self.dead_connections:
      if connection == conn:
        raise ConnectionError.init(\"Unable to connect to {address}:{port}")

    var got_messages = false
    for msg in self.reactor.messages:
      got_messages = true
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
    if got_messages:
      last_progress = epoch_time()
    # reactor.tick is non-blocking, so an unyielding loop pegs a core for the
    # whole connect-timeout window when the peer is down. Spin hot at first so a
    # healthy handshake (sub-ms on localhost) is timing-identical to before, then
    # yield once we've gone a while with no traffic — the peer is gone and we're
    # just waiting out the timeout.
    elif epoch_time() - last_progress > 0.2:
      sleep 1

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

  if self.id in source:
    # Routing invariant violated: a message tagged with our own id arrived
    # back at us. With the publish-side filter and the SUBSCRIBE-time stale
    # subscription sweep this should be unreachable for any well-behaved
    # client. If it fires, treat it as a bug rather than swallowing it.
    error "own_message_assert",
      ctx = self.id,
      source = source.to_seq.join(","),
      kind = $msg.kind,
      sub_kind = (if sub.is_nil: "nil" else: $sub.kind),
      raw_source = msg.source.map_it($it).join(","),
      sub_ctx = (if sub.is_nil: "nil" else: sub.ctx_id)
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

  # Ordered-op idempotency: a stamped op at or below our frontier was already
  # applied or superseded — drop it. lsn == 0 (CREATE / unordered) always
  # proceeds. Gap/reorder buffering (lsn > frontier + 1) is deferred to the
  # network phase; cross-thread delivery is FIFO from a single sequencer.
  if msg.lsn > 0 and msg.lsn <= self.applied_lsn:
    debug "skipping already-applied op",
      lsn = msg.lsn, frontier = self.applied_lsn
    return

  # Own-op reconciliation: an op we originated, echoed back canonically.
  #  - Collections (delta): already applied optimistically — skip to avoid
  #    double-applying (a seq.add would duplicate).
  #  - Registers: skip only if a *later* write of ours supersedes this echo
  #    (op_id < our latest for this object) — that's what stops a moving entity
  #    snapping back to its own stale echoes. Our *latest* own write (op_id ==
  #    latest) is applied, so a contended register still converges to the
  #    canonical value. (The op_id-superseded rule; see reconciliation-design.md.)
  if msg.origin == self.id:
    let superseded =
      msg.delta or
      msg.op_id < self.latest_op_id.getOrDefault(msg.object_id, 0'i64)
    if superseded:
      if msg.lsn > self.applied_lsn:
        self.applied_lsn = msg.lsn
      return
    # else: our latest own write — fall through and apply it.

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
    if msg.lsn > self.applied_lsn:
      self.applied_lsn = msg.lsn
  elif msg.kind == CREATE:
    {.gcsafe.}:
      if msg.type_id notin type_initializers:
        # Unknown type: a version-skewed peer or a type this context wasn't
        # compiled with. Skip it rather than aborting — the consistency layer no
        # longer needs every object present to trust the rest. (Relaying unknown
        # types through the authority is a separate, future step.)
        debug "skipping create for unknown type",
          type_id = msg.type_id, object_id = msg.object_id
        return

    {.gcsafe.}:
      let fn = type_initializers[msg.type_id]
      # Synced ownership: materialize INSIDE the owner's scope, not after — the
      # initializer (`defaults`) re-broadcasts the CREATE to our own subscribers
      # while it runs (a relay: e.g. worker -> node ctx for an object an MCP
      # client built), so owner_id must be stamped before that re-broadcast or
      # second-hop contexts receive it unowned.
      template materialize_it() =
        fn(
          msg.obj,
          self,
          msg.object_id,
          msg.flags,
          OperationContext.init(
            source = source, ctx = self, origin = msg.origin, op_id = msg.op_id
          ),
        )

      if msg.owner_id.len > 0:
        msg.owner_id.own:
          materialize_it()
      else:
        materialize_it()
      # :(
    # Safety net for paths where the initializer fills an existing object (a
    # placeholder) rather than running `defaults` — stamp + index after the fact.
    # Keyed by owner id, so arrival order vs. the owner doesn't matter.
    if msg.owner_id.len > 0 and msg.object_id in self.objects and
        ?self.objects[msg.object_id]:
      self.objects[msg.object_id].owner_id = msg.owner_id
      self.owned_by.mgetOrPut(msg.owner_id, initHashSet[string]()).incl(
        msg.object_id
      )
    # Resolve fetch handles: the object itself and — for a deep fetch of an
    # *owner* id — the owner its containers point back to (the owner has no
    # container of its own, so its handle resolves via the arriving closure).
    if msg.object_id in self.fetches:
      let pending_fetch = self.fetches[msg.object_id]
      pending_fetch.state = Found
      if msg.object_id in self.objects and ?self.objects[msg.object_id]:
        pending_fetch.obj = self.objects[msg.object_id]
      self.fetches.del(msg.object_id)
    if msg.owner_id.len > 0 and msg.owner_id in self.fetches:
      self.fetches[msg.owner_id].state = Found
      self.fetches.del(msg.owner_id)
    # Serve chained wants (see forward_request): whoever asked while we didn't
    # have it. Deep wants serve the closure — its CREATEs precede this one
    # (deepest-first publish); owner-only ids resolve via msg.owner_id.
    template serve_obj_wants(id: string) =
      if id in self.pending_obj_wants:
        let wants = self.pending_obj_wants[id]
        self.pending_obj_wants.del(id)
        for want in wants:
          if want.follow:
            want.sub.interest.incl id
          if want.deep:
            discard self.publish_closure(want.sub, id, follow = want.follow)
          elif id in self.objects and ?self.objects[id]:
            self.objects[id].publish_create(want.sub)

    serve_obj_wants(msg.object_id)
    if msg.owner_id.len > 0:
      serve_obj_wants(msg.owner_id)
    # A fill can bring table entries chained key-waiters are waiting on.
    self.serve_key_wants(msg.object_id)
    # The creator is interested in its own object: make sure its canonical ops
    # flow back. Matters for partial subscribers; a no-op for full ones.
    for s in self.subscribers:
      if s.ctx_id in source:
        s.interest.incl msg.object_id
  elif msg.kind == NOT_FOUND:
    # The authority NACKed a fetch: resolve the handle so callers (and the
    # blocking `ctx[]` pump) learn promptly instead of waiting out a deadline,
    # and relay the answer to any chained waiters (see forward_request).
    if msg.obj.len > 0:
      # Per-key NACK: a missing key is a *normal* answer (an empty-space voxel
      # chunk). Relay per waiter and clear the wants so nothing dangles.
      if msg.object_id in self.pending_key_wants:
        for key_bin in msg.obj.from_flatty(seq[string]):
          if key_bin in self.pending_key_wants[msg.object_id]:
            for waiter in self.pending_key_wants[msg.object_id][key_bin]:
              self.send(
                waiter,
                Message(
                  kind: NOT_FOUND,
                  object_id: msg.object_id,
                  obj: @[key_bin].to_flatty,
                ),
                OperationContext(),
                DEFAULT_FLAGS,
              )
            self.pending_key_wants[msg.object_id].del key_bin
        if self.pending_key_wants[msg.object_id].len == 0:
          self.pending_key_wants.del msg.object_id
    else:
      if msg.object_id in self.fetches:
        self.fetches[msg.object_id].state = NotFound
        self.fetches.del(msg.object_id)
      if msg.object_id in self.pending_obj_wants:
        for want in self.pending_obj_wants[msg.object_id]:
          self.send(
            want.sub,
            Message(kind: NOT_FOUND, object_id: msg.object_id),
            OperationContext(),
            DEFAULT_FLAGS,
          )
        self.pending_obj_wants.del msg.object_id
  elif msg.kind == REQUEST:
    # A partial subscriber wants data. Two forms:
    #  - whole-object (`obj` empty): add the object to interest and publish_create
    #    it (existing behavior — future ops then follow).
    #  - per-key (`obj` = a batch of serialized table keys): reply with just those
    #    entries (an ADD op each), without adding the whole table to interest.
    # The requester is whoever the message came from — match by ctx id in `source`.
    #
    # Request chaining: a hub that can't serve a request forwards it to its
    # other peers (becoming the requester there) and remembers who asked; the
    # answer — data or NOT_FOUND — relays back down hop by hop. Only misses
    # forward, and only the first want for an id/key does; the authority never
    # forwards (its miss is the real NOT_FOUND).
    for s in self.subscribers:
      if s.ctx_id notin source:
        continue
      if msg.obj.len > 0:
        # Per-key: serve what we have, chain or NACK the rest.
        var missing: seq[string]
        if msg.object_id in self:
          let obj = self.objects[msg.object_id]
          for key_bin in msg.obj.from_flatty(seq[string]):
            let reply = obj.publish_key(obj, key_bin)
            if reply.found:
              self.send(s, reply.msg, OperationContext(), DEFAULT_FLAGS)
            else:
              missing.add key_bin
        else:
          missing = msg.obj.from_flatty(seq[string])
        if missing.len > 0:
          if self.is_authority:
            self.send(
              s,
              Message(
                kind: NOT_FOUND,
                object_id: msg.object_id,
                obj: missing.to_flatty,
              ),
              OperationContext(),
              DEFAULT_FLAGS,
            )
          else:
            var to_forward: seq[string]
            for key_bin in missing:
              if msg.object_id notin self.pending_key_wants:
                self.pending_key_wants[msg.object_id] =
                  init_table[string, seq[Subscription]]()
              if key_bin notin self.pending_key_wants[msg.object_id]:
                to_forward.add key_bin
                self.pending_key_wants[msg.object_id][key_bin] = @[s]
              elif s notin self.pending_key_wants[msg.object_id][key_bin]:
                self.pending_key_wants[msg.object_id][key_bin].add s
            if to_forward.len > 0:
              var fwd = msg
              fwd.obj = to_forward.to_flatty
              self.forward_request(s, fwd)
      elif msg.deep:
        # Deep fetch: the id plus its ownership closure (see publish_closure —
        # the requested id may be an *owner*, a unit id with no container of its
        # own, and the walk recurses through owned members into their subtrees).
        let found = self.publish_closure(s, msg.object_id, follow = msg.follow)
        if msg.follow:
          # Follow the root id itself even if nothing exists yet: a later
          # CREATE under this id is then delivered without re-fetching.
          s.interest.incl msg.object_id
        if not found:
          if self.is_authority:
            self.send(
              s,
              Message(kind: NOT_FOUND, object_id: msg.object_id),
              OperationContext(),
              DEFAULT_FLAGS,
            )
          else:
            self.add_obj_want(s, msg)
      else:
        if msg.object_id in self and not self.objects[msg.object_id].placeholder:
          if msg.follow:
            s.interest.incl msg.object_id
          self.objects[msg.object_id].publish_create(s)
        else:
          # Missing — or held only as an unloaded placeholder, which would
          # serve empty state; chain instead so the real data comes back.
          if msg.follow:
            # Keep the interest so a later CREATE under this id is delivered
            # without re-fetching.
            s.interest.incl msg.object_id
          if self.is_authority:
            self.send(
              s,
              Message(kind: NOT_FOUND, object_id: msg.object_id),
              OperationContext(),
              DEFAULT_FLAGS,
            )
          else:
            self.add_obj_want(s, msg)
  elif msg.kind != BLANK:
    if msg.object_id notin self:
      # :( this should throw an error
      debug "missing object", object_id = msg.object_id
      return
    let obj = self.objects[msg.object_id]
    obj.change_receiver(
      obj,
      msg,
      op_ctx = OperationContext.init(
        source = source, ctx = self, origin = msg.origin, op_id = msg.op_id
      ),
    )
    if msg.lsn > self.applied_lsn:
      self.applied_lsn = msg.lsn
    # Ops (table ADDs) may have brought entries chained key-waiters want.
    self.serve_key_wants(msg.object_id)
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

proc bind_lifetime*[T, O](self: Ed[T, O], lifetime: Lifetime, zid: EID) =
  ## Bind an already-registered callback (`zid`) to `lifetime`, so it untracks
  ## when the lifetime finishes. Lets sugar that mints its own zid (`changes`,
  ## enu's `watch`) route teardown through an owner's Lifetime without exposing
  ## the privileged untrack path. Guarded so a manual untrack first — or the
  ## owner dying first — is safe and idempotent.
  privileged
  lifetime.add proc() {.gcsafe.} =
    if not self.destroyed and zid in self.changed_callbacks:
      self.untrack(zid)

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

  # Inside an `own` scope, route this callback's untrack through the owner's
  # lifetime too, so it's torn down when the owner is destroyed (the typical
  # case: a subscription on something the owner doesn't itself own). No scope
  # open → no-op. Idempotent if also bound explicitly.
  {.gcsafe.}:
    if not current_lifetime.is_nil:
      self.bind_lifetime(current_lifetime, zid)

proc track*[T, O](
    self: Ed[T, O], callback: proc(changes: seq[Change[O]], zid: EID) {.gcsafe.}
): EID {.discardable.} =
  assert self.valid
  var zid: EID
  zid = self.track proc(changes: seq[Change[O]]) {.gcsafe.} =
    callback(changes, zid)

  result = zid

proc track*[T, O](
    self: Ed[T, O],
    lifetime: Lifetime,
    callback: proc(changes: seq[Change[O]]) {.gcsafe.},
): EID {.discardable.} =
  ## Like `track`, but the callback's removal is owned by `lifetime`: when the
  ## owner calls `lifetime.finish` the callback untracks automatically — no
  ## manual `zid` bookkeeping. (Standalone Lifetime, per the lifecycle redesign;
  ## becomes the proxy's cleanup set under the future proxy/body split.)
  result = self.track(callback)
  self.bind_lifetime(lifetime, result)

proc untrack_on_destroy*(self: ref EdBase, zid: EID) =
  self.bound_eids.add(zid)

proc parse_remote(
    self: EdContext, raw_msg: netty.Message
): tuple[ok: bool, msg: Message] {.gcsafe.} =
  ## Decode one raw remote packet into a Message (source short-ids + mappings
  ## attached, body uncompressed). ok = false for keepalive pings and unparseable
  ## bytes — a version-skewed peer or stray packet on the same port is dropped,
  ## not fatal. Shared by `tick` and the silent materialize pump so the wire
  ## decode lives in exactly one place.
  if raw_msg.data == "PING":
    return (false, Message())
  try:
    # Wire format: a small per-subscriber header (source short-ids + new
    # mappings) followed by the shared, compressed body (see send_remote).
    let (enc_source, mappings, body) =
      raw_msg.data.from_flatty((seq[uint8], seq[IdMapping], string))
    var msg = body.ed_uncompress.from_flatty(Message, self)
    msg.source = enc_source
    msg.id_mappings = mappings
    return (true, msg)
  except CatchableError, Defect:
    warn "dropping unparseable remote message",
      bytes = raw_msg.data.len, peer = $raw_msg.conn.address
    return (false, Message())

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
  self.flush_key_requests # send this frame's batched per-key fetches

  # Replay whatever a silent (blocking) materialize deferred — at this tick
  # boundary, before new traffic: first the messages it buffered (apply + fire
  # their callbacks), then the Fill callbacks for the object it materialized.
  if self.pending_msgs.len > 0:
    let deferred = self.pending_msgs
    self.pending_msgs = @[]
    for m in deferred:
      self.process_message(m)
  if self.pending_fills.len > 0:
    let fills = self.pending_fills
    self.pending_fills = @[]
    for f in fills:
      f()

  while true:
    if poll:
      # Drain the available batch, then coalesce superseded register updates:
      # a non-delta ASSIGN for an object that a higher-LSN ASSIGN in the same
      # batch overwrites is frontier-advanced but its effect is skipped, so a
      # losing optimistic writer converges to the latest value without applying
      # (or showing) the intermediate one. Deltas (collections) are never
      # coalesced — every add matters.
      var batch: seq[Message]
      while get_mono_time() < timeout and self.chan.try_recv(msg):
        batch.add msg
      if batch.len > 0:
        var latest: Table[string, int64]
        for m in batch:
          if m.kind == ASSIGN and not m.delta and m.lsn > 0 and
              m.lsn > latest.getOrDefault(m.object_id, 0'i64):
            latest[m.object_id] = m.lsn
        for m in batch:
          if m.kind == ASSIGN and not m.delta and m.lsn > 0 and
              m.lsn < latest.getOrDefault(m.object_id, 0'i64):
            if m.lsn > self.applied_lsn:
              self.applied_lsn = m.lsn  # superseded register update: skip effect
          else:
            self.process_message(m)
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
        let parsed = self.parse_remote(raw_msg)
        if not parsed.ok: # keepalive ping or unparseable — already handled
          continue
        var msg = parsed.msg
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

          # Drop any subscription that this SUBSCRIBE supersedes. Two
          # conditions both warrant a sweep:
          #   1. Same ctx_id — the client reused its stable id (same
          #      process reconnect, or a deterministically-assigned id).
          #      Without this the old subscription persists until netty's
          #      ~10s keepalive timeout, during which the publisher can
          #      route messages back to the reconnected peer via the
          #      stale route.
          #   2. Same remote endpoint — a previous client at that
          #      address/port has been replaced by a new process that
          #      happened to get the same UDP source port. Different
          #      ctx_ids, but routing to the old sub's endpoint would now
          #      land in the new process's reactor.
          let new_addr_str = $raw_msg.conn.address
          let stale = self.subscribers.filter_it(
            it.kind == REMOTE and (
              (source_str != "" and source_str != "unknown" and
                it.ctx_id == source_str) or
              $it.connection.address == new_addr_str
            )
          )
          for sub in stale:
            debug "dropping superseded subscription",
              old_ctx_id = sub.ctx_id, new_ctx_id = source_str
            self.unsubscribe(sub)

          # Handshake (capabilities, partial, fetch ids) rides in the SUBSCRIBE `obj`.
          # Empty (older peer) = unfiltered, full replica.
          var caps: HashSet[int]
          var is_partial = false
          var interest: HashSet[string]
          var is_deep = false
          if msg.obj.len > 0:
            let (cap_ids, p, fetch_ids, d) =
              msg.obj.from_flatty((seq[int], bool, seq[string], bool))
            caps = cap_ids.to_hash_set
            is_partial = p
            is_deep = d
            interest = fetch_ids.to_hash_set

          var new_sub = Subscription(
            kind: REMOTE,
            connection: raw_msg.conn,
            ctx_id: source_str,
            last_sent_time: epoch_time(),
            capabilities: caps,
            partial: is_partial,
            deep: is_deep,
            interest: interest,
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

proc materialize_impl(self: EdContext, id: string) {.gcsafe.} =
  ## Wired onto a context at subscribe time and called by the read accessors when
  ## they touch a placeholder (see operations.touch_placeholder). Kicks a fetch;
  ## when in a `blocking` scope, pumps I/O and **silently** materializes just this
  ## object — every other received message and even this object's own Fill
  ## callback are deferred to the next explicit `tick`, so nothing
  ## application-visible happens mid-read (clean reentrancy). Bounded by a deadline
  ## so a gone authority can't hang the caller; it then falls back to the empty
  ## placeholder, same as the non-blocking path. Drains both the local
  ## (cross-thread) and remote (network) transports.
  privileged
  if id in self and ?self.objects[id] and not self.objects[id].placeholder:
    return
  let pending_fetch = self.fetch(id)
  if not self.blocking:
    return

  template triage(candidate: Message) =
    # Apply only the target object's CREATE — or its NOT_FOUND NACK, which
    # resolves the fetch so we stop waiting — silently (callbacks deferred);
    # buffer everything else for the next tick. SUBSCRIBE can't be replayed
    # sub-less, but a blocking *client* shouldn't receive one.
    if candidate.object_id == id and candidate.kind in {CREATE, NOT_FOUND}:
      self.process_message(candidate)
    elif candidate.kind != SUBSCRIBE:
      self.pending_msgs.add candidate

  let deadline = get_mono_time() + init_duration(seconds = 5)
  self.silent = true
  while pending_fetch.state == Pending and get_mono_time() < deadline:
    # Local transport.
    var m: Message
    while self.chan.try_recv(m):
      triage(m)
    # Remote transport — reuse the same wire decode as tick, then resolve the
    # source eagerly so a deferred message processes correctly sub-less later.
    if ?self.reactor:
      self.tick_reactor
      let raws = self.remote_messages
      self.remote_messages = @[]
      for raw_msg in raws:
        let parsed = self.parse_remote(raw_msg)
        if not parsed.ok:
          continue
        var rmsg = parsed.msg
        for s in self.subscribers:
          if s.kind == REMOTE and s.connection == raw_msg.conn:
            s.register_mappings(rmsg.id_mappings)
            rmsg.source_set = s.decode_source(rmsg.source)
            break
        triage(rmsg)
  self.silent = false

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
