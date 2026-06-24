## The sync core: subscription lifecycle (subscribe / add_subscriber /
## unsubscribe) and the receive path (tick + the per-message-kind handlers +
## process_message). These form one mutually-recursive cluster -- subscribe
## pumps tick, tick dispatches process_message, the handlers call back into
## unsubscribe/add_subscriber -- so they live together. Builds on every other
## part of the subsystem (wire/publish/eviction/paging/watch).

import
  std/[
    importutils, tables, sets, sequtils, algorithm, intsets, locks, math, times,
    strutils, macros, os, heapqueue,
  ]
import pkg/threading/channels {.all.}
import pkg/[flatty, supersnappy]
import ed/[core, types {.all.}], ed/zens/[contexts, private, initializers {.all.}]
import ed/components/private/global_state
import ed/lifecycle
import ../type_registry
import ./[wire, publish, eviction, paging]

privileged

# Forward-declared: subscribe pumps tick, which is defined far below.
proc tick*(
  self: EdContext,
  messages = int.high,
  max_duration = self.max_recv_duration,
  min_duration = self.min_recv_duration,
  blocking = self.blocking_recv,
  poll = true,
) {.gcsafe.}
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

proc process_message(
  self: EdContext, msg: Message, sub: Subscription = nil
) {.gcsafe.}

proc handle_packed(self: EdContext, msg: Message, sub: Subscription) {.gcsafe.} =
  privileged
  log_defaults("ed publishing")
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

proc handle_create(self: EdContext, msg: Message, source: HashSet[string]) =
  privileged
  log_defaults("ed publishing")
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

proc handle_not_found(self: EdContext, msg: Message) =
  privileged
  log_defaults("ed publishing")
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

proc handle_release_object(
    self: EdContext, msg: Message, source: HashSet[string]
) =
  privileged
  log_defaults("ed publishing")
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

proc handle_interest(self: EdContext, msg: Message, source: HashSet[string]) =
  privileged
  log_defaults("ed publishing")
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

proc handle_release_keys(
    self: EdContext, msg: Message, source: HashSet[string]
) =
  privileged
  log_defaults("ed publishing")
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

proc handle_request(self: EdContext, msg: Message, source: HashSet[string]) =
  privileged
  log_defaults("ed publishing")
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

proc handle_unsubscribe(self: EdContext, source: HashSet[string]) =
  privileged
  log_defaults("ed publishing")
  # A LOCAL peer is leaving. Drop our reverse subscription(s) to it (without
  # echoing UNSUBSCRIBE back) and record it in `unsubscribed` so consumers
  # reap what it owned (drain_unsubscribed).
  for s in self.subscribers.filter_it(it.ctx_id in source):
    self.unsubscribe(s, notify = false)

proc handle_op(self: EdContext, msg: Message, source: HashSet[string]) =
  privileged
  log_defaults("ed publishing")
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

proc process_message(
    self: EdContext, msg: Message, sub: Subscription = nil
) {.gcsafe.} =
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
    self.handle_packed(msg, sub)
  elif msg.kind == CREATE:
    self.handle_create(msg, source)
  elif msg.kind == NOT_FOUND:
    self.handle_not_found(msg)
  elif msg.kind == RELEASE and msg.obj.len == 0:
    self.handle_release_object(msg, source)
  elif msg.kind == INTEREST:
    self.handle_interest(msg, source)
  elif msg.kind == RELEASE:
    self.handle_release_keys(msg, source)
  elif msg.kind == REQUEST:
    self.handle_request(msg, source)
  elif msg.kind == UNSUBSCRIBE:
    self.handle_unsubscribe(source)
  elif msg.kind != BLANK:
    self.handle_op(msg, source)
  else:
    fail "Can't recv a blank message"

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

proc handle_subscribe(
    self: EdContext, msg: Message, conn: Connection
) {.gcsafe.} =
  ## A remote SUBSCRIBE arrived: register the subscriber (dropping any
  ## subscription it supersedes), ACK with our object ids, and pump the reactor
  ## so the ACK and any follow-on traffic flow.
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
  let new_addr_str = $conn.address
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
    connection: conn,
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
  self.reactor.send(conn, ack_data)
  sent_message_counter.inc(label_values = [self.metrics_label])
  self.reactor.tick
  self.dead_connections &= self.reactor.dead_connections
  for msg in self.reactor.messages:
    self.bytes_received += msg.data.len
  self.remote_messages &= self.reactor.messages

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
          self.handle_subscribe(msg, raw_msg.conn)
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
