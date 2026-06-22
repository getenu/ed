import std/[locks, unittest]
import ed
import test_util

var global_lock: Lock
global_lock.init_lock
var global_cond: Cond
global_cond.init_cond
var worker_thread: Thread[EdContext]

proc start_worker(ctx: EdContext) {.thread.} =
  Ed.thread_ctx = ctx

  var b = EdValue[string](ctx["t1"])
  var working = true
  b.changes:
    if "scott".added:
      it.value = "marie"
    if "claire".added:
      it.value = "cal"
    if "vin".added:
      it.value = "banana"
    if "bacon".added:
      it.value = "ghetti"
    if "done".added:
      working = false

  global_cond.signal()
  while working:
    ctx.tick

proc run*() =
  test "basic":
    Ed.thread_ctx.clear
    Ed.thread_ctx = EdContext.init(id = "main")
    let host = free_addr()
    var ctx = EdContext.init(id = "worker", listen_address = host)
    Ed.thread_ctx.subscribe host,
      callback = proc() =
        ctx.tick

    var a = Ed.init("", id = "t1")
    ctx.tick(blocking = true)
    global_lock.acquire()
    worker_thread.create_thread(start_worker, ctx)
    global_cond.wait(global_lock)
    global_lock.release()
    a.value = "scott"
    var remaining = 1000
    var working = true
    a.changes:
      if "marie".added:
        it.value = "claire"
      if "cal".added:
        it.value = "vin"
      if "banana".added:
        it.value = "bacon"
      if "ghetti".added:
        remaining -= 1
        if remaining == 0:
          it.value = "done"
          working = false
        else:
          it.value = "scott"

    while working:
      Ed.thread_ctx.tick
    worker_thread.join_thread
    ctx.close

when is_main_module:
  Ed.bootstrap
  run()
