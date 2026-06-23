import std/[net, tables, times, options, sugar, math, sets, isolation]
import pkg/threading/channels {.all.}

import
  ed/[
    core,
    types {.all.},
    utils/misc,
    utils/logging,
    zens/validations,
    components/private/global_state
  ]

import ./private
import ed/lifecycle

export EdContext

proc init_metrics*(_: type EdContext, labels: varargs[string]) =
  for label in labels:
    pressure_gauge.set(0.0, label_values = [label])
    object_pool_gauge.set(0.0, label_values = [label])
    ref_pool_gauge.set(0.0, label_values = [label])
    buffer_gauge.set(0.0, label_values = [label])
    chan_remaining_gauge.set(0.0, label_values = [label])
    sent_message_counter.inc(0, label_values = [label])
    received_message_counter.inc(0, label_values = [label])
    dropped_message_counter.inc(0, label_values = [label])
    ticks_counter.inc(0, label_values = [label])

proc pack_objects*(self: EdContext) =
  if self.objects_need_packing:
    var table: OrderedTable[string, ref EdBodyBase]
    for key, value in self.objects:
      if ?value:
        table[key] = value
    self.objects = table
    self.objects_need_packing = false

template blocking*(self: EdContext, body: untyped) =
  ## Within this scope, raise a PARTIAL_ASYNC context to PARTIAL: a read that
  ## touches an unmaterialized placeholder blocks (pumps I/O) until it fills
  ## instead of returning empty. A no-op for any other `sync_mode` -- FULL has
  ## nothing to block on, PARTIAL already blocks.
  let prev = self.sync_mode
  if self.sync_mode == PARTIAL_ASYNC:
    self.sync_mode = PARTIAL
  try:
    body
  finally:
    self.sync_mode = prev

proc contains*(self: EdContext, id: string): bool =
  id in self.objects and self.objects[id] != nil

proc contains*(self: EdContext, zen: ref EdBase): bool =
  assert zen.valid
  zen.id in self

proc len*(self: EdContext): int =
  self.pack_objects
  self.objects.len

proc init*(
    _: type EdContext,
    id = "thread-" & $get_thread_id(),
    listen_address = "",
    blocking_recv = false,
    chan_size = 100,
    buffer = false,
    max_recv_duration = Duration.default,
    min_recv_duration = Duration.default,
    label = "default",
    is_authority = false,
    mem_limit = DEFAULT_MEM_LIMIT, # 0 = no cache; n = LRU budget; Unbounded = never
): EdContext =
  ## Create a new `EdContext`. Set `listen_address` to enable network sync.
  ## Set `is_authority` to make this context the sequencer (leader) that assigns
  ## global LSNs -- see docs/consistency.md.
  privileged
  log_scope:
    topics = "ed"

  debug "EdContext initialized", id

  let uid = next_ctx_uid.fetch_add(1) + 1
  result = EdContext(
    id: id,
    uid: uid,
    blocking_recv: blocking_recv,
    max_recv_duration: max_recv_duration,
    min_recv_duration: min_recv_duration,
    buffer: buffer,
    metrics_label: label,
    last_keepalive_tick: epoch_time(),
    is_authority: is_authority,
    mem_limit: max(0, mem_limit), # clamp: a negative limit means no cache
  )
  if is_authority:
    result.leader_id = id

  result.chan = new_chan[Message](elements = chan_size)
  if ?listen_address:
    var listen_address = listen_address
    let parts = listen_address.split(":")
    do_assert parts.len in [1, 2],
      "listen_address must be in the format " & "`hostname` or `hostname:port`"

    var port = 9632
    if parts.len == 2:
      listen_address = parts[0]
      port = parts[1].parse_int

    debug "listening"
    result.reactor = new_reactor(listen_address, port)

proc thread_ctx*(t: type Ed): EdContext =
  ## Get the current thread's `EdContext`. Creates one if it doesn't exist.
  if active_ctx == nil:
    active_ctx = EdContext.init(id = "thread-" & $get_thread_id())
  active_ctx

proc thread_ctx*(_: type EdBase): EdContext =
  Ed.thread_ctx

proc `thread_ctx=`*(_: type Ed, ctx: EdContext) =
  active_ctx = ctx

proc `$`*(self: EdContext): string =
  \"EdContext {self.id}"

proc next_lsn*(self: EdContext): int64 =
  ## Authority-only: allocate the next global sequence number.
  inc self.lsn_counter
  self.lsn_counter

proc next_op_id*(self: EdContext): int64 =
  ## Allocate the next op id for a write this context originates.
  inc self.op_id_counter
  self.op_id_counter

proc stamp_lsn*(self: EdContext, msg: var Message) =
  ## If this context is the authority, assign the op its global LSN, once.
  ## Applies to the ordered ops the authority broadcasts (self-originated or
  ## forwarded). CREATE is intentionally not stamped -- concurrent same-id
  ## creation is out of scope and the subscribe-time resend distinction needs
  ## its own step (see spike doc). DESTROY *is* stamped: delete-vs-update is a
  ## real conflict that must be ordered.
  if self.is_authority and msg.lsn == 0 and
      msg.kind in {ASSIGN, UNASSIGN, TOUCH, DESTROY, PACKED}:
    msg.lsn = self.next_lsn

