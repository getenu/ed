import
  std/[
    importutils, isolation, tables, sets, sequtils, algorithm, intsets, locks,
    math, times, strutils, macros, os, heapqueue,
  ]

import pkg/threading/channels {.all.}
import pkg/[flatty, supersnappy]

import
  ed/[core, types {.all.}], ed/zens/[contexts, private, initializers {.all.}]

import ed/components/[private/global_state]

import ./type_registry

var flatty_ctx {.threadvar.}: EdContext

type FlatRef = tuple[tid: int, ref_id: string, item: string]

type EdFlattyInfo = tuple[object_id: string, tid: int]

privileged

# Short ID helpers for source field optimization

proc get_or_assign_short_id(sub: Subscription, full_id: string): uint8 =
  ## Get existing short ID or assign a new one for our outgoing encoding.
  ## Touches only the outgoing namespace -- incoming shorts are tracked
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
      s.to_flatty EdFlattyInfo((x.id, x.type.tid))
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
      var info: EdFlattyInfo
      s.from_flatty(i, info)
      if info.object_id in flatty_ctx:
        value = value.type()(flatty_ctx.resolve_proxy(flatty_ctx.objects[info.object_id]))
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
          # ref nil and carry on rather than aborting -- forgiving on payload,
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
  ## part of the synced value. Skip it -- flatty can't serialize `seq[proc]`, and
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
  ## Pass-through under `-d:ed_no_compress` -- supersnappy's snappy fast-path
  ## over-reads within an allocation, which trips AddressSanitizer (it's a benign
  ## third-party over-read, not our bug). The sanitizer build defines the flag so
  ## ASan can focus on Ed's own memory behaviour; in-process sync uses one build,
  ## so both sides agree on the (un)compressed wire format.
  when defined(ed_no_compress): s else: s.compress

template ed_uncompress(s: string): string =
  when defined(ed_no_compress): s else: s.uncompress

proc remote_body(msg: Message, no_overwrite: bool): string =
  ## The shared, compressed wire body for a remote message -- identical across
  ## subscribers (source / id_mappings travel per-subscriber, outside it), so a
  ## fanout serializes + compresses it once.
  var body_msg = msg
  body_msg.source = @[]
  body_msg.id_mappings = @[]
  if no_overwrite:
    body_msg.obj = ""
  result = body_msg.to_flatty.ed_compress

const wire_header = "ED\x01"
  ## Magic + wire-format version, prefixed to every remote packet. flatty is
  ## positional: bytes from an older wire format can decode *cleanly* into
  ## wrong-typed fields and blow up (or corrupt state) deep in processing -- a
  ## version-skewed peer once killed a server silently this way. The prefix
  ## rejects foreign packets at the front door instead. Bump the version byte
  ## whenever the wire format changes.

proc send_remote(
    self: EdContext, sub: Subscription, source: HashSet[string], body: string
) =
  ## One remote packet: the wire header, then a small per-subscriber header
  ## (source short-ids + any new mappings), then the shared compressed body.
  let (encoded_source, new_mappings) = sub.encode_source(source)
  let packet = wire_header & (encoded_source, new_mappings, body).to_flatty
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
    when defined(ed_debug_messages):
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
    when defined(ed_debug_messages):
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
    if sub.partial and msg.kind != DESTROY and msg.object_id notin sub.interest:
      # Partial subscriber: only ops for objects it's interested in. DESTROY is
      # exempt, mirroring the capability gate below: a partial replica can hold
      # ids the authority never learned about (placeholders minted from inline
      # refs during parse), and filtering their DESTROYs strands those bodies
      # forever (the reload leak). A destroy for an id a peer doesn't hold is a
      # cheap no-op.
      continue
    if sub.capabilities.len > 0 and msg.type_id notin sub.capabilities:
      # Peer can't materialize this type -- never send its ops (incl. DESTROY: it
      # never built the type, so it never held the object).
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
  # ASSIGN -- delete-vs-update is a real conflict (see spike doc).
  # type_id rides along for the capability filter (which types a peer can hold),
  # not for construction -- DESTROY tears down by id.
  var msg = Message(kind: DESTROY, object_id: self.id, type_id: Ed[T, O].tid)
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
    self: EdContext, s: Subscription, root_id: string
): bool {.discardable.} =
  ## Serve an ownership closure to `s`: BFS from `root_id` over `owned_by`,
  ## publishing every container and following member keys (tid:id) into the
  ## members' own owned sets. Used to serve deep fetches, and to push an
  ## OWNS_MEMBERS collection's member closures *before* the collection itself --
  ## so a partial subscriber's parse links member fields to real containers
  ## instead of minting unregistered husks. Returns whether anything was found.
  ## Everything published (except LAZY handles) joins `s.interest` so future ops
  ## flow.
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
  # restoration and replays it in arrival order, so a collection's restore --
  # which fires the app's ADDED watchers -- must come *after* its members'
  # containers have their values, or the watchers read empty state. Mirrors
  # add_subscriber's newest-first iteration, which is what full replicas rely
  # on for the same reason.
  for j in countdown(to_publish.high, 0):
    let id = to_publish[j]
    let zen = self.objects[id]
    if LAZY in zen.flags:
      # Pull-only: send a *handle* (empty-body CREATE -- id, type, flags) and
      # don't follow it. The receiver registers a placeholder and pages
      # entries with request/release; a whole-table push would defeat LAZY.
      zen.publish_create(s, contents = false)
    else:
      s.interest.incl id
      zen.publish_create(s)

