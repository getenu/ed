import std/[net, tables, times, options, sugar, math]
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
    var table: OrderedTable[string, ref EdBase]
    for key, value in self.objects:
      if ?value:
        table[key] = value
    self.objects = table
    self.objects_need_packing = false

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
): EdContext =
  ## Create a new `EdContext`. Set `listen_address` to enable network sync.
  privileged
  log_scope:
    topics = "ed"

  debug "EdContext initialized", id

  result = EdContext(
    id: id,
    blocking_recv: blocking_recv,
    max_recv_duration: max_recv_duration,
    min_recv_duration: min_recv_duration,
    buffer: buffer,
    metrics_label: label,
    last_keepalive_tick: epoch_time(),
  )

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

proc `[]`*[T, O](self: EdContext, src: Ed[T, O]): Ed[T, O] =
  result = Ed[T, O](self.objects[src.id])

proc `[]`*(self: EdContext, id: string): ref EdBase =
  result = self.objects[id]

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
  self.objects_need_packing = false

proc close*(self: EdContext) =
  ## Close network connections and cleanup resources.
  if ?self.reactor:
    private_access Reactor
    self.reactor.socket.close()
  self.reactor = nil
