import std/[unittest, macros]
import ed
import ./objects_tests_types

# A context of our own: one left by an earlier test may have a subscriber
# nobody ticks, and creating a gadget's fields would fill its channel.
let objects_ctx = EdContext.init(id = "objects_tests")

proc gadget(): Gadget =
  Ed.thread_ctx = objects_ctx
  Gadget().init_ed_fields(ctx = objects_ctx)

proc run*() =
  test "{.ed.} fields become Ed fields; ignored ones stay plain":
    let g = gadget()
    check g.size_value is EdValue[float]
    check g.xform_value is EdValue[Xform]
    check g.parts is EdSeq[int]
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

  test "edit works on an EdValue too":
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
    g.size_value = EdValue[float].init(flags = {SYNC_LOCAL}, ctx = objects_ctx)
    g.init_ed_fields(ctx = objects_ctx)
    check g.size_value.flags == {SYNC_LOCAL}
    check g.count_value.flags == {SYNC_LOCAL, SYNC_REMOTE}