proc serve_key_wants(self: EdContext, object_id: string) =
  ## Serve chained per-key wants that can now be answered -- entries for
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
        # Handle-first (see the REQUEST handler): the waiter may not hold the
        # container, and an ADD for an unknown object drops silently.
        if not obj.placeholder:
          obj.publish_create(waiter, contents = false)
        # Per-key deep: nested containers (a chunk's delta seq) go first so
        # the receiver's parse links them -- and they're followed, so their
        # future ops stream.
        for nested_id in reply.nested:
          if nested_id in self and not self.objects[nested_id].placeholder:
            waiter.interest.incl nested_id
            self.objects[nested_id].publish_create(waiter)
        self.send(waiter, reply.msg, OperationContext(), DEFAULT_FLAGS)
      done.add key_bin
  for key_bin in done:
    self.pending_key_wants[object_id].del key_bin
  if self.pending_key_wants[object_id].len == 0:
    self.pending_key_wants.del object_id

proc request_targets(self: EdContext): seq[Subscription] =
  ## Who to send a REQUEST to: our upstreams (the contexts we page from).
  ## Never downstream -- a clone's copy of us is stale-by-definition, and
  ## letting it answer can overwrite fresher local state with its echo. Only a
  ## non-authority forwards, and a non-authority pages from a recorded upstream,
  ## so this is non-empty in practice. An empty result means a degenerate
  ## topology (a non-authority with no upstream); rather than fall back to all
  ## subscribers -- which could route the request downstream -- treat it as a bug
  ## (assert in debug, log in release) and forward nowhere.
  for sub in self.subscribers:
    if sub.ctx_id in self.upstream_ctx_ids:
      result.add sub
  if result.len == 0:
    error "request_with_no_upstream", ctx = self.id
    assert false, "request_targets: forwarding with no recorded upstream"

proc forward_request(self: EdContext, requester: Subscription, msg: Message) =
  ## Chain a request we can't serve: send it to our upstream(s).
  ## The forward makes *us* the requester there, so the answer lands here and
  ## the want-serving hooks relay it back to the original asker. The authority
  ## never forwards (its miss is a real NOT_FOUND), which also terminates any
  ## forwarding cycle in a bidirectional pair.
  var fwd = msg
  fwd.source = @[]
  fwd.id_mappings = @[]
  for sub in self.request_targets:
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
    self.pending_obj_wants[msg.object_id].add (requester, msg.deep)
  else:
    self.pending_obj_wants[msg.object_id] = @[(requester, msg.deep)]
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
      ops.add (
        msg.kind, msg.ref_id, msg.change_object_id, msg.obj, msg.delta,
        msg.key_bin,
      )

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
      # target now -- these CREATEs are sent immediately, ahead of the ADD ops
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

      # Per-key interest (LAZY tables): a partial subscriber without
      # whole-object interest still receives ops for keys it has requested --
      # including a key that was missing at request time (an empty-space chunk
      # someone later builds in). Filtered per-sub on the pre-pack messages
      # (each sub's key set differs) and sent unordered (lsn 0), matching
      # per-key pulls. The canonical fanout below skips these subs -- the
      # object isn't in their `interest`.
      for sub in self.ctx.subscribers:
        if sub.partial and id notin sub.interest and
            id in sub.key_interest and sub.ctx_id notin op_ctx.source:
          for msg in msgs.mitems:
            if msg.key_bin.len > 0 and msg.key_bin in sub.key_interest[id]:
              if sub.capabilities.len > 0 and msg.type_id notin sub.capabilities:
                continue
              if msg.kind == ASSIGN and msg.change_object_id.len > 0 and
                  msg.change_object_id in self.ctx and
                  msg.change_object_id notin sub.interest:
                # Ed-valued entry (a chunk's delta seq): send the nested
                # container ahead of the ADD so the receiver links it, and
                # follow it so its future ops stream. RELEASE sheds it.
                sub.interest.incl msg.change_object_id
                self.ctx.objects[msg.change_object_id].publish_create(sub)
              var keyed = msg
              keyed.origin = out_origin
              keyed.op_id = out_op_id
              self.ctx.send(sub, keyed, op_ctx, self.flags)

      msgs = pack_messages(msgs)

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
        # and deliver to ALL subscribers -- including the original writer
        # (return-to-source) -- so writers learn the canonical order/value and
        # converge. LSN dedup in process_message keeps this idempotent and
        # loop-free (receivers won't echo back to us: we're in their source).
        let canon_ctx = OperationContext.init(source = [self.ctx.id].to_hash_set)
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
        # Members are indexed under the collection's owner -- or under the
        # collection's own id when it's ownerless (the root units list).
        let member_owner = if zen.owner_id.len > 0: zen.owner_id else: id
        self.publish_closure(sub, member_owner)
      zen.publish_create sub
    else:
      debug "not sending object because remote ctx already has it",
        from_ctx = self.id, to_ctx = sub.ctx_id, ed_id = id

proc drain_unsubscribed*(self: EdContext): seq[string] =
  ## The ctx ids of peers that unsubscribed (or died) since the last drain.
  ## Accumulates until drained -- consume with this, not by reading the field,
  ## so no event is lost to tick timing.
  result = self.unsubscribed
  self.unsubscribed = @[]

