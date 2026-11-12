import std/[unittest, strutils, tables, os, hashes]
import pkg/netty
import ed
import ed/utils/[layouts, misc]
import ed/components/private/global_state
import test_util
from std/times import init_duration

type
  Mood = enum
    HAPPY
    SAD

  Point = object
    x, y: float

  Node = ref object
    value: int
    next: Node

  Pal = ref object of EdRef
    name: string

  Unit = ref object of EdRef
    label: string
    mood: Mood
    at: Point
    local_cache {.ed_ignore.}: Table[string, int]
    handle: Node
    on_change: proc()
    friend: Pal
    friends: EdSeq[Pal]
    flags: EdSet[Mood]

proc run*() =
  suite "wire layouts":
    test "registered types skip what stringify drops":
      let sig = Unit.registered_layout_signature
      check "label:string" in sig
      check "mood:enum(HAPPY,SAD)" in sig
      check "at:{x:f8;y:f8;}" in sig
      check "friends:Ed[seq[edref],edref]" in sig
      check "flags:Ed[set[enum(HAPPY,SAD)],enum(HAPPY,SAD)]" in sig
      check "local_cache" notin sig
      check "handle" notin sig
      check "on_change" notin sig
      check "friend:" notin sig

    test "container item types are walked; recursive refs terminate":
      check EdValue[Node].layout_signature ==
        "Ed[ref {value:i8;next:ref rec1;},ref {value:i8;next:ref rec1;}]"
      check EdValue[int].layout_hash != EdValue[float].layout_hash
      check EdValue[int32].layout_hash != EdValue[int64].layout_hash

    test "aliases don't change a signature":
      type Count = int
      check EdValue[Count].layout_signature == EdValue[int].layout_signature
      check EdValue[Hash].layout_signature == "Ed[i8,i8]"

  suite "layout handshake":
    proc subscribe_error(skew: bool): string =
      # The client builds its handshake before the authority first ticks, so
      # skewing the authority's entry in the callback stands in for a peer built
      # from different sources.
      let host = free_addr()
      let tid = Ed[int, int].tid
      var authority = EdContext.init(
        id = "layout_auth",
        listen_address = host,
        min_recv_duration = init_duration(milliseconds = 10),
        blocking_recv = true,
      )
      var client = EdContext.init(id = "layout_client")
      discard EdValue[int].init(ctx = authority)
      let original = global_layout_registry[][tid]
      try:
        client.subscribe host,
          callback = proc() {.gcsafe.} =
            if skew:
              with_lock:
                global_layout_registry[][tid].layout = original.layout + 1
            authority.tick(blocking = false)
      except SchemaMismatchError as e:
        result = e.msg
      finally:
        with_lock:
          global_layout_registry[][tid] = original
        authority.close

    test "matching layouts subscribe":
      check subscribe_error(skew = false) == ""

    test "a shared type with a different layout is refused, naming the type":
      let error = subscribe_error(skew = true)
      check "refused the subscription" in error
      check $Ed[int, int] in error

    test "a peer on another wire version gets a NAK, not silence":
      let host = free_addr()
      var authority = EdContext.init(id = "layout_auth2", listen_address = host)
      let reactor = new_reactor()
      let parts = host.split(":")
      let conn = reactor.connect(parts[0], parts[1].parse_int)
      reactor.send(conn, "ED\x01not-our-format")
      var reply = ""
      for _ in 0 ..< 200:
        reactor.tick
        authority.tick(blocking = false)
        for msg in reactor.messages:
          if msg.data.starts_with("NAK:"):
            reply = msg.data
        if reply != "":
          break
        sleep 5
      check "different ed wire versions" in reply
      authority.close

when is_main_module:
  Ed.bootstrap
  run()
