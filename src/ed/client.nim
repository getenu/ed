## Connection helpers for keeping a remote `EdContext` subscribed and live.
##
## A context only stays healthy if it is `tick`ed regularly: ticking drives
## netty's keepalives and reaps dead connections. Tick on a timer and
## `connected` (subscribers present) becomes an authoritative liveness
## signal — no application-level ping needed.

import std/os

import ed/[types, utils/misc, utils/logging, utils/timing]
import ed/zens/contexts
import ed/zens/initializers
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

const DEFAULT_RECONNECT_INTERVAL = 1.second

type EdClient* = ref object
  ## A remote `EdContext` that reconnects itself. `id` is stable across
  ## reconnects so the peer can recognize and supersede the prior session.
  id*: string
  address*: string
  mode*: SyncMode
    ## How this client replicates: FULL (everything), PARTIAL (on-demand,
    ## blocking reads) or PARTIAL_ASYNC (on-demand, frame-paced). Drives both
    ## the subscribe filter and the context's blocking flag, so the
    ## full-but-blocking nonsense can't be configured.
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
  prev*: EdContext
    ## The session before the current one (one generation only). Each
    ## reconnect mints a fresh context, but the old replica's objects stay
    ## readable — state that lived in it (a bot's last transform, say) can
    ## be salvaged from here after the peer restarted and lost its copy.
  reconnect_interval*: Duration
    ## Minimum gap between re-subscribe attempts while down (default 1 s).
    ## Re-subscribing tears down the context, so doing it every tick would
    ## prevent any handshake from completing; the gap lets one settle.
  last_attempt: MonoTime

proc reconnect*(self: EdClient): EdClient {.discardable.} =
  ## (Re)create the context with the stable `id`, subscribe to `address`,
  ## and run `on_connect`. Resilient: if the peer is unreachable the new
  ## context simply has no subscribers, so a later `tick` retries. Returns
  ## `self` so it can be chained (`EdClient(...).reconnect`).
  ##
  ## Assumes the Ed runtime is already bootstrapped — use `connect` for the
  ## initial connection (it bootstraps first). This is the bootstrap-free
  ## routine the reconnect paths (`tick`/`online`) drive; call it directly
  ## only where `connect`'s `Ed.bootstrap` can't expand (e.g. inside another
  ## template), after bootstrapping at top level yourself.
  ##
  ## The context is NOT reused across reconnects (tried; doesn't work):
  ## an existing object's CREATE never re-broadcasts, so a restarted peer
  ## would never learn about this client's objects — they'd survive
  ## locally as ghosts whose ops the peer skips. Same-session resync is
  ## the body-persistence/revive work, not a client-side trick.
  result = self
  # Mint a stable id on first use if the caller didn't supply one, so it
  # survives reconnects (the peer recognizes and supersedes the prior
  # session by id).
  if self.id == "":
    self.id = generate_id()
  self.last_attempt = get_mono_time()
  if not self.ctx.is_nil:
    self.ctx.close
    self.prev = self.ctx
  self.ctx = EdContext.init(buffer = false, id = self.id)
  self.ctx.blocking = self.mode == PARTIAL
  Ed.thread_ctx = self.ctx
  try:
    self.ctx.subscribe(
      self.address, mode = self.mode, fetch = self.fetch, deep = self.deep
    )
    if self.on_connect != nil:
      self.on_connect()
  except ConnectionError as e:
    debug "EdClient connect failed; will retry",
      address = self.address, msg = e.msg

template connect*(self: EdClient) =
  ## Bootstrap the Ed runtime, then connect. Call once from your application's
  ## main module — `Ed.bootstrap` + `reconnect` in one step, so the app never
  ## names `bootstrap` itself.
  ##
  ## `Ed.bootstrap` is a macro that registers an initializer for every
  ## `Ed[T, O]` the program has instantiated, and only yields the complete
  ## set when expanded in the final module after every type-instantiating
  ## import. `connect` is a template so the macro expands at YOUR call site,
  ## where the full set is known. The registry is a process-wide runtime
  ## table, so it lands once; the reconnects `tick`/`online` drive go through
  ## the bootstrap-free `reconnect` and reuse it.
  ##
  ## Caveat: `Ed.bootstrap`'s generated code only compiles at module top
  ## level or inside a plain proc — not inside another template's expansion
  ## (e.g. a `unittest` `test` block). In those spots bootstrap once at top
  ## level and call `reconnect` instead.
  ##
  ## Returns the client, so it can be chained: `let c = EdClient(...).connect`.
  Ed.bootstrap
  self.reconnect

proc connected*(self: EdClient): bool =
  not self.ctx.is_nil and self.ctx.connected

proc online*(self: EdClient) =
  ## Reconnect if the link is down. Cheap when already connected.
  if not self.connected:
    self.reconnect

proc tick*(self: EdClient) =
  ## Tick the context, reconnecting if it has dropped. Call on a timer to
  ## keep an otherwise-idle connection alive. While down, keep ticking the
  ## existing context so an in-flight handshake can complete, and only
  ## re-subscribe once per `reconnect_interval` — re-subscribing every tick
  ## would restart the handshake before it finishes and spin the CPU.
  if self.ctx.is_nil:
    self.reconnect
    return
  try:
    self.ctx.tick
  except CatchableError as e:
    debug "EdClient tick raised; reconnecting", msg = e.msg
    self.reconnect
    return
  if self.ctx.connected:
    return
  let interval =
    if self.reconnect_interval > DurationZero: self.reconnect_interval
    else: DEFAULT_RECONNECT_INTERVAL
  if get_mono_time() - self.last_attempt >= interval:
    self.reconnect

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

const FRAME = 33.milliseconds

template animate*(self: EdClient, duration: Duration, body: untyped) =
  ## Run `body` once per ~33ms frame for `duration`, ticking each frame so
  ## changes sync. Injects `t` (float) in 0..1 (1.0 on the final frame); a
  ## final tick flushes the last frame.
  block:
    let
      frame_ms = FRAME.in_milliseconds.float
      total_ms = max(duration.in_milliseconds.float, frame_ms)
    var elapsed = 0.0
    self.every(FRAME):
      elapsed += frame_ms
      let t {.inject.} = min(elapsed / total_ms, 1.0)
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
    # init_duration, not 10.milliseconds: template bodies resolve at the
    # expansion site, where std/times' TimeInterval milliseconds may also
    # be in scope.
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
