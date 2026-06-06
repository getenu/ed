import std/[unittest, sets, tables]
import ed
import ed/zens/contexts

type DeepOwner = ref object of EdRef
  id: string
  items: EdSeq[int]
  val: EdValue[int]

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
      client.subscribe(authority, partial = true, fetch = ["obj_x"])
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

    test "fetch materializes an out-of-interest object and starts syncing it":
      var authority = EdContext.init(id = "f_authority", is_authority = true)
      var client = EdContext.init(id = "f_client")

      var x = EdValue[int].init(ctx = authority, id = "f_x")
      var y = EdValue[int].init(ctx = authority, id = "f_y")
      x.value = 1
      y.value = 2

      client.subscribe(authority, partial = true, fetch = ["f_x"])
      client.tick()
      check "f_y" notin client

      # Fetch f_y on demand.
      client.fetch("f_y")
      authority.tick() # authority handles REQUEST, sends f_y's CREATE
      client.tick() # client materializes f_y
      check "f_y" in client
      check EdValue[int](client["f_y"]).value == 2

      # f_y now syncs (it joined the interest set).
      y.value = 20
      client.tick()
      check EdValue[int](client["f_y"]).value == 20

    test "deep fetch pulls an owner's full ownership closure":
      var authority = EdContext.init(id = "d_auth", is_authority = true)
      var client = EdContext.init(id = "d_client")

      var bot = DeepOwner(id: "d_bot")
      bot.own:
        bot.items = EdSeq[int].init(ctx = authority, id = "d_items")
        bot.val = EdValue[int].init(ctx = authority, id = "d_val")
      bot.items.add 3

      client.subscribe(authority, partial = true, fetch = [])
      client.tick()
      check "d_items" notin client # out of interest
      check "d_val" notin client

      # The owner id isn't itself a container — a deep fetch expands its
      # ownership closure on the authority and sends everything it owns.
      client.fetch("d_bot", deep = true)
      authority.tick() # serves the REQUEST: walks owned_by, publishes the closure
      client.tick() # materializes the owned containers
      check "d_items" in client
      check "d_val" in client
      check EdSeq[int](client["d_items"])[0] == 3
      check EdSeq[int](client["d_items"]).owner_id == "d_bot" # ownership syncs too
      check "d_items" in client.owned_by["d_bot"]

      # The closure joined the interest set: future ops follow.
      bot.items.add 4
      client.tick()
      check EdSeq[int](client["d_items"]).len == 2

    test "objects created after subscribe respect partial interest":
      var authority = EdContext.init(id = "pc_auth", is_authority = true)
      var client = EdContext.init(id = "pc_client")
      client.subscribe(authority, partial = true, fetch = ["pc_root"])
      client.tick()

      # Created after the subscribe — the broadcast CREATE must still be filtered.
      var root = EdValue[int].init(ctx = authority, id = "pc_root")
      var other = EdValue[int].init(ctx = authority, id = "pc_other")
      client.tick()
      check "pc_root" in client # in interest
      check "pc_other" notin client # filtered

    test "a partial client's own object syncs back from the authority":
      var authority = EdContext.init(id = "po_auth", is_authority = true)
      var client = EdContext.init(id = "po_client")
      client.subscribe(authority, partial = true, fetch = [])
      client.tick()

      # Client creates its own object; the authority should pick it up and
      # return its canonical ops (auto-interest on create-from-subscriber).
      var mine = EdValue[int].init(ctx = client, id = "po_mine")
      mine.value = 5
      authority.tick()
      client.tick()
      check "po_mine" in authority
      check EdValue[int](authority["po_mine"]).value == 5

      # Return-to-source works for the partial client's own object.
      EdValue[int](client["po_mine"]).value = 7
      authority.tick()
      client.tick()
      check EdValue[int](authority["po_mine"]).value == 7
      check EdValue[int](client["po_mine"]).value == 7

    test "non-partial subscriber still gets everything (default unchanged)":
      var authority = EdContext.init(id = "p_authority2", is_authority = true)
      var client = EdContext.init(id = "p_client2")

      var x = EdValue[int].init(ctx = authority, id = "obj_x2")
      var y = EdValue[int].init(ctx = authority, id = "obj_y2")

      client.subscribe(authority) # full
      client.tick()
      check "obj_x2" in client
      check "obj_y2" in client