proc unsubscribe*(self: EdContext, sub: Subscription, notify = true) =
  ## Drop `sub` and let the peer know it's gone. REMOTE: disconnect (the peer
  ## sees a dead connection). LOCAL: send an `UNSUBSCRIBE` through its channel so
  ## the peer drops its reverse subscription and stops fanning ops into our inbox
  ## -- there's no keepalive timeout to do it for us. `notify = false` when *we're*
  ## reacting to an incoming `UNSUBSCRIBE`, so the two sides don't ping-pong.
  # Snapshot the id before the delete below: `sub` is a borrowed param (ORC
  # doesn't refcount parameters), and the seq slot is the only owner, so the
  # delete frees it -- every later read must use this local, not `sub`.
  let ctx_id = sub.ctx_id
  if sub.kind == REMOTE:
    self.reactor.disconnect(sub.connection)
  elif notify and sub.kind == LOCAL:
    self.send(sub, Message(kind: UNSUBSCRIBE), OperationContext(), DEFAULT_FLAGS)
  self.subscribers.delete self.subscribers.find(sub)
  self.unsubscribed.add ctx_id
  # Purge the subscriber's chained wants so nothing is served to a dead sub.
  var empty_ids: seq[string]
  for id, wants in self.pending_obj_wants.mpairs:
    wants = wants.filter_it(it.sub.ctx_id != ctx_id)
    if wants.len == 0:
      empty_ids.add id
  for id in empty_ids:
    self.pending_obj_wants.del id
  var empty_objs: seq[string]
  for id, keys in self.pending_key_wants.mpairs:
    var empty_keys: seq[string]
    for key_bin, waiters in keys.mpairs:
      waiters = waiters.filter_it(it.ctx_id != ctx_id)
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
    mode = FULL,
    fetch: open_array[string] = [],
    deep = false,
    upstream = true,
) =
  ## Subscribe to another local context for cross-thread sync. When `mode` is
  ## partial, we only receive the objects in `fetch` (and ids we `fetch` later)
  ## -- the authority->us direction is filtered; our own writes still flow to it.
  ## The fetched ids land in the registry, so `ctx[id]` works for them
  ## afterwards. `ctx` is recorded as our upstream (we're a clone of it --
  ## eviction notices from it are honored); the internal reverse leg passes
  ## `upstream = false` because receiving a client's own writes doesn't make
  ## it our data source.
  privileged
  let partial = mode != FULL
  debug "local subscribe", ctx = self.id
  self.materialize = materialize_impl # enable materialize-on-access
  if upstream:
    self.upstream_ctx_ids.incl ctx.id
  if partial:
    self.sync_mode = mode # FULL subscribes (incl. the reverse leg) don't downgrade
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
      interest: fetch.to_hash_set,
    ),
    push_all = bidirectional,
    remote_objects,
  )

  self.tick(blocking = false, min_duration = Duration.default)
  self.subscribing = false
  self.process_value_initializers

  if bidirectional:
    # Reverse direction (us -> authority) stays full: we push our own writes.
    ctx.subscribe(self, bidirectional = false, upstream = false)

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

const up_live = 1
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

proc fetch*(
    self: EdContext, object_id: string, deep = false
): Fetch {.discardable.} =
  ## Ask the authority for `object_id`. Returns a handle that resolves on a
  ## later tick: `Found` (with `obj` linking the container) when it arrives, or
  ## `NotFound` if the authority NACKs. Already holding it loaded resolves
  ## immediately; fetching an id already in flight returns the same handle.
  ##
  ## Always registers interest, so future ops follow -- and a *missing* id is
  ## delivered whenever something creates it (the handle still resolves NotFound
  ## for "not there right now"). To stop following, drop your reference: with no
  ## live proxy the object becomes an eviction candidate and its interest is
  ## retracted upstream when it's reclaimed (see the evictor / `mem_limit`).
  ##
  ## `deep` also fetches everything the id *owns* (the synced-ownership closure,
  ## recursively) -- so an owner id (a unit, which isn't itself a container) pulls
  ## its whole owned state in one request. The already-loaded short-circuit is
  ## skipped for deep fetches: holding the root says nothing about the closure.
  if not deep and object_id in self and not self.objects[object_id].placeholder:
    return Fetch(
      id: object_id,
      state: Found,
      obj: self.resolve_proxy(self.objects[object_id]),
    )
  if object_id in self.fetches and self.fetches[object_id].state == Pending:
    return self.fetches[object_id]
  result = Fetch(id: object_id, state: Pending)
  self.fetches[object_id] = result
  var msg = Message(kind: REQUEST, object_id: object_id, deep: deep)
  for sub in self.request_targets:
    self.send(sub, msg, OperationContext(), DEFAULT_FLAGS)
  self.tick_reactor

proc flush_key_requests(self: EdContext) =
  ## Send the per-key fetches buffered since the last tick -- one REQUEST per
  ## table, carrying the batch of serialized keys in `obj`. The authority replies
  ## with an ADD op per found key (see the REQUEST handler).
  if self.pending_key_requests.len == 0:
    return
  let pending = self.pending_key_requests
  self.pending_key_requests.clear
  for object_id, keys in pending:
    let msg = Message(kind: REQUEST, object_id: object_id, obj: keys.to_flatty)
    for sub in self.request_targets:
      self.send(sub, msg, OperationContext(), DEFAULT_FLAGS)
  self.tick_reactor

proc flush_key_releases(self: EdContext) =
  ## Send the per-key releases buffered since the last tick -- one RELEASE per
  ## table, broadcast to every peer. Upstream reads it as an interest retract
  ## (ops for those keys stop flowing); downstream clones read it as an
  ## eviction notice and drop the keys too (see the RELEASE handler).
  if self.pending_key_releases.len == 0:
    return
  let pending = self.pending_key_releases
  self.pending_key_releases.clear
  for object_id, keys in pending:
    let msg = Message(kind: RELEASE, object_id: object_id, obj: keys.to_flatty)
    for sub in self.subscribers:
      self.send(sub, msg, OperationContext(), DEFAULT_FLAGS)
  self.tick_reactor

