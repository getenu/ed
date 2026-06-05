import std/[unittest, sets]
import ed
import ed/zens/contexts

proc run*() =
  suite "lifetime":
    test "finish untracks callbacks bound to the lifetime":
      var ctx = EdContext.init(id = "lt_ctx")
      var v = EdValue[int].init(ctx = ctx, id = "v")
      let life = new_lifetime()

      var fired = 0
      v.track(life, proc(changes: seq[Change[int]]) {.gcsafe.} =
        fired.inc
      )

      v.value = 1
      check fired > 0 # fires while tracked

      life.finish()
      check life.finished
      let after_finish = fired # finish may itself fire one CLOSED

      v.value = 2
      v.value = 3
      check fired == after_finish # silent after finish — callback removed

    test "binding to an already-finished lifetime cleans up immediately":
      var ctx = EdContext.init(id = "lt_ctx2")
      var v = EdValue[int].init(ctx = ctx, id = "v2")
      let life = new_lifetime()
      life.finish() # finished before any tracking

      var mutations = 0
      v.track(life, proc(changes: seq[Change[int]]) {.gcsafe.} =
        for c in changes:
          if CLOSED notin c.changes:
            mutations.inc
      )
      v.value = 1
      check mutations == 0 # registered then untracked at once; no mutation seen

    test "finish is idempotent":
      let life = new_lifetime()
      var ran = 0
      life.add proc() {.gcsafe.} =
        ran.inc
      life.finish()
      life.finish()
      check ran == 1
