import std/[unittest, sequtils]
import ed

# Regression gate for the context-teardown leak (branch fix/ctx-teardown-leak):
# EdBodyBase.publish_create captured the body + its context, an ORC-uncollectable
# closure cycle that pinned every body and its whole context. release_closures now
# nils publish_create, and EdContext.destroy releases all bodies. This test fails
# if that cycle comes back: it would show steady-state growth across create->destroy
# cycles that GC_fullCollect can't reclaim.

proc cycle(n: int) =
  var ctx = EdContext.init(id = "teardown")
  Ed.thread_ctx = ctx
  for i in 0 ..< n:
    block:
      var v = EdValue[string].init(ctx = ctx, id = "v" & $i)
      v.value = "x"
      v.destroy()
    # proxy drops at block exit
  ctx.destroy()
  ctx = nil
  Ed.thread_ctx = nil
  GC_fullCollect()
  GC_fullCollect()

proc run*() =
  test "EdContext.destroy reclaims bodies -- no steady-state growth":
    const N = 200
    const ITERS = 8
    cycle(N) # warm up one-time allocations (type registries, threadvars)
    cycle(N)
    let base = getOccupiedMem()
    for _ in 1 .. ITERS:
      cycle(N)
    let growth = getOccupiedMem() - base
    # Pre-fix this leaked ~2 MB/cycle (~16 MB over 8 cycles). Post-fix it's flat;
    # the slack covers reachable per-cycle caches. A regressed closure cycle would
    # blow far past this.
    checkpoint("occupied-mem growth over " & $ITERS & " cycles: " & $growth & " B")
    check growth < 512 * 1024

  test "destroying a LOCAL peer notifies the survivor (drops its reverse sub)":
    # enu's main<->worker shape: a long-lived survivor subscribes to a worker that
    # is torn down on level reload. Without peer-notify the survivor keeps a
    # stale sub to the dead worker's inbox (fanning ops into it forever) and never
    # learns to reap what the worker owned (drain_unsubscribed).
    var survivor = EdContext.init(id = "survivor")
    var worker = EdContext.init(id = "worker1")
    Ed.thread_ctx = survivor
    survivor.subscribe(worker) # bidirectional local: survivor <-> worker
    survivor.tick()
    worker.tick()
    check worker.id in survivor.subscribers.map_it(it.ctx_id)
    check survivor.id in worker.subscribers.map_it(it.ctx_id)

    worker.destroy() # reload tears the worker down
    survivor.tick()  # survivor processes the worker's UNSUBSCRIBE

    check worker.id notin survivor.subscribers.map_it(it.ctx_id)
    check worker.id in survivor.drain_unsubscribed

when is_main_module:
  Ed.bootstrap
  run()
