## Regression tests for the wire-decode hardening (see the getenu/flatty fork).
##
## ed decodes flatty off the network, where a peer's bytes are untrusted. The
## length-prefixed decoders (string, seq, table, set) must validate every count
## against the bytes that remain, so a hostile packet is rejected with a
## catchable `FlattyError` instead of over-allocating (OOM) or reading past the
## buffer (SIGSEGV via copyMem, which no `try` catches). These tests pin that:
## normal data still round-trips, and every bomb shape raises.

import std/[unittest, tables, sets]
import pkg/flatty
import pkg/flatty/binny

proc run*() =
  test "flatty round-trips survive the length guard":
    check "hello".toFlatty.fromFlatty(string) == "hello"
    check "".toFlatty.fromFlatty(string) == ""
    check @[1'u8, 2, 3].toFlatty.fromFlatty(seq[uint8]) == @[1'u8, 2, 3]
    check (newSeq[uint8]()).toFlatty.fromFlatty(seq[uint8]).len == 0
    check @["a", "bb"].toFlatty.fromFlatty(seq[string]) == @["a", "bb"]
    var t = {"x": 1, "y": 2}.to_table
    check t.toFlatty.fromFlatty(Table[string, int]) == t
    var hs = [10, 20, 30].to_hash_set
    check hs.toFlatty.fromFlatty(HashSet[int]) == hs

  test "FlattyError is catchable at a trust boundary":
    # A subtype of CatchableError, so existing `except CatchableError` handlers
    # (e.g. parse_remote) catch it -- the whole point of not crashing.
    check FlattyError is CatchableError

  template rejects(name: string, body: untyped) =
    test name:
      var raised = false
      try:
        body
      except FlattyError:
        raised = true
      check raised

  # The critical one: a copyMem seq whose declared length dwarfs the payload.
  # Pre-fix this over-reads the buffer via copyMem -> SIGSEGV (uncatchable).
  rejects "huge seq[uint8] length is rejected":
    var b = ""
    b.addInt64(0x7fff_ffff'i64)
    discard b.fromFlatty(seq[uint8])

  rejects "seq length just past the buffer is rejected":
    var b = ""
    b.addInt64(64'i64)
    b.add("only a handful of bytes")
    discard b.fromFlatty(seq[uint8])

  rejects "huge string length is rejected":
    var b = ""
    b.addInt64(0x7fff_ffff_ffff'i64)
    discard b.fromFlatty(string)

  rejects "huge set element count is rejected":
    var b = ""
    b.addInt64(0x7fff_ffff'i64)
    discard b.fromFlatty(HashSet[int])

  rejects "huge table entry count is rejected":
    var b = ""
    b.addInt64(0x7fff_ffff'i64)
    discard b.fromFlatty(Table[string, int])

  rejects "negative length is rejected":
    var b = ""
    b.addInt64(-1'i64)
    discard b.fromFlatty(seq[uint8])

  rejects "truncated length prefix is rejected":
    discard "\x01\x02\x03".fromFlatty(seq[uint8])

when isMainModule:
  run()
