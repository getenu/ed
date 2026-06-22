import std/[unittest, sets]
import ed
import ed/zens/contexts
import ed/utils/misc

proc run*() =
  suite "capability handshake":
    test "authority skips objects the subscriber can't materialize":
      var authority = EdContext.init(id = "cap_auth", is_authority = true)
      var client = EdContext.init(id = "cap_client")
      client.subscribe(authority)

      # Model a different-build remote peer: in-process both share
      # `type_initializers`, so restrict the subscription by hand to a single
      # type it "can handle". (The wire handshake populates this automatically
      # for real remote subscribers.)
      authority.subscribers[0].capabilities = [Ed[int, int].tid].to_hash_set

      var i = EdValue[int].init(ctx = authority, id = "cap_int")
      i.value = 7
      var s = EdValue[string].init(ctx = authority, id = "cap_str")
      s.value = "hi"
      client.tick()

      check "cap_int" in client # capable type delivered
      check "cap_str" notin client # incapable type filtered out
      check EdValue[int](client["cap_int"]).value == 7

      # Ongoing ops respect it too: a later write to the filtered object never
      # arrives (and never crashes the client trying to deserialize it).
      s.value = "world"
      client.tick()
      check "cap_str" notin client

    test "empty capabilities = unfiltered (default full replica)":
      var authority = EdContext.init(id = "cap_auth2", is_authority = true)
      var client = EdContext.init(id = "cap_client2")
      client.subscribe(authority) # local subscribe leaves capabilities empty

      var i = EdValue[int].init(ctx = authority, id = "cap_int2")
      var s = EdValue[string].init(ctx = authority, id = "cap_str2")
      client.tick()
      check "cap_int2" in client
      check "cap_str2" in client
