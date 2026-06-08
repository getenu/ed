import std/[unittest, sets, tables, times, monotimes, strutils]
import ed
import ed/zens/contexts

type DeepOwner = ref object of EdRef
  items: EdSeq[int]
  val: EdValue[int]

type LazyOwner = ref object of EdRef
  # Mirrors enu's Build: a LAZY EdTable field next to a normal EdSeq field, both
  # owned. The LAZY table is first so that, if its serialization misaligns, the
  # EdSeq after it is the field that gets corrupted (which is what we saw: enu's
  # `units` collection went invalid after adding LAZY voxel-table fields).
  chunks: EdTable[int, string]
  items: EdSeq[int]

proc run*() =
  Ed.register(DeepOwner, false)
  Ed.register(LazyOwner, false)

  suite "partial replicas":
    test "a LAZY EdTable field on a registered ref doesn't corrupt its siblings":
      var authority = EdContext.init(id = "lzf_auth", is_authority = true)
      var client = EdContext.init(id = "lzf_client")
      Ed.thread_ctx = authority

      var u = LazyOwner(id: "lzf_u")
      u.own:
        u.chunks = EdTable[int, string].init(
          ctx = authority, id = "lzf_chunks", flags = DEFAULT_FLAGS + {LAZY}
        )
        u.items = EdSeq[int].init(ctx = authority, id = "lzf_items")
      u.chunks[1] = "x" # LAZY table has contents (paged per-key)
      u.items.add 5     # the canary sibling

      var units = EdSeq[LazyOwner].init(
        ctx = authority, id = "lzf_units", flags = DEFAULT_FLAGS + {OWNS_MEMBERS}
      )
      units.add u

      client.subscribe(
        authority, partial = true, fetch = ["lzf_units"], deep = true
      )
      client.tick()

      let m = EdSeq[LazyOwner](client["lzf_units"])[0]
      # The EdSeq sibling must survive the LAZY field intact (not destroyed /
      # misaligned by it).
      check m.items.valid
      check m.items.len == 1
      check m.items[0] == 5

    test "reload of a LAZY-field OWNS_MEMBERS member (full clone) keeps siblings valid":
      # The enu reload: a full-clone replica, an OWNS_MEMBERS member reused by id
      # while its owned tables get fresh ids — destroy the old incarnation, add a
      # new one. This is the path where the hoist corrupted the member's `units`
      # sibling, so reproduce it minimally.
      var authority = EdContext.init(id = "lzr_auth", is_authority = true)
      var client = EdContext.init(id = "lzr_client") # full clone
      Ed.thread_ctx = authority

      var units = EdSeq[LazyOwner].init(
        ctx = authority, id = "lzr_units", flags = DEFAULT_FLAGS + {OWNS_MEMBERS}
      )
      var u1 = LazyOwner(id: "lzr_m") # the reused EdRef id
      u1.own:
        u1.chunks = EdTable[int, string].init(
          ctx = authority, flags = DEFAULT_FLAGS + {LAZY} # generated id
        )
        u1.items = EdSeq[int].init(ctx = authority) # generated id
      u1.items.add 1
      units.add u1

      client.subscribe(authority)
      client.tick()
      authority.tick()
      client.tick()
      check EdSeq[LazyOwner](client["lzr_units"])[0].items[0] == 1

      # Reload: remove + destroy the old incarnation, add a fresh one (same EdRef
      # id, fresh table/seq ids — no container id reuse).
      units -= u1
      u1.destroy()
      var u2 = LazyOwner(id: "lzr_m")
      u2.own:
        u2.chunks = EdTable[int, string].init(
          ctx = authority, flags = DEFAULT_FLAGS + {LAZY}
        )
        u2.items = EdSeq[int].init(ctx = authority)
      u2.items.add 2
      units.add u2

      authority.tick()
      client.tick()
      authority.tick()
      client.tick()

      let m = EdSeq[LazyOwner](client["lzr_units"])[0]
      check m.items.valid # ← the corruption point in enu
      check m.items.len == 1
      check m.items[0] == 2

    test "OWNS_MEMBERS member closures push to partial subscribers, in order":
      var authority = EdContext.init(id = "omp_auth", is_authority = true)
      var client = EdContext.init(id = "omp_client")
      Ed.thread_ctx = authority

      var u1 = DeepOwner(id: "omp_u1")
      u1.own:
        u1.items = EdSeq[int].init(ctx = authority, id = "omp_u1_items")
      u1.items.add 5
      var units = EdSeq[DeepOwner].init(
        ctx = authority, id = "omp_units", flags = DEFAULT_FLAGS + {OWNS_MEMBERS}
      )
      units.add u1

      # The subscribe pushes u1's closure ahead of the collection: the client's
      # parse links the member's fields to real containers - no husks.
      client.subscribe(
        authority, partial = true, fetch = ["omp_units"], deep = true
      )
      client.tick()
      check "omp_u1_items" in client
      let m1 = EdSeq[DeepOwner](client["omp_units"])[0]
      check m1.items.len == 1
      check m1.items[0] == 5

      # A member added later: its closure precedes the ADD too.
      var u2 = DeepOwner(id: "omp_u2")
      u2.own:
        u2.items = EdSeq[int].init(ctx = authority, id = "omp_u2_items")
      u2.items.add 6
      units.add u2
      client.tick()
      check "omp_u2_items" in client
      let m2 = EdSeq[DeepOwner](client["omp_units"])[1]
      check m2.items.len == 1
      check m2.items[0] == 6

      # The closure joined the interest set: members keep syncing.
      u2.items.add 7
      client.tick()
      check m2.items.len == 2

    test "deep = false (default): no member closures, fetch what you touch":
      var authority = EdContext.init(id = "omd_auth", is_authority = true)
      var client = EdContext.init(id = "omd_client")
      Ed.thread_ctx = authority

      var u1 = DeepOwner(id: "omd_u1")
      u1.own:
        u1.items = EdSeq[int].init(ctx = authority, id = "omd_u1_items")
      var units = EdSeq[DeepOwner].init(
        ctx = authority, id = "omd_units", flags = DEFAULT_FLAGS + {OWNS_MEMBERS}
      )
      units.add u1

      # Narrow subscriber (an enu_mcp-style utility): the directory arrives,
      # the members' closures don't.
      client.subscribe(authority, partial = true, fetch = ["omd_units"])
      client.tick()
      check "omd_units" in client
      # The member's container arrives only as a placeholder stand-in (the
      # inline reference mints one) — its value was not pushed.
      check not client["omd_u1_items"].loaded

      # It pulls what it touches, explicitly.
      client.fetch("omd_u1", deep = true)
      authority.tick()
      client.tick()
      check client["omd_u1_items"].loaded
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

    test "fetch returns a handle that resolves Found with the object":
      var authority = EdContext.init(id = "fh_auth", is_authority = true)
      var client = EdContext.init(id = "fh_client")
      var x = EdValue[int].init(ctx = authority, id = "fh_x")
      x.value = 4
      client.subscribe(authority, partial = true, fetch = [])
      client.tick()

      let handle = client.fetch("fh_x")
      check handle.state == Pending
      authority.tick()
      client.tick()
      check handle.state == Found
      check handle.obj == client["fh_x"]

    test "fetching a missing id resolves NotFound (authority NACK)":
      var authority = EdContext.init(id = "nf_auth", is_authority = true)
      var client = EdContext.init(id = "nf_client")
      client.subscribe(authority, partial = true, fetch = [])
      client.tick()

      let handle = client.fetch("does_not_exist")
      check handle.state == Pending
      authority.tick()
      client.tick()
      check handle.state == NotFound
      check "does_not_exist" notin client

    test "follow (default): a missing fetch is delivered when created later":
      var authority = EdContext.init(id = "fl_auth", is_authority = true)
      var client = EdContext.init(id = "fl_client")
      client.subscribe(authority, partial = true, fetch = [])
      client.tick()

      let handle = client.fetch("late_obj")
      authority.tick()
      client.tick()
      check handle.state == NotFound # didn't exist at fetch time...

      var late = EdValue[int].init(ctx = authority, id = "late_obj")
      late.value = 9
      client.tick()
      check "late_obj" in client # ...but the kept interest delivered it
      check EdValue[int](client["late_obj"]).value == 9

    test "blocking ctx[] pulls an unknown id; a NACK fails fast":
      var authority = EdContext.init(id = "bk_auth", is_authority = true)
      var client = EdContext.init(id = "bk_client")
      var x = EdValue[int].init(ctx = authority, id = "bk_x")
      x.value = 7
      client.subscribe(authority, partial = true, fetch = [])
      client.tick()
      check "bk_x" notin client

      # Single-threaded choreography: queue the answer into the client's channel
      # first; the blocking read's pump then drains it (the fetch dedups onto
      # the in-flight handle rather than re-sending).
      discard client.fetch("bk_x")
      authority.tick()
      var got: ref EdBase
      client.blocking:
        got = client["bk_x"]
      check EdValue[int](got).value == 7

      # Unknown id: the NACK resolves the blocking wait promptly (KeyError),
      # well inside the pump's safety deadline.
      discard client.fetch("bk_missing")
      authority.tick()
      let started = get_mono_time()
      expect KeyError:
        client.blocking:
          discard client["bk_missing"]
      check get_mono_time() - started < init_duration(seconds = 2)

    test "request chaining: a hub forwards a miss and relays the answer":
      var a = EdContext.init(id = "ch_auth", is_authority = true)
      var b = EdContext.init(id = "ch_hub")
      var c = EdContext.init(id = "ch_leaf")
      var x = EdValue[int].init(ctx = a, id = "ch_x")
      x.value = 11
      b.subscribe(a, partial = true, fetch = [])
      b.tick()
      c.subscribe(b, partial = true, fetch = [])
      c.tick()
      check "ch_x" notin b # the hub doesn't have it either

      let handle = c.fetch("ch_x")
      b.tick() # hub: miss -> remembers the want, forwards upstream
      a.tick() # authority serves the hub
      b.tick() # hub materializes, serves the waiting leaf
      c.tick() # leaf receives
      check handle.state == Found
      check EdValue[int](c["ch_x"]).value == 11
      check "ch_x" in b # the hub holds it now too

    test "request chaining: an authority miss NACKs back down the chain":
      var a = EdContext.init(id = "chn_auth", is_authority = true)
      var b = EdContext.init(id = "chn_hub")
      var c = EdContext.init(id = "chn_leaf")
      b.subscribe(a, partial = true, fetch = [])
      b.tick()
      c.subscribe(b, partial = true, fetch = [])
      c.tick()

      let handle = c.fetch("chn_missing")
      b.tick() # forward
      a.tick() # authority: real miss -> NOT_FOUND
      b.tick() # relay to the waiter
      c.tick()
      check handle.state == NotFound

    test "request chaining: per-key through a placeholder hub":
      var a = EdContext.init(id = "chk_auth", is_authority = true)
      var b = EdContext.init(id = "chk_hub")
      var c = EdContext.init(id = "chk_leaf")
      var tbl = EdTable[int, string].init(ctx = a, id = "chk_tbl")
      tbl[1] = "one"
      var parent = EdSeq[EdValue[string]].init(ctx = a, id = "chk_parent")
      # Reference the table indirectly so partial subscribers mint placeholders
      # for it (the voxel topology: worker holds the table unloaded).
      var pointer_value = EdValue[string].init(ctx = a, id = "chk_ptr")
      parent += pointer_value
      b.subscribe(a, partial = true, fetch = ["chk_parent", "chk_tbl_ph"])
      b.tick()
      c.subscribe(b, partial = true, fetch = ["chk_parent"])
      c.tick()

      # Mint the placeholder relationship directly: leaf + hub hold the table
      # id but not its data.
      discard c.fetch("chk_tbl") # chains: b -> a; both materialize
      b.tick()
      a.tick()
      b.tick()
      c.tick()
      check "chk_tbl" in c
      let leaf_tbl = EdTable[int, string](c["chk_tbl"])
      check leaf_tbl.loaded(1) == false or leaf_tbl[1] == "one"
        # whole-object fetch may carry the value; the per-key path below is
        # exercised against key 2, added after the fetch
      tbl[2] = "two"
      b.tick() # hub may or may not see it (interest-dependent); leaf requests:
      leaf_tbl.request(2)
      c.tick() # flush the key request
      b.tick() # hub serves (if loaded) or chains
      a.tick() # authority serves
      b.tick() # hub applies + serves the waiter
      c.tick() # leaf applies
      check leaf_tbl.loaded(2)
      check leaf_tbl[2] == "two"

    test "LAZY containers arrive as pull-only handles (no contents)":
      var authority = EdContext.init(id = "lz_auth", is_authority = true)
      var client = EdContext.init(id = "lz_client")
      Ed.thread_ctx = authority
      var owner = DeepOwner(id: "lz_owner")
      owner.own:
        owner.items = EdSeq[int].init(ctx = authority, id = "lz_items")
        discard EdTable[int, string].init(
          ctx = authority, id = "lz_big", flags = DEFAULT_FLAGS + {LAZY}
        )
      EdTable[int, string](authority["lz_big"])[1] = "huge"

      client.subscribe(authority, partial = true, fetch = [])
      client.tick()
      discard client.fetch("lz_owner", deep = true)
      authority.tick()
      client.tick()
      check "lz_items" in client # normal container came with the closure
      check "lz_big" in client # LAZY came too — but only as a handle
      let big = EdTable[int, string](client["lz_big"])
      check not big.loaded # placeholder: shape unknown, entries page in
      check not big.loaded(1) # the entry did NOT ride along
      check big.value.len == 0 # and reading doesn't materialize (LAZY: no touch)

      discard client.fetch("lz_big") # explicit whole-table pull still works
      authority.tick()
      client.tick()
      check big.loaded
      check big[1] == "huge"

    test "per-key interest: requested keys stream, missing keys pop in":
      var authority = EdContext.init(id = "ki_auth", is_authority = true)
      var client = EdContext.init(id = "ki_client")
      Ed.thread_ctx = authority
      var owner = DeepOwner(id: "ki_owner")
      var tbl: EdTable[int, string]
      owner.own:
        tbl = EdTable[int, string].init(
          ctx = authority, id = "ki_tbl", flags = DEFAULT_FLAGS + {LAZY}
        )
      tbl[1] = "one"

      client.subscribe(authority, partial = true, fetch = [])
      client.tick()
      discard client.fetch("ki_owner", deep = true) # handle rides the closure
      authority.tick()
      client.tick()
      let ctbl = EdTable[int, string](client["ki_tbl"])
      check not ctbl.loaded(1) # handle only — entries page in on request

      # Requesting a present key loads it — and subscribes to it: a later
      # write to that key streams without re-requesting.
      ctbl.request(1)
      client.tick()
      authority.tick()
      client.tick()
      check ctbl.loaded(1)
      check ctbl[1] == "one"
      tbl[1] = "one, live"
      authority.tick()
      client.tick()
      check ctbl[1] == "one, live"

      # Requesting a missing key is a normal answer (empty space) — but the
      # interest sticks, so the key pops in when someone builds there.
      ctbl.request(2)
      client.tick()
      authority.tick()
      client.tick()
      check not ctbl.loaded(2)
      tbl[2] = "two"
      authority.tick()
      client.tick()
      check ctbl.loaded(2)
      check ctbl[2] == "two"

      # A key never requested doesn't stream.
      tbl[3] = "three"
      authority.tick()
      client.tick()
      check not ctbl.loaded(3)

    test "release: evicts locally, retracts upstream, downstream clones shed":
      var authority = EdContext.init(id = "rl_auth", is_authority = true)
      var pager = EdContext.init(id = "rl_pager")
      var clone = EdContext.init(id = "rl_clone")
      Ed.thread_ctx = authority
      var owner = DeepOwner(id: "rl_owner")
      var tbl: EdTable[int, string]
      owner.own:
        tbl = EdTable[int, string].init(
          ctx = authority, id = "rl_tbl", flags = DEFAULT_FLAGS + {LAZY}
        )
      tbl[1] = "one"

      pager.subscribe(authority, partial = true, fetch = [])
      pager.tick()
      clone.subscribe(pager) # full clone of the partial pager (a node ctx)
      clone.tick()
      discard pager.fetch("rl_owner", deep = true) # handle rides the closure
      authority.tick()
      pager.tick()
      clone.tick()
      let ptbl = EdTable[int, string](pager["rl_tbl"])
      let ntbl = EdTable[int, string](clone["rl_tbl"])
      check not ptbl.loaded(1) # handle only

      ptbl.request(1) # page in
      pager.tick()
      authority.tick()
      pager.tick()
      clone.tick()
      check ptbl.loaded(1)
      check ntbl.loaded(1) # the fill relayed to the clone

      ptbl.release(1) # page out
      check not ptbl.loaded(1) # evicted locally, immediately
      pager.tick() # flush the RELEASE broadcast
      authority.tick()
      clone.tick()
      check not ntbl.loaded(1) # eviction notice reached the clone

      tbl[1] = "one, unseen" # interest was retracted: this must NOT stream
      authority.tick()
      pager.tick()
      clone.tick()
      check not ptbl.loaded(1)
      check not ntbl.loaded(1)

      ptbl.request(1) # paging back in re-fetches and re-subscribes
      pager.tick()
      authority.tick()
      pager.tick()
      clone.tick()
      check ptbl[1] == "one, unseen"
      check ntbl[1] == "one, unseen"

    test "evictor: per-key release shrinks used_bytes (paging out frees mem)":
      # The voxel case: a LAZY table grows per-key as chunks page in, and
      # releasing a chunk must subtract exactly what it added — otherwise the
      # memory figure only ever climbs (the bug Scott saw: ed mem up on
      # move-in, never down on move-out).
      var authority = EdContext.init(id = "pk_auth", is_authority = true)
      var client = EdContext.init(id = "pk_client", mem_limit = 1024 * 1024)
      Ed.thread_ctx = authority
      var owner = DeepOwner(id: "pk_owner")
      var tbl: EdTable[int, string]
      owner.own:
        tbl = EdTable[int, string].init(
          ctx = authority, id = "pk_tbl", flags = DEFAULT_FLAGS + {LAZY}
        )
      tbl[1] = 'x'.repeat(200)
      tbl[2] = 'y'.repeat(200)

      client.subscribe(authority, partial = true, fetch = [])
      client.tick()
      discard client.fetch("pk_owner", deep = true) # the LAZY handle rides in
      authority.tick()
      client.tick()
      let ctbl = EdTable[int, string](client["pk_tbl"])
      check client.used_bytes == 0 # handle only, no entries yet

      ctbl.request(1)
      ctbl.request(2)
      client.tick()
      authority.tick()
      client.tick()
      check ctbl.loaded(1) and ctbl.loaded(2)
      let loaded = client.used_bytes
      check loaded >= 400 # both entries accounted

      ctbl.release(1) # page one chunk out
      client.tick()
      check not ctbl.loaded(1)
      check client.used_bytes < loaded # ...and the memory actually dropped
      check client.used_bytes >= 200 # the still-loaded entry remains accounted

    test "interest tiers: a downstream cache doesn't pin its hub (Option 2)":
      # A ← H ← L. L caches X with a big limit; that must NOT force H to hold X.
      # When L demotes X (it goes non-live), H may reclaim X under its own
      # pressure and invalidate L.
      var authority = EdContext.init(id = "it_auth", is_authority = true)
      var hub = EdContext.init(id = "it_hub", mem_limit = 200)
      var leaf = EdContext.init(id = "it_leaf", mem_limit = 10_000_000)
      Ed.thread_ctx = authority
      discard EdValue[string].init(ctx = authority, id = "it_x")
      EdValue[string](authority["it_x"]).value = 'z'.repeat(400)

      hub.subscribe(authority, partial = true, fetch = [])
      hub.tick()
      leaf.subscribe(hub, partial = true, fetch = [])
      leaf.tick()

      # L fetches X live (chains L→H→A); H holds it because L is live on it.
      var f = leaf.fetch("it_x")
      leaf.tick()
      hub.tick()
      authority.tick()
      hub.tick()
      leaf.tick()
      check "it_x" in leaf
      check "it_x" in hub # H holds X for live L
      # H must not evict X while L is live on it.
      hub.tick()
      check "it_x" in hub

      # L drops its live reference but keeps caching (big limit). It demotes X.
      f.obj = nil
      f = nil
      GC_full_collect()
      leaf.tick() # reconcile: X non-live here → demote upstream
      hub.tick() # H records X as cache-tier for L
      check "it_x" in leaf # L still caches it
      check "it_x" in hub

      # H is over its own budget (X is 400+ bytes, limit 200) and X is now
      # cache-tier (unprotected) — H sheds X and invalidates L.
      for i in 1 .. 4:
        hub.tick()
        leaf.tick()
      check "it_x" notin hub # H reclaimed it — not pinned by L's cache
      check "it_x" notin leaf # ...and invalidated L's cache

    test "mem_limit encoding: default budget, negative clamps, Unbounded holds":
      # Honest byte budget: a small default cache, negatives clamp to no-cache,
      # and Unbounded means never evict — the mirror image of the mem_limit 0
      # case below (there the dropped object is shed; here it's kept).
      check EdContext.init(id = "ml_def").mem_limit == DEFAULT_MEM_LIMIT
      check EdContext.init(id = "ml_neg", mem_limit = -5).mem_limit == 0

      var authority = EdContext.init(id = "ub_auth", is_authority = true)
      var client = EdContext.init(id = "ub_client", mem_limit = Unbounded)
      Ed.thread_ctx = authority
      discard EdValue[string].init(ctx = authority, id = "ub_x")
      EdValue[string](authority["ub_x"]).value = "hi"

      client.subscribe(authority, partial = true, fetch = [])
      client.tick()
      var f = client.fetch("ub_x")
      authority.tick()
      client.tick()
      check "ub_x" in client and f.obj != nil

      f.obj = nil
      f = nil # drop the reference — nothing is live now
      GC_full_collect()
      client.tick() # Unbounded: the sweep is a no-op, the cache holds it
      check "ub_x" in client # a finite limit / no-cache would have shed it

    test "evictor: mem_limit 0 evicts everything the moment it isn't live":
      # The no-cache mode for utility clients: a fetched object survives only
      # while a reference holds it; drop the reference and it's gone next sweep,
      # its interest retracted upstream.
      var authority = EdContext.init(id = "nc_auth", is_authority = true)
      var client = EdContext.init(id = "nc_client", mem_limit = 0)
      Ed.thread_ctx = authority
      discard EdValue[string].init(ctx = authority, id = "nc_x")
      EdValue[string](authority["nc_x"]).value = "hi"

      client.subscribe(authority, partial = true, fetch = [])
      client.tick()
      var f = client.fetch("nc_x")
      authority.tick()
      client.tick()
      check "nc_x" in client # held by the live handle
      check f.obj != nil

      f.obj = nil
      f = nil # drop the reference — nothing is live now
      GC_full_collect()
      client.tick() # no-cache sweep evicts it immediately
      check "nc_x" notin client

    test "evictor: pressure sheds the least-recently-read body":
      # mem_limit turns on the partial-replica evictor. Snapshot three bodies
      # we don't keep open, go over budget, and watch the stalest shed first.
      var authority = EdContext.init(id = "ev_auth", is_authority = true)
      var client = EdContext.init(id = "ev_client", mem_limit = 250)
      Ed.thread_ctx = authority
      discard EdValue[string].init(ctx = authority, id = "ev_1")
      discard EdValue[string].init(ctx = authority, id = "ev_2")
      discard EdValue[string].init(ctx = authority, id = "ev_3")
      EdValue[string](authority["ev_1"]).value = 'a'.repeat(100)
      EdValue[string](authority["ev_2"]).value = 'b'.repeat(100)
      EdValue[string](authority["ev_3"]).value = 'c'.repeat(100)

      client.subscribe(authority, partial = true, fetch = [])
      client.tick()
      # Fetch all three. On a leaf (no downstream), an object with no live
      # proxy is an eviction candidate regardless of our own upstream interest
      # — so dropping the handles makes them evictable. Hold the handles until
      # we're set up, then drop them (the app is done with them).
      var f1 = client.fetch("ev_1")
      var f2 = client.fetch("ev_2")
      var f3 = client.fetch("ev_3")
      authority.tick()
      client.tick()
      check "ev_1" in client and "ev_2" in client and "ev_3" in client
      check client.used_bytes >= 300

      # Read ev_2 and ev_3 (recently used); ev_1 is never read, so it stays the
      # stalest. Drop the handles and force ORC so the bodies read as unheld
      # (production reaches this as allocation drives collection).
      discard EdValue[string](client["ev_2"]).value
      discard EdValue[string](client["ev_3"]).value
      f1.obj = nil
      f2.obj = nil
      f3.obj = nil
      f1 = nil
      f2 = nil
      f3 = nil
      GC_full_collect()
      client.tick() # evict_sweep: over 250, sheds the stalest (ev_1) and stops
      check "ev_1" notin client # least-recently-read went
      check "ev_2" in client and "ev_3" in client # newer survive under budget
      check client.used_bytes <= 250

    test "caching hub keeps released keys; per-key LRU sheds under pressure":
      # A ← H(cache) ← L. L pages a chunk in then out; a caching hub keeps it
      # (so L's return is served from H, no refetch to A) until H's own budget
      # forces it out, least-recently-served first.
      var authority = EdContext.init(id = "ck_auth", is_authority = true)
      var hub = EdContext.init(id = "ck_hub", mem_limit = 600)
      var leaf = EdContext.init(id = "ck_leaf", mem_limit = 0)
      Ed.thread_ctx = authority
      var owner = DeepOwner(id: "ck_owner")
      var tbl: EdTable[int, string]
      owner.own:
        tbl = EdTable[int, string].init(
          ctx = authority, id = "ck_tbl", flags = DEFAULT_FLAGS + {LAZY}
        )
      tbl[1] = 'a'.repeat(200)
      tbl[2] = 'b'.repeat(200)
      tbl[3] = 'c'.repeat(200)

      hub.subscribe(authority, partial = true, fetch = [])
      hub.tick()
      leaf.subscribe(hub, partial = true, fetch = [])
      leaf.tick()
      # Both pull the owner's closure (the LAZY table arrives as a handle).
      discard hub.fetch("ck_owner", deep = true)
      authority.tick()
      hub.tick()
      discard leaf.fetch("ck_owner", deep = true) # chains to the hub
      leaf.tick()
      hub.tick()
      leaf.tick()
      let htbl = EdTable[int, string](hub["ck_tbl"])
      let ltbl = EdTable[int, string](leaf["ck_tbl"])

      # L pages key 1 in, then releases it (out of view).
      ltbl.request(1)
      leaf.tick()
      hub.tick()
      authority.tick()
      hub.tick()
      leaf.tick()
      check ltbl.loaded(1)
      check htbl.loaded(1)
      ltbl.release(1)
      leaf.tick()
      hub.tick()
      check not ltbl.loaded(1) # L (no-cache) dropped it
      check htbl.loaded(1) # ...but the caching hub KEPT it (no refetch on return)

      # Now drive H over its 600 budget: page in 2 and 3 too (still under after
      # 1+2+3 ≈ 600+? push past it). Least-recently-served (key 1) sheds first.
      ltbl.request(2)
      ltbl.request(3)
      leaf.tick()
      hub.tick()
      authority.tick()
      hub.tick()
      leaf.tick()
      for i in 1 .. 3:
        hub.tick()
      check htbl.loaded(2) and htbl.loaded(3) # live (L wants them) — protected
      check not htbl.loaded(1) # cache-tier + stalest → shed under pressure

    test "hub shedding: last retract releases the hub's copy upstream":
      # The enu client topology: authority (server) <- partial hub (worker)
      # <- full leaf (node ctx). The leaf drives paging; releases must shed
      # the hub's copy and chain the retract up, or the hub re-accumulates
      # a full replica and keeps paying for ops it no longer needs.
      var authority = EdContext.init(id = "hs_auth", is_authority = true)
      var hub = EdContext.init(id = "hs_hub", mem_limit = 0) # no-cache: shed now
      var leaf = EdContext.init(id = "hs_leaf")
      Ed.thread_ctx = authority
      var owner = DeepOwner(id: "hs_owner")
      var tbl: EdTable[int, string]
      owner.own:
        tbl = EdTable[int, string].init(
          ctx = authority, id = "hs_tbl", flags = DEFAULT_FLAGS + {LAZY}
        )
      tbl[1] = "one"

      hub.subscribe(authority, partial = true, fetch = [])
      hub.tick()
      leaf.subscribe(hub) # full clone of the partial hub
      leaf.tick()
      discard hub.fetch("hs_owner", deep = true)
      authority.tick()
      hub.tick()
      leaf.tick()
      let htbl = EdTable[int, string](hub["hs_tbl"])
      let ltbl = EdTable[int, string](leaf["hs_tbl"])

      ltbl.request(1) # leaf pages in: chains leaf -> hub -> authority
      leaf.tick() # flush the key request
      hub.tick() # miss: forward upstream
      authority.tick() # serve
      hub.tick() # apply + serve the waiting leaf
      leaf.tick() # apply
      check htbl.loaded(1) # the hub caches what it relayed
      check ltbl[1] == "one"

      ltbl.release(1) # leaf pages out
      check not ltbl.loaded(1)
      leaf.tick() # flush the RELEASE to the hub
      hub.tick() # retract leaf + shed own copy + queue the chained release
      hub.tick() # flush it upstream
      authority.tick() # retract the hub's interest
      leaf.tick()
      check not htbl.loaded(1) # hub shed its copy

      tbl[1] = "one, unseen" # nobody is interested: must not stream
      authority.tick()
      hub.tick()
      leaf.tick()
      check not htbl.loaded(1)
      check not ltbl.loaded(1)

      ltbl.request(1) # paging back in re-chains end to end
      leaf.tick()
      hub.tick()
      authority.tick()
      hub.tick()
      leaf.tick()
      check htbl[1] == "one, unseen"
      check ltbl[1] == "one, unseen"

    test "paging out drops an entry's nested container bodies":
      # The chunk_deltas case: each entry's value is its own container. Before
      # phase 3 the seq stayed pinned in ctx.objects after eviction; now the
      # registry releases it (the stats screen's object count follows paging),
      # and re-paging-in resolves a fresh body.
      var authority = EdContext.init(id = "nb_auth", is_authority = true)
      var client = EdContext.init(id = "nb_client")
      Ed.thread_ctx = authority
      var owner = DeepOwner(id: "nb_owner")
      var tbl: EdTable[int, EdSeq[int]]
      owner.own:
        tbl = EdTable[int, EdSeq[int]].init(
          ctx = authority, id = "nb_tbl", flags = DEFAULT_FLAGS + {LAZY}
        )
      var entry = EdSeq[int].init(ctx = authority, id = "nb_entry")
      entry.add 7
      tbl[1] = entry

      client.subscribe(authority, partial = true, fetch = [])
      client.tick()
      discard client.fetch("nb_owner", deep = true)
      authority.tick()
      client.tick()
      let ctbl = EdTable[int, EdSeq[int]](client["nb_tbl"])

      ctbl.request(1)
      client.tick()
      authority.tick()
      client.tick()
      check ctbl.loaded(1)
      check "nb_entry" in client # the nested seq came with the entry

      ctbl.release(1)
      check not ctbl.loaded(1)
      check "nb_entry" notin client # ...and leaves the registry with it

      client.tick() # flush the release upstream
      authority.tick()
      check "nb_entry" in authority # eviction is local; the authority keeps it

      ctbl.request(1) # paging back in restores entry + nested seq
      client.tick()
      authority.tick()
      client.tick()
      check ctbl.loaded(1)
      check "nb_entry" in client
      check ctbl[1][0] == 7

    test "per-key chain outruns the closure push (handle-first replies)":
      # A leaf can request keys before the hub holds the table (the closure
      # push carrying the LAZY handle hasn't landed). Without handle-first
      # replies the per-key ADD drops at the hub as an op for a missing
      # object, the want dangles (only the first want per key forwards), and
      # the entry never loads — the invisible-tower bug.
      var authority = EdContext.init(id = "hf_auth", is_authority = true)
      var hub = EdContext.init(id = "hf_hub")
      var leaf = EdContext.init(id = "hf_leaf")
      Ed.thread_ctx = authority
      var tbl = EdTable[int, string].init(
        ctx = authority, id = "hf_tbl", flags = DEFAULT_FLAGS + {LAZY}
      )
      tbl[1] = "one"

      hub.subscribe(authority, partial = true, fetch = [])
      hub.tick()
      leaf.subscribe(hub)
      leaf.tick()
      # The leaf knows the table only by its derived id — neither it nor the
      # hub holds the container.
      let ltbl = EdTable[int, string].init_placeholder(leaf, "hf_tbl")
      check "hf_tbl" notin hub

      ltbl.request(1)
      leaf.tick() # flush: chains through the hub, which lacks the table
      hub.tick() # miss: forward upstream
      authority.tick() # serve: handle first, then the entry
      hub.tick() # apply handle + entry; serve the waiting leaf
      leaf.tick() # apply
      check "hf_tbl" in hub
      check EdTable[int, string](hub["hf_tbl"]).loaded(1)
      check ltbl[1] == "one"

    test "per-key replies carry nested containers (chunk-deep)":
      var authority = EdContext.init(id = "kd_auth", is_authority = true)
      var client = EdContext.init(id = "kd_client")
      Ed.thread_ctx = authority
      var owner = DeepOwner(id: "kd_owner")
      var tbl: EdTable[int, EdSeq[int]]
      owner.own:
        tbl = EdTable[int, EdSeq[int]].init(
          ctx = authority, id = "kd_tbl", flags = DEFAULT_FLAGS + {LAZY}
        )
      client.subscribe(authority, partial = true, fetch = [])
      client.tick()
      discard client.fetch("kd_owner", deep = true) # LAZY handle rides the closure
      authority.tick()
      client.tick()
      check "kd_tbl" in client

      var entry = EdSeq[int].init(ctx = authority, id = "kd_entry")
      entry.add 7
      tbl[1] = entry # LAZY + no per-key interest: not streamed
      client.tick()
      let ctbl = EdTable[int, EdSeq[int]](client["kd_tbl"])
      check not ctbl.loaded(1)

      ctbl.request(1)
      client.tick() # flush the key request
      authority.tick() # serve: nested seq first, then the entry
      client.tick() # apply
      check ctbl.loaded(1)
      check "kd_entry" in client
      check EdSeq[int](client["kd_entry"]).len == 1 # nested arrived loaded
      check ctbl[1][0] == 7 # and the entry links to it

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
