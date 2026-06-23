import std/unittest
import ed
import ed/zens/contexts

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
