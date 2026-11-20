import std/[unittest, sets, tables]
import ed
import ed/lifecycle
import ed/zens/contexts

type OwnerTest = ref object of EdRef
  items: Ed[seq[int]]
  val: Ed[int]
  kids: Ed[seq[OwnerTest]]

type ReincUnit = ref object of EdRef
  # Minimal model of an enu Build for the reincarnation tests: one owned
  # container, no recursive/extra fields (rules out OwnerTest's val/kids
  # serialization as the cause).
  items: Ed[seq[int]]

type MoveUnit = ref object of EdRef
  items: Ed[seq[int]]
  note: string # plain: stays on each side, so it shows which object this is

# Register the synced ref types so they cross contexts (parse/stringify +
# type_id). Without this the replica deserializes garbage (IndexDefect).
Ed.register(OwnerTest, false)
Ed.register(ReincUnit, false)
Ed.register(MoveUnit, false)

proc run*() =
  suite "lifetime":
    test "finish untracks callbacks bound to the lifetime":
      var ctx = EdContext.init(id = "lt_ctx")
      var v = Ed[int].init(ctx = ctx, id = "v")
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
      check fired == after_finish # silent after finish -- callback removed

    test "binding to an already-finished lifetime cleans up immediately":
      var ctx = EdContext.init(id = "lt_ctx2")
      var v = Ed[int].init(ctx = ctx, id = "v2")
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
        owner.items = Ed[seq[int]].init(ctx = ctx, id = "own_items")
        owner.val = Ed[int].init(ctx = ctx, id = "own_val")

      check "own_items" in ctx
      check "own_val" in ctx
      check owner.items.owner_id == "owner1"        # ownership baked into the object
      check "own_items" in ctx.owned_by["owner1"]   # and indexed

      ctx.destroy_owned("owner1")
      check "own_items" notin ctx                   # destroyed -> out of ctx.objects
      check "own_val" notin ctx
      check "owner1" notin ctx.owned_by

    test "callbacks tracked in an own scope untrack on finish":
      var ctx = EdContext.init(id = "own_ctx2")
      Ed.thread_ctx = ctx
      var external = Ed[int].init(ctx = ctx, id = "ext")
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
        outer.items = Ed[seq[int]].init(ctx = ctx, id = "outer_items")
        inner.own:
          inner.items = Ed[seq[int]].init(ctx = ctx, id = "inner_items")
        outer.val = Ed[int].init(ctx = ctx, id = "outer_val") # back to outer

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
        discard Ed[seq[int]].init(ctx = ctx, id = "bi_items")
        discard Ed[int].init(ctx = ctx, id = "bi_val")

      check Ed[seq[int]](ctx["bi_items"]).owner_id == "build_42"
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
        owner.items = Ed[seq[int]].init(ctx = ctx1, id = "bot_items")
      owner.items.add 42 # a change, so it syncs

      ctx2.tick

      check "bot_items" in ctx2
      check Ed[seq[int]](ctx2["bot_items"]).owner_id == "mcp_bot" # rode the CREATE
      check "bot_items" in ctx2.owned_by["mcp_bot"]             # indexed on the replica

      ctx2.destroy_owned("mcp_bot") # ctx2 never built it, but owns the teardown
      check "bot_items" notin ctx2

    test "set_owner: a standalone EdRef cascades through destroy_owned":
      # The enu Shared pattern: a root unit mints a standalone EdRef (not a
      # member of any OWNS_MEMBERS collection) owning containers, publishes it
      # through a synced field, and attributes it to itself via set_owner.
      # Destroying the unit must cascade: unit -> (set_owner) Shared ->
      # (own scope) its containers. Regression: set_owner indexed the BARE id
      # while destroy_owned resolves ref_pool keys (tid:id) -- the ref silently
      # escaped the cascade and its containers leaked on every reload.
      var ctx = EdContext.init(id = "so_ctx")
      Ed.thread_ctx = ctx

      var owner = OwnerTest(id: "so_unit")
      owner.own:
        owner.items = Ed[seq[int]].init(ctx = ctx, id = "so_unit_items")

      var shared = OwnerTest(id: "so_shared")
      shared.id.own:
        shared.items = Ed[seq[int]].init(ctx = ctx, id = "so_shared_items")
      # Publish through a synced field so the ref enters ref_pool (the enu
      # shared_value pattern), then attribute it to the unit.
      var shared_value = Ed[OwnerTest].init(ctx = ctx, id = "so_shared_val")
      shared_value.value = shared
      ctx.set_owner(shared, "so_unit")

      owner.destroy()
      check owner.destroyed
      check "so_unit_items" notin ctx # the unit's own containers died
      check shared.destroyed # the set_owner'd ref cascaded
      check "so_shared_items" notin ctx # ...and everything IT owned died too

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
        owner.items = Ed[seq[int]].init(ctx = ctx1, id = "relay_items")
      owner.items.add 7

      ctx2.tick
      ctx3.tick

      check "relay_items" in ctx2
      check "relay_items" in ctx3
      check Ed[seq[int]](ctx2["relay_items"]).owner_id == "relay_bot"
      check Ed[seq[int]](ctx3["relay_items"]).owner_id == "relay_bot" # second hop
      check "relay_items" in ctx3.owned_by["relay_bot"]

      ctx3.destroy_owned("relay_bot")
      check "relay_items" notin ctx3

    test "destroy cascade carries op-source: a same-id recreate survives the echo":
      # The enu worker<->main topology: one ordered authority, a *bidirectional*
      # replica, zero contention. Destroying an owner cascades a DESTROY to its
      # owned container; if that cascade DESTROY goes out with an empty
      # OperationContext (no source), the replica re-publishes it back to the
      # authority -- where it lands AFTER the authority has recreated the same id,
      # killing the live recreate. A single ordered producer over FIFO can only
      # misorder if an op echoes, and the cascade is the lone sourceless op.
      var auth = EdContext.init(id = "casc_auth", is_authority = true)
      var rep = EdContext.init(id = "casc_rep")
      rep.subscribe(auth) # bidirectional (default)
      Ed.thread_ctx = auth

      proc make_owner(): OwnerTest =
        result = OwnerTest(id: "casc_owner")
        result.own:
          result.items = Ed[seq[int]].init(ctx = auth, id = "casc_items")

      var o1 = make_owner()
      o1.items.add 1
      rep.tick
      check "casc_items" in rep

      # Reload: destroy gen 1 (cascade DESTROY casc_items), recreate the same ids.
      o1.destroy()
      var o2 = make_owner()
      o2.items.add 2

      # Drain all cross-context traffic, including any echo back to the authority.
      for _ in 0 ..< 6:
        rep.tick(blocking = false)
        auth.tick(blocking = false)

      # The live recreate must still be valid on the authority -- the stale
      # DESTROY for the old incarnation must not have echoed back onto it.
      check "casc_items" in auth
      check o2.items.valid
      check o2.items.len == 1
      check o2.items[0] == 2

    test "OWNS_MEMBERS member reload: same-id member survives the cross-context echo":
      # Closer to enu: the reloaded unit is a *member* of an OWNS_MEMBERS
      # collection (state.units), reused by id. Remove+destroy it, recreate the
      # same id, re-add. Any op in this dance that re-broadcasts without
      # accumulating its source echoes back and can corrupt the live recreate
      # (its owned container, or its ref-pool refcount).
      var auth = EdContext.init(id = "mem_auth", is_authority = true)
      var rep = EdContext.init(id = "mem_rep")
      rep.subscribe(auth) # bidirectional
      Ed.thread_ctx = auth

      var units = Ed[seq[OwnerTest]].init(
        ctx = auth, id = "mem_units", flags = DEFAULT_FLAGS + {OWNS_MEMBERS}
      )

      proc make_member(): OwnerTest =
        result = OwnerTest(id: "mem_build")
        result.own:
          result.items = Ed[seq[int]].init(ctx = auth, id = "mem_items")

      var m1 = make_member()
      m1.items.add 1
      units.add m1
      rep.tick
      check "mem_items" in rep

      # Reload: remove + destroy gen 1, recreate the same ids, re-add.
      units -= m1
      m1.destroy()
      var m2 = make_member()
      m2.items.add 2
      units.add m2

      for _ in 0 ..< 6:
        rep.tick(blocking = false)
        auth.tick(blocking = false)

      check "mem_items" in auth
      check m2.items.valid
      check m2.items.len == 1
      check m2.items[0] == 2

    test "REINC same-tick: replica must swap to the new incarnation":
      # The enu reload bug, isolated from enu. A registered EdRef "ri_x" lives in
      # a synced seq (models state.units); its owned container "ri_x_items"
      # (models the build's code/units fields) carries a value that identifies
      # the incarnation. Reload = remove+destroy gen 1, recreate the SAME ids,
      # re-add -- all in one tick (no tick between destroy and recreate). The
      # replica must end up reflecting gen 2, not pinned on the dead gen 1.
      var auth = EdContext.init(id = "ri1_auth", is_authority = true)
      var rep = EdContext.init(id = "ri1_rep")
      rep.subscribe(auth)
      Ed.thread_ctx = auth

      var units = Ed[seq[ReincUnit]].init(ctx = auth, id = "ri1_units")
      proc make(v: int): ReincUnit =
        result = ReincUnit(id: "ri1_x")
        result.own:
          result.items = Ed[seq[int]].init(ctx = auth, id = "ri1_x_items")
        result.items.add v

      var x1 = make(1)
      units.add x1
      for _ in 0 ..< 4:
        auth.tick(blocking = false)
        rep.tick(blocking = false)
      check "ri1_x_items" in rep
      check Ed[seq[int]](rep["ri1_x_items"]).value == @[1]

      # Count what the replica's seq watcher sees across the reload (the enu
      # "node_ctrl state.units change" signature: added=N, removed=M).
      var rep_added, rep_removed: int
      Ed[seq[ReincUnit]](rep["ri1_units"]).track proc(
          cs: seq[Change[ReincUnit]]
      ) {.gcsafe.} =
        for c in cs:
          if ADDED in c.changes:
            inc rep_added
          if REMOVED in c.changes:
            inc rep_removed

      # Same-tick reload.
      units -= x1
      x1.destroy()
      var x2 = make(2)
      units.add x2
      for _ in 0 ..< 6:
        auth.tick(blocking = false)
        rep.tick(blocking = false)

      check Ed[seq[ReincUnit]](rep["ri1_units"]).len == 1
      check "ri1_x_items" in rep
      check rep["ri1_x_items"].valid
      check Ed[seq[int]](rep["ri1_x_items"]).value == @[2]
      check rep_added == rep_removed # balanced: every add paired with a remove

    test "REINC tick-between: does a publish boundary fix it 100%":
      # Same as above but with a full drain (tick on both sides) BETWEEN destroy
      # and recreate, so the DESTROY is published and applied before the CREATE
      # exists. Determines whether "no same-tick destroy+create" is a complete
      # fix or just a likelihood reduction.
      var auth = EdContext.init(id = "ri2_auth", is_authority = true)
      var rep = EdContext.init(id = "ri2_rep")
      rep.subscribe(auth)
      Ed.thread_ctx = auth

      var units = Ed[seq[ReincUnit]].init(ctx = auth, id = "ri2_units")
      proc make(v: int): ReincUnit =
        result = ReincUnit(id: "ri2_x")
        result.own:
          result.items = Ed[seq[int]].init(ctx = auth, id = "ri2_x_items")
        result.items.add v

      var x1 = make(1)
      units.add x1
      for _ in 0 ..< 4:
        auth.tick(blocking = false)
        rep.tick(blocking = false)
      check Ed[seq[int]](rep["ri2_x_items"]).value == @[1]

      # Reload WITH a publish boundary between destroy and recreate.
      units -= x1
      x1.destroy()
      for _ in 0 ..< 4:
        auth.tick(blocking = false)
        rep.tick(blocking = false)
      check "ri2_x_items" notin rep # the dead incarnation is gone on the replica

      var x2 = make(2)
      units.add x2
      for _ in 0 ..< 6:
        auth.tick(blocking = false)
        rep.tick(blocking = false)

      check Ed[seq[ReincUnit]](rep["ri2_units"]).len == 1
      check "ri2_x_items" in rep
      check rep["ri2_x_items"].valid
      check Ed[seq[int]](rep["ri2_x_items"]).value == @[2]

    test "REINC storm: many reincarnations in one replica drain (enu churn)":
      # The enu failure: the authority (worker) churns many same-id incarnations
      # while the replica (main) falls behind, so the replica processes a *batch*
      # spanning several reincarnations in one drain. Models that by flushing only
      # the authority between reloads, then draining the replica once at the end.
      # The replica must converge on the LAST incarnation -- valid, not a stale one.
      var auth = EdContext.init(id = "ri3_auth", is_authority = true)
      # Room for the whole unread churn: the authority's sends block once the
      # replica's channel is full, and nothing drains it until the end.
      var rep = EdContext.init(id = "ri3_rep", chan_size = 400)
      rep.subscribe(auth)
      Ed.thread_ctx = auth

      var units = Ed[seq[ReincUnit]].init(ctx = auth, id = "ri3_units")
      proc make(v: int): ReincUnit =
        result = ReincUnit(id: "ri3_x")
        result.own:
          result.items = Ed[seq[int]].init(ctx = auth, id = "ri3_x_items")
        result.items.add v

      var cur = make(0)
      units.add cur
      for _ in 0 ..< 4:
        auth.tick(blocking = false)
        rep.tick(blocking = false)
      check Ed[seq[int]](rep["ri3_x_items"]).value == @[0]

      # Churn 20 same-id incarnations, flushing ONLY the authority each time so
      # the replica's inbox accumulates a multi-incarnation batch.
      for gen in 1 .. 20:
        units -= cur
        cur.destroy()
        cur = make(gen)
        units.add cur
        auth.tick(blocking = false)

      # Replica catches up in one go.
      for _ in 0 ..< 8:
        rep.tick(blocking = false)
        auth.tick(blocking = false)

      check Ed[seq[ReincUnit]](rep["ri3_units"]).len == 1
      check "ri3_x_items" in rep
      check rep["ri3_x_items"].valid
      check Ed[seq[int]](rep["ri3_x_items"]).value == @[20] # the latest, not a stale one

    test "REINC held ref: a held reference is destroyed, and the reload is a new object":
      # A consumer that holds the unit across a reload sees it destroyed -- ed
      # doesn't bring it back -- and the collection holds a new object under the
      # same id. (Holders let go on removal or destroy: see fix-1.)
      var auth = EdContext.init(id = "ri4_auth", is_authority = true)
      var rep = EdContext.init(id = "ri4_rep")
      rep.subscribe(auth)
      Ed.thread_ctx = auth

      var units = Ed[seq[ReincUnit]].init(ctx = auth, id = "ri4_units")
      proc make(v: int): ReincUnit =
        result = ReincUnit(id: "ri4_x") # stable id (the build), reincarnated
        result.own:
          # Fresh field id per incarnation -- models enu, where a reloaded build's
          # owned containers (code/units) get newly-generated ids each time.
          result.items = Ed[seq[int]].init(ctx = auth, id = "ri4_x_items_" & $v)
        result.items.add v

      var cur = make(0)
      units.add cur
      for _ in 0 ..< 4:
        auth.tick(blocking = false)
        rep.tick(blocking = false)

      # The consumer captures and HOLDS a reference (never released).
      var held = Ed[seq[ReincUnit]](rep["ri4_units"]).value[0]
      check held.items.valid
      check held.items.value == @[0]

      # Churn, draining the replica fully each time -- the consumer keeps `held`.
      for gen in 1 .. 20:
        units -= cur
        cur.destroy()
        cur = make(gen)
        units.add cur
        for _ in 0 ..< 3:
          auth.tick(blocking = false)
          rep.tick(blocking = false)

      check held.destroyed
      let current = Ed[seq[ReincUnit]](rep["ri4_units"]).value[0]
      check current != held
      check not current.destroyed
      check current.items.value == @[20]

    test "on_destroy fires in every context, and not on removal":
      var auth = EdContext.init(id = "od_auth", is_authority = true)
      var rep = EdContext.init(id = "od_rep")
      rep.subscribe(auth)
      Ed.thread_ctx = auth

      var units = Ed[seq[ReincUnit]].init(ctx = auth, id = "od_units")
      var x = ReincUnit(id: "od_x")
      x.own:
        x.items = Ed[seq[int]].init(@[0], ctx = auth, id = "od_x_items")
      units.add x
      for _ in 0 ..< 4:
        auth.tick(blocking = false)
        rep.tick(blocking = false)

      let copy = Ed[seq[ReincUnit]](rep["od_units"]).value[0]
      var auth_fired, rep_fired = 0
      var rep_saw: seq[int]
      x.on_destroy:
        check it == x
        auth_fired.inc
      copy.on_destroy:
        # The destroy arrives ahead of the teardown: the object is still whole.
        rep_saw = it.items.value
        rep_fired.inc

      # A move: removed and added back, never destroyed.
      units -= x
      units.add x
      for _ in 0 ..< 4:
        auth.tick(blocking = false)
        rep.tick(blocking = false)
      check auth_fired == 0
      check rep_fired == 0

      units -= x
      x.destroy()
      for _ in 0 ..< 4:
        auth.tick(blocking = false)
        rep.tick(blocking = false)
      check auth_fired == 1
      check rep_fired == 1
      check rep_saw == @[0]
      check copy.destroyed

    test "a destroy ends only the incarnation it names":
      # The replica destroys its copy of the first object late -- after the
      # authority already made a new one under the same id. That destroy must
      # not reach the new object.
      var auth = EdContext.init(id = "inc_auth", is_authority = true)
      var rep = EdContext.init(id = "inc_rep")
      rep.subscribe(auth)
      Ed.thread_ctx = auth

      var units = Ed[seq[ReincUnit]].init(ctx = auth, id = "inc_units")
      proc make(v: int): ReincUnit =
        result = ReincUnit(id: "inc_x")
        result.own:
          result.items = Ed[seq[int]].init(ctx = auth, id = "inc_x_items_" & $v)
        result.items.add v

      var x1 = make(1)
      units.add x1
      for _ in 0 ..< 4:
        auth.tick(blocking = false)
        rep.tick(blocking = false)
      let stale = Ed[seq[ReincUnit]](rep["inc_units"]).value[0]

      units -= x1
      var x2 = make(2)
      units.add x2
      for _ in 0 ..< 4:
        auth.tick(blocking = false)
        rep.tick(blocking = false)
      check x2.incarnation != stale.incarnation

      Ed.thread_ctx = rep
      stale.destroy()
      for _ in 0 ..< 4:
        rep.tick(blocking = false)
        auth.tick(blocking = false)
      Ed.thread_ctx = auth
      # (The authority's `x1` isn't reached either: once a newer object holds
      # the id in a context, a destroy of the older one finds nothing there.)
      check not x2.destroyed
      check x2.items.valid
      let current = Ed[seq[ReincUnit]](rep["inc_units"]).value[0]
      check current != stale
      check not current.destroyed
      check current.items.value == @[2]

    test "a move within a tick keeps the object on the other side":
      # Nothing on the replica holds the object but the collections, so between
      # its removal and its re-add it's held only by ed for the rest of the tick.
      var auth = EdContext.init(id = "mv_auth", is_authority = true)
      var rep = EdContext.init(id = "mv_rep")
      rep.subscribe(auth)
      Ed.thread_ctx = auth

      var here = Ed[seq[MoveUnit]].init(ctx = auth, id = "mv_here")
      var there = Ed[seq[MoveUnit]].init(ctx = auth, id = "mv_there")
      var x = MoveUnit(id: "mv_x")
      x.own:
        x.items = Ed[seq[int]].init(ctx = auth, id = "mv_x_items")
      here.add x
      for _ in 0 ..< 4:
        auth.tick(blocking = false)
        rep.tick(blocking = false)
      # In a proc of its own, so no temporary here keeps the replica's copy
      # alive across the move.
      proc mark(rep: EdContext) {.nimcall.} =
        Ed[seq[MoveUnit]](rep["mv_here"]).value[0].note = "the replica's own"
      mark(rep)

      here -= x
      there.add x
      for _ in 0 ..< 4:
        auth.tick(blocking = false)
        rep.tick(blocking = false)
      proc note(rep: EdContext): string {.nimcall.} =
        Ed[seq[MoveUnit]](rep["mv_there"]).value[0].note
      check Ed[seq[MoveUnit]](rep["mv_here"]).len == 0
      check note(rep) == "the replica's own"

    test "on_destroy with a lifetime is dropped when that lifetime finishes":
      var ctx = EdContext.init(id = "odl_ctx")
      Ed.thread_ctx = ctx
      var x = ReincUnit(id: "odl_x")
      let watcher = new_lifetime()
      var fired = 0
      x.on_destroy(watcher):
        fired.inc
      watcher.finish()
      x.destroy()
      check fired == 0

    test "REINC fix-1: release-on-removal keeps the held ref valid":
      # Fix (1): the consumer (BuildNode) RELEASES its reference when the unit is
      # removed and re-acquires on add -- modelled as a seq watcher that clears
      # `held` on REMOVED and sets it on ADDED. With the reference dropped on
      # removal the object prunes, so the next CREATE mints fresh; `held` is then
      # never left pointing at destroyed fields. (The same full-reload churn as
      # the `REINC held ref` test -- only the consumer discipline differs.)
      var auth = EdContext.init(id = "ri5_auth", is_authority = true)
      var rep = EdContext.init(id = "ri5_rep")
      rep.subscribe(auth)
      Ed.thread_ctx = auth

      var units = Ed[seq[ReincUnit]].init(ctx = auth, id = "ri5_units")
      proc make(v: int): ReincUnit =
        result = ReincUnit(id: "ri5_x")
        result.own:
          result.items = Ed[seq[int]].init(ctx = auth, id = "ri5_x_items")
        result.items.add v

      var cur = make(0)
      units.add cur
      for _ in 0 ..< 4:
        auth.tick(blocking = false)
        rep.tick(blocking = false)

      var held: ReincUnit = nil
      Ed[seq[ReincUnit]](rep["ri5_units"]).track proc(
          cs: seq[Change[ReincUnit]]
      ) {.gcsafe.} =
        for c in cs:
          if REMOVED in c.changes:
            held = nil # remove_from_scene: release the reference
          if ADDED in c.changes:
            held = c.item # add_to_scene: re-acquire

      var bad = 0
      for gen in 1 .. 20:
        units -= cur
        cur.destroy()
        cur = make(gen)
        units.add cur
        for _ in 0 ..< 3:
          auth.tick(blocking = false)
          rep.tick(blocking = false)
        # Whenever the consumer holds a reference, it must be usable.
        if not held.is_nil and (held.items.is_nil or not held.items.valid):
          inc bad

      check bad == 0
      check not held.is_nil
      check held.items.valid
      check held.items.value == @[20]

    test "EdRef destroy: lifetime, owned containers, destroyed latch":
      var ctx = EdContext.init(id = "rd_ctx")
      Ed.thread_ctx = ctx
      var external = Ed[int].init(ctx = ctx, id = "rd_ext")
      var owner = OwnerTest(id: "rd_owner")
      var fired = 0
      owner.own:
        owner.items = Ed[seq[int]].init(ctx = ctx, id = "rd_items")
        external.track proc(changes: seq[Change[int]]) {.gcsafe.} =
          fired.inc

      external.value = 1
      check fired > 0

      owner.destroy() # the ed-generic teardown
      check owner.destroyed
      check "rd_items" notin ctx # owned containers gone
      let after = fired
      external.value = 2
      check fired == after # lifetime finished -> callback untracked

    test "EdRef.destroy uses the ref's own context, not thread_ctx":
      # A ref stamped with ctx_a (it entered ctx_a's ref_pool via collection
      # membership) must tear down ctx_a's owned containers even when a *different*
      # context is the active thread_ctx -- destroy follows the ref's ctx backref,
      # not Ed.thread_ctx (which is wrong under multiple contexts per thread).
      var ctx_a = EdContext.init(id = "xd_a")
      var ctx_b = EdContext.init(id = "xd_b")
      Ed.thread_ctx = ctx_a
      var child = OwnerTest(id: "xd_child")
      child.own:
        child.items = Ed[seq[int]].init(ctx = ctx_a, id = "xd_child_items")
      var parent = OwnerTest(id: "xd_parent")
      parent.own:
        parent.kids = Ed[seq[OwnerTest]].init(
          ctx = ctx_a, id = "xd_kids", flags = DEFAULT_FLAGS + {OWNS_MEMBERS}
        )
      parent.kids.add child # -> ctx_a.ref_pool, stamps child.ctx = ctx_a
      check child.ctx == ctx_a

      Ed.thread_ctx = ctx_b # the wrong context is now active
      child.destroy()
      check child.destroyed
      check "xd_child_items" notin ctx_a # torn down via child.ctx, not thread_ctx

    test "OWNS_MEMBERS: destroying the owner cascades into members":
      var ctx = EdContext.init(id = "om_ctx")
      Ed.thread_ctx = ctx
      var child = OwnerTest(id: "om_child")
      child.own:
        child.items = Ed[seq[int]].init(ctx = ctx, id = "om_child_items")
      var parent = OwnerTest(id: "om_parent")
      parent.own:
        parent.kids = Ed[seq[OwnerTest]].init(
          ctx = ctx, id = "om_kids", flags = DEFAULT_FLAGS + {OWNS_MEMBERS}
        )
      parent.kids.add child # membership -> owned by parent

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
        parent.kids = Ed[seq[OwnerTest]].init(
          ctx = ctx, id = "om2_kids", flags = DEFAULT_FLAGS + {OWNS_MEMBERS}
        )
      parent.kids.add child
      parent.kids -= child # removal un-registers from the owned index

      parent.destroy()
      check not child.destroyed # independently-removed member untouched
