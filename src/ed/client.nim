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
  blocking*: bool
    ## Applied to each (re)created context: touching an unmaterialized
    ## placeholder — by read or local write — pumps I/O until it fills.
    ## Synchronous semantics for CLIs and narrow agents; leave off for
    ## anything frame-paced.
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
  self.ctx.blocking = self.blocking
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

proc online*(self: EdClient) =
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

template online*(self: EdClient, body: untyped): untyped =
  ## Ensure the link is up, run `body`, then tick so its writes drain to
  ## the peer. Evaluates to `body`'s value.
  self.online
  when typeof(block: body) is void:
    body
    self.tick
  else:
    let online_result = block: body
    self.tick
    online_result

type SessionLost* = object of CatchableError
  ## Raised by EdClient's waiting helpers (`every` / `animate` /
  ## `tick_until`) when the live session they started with goes away
  ## mid-wait: the link dropped, or a reconnect replaced the context —
  ## stranding any handles the caller's loop body captured (each reconnect
  ## mints a fresh context). A loop that starts *without* a live session
  ## (waiting for the first connect) never raises.

template every*(self: EdClient, interval: Duration, body: untyped) =
  ## Reconnect-aware `every`: ticks the client (re-subscribing if the link
  ## drops) instead of the bare context, every `interval`, until `break`.
  ## Raises `SessionLost` if the session it started with goes away.
  block:
    let
      interval_ms = max(0, interval.in_milliseconds.int)
      session = self.ctx
      had_session = self.connected
    while true:
      self.tick
      if had_session and (self.ctx != session or not self.connected):
        raise newException(
          SessionLost, "the session this wait started with is gone"
        )
      body
      sleep interval_ms

const FRAME = init_duration(milliseconds = 33)

template animate*(self: EdClient, seconds: float, body: untyped) =
  ## Run `body` once per ~33ms frame for `seconds`, ticking each frame so
  ## changes sync. Injects `t` in 0..1 (1.0 on the final frame); a final
  ## tick flushes the last frame.
  block:
    let
      frame_sec = FRAME.in_milliseconds.float / 1000.0
      total = max(seconds, frame_sec)
    var elapsed = 0.0
    self.every(FRAME):
      elapsed += frame_sec
      let t {.inject.} = min(elapsed / total, 1.0)
      body
      if t >= 1.0:
        self.tick
        break

template tick_until*(self: EdClient, timeout: Duration, cond: untyped): bool =
  ## Tick (reconnect-aware) every ~10ms until `cond` holds or `timeout`
  ## elapses; returns whether it held. Raises `SessionLost` (via `every`)
  ## if the session it started with goes away mid-wait.
  block:
    let deadline = get_mono_time() + timeout
    var met = false
    self.every(init_duration(milliseconds = 10)):
      if cond:
        met = true
        break
      if get_mono_time() > deadline:
        break
    met

proc flush*(self: EdClient, ticks = 3) =
  ## Tick a few times with short gaps so just-written ops drain to the peer
  ## before the caller stops ticking (UDP batches per tick).
  for _ in 1 .. ticks:
    self.tick
    sleep 20
