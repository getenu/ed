import
  std/[
    tables, sequtils, sugar, macros, typetraits, sets, isolation, unittest,
    deques, importutils, monotimes, os
  ]
import pkg/[pretty, chronicles, netty]
import ed
import test_util
from std/times import init_duration
import ed/[types {.all.}, zens {.all.}, zens/contexts {.all.}]

import ed/components/type_registry

type Vector3 = array[3, float]

proc run*() =
  var change_count = 0
  proc count_changes(obj: auto): EID {.discardable.} =
    obj.changes:
      change_count += 1

  template changes(expected_count: int, body) =
    change_count = 0
    body
    if change_count != expected_count:
      echo ast_to_str(body)
      echo "Expected ", expected_count, " changes. Got ", change_count

  template assert_changes[T, O](self: Ed[T, O], expect, body: untyped) =
    var expectations = expect.to_deque
    self.track proc(changes: seq[Change[O]]) {.gcsafe.} =
      for change in changes:
        let expectation = expectations.pop_first()
        if not (
          expectation[0] in change.changes and expectation[1] == change.item
        ):
          error "unsatisfied expectation", expectation
    body
    if expectations.len > 0:
      echo "unsatisfied expectations: ", expectations
      check false

  template local(body) =
    block local:
      debug "local run"
      var
        ctx1 {.inject.} = EdContext.init(id = "ctx1", blocking_recv = true)
        ctx2 {.inject.} = EdContext.init(id = "ctx2", blocking_recv = true)

      ctx2.subscribe(ctx1)
      Ed.thread_ctx = ctx1
      ctx1.tick(blocking = false)

      body

  template remote(body) =
    block remote:
      debug "remote run"
      const recv_duration = init_duration(milliseconds = 10)
      let host = free_addr()
      var
        ctx1 {.inject.} = EdContext.init(
          id = "ctx1",
          listen_address = host,
          min_recv_duration = recv_duration,
          blocking_recv = true,
        )

        ctx2 {.inject.} = EdContext.init(
          id = "ctx2", min_recv_duration = recv_duration, blocking_recv = true
        )

      ctx2.subscribe host,
        callback = proc() =
          ctx1.tick(blocking = false)

      Ed.thread_ctx = ctx1
      ctx1.tick(blocking = false)

      body

      ctx1.close
      ctx2.close

  template local_and_remote(body) =
    local(body)
    remote(body)

  test "sets":
    type TestFlags = enum
      Flag1
      Flag2
      Flag3
      Flag4

    var s = Ed.init({Flag1, Flag2})

    check:
      Flag2 in s
      Flag2 in s
      Flag3 notin s
      Flag4 notin s
      {Flag1} in s
      {Flag1, Flag2} in s
      {Flag1, Flag2, Flag3} notin s

    var added {.threadvar.}: set[TestFlags]
    var removed {.threadvar.}: set[TestFlags]

    let zid = s.track proc(changes, zid: auto) {.gcsafe.} =
      added = {}
      removed = {}
      for c in changes:
        if ADDED in c.changes:
          added.incl(c.item)
        elif REMOVED in c.changes:
          removed.incl(c.item)

    s += Flag3
    check:
      added == {Flag3}
      removed == {}
      s.value == {Flag1, Flag2, Flag3}

    s -= {Flag1, Flag2}
    check:
      added == {}
      removed == {Flag1, Flag2}
      s.value == {Flag3}

    s.value = {Flag4, Flag1}
    check:
      added == {Flag1, Flag4}
      removed == {Flag3}

    var also_added: set[TestFlags]
    var also_removed: set[TestFlags]
    s.track proc(changes, zid: auto) {.gcsafe.} =
      also_added = {}
      also_removed = {}
      for c in changes:
        if ADDED in c.changes:
          also_added.incl(c.item)
        elif REMOVED in c.changes:
          also_removed.incl(c.item)

    s.untrack(zid)
    s.value = {Flag2, Flag3}
    check:
      added == {}
      removed == {}
      s.value == {Flag2, Flag3}
      also_added == {Flag2, Flag3}
      also_removed == {Flag1, Flag4}
    s.clear()
    check also_removed == {Flag2, Flag3}

  test "seqs":
    var
      s = EdSeq[string].init
      added_items {.threadvar.}: seq[string]
      removed_items {.threadvar.}: seq[string]

    var id = s.track proc(changes: auto) {.gcsafe.} =
      added_items.add changes.filter_it(ADDED in it.changes).map_it it.item
      removed_items.add changes.filter_it(REMOVED in it.changes).map_it it.item
    s.add "hello"
    s.add "world"

    check added_items == @["hello", "world"]
    s -= "world"
    check removed_items == @["world"]
    removed_items = @[]
    s.clear()
    check removed_items == @["hello"]
    s.untrack(id)

    id = s.count_changes
    1.changes:
      s += "hello"
    check s.len == 1
    1.changes:
      s.del(0)
    check s.len == 0

  test "set literal":
    type TestFlags = enum
      Flag1
      Flag2
      Flag3

    var a = Ed.init({Flag1, Flag3})

  test "table literals":
    var a = EdTable[int, EdSeq[string]].init
    a.track proc(changes, _: auto) {.gcsafe.} =
      discard
    a[1] = EdSeq[string].init(@["nim"])
    a[5] = EdSeq[string].init(@["vin", "rw"])
    a.clear

  test "touch table":
    var a = EdTable[string, string].init
    let zid = a.count_changes

    1.changes:
      a["hello"] = "world"
    0.changes:
      a["hello"] = "world"
    1.changes:
      a.touch("hello", "world")
    a.untrack_all

  test "primitive_table":
    var a = EdTable[int, int].init
    a[1] = 2

  test "nested":
    var a = EdTable[int, EdSeq[int]].init
    a[1] = EdSeq[int].init(@[1, 2])
    a[1] += 3

  test "nested_2":
    var a = EdTable[int, EdSeq[int]].init({1: EdSeq[int].init(@[1])}.to_table)
    a[1] = EdSeq[int].init(@[1, 2])
    a[1] += 3

  test "nested_changes":
    let flags = {TRACK_CHILDREN, SYNC_LOCAL, SYNC_REMOTE}
    type Flags = enum
      Flag1
      Flag2

    let innerSeq = EdSeq[EdSet[Flags]].init(
      @[EdSet[Flags].init({Flag1}, flags = flags), EdSet[Flags].init({Flag2}, flags = flags)],
      flags = flags
    )
    let innerTable = EdTable[int, EdSeq[EdSet[Flags]]].init(
      {1: innerSeq}.to_table,
      flags = flags
    )
    let buffers = EdTable[int, EdTable[int, EdSeq[EdSet[Flags]]]].init(
      {1: innerTable}.to_table,
      flags = flags
    )
    var id = buffers.count_changes

    # we're watching the top level object. Any child change will
    # come through as a single Modified change on the top level child,
    # regardless of how deep it is or how much actually changed

    1.changes:
      buffers[1][1][0] += Flag2
    0.changes:
      buffers[1][1][0] += Flag1
      # already there. No change
    1.changes:
      buffers[1][1][0] -= {Flag1, Flag2}
    1.changes:
      buffers[1][1] += EdSet[Flags].init({Flag1, Flag2}, flags = flags)
    1.changes:
      buffers[1][1] = EdSeq[EdSet[Flags]].init(@[EdSet[Flags].init({Flag1}, flags = flags)], flags = flags)

    # unlink
    buffers[1][1][0].clear
    let child = buffers[1][1][0]
    buffers[1][1].del 0
    0.changes:
      child += Flag1
    buffers[1][1] += child
    1.changes:
      child += Flag2

    2.changes:
      buffers[1] = nil
      # Added and Removed changes
    buffers.untrack(id)

    let newInnerSeq = EdSeq[EdSet[Flags]].init(
      @[EdSet[Flags].init({Flag1}, flags = flags)],
      flags = flags
    )
    let newInnerTable = EdTable[int, EdSeq[EdSet[Flags]]].init(
      {1: newInnerSeq}.to_table,
      flags = flags
    )
    buffers[1] = newInnerTable
    id = buffers[1][1][0].count_changes
    1.changes:
      buffers[1][1][0] += {Flag1, Flag2}
    0.changes:
      buffers[1][1][0] += {Flag1, Flag2}
    2.changes:
      buffers[1][1][0] -= {Flag1, Flag2}
    1.changes:
      buffers[1][1][0].touch Flag1
    0.changes:
      buffers[1][1][0] += Flag1
    1.changes:
      buffers[1][1][0].touch Flag1
    2.changes:
      buffers[1][1][0].touch {Flag1, Flag2}
    2.changes:
      buffers[1][1][0].touch {Flag1, Flag2}

    buffers[1][1][0].untrack(id)

    var changed = false
    id = buffers.track proc(changes, _: auto) {.gcsafe.} =
      if not changed:
        changed = true
        check changes.len == 2
        check changes[0].changes == {REMOVED, MODIFIED}
        check not changes[0].item.value.is_nil
        check changes[1].changes == {ADDED, MODIFIED}
        check changes[1].item.value.is_nil
    buffers[1] = nil
    check changed
    buffers.untrack(id)

    buffers.count_changes
    1.changes:
      buffers.del(1)
    check 1 notin buffers

  test "comparable aliases":
    var a = EdTable[int, string].init(id = "1")
    var b = Ed[Table[int, string], Pair[int, string]].init(id = "1")
    var c = EdTable[string, int].init(id = "2")
    check b is EdTable[int, string]
    check a == b
    when compiles(a == c):
      check false, &"{a.type} and {b.type} shouldn't be comparable"

  test "init from type":
    type TestFlag = enum
      Flag1
      Flag2

    var a = EdSeq[int].init
    var b = EdSet[TestFlag].init
    check:
      a is Ed[seq[int], int]
      b is Ed[set[TestFlag], TestFlag]

  test "nested_triggers":
    type
      UnitFlags = enum
        Targeted
        Highlighted

      Unit = ref object of RootRef
        id: int
        parent: Unit
        units: Ed[seq[Unit], Unit]
        flags: EdSet[UnitFlags]

    proc init(
        _: type Unit, id = 0, flags = {TRACK_CHILDREN, SYNC_LOCAL, SYNC_REMOTE}
    ): Unit =
      result = Unit(id: id)
      result.units = EdSeq[Unit].init(flags = flags)
      result.flags = EdSet[UnitFlags].init(flags = flags)

    var a = Unit.init
    var id = a.units.count_changes
    var b = Unit.init
    1.changes:
      a.units.add b
    var c = Unit.init
    1.changes:
      b.units.add c
    a.units.untrack(id)

    var triggered_by {.threadvar.}: seq[seq[BaseChange]]
    a.units.track proc(changes: auto) {.gcsafe.} =
      triggered_by = @[]
      for change in changes:
        triggered_by.add change.triggered_by

    let d = Unit.init(id = 222)
    c.units.add d
    check triggered_by[0][0].triggered_by[0] of Change[Unit]
    check triggered_by[0][0].triggered_by_type == "Unit"
    let x = Change[Unit](triggered_by[0][0].triggered_by[0])
    check x.item.id == 222
    d.flags += Targeted
    let trigger = triggered_by[0][0].triggered_by[0].triggered_by[0]
    check trigger of Change[UnitFlags]
    let f = Change[UnitFlags](trigger)
    check ADDED in f.changes
    check f.item == Targeted

    # without child tracking:
    a = Unit.init(flags = {SYNC_LOCAL, SYNC_REMOTE})
    id = a.units.count_changes
    b = Unit.init
    1.changes:
      a.units.add b
    c = Unit.init
    0.changes:
      b.units.add c
    a.units.untrack(id)

  test "primitives":
    let a = EdValue[int].init
    a.assert_changes {
      REMOVED: 0,
      ADDED: 5,
      REMOVED: 5,
      ADDED: 10,
      TOUCHED: 10,
      REMOVED: 10,
      TOUCHED: 11,
      REMOVED: 11,
      ADDED: 12
    }:
      a.value = 5
      a.value = 10
      a.touch 10
      a.touch 11
      a.touch 12

    let b = ed(4)
    b.assert_changes {REMOVED: 4, ADDED: 11}:
      b.value = 11

    let c = ed("enu")
    c.assert_changes {REMOVED: "enu", ADDED: "ENU"}:
      c.value = "ENU"

  test "refs":
    type ARef = ref object of RootObj
      id: int

    let (r1, r2, r3) = (ARef(id: 1), ARef(id: 2), ARef(id: 3))

    let a = ed(r1)
    a.assert_changes {REMOVED: r1, ADDED: r2, REMOVED: r2, ADDED: r3}:
      a.value = r2
      a.value = r3

  test "pausing":
    var s = EdValue[string].init
    let zid = s.count_changes
    2.changes:
      s.value = "one"
    s.pause zid:
      0.changes:
        s.value = "two"
    2.changes:
      s.value = "three"
    let zids = @[zid, 1234]
    s.pause zids:
      0.changes:
        s.value = "four"
    2.changes:
      s.value = "five"
    s.pause zid, 1234:
      0.changes:
        s.value = "six"
    2.changes:
      s.value = "seven"
    s.pause:
      0.changes:
        s.value = "eight"
    2.changes:
      s.value = "nine"

    var calls = 0
    s.changes:
      calls += 1
      s.value = "cal"

    s.value = "vin"
    check calls == 2

  test "closed":
    var s = ed("")
    var changed = false

    s.track proc(changes: auto) {.gcsafe.} =
      changed = true
      check changes[0].changes == {CLOSED}
    s.untrack_all
    check changed == true

    changed = false
    let zid = s.track proc(changes: auto) {.gcsafe.} =
      changed = true
      check changes[0].changes == {CLOSED}
    Ed.thread_ctx.untrack(zid)
    check changed == true

  test "init_props":
    type Model = ref object
      list: EdSeq[int]
      field: string
      ed_field: EdValue[string]

    proc init(_: type Model): Model =
      result = Model()
      result.init_ed_fields

    let m = Model.init
    m.ed_field.value = "test"
    check m.ed_field.value == "test"

  test "sync":
    type
      Thing = ref object of EdRef

      Tree = ref object
        zen: EdValue[string]
        things: EdSeq[Thing]
        values: EdSeq[EdValue[string]]

      Container = ref object
        thing1: EdValue[Thing]
        thing2: EdValue[Thing]

    Ed.register(Thing, false)

    local_and_remote:
      var s1 = EdValue[string].init(ctx = ctx1)
      ctx2.tick
      var s2 = EdValue[string](ctx2[s1])
      check s2.ctx != nil

      s1.value = "sync me"
      ctx2.tick

      check s2.value == s1.value

      s1 &= " and me"
      ctx2.tick

      check s2.value == s1.value and s2.value == "sync me and me"

      var msg = "hello world"
      var another_msg = "another"
      var src = Tree().init_ed_fields(ctx = ctx1)
      ctx2.tick
      var dest = Tree.init_from(src, ctx = ctx2)

      src.zen.value = "hello world"
      ctx2.tick
      check src.zen.value == "hello world"
      check dest.zen.value == "hello world"

      let thing = Thing(id: "Vin")
      src.things += thing
      ctx2.tick
      check dest.things.len == 1
      check dest.things[0] != nil
      check dest.things[0].id == "Vin"

      src.things -= thing
      check src.things.len == 0

      ctx2.tick

      check dest.things.len == 0

      var container = Container().init_ed_fields(ctx = ctx1)

      var t = Thing(id: "Scott")
      ctx2.tick
      var remote_container = Container.init_from(container, ctx = ctx2)
      container.thing1.value = t
      container.thing2.value = t

      check container.thing1.value == container.thing2.value

      sleep(100)
      ctx2.tick

      check remote_container.thing1.value.id == container.thing1.value.id
      check remote_container.thing1.value == remote_container.thing2.value
      var s3 = EdValue[string].init(ctx = ctx1)
      src.values += s3
      s3.value = "hi"
      ctx2.tick
      check dest.values[^1].value == "hi"

      var ctx3 = EdContext.init(id = "ctx3")
      Ed.thread_ctx = ctx3
      ctx3.subscribe(ctx2, bidirectional = false)
      Ed.thread_ctx = ctx1
      check ctx3.len == ctx1.len
      src.values += Ed.init("", ctx = ctx1)
      check ctx1.len != ctx2.len and ctx1.len != ctx3.len
      ctx2.tick
      check ctx1.len == ctx2.len and ctx1.len != ctx3.len
      Ed.thread_ctx = ctx3
      ctx3.tick
      Ed.thread_ctx = ctx1
      check ctx1.len == ctx2.len and ctx1.len == ctx3.len

  test "delete":
    local_and_remote:
      var a = Ed.init("", ctx = ctx1)
      check ctx1.len == 1
      ctx2.tick
      check ctx1.len == 1
      check ctx2.len == 1

      a.destroy
      check ctx1.len == 0
      ctx2.tick
      check ctx1.len == 0
      check ctx2.len == 0

  test "sync nested":
    type Unit = ref object of EdRef
      units: EdSeq[Unit]
      code: EdValue[string]

    Ed.register(Unit, false)
    local_and_remote:
      var u1 = Unit(id: "1")
      var u2 = Unit(id: "2")
      u1.init_ed_fields
      u2.init_ed_fields
      ctx2.tick

      var ru1 = Unit.init_from(u1, ctx = ctx2)

      u1.units += u2
      ctx2.tick
      check ru1.units[0].code.ctx == ctx2

  test "zentable of tables":
    type Shared = ref object of EdRef
      edits: EdTable[int, Table[string, string]]

    Ed.register(Shared, false)

    local_and_remote:
      var container: EdValue[Shared]
      container.init

      var shared = Shared(id: "1")
      shared.init_ed_fields

      container.value = shared
      container.value.edits[1] = {"1": "one", "2": "two"}.to_table
      ctx2.tick

      var dest = type(container)(ctx2[container])
      check 1 in dest.value.edits
      check dest.value.edits[1].len == 2
      check dest.value.edits[1]["2"] == "two"

      container.value.edits +=
        {2: {"3": "three"}.to_table, 3: {"4": "four"}.to_table}.to_table

      ctx2.tick
      check dest.value.edits.len == 3
      check dest.value.edits[3]["4"] == "four"

  test "zentable of zentables":
    type Block = ref object of RootObj
      id: string
      chunks: EdTable[int, EdTable[string, string]]

    local_and_remote:
      var container: EdValue[Block]
      container.init

      var shared = Block(id: "2")
      shared.init_ed_fields

      ctx2.tick
      var shared2 = Block.init_from(shared, ctx = ctx2)

      shared.chunks[1] = EdTable[string, string].init
      shared.chunks[1]["hello"] = "world"
      Ed.thread_ctx = ctx2
      ctx2.tick

      check addr(shared.chunks[]) != addr(shared2.chunks[])
      check shared2.chunks[1]["hello"] == "world"

      shared2.chunks[1]["hello"] = "goodbye"
      Ed.thread_ctx = ctx1
      ctx1.tick

      check shared.chunks[1]["hello"] == "goodbye"

  test "refs freed when unreferenced":
    # New lifecycle contract (replaces the old 10s-grace "free refs" test). A
    # container REMOVE only unlinks — it never schedules a free. A registered
    # ref's body persists while anything still holds it, so a remove-then-readd
    # re-links the *same* instance for any gap (move-identity, no timer). The
    # body is freed only when its last real reference drops: ORC reclaims it and
    # its RefHandle.=destroy clears the ref_pool entry. The registered type must
    # inherit EdRef to carry that handle. See docs/step4-body-protocol-sketch.md.
    type RefType = ref object of EdRef

    Ed.register(RefType, false)

    local_and_remote:
      var src = EdSeq[RefType].init
      var obj = RefType(id: "1")
      let id = obj.ref_id

      src += obj
      ctx2.tick
      var dest = EdSeq[RefType](ctx2[src])

      private_access EdContext
      private_access CountedRef

      check id in ctx1.ref_pool
      check id in ctx2.ref_pool

      # Hold the dest-side instance so it can't be reclaimed across the remove.
      var orig = RefType(ctx2.ref_pool[id].obj)

      # REMOVE unlinks only: the body persists (still held by `orig`), the
      # reachability count drops to zero, and nothing is scheduled for free.
      src -= obj
      ctx2.tick
      check dest.len == 0
      check id in ctx2.ref_pool

      # Re-add across the gap re-links the very same instance — move-identity with
      # no grace window (strictly better than the 10s timer it replaces).
      src += obj
      ctx2.tick
      check dest.len == 1
      check dest[0] == orig

      # Drop every reference to the dest-side body: unlink it from the container
      # and release the local handle. ORC reclaims it and its RefHandle records
      # the id for the context to prune (the destructor never touches ref_pool) —
      # freed exactly when unreferenced, no timer.
      src -= obj
      ctx2.tick
      check dest.len == 0
      orig = nil
      ctx2.prune_dead_refs()
      check id notin ctx2.ref_pool

      # So a later re-add can only materialize a fresh instance.
      src += obj
      ctx2.tick
      check dest.len == 1
      check dest[0].id == "1"
      check id in ctx2.ref_pool

  test "sync set":
    type Flags = enum
      One
      Two
      Three

    local_and_remote:
      let msg = "hello world"
      var src = EdSet[Flags].init
      ctx2.tick
      var dest = EdSet[Flags](ctx2[src])
      src += One
      ctx2.tick
      check dest.value == {One}
      dest += Two
      ctx1.tick
      check src.value == {One, Two}

  test "seq of tuples":
    local_and_remote:
      let val = ("hello", 1)
      let z = EdSeq[val.type].init
      ctx2.tick
      z += val
      ctx2.tick
      z += val
      ctx2.tick
      let z2 = ctx2[z]
      check z2.len == 2

  test "pointer to ref":
    type RefType = ref object of RootObj
      id: string

    local_and_remote:
      let a = RefType(id: "a")
      var src = EdValue[ptr RefType].init

      ctx2.tick
      var dest = EdValue[ptr RefType](ctx2[src])

      src.value = unsafe_addr(a)
      ctx2.tick

      check dest.value[].id == "a"

  test "object with registered ref":
    type
      RefType2 = ref object of EdRef

      RefType3 = ref object of RefType2

      Query = object
        target: RefType2
        other: string

    Ed.register(RefType3, false)

    local_and_remote:
      let a = Query(target: RefType3(id: "b"), other: "hello")
      var src = EdValue[Query].init

      ctx2.tick
      var dest = EdValue[Query](ctx2[src])

      src.value = a
      ctx2.tick

      check:
        src.value.target.id == dest.value.target.id
        src.value.other == dest.value.other
        src.value.target != dest.value.target

  test "triggered by sync":
    type
      UnitFlags = enum
        Targeted
        Highlighted

      SyncUnit = ref object of EdRef
        parent: SyncUnit
        units: EdSeq[SyncUnit]

      State = ref object
        units: EdSeq[SyncUnit]
        active: SyncUnit

    Ed.register(SyncUnit, false)

    local_and_remote:
      let flags = {TRACK_CHILDREN, SYNC_LOCAL, SYNC_REMOTE}
      var src = State().init_ed_fields(flags = flags)

      ctx2.tick
      var dest = State.init_from(src, ctx = ctx2)
      var src_change_id = ""
      var dest_change_id = ""

      src.units.changes:
        var change = change
        while change.triggered_by.len > 0:
          change = Change[SyncUnit](change.triggered_by[0])
        src_change_id = change.item.id

      dest.units.changes:
        var change = change
        while change.triggered_by.len > 0:
          change = Change[SyncUnit](change.triggered_by[0])
        dest_change_id = change.item.id

      let base = SyncUnit(id: "1").init_ed_fields(flags = flags)
      src.units.add base
      ctx2.tick

      let child = SyncUnit(id: "3").init_ed_fields(flags = flags)
      ctx2.tick
      src_change_id = ""
      dest_change_id = ""
      base.units.add child

      ctx2.tick
      check src_change_id == "3"
      check dest_change_id == "3"

      Ed.thread_ctx = ctx2
      let grandchild =
        SyncUnit(id: "4").init_ed_fields(ctx = ctx2, flags = flags)

      dest.units[0].units.add grandchild

      ctx1.tick
      check src_change_id == "4"
      check dest_change_id == "4"

when is_main_module:
  Ed.bootstrap
  run()
