## Cross-context convergence tests for positional EdSeq ops (`[]=`, indexed
## `del`). Indexes needn't be stable across ticks, but once ops propagate the
## owner and its replica must converge to identical contents *and order* -- the
## same eventual-consistency guarantee the rest of ed gives.
##
## On master these fail: positional ops publish a value-based REMOVED+ADDED diff
## (see process_changes[seq]), so the replica applies remove-by-value + append.
## In-place replacement degrades to reorder, and length can diverge outright.

import std/[unittest, sequtils]
import ed
import ed/zens/contexts

proc run*() =
  template two_contexts(owner, replica, body: untyped) =
    block:
      var
        owner {.inject.} = EdContext.init(id = "owner", blocking_recv = true)
        replica {.inject.} = EdContext.init(id = "replica", blocking_recv = true)
      replica.subscribe(owner)
      Ed.thread_ctx = owner
      owner.tick(blocking = false)
      body
      owner.close
      replica.close

  template sync(owner, replica: untyped) =
    # A couple of round-trips so a mutation and any reverse-leg echo settle.
    # Non-blocking: these are local (cross-thread channel) contexts.
    for _ in 0 .. 2:
      owner.tick(blocking = false)
      replica.tick(blocking = false)

  test "positional assign at index 0 converges":
    two_contexts(owner, replica):
      var
        a = EdSeq[string].init(id = "s", ctx = owner)
        b = EdSeq[string].init(id = "s", ctx = replica)
      a.add "A"
      a.add "B"
      sync(owner, replica)
      check a.value == @["A", "B"]
      check b.value == @["A", "B"]

      a[0] = "A2"
      sync(owner, replica)
      check a.value == @["A2", "B"]
      check b.value == @["A2", "B"] # master: b == @["B", "A2"]

  test "positional assign in the middle converges":
    two_contexts(owner, replica):
      var
        a = EdSeq[string].init(id = "s", ctx = owner)
        b = EdSeq[string].init(id = "s", ctx = replica)
      for x in ["A", "B", "C"]:
        a.add x
      sync(owner, replica)
      a[1] = "B2"
      sync(owner, replica)
      check a.value == @["A", "B2", "C"]
      check b.value == @["A", "B2", "C"]

  test "indexed del converges":
    two_contexts(owner, replica):
      var
        a = EdSeq[string].init(id = "s", ctx = owner)
        b = EdSeq[string].init(id = "s", ctx = replica)
      for x in ["A", "B", "C"]:
        a.add x
      sync(owner, replica)
      a.del(1) # remove "B" by position
      sync(owner, replica)
      check a.value == @["A", "C"]
      check b.value == @["A", "C"]

  test "reported sequence: assign then add then indexed del converges":
    two_contexts(owner, replica):
      var
        a = EdSeq[string].init(id = "s", ctx = owner)
        b = EdSeq[string].init(id = "s", ctx = replica)
      a.add "A"
      a.add "B"
      sync(owner, replica)
      a[0] = "A2"
      a.add "C"
      a.del(2) # remove "C"
      sync(owner, replica)
      check a.value == @["A2", "B"]
      check b.value == @["A2", "B"] # master: length/order diverges
      check a.value.len == b.value.len

  test "indexed del reproduces swap-remove reordering":
    # Nim's `del` is swap-remove: [A,B,C,D].del(1) -> [A,D,C]. The replica must
    # reproduce that exact order, not remove-by-value (which gives [A,C,D]).
    two_contexts(owner, replica):
      var
        a = EdSeq[string].init(id = "s", ctx = owner)
        b = EdSeq[string].init(id = "s", ctx = replica)
      for x in ["A", "B", "C", "D"]:
        a.add x
      sync(owner, replica)
      a.del(1)
      sync(owner, replica)
      check a.value == @["A", "D", "C"]
      check b.value == @["A", "D", "C"]

  test "shift delete preserves order across contexts":
    two_contexts(owner, replica):
      var
        a = EdSeq[string].init(id = "s", ctx = owner)
        b = EdSeq[string].init(id = "s", ctx = replica)
      for x in ["A", "B", "C", "D"]:
        a.add x
      sync(owner, replica)
      a.delete(1) # shift-remove
      sync(owner, replica)
      check a.value == @["A", "C", "D"]
      check b.value == @["A", "C", "D"]

  test "positional assign with duplicate values converges":
    # Value-based diff can't tell which duplicate changed; position can.
    two_contexts(owner, replica):
      var
        a = EdSeq[string].init(id = "s", ctx = owner)
        b = EdSeq[string].init(id = "s", ctx = replica)
      for x in ["X", "Y", "X"]:
        a.add x
      sync(owner, replica)
      a[0] = "Z" # replace the FIRST X
      sync(owner, replica)
      check a.value == @["Z", "Y", "X"]
      check b.value == @["Z", "Y", "X"]

  test "assign at last index converges":
    two_contexts(owner, replica):
      var
        a = EdSeq[string].init(id = "s", ctx = owner)
        b = EdSeq[string].init(id = "s", ctx = replica)
      for x in ["A", "B", "C"]:
        a.add x
      sync(owner, replica)
      a[2] = "C2"
      sync(owner, replica)
      check a.value == @["A", "B", "C2"]
      check b.value == @["A", "B", "C2"]

  test "received CREATE does not clobber materialized local content (ed#28)":
    # Two contexts independently create the same id: owner with content, replica
    # empty. On (bidirectional) subscribe the reverse leg pushes replica's empty
    # CREATE to owner -- which must NOT reset owner's contents. (An empty seq
    # serializes to a non-empty `bin`, so this is a content-bearing CREATE.)
    var
      owner = EdContext.init(id = "owner", blocking_recv = true)
      replica = EdContext.init(id = "replica", blocking_recv = true)
    var a = EdSeq[string].init(@["A", "B"], id = "s", ctx = owner)
    var b {.used.} = EdSeq[string].init(id = "s", ctx = replica)
    replica.subscribe(owner)
    for _ in 0 .. 2:
      owner.tick(blocking = false)
      replica.tick(blocking = false)
    check a.value == @["A", "B"] # owner's content survives replica's empty create
    owner.close
    replica.close

  test "same-id handle: mutate before creates converge still converges":
    # The realistic pattern (Enu shares an EdSeq handle): create the same empty
    # id in both contexts, mutate one *before* the creates have synced. Must
    # converge, not clobber. (Pre-#28-fix this lost the owner's content.)
    two_contexts(owner, replica):
      var
        a = EdSeq[string].init(id = "s", ctx = owner)
        b = EdSeq[string].init(id = "s", ctx = replica)
      a.add "A"
      a.add "B"
      sync(owner, replica)
      check a.value == @["A", "B"]
      check b.value == @["A", "B"]

when isMainModule:
  run()
