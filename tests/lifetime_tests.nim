import std/[unittest, sets, tables]
import ed
import ed/zens/contexts

type OwnerTest = ref object of EdRef
  id: string
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
    test "own scope records ownership; destroy_owned tears containers down":
      var ctx = EdContext.init(id = "own_ctx")
      Ed.thread_ctx = ctx
      var owner = OwnerTest(id: "owner1")
      owner.own:
        owner.items = EdSeq[int].init(ctx = ctx, id = "own_items")
        owner.val = EdValue[int].init(ctx = ctx, id = "own_val")

      check "own_items" in ctx
      check "own_val" in ctx
      check owner.items.owner_id == "owner1"        # ownership baked into the object
      check "own_items" in ctx.owned_by["owner1"]   # and indexed

      ctx.destroy_owned("owner1")
      check "own_items" notin ctx                   # destroyed → out of ctx.objects
      check "own_val" notin ctx
      check "owner1" notin ctx.owned_by

    test "callbacks tracked in an own scope untrack on finish":
      var ctx = EdContext.init(id = "own_ctx2")
      Ed.thread_ctx = ctx
      var external = EdValue[int].init(ctx = ctx, id = "ext")
      var owner = OwnerTest(id: "owner2")

      var fired = 0
      owner.own:
        external.track proc(changes: seq[Change[int]]) {.gcsafe.} =
          fired.inc

      external.value = 1
      check fired > 0                 # fires while tracked

      owner.lifetime.finish()
      let after = fired
      external.value = 2
      check fired == after            # untracked by finish (lifetime = callbacks)

    test "nested own scopes attribute containers to the innermost owner":
      var ctx = EdContext.init(id = "own_ctx3")
      Ed.thread_ctx = ctx
      var outer = OwnerTest(id: "outer")
      var inner = OwnerTest(id: "inner")

      outer.own:
        outer.items = EdSeq[int].init(ctx = ctx, id = "outer_items")
        inner.own:
          inner.items = EdSeq[int].init(ctx = ctx, id = "inner_items")
        outer.val = EdValue[int].init(ctx = ctx, id = "outer_val") # back to outer

      check inner.items.owner_id == "inner"
      check outer.items.owner_id == "outer"
      check outer.val.owner_id == "outer"

      ctx.destroy_owned("inner")
      check "inner_items" notin ctx
      check "outer_items" in ctx      # outer's still alive
      check "outer_val" in ctx

      ctx.destroy_owned("outer")
      check "outer_items" notin ctx
      check "outer_val" notin ctx

    test "id.own: (string form) attributes containers to the id at construction":
      var ctx = EdContext.init(id = "own_str_ctx")
      Ed.thread_ctx = ctx
      let bid = "build_42"
      bid.own: # owner id known before the owner object exists
        discard EdSeq[int].init(ctx = ctx, id = "bi_items")
        discard EdValue[int].init(ctx = ctx, id = "bi_val")

      check EdSeq[int](ctx["bi_items"]).owner_id == "build_42"
      check "bi_items" in ctx.owned_by["build_42"]

      ctx.destroy_owned("build_42")
      check "bi_items" notin ctx
      check "bi_val" notin ctx

    test "owner_id syncs; a non-creator context tears down via the owned index":
      # The MCP case: one context builds an owned container; another (which never
      # constructed it) destroys it via the synced ownership.
      var ctx1 = EdContext.init(id = "own_src", blocking_recv = true)
      var ctx2 = EdContext.init(id = "own_dst", blocking_recv = true)
      ctx2.subscribe(ctx1)
      Ed.thread_ctx = ctx1
      ctx1.tick(blocking = false)

      var owner = OwnerTest(id: "mcp_bot")
      owner.own:
        owner.items = EdSeq[int].init(ctx = ctx1, id = "bot_items")
      owner.items.add 42 # a change, so it syncs

      ctx2.tick

      check "bot_items" in ctx2
      check EdSeq[int](ctx2["bot_items"]).owner_id == "mcp_bot" # rode the CREATE
      check "bot_items" in ctx2.owned_by["mcp_bot"]             # indexed on the replica

      ctx2.destroy_owned("mcp_bot") # ctx2 never built it, but owns the teardown
      check "bot_items" notin ctx2