proc subscribe*(
    self: EdContext,
    address: string,
    bidirectional = true,
    mode = FULL,
    fetch: open_array[string] = [],
    deep = false,
    callback: proc() {.gcsafe.} = nil,
) =
  ## Subscribe to a remote context for network sync. Address format: "host" or
  ## "host:port". When `mode` is partial, the authority only sends the objects
  ## in `fetch` (and ids fetched later); the reference graph + materialize-on-
  ## access pull the rest. Mirrors the local `subscribe(mode = ..., fetch =
  ## ...)`. Blocking semantics (PARTIAL vs PARTIAL_ASYNC) live in the context's
  ## `sync_mode`, set here from `mode` -- the handshake only carries the partial
  ## filter (the authority doesn't care whether our reads block).
  var address = address
  var port = 9632
  let partial = mode != FULL

  debug "remote subscribe", address
  self.materialize = materialize_impl # enable materialize-on-access
  if partial:
    self.sync_mode = mode
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
      to_seq(type_initializers.keys)
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
    # yield once we've gone a while with no traffic -- the peer is gone and we're
    # just waiting out the timeout.
    elif epoch_time() - last_progress > 0.2:
      sleep 1

  # Create bidirectional subscription BEFORE processing messages so mappings get registered
  var bi_sub: Subscription = nil
  if bidirectional:
    # The remote is our upstream: we're a clone of (a subset of) it, so its
    # eviction notices apply to us. One-way remote subscribes never learn the
    # peer's ctx_id (no ACK parse), so they can't be eviction targets yet.
    self.upstream_ctx_ids.incl ctx_id
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

  # Any inbound message can change what an eviction sweep would act on (resident
  # bytes, interest, liveness), so mark the sweep dirty. Coarse but cheap; the
  # sweep does its O(objects) work only when this (or a pruned death) is set.
  self.sweep_dirty = true

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
    # Our own id in the source set means a message looped back to us -- the
    # publish-side source filter should prevent it. Skip rather than risk
    # double-applying it, and warn so a routing regression stays visible.
    warn "dropping message that looped back to its source",
      ctx = self.id, kind = $msg.kind, source = source.to_seq.join(",")
    return

  received_message_counter.inc(label_values = [self.metrics_label])
  debug "receiving", msg, topics = "networking"

  # Ordered-op idempotency: a stamped op at or below our frontier was already
  # applied or superseded -- drop it. lsn == 0 (CREATE / unordered) always
  # proceeds. Gap/reorder buffering (lsn > frontier + 1) is deferred to the
  # network phase; cross-thread delivery is FIFO from a single sequencer.
  if msg.lsn > 0 and msg.lsn <= self.applied_lsn:
    debug "skipping already-applied op",
      lsn = msg.lsn, frontier = self.applied_lsn
    return

  # Own-op reconciliation: an op we originated, echoed back canonically.
  #  - Collections (delta): already applied optimistically -- skip to avoid
  #    double-applying (a seq.add would duplicate).
  #  - Registers: skip only if a *later* write of ours supersedes this echo
  #    (op_id < our latest for this object) -- that's what stops a moving entity
  #    snapping back to its own stale echoes. Our *latest* own write (op_id ==
  #    latest) is applied, so a contended register still converges to the
  #    canonical value. (The op_id-superseded rule; see consistency.md.)
  if msg.origin == self.id:
    let superseded =
      msg.delta or
      msg.op_id < self.latest_op_id.get_or_default(msg.object_id, 0'i64)
    if superseded:
      if msg.lsn > self.applied_lsn:
        self.applied_lsn = msg.lsn
      return
    # else: our latest own write -- fall through and apply it.

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
        delta: op.delta,
        key_bin: op.key_bin,
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
        # compiled with. Skip it rather than aborting -- the consistency layer no
        # longer needs every object present to trust the rest. (Relaying unknown
        # types through the authority is a separate, future step.)
        debug "skipping create for unknown type",
          type_id = msg.type_id, object_id = msg.object_id
        return

    {.gcsafe.}:
      # Stored as a raw pointer (see initializers.register_initializer); cast
      # back to the materializer proc type to call it.
      let fn = cast[CreateInitializer](type_initializers[msg.type_id])
      # Synced ownership: materialize INSIDE the owner's scope, not after -- the
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
    # Safety net for paths where the initializer fills an existing object (a
    # placeholder) rather than running `defaults` -- stamp + index after the fact.
    # Keyed by owner id, so arrival order vs. the owner doesn't matter.
    if msg.owner_id.len > 0 and msg.object_id in self.objects and
        ?self.objects[msg.object_id]:
      let body = self.objects[msg.object_id]
      # Ownership transfer isn't supported yet, so an object's owner shouldn't
      # change once set. (When re-home lands, replace this with a drop from
      # owned_by[body.owner_id] before re-indexing under the new owner.)
      invariant(
        body.owner_id.len == 0 or body.owner_id == msg.owner_id,
        "owner_id changed for " & msg.object_id & ": '" & body.owner_id &
          "' -> '" & msg.owner_id & "'",
      )
      body.owner_id = msg.owner_id
      self.owned_by.mget_or_put(msg.owner_id, init_hash_set[string]()).incl(
        msg.object_id
      )
    # Interest tiering (Option 2): a body materialized from an upstream CREATE
    # is one we follow -- mark it live-up so the sweep reconciles its tier as it
    # goes live/cache here. Only on an evicting partial replica with an upstream.
    if self.evicts and self.upstream_ctx_ids.len > 0 and
        msg.object_id in self.objects and self.objects[msg.object_id] != nil:
      if self.objects[msg.object_id].up_tier == 0:
        self.objects[msg.object_id].up_tier = up_live
    # Resolve fetch handles: the object itself and -- for a deep fetch of an
    # *owner* id -- the owner its containers point back to (the owner has no
    # container of its own, so its handle resolves via the arriving closure).
    if msg.object_id in self.fetches:
      let pending_fetch = self.fetches[msg.object_id]
      pending_fetch.state = Found
      if msg.object_id in self.objects and ?self.objects[msg.object_id]:
        pending_fetch.obj = self.resolve_proxy(self.objects[msg.object_id])
      self.fetches.del(msg.object_id)
    if msg.owner_id.len > 0 and msg.owner_id in self.fetches:
      self.fetches[msg.owner_id].state = Found
      self.fetches.del(msg.owner_id)
    # Serve chained wants (see forward_request): whoever asked while we didn't
    # have it. Deep wants serve the closure -- its CREATEs precede this one
    # (deepest-first publish); owner-only ids resolve via msg.owner_id.
    template serve_obj_wants(id: string) =
      if id in self.pending_obj_wants:
        let wants = self.pending_obj_wants[id]
        self.pending_obj_wants.del(id)
        for want in wants:
          want.sub.interest.incl id
          if want.deep:
            discard self.publish_closure(want.sub, id)
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
  elif msg.kind == RELEASE and msg.obj.len == 0:
    # Whole-object release (evictor): a peer dropped object_id entirely.
    #  - From a subscriber: an interest retract -- stop streaming it to them.
    #  - From upstream: an eviction notice -- but a received drop is NEVER
    #    authoritative over a live local hold (Scott's rule). Evict only if we
    #    aren't using it ourselves and nobody below us wants it; otherwise keep
    #    using it and let our own evictor reclaim it when it goes dormant.
    for s in self.subscribers:
      if s.ctx_id notin source:
        continue
      s.interest.excl msg.object_id
      s.interest_cache.excl msg.object_id
      s.key_interest.del msg.object_id
    var from_upstream = false
    for src in source:
      if src in self.upstream_ctx_ids:
        from_upstream = true
        break
    if from_upstream and msg.object_id in self and
        self.objects[msg.object_id].proxy == nil and
        not self.any_interest(msg.object_id):
      self.evict_body(msg.object_id)
  elif msg.kind == INTEREST:
    # Live/cache tier change from a downstream subscriber (Option 2). Demote
    # moves the object to that subscriber's cache tier -- it still streams, but
    # no longer protects the object from our eviction; promote moves it back.
    # Our own up-tier to the authority then reconciles on the next sweep (our
    # aggregate downstream liveness changed).
    for s in self.subscribers:
      if s.ctx_id notin source:
        continue
      if msg.object_id notin s.interest:
        continue
      if msg.demote:
        s.interest_cache.incl msg.object_id
      else:
        s.interest_cache.excl msg.object_id
  elif msg.kind == RELEASE:
    # Per-key paging notice (see `release`). Role decides the meaning:
    #  - From a subscriber that pages from us: an interest retract -- stop
    #    streaming those keys (and the nested containers that rode in with
    #    them). Our copy is untouched; we may serve others.
    #  - From *upstream*: an eviction notice -- our data source dropped the
    #    keys, and we're a clone of it, so they're gone for us too. Evict
    #    locally (REMOVED fires, watches un-render) and relay downstream.
    # A full clone of a full source never receives one (full sources don't
    # release); the authority has no upstream, so it only ever retracts.
    let keys = msg.obj.from_flatty(seq[string])
    var retracted = false
    for s in self.subscribers:
      if s.ctx_id notin source:
        continue
      if msg.object_id in s.key_interest:
        retracted = true
        for key_bin in keys:
          s.key_interest[msg.object_id].excl key_bin
          # Shed the keys' nested containers (the chunk's delta seq) from the
          # follow set, so their ops stop streaming as well.
          if msg.object_id in self:
            let obj = self.objects[msg.object_id]
            let reply = obj.publish_key(obj, key_bin)
            for nested_id in reply.nested:
              s.interest.excl nested_id
        if s.key_interest[msg.object_id].len == 0:
          s.key_interest.del msg.object_id
        # A release can outrun an in-flight chained request: drop the
        # subscriber from any pending wants so the late answer isn't served
        # to someone who no longer wants it (re-materializing a paged-out key).
        if msg.object_id in self.pending_key_wants:
          for key_bin in keys:
            if key_bin in self.pending_key_wants[msg.object_id]:
              self.pending_key_wants[msg.object_id][key_bin] =
                self.pending_key_wants[msg.object_id][key_bin].filter_it(
                  it.ctx_id != s.ctx_id
                )
    if retracted and self.sync_mode != FULL and not self.is_authority and
        self.mem_limit == 0:
      # No-cache hub: shed immediately (the symmetric counterpart of request
      # chaining). When the last interest in a key retracts, drop our copy and
      # chain the release upstream. A caching hub (mem_limit > 0) instead KEEPS
      # the key -- it becomes cache-tier (no live downstream wants it), stays
      # current via the stream, and the per-key cache LRU sheds it under our
      # own pressure (so a downstream's release doesn't force us to refetch on
      # its return).
      for key_bin in keys:
        var still_wanted = false
        for s in self.subscribers:
          if msg.object_id in s.key_interest and
              key_bin in s.key_interest[msg.object_id]:
            still_wanted = true
            break
        if not still_wanted:
          if msg.object_id in self:
            let obj = self.objects[msg.object_id]
            if obj.evict_key != nil:
              let evicted = obj.evict_key(obj, key_bin)
              self.drop_nested_bodies(evicted.nested)
          self.pending_key_releases.mget_or_put(msg.object_id, @[]).add key_bin
    if not retracted:
      var from_upstream = false
      for src in source:
        if src in self.upstream_ctx_ids:
          from_upstream = true
          break
      if from_upstream:
        if msg.object_id in self:
          let obj = self.objects[msg.object_id]
          if obj.evict_key != nil:
            for key_bin in keys:
              let evicted = obj.evict_key(obj, key_bin)
              self.drop_nested_bodies(evicted.nested)
        if not self.is_authority:
          # Relay to our own subscribers (downstream clones); the accumulated
          # source stops it echoing back the way it came.
          var fwd_source = source
          fwd_source.incl self.id
          for s in self.subscribers:
            if s.ctx_id notin fwd_source:
              self.send(
                s, msg, OperationContext(source: fwd_source), DEFAULT_FLAGS
              )
  elif msg.kind == REQUEST:
    # A partial subscriber wants data. Two forms:
    #  - whole-object (`obj` empty): add the object to interest and publish_create
    #    it (existing behavior -- future ops then follow).
    #  - per-key (`obj` = a batch of serialized table keys): reply with just those
    #    entries (an ADD op each), without adding the whole table to interest.
    # The requester is whoever the message came from -- match by ctx id in `source`.
    #
    # Request chaining: a hub that can't serve a request forwards it to its
    # upstream(s) (becoming the requester there) and remembers who asked; the
    # answer -- data or NOT_FOUND -- relays back down hop by hop. Only misses
    # forward, and only the first want for an id/key does; the authority never
    # forwards (its miss is the real NOT_FOUND).
    #
    # A REQUEST only ever arrives from a downstream subscriber that pages from
    # us; it can't come from one of our own upstreams, since upstreams are
    # authorities (or page further up) and never send requests back down. If one
    # does, our copy is a stale subset of theirs and serving it would echo old
    # state over fresher data -- treat it as a bug (assert in debug, log in
    # release) but stay safe by not serving.
    for src in source:
      if src in self.upstream_ctx_ids:
        error "request_from_upstream",
          ctx = self.id, src = src, source = source.to_seq.join(",")
        assert src notin self.upstream_ctx_ids
        return
    for s in self.subscribers:
      if s.ctx_id notin source:
        continue
      if msg.obj.len > 0:
        # Per-key: serve what we have, chain or NACK the rest. Every requested
        # key joins the subscriber's key interest -- found or missing -- so its
        # future ops stream (a missing chunk pops in when someone builds
        # there). RELEASE retracts.
        for key_bin in msg.obj.from_flatty(seq[string]):
          s.key_interest.mget_or_put(msg.object_id, init_hash_set[string]()).incl(
            key_bin
          )
        var missing: seq[string]
        if msg.object_id in self:
          let obj = self.objects[msg.object_id]
          # Handle-first: the requester (or a hub between us) may not hold the
          # container yet -- a chained request can outrun the closure push that
          # carries it. An ADD for an unknown object is dropped on arrival and
          # the want dangles (only the first want per key forwards), so the
          # entry would never load. The empty-body CREATE is idempotent and
          # makes the ADDs below always applicable.
          if not obj.placeholder:
            obj.publish_create(s, contents = false)
          for key_bin in msg.obj.from_flatty(seq[string]):
            let reply = obj.publish_key(obj, key_bin)
            if reply.found:
              if self.has_budget: # recency only feeds the cache LRU
                obj.key_last_read[key_bin] = get_mono_time() # served -> in-view
              # Per-key deep: nested containers (a chunk's delta seq) go
              # first so the receiver's parse links them -- and they're
              # followed, so their future ops (delta appends) stream.
              for nested_id in reply.nested:
                if nested_id in self and not self.objects[nested_id].placeholder:
                  s.interest.incl nested_id
                  self.objects[nested_id].publish_create(s)
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
        # Deep fetch: the id plus its ownership closure (see publish_closure --
        # the requested id may be an *owner*, a unit id with no container of its
        # own, and the walk recurses through owned members into their subtrees).
        let found = self.publish_closure(s, msg.object_id)
        # Follow the root id itself even if nothing exists yet: a later CREATE
        # under this id is then delivered without re-fetching.
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
          s.interest.incl msg.object_id
          self.objects[msg.object_id].publish_create(s)
        else:
          # Missing -- or held only as an unloaded placeholder, which would
          # serve empty state; chain instead so the real data comes back. Keep
          # the interest so a later CREATE under this id is delivered.
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
  elif msg.kind == UNSUBSCRIBE:
    # A LOCAL peer is leaving. Drop our reverse subscription(s) to it (without
    # echoing UNSUBSCRIBE back) and record it in `unsubscribed` so consumers
    # reap what it owned (drain_unsubscribed).
    for s in self.subscribers.filter_it(it.ctx_id in source):
      self.unsubscribe(s, notify = false)
  elif msg.kind != BLANK:
    if msg.object_id notin self:
      # An op for an object we don't hold is dropped. Usually benign
      # (partial replica, version skew), but a drop on a paging path means a
      # requested entry silently never loads -- surface the first one per
      # object so a stalled chain is visible in the logs. DESTROY misses are
      # fully expected (destroys broadcast past the interest filter so peers
      # holding self-minted placeholders converge) -- drop them silently.
      if msg.kind != DESTROY and msg.object_id notin self.warned_missing:
        self.warned_missing.incl msg.object_id
        notice "dropping op for missing object",
          object_id = msg.object_id, kind = msg.kind
      return
    let obj = self.objects[msg.object_id]
    # Eviction accounting: an arriving op for a body we're not reading is churn
    # (the signal that holding it costs traffic); collection deltas also move
    # its resident size. Cheap, and only when there's a finite budget to track.
    if self.has_budget:
      inc obj.updates
      if msg.delta and msg.key_bin.len > 0:
        # Table entry: account per-key so per-key evict can subtract exactly.
        if msg.kind == ASSIGN:
          self.set_key_bytes(obj, msg.key_bin, msg.obj.len)
          obj.key_last_read[msg.key_bin] = get_mono_time() # updated -> recent
        elif msg.kind == UNASSIGN:
          self.forget_key_bytes(obj, msg.key_bin)
      elif msg.delta and msg.kind == ASSIGN:
        self.set_body_bytes(obj, obj.bytes + msg.obj.len)
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

  let body = self.typed_body
  if zid in body.changed_callbacks:
    let callback = body.changed_callbacks[zid]
    if zid notin body.paused_eids:
      callback(@[Change.init(O, {CLOSED})], self)
    self.ctx.close_index.del(zid)
    body.changed_callbacks.del(zid)
    body.callback_gens.del(zid)
  else:
    error "no change callback for zid", zid = zid

proc bind_lifetime*[T, O](self: Ed[T, O], lifetime: Lifetime, zid: EID) =
  ## Bind an already-registered callback (`zid`) to `lifetime`, so it untracks
  ## when the lifetime finishes. Lets sugar that mints its own zid (`changes`,
  ## enu's `watch`) route teardown through an owner's Lifetime without exposing
  ## the privileged untrack path. Guarded so a manual untrack first -- or the
  ## owner dying first -- is safe and idempotent.
  privileged
  lifetime.add proc() {.gcsafe.} =
    if not self.destroyed and zid in self.typed_body.changed_callbacks:
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
  let body = self.typed_body
  # Wrap the 1-arg callback in the stored 2-arg shape; the wrapper captures
  # only the user's closure (their captures are their pins).
  body.changed_callbacks[zid] = proc(
      changes: seq[Change[O]], it: ref EdBase
  ) {.gcsafe.} =
    callback(changes)
  body.callback_gens[zid] = body.proxy_gen
  self.ctx.close_index[zid] = self.id
  result = zid

  # Inside an `own` scope, route this callback's untrack through the owner's
  # lifetime too, so it's torn down when the owner is destroyed (the typical
  # case: a subscription on something the owner doesn't itself own). No scope
  # open -> no-op. Idempotent if also bound explicitly.
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
    callback:
      proc(changes: seq[Change[O]], zid: EID, it: Ed[T, O]) {.gcsafe.},
): EID {.discardable.} =
  ## The non-capturing form: the live proxy arrives as `it` each fire, so the
  ## callback needs no reference to the watched object at all -- a proxy
  ## tracked this way still dies promptly when the app drops it. The sugar
  ## (`changes`/`watch`) builds on this.
  privileged
  assert self.valid
  inc self.ctx.changed_callback_eid
  let zid = self.ctx.changed_callback_eid
  let body = self.typed_body
  body.changed_callbacks[zid] = proc(
      changes: seq[Change[O]], it: ref EdBase
  ) {.gcsafe.} =
    callback(changes, zid, Ed[T, O](it))
  body.callback_gens[zid] = body.proxy_gen
  self.ctx.close_index[zid] = self.id
  result = zid
  {.gcsafe.}:
    if not current_lifetime.is_nil:
      self.bind_lifetime(current_lifetime, zid)

