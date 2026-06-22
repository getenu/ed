## Connection helpers for keeping a remote `EdContext` subscribed and live.
##
## A context only stays healthy if it is `tick`ed regularly: ticking drives
## netty's keepalives and reaps dead connections. Tick on a timer and
## `connected` (subscribers present) becomes an authoritative liveness
## signal — no application-level ping needed.

import std/[times, monotimes, os]

import ed/[types, utils/misc, utils/logging]
import ed/zens/contexts
import ed/components/subscriptions

proc connected*(self: EdContext): bool =
  ## True if at least one subscriber is live. Reliable as long as the
  ## context is `tick`ed regularly (tick reaps dead connections).
  self.subscribers.len > 0

template every*(ctx: EdContext, interval: Duration, body: untyped) =
  ## `tick` `ctx` then run `body`, every `interval`, until `body` `break`s.
  ## The one loop primitive behind idle keepalives, change polling, and
  ## frame-paced animation.
  block:
    let interval_ms = max(0, interval.in_milliseconds.int)
    while true:
      ctx.tick
      body
      sleep interval_ms

const DEFAULT_RECONNECT_INTERVAL = init_duration(seconds = 1)

type EdClient* = ref object
  ## A remote `EdContext` that reconnects itself. `id` is stable across
  ## reconnects so the peer can recognize and supersede the prior session.
  id*: string
  address*: string
  chan_size*: int
  partial*: bool
    ## Subscribe as a partial replica: only the ids in `fetch` (and anything
    ## fetched later) sync; the rest is filtered at the authority.
  fetch*: seq[string]
    ## Ids fetched as part of each (re)subscribe (partial only). They land in
    ## the registry, so `ctx[id]` works for them afterwards.
  deep*: bool
    ## Ask the authority to push OWNS_MEMBERS member closures (a game client
    ## wants units render-ready; a narrow utility fetches what it touches).
  on_connect*: proc()
    ## (Re)create this client's objects after each (re)connect. Runs with
    ## `Ed.thread_ctx` set to the fresh context. Single-threaded — runs on
    ## the caller's thread, so it may touch the caller's globals.
  ctx*: EdContext
  reconnect_interval*: Duration
    ## Minimum gap between re-subscribe attempts while down (default 1 s).
    ## Re-subscribing tears down the context, so doing it every tick would
    ## prevent any handshake from completing; the gap lets one settle.
  last_attempt: MonoTime

proc connect*(self: EdClient) =
  ## (Re)create the context with the stable `id`, subscribe to `address`,
  ## and run `on_connect`. Resilient: if the peer is unreachable the new
  ## context simply has no subscribers, so a later `tick` retries.
  self.last_attempt = get_mono_time()
  if not self.ctx.is_nil:
    self.ctx.close
  let chan_size = if self.chan_size > 0: self.chan_size else: 100
  self.ctx = EdContext.init(chan_size = chan_size, buffer = false, id = self.id)
  Ed.thread_ctx = self.ctx
  try:
    self.ctx.subscribe(
      self.address, partial = self.partial, fetch = self.fetch, deep = self.deep
    )
    if self.on_connect != nil:
      self.on_connect()
  except ConnectionError as e:
    debug "EdClient connect failed; will retry",
      address = self.address, msg = e.msg

proc connected*(self: EdClient): bool =
  not self.ctx.is_nil and self.ctx.connected

proc ensure_connected*(self: EdClient) =
  ## Reconnect if the link is down. Cheap when already connected.
  if not self.connected:
    self.connect

proc tick*(self: EdClient) =
  ## Tick the context, reconnecting if it has dropped. Call on a timer to
  ## keep an otherwise-idle connection alive. While down, keep ticking the
  ## existing context so an in-flight handshake can complete, and only
  ## re-subscribe once per `reconnect_interval` — re-subscribing every tick
  ## would restart the handshake before it finishes and spin the CPU.
  if self.ctx.is_nil:
    self.connect
    return
  try:
    self.ctx.tick
  except CatchableError as e:
    debug "EdClient tick raised; reconnecting", msg = e.msg
    self.connect
    return
  if self.ctx.connected:
    return
  let interval =
    if self.reconnect_interval > DurationZero: self.reconnect_interval
    else: DEFAULT_RECONNECT_INTERVAL
  if get_mono_time() - self.last_attempt >= interval:
    self.connect
