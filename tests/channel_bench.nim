## Channel flow-control benchmark / deadlock repro.
##
## Mirrors enu's cross-thread setup: a *consumer* context (like enu's main/game
## thread: large inbox, `buffer = true`) and a *producer* context (like enu's
## worker: smaller inbox) that streams changes into it. The producer is the data
## source; `consumer.subscribe(producer)` makes the producer send into the
## consumer's inbox -- so `producer.pressure` reads that inbox's fill, the exact
## signal enu's worker gates on.
##
## It compares three send policies under a consumer stall (the "main thread is
## busy changing levels and isn't draining" case):
##
##   Blocking  worker `buffer = false` (today). A full inbox blocks the whole
##             producer thread mid-send -> max send latency spikes to the stall
##             length. In enu, if the consumer is *also* waiting on the worker,
##             that freeze is the permanent lock.
##   Buffered  worker `buffer = true`, no production gate. Never blocks, but the
##             in-flight backlog grows for the whole stall -> the unbounded-memory
##             case.
##   Gated     worker `buffer = true` + a cooperative `pressure` gate at the
##             production point. Never blocks AND the backlog stays bounded: the
##             producer declines to produce while the consumer is behind.
##
## Run:  nim c -r --mm:orc --threads:on -d:metrics tests/channel_bench.nim

import std/[atomics, monotimes, times, os, strformat, math, sets, sequtils]
import ed

type
  Policy = enum
    Blocking, Buffered, Gated

  Scenario = object
    name: string
    policy: Policy
    main_chan: int      ## consumer inbox capacity
    worker_chan: int    ## producer inbox capacity
    produce_total: int  ## how many items the producer adds
    produce_batch: int  ## adds between producer ticks
    stall_at: int       ## consumer stops ticking once this many are produced
    stall_ms: int       ## ...for this long (0 = no stall)
    gate: float         ## Gated: pause production while pressure >= gate
    consume_us: int     ## per-message consumer cost (models main-thread mesh work)
    wait_for_producer: bool
      ## After `stall_at`, the consumer stops draining and waits for the producer
      ## to *finish* before resuming. With a blocking producer that's a true
      ## deadlock: the producer can't finish because it's blocked sending into the
      ## consumer's full inbox, which the consumer won't drain until the producer
      ## finishes. (enu's real freeze: main waits on the worker mid-level-change.)

    # --- enu-shaped (frame) producer -------------------------------------------
    frame_shaped: bool  ## model enu's worker frame instead of per-add
    frame_edits: int    ## "voxel edits" produced in one advancing frame (a big
                        ## number models an ASAP burst: a whole frame's draw
                        ## lands before the next pressure check)
    chunk_space: int    ## edits map into this many distinct chunk ids; re-touched
                        ## chunks COALESCE in the pending store (one msg per flush)
    gate_flush: bool    ## the proposed fix: also skip the flush while pressure high
                        ## (advance is always gated, like enu today)

  Sample = object
    t_ms: int
    produced: int
    consumed: int
    backlog: int

# --- shared state (single heap; scenarios run sequentially) --------------------
var
  g_main_ctx: EdContext
  g_worker_ctx: EdContext
  cur: Scenario
  run_start: MonoTime

  produced: Atomic[int]
  consumed: Atomic[int]
  max_send_us: Atomic[int]
  max_backlog: Atomic[int]
  max_pressure_milli: Atomic[int]   ## max producer pressure * 1000
  produced_edits: Atomic[int]       ## frame producer: upstream "voxel edits"
  max_dirty: Atomic[int]            ## frame producer: pending-store high-water
  g_consume_us: Atomic[int]         ## per-message consumer cost (gcsafe access)

  sub_done: Atomic[bool]
  main_ready: Atomic[bool]
  producer_done: Atomic[bool]
  sampler_stop: Atomic[bool]

  samples: seq[Sample]

  producer_thread: Thread[void]
  sampler_thread: Thread[void]

proc bump_max(a: var Atomic[int], v: int) =
  if v > a.load(moRelaxed):
    a.store(v, moRelaxed)

