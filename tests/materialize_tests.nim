import std/[unittest, sets, atomics, os, tables]
import ed
import ed/zens/contexts
import test_util

# A listening authority on its own thread, ticking continuously — the role Enu
# plays for the MCP server (separate process, independent tick loop), and what a
# blocking remote materialize needs to respond to it.
var rmat_running: Atomic[bool]
var rmat_ready: Atomic[bool]
var rmat_thread: Thread[string]

proc rmat_server_loop(address: string) {.thread.} =
  let server =
    EdContext.init(id = "rmat-server", is_authority = true, listen_address = address)
  Ed.thread_ctx = server
  var parent = EdSeq[EdValue[string]].init(id = "parent", ctx = server)
  var child = EdValue[string].init(id = "child", ctx = server)
  child.value = "materialized"
  parent += child # parent is pre-populated before any client connects
  rmat_ready.store(true)
  while rmat_running.load:
    server.tick
    sleep 5
  server.close

proc run*() =
  suite "materialize on access":
    test "placeholder stands in for an out-of-interest nested object":
      var authority = EdContext.init(id = "m_auth", is_authority = true)
      var client = EdContext.init(id = "m_client")

      # Parent collection of nested Ed values.
      var parent = EdSeq[EdValue[string]].init(ctx = authority, id = "parent")

      # Client is interested only in the parent, not its children.
      client.subscribe(authority, partial = true, roots = @["parent"])
      client.tick()
      check "parent" in client

      # Author a child and add it to the parent. The child's CREATE is filtered
      # (not in interest), but the parent's ADD op — which references the child —
      # is delivered, so the client must stand in with a placeholder.
      var child = EdValue[string].init(ctx = authority, id = "child")
      child.value = "hi"
      parent += child
      client.tick()

      check "child" in client # placeholder materialized into the object pool
      check EdSeq[EdValue[string]](client["parent"]).len == 1 # cardinality correct
      check not client["child"].loaded # exists, but not loaded
      check EdValue[string](client["child"]).value == "" # empty until filled

      # Explicit fetch materializes it (access-triggered fetch is the next slice).
      client.fetch("child")
      authority.tick() # authority answers the REQUEST
      client.tick() # client fills the placeholder
      check client["child"].loaded # fill cleared the bit
      check EdValue[string](client["child"]).value == "hi"

    test "reading a placeholder auto-triggers the fetch (no explicit fetch)":
      var authority = EdContext.init(id = "ma_auth", is_authority = true)
      var client = EdContext.init(id = "ma_client")
      var parent = EdSeq[EdValue[string]].init(ctx = authority, id = "parent")
      client.subscribe(authority, partial = true, roots = @["parent"])
      client.tick()

      var child = EdValue[string].init(ctx = authority, id = "child")
      child.value = "hi"
      parent += child
      client.tick()
      check not client["child"].loaded

      # Just *reading* the placeholder's value kicks the fetch (non-blocking:
      # returns empty now). No client.fetch() call here.
      check EdValue[string](client["child"]).value == ""
      authority.tick() # authority answers the access-triggered REQUEST
      client.tick() # fill arrives
      check client["child"].loaded
      check EdValue[string](client["child"]).value == "hi"

    test "a fill fires a change tagged reason == Fill":
      var authority = EdContext.init(id = "mf_auth", is_authority = true)
      var client = EdContext.init(id = "mf_client")
      var parent = EdSeq[EdValue[string]].init(ctx = authority, id = "parent")
      client.subscribe(authority, partial = true, roots = @["parent"])
      client.tick()
      var child = EdValue[string].init(ctx = authority, id = "child")
      child.value = "hi"
      parent += child
      client.tick()
      check not client["child"].loaded

      var fill_reason = Normal
      EdValue[string](client["child"]).track proc(cs: seq[Change[string]]) =
        for c in cs:
          if MODIFIED in c.changes:
            fill_reason = c.reason

      client.fetch("child")
      authority.tick()
      client.tick() # fill applies here → callback fires, tagged Fill
      check client["child"].loaded
      check fill_reason == Fill

    test "blocking materialize is silent: only the target fills, rest defers":
      var authority = EdContext.init(id = "ms_auth", is_authority = true)
      var client = EdContext.init(id = "ms_client")
      var parent = EdSeq[EdValue[string]].init(ctx = authority, id = "parent")
      var other = EdValue[int].init(ctx = authority, id = "other")
      client.subscribe(authority, partial = true, roots = @["parent", "other"])
      client.tick()

      var child = EdValue[string].init(ctx = authority, id = "child")
      child.value = "hi"
      parent += child
      client.tick() # placeholder for child
      check not client["child"].loaded

      var other_fired = false
      EdValue[int](client["other"]).track proc(cs: seq[Change[int]]) =
        other_fired = true
      var child_fill_reason = Normal
      EdValue[string](client["child"]).track proc(cs: seq[Change[string]]) =
        for c in cs:
          if MODIFIED in c.changes:
            child_fill_reason = c.reason

      # Queue two messages into the client's channel WITHOUT processing them:
      # an unrelated change to `other`, and (via fetch) the child's CREATE.
      other.value = 99
      client.fetch("child")
      authority.tick() # authority queues child's CREATE onto the client's chan

      # Blocking read materializes ONLY child; everything else is deferred.
      var got = "before"
      client.blocking:
        got = EdValue[string](client["child"]).value

      check got == "hi" # blocking read returned the real value
      check client["child"].loaded
      check not other_fired # unrelated message was deferred, not applied
      check EdValue[int](client["other"]).value == 0 # ...and its value untouched
      check not (child_fill_reason == Fill) # even the Fill callback deferred

      # The next explicit tick replays everything at the tick boundary.
      client.tick()
      check other_fired
      check EdValue[int](client["other"]).value == 99
      check child_fill_reason == Fill

    test "remote partial replica blocking-materializes a placeholder":
      let address = free_addr()
      rmat_ready.store(false)
      rmat_running.store(true)
      create_thread(rmat_thread, rmat_server_loop, address)
      while not rmat_ready.load:
        sleep 5
      defer:
        rmat_running.store(false)
        join_thread(rmat_thread)

      var client = EdContext.init(id = "rmat-client")
      # Partial subscribe over the network: interested only in the parent.
      client.subscribe(address, partial = true, roots = @["parent"])

      # The pre-populated parent arrives; its out-of-interest child is a
      # placeholder (created in from_flatty). Wait briefly for it (UDP).
      var tries = 0
      while "child" notin client and tries < 200:
        client.tick()
        sleep 5
        inc tries
      check "parent" in client
      check "child" in client
      check not client["child"].loaded # placeholder, contents not pulled yet

      # A blocking read materializes it over the network — the server thread
      # answers the fetch while we pump.
      var got = ""
      client.blocking:
        got = EdValue[string](client["child"]).value
      check got == "materialized"
      check client["child"].loaded
      client.close

    test "per-key fetch: pull individual table entries, batched, as ADDED":
      var authority = EdContext.init(id = "pk_auth", is_authority = true)
      var client = EdContext.init(id = "pk_client")
      # A seq of tables; the client takes the seq as a root, so each table comes
      # in as an empty placeholder.
      var parent = EdSeq[EdTable[int, string]].init(ctx = authority, id = "parent")
      var child = EdTable[int, string].init(ctx = authority, id = "child")
      child[1] = "one"
      child[2] = "two"
      child[3] = "three"
      parent += child

      client.subscribe(authority, partial = true, roots = @["parent"])
      client.tick()
      let table = EdTable[int, string](client["child"])
      check "child" in client
      check not table.loaded(1) # nothing pulled yet

      # Watch records arrivals as ADDED (the pattern enu's renderer uses).
      var arrived: seq[(int, string)]
      table.changes:
        if added:
          arrived.add (change.item.key, change.item.value)

      # Two requests in one frame → one batched REQUEST on the next tick.
      table.request(1)
      table.request(3)
      client.tick() # flush_key_requests sends the batch
      authority.tick() # authority replies with entries 1 and 3
      client.tick() # client applies the ADD ops

      check table.loaded(1)
      check table.loaded(3)
      check not table.loaded(2) # never requested → not pulled
      check table[1] == "one"
      check table[3] == "three"
      check arrived.len == 2 # both fills fired as ADDED changes
      check (1, "one") in arrived
      check (3, "three") in arrived

      # release evicts locally (loaded -> false) without deleting on the authority.
      var removed_keys: seq[int]
      table.changes:
        if removed:
          removed_keys.add change.item.key
      table.release(1)
      check not table.loaded(1) # dropped locally
      check removed_keys == @[1] # fired REMOVED so watches un-render
      check EdTable[int, string](authority["child"]).loaded(1) # still on authority
      table.request(1) # re-fetch works
      client.tick()
      authority.tick()
      client.tick()
      check table.loaded(1)
      check table[1] == "one"

    test "blocking scope toggles the flag and restores it":
      var ctx = EdContext.init(id = "mb_ctx")
      check not ctx.blocking
      ctx.blocking:
        check ctx.blocking # set inside the scope
      check not ctx.blocking # restored after
      # Nested / manual management still composes.
      ctx.blocking = true
      ctx.blocking:
        check ctx.blocking
      check ctx.blocking # restored to the manual value, not forced off
