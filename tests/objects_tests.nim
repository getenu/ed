import std/[unittest, macros, tables, strutils, rationals, complex, atomics]
import ed
import ./objects_tests_types

# A context of our own: one left by an earlier test may have a subscriber
# nobody ticks, and creating a gadget's fields would fill its channel.
let objects_ctx = EdContext.init(id = "objects_tests")

proc gadget(): Gadget =
  Ed.thread_ctx = objects_ctx
  Gadget.init(ed_ctx = objects_ctx)

proc run*() =
  test "{.ed.} fields become Ed fields; ignored ones stay plain":
    let g = gadget()
    check g.size_value is Ed[float]
    check g.xform_value is Ed[Xform]
    check g.parts is Ed[seq[int]]
    check g.cache is string
    check g.cache.has_custom_pragma(ed_ignore)

  test "accessors read and write plain values":
    let g = gadget()
    g.size = 2.5
    let old = g.size
    g.size = 4
    check old == 2.5
    check g.size == 4.0
    check g.size is float

  test "changes watches a field by its own name":
    let g = gadget()
    var seen: seq[float]
    g.size.changes:
      if added:
        seen.add change.item
    g.size = 3
    g.size += 1
    check seen == @[3.0, 4.0]

  test "compound assignment writes back":
    let g = gadget()
    g.size = 1
    g.size += 2
    g.size -= 0.5
    g.size *= 2
    g.count += 3
    g.label = "bob"
    g.label &= "!"
    check g.size == 5.0
    check g.count == 3
    check g.label == "bob!"

  test "compound assignment on part of a field is one write":
    let g = gadget()
    var writes = 0
    g.xform.changes:
      if added:
        inc writes
    g.xform.origin.x += 3
    g.xform.origin.y -= 1
    check g.xform.origin.x == 3.0
    check g.xform.origin.y == -1.0
    check writes == 2

  test ":= writes a part of a field, or the whole field":
    let g = gadget()
    g.xform.origin.x := 5
    g.xform.scale := 2
    g.size := 7
    check g.xform.origin.x == 5.0
    check g.xform.scale == 2.0
    check g.size == 7.0

  test "edit changes several parts in one write":
    let g = gadget()
    var writes = 0
    g.xform.changes:
      if added:
        inc writes
    edit g.xform:
      origin.x = 10
      origin.y = 20
      scale = 3
    check g.xform == Xform(origin: Vec(x: 10, y: 20), scale: 3)
    check writes == 1

  test "edit works on a value Ed too":
    let g = gadget()
    edit g.xform_value:
      scale = 4
    check g.xform.scale == 4.0

  test "plain variables and Ed containers keep their own +=":
    Ed.thread_ctx = objects_ctx
    var f = 1.0
    f += 2
    var s = "a"
    s &= "b"
    let g = gadget()
    g.parts += 7
    check f == 3.0
    check s == "ab"
    check g.parts.value == @[7]

  test "with nothing synced, += is Nim's own error":
    let n = 1
    check not compiles(n += 1)
    check not compiles((let x = 1.0; x := 2.0))

  test "edit leaves locals and calls alone":
    let g = gadget()
    var notes: seq[string]
    edit g.xform:
      var step = 2.0
      step += 1
      scale = step
      notes.add "set scale"
    check g.xform.scale == 3.0
    check notes == @["set scale"]

  test "field pragmas set the Ed's flags":
    let g = gadget()
    check g.size_value.flags == {SYNC_LOCAL, SYNC_REMOTE}
    check g.note_value.flags == {SYNC_LOCAL}
    check g.beacon_value.flags == {SYNC_REMOTE}
    check g.scratch_value.flags == {}
    check g.gadgets.flags == {SYNC_LOCAL, SYNC_REMOTE, OWNS_MEMBERS}
    check g.pos_value.flags == {SYNC_LOCAL, SYNC_REMOTE, REJECT_STALE}

  test "an unsynced field is still an Ed: watched, +=, :=":
    let g = gadget()
    var seen = 0
    g.scratch.changes:
      if added:
        inc seen
    g.scratch += 2
    g.scratch := 5
    check g.scratch == 5
    check seen == 2

  test "init_ed_fields leaves a field that already exists":
    Ed.thread_ctx = objects_ctx
    var g = Gadget()
    g.size_value = Ed[float].init(flags = {SYNC_LOCAL}, ctx = objects_ctx)
    g.init_ed_fields(ctx = objects_ctx)
    check g.size_value.flags == {SYNC_LOCAL}
    check g.count_value.flags == {SYNC_LOCAL, SYNC_REMOTE}

  test "plain fields stay on their own side, at creation and after":
    var ctx1 = EdContext.init(id = "plain_sender")
    var ctx2 = EdContext.init(id = "plain_receiver")
    ctx2.subscribe(ctx1)
    Ed.thread_ctx = ctx1
    proc settle() =
      for _ in 0 ..< 5:
        ctx1.tick(blocking = false)
        ctx2.tick(blocking = false)
    settle()

    var src = Ed[seq[Widget]].init(ctx = ctx1)
    var w = Widget(id: "plain_widget", note: "the sender's").init_ed_fields(ctx = ctx1)
    w.name = "bob"
    src += w
    settle()

    let copy = Ed[seq[Widget]](ctx2[src])[0]
    check copy.note == ""             # not sent
    check copy.name_value.value == "bob" # the Ed field is
    copy.note = "the receiver's"

    # the same object arriving again inside another value (as opening enu's
    # editor sends a build) leaves the receiver's plain field alone
    var holder = Ed[Widget].init(ctx = ctx1)
    holder.value = w
    settle()
    check copy.note == "the receiver's"
    Ed.thread_ctx = objects_ctx

  test "paths can index into a field's value":
    let g = gadget()
    g.grid = Grid(cells: @[1, 2, 3], rows: @[Vec(), Vec()], names: {"a": 1}.to_table)
    var writes = 0
    g.grid.changes:
      if added:
        inc writes
    var calls = 0
    proc second(): int =
      inc calls
      1
    g.grid.cells[second()] += 10
    g.grid.rows[1].x := 4
    g.grid.names["a"] += 1
    edit g.grid:
      cells[0] = 7
      rows[0].y = 2
    check g.grid.cells == @[7, 12, 3]
    check g.grid.rows == @[Vec(x: 0, y: 2), Vec(x: 4, y: 0)]
    check g.grid.names["a"] == 2
    check calls == 1
    check writes == 4
    Ed.thread_ctx = objects_ctx

  test "ed picks the container kind from the value":
    Ed.thread_ctx = objects_ctx
    check ed(1.5) is Ed[float]
    check ed(@[1, 2]) is Ed[seq[int]]
    check ed({'a', 'b'}) is Ed[set[char]]
    check ed({"a": 1}.to_table) is Ed[Table[string, int]]
    let local = ed(3, flags = {SYNC_LOCAL}, id = "ed_kind_local")
    check local.flags == {SYNC_LOCAL}
    check local.id == "ed_kind_local"
    check local.value == 3
    check not compiles(Ed.init(int))

  test "generated constructors":
    Ed.thread_ctx = objects_ctx
    let g = Gadget.init(id = "gadget_ctor", label = "bob", parts = @[1, 2])
    check g.id == "gadget_ctor"
    check g.size == 1.5                     # the declared default
    check g.label == "bob"
    check g.parts.value == @[1, 2]
    check g.note_value.flags == {SYNC_LOCAL} # declared flags
    check g.cache == ""
    check Gadget.init.id.starts_with("gadget_")

    let o = Gadget.init(ed_flags = (size: {SYNC_LOCAL}))
    check o.size_value.flags == {SYNC_LOCAL}
    check o.count_value.flags == {SYNC_LOCAL, SYNC_REMOTE}
    check not compiles(Gadget.init(ed_flags = (sise: {SYNC_LOCAL})))

    # base fields first, so the first few can be positional
    let p = Gadget.init("gadget_positional", 2.5, 3)
    check p.size == 2.5
    check p.count == 3

  test "constructor = false: a hand-written init calls Ed.init":
    Ed.thread_ctx = objects_ctx
    let d = Derived.init(level = 2)
    check d.level == 20
    check d.name == "base"
    check d.marks.value == @[1]
    check d.marks.flags == {SYNC_LOCAL}
    check d.id.starts_with("derived_")
    let parent = Ed.init(Derived)
    check Ed.init(Derived, owner = parent).owner == parent

  test "{.id: ...} gives a field a fixed id":
    Ed.thread_ctx = objects_ctx
    let s = Settings.init(id = "settings_one", level_name = "town")
    check s.level_name_value.id == "settings_level_name"
    check s.level_name_value.flags == {SYNC_LOCAL}
    check s.level_name == "town"
    check s.parts.id == "settings_one:parts"
    check s.scale_value.id != ""
    check s.scale_value.id != "settings_one:parts"
    let h = Settings(id: "settings_hand").init_ed_fields(ctx = objects_ctx)
    check h.parts.id == "settings_hand:parts"
    check h.level_name_value.flags == {SYNC_LOCAL}

  test "init_ed_fields creates fields with their declared defaults":
    Ed.thread_ctx = objects_ctx
    let d = Defaults().init_ed_fields(ctx = objects_ctx)
    check d.xform.scale == 2.0
    check d.code == -1
    check d.names.value == @["a"]
    check d.plain == 7
    let c = Defaults.init
    check c.plain == 7
    check c.code == -1

  test "init_ed_fields on an object that isn't an EdRef":
    Ed.thread_ctx = objects_ctx
    let r = Root().init_ed_fields(ctx = objects_ctx)
    check r.things.id == "root_tests_things"
    check r.count_value.value == 3

  test "Ed[T] is the container for a T, whatever its kind":
    Ed.thread_ctx = objects_ctx
    check ed(3) is Ed[int]
    check ed(@[1]) is Ed[seq[int]]
    check ed({'a'}) is Ed[set[char]]
    check ed({"a": 1}.to_table) is Ed[Table[string, int]]
    check Ed.init(Vec(x: 1)) is Ed[Vec]
    let names: Ed[seq[string]] = Ed.init(@["a"])
    let more = Ed[seq[string]].init(@["b", "c"])
    check names.value == @["a"]
    check more.len == 2
    # Generic code infers through Ed[...], and a bare `Ed` takes any kind.
    proc total[X](items: Ed[seq[X]]): X =
      for item in items:
        result += item
    proc id_of(x: Ed): string =
      x.id
    check total(ed(@[1, 2, 3])) == 6
    check total(ed(@[1.5, 2.5])) == 4.0
    check id_of(more) == more.id and id_of(ed(1)) != ""
    var keys: seq[string]
    let table = Ed[Table[string, int]].init
    table.changes:
      if added:
        keys.add change.item.key
    table["x"] = 1
    check keys == @["x"]
    # What each kind holds, for naming it in generic code.
    check int.item_type is int
    check seq[string].item_type is string
    check set[char].item_type is char
    check Table[string, int].item_type is Pair[string, int]
    proc first[T](x: Ed[T]): T.item_type =
      for item in x:
        return item
    check first(ed(@["a", "b"])) == "a"

  test "+= on synced fields sits beside other libraries' +=":
    var r = 1 // 2
    r += 1 // 2
    var c = complex(1.0, 2.0)
    c += complex(1.0, 1.0)
    var a: Atomic[int]
    a += 3
    var i = 1
    i += 2
    check r == 1 // 1
    check c == complex(2.0, 3.0)
    check a.load == 3
    check i == 3