proc track*[T, O](
    self: Ed[T, O],
    lifetime: Lifetime,
    callback: proc(changes: seq[Change[O]]) {.gcsafe.},
): EID {.discardable.} =
  ## Like `track`, but the callback's removal is owned by `lifetime`: when the
  ## owner calls `lifetime.finish` the callback untracks automatically -- no
  ## manual `zid` bookkeeping.
  result = self.track(callback)
  self.bind_lifetime(lifetime, result)

proc untrack_on_destroy*(self: ref EdBase, zid: EID) =
  self.bound_eids.add(zid)

type RemoteParse = enum
  Parsed      ## decoded into a usable Message
  Ignored     ## keepalive ping -- skip
  Unparseable ## bad/incompatible bytes -- drop the connection if it's a real peer

proc parse_remote(
    self: EdContext, raw_msg: netty.Message
): tuple[status: RemoteParse, msg: Message] {.gcsafe.} =
  ## Decode one raw remote packet into a Message (source short-ids + mappings
  ## attached, body uncompressed). `Ignored` = a keepalive ping. `Unparseable` =
  ## a version-skewed peer, schema mismatch, or corruption; the caller drops the
  ## connection (if it maps to a subscription) so the peer re-handshakes/resyncs.
  ## netty doesn't checksum content and we have no gap replay, so silently
  ## dropping the packet could leave a divergent op gap -- a reconnect is safer.
  ## Shared by `tick` and the silent materialize pump so the wire decode lives in
  ## one place.
  if raw_msg.data == "PING":
    return (Ignored, Message())
  if not raw_msg.data.starts_with(wire_header):
    # A peer speaking a different wire version (or a stray packet). flatty is
    # positional, so foreign bytes can decode cleanly into wrong-typed fields and
    # corrupt or crash processing. Warn once per peer -- a stray/un-subscribed
    # source would otherwise flood the log (a subscribed one is dropped below).
    let peer = $raw_msg.conn.address
    if peer notin self.warned_missing:
      self.warned_missing.incl peer
      warn "dropping message from incompatible peer (wire version mismatch)",
        peer, bytes = raw_msg.data.len
    return (Unparseable, Message())
  try:
    # Wire format: a small per-subscriber header (source short-ids + new
    # mappings) followed by the shared, compressed body (see send_remote).
    let (enc_source, mappings, body) = raw_msg.data[wire_header.len ..^ 1]
      .from_flatty((seq[uint8], seq[IdMapping], string))
    var msg = body.ed_uncompress.from_flatty(Message, self)
    msg.source = enc_source
    msg.id_mappings = mappings
    return (Parsed, msg)
  except CatchableError, Defect:
    warn "dropping unparseable remote message",
      bytes = raw_msg.data.len, peer = $raw_msg.conn.address
    return (Unparseable, Message())