proc `[]`*[T, O](self: EdContext, src: Ed[T, O]): Ed[T, O] =
  result = Ed[T, O](self.resolve_proxy(self.objects[src.id]))

proc `[]`*(self: EdContext, id: string): ref EdBase =
  ## Container lookup by id. Raises `KeyError` when absent -- except inside a
  ## `blocking` scope, where an unknown id is fetched from the authority and
  ## waited for (bounded, silent pump); a NOT_FOUND NACK fails fast. Still
  ## absent afterwards -> `KeyError` as usual. A destroyed-but-unswept id keeps
  ## its old behavior (returns nil) and doesn't trigger a fetch.
  if self.sync_mode == PARTIAL and self.materialize != nil and id notin self.objects:
    self.materialize(self, id)
  result = self.resolve_proxy(self.objects[id])

proc len*(self: Chan): int =
  private_access Chan
  private_access ChannelObj
  result = self.d[].slots

proc remaining*(self: Chan): int =
  result = self.len - self.peek

proc full*(self: Chan): bool =
  self.remaining == 0

proc pressure*(self: EdContext): float =
  privileged

  let values = collect:
    for sub in self.subscribers:
      if sub.kind == LOCAL:
        if sub.chan_buffer.len > 0:
          return 1.0
        (sub.chan.len - sub.chan.remaining).float / sub.chan.len.float

  result = values.sum / float values.len

template harvest_reactor(self: EdContext) =
  self.dead_connections &= self.reactor.dead_connections
  for msg in self.reactor.messages:
    self.bytes_received += msg.data.len
  self.remote_messages &= self.reactor.messages

proc tick_reactor*(self: EdContext) =
  privileged
  if ?self.reactor:
    self.reactor.tick
    self.harvest_reactor

proc tick_keepalives*(self: EdContext) {.gcsafe.} =
  privileged
  ## Lightweight tick that only sends keepalives if enough time has passed.
  ## Safe to call frequently - won't do anything if called too soon.
  ## Call this after long operations (file I/O, etc.) to prevent connection timeouts.
  const keepalive_interval = 5.0  ## Seconds between keepalive pings to idle connections
  const keepalive_tick_interval = 3.0  ## Seconds between keepalive-only ticks

  if not ?self.reactor:
    return

  let now = epoch_time()
  if now - self.last_keepalive_tick < keepalive_tick_interval:
    return

  self.last_keepalive_tick = now

  self.reactor.tick
  self.harvest_reactor

  for sub in self.subscribers:
    if sub.kind == REMOTE and sub.last_sent_time + keepalive_interval <= now:
      self.bytes_sent += 4  # "PING"
      self.reactor.send(sub.connection, "PING")
      sub.last_sent_time = now

  self.reactor.tick
  self.harvest_reactor

proc clear*(self: EdContext) =
  ## Remove all objects from this context.
  debug "Clearing EdContext"
  self.objects.clear
  self.latest_op_id.clear
  self.objects_need_packing = false

proc close*(self: EdContext) =
  ## Close network connections and cleanup resources.
  if ?self.reactor:
    private_access Reactor
    self.reactor.socket.close()
  self.reactor = nil

proc destroy*(self: EdContext) =
  ## Tear the context down and release everything it owns.
  ##
  ## Bodies linger in the registry by design -- they outlive their proxies (the
  ## registry is a cache with its own eviction). So a dropped context can't
  ## reclaim them on its own: every body holds self-/context-capturing closures
  ## (`publish_create` et al.), and ORC doesn't collect closure cycles, so the
  ## context stays pinned through its own registry. This is the explicit
  ## teardown that breaks those cycles -- `release_closures` on each body -- and
  ## drops the registry plus the per-context buffers. Afterwards the context
  ## holds nothing, so it (and its channel/reactor) is reclaimed when the last
  ## reference drops. Idempotent.
  privileged
  debug "destroying EdContext", id = self.id
  # Notify LOCAL peers so they drop their reverse subscription and stop fanning
  # ops into our about-to-be-freed inbox -- cross-thread channels have no
  # keepalive signal (REMOTE peers learn from the closed socket below). Enqueue
  # directly and non-blocking: if a peer's inbox is full we skip rather than hang
  # teardown (the peer keeps the stale sub, the pre-existing behavior).
  for sub in self.subscribers:
    if sub.kind == LOCAL:
      var iso = isolate(Message(kind: UNSUBSCRIBE, source_set: [self.id].to_hash_set))
      discard sub.chan.try_take(iso)
  for id, body in self.objects:
    if ?body:
      body.release_closures
  self.objects.clear
  self.owned_by.clear
  self.latest_op_id.clear
  self.ref_pool.clear
  self.close_index.clear
  self.subscribers.set_len(0)
  self.value_initializers.set_len(0)
  self.fetches.clear
  self.pending_obj_wants.clear
  self.pending_key_wants.clear
  self.pending_key_requests.clear
  self.pending_key_releases.clear
  self.pending_fills.set_len(0)
  self.pending_msgs.set_len(0)
  self.materialize = nil
  self.objects_need_packing = false
  self.close()