proc reset_shared() =
  produced.store 0
  consumed.store 0
  max_send_us.store 0
  max_backlog.store 0
  max_pressure_milli.store 0
  produced_edits.store 0
  max_dirty.store 0
  sub_done.store false
  main_ready.store false
  producer_done.store false
  sampler_stop.store false
  samples = @[]

# --- sampler: never blocks, records the time series -----------------------------
proc sampler_proc() {.thread.} =
  {.cast(gcsafe).}:
    while not sampler_stop.load(moRelaxed):
      let p = produced.load(moRelaxed)
      let c = consumed.load(moRelaxed)
      let b = p - c
      bump_max(max_backlog, b)
      samples.add Sample(
        t_ms: (get_mono_time() - run_start).in_milliseconds.int,
        produced: p, consumed: c, backlog: b,
      )
      sleep 4

# --- producer: owns the data, streams adds into the consumer --------------------
proc per_add_producer(data: EdSeq[int]) =
  var i = 0
  while i < cur.produce_total:
    if cur.policy == Gated:
      # Cooperative backpressure: don't add while the consumer is behind.
      var spins = 0
      while g_worker_ctx.pressure >= cur.gate and spins < 20_000:
        g_worker_ctx.tick
        sleep 1
        inc spins
    bump_max(max_pressure_milli, int(g_worker_ctx.pressure * 1000))
    let t0 = get_mono_time()
    data.add i
    bump_max(max_send_us, (get_mono_time() - t0).in_microseconds.int)
    inc i
    produced.store i
    if i mod cur.produce_batch == 0:
      g_worker_ctx.tick

proc frame_producer(data: EdSeq[int]) =
  ## Models enu's worker frame: advance (always gated on pressure, like enu today)
  ## produces a frame's "voxel edits" into a COALESCING pending-chunk store; the
  ## flush emits one message per dirty chunk. `gate_flush` adds the proposed fix:
  ## also skip the flush while pressure is high, so deferred edits coalesce in the
  ## store instead of piling into the channel's overflow buffer.
  var dirty: HashSet[int]
  var edits = 0
  var next_chunk = 0
  var msgs = 0
  let deadline = get_mono_time() + init_duration(seconds = 20)
  while (edits < cur.produce_total or dirty.len > 0) and get_mono_time() < deadline:
    let p = g_worker_ctx.pressure
    bump_max(max_pressure_milli, int(p * 1000))
    # advance: a whole frame's draw lands before the next pressure check.
    if p < cur.gate and edits < cur.produce_total:
      for k in 0 ..< cur.frame_edits:
        if edits >= cur.produce_total: break
        dirty.incl(next_chunk mod cur.chunk_space)
        inc next_chunk
        inc edits
      produced_edits.store edits
    bump_max(max_dirty, dirty.len)
    # flush: one message per dirty chunk. The proposed fix flushes INCREMENTALLY,
    # stopping when pressure hits the gate and leaving the rest in the coalescing
    # store for a later frame -- so a single huge burst can't overshoot the
    # channel. The unfixed path flushes the whole burst regardless.
    if dirty.len > 0:
      for cid in to_seq(dirty.items):
        if cur.gate_flush and g_worker_ctx.pressure >= cur.gate:
          break  # channel at the gate; defer the rest (they coalesce in `dirty`)
        let t0 = get_mono_time()
        data.add cid
        bump_max(max_send_us, (get_mono_time() - t0).in_microseconds.int)
        dirty.excl cid
        inc msgs
      produced.store msgs
    g_worker_ctx.tick
    sleep 1  # frame pacing

