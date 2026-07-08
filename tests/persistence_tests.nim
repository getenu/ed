import std/[unittest, os, strutils, tables, sets]
import ed
import ed/types {.all.} # Message, for the entry-format tests
import ed/utils/crc32
import ed/zens/contexts
import ed/components/subscriptions/core {.all.} # process_message, for the
                                                # hostile-epoch test

proc store_dir(): string =
  result = get_temp_dir() / "ed_store_" & generate_id()

proc read_log(path: string): string =
  ## Concatenated content of every segment, for greppability assertions.
  for kind, p in walk_dir(path / "log"):
    if kind == pc_file:
      result.add read_file(p)

proc run*() =
  suite "persistence":
    test "append + restore roundtrip":
      let path = store_dir()
      defer:
        remove_dir(path)
      var a = EdContext.init(id = "p1_auth", is_authority = true)
      a.open_store(path)
      var value = EdValue[int].init(ctx = a, id = "p1_value")
      var s = EdSeq[string].init(ctx = a, id = "p1_seq")
      var t = EdTable[string, int].init(ctx = a, id = "p1_table")
      value.value = 42
      s.add "one"
      s.add "two"
      t["k"] = 7
      let lsn = a.lsn_counter
      check lsn > 0
      a.destroy()

      var b = EdContext.init(id = "p1_auth", is_authority = true)
      b.open_store(path)
      check EdValue[int](b["p1_value"]).value == 42
      check EdSeq[string](b["p1_seq"]).len == 2
      check "two" in EdSeq[string](b["p1_seq"])
      check EdTable[string, int](b["p1_table"])["k"] == 7
      # Counters continue: a new write stamps a strictly higher LSN.
      check b.lsn_counter == lsn
      EdValue[int](b["p1_value"]).value = 43
      check b.lsn_counter > lsn
      b.destroy()

    test "own-origin collection ops survive replay (no delta-skip)":
      # Regression for the own-op superseded rule: without the replaying
      # bypass, every self-originated delta op is silently dropped on replay.
      let path = store_dir()
      defer:
        remove_dir(path)
      var a = EdContext.init(id = "p2_auth", is_authority = true)
      a.open_store(path)
      var s = EdSeq[int].init(ctx = a, id = "p2_seq")
      s.add 1
      s.add 2
      s.add 3
      a.destroy()

      var b = EdContext.init(id = "p2_auth", is_authority = true)
      b.open_store(path)
      check EdSeq[int](b["p2_seq"]).len == 3
      check EdSeq[int](b["p2_seq"])[2] == 3
      b.destroy()

    test "content created with zero subscribers is captured":
      # The headless-authority case: publish_changes used to early-out with no
      # subscribers, so nothing would be built/stamped/logged.
      let path = store_dir()
      defer:
        remove_dir(path)
      var a = EdContext.init(id = "p3_auth", is_authority = true)
      a.open_store(path)
      var value = EdValue[string].init(ctx = a, id = "p3_value")
      value.value = "durable"
      check a.lsn_counter > 0 # stamped despite zero subscribers
      a.destroy()

      var b = EdContext.init(id = "p3_auth", is_authority = true)
      b.open_store(path)
      check EdValue[string](b["p3_value"]).value == "durable"
      b.destroy()

    test "torn tail is dropped; state as of last valid entry":
      let path = store_dir()
      defer:
        remove_dir(path)
      var a = EdContext.init(id = "p4_auth", is_authority = true)
      a.open_store(path)
      var value = EdValue[int].init(ctx = a, id = "p4_value")
      value.value = 1
      value.value = 2
      let segment = path / a.store.segment_name
      a.destroy()

      # Simulate a mid-write crash: half a line at the end of the segment.
      let f = open(segment, fm_append)
      f.write("{\"v\":1,\"epo")
      f.close

      var b = EdContext.init(id = "p4_auth", is_authority = true)
      b.open_store(path)
      check EdValue[int](b["p4_value"]).value == 2
      EdValue[int](b["p4_value"]).value = 3 # appends still work
      b.destroy()

    test "mid-file corruption raises StoreError":
      let path = store_dir()
      defer:
        remove_dir(path)
      var a = EdContext.init(id = "p5_auth", is_authority = true)
      a.open_store(path)
      var value = EdValue[int].init(ctx = a, id = "p5_value")
      value.value = 1
      value.value = 2
      let segment = path / a.store.segment_name
      a.destroy()

      var lines = read_file(segment).strip(leading = false).split('\n')
      check lines.len >= 3
      lines[1] = "garbage line"
      write_file(segment, lines.join("\n") & "\n")

      var b = EdContext.init(id = "p5_auth", is_authority = true)
      expect StoreError:
        b.open_store(path)
      b.destroy()

    test "snapshot + tail restore (pre-snapshot segments not needed)":
      let path = store_dir()
      defer:
        remove_dir(path)
      var a = EdContext.init(id = "p6_auth", is_authority = true)
      a.open_store(path)
      var s = EdSeq[int].init(ctx = a, id = "p6_seq")
      s.add 1
      s.add 2
      let genesis_segment = path / a.store.segment_name
      a.snapshot()
      s.add 3 # tail, after the watermark
      a.destroy()

      # Prove restore uses the snapshot: the pre-snapshot segment (which holds
      # the CREATE and the first two adds) is gone.
      remove_file(genesis_segment)

      var b = EdContext.init(id = "p6_auth", is_authority = true)
      b.open_store(path)
      check EdSeq[int](b["p6_seq"]).len == 3
      check EdSeq[int](b["p6_seq"])[2] == 3
      b.destroy()

    test "snapshot_every auto-triggers; retention prunes":
      let path = store_dir()
      defer:
        remove_dir(path)
      var a = EdContext.init(id = "p7_auth", is_authority = true)
      a.open_store(path, snapshot_every = 5, retain_snapshots = 1)
      var value = EdValue[int].init(ctx = a, id = "p7_value")
      for i in 1 .. 12:
        value.value = i
        a.tick()
      var snapshots: seq[string]
      for kind, p in walk_dir(path / "snapshots"):
        if kind == pc_dir:
          snapshots.add p.extract_filename
      check snapshots.len == 1 # retention pruned the older one
      # Covered segments went with it: only segments at/after the retained
      # watermark (plus the active one) remain.
      var segments: seq[string]
      for kind, p in walk_dir(path / "log"):
        if kind == pc_file:
          segments.add p.extract_filename
      check segments.len <= 2
      a.destroy()

      var b = EdContext.init(id = "p7_auth", is_authority = true)
      b.open_store(path)
      check EdValue[int](b["p7_value"]).value == 12
      b.destroy()

    test "replay_to materializes historical state; views never persist":
      let path = store_dir()
      defer:
        remove_dir(path)
      var a = EdContext.init(id = "p8_auth", is_authority = true)
      a.open_store(path)
      var value = EdValue[int].init(ctx = a, id = "p8_value")
      var lsns: seq[int64]
      for i in 1 .. 5:
        value.value = i * 10
        lsns.add a.lsn_counter
      a.destroy()

      let view = EdContext.replay(path, to_lsn = lsns[2])
      check EdValue[int](view["p8_value"]).value == 30
      check not view.is_authority
      # A write on the view is local-only.
      EdValue[int](view["p8_value"]).value = 999
      view.destroy()

      var b = EdContext.init(id = "p8_auth", is_authority = true)
      b.open_store(path)
      check EdValue[int](b["p8_value"]).value == 50 # 999 never persisted
      b.destroy()

    test "replay_to below retained history raises":
      let path = store_dir()
      defer:
        remove_dir(path)
      var a = EdContext.init(id = "p9_auth", is_authority = true)
      a.open_store(path, retain_snapshots = 1)
      var value = EdValue[int].init(ctx = a, id = "p9_value")
      value.value = 1
      let early_lsn = a.lsn_counter
      value.value = 2
      a.snapshot()
      value.value = 3
      a.snapshot() # second snapshot; retention drops the first + its segments
      a.destroy()

      expect StoreError:
        discard EdContext.replay(path, to_lsn = early_lsn)

    test "epoch bumps per reopen and is stamped into entries":
      let path = store_dir()
      defer:
        remove_dir(path)
      var a = EdContext.init(id = "p10_auth", is_authority = true)
      let store_a = a.open_store(path)
      check store_a.epoch == 1
      var value = EdValue[int].init(ctx = a, id = "p10_value")
      value.value = 1
      a.destroy()

      var b = EdContext.init(id = "p10_auth", is_authority = true)
      let store_b = b.open_store(path)
      check store_b.epoch == 2
      EdValue[int](b["p10_value"]).value = 2
      b.destroy()

      let log = read_log(path)
      check "\"epoch\":1" in log
      check "\"epoch\":2" in log

    test "follower adopts a restarted authority's timeline (epoch reset)":
      let path = store_dir()
      defer:
        remove_dir(path)
      var a = EdContext.init(id = "p11_auth", is_authority = true)
      a.open_store(path)
      var follower = EdContext.init(id = "p11_follower")
      follower.subscribe(a)
      var value = EdValue[int].init(ctx = a, id = "p11_value")
      for i in 1 .. 5:
        value.value = i
      follower.tick()
      check follower.applied_lsn == 5
      let last_segment = path / a.store.segment_name
      a.destroy()

      # Crash that loses the durable tail: the restarted authority legitimately
      # reissues LSNs the follower already applied -- under a new epoch.
      remove_file(last_segment)

      var b = EdContext.init(id = "p11_auth", is_authority = true)
      b.open_store(path)
      check b.lsn_counter == 0 # tail lost; timeline restarts
      follower.subscribe(b)
      var value2 = EdValue[int].init(ctx = b, id = "p11_value2")
      value2.value = 77 # stamps lsn 1/2, epoch 2 -- below the follower's old frontier
      follower.tick()
      # Without the epoch-aware frontier reset these would be stale-dropped
      # forever (applied_lsn was 5).
      check "p11_value2" in follower
      check EdValue[int](follower["p11_value2"]).value == 77
      b.destroy()
      follower.destroy()

    test "restore refuses truncated history (no snapshot, pruned genesis)":
      let path = store_dir()
      defer:
        remove_dir(path)
      var a = EdContext.init(id = "p20_auth", is_authority = true)
      a.open_store(path)
      var value = EdValue[int].init(ctx = a, id = "p20_value")
      value.value = 1
      let genesis_segment = path / a.store.segment_name
      a.snapshot()
      value.value = 2
      a.destroy()

      # Damage the only snapshot AND remove pre-watermark history: restoring
      # just the tail would silently canonize a near-empty world.
      write_file(path / "snapshots" / "000000000000001" / "manifest.json", "x")
      remove_file(genesis_segment)

      var b = EdContext.init(id = "p20_auth", is_authority = true)
      expect StoreError:
        b.open_store(path)
      b.destroy()

    test "re-snapshot at an unchanged watermark keeps the existing snapshot":
      let path = store_dir()
      defer:
        remove_dir(path)
      var a = EdContext.init(id = "p21_auth", is_authority = true)
      a.open_store(path)
      var value = EdValue[int].init(ctx = a, id = "p21_value")
      value.value = 1
      let first = a.snapshot()
      # No stamped ops since (a CREATE-only append doesn't move the
      # watermark): the second snapshot must not delete-and-rewrite the only
      # retained snapshot -- a crash mid-replace would lose it.
      discard EdValue[int].init(ctx = a, id = "p21_extra")
      let second = a.snapshot()
      check second == first
      check file_exists(first / "manifest.json")
      a.destroy()

      var b = EdContext.init(id = "p21_auth", is_authority = true)
      b.open_store(path)
      check EdValue[int](b["p21_value"]).value == 1
      check "p21_extra" in b # CREATE-only tail replays over the kept snapshot
      b.destroy()

    test "a non-upstream peer can't reset the frontier with a hostile epoch":
      var leader = EdContext.init(id = "p22_auth", is_authority = true)
      var follower = EdContext.init(id = "p22_follower")
      follower.subscribe(leader)
      var value = EdValue[int].init(ctx = leader, id = "p22_value")
      for i in 1 .. 3:
        value.value = i
      follower.tick()
      check follower.applied_lsn == 3

      # A stamped op claiming a huge epoch, from a source that is not our
      # upstream: the frontier must hold, or redelivered delta ops below it
      # would re-apply (duplicated seq/set items).
      var hostile = Message(
        kind: ASSIGN,
        object_id: "p22_value",
        lsn: 1,
        epoch: int64.high,
        origin: "stranger",
      )
      hostile.source_set = ["stranger"].to_hash_set
      follower.process_message(hostile)
      check follower.applied_lsn == 3 # unchanged
      check follower.seen_epoch < int64.high
      leader.destroy()
      follower.destroy()

    test "clear raises on a store-backed authority":
      let path = store_dir()
      defer:
        remove_dir(path)
      var a = EdContext.init(id = "p23_auth", is_authority = true)
      a.open_store(path)
      expect StoreError:
        a.clear()
      a.destroy()

    test "destroy tombstone survives restore; same-id recreate replays":
      let path = store_dir()
      defer:
        remove_dir(path)
      var a = EdContext.init(id = "p13_auth", is_authority = true)
      a.open_store(path)
      var doomed = EdValue[int].init(ctx = a, id = "p13_doomed")
      doomed.value = 1
      a.snapshot()
      doomed.destroy() # tail op
      var phoenix = EdValue[int].init(ctx = a, id = "p13_phoenix")
      phoenix.value = 1
      phoenix.destroy()
      var phoenix2 = EdValue[int].init(ctx = a, id = "p13_phoenix")
      phoenix2.value = 2
      a.destroy()

      var b = EdContext.init(id = "p13_auth", is_authority = true)
      b.open_store(path)
      check "p13_doomed" notin b
      check "p13_phoenix" in b
      check EdValue[int](b["p13_phoenix"]).value == 2
      b.destroy()

    test "nested + owned objects restore linked; new follower gets a working replica":
      let path = store_dir()
      defer:
        remove_dir(path)
      var a = EdContext.init(id = "p14_auth", is_authority = true)
      a.open_store(path)
      var tbl = EdTable[string, EdSeq[int]].init(ctx = a, id = "p14_tbl")
      var inner = EdSeq[int].init(ctx = a, id = "p14_inner")
      tbl["k"] = inner
      inner.add 42
      "p14_owner".own:
        discard EdValue[int].init(ctx = a, id = "p14_owned")
      a.snapshot()
      a.destroy()

      var b = EdContext.init(id = "p14_auth", is_authority = true)
      b.open_store(path)
      let restored = EdTable[string, EdSeq[int]](b["p14_tbl"])
      check restored["k"].id == "p14_inner"
      check not restored["k"].body.placeholder # linked, not a husk
      check restored["k"][0] == 42
      check "p14_owner" in b.owned_by # ownership index rebuilt
      check "p14_owned" in b.owned_by["p14_owner"]

      # A fresh follower subscribing to the restored authority must receive a
      # dependency-ordered push (exercises the registry re-order).
      var follower = EdContext.init(id = "p14_follower")
      follower.subscribe(b)
      follower.tick()
      let mirrored = EdTable[string, EdSeq[int]](follower["p14_tbl"])
      check mirrored["k"][0] == 42
      b.destroy()
      follower.destroy()

    test "packed multi-op changes log as one entry and restore":
      let path = store_dir()
      defer:
        remove_dir(path)
      var a = EdContext.init(id = "p15_auth", is_authority = true)
      a.open_store(path)
      var t = EdTable[string, int].init(ctx = a, id = "p15_table")
      t.value = {"a": 1, "b": 2, "c": 3}.to_table # one changeset, packed
      a.destroy()

      check "\"kind\":\"PACKED\"" in read_log(path)

      var b = EdContext.init(id = "p15_auth", is_authority = true)
      b.open_store(path)
      check EdTable[string, int](b["p15_table"]).len == 3
      check EdTable[string, int](b["p15_table"])["b"] == 2
      b.destroy()

    test "a follower-originated op is captured exactly once":
      let path = store_dir()
      defer:
        remove_dir(path)
      var a = EdContext.init(id = "p16_auth", is_authority = true)
      a.open_store(path)
      var follower = EdContext.init(id = "p16_follower")
      follower.subscribe(a)
      var s = EdSeq[int].init(ctx = a, id = "p16_seq")
      follower.tick()
      EdSeq[int](follower["p16_seq"]).add 42
      a.tick() # authority orders + appends the follower's op
      follower.tick()

      check read_log(path).count("\"origin\":\"p16_follower\"") == 1
      a.destroy()
      follower.destroy()

      var b = EdContext.init(id = "p16_auth", is_authority = true)
      b.open_store(path)
      check EdSeq[int](b["p16_seq"]).len == 1
      b.destroy()

    test "open_store guards: non-authority, non-empty, stale tmp dirs":
      let path = store_dir()
      defer:
        remove_dir(path)
      var follower = EdContext.init(id = "p17_follower")
      expect AssertionDefect:
        follower.open_store(path)

      var busy = EdContext.init(id = "p17_busy", is_authority = true)
      discard EdValue[int].init(ctx = busy, id = "p17_value")
      expect AssertionDefect:
        busy.open_store(path)
      busy.destroy()

      # A crashed-mid-snapshot tmp dir is deleted and ignored on open.
      create_dir(path / "snapshots" / "tmp-000000000000009")
      write_file(path / "snapshots" / "tmp-000000000000009" / "junk", "x")
      var a = EdContext.init(id = "p17_auth", is_authority = true)
      a.open_store(path)
      check not dir_exists(path / "snapshots" / "tmp-000000000000009")
      a.destroy()

    test "schema gate: matching version reopens with no false positive":
      let path = store_dir()
      defer:
        remove_dir(path)
      var a = EdContext.init(id = "p24_auth", is_authority = true)
      a.open_store(path)
      var value = EdValue[int].init(ctx = a, id = "p24_value")
      value.value = 1
      a.snapshot()
      a.destroy()
      # Same build -> manifest.schema == ED_SCHEMA_VERSION -> opens cleanly.
      var b = EdContext.init(id = "p24_auth", is_authority = true)
      b.open_store(path)
      check EdValue[int](b["p24_value"]).value == 1
      b.destroy()

    test "schema gate: mismatched version refuses; override opens":
      let path = store_dir()
      defer:
        remove_dir(path)
      var a = EdContext.init(id = "p25_auth", is_authority = true)
      a.open_store(path)
      var value = EdValue[int].init(ctx = a, id = "p25_value")
      value.value = 1
      let snap = a.snapshot()
      a.destroy()

      # Simulate a store written by a build with a different schema version:
      # rewrite the manifest's schema field, re-sealed so its crc stays valid.
      let manifest_path = snap / "manifest.json"
      let (ok, m) = parse_manifest(read_file(manifest_path))
      check ok
      var bumped = m
      bumped.schema = ED_SCHEMA_VERSION + 1
      write_file(manifest_path, to_manifest(bumped) & "\n")

      var b = EdContext.init(id = "p25_auth", is_authority = true)
      expect StoreError:
        b.open_store(path)
      b.destroy()

      # The override opens it anyway.
      var c = EdContext.init(id = "p25_auth", is_authority = true)
      c.open_store(path, allow_schema_mismatch = true)
      check EdValue[int](c["p25_value"]).value == 1
      c.destroy()

    test "entry format: roundtrip, crc rejection, forward compat":
      var msg = Message(
        kind: ASSIGN,
        object_id: "obj-1",
        type_id: 12345,
        obj: "\x00\x01\xff binary \n bytes",
        key_bin: "\xde\xad",
        flags: {SYNC_LOCAL, SYNC_REMOTE},
        epoch: 2,
        lsn: 43,
        op_id: 7,
        origin: "ctx-a",
        delta: true,
      )
      let line = msg.to_entry_line
      let (ok, parsed) = parse_entry(line)
      check ok
      check parsed.kind == ASSIGN
      check parsed.object_id == "obj-1"
      check parsed.obj == msg.obj
      check parsed.key_bin == msg.key_bin
      check parsed.flags == msg.flags
      check parsed.epoch == 2
      check parsed.lsn == 43
      check parsed.op_id == 7
      check parsed.origin == "ctx-a"
      check parsed.delta

      # Any corrupted byte fails the crc.
      var corrupt = line
      corrupt[10] = if corrupt[10] == 'x': 'y' else: 'x'
      check not parse_entry(corrupt).ok

      # Unknown fields from a future writer are tolerated (crc intact).
      let idx = line.rfind(",\"crc\":\"")
      let extended = line[0 ..< idx] & ",\"future\":1"
      let resealed =
        extended & ",\"crc\":\"" & crc32_hex(extended) & "\"}"
      check parse_entry(resealed).ok

    test "manifest format: roundtrip + platform guard":
      var m = Manifest.init(epoch = 2, lsn = 42, op_id_counter = 17)
      m.objects.add ManifestEntry(
        file: "obj-000001-x.json", oid: "x", tid: 99, crc: "deadbeef"
      )
      let (ok, parsed) = parse_manifest(m.to_manifest)
      check ok
      check parsed.lsn == 42
      check parsed.op_id_counter == 17
      check parsed.objects.len == 1
      check parsed.objects[0].oid == "x"
      check parsed.platform_ok

      var alien = m
      alien.endian = "mixed"
      let (ok2, parsed2) = parse_manifest(alien.to_manifest)
      check ok2
      check not parsed2.platform_ok

when is_main_module:
  Ed.bootstrap
  run()
