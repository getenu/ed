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