proc producer_body() =
  g_worker_ctx = EdContext.init(
    id = "worker",
    chan_size = cur.worker_chan,
    buffer = cur.policy != Blocking,
    is_authority = true,
    label = "worker",
  )
  Ed.thread_ctx = g_worker_ctx

  var data = EdSeq[int].init(flags = {SYNC_LOCAL}, id = "bench", ctx = g_worker_ctx)

  # Consumer subscribes to us -> we become the sender into its inbox.
  g_main_ctx.subscribe(g_worker_ctx)
  sub_done.store true

  # Finish the handshake while the consumer wires up its callback.
  while not main_ready.load:
    g_worker_ctx.tick
    sleep 1

  if cur.frame_shaped:
    frame_producer(data)
  else:
    per_add_producer(data)

  producer_done.store true

  # Drain anything still queued so consumed can catch up.
  let deadline = get_mono_time() + init_duration(seconds = 10)
  while consumed.load < produced.load and get_mono_time() < deadline:
    g_worker_ctx.tick
    sleep 1

proc producer_proc() {.thread.} =
  {.cast(gcsafe).}:
    producer_body()

# --- consumer / driver: runs on the main thread ---------------------------------
proc run_scenario(sc: Scenario): bool =
  ## Returns false if it wedged past the hard deadline.
  cur = sc
  reset_shared()
  g_consume_us.store sc.consume_us

  Ed.thread_ctx = EdContext.init(
    id = "main",
    chan_size = sc.main_chan,
    buffer = true,
    label = "main",
    max_recv_duration = (1.0 / 30.0).seconds,
  )
  g_main_ctx = Ed.thread_ctx

  run_start = get_mono_time()
  create_thread(sampler_thread, sampler_proc)
  create_thread(producer_thread, producer_proc)

  # Wait for the producer to register the subscription, then wire our callback.
  while not sub_done.load:
    sleep 1
  while "bench" notin g_main_ctx:
    g_main_ctx.tick
    sleep 1

  var data_main = EdSeq[int](g_main_ctx["bench"])
  data_main.track proc(changes: seq[Change[int]]) {.gcsafe.} =
    var added = 0
    for c in changes:
      if ADDED in c.changes:
        inc added
    if added > 0:
      let cost = g_consume_us.load(moRelaxed)
      if cost > 0:
        # Busy-spin to model the main thread's per-message mesh work, so a burst
        # can't be drained for free (the channel stays full long enough to matter).
        let until = get_mono_time() + init_duration(microseconds = cost * added)
        while get_mono_time() < until: discard
      discard consumed.fetch_add(added)
  main_ready.store true

  let hard_deadline = get_mono_time() + init_duration(seconds = 8)
  var stalled = false
  var wedged = false
  while true:
    if not stalled and produced.load >= sc.stall_at:
      stalled = true
      if sc.wait_for_producer:
        # Stop draining and wait for the producer to finish (mutual wait).
        while not producer_done.load and get_mono_time() < hard_deadline:
          sleep 1
      elif sc.stall_ms > 0:
        # Main busy (NOT draining its inbox) for a bounded window.
        sleep sc.stall_ms
    g_main_ctx.tick
    if producer_done.load and consumed.load >= produced.load:
      break
    if get_mono_time() > hard_deadline:
      wedged = true
      break
    sleep 0

  # Rescue: if we wedged, drain so the (possibly blocked) producer can finish and
  # be joined cleanly -- the result is already recorded as WEDGED.
  if wedged:
    let rescue_until = get_mono_time() + init_duration(seconds = 5)
    while not producer_done.load and get_mono_time() < rescue_until:
      g_main_ctx.tick
      sleep 1

  sampler_stop.store true
  join_thread(sampler_thread)
  join_thread(producer_thread)

  result = not wedged

