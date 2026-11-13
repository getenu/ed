import std/[unittest, sets]
import ed
import ed/zens/contexts

proc settle(ctxs: varargs[EdContext]) =
  for _ in 1 .. 4:
    for ctx in ctxs:
      ctx.tick()

proc run*() =
  suite "lsn leader stamping":
    test "authority is designated via init":
      var leader = EdContext.init(id = "lsn_leader", is_authority = true)
      var follower = EdContext.init(id = "lsn_follower")
      check leader.is_authority
      check leader.leader_id == "lsn_leader"
      check not follower.is_authority
      check follower.leader_id == ""

    test "authority stamps increasing LSNs on its mutations":
      var leader = EdContext.init(id = "lsn_leader_a", is_authority = true)
      var follower = EdContext.init(id = "lsn_follower_a")
      follower.subscribe(leader)

      var obj = EdValue[int].init(ctx = leader, id = "lsn_obj_a")
      let before = leader.lsn_counter  # CREATE is not stamped yet
      obj.value = 1
      obj.value = 2
      obj.value = 3
      # Each assignment is an ordered op stamped by the authority.
      check leader.lsn_counter >= before + 3

      # LSNs are strictly increasing.
      let mid = leader.lsn_counter
      obj.value = 4
      check leader.lsn_counter > mid

    test "non-authority never stamps":
      var leader = EdContext.init(id = "lsn_leader_b", is_authority = true)
      var follower = EdContext.init(id = "lsn_follower_b")
      follower.subscribe(leader)

      var fobj = EdValue[int].init(ctx = follower, id = "lsn_obj_b")
      fobj.value = 7
      fobj.value = 8
      check follower.lsn_counter == 0

    test "follower frontier tracks the authority's ordered ops":
      var leader = EdContext.init(id = "lsn_leader_c", is_authority = true)
      var follower = EdContext.init(id = "lsn_follower_c")
      follower.subscribe(leader)

      var obj = EdValue[int].init(ctx = leader, id = "lsn_obj_c")
      obj.value = 1
      obj.value = 2
      obj.value = 3
      follower.tick()

      # Follower applied the ordered ops; its frontier matches the authority's
      # LSN counter (CREATE is unstamped, so only the 3 assigns count).
      check follower.applied_lsn == leader.lsn_counter
      check follower.applied_lsn >= 3
      check EdValue[int](follower["lsn_obj_c"]).value == 3

    test "concurrent register writers converge to the authority's order":
      var leader = EdContext.init(id = "lsn_leader_e", is_authority = true)
      var fa = EdContext.init(id = "lsn_fa")
      var fb = EdContext.init(id = "lsn_fb")
      fa.subscribe(leader)
      fb.subscribe(leader)

      var obj = EdValue[int].init(ctx = leader, id = "lsn_obj_e")
      fa.tick()
      fb.tick()
      check "lsn_obj_e" in fa
      check "lsn_obj_e" in fb

      # Two optimistic writers race the same register.
      EdValue[int](fa["lsn_obj_e"]).value = 10
      EdValue[int](fb["lsn_obj_e"]).value = 20

      # Authority orders them (FIFO: fa then fb) and fans the canonical values
      # back to everyone -- including the writers (return-to-source).
      leader.tick()
      fa.tick()
      fb.tick()

      let lv = EdValue[int](leader["lsn_obj_e"]).value
      check EdValue[int](fa["lsn_obj_e"]).value == lv  # no divergence
      check EdValue[int](fb["lsn_obj_e"]).value == lv
      check lv == 20  # later writer in the authority's order wins

    test "register reconciliation is flicker-free (coalesced)":
      var leader = EdContext.init(id = "lsn_leader_h", is_authority = true)
      var fa = EdContext.init(id = "lsn_fa_h")
      var fb = EdContext.init(id = "lsn_fb_h")
      fa.subscribe(leader)
      fb.subscribe(leader)

      var obj = EdValue[int].init(ctx = leader, id = "lsn_obj_h")
      fa.tick()
      fb.tick()

      var seen: seq[int]
      EdValue[int](fb["lsn_obj_h"]).track proc(
          changes: seq[Change[int]]
      ) {.gcsafe.} =
        for c in changes:
          if ADDED in c.changes:
            seen.add c.item

      EdValue[int](fa["lsn_obj_h"]).value = 10
      EdValue[int](fb["lsn_obj_h"]).value = 20
      leader.tick()
      fa.tick()
      fb.tick()

      # fb converges to 20 without ever applying the superseded intermediate 10.
      check EdValue[int](fb["lsn_obj_h"]).value == 20
      check 10 notin seen

    test "a non-leader's writes don't snap back to their own stale echoes":
      # The movement case: a writer keeps updating a register; an earlier write
      # echoes back from the authority after the writer has moved on. The stale
      # echo must NOT snap the value backward (op_id-superseded rule).
      var leader = EdContext.init(id = "lsn_leader_j", is_authority = true)
      var follower = EdContext.init(id = "lsn_follower_j")
      follower.subscribe(leader)

      var obj = EdValue[int].init(ctx = leader, id = "lsn_obj_j")
      follower.tick()
      check "lsn_obj_j" in follower

      # Write 1; let the authority order it (the echo is now queued for us)...
      EdValue[int](follower["lsn_obj_j"]).value = 1
      leader.tick()
      # ...but before applying that echo we move on to 2.
      EdValue[int](follower["lsn_obj_j"]).value = 2
      follower.tick()
      # The stale echo of 1 must not drag us back.
      check EdValue[int](follower["lsn_obj_j"]).value == 2

      # And we still converge: the latest write is the canonical value.
      leader.tick()
      follower.tick()
      check EdValue[int](follower["lsn_obj_j"]).value == 2
      check EdValue[int](leader["lsn_obj_j"]).value == 2

    test "a follower's collection op is not double-applied":
      var leader = EdContext.init(id = "lsn_leader_f", is_authority = true)
      var follower = EdContext.init(id = "lsn_follower_f")
      follower.subscribe(leader)

      var s = EdSeq[int].init(ctx = leader, id = "lsn_seq_f")
      follower.tick()
      check "lsn_seq_f" in follower

      # Applied optimistically, sent to the authority, ordered, returned --
      # must NOT be re-applied (no duplicate).
      EdSeq[int](follower["lsn_seq_f"]).add 42
      leader.tick()
      follower.tick()

      check EdSeq[int](follower["lsn_seq_f"]).len == 1
      check EdSeq[int](leader["lsn_seq_f"]).len == 1
      check 42 in EdSeq[int](follower["lsn_seq_f"])

    test "concurrent collection writers converge without duplication":
      var leader = EdContext.init(id = "lsn_leader_g", is_authority = true)
      var fa = EdContext.init(id = "lsn_fa_g")
      var fb = EdContext.init(id = "lsn_fb_g")
      fa.subscribe(leader)
      fb.subscribe(leader)

      var s = EdSeq[int].init(ctx = leader, id = "lsn_seq_g")
      fa.tick()
      fb.tick()

      EdSeq[int](fa["lsn_seq_g"]).add 1
      EdSeq[int](fb["lsn_seq_g"]).add 2
      leader.tick()
      fa.tick()
      fb.tick()

      # Both adds present exactly once on every replica.
      check EdSeq[int](leader["lsn_seq_g"]).len == 2
      check EdSeq[int](fa["lsn_seq_g"]).len == 2
      check EdSeq[int](fb["lsn_seq_g"]).len == 2

    test "concurrent update and delete converge (delete wins, no divergence)":
      var leader = EdContext.init(id = "lsn_leader_i", is_authority = true)
      var fa = EdContext.init(id = "lsn_fa_i")
      var fb = EdContext.init(id = "lsn_fb_i")
      fa.subscribe(leader)
      fb.subscribe(leader)

      var obj = EdValue[int].init(ctx = leader, id = "lsn_obj_i")
      obj.value = 1
      fa.tick()
      fb.tick()
      check "lsn_obj_i" in fa
      check "lsn_obj_i" in fb

      # fa updates the object; fb deletes it -- concurrently.
      EdValue[int](fa["lsn_obj_i"]).value = 99
      EdValue[int](fb["lsn_obj_i"]).destroy()

      leader.tick()
      fa.tick()
      fb.tick()

      # All replicas agree (no divergence); the ordered delete wins.
      check ("lsn_obj_i" in leader) == ("lsn_obj_i" in fa)
      check ("lsn_obj_i" in fa) == ("lsn_obj_i" in fb)
      check "lsn_obj_i" notin leader

    test "ordered destroy propagates and advances the frontier":
      var leader = EdContext.init(id = "lsn_leader_d", is_authority = true)
      var follower = EdContext.init(id = "lsn_follower_d")
      follower.subscribe(leader)

      var obj = EdValue[int].init(ctx = leader, id = "lsn_obj_d")
      obj.value = 5
      follower.tick()
      check "lsn_obj_d" in follower

      let before = follower.applied_lsn
      obj.destroy()
      follower.tick()
      check "lsn_obj_d" notin follower
      check follower.applied_lsn > before  # DESTROY is a stamped, ordered op

    test "a lone writer gets its op back, and converges with an override":
      # The authority's only subscriber is the op's originator, which must still
      # get its op back (return-to-source) or the two disagree for good. Here
      # the follower's write is ordered after the authority's override, so
      # both settle on the write (see "REJECT_STALE registers" for the fix).
      var leader = EdContext.init(id = "cond_leader_a", is_authority = true)
      var follower = EdContext.init(id = "cond_follower_a")
      follower.subscribe(leader)
      var obj = EdValue[int].init(ctx = leader, id = "cond_obj_a")
      follower.tick()
      let fobj = EdValue[int](follower["cond_obj_a"])

      fobj.value = 1
      follower.tick() # sent, not yet ordered
      obj.value = 100
      settle(leader, follower)
      check obj.value == 1
      check fobj.value == 1

  suite "REJECT_STALE registers":
    const flags = DEFAULT_FLAGS + {REJECT_STALE}


    test "an override isn't undone by a write already in flight":
      var leader = EdContext.init(id = "cond_leader_b", is_authority = true)
      var follower = EdContext.init(id = "cond_follower_b")
      follower.subscribe(leader)
      var obj = EdValue[int].init(ctx = leader, id = "cond_obj_b", flags = flags)
      follower.tick()
      let fobj = EdValue[int](follower["cond_obj_b"])

      fobj.value = 1
      follower.tick() # sent, not yet ordered
      obj.value = 100
      settle(leader, follower)
      check obj.value == 100
      check fobj.value == 100

      # Writes made after seeing the override go through.
      fobj.value = 101
      settle(follower, leader)
      check obj.value == 101
      check fobj.value == 101

    test "a writer's own writes don't conflict with each other":
      var leader = EdContext.init(id = "cond_leader_c", is_authority = true)
      var follower = EdContext.init(id = "cond_follower_c")
      follower.subscribe(leader)
      var obj = EdValue[int].init(ctx = leader, id = "cond_obj_c", flags = flags)
      follower.tick()
      let fobj = EdValue[int](follower["cond_obj_c"])

      for i in 1 .. 5:
        fobj.value = i # none of these has seen the one before come back
        follower.tick()
      settle(leader, follower)
      check obj.value == 5
      check fobj.value == 5

    test "a new subscriber's first write isn't treated as stale":
      var leader = EdContext.init(id = "cond_leader_d", is_authority = true)
      var obj = EdValue[int].init(ctx = leader, id = "cond_obj_d", flags = flags)
      obj.value = 5 # the latest write is the leader's, before anyone subscribes
      var follower = EdContext.init(id = "cond_follower_d")
      follower.subscribe(leader)
      follower.tick()
      let fobj = EdValue[int](follower["cond_obj_d"])
      check fobj.value == 5

      fobj.value = 7
      settle(follower, leader)
      check obj.value == 7
      check fobj.value == 7

    test "concurrent writers: the first committed wins":
      var leader = EdContext.init(id = "cond_leader_e", is_authority = true)
      var fa = EdContext.init(id = "cond_fa")
      var fb = EdContext.init(id = "cond_fb")
      fa.subscribe(leader)
      fb.subscribe(leader)
      var obj = EdValue[int].init(ctx = leader, id = "cond_obj_e", flags = flags)
      fa.tick()
      fb.tick()

      EdValue[int](fa["cond_obj_e"]).value = 10
      EdValue[int](fb["cond_obj_e"]).value = 20 # hasn't seen fa's
      fa.tick()
      fb.tick()
      settle(leader, fa, fb)
      check obj.value == 10
      check EdValue[int](fa["cond_obj_e"]).value == 10
      check EdValue[int](fb["cond_obj_e"]).value == 10

    test "a touch is conditional too":
      var leader = EdContext.init(id = "cond_leader_f", is_authority = true)
      var follower = EdContext.init(id = "cond_follower_f")
      follower.subscribe(leader)
      var obj = EdValue[int].init(ctx = leader, id = "cond_obj_f", flags = flags)
      follower.tick()
      let fobj = EdValue[int](follower["cond_obj_f"])

      fobj.touch 1
      follower.tick()
      obj.value = 100
      settle(leader, follower)
      check obj.value == 100
      check fobj.value == 100

    test "it works through a relay":
      # leader <- relay <- writer, like an Enu client's main thread. The relay
      # doesn't forward an op that changes nothing it holds (the writer's own
      # echo), so it reports its progress instead.
      var leader = EdContext.init(id = "cond_leader_g", is_authority = true)
      var relay = EdContext.init(id = "cond_relay_g")
      var writer = EdContext.init(id = "cond_writer_g")
      relay.subscribe(leader)
      writer.subscribe(relay)
      check writer.authority_known
      var obj = EdValue[int].init(ctx = leader, id = "cond_obj_g", flags = flags)
      settle(leader, relay, writer)
      let wobj = EdValue[int](writer["cond_obj_g"])

      wobj.value = 1
      settle(writer, relay, leader, relay, writer)
      check obj.value == 1
      check writer.write_base > 0 # the relay told it how far it had read

      wobj.value = 2
      writer.tick()
      relay.tick()
      obj.value = 100 # lands before the writer's 2
      settle(leader, relay, writer)
      check obj.value == 100
      check wobj.value == 100

      wobj.value = 101
      settle(writer, relay, leader, relay, writer)
      check obj.value == 101
      check wobj.value == 101

    test "a REJECT_STALE collection is refused, not quietly unchecked":
      var ctx = EdContext.init(id = "cond_ctx_h", is_authority = true)
      expect AssertionDefect:
        discard EdSeq[int].init(ctx = ctx, id = "cond_seq_h", flags = flags)

    test "writing with no authority above says so":
      var a = EdContext.init(id = "cond_a_i")
      var b = EdContext.init(id = "cond_b_i")
      b.subscribe(a)
      check not b.authority_known
      var obj = EdValue[int].init(ctx = b, id = "cond_obj_i", flags = flags)
      obj.value = 1
      check "cond_obj_i" in b.unordered_warned

    test "a writer below a relay isn't stuck behind a write that changed nothing":
      # Another context writes the value the relay already holds, so the relay
      # forwards nothing. The writer must still learn it's past that write, or
      # every write it makes would be judged stale.
      var leader = EdContext.init(id = "cond_leader_j", is_authority = true)
      var relay = EdContext.init(id = "cond_relay_j")
      var writer = EdContext.init(id = "cond_writer_j")
      var other = EdContext.init(id = "cond_other_j")
      relay.subscribe(leader)
      writer.subscribe(relay)
      other.subscribe(leader)
      var obj = EdValue[int].init(ctx = leader, id = "cond_obj_j", flags = flags)
      obj.value = 5
      settle(leader, relay, writer, other)

      EdValue[int](other["cond_obj_j"]).value = 5 # same value, other origin
      EdValue[int](other["cond_obj_j"]).touch 5
      settle(other, leader, relay, writer)

      EdValue[int](writer["cond_obj_j"]).value = 9
      settle(writer, relay, leader, relay, writer)
      check obj.value == 9
      check EdValue[int](writer["cond_obj_j"]).value == 9
