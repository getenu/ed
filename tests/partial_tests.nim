import std/unittest
import ed
import ed/zens/contexts

proc run*() =
  suite "partial replicas":
    test "partial subscriber only receives its interest set":
      var authority = EdContext.init(id = "p_authority", is_authority = true)
      var client = EdContext.init(id = "p_client")

      var x = EdValue[int].init(ctx = authority, id = "obj_x")
      var y = EdValue[int].init(ctx = authority, id = "obj_y")
      x.value = 1
      y.value = 2

      # Interested only in obj_x.
      client.subscribe(authority, partial = true, roots = @["obj_x"])
      client.tick()

      check "obj_x" in client # pushed (in interest)
      check "obj_y" notin client # filtered out
      check EdValue[int](client["obj_x"]).value == 1

      # Ongoing ops: only obj_x's changes reach the client.
      x.value = 10
      y.value = 20
      client.tick()
      check EdValue[int](client["obj_x"]).value == 10
      check "obj_y" notin client

    test "non-partial subscriber still gets everything (default unchanged)":
      var authority = EdContext.init(id = "p_authority2", is_authority = true)
      var client = EdContext.init(id = "p_client2")

      var x = EdValue[int].init(ctx = authority, id = "obj_x2")
      var y = EdValue[int].init(ctx = authority, id = "obj_y2")

      client.subscribe(authority) # full
      client.tick()
      check "obj_x2" in client
      check "obj_y2" in client
