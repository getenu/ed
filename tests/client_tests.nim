import test_util
import std/[unittest, atomics, os, strutils]
import ed
import ed/types {.all.}

# A per-process random loopback address (via test_util) so a live Enu / MCP
# server on the host can't leak packets into the test reactor.
let test_address = free_addr()

# A listening peer on its own thread, ticking continuously -- the role Enu
# plays for the MCP server (separate process, independent tick loop). An
# in-process same-thread server would deadlock the client's blocking
# subscribe, so a thread is the faithful setup.

var server_running: Atomic[bool]
var server_ready: Atomic[bool]
var server_thread: Thread[string]

proc server_loop(address: string) {.thread.} =
  let server = EdContext.init(id = "test-server", listen_address = address)
  Ed.thread_ctx = server
  var shared = EdValue[string].init(id = "shared", ctx = server)
  shared.value = "hello"
  server_ready.store(true)
  while server_running.load:
    server.tick
    sleep 5
  server.close

proc start_server() =
  server_ready.store(false)
  server_running.store(true)
  create_thread(server_thread, server_loop, test_address)
  while not server_ready.load:
    sleep 5

proc stop_server() =
  server_running.store(false)
  join_thread(server_thread)

var setups = 0

proc on_connect() {.gcsafe.} =
  inc setups

proc run*() =
  test "EdClient connects, stays live, and reconnects on the same id":
    setups = 0
    start_server()
    defer:
      stop_server()

    let client = EdClient(
      id: "test-agent",
      address: test_address,
      on_connect: on_connect,
    )

    check not client.connected
    client.reconnect
    check client.connected
    check setups == 1

    # The server's object syncs to the client through ticks.
    var received = ""
    for _ in 0 ..< 20:
      client.tick
      if "shared" in client.ctx:
        received = EdValue[string](client.ctx["shared"]).value
        if received == "hello":
          break
      sleep 5
    check received == "hello"

    # Idle ticking keeps the link up -- no spurious reconnect, no re-setup.
    for _ in 0 ..< 10:
      client.tick
      sleep 5
    check client.connected
    check setups == 1

    # online is a no-op while connected.
    client.online
    check setups == 1

    # An explicit reconnect rebuilds the context under the same id and
    # reruns on_connect; the server's stale-sub sweep accepts it.
    client.reconnect
    check client.connected
    check setups == 2

  test "EdClient reconnects after the peer goes away and returns":
    # The MCP-server-survives-an-Enu-restart path. A dropped peer must be
    # detected (netty reaps the connection after its ~10s timeout) and the
    # client must re-subscribe under the same id once the peer is back --
    # all from plain idle ticking, no manual intervention.
    setups = 0
    start_server()
    let client = EdClient(
      id: "test-agent-restart",
      address: test_address,
      on_connect: on_connect,
    )
    client.reconnect
    check client.connected
    check setups == 1

    # Peer disappears. Tick the context directly (not `client.tick`, which
    # would also try a blocking reconnect) until the dead connection is
    # reaped and the link reads as down.
    stop_server()
    var dropped = false
    for _ in 0 ..< 1000: # generous: netty conn_timeout is 10s
      client.ctx.tick
      if not client.connected:
        dropped = true
        break
      sleep 20
    check dropped

    # Peer returns; idle `client.tick`s alone bring it back.
    start_server()
    defer:
      stop_server()
    var recovered = false
    for _ in 0 ..< 200:
      client.tick
      if client.connected:
        recovered = true
        break
      sleep 20
    check recovered
    check setups >= 2

  test "waiting helpers raise SessionLost when the live session goes away":
    setups = 0
    start_server()
    let client = EdClient(id: "test-agent-sl", address: test_address)
    client.reconnect
    check client.connected

    # The peer dies mid-wait. tick_until's ticking reaps the dead
    # connection (and eventually reconnects, replacing the context); either
    # way the session this wait captured handles from is gone.
    stop_server()
    var lost = false
    try:
      discard client.tick_until(30.seconds, false)
    except SessionLost:
      lost = true
    check lost

    # A wait that STARTS without a live session is a connect-wait: it must
    # keep looping through reconnect attempts without raising.
    start_server()
    defer:
      stop_server()
    check client.tick_until(10.seconds, client.connected)

  test "first connect adopts the thread default instead of clobbering it":
    start_server()
    defer:
      stop_server()

    # A context the caller set up as the thread default.
    let default_ctx = EdContext.init(id = "adopt-me")
    Ed.thread_ctx = default_ctx

    # An id-agnostic client: no explicit id.
    let client = EdClient(address: test_address)
    client.reconnect

    # It adopted the existing thread default rather than minting a new one, and
    # took that context's id as its stable identity. The thread default is
    # untouched (still the same object).
    check client.ctx == default_ctx
    check client.id == "adopt-me"
    check Ed.thread_ctx == default_ctx

    # A genuine reconnect still mints a FRESH context under the adopted id (the
    # adopted context becomes `prev`).
    client.reconnect
    check client.ctx != default_ctx
    check client.prev == default_ctx
    check client.id == "adopt-me"
    check Ed.thread_ctx == client.ctx

  test "a caller-pinned id wins over the thread default and is installed as it":
    start_server()
    defer:
      stop_server()

    # A thread default with a different id must NOT be adopted when the caller
    # pinned a specific id -- that stays backward-compatible with id-driven
    # callers (e.g. the MCP server). The pinned context is promoted to the
    # thread default so on_connect/app helpers read the right context.
    let default_ctx = EdContext.init(id = "some-other-default")
    Ed.thread_ctx = default_ctx

    let client = EdClient(id: "pinned-id", address: test_address)
    client.reconnect

    check client.ctx != default_ctx
    check client.ctx.id == "pinned-id"
    check client.id == "pinned-id"
    check Ed.thread_ctx == client.ctx

  test "the default context id is globally unique, not a bare thread id":
    # A context id doubles as its identity on the wire, so two default contexts
    # (e.g. one per process) must not collide. The `thread-<id>` prefix stays for
    # readable logs; a unique suffix makes the whole id distinct.
    let a = EdContext.init()
    let b = EdContext.init()
    check a.id != b.id
    check a.id.starts_with("thread-")

when is_main_module:
  Ed.bootstrap
  run()
