import std/[tables, sugar, unittest, sequtils, strutils, sets]
import pkg/[flatty, chronicles, netty]
import ed
import ed/types {.all.}
import ed/zens/private {.all.}
import test_util
from std/times import init_duration, epoch_time

const recv_duration = init_duration(milliseconds = 10)

type Vector3 = array[3, float]

proc run*() =
  test "4 way sync":
    let host = free_addr()
    var
      ctx1 = EdContext.init(id = "ctx1")
      ctx2 = EdContext.init(
        id = "ctx2",
        listen_address = host,
        min_recv_duration = recv_duration,
        blocking_recv = true,
      )
      ctx3 = EdContext.init(
        id = "ctx3", min_recv_duration = recv_duration, blocking_recv = true
      )
      ctx4 = EdContext.init(id = "ctx4")

    ctx2.subscribe(ctx1)
    ctx3.subscribe(ctx4)
    ctx3.subscribe host,
      callback = proc() =
        ctx2.tick(blocking = false)

    var
      a = EdValue[string].init(id = "test1", ctx = ctx1)
      b = EdValue[string].init(id = "test1", ctx = ctx2)
      c = EdValue[string].init(id = "test1", ctx = ctx3)
      d = EdValue[string].init(id = "test1", ctx = ctx4)

    ctx1.tick
    ctx2.tick

    a.value = "set"
    ctx1.tick
    ctx2.tick
    ctx3.tick
    ctx4.tick
    check d.value == "set"

    ctx2.close

  test "trigger changes on subscribe":
    let host = free_addr()
    var
      count = 0
      ctx1 = EdContext.init(id = "ctx1")
      ctx2 = EdContext.init(
        id = "ctx2",
        listen_address = host,
        min_recv_duration = recv_duration,
        blocking_recv = true,
      )
      ctx3 = EdContext.init(
        id = "ctx3", min_recv_duration = recv_duration, blocking_recv = true
      )
      ctx4 = EdContext.init(id = "ctx4")

    var
      a = Ed.init(@["a1", "a2"], id = "test2", ctx = ctx1)
      b = Ed.init(@["b1", "b2"], id = "test2", ctx = ctx2)
      c = Ed.init(@["c1", "c2"], id = "test2", ctx = ctx3)
      d = Ed.init(@["d1", "d2"], id = "test2", ctx = ctx4)

    d.changes:
      if added:
        inc count

    ctx2.subscribe(ctx1)
    ctx3.subscribe(ctx4)

    ctx1.tick

    check a.value == @["a1", "a2"]
    check b.value == @["a1", "a2"]

    ctx4.tick
    ctx3.subscribe host,
      callback = proc() =
        ctx2.tick(blocking = false)

    ctx4.tick

    check count == 2
    check a.len == 2

    check a.value == @["a1", "a2"]
    check b.value == @["a1", "a2"]
    check c.value == @["a1", "a2"]
    check d.value == @["a1", "a2"]

    ctx2.close

  test "nested collection":
    let host = free_addr()
    type Unit = object
      code: EdValue[string]

    var
      count = 0
      ctx1 = EdContext.init(id = "ctx1")
      ctx2 = EdContext.init(
        id = "ctx2",
        listen_address = host,
        min_recv_duration = recv_duration,
        blocking_recv = true,
      )
      ctx3 = EdContext.init(
        id = "ctx3", min_recv_duration = recv_duration, blocking_recv = true
      )
      ctx4 = EdContext.init(id = "ctx4")

    var
      a = Ed.init(@["a1", "a2"], id = "test2", ctx = ctx1)
      b = Ed.init(@["b1", "b2"], id = "test2", ctx = ctx2)
      c = Ed.init(@["c1", "c2"], id = "test2", ctx = ctx3)
      d = Ed.init(@["d1", "d2"], id = "test2", ctx = ctx4)

    d.changes:
      if added:
        inc count

    ctx2.subscribe(ctx1)
    ctx3.subscribe(ctx4)

    ctx1.tick

    check a.value == @["a1", "a2"]
    check b.value == @["a1", "a2"]

    ctx4.tick
    ctx3.subscribe host,
      callback = proc() =
        ctx2.tick(blocking = false)

    ctx4.tick

    check count == 2
    check a.len == 2

    check a.value == @["a1", "a2"]
    check b.value == @["a1", "a2"]
    check c.value == @["a1", "a2"]
    check d.value == @["a1", "a2"]

    ctx2.close

  test "Vector3 array network sync":
    let host = free_addr()
    var
      ctx1 = EdContext.init(id = "ctx1")
      ctx2 = EdContext.init(
        id = "ctx2",
        listen_address = host,
        min_recv_duration = recv_duration,
        blocking_recv = true,
      )

    ctx2.subscribe(ctx1)

    # Create Vector3 value and verify it creates EdValue not EdSeq
    var vec = Vector3([1.0, 2.0, 3.0])
    var v1 = Ed.init(vec, id = "vector", ctx = ctx1)
    
    # Verify type - this ensures our fix worked
    check v1 is EdValue[Vector3]
    check v1.value == vec

    ctx1.tick
    ctx2.tick

    # Test that it synced over network
    var v2 = EdValue[Vector3](ctx2["vector"])
    check v2.value == vec

    # Test mutation sync
    v1.value = Vector3([4.0, 5.0, 6.0])
    ctx1.tick
    ctx2.tick
    check v2.value == Vector3([4.0, 5.0, 6.0])

    ctx2.close

  test "resubscribe with same ctx_id drops the stale subscription":
    # Reproduces the Enu MCP reconnect scenario at the protocol level. A
    # client subscribes, then its EdContext is recreated (process didn't
    # die -- same id, fresh context) and subscribes again. The publisher
    # must drop the stale subscriber so it doesn't route messages to a
    # connection that now belongs to the new context.
    let host = free_addr()
    Ed.thread_ctx = EdContext.init(id = "mainA")
    var
      publisher = EdContext.init(
        id = "publisher",
        listen_address = host,
        min_recv_duration = recv_duration,
        blocking_recv = true,
      )
      client_a = Ed.thread_ctx

    client_a.subscribe host,
      callback = proc() =
        publisher.tick(blocking = false)

    privileged
    check publisher.subscribers.filter_it(it.kind == REMOTE).len == 1

    # Simulate the reconnect: same ctx id, fresh EdContext.
    Ed.thread_ctx = EdContext.init(id = "mainA")
    var client_b = Ed.thread_ctx
    client_b.subscribe host,
      callback = proc() =
        publisher.tick(blocking = false)

    # Publisher should have swept the stale "mainA" subscriber when the
    # new one's SUBSCRIBE arrived -- exactly one REMOTE sub remains.
    let remote_subs = publisher.subscribers.filter_it(it.kind == REMOTE)
    check remote_subs.len == 1
    check remote_subs[0].ctx_id == "mainA"

    publisher.close

  test "a wire-version-mismatched peer is rejected, not fatal":
    # A version-skewed client once killed a server silently: flatty is
    # positional, so old-format bytes can decode cleanly into wrong-typed
    # fields and blow up deep in processing. Every packet now carries a wire
    # header; foreign packets drop at parse_remote with a warning, and the
    # server keeps serving its real clients.
    let host = free_addr()
    let port = host.split(":")[1].parse_int
    var server = EdContext.init(
      id = "wire_srv",
      listen_address = host,
      min_recv_duration = recv_duration,
      blocking_recv = true,
    )
    var sv = EdValue[string].init(id = "wire_v", ctx = server)
    sv.value = "alive"

    # A "client" speaking a different wire format: valid netty framing,
    # old-format-shaped payloads (no wire header) -- including one that
    # resembles the pre-header packet layout.
    var rogue = new_reactor()
    let conn = rogue.connect("127.0.0.1", port)
    let old_style = (@[1'u8, 2'u8], @[("a", "b")], "not compressed").to_flatty
    for payload in ["garbage", old_style, "\x00\x01\x02\x03"]:
      rogue.send(conn, payload)
      rogue.tick()

    # The server must survive parsing all of it...
    for _ in 0 ..< 10:
      server.tick(blocking = false)
      rogue.tick()

    # ...and still serve a real, matching client.
    Ed.thread_ctx = EdContext.init(id = "wire_cli")
    Ed.thread_ctx.subscribe host,
      callback = proc() =
        server.tick(blocking = false)
    var cv = EdValue[string](Ed.thread_ctx["wire_v"])
    check cv.value == "alive"

    server.close

  test "a subscribed peer sending unparseable bytes is disconnected":
    # Got past the wire header and established a subscription (same version), then
    # sent bytes we can't decode -- schema mismatch / corruption / a bug. Tear the
    # connection down so it re-handshakes and resyncs, rather than silently
    # dropping its packets forever. (Stray, un-subscribed noise is left alone --
    # see the test above.)
    let host = free_addr()
    var server = EdContext.init(
      id = "wd_srv",
      listen_address = host,
      min_recv_duration = recv_duration,
      blocking_recv = true,
    )
    var sv = EdValue[string].init(id = "wd_v", ctx = server)
    sv.value = "x"

    Ed.thread_ctx = EdContext.init(id = "wd_cli")
    let client = Ed.thread_ctx
    client.subscribe host,
      callback = proc() =
        server.tick(blocking = false)
    check "wd_cli" in server.subscribers.map_it(it.ctx_id) # sub established

    # Garbage over the established connection: valid netty framing, no wire header.
    var conn: Connection
    for s in client.subscribers:
      if s.kind == REMOTE:
        conn = s.connection
    client.reactor.send(conn, "not an ed packet")
    client.reactor.tick()

    for _ in 0 ..< 30:
      server.tick(blocking = false)
      client.reactor.tick()
      if "wd_cli" notin server.subscribers.map_it(it.ctx_id):
        break
    check "wd_cli" notin server.subscribers.map_it(it.ctx_id) # connection dropped
    check "wd_cli" in server.drain_unsubscribed # ...and reported for reaping
    server.close

  test "a real upstream timeout leaves fetch resolving NotFound, not crashing":
    # A PARTIAL_ASYNC replica whose upstream times out (netty connTimeout) used to
    # crash on the next fetch: the sub is reaped but the id stays in the append-only
    # upstream_ctx_ids, so request_targets found a recorded-but-dead upstream. Drive
    # a genuine timeout (clock-jump the reactor past connTimeout) and confirm fetch
    # degrades to NotFound -- the data returns via the reconnect's resubscribe.
    let host = free_addr()
    var
      authority = EdContext.init(id = "rt_auth", listen_address = host)
      client = EdContext.init(id = "rt_cli")
    client.subscribe host,
      mode = PARTIAL_ASYNC,
      callback = proc() =
        authority.tick(blocking = false)
    var recorded = authority.id in client.upstream_ctx_ids
    check recorded
    check client.subscribers.len == 1

    # Jump the client's reactor clock past connTimeout (10s): a sleep/wake or a
    # >10s starved thread reaches the same state with zero real inactivity.
    client.reactor.debug.tick_time = epoch_time() + 11.0
    client.tick(blocking = false) # timeoutConnections -> dead -> unsubscribe

    check client.subscribers.len == 0 # upstream sub reaped...
    recorded = authority.id in client.upstream_ctx_ids # ...but still recorded
    check recorded
    let handle = client.fetch("rt_missing")
    check handle.state == NotFound # no crash
    authority.close
    client.close

when is_main_module:
  Ed.bootstrap
  run()
