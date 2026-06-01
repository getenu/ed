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
