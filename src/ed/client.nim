## Connection helpers for keeping a remote `EdContext` subscribed and live.
##
## A context only stays healthy if it is `tick`ed regularly: ticking drives
## netty's keepalives and reaps dead connections. Tick on a timer and
## `connected` (subscribers present) becomes an authoritative liveness
## signal -- no application-level ping needed.

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
    ## `Ed.thread_ctx` set to this client's live context. Single-threaded --
    ## runs on the caller's thread, so it may touch the caller's globals.
  ctx*: EdContext
  prev*: EdContext
    ## The session before the current one (one generation only). Each reconnect
    ## mints a fresh context, but the previous session's objects stay readable --
    ## state that lived in it (a bot's last transform, say) can be salvaged from
    ## here after the peer restarted and lost its copy.
  reconnect_interval*: Duration
    ## Minimum gap between re-subscribe attempts while down (default 1 s).
    ## Re-subscribing tears down the context, so doing it every tick would
    ## prevent any handshake from completing; the gap lets one settle.
  last_attempt: MonoTime

proc reconnect*(self: EdClient): EdClient {.discardable.} =
  ## Establish (or re-establish) this client's context, subscribe to `address`,
  ## and run `on_connect`. Resilient: if the peer is unreachable the context
  ## simply has no subscribers, so a later `tick` retries. Returns `self` so it
  ## can be chained (`EdClient(...).reconnect`).
  ##
  ## `connect` is an alias; both are plain procs callable anywhere (including
  ## inside a `unittest` `test` block). Type initializers self-register at
  ## program startup (see `create_initializer`), so there's no bootstrap step.
  ## The reconnect paths (`tick`/`online`) drive this.
  ##
  ## First connect vs reconnect -- the context handling deliberately differs:
  ##
  ## * FIRST connect uses the thread's context (`Ed.thread_ctx`) rather than
  ##   minting one and clobbering it, and inherits its `id` as this client's
  ##   stable identity. The default thread context now carries a globally-unique
  ##   id (see `EdContext.init`), so it's safe to adopt as a network identity. A
  ##   caller that pins an explicit `id` still wins: if it differs from the
  ##   thread context's, a context under that id is installed as the thread
  ##   context (keeps id-driven callers -- e.g. the MCP server -- unchanged).
  ##
  ## * A genuine RECONNECT (this client already has a live context) is NOT
  ##   allowed to reuse it: an existing object's CREATE never re-broadcasts, so
  ##   a restarted peer would never learn about this client's objects -- they'd
  ##   survive locally as ghosts whose ops the peer skips. So a reconnect always
  ##   mints a FRESH context under the same stable `id`; the peer recognizes and
  ##   supersedes the prior session by that id. Same-session resync is the
  ##   body-persistence/revive work, not a client-side trick.
  ##
  ## Either way `Ed.thread_ctx` ends up pointing at this client's live context,
  ## so `on_connect` and app helpers that read it see the right one.
  result = self
  self.last_attempt = get_mono_time()
  if self.ctx.is_nil:
    # FIRST connect: use the thread context. Honor a caller-pinned id by
    # installing a context under it; otherwise adopt whatever the thread has.
    if self.id != "" and Ed.thread_ctx.id != self.id:
      Ed.thread_ctx = EdContext.init(id = self.id)
    self.ctx = Ed.thread_ctx
  else:
    # RECONNECT: retire the current context and mint a fresh one under the same
    # stable id, then point the thread at it.
    self.ctx.close
    self.prev = self.ctx
    self.ctx = EdContext.init(id = self.id)
    Ed.thread_ctx = self.ctx
  # A stable id survives reconnects (the peer supersedes the prior session by
  # id); align it with the context we settled on.
  self.id = self.ctx.id
  try:
    # subscribe sets ctx.sync_mode from `mode` (PARTIAL => blocking reads)
    self.ctx.subscribe(
      self.address, mode = self.mode, fetch = self.fetch, deep = self.deep
    )
    if self.on_connect != nil:
      self.on_connect()
  except ConnectionError as e:
    debug "EdClient connect failed; will retry",
      address = self.address, msg = e.msg

template connect*(self: EdClient) =
  ## Bootstrap the Ed runtime, then connect -- `Ed.bootstrap` + `reconnect` in
  ## one step, so apps never name `bootstrap`. Returns the client, chainable:
  ## `let c = EdClient(...).connect`.
  ##
  ## `Ed.bootstrap` is a macro emitting one registration per `Ed[T,O]` the
  ## program has instantiated; `connect` is a template so it expands at YOUR
  ## call site, picking up everything instantiated by then (so call it after
  ## your imports). The registrations are trivial calls referencing named
  ## procs, so -- unlike before -- this expands cleanly inside a `unittest test`
  ## block. `tick`/`online` reconnect through the bootstrap-free `reconnect`.
  ##
  ## `-d:ed_disable_auto_bootstrap` makes this skip `Ed.bootstrap`; call
  ## `Ed.bootstrap` yourself once, wherever it fits, independent of connect.
  when not defined(ed_disable_auto_bootstrap):
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
  ## re-subscribe once per `reconnect_interval` -- re-subscribing every tick
  ## would restart the handshake before it finishes and spin the CPU.
  if self.ctx.is_nil:
    self.reconnect
    return
  try:
    self.ctx.tick
  except ConnectionError as e:
    # Only recover from a connection failure; let anything else propagate -- a
    # logic error shouldn't be silently masked as a reconnect. (A dropped link
    # normally surfaces as `connected == false` below, not as an exception;
    # netty handles socket errors internally.)
    warn "EdClient connection error; reconnecting", msg = e.msg
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
  ## mid-wait: the link dropped, or a reconnect replaced the context --
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
        raise new_exception(
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
