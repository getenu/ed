## Outbound op production: the fanout to subscribers, change/destroy publishing,
## ownership-closure pushes, and packed-op batching. Builds on `wire`.

import
  std/[
    importutils, tables, sets, sequtils, intsets, times, strutils, macros, os,
    heapqueue,
  ]
import pkg/threading/channels {.all.}
import pkg/flatty
import ed/[core, types {.all.}], ed/zens/[contexts, private, initializers {.all.}]
import ed/components/private/global_state
import ed/lifecycle
import ./wire {.all.}

privileged
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

