import std/[unittest, sets]
import ed
import ed/zens/contexts

type OwnerTest = ref object of EdRef
  items: EdSeq[int]
  val: EdValue[int]

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

  suite "own scope":
    test "containers created in an own scope are torn down by finish":
      var ctx = EdContext.init(id = "own_ctx")
      Ed.thread_ctx = ctx
      var owner = OwnerTest()
      owner.own:
        owner.items = EdSeq[int].init(ctx = ctx, id = "own_items")
        owner.val = EdValue[int].init(ctx = ctx, id = "own_val")

      check "own_items" in ctx
      check "own_val" in ctx
      check not owner.lifetime.is_nil

      owner.lifetime.finish()
      check "own_items" notin ctx     # destroyed → removed from ctx.objects
      check "own_val" notin ctx
      check owner.items.destroyed

    test "callbacks tracked in an own scope untrack on finish":
      var ctx = EdContext.init(id = "own_ctx2")
      Ed.thread_ctx = ctx
      var external = EdValue[int].init(ctx = ctx, id = "ext")
      var owner = OwnerTest()

      var fired = 0
      owner.own:
        external.track proc(changes: seq[Change[int]]) {.gcsafe.} =
          fired.inc

      external.value = 1
      check fired > 0                 # fires while tracked

      owner.lifetime.finish()
      let after = fired
      external.value = 2
      check fired == after            # untracked by finish

    test "nested own scopes bind to the innermost owner":
      var ctx = EdContext.init(id = "own_ctx3")
      Ed.thread_ctx = ctx
      var outer = OwnerTest()
      var inner = OwnerTest()

      outer.own:
        outer.items = EdSeq[int].init(ctx = ctx, id = "outer_items")
        inner.own:
          inner.items = EdSeq[int].init(ctx = ctx, id = "inner_items")
        outer.val = EdValue[int].init(ctx = ctx, id = "outer_val") # back to outer

      inner.lifetime.finish()
      check "inner_items" notin ctx
      check "outer_items" in ctx      # outer's still alive
      check "outer_val" in ctx

      outer.lifetime.finish()
      check "outer_items" notin ctx
      check "outer_val" notin ctx

    test "destroy_fields destroys Ed container fields regardless of construction":
      # The synced-replica path: containers built outside any `own` scope still
      # tear down via reflection.
      var ctx = EdContext.init(id = "df_ctx")
      Ed.thread_ctx = ctx
      var owner = OwnerTest()
      owner.items = EdSeq[int].init(ctx = ctx, id = "df_items")   # no own scope
      owner.val = EdValue[int].init(ctx = ctx, id = "df_val")

      check "df_items" in ctx
      check "df_val" in ctx

      owner.destroy_fields()
      check "df_items" notin ctx
      check "df_val" notin ctx
