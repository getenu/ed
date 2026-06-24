## Wire format for cross-context sync: source short-id mapping, flatty
## (de)serialization of refs and messages, snappy compression, and the
## low-level send primitives (local channel buffer + remote packet). The base
## layer of the subscriptions subsystem -- everything else builds on `send`.

import
  std/[
    importutils, isolation, tables, sets, intsets, locks, times, strutils,
    macros, heapqueue,
  ]
import pkg/threading/channels {.all.}
import pkg/[flatty, supersnappy]
import ed/[core, types {.all.}], ed/zens/[contexts, private, initializers {.all.}]
import ed/components/private/global_state
import ed/lifecycle
import ../type_registry

privileged
var flatty_ctx {.threadvar.}: EdContext

type FlatRef = tuple[tid: int, ref_id: string, item: string]

type EdFlattyInfo = tuple[object_id: string, tid: int]
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

proc register_mappings*(sub: Subscription, mappings: seq[IdMapping]) =
  ## Register new ID mappings from an incoming message into the *incoming*
  ## namespace. The peer chose these short IDs independently of ours, so we
  ## must not let them interact with our outgoing allocation.
  for (short_id, full_id) in mappings:
    sub.incoming_short_to_id[short_id] = full_id

proc decode_source*(sub: Subscription, source: seq[uint8]): HashSet[string] =
  ## Convert short IDs back to full context ID HashSet.
  for short_id in source:
    if short_id in sub.incoming_short_to_id:
      result.incl sub.incoming_short_to_id[short_id]
    else:
      result.incl "unknown:" & $short_id

proc `$`*(self: Subscription): string =
  \"{self.kind} subscription for {self.ctx_id}"

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

template ed_compress*(s: string): string =
  ## Pass-through under `-d:ed_no_compress` -- supersnappy's snappy fast-path
  ## over-reads within an allocation, which trips AddressSanitizer (it's a benign
  ## third-party over-read, not our bug). The sanitizer build defines the flag so
  ## ASan can focus on Ed's own memory behaviour; in-process sync uses one build,
  ## so both sides agree on the (un)compressed wire format.
  when defined(ed_no_compress): s else: s.compress

template ed_uncompress*(s: string): string =
  when defined(ed_no_compress): s else: s.uncompress

proc remote_body*(msg: Message, no_overwrite: bool): string =
  ## The shared, compressed wire body for a remote message -- identical across
  ## subscribers (source / id_mappings travel per-subscriber, outside it), so a
  ## fanout serializes + compresses it once.
  var body_msg = msg
  body_msg.source = @[]
  body_msg.id_mappings = @[]
  if no_overwrite:
    body_msg.obj = ""
  result = body_msg.to_flatty.ed_compress

const wire_header* = "ED\x01"
  ## Magic + wire-format version, prefixed to every remote packet. flatty is
  ## positional: bytes from an older wire format can decode *cleanly* into
  ## wrong-typed fields and blow up (or corrupt state) deep in processing -- a
  ## version-skewed peer once killed a server silently this way. The prefix
  ## rejects foreign packets at the front door instead. Bump the version byte
  ## whenever the wire format changes.

proc send_remote*(
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