# --- reporting ------------------------------------------------------------------
proc spark(values: seq[int], peak: int): string =
  const bars = ["·", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
  if peak <= 0: return ""
  for v in values:
    let idx = clamp(int(v.float / peak.float * 8.0), 0, 8)
    result.add bars[idx]

proc backlog_timeline(width = 60): string =
  ## Downsample the backlog series to `width` buckets (max per bucket).
  if samples.len == 0: return ""
  var buckets = new_seq[int](width)
  let n = samples.len
  for k, s in samples:
    let b = min(width - 1, k * width div n)
    buckets[b] = max(buckets[b], s.backlog)
  spark(buckets, max_backlog.load)

proc report(sc: Scenario, ok: bool) =
  let total_ms = if samples.len > 0: samples[^1].t_ms else: 0
  let thru =
    if total_ms > 0: float(consumed.load) / (total_ms.float / 1000.0) else: 0.0
  echo ""
  echo &"── {sc.name}  [{sc.policy}]"
  echo &"   inbox: main={sc.main_chan} worker={sc.worker_chan}   " &
    &"msgs={produced.load} consumed={consumed.load}"
  if sc.frame_shaped:
    echo &"   edits produced    : {produced_edits.load:>8}      " &
      &"(coalesced into {produced.load} msgs)"
    echo &"   max pending store : {max_dirty.load:>8} chunks " &
      "(deferred upstream memory; coalesces)"
  echo &"   max send latency : {max_send_us.load:>8} µs    " &
    "(blocking shows up here)"
  echo &"   max in-flight     : {max_backlog.load:>8} msgs  " &
    "(channel overflow / memory)"
  echo &"   max pressure      : {max_pressure_milli.load.float / 1000.0:>8.2f}"
  echo &"   throughput        : {thru.int:>8} msg/s"
  echo &"   result            : " & (if ok: "ok" else: "WEDGED (hit deadline)")
  echo &"   backlog timeline  : {backlog_timeline()}"

# --- scenarios ------------------------------------------------------------------
proc scenarios(): seq[Scenario] =
  # enu-like sizes; a 400ms consumer stall after 1000 items, on a 20k stream.
  for policy in [Blocking, Buffered, Gated]:
    result.add Scenario(
      name: "stall-" & $policy,
      policy: policy,
      main_chan: 2000,
      worker_chan: 500,
      produce_total: 20_000,
      produce_batch: 64,
      stall_at: 1000,
      stall_ms: 400,
      gate: 0.9,
    )
  # The real freeze: consumer waits on the producer while not draining.
  for policy in [Blocking, Buffered, Gated]:
    result.add Scenario(
      name: "deadlock-" & $policy,
      policy: policy,
      main_chan: 2000,
      worker_chan: 500,
      produce_total: 20_000,
      produce_batch: 64,
      stall_at: 1000,
      gate: 0.9,
      wait_for_producer: true,
    )

  # enu-shaped: worker frame produces a 600-chunk draw/frame into a coalescing
  # store (chunk_space 2000), 60k edits, with a 400ms consumer stall. Both are
  # buffer=true (no freeze); the difference is whether the FLUSH is gated.
  template enu_frame(nm: string, gate_the_flush: bool): Scenario =
    Scenario(
      name: nm, policy: Buffered, main_chan: 2000, worker_chan: 500,
      produce_total: 60_000, stall_at: 1500, stall_ms: 400, gate: 0.9,
      consume_us: 8,
      frame_shaped: true, frame_edits: 600, chunk_space: 2000,
      gate_flush: gate_the_flush,
    )
  result.add enu_frame("enu-flush-ungated (buffer-flip only)", false)
  result.add enu_frame("enu-flush-gated  (proposed fix)", true)

  # ASAP burst: one frame draws 8000 distinct chunks (>> the 2000 inbox) before
  # any pressure check -- the case enu's advance gate can't catch. Shows whether
  # the incremental flush gate is needed to bound channel overflow.
  template asap_burst(nm: string, gate_the_flush: bool): Scenario =
    Scenario(
      name: nm, policy: Buffered, main_chan: 2000, worker_chan: 500,
      produce_total: 40_000, stall_at: 1, stall_ms: 0, gate: 0.9,
      consume_us: 20,
      frame_shaped: true, frame_edits: 8000, chunk_space: 8000,
      gate_flush: gate_the_flush,
    )
  result.add asap_burst("asap-flush-ungated (buffer-flip only)", false)
  result.add asap_burst("asap-flush-gated  (proposed fix)", true)

when is_main_module:
  Ed.bootstrap
  echo "channel flow-control benchmark"
  echo "(consumer stalls 400ms mid-stream; watch send latency + in-flight)"
  for sc in scenarios():
    let ok = run_scenario(sc)
    report(sc, ok)
    g_main_ctx.clear
  echo ""
