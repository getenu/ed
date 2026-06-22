import std/[unittest, sets, tables]
import ed
import ed/zens/contexts

type OwnerTest = ref object of EdRef
  items: EdSeq[int]
  val: EdValue[int]
  kids: EdSeq[OwnerTest]

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

    test "ownership survives a relay (creator -> hub -> second hop)":
      # The enu topology: an MCP client builds a bot, the worker (hub) relays it
      # to the node ctx. The hub's initializer re-broadcasts the CREATE *while*
      # materializing, so ownership must be stamped inside that window or the
      # second hop receives the container unowned.
      var ctx1 = EdContext.init(id = "relay_src", blocking_recv = true)
      var ctx2 = EdContext.init(id = "relay_hub", blocking_recv = true)
      var ctx3 = EdContext.init(id = "relay_dst", blocking_recv = true)
      ctx2.subscribe(ctx1)
      ctx3.subscribe(ctx2)
      Ed.thread_ctx = ctx1
      ctx1.tick(blocking = false)

      var owner = OwnerTest(id: "relay_bot")
      owner.own:
        owner.items = EdSeq[int].init(ctx = ctx1, id = "relay_items")
      owner.items.add 7

      ctx2.tick
      ctx3.tick

      check "relay_items" in ctx2
      check "relay_items" in ctx3
      check EdSeq[int](ctx2["relay_items"]).owner_id == "relay_bot"
      check EdSeq[int](ctx3["relay_items"]).owner_id == "relay_bot" # second hop
      check "relay_items" in ctx3.owned_by["relay_bot"]

      ctx3.destroy_owned("relay_bot")
      check "relay_items" notin ctx3

    test "EdRef destroy: lifetime, owned containers, destroyed latch":
      var ctx = EdContext.init(id = "rd_ctx")
      Ed.thread_ctx = ctx
      var external = EdValue[int].init(ctx = ctx, id = "rd_ext")
      var owner = OwnerTest(id: "rd_owner")
      var fired = 0
      owner.own:
        owner.items = EdSeq[int].init(ctx = ctx, id = "rd_items")
        external.track proc(changes: seq[Change[int]]) {.gcsafe.} =
          fired.inc

      external.value = 1
      check fired > 0

      owner.destroy() # the ed-generic teardown
      check owner.destroyed
      check "rd_items" notin ctx # owned containers gone
      let after = fired
      external.value = 2
      check fired == after # lifetime finished → callback untracked

    test "EdRef.destroy uses the ref's own context, not thread_ctx":
      # A ref stamped with ctxA (it entered ctxA's ref_pool via collection
      # membership) must tear down ctxA's owned containers even when a *different*
      # context is the active thread_ctx — destroy follows the ref's ctx backref,
      # not Ed.thread_ctx (which is wrong under multiple contexts per thread).
      var ctxA = EdContext.init(id = "xd_a")
      var ctxB = EdContext.init(id = "xd_b")
      Ed.thread_ctx = ctxA
      var child = OwnerTest(id: "xd_child")
      child.own:
        child.items = EdSeq[int].init(ctx = ctxA, id = "xd_child_items")
      var parent = OwnerTest(id: "xd_parent")
      parent.own:
        parent.kids = EdSeq[OwnerTest].init(
          ctx = ctxA, id = "xd_kids", flags = DEFAULT_FLAGS + {OWNS_MEMBERS}
        )
      parent.kids.add child # → ctxA.ref_pool, stamps child.ctx = ctxA
      check child.ctx == ctxA

      Ed.thread_ctx = ctxB # the wrong context is now active
      child.destroy()
      check child.destroyed
      check "xd_child_items" notin ctxA # torn down via child.ctx, not thread_ctx

    test "OWNS_MEMBERS: destroying the owner cascades into members":
      var ctx = EdContext.init(id = "om_ctx")
      Ed.thread_ctx = ctx
      var child = OwnerTest(id: "om_child")
      child.own:
        child.items = EdSeq[int].init(ctx = ctx, id = "om_child_items")
      var parent = OwnerTest(id: "om_parent")
      parent.own:
        parent.kids = EdSeq[OwnerTest].init(
          ctx = ctx, id = "om_kids", flags = DEFAULT_FLAGS + {OWNS_MEMBERS}
        )
      parent.kids.add child # membership → owned by parent

      parent.destroy()
      check child.destroyed # member cascaded via the destroy method
      check "om_child_items" notin ctx # ...including the child's own containers
      check "om_kids" notin ctx # parent's container destroyed too

    test "OWNS_MEMBERS: a removed member is not cascaded":
      var ctx = EdContext.init(id = "om_ctx2")
      Ed.thread_ctx = ctx
      var child = OwnerTest(id: "om2_child")
      var parent = OwnerTest(id: "om2_parent")
      parent.own:
        parent.kids = EdSeq[OwnerTest].init(
          ctx = ctx, id = "om2_kids", flags = DEFAULT_FLAGS + {OWNS_MEMBERS}
        )
      parent.kids.add child
      parent.kids -= child # removal un-registers from the owned index

      parent.destroy()
      check not child.destroyed # independently-removed member untouched