proc drop_remote_conn(self: EdContext, conn: Connection) =
  ## A real peer sent bytes we can't parse -- tear down its subscription so it
  ## re-handshakes/resyncs instead of us silently dropping its packets forever.
  ## No-op for stray/pre-handshake packets that match no subscription.
  for s in self.subscribers:
    if s.kind == REMOTE and s.connection == conn:
      self.unsubscribe(s)
      break

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
  # `unsubscribed` is NOT cleared here: it accumulates until the consumer
  # drains it (see drain_unsubscribed). Clearing it per-tick made the events
  # tick-scoped transients -- a consumer that polls between ticks loses any
  # event when an extra tick sneaks in between produce and consume (the enu
  # agent-bot reap missed disconnects that landed during a reload this way).
  var count = 0
  self.free_refs
  self.prune_dead_proxies # clear backrefs of proxies ORC reclaimed
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
  self.flush_key_releases # ...and its batched per-key releases (paging out)
  self.evict_sweep        # reclaim dormant/over-budget bodies (partial replicas)

  # Replay whatever a silent (blocking) materialize deferred -- at this tick
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
      # coalesced -- every add matters.
      var batch: seq[Message]
      while get_mono_time() < timeout and self.chan.try_recv(msg):
        batch.add msg
      if batch.len > 0:
        var latest: Table[string, int64]
        for m in batch:
          if m.kind == ASSIGN and not m.delta and m.lsn > 0 and
              m.lsn > latest.get_or_default(m.object_id, 0'i64):
            latest[m.object_id] = m.lsn
        for m in batch:
          if m.kind == ASSIGN and not m.delta and m.lsn > 0 and
              m.lsn < latest.get_or_default(m.object_id, 0'i64):
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
        if parsed.status == Ignored: # keepalive ping
          continue
        if parsed.status == Unparseable:
          self.drop_remote_conn(raw_msg.conn) # real peer -> tear down; noise -> ignore
          continue
        var msg = parsed.msg
        when defined(ed_debug_messages):
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
          #   1. Same ctx_id -- the client reused its stable id (same
          #      process reconnect, or a deterministically-assigned id).
          #      Without this the old subscription persists until netty's
          #      ~10s keepalive timeout, during which the publisher can
          #      route messages back to the reconnected peer via the
          #      stale route.
          #   2. Same remote endpoint -- a previous client at that
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
  ## object -- every other received message and even this object's own Fill
  ## callback are deferred to the next explicit `tick`, so nothing
  ## application-visible happens mid-read (clean reentrancy). Bounded by a deadline
  ## so a gone authority can't hang the caller; it then falls back to the empty
  ## placeholder, same as the non-blocking path. Drains both the local
  ## (cross-thread) and remote (network) transports.
  privileged
  if id in self and ?self.objects[id] and not self.objects[id].placeholder:
    return
  let pending_fetch = self.fetch(id)
  if self.sync_mode != PARTIAL: # only PARTIAL blocks; PARTIAL_ASYNC fills on a later tick
    return

  template triage(candidate: Message) =
    # Apply only the target object's CREATE -- or its NOT_FOUND NACK, which
    # resolves the fetch so we stop waiting -- silently (callbacks deferred);
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
    # Remote transport -- reuse the same wire decode as tick, then resolve the
    # source eagerly so a deferred message processes correctly sub-less later.
    if ?self.reactor:
      self.tick_reactor
      let raws = self.remote_messages
      self.remote_messages = @[]
      for raw_msg in raws:
        let parsed = self.parse_remote(raw_msg)
        if parsed.status == Ignored:
          continue
        if parsed.status == Unparseable:
          self.drop_remote_conn(raw_msg.conn)
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
  if n.kind == nnk_return_stmt:
    return n
  if n.kind in {nnk_proc_def, nnk_func_def, nnk_lambda, nnk_do}:
    return nil
  for child in n:
    let found = find_bare_return(child)
    if found != nil:
      return found

macro check_no_return*(body: untyped): untyped =
  ## Passthrough macro: emits a compile error if body contains a bare return.
  ## Use inside changes bodies -- return exits the callback proc, not the
  ## enclosing proc, and skips remaining changes in the seq.
  let ret = find_bare_return(body)
  if ret != nil:
    error(
      "return is not valid inside a changes body; " &
        "use if/else instead of early return",
      ret,
    )
  result = body

macro warn_self_capture(watched: untyped, body: untyped): untyped =
  ## Bare-identifier self-capture detection for the `changes`/`watch` sugar:
  ## a callback body that references the watched *variable* captures it,
  ## pinning the object until untracked (closure cycles are not collected).
  ## Deliberately narrow -- only a bare identifier, only outside dot-RHS
  ## positions -- so it stays near-zero false positives (enu fires none).
  result = new_empty_node()
  if watched.kind in {nnk_ident, nnk_sym}:
    let name = watched.str_val
    proc references(n: NimNode): bool =
      if n.kind in {nnk_ident, nnk_sym} and eq_ident(n, name):
        return true
      for i in 0 ..< n.len:
        if n.kind == nnk_dot_expr and i == 1:
          continue # `x.foo` -- foo is a field, not a capture
        if references(n[i]):
          return true
    if references(body):
      warning(
        "callback closes over '" & name &
          "', pinning it until untracked -- use `it` (the injected live " &
          "proxy) or bind a Lifetime",
        watched,
      )

template changes*[T, O](self: Ed[T, O], pause_me, body) =
  warn_self_capture(self, body)
  make_discardable block:
    {.line.}:
      track self, proc(
          changes: seq[Change[O]], zid {.inject.}: EID, it {.inject.}: Ed[T, O]
      ) {.gcsafe.} =
        # `it` is the live proxy, delivered as a parameter -- referencing it
        # captures nothing, so sugar watchers never pin their object.
        let pause_zid = if pause_me: zid else: 0
        it.pause(pause_zid):
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

when defined(ed_debug_messages):
  proc get_type_name(tid: int): string =
    {.gcsafe.}:
      if tid in global_type_name_registry[]:
        result = global_type_name_registry[][tid]
      else:
        result = "type_" & $tid

  proc dump_message_stats*(self: EdContext, label = "") =
    ## Dump message statistics for debugging network sync issues.
    echo "=== EdContext Message Stats ", label, " ==="
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
