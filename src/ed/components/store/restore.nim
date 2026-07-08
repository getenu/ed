import std/[os, algorithm, tables, sets, strutils]
import ed/types {.all.}
import ed/zens/[contexts, private]
import ed/utils/[misc, logging, crc32]
import ed/components/subscriptions/core {.all.}
import ./format
import ./log as store_log

# Store open + restore + time-travel (docs/persistence.md). Restore feeds the
# newest valid snapshot and the log tail through `process_message` -- the same
# idempotent, frontier-guarded apply engine live sync uses -- with
# `ctx.replaying` set so the loopback/own-op guards stand down (entries carry
# our own id) and nothing re-publishes or re-appends. It must run before any
# subscriber attaches or type watcher registers, on the context's home thread.

privileged
log_defaults

proc load_snapshot(
    path: string, to_lsn: int64
): tuple[found: bool, manifest: Manifest, lines: seq[string]] =
  ## The newest fully-valid snapshot at or below `to_lsn`: manifest parses,
  ## every object file present with a matching crc. A damaged snapshot falls
  ## back to the previous one -- the log tail covers the gap.
  var snaps = scan_snapshots(path)
  snaps.reverse
  for (dir, lsn) in snaps.items:
    if lsn > to_lsn:
      continue
    let manifest_path = dir / "manifest.json"
    if not file_exists(manifest_path):
      continue
    let (ok, manifest) = parse_manifest(read_file(manifest_path))
    if not ok:
      warn "skipping snapshot with invalid manifest", dir
      continue
    if not manifest.platform_ok:
      raise StoreError.init(
        "store snapshot written on an incompatible platform: " & dir
      )
    var lines = new_seq[string](manifest.objects.len)
    var valid = true
    for i, entry in manifest.objects:
      let file = dir / entry.file
      if not file_exists(file):
        valid = false
        break
      let line = read_file(file).strip(leading = false, chars = {'\n'})
      if crc32_hex(line) != entry.crc:
        valid = false
        break
      lines[i] = line
    if not valid:
      warn "skipping snapshot with damaged object files", dir
      continue
    return (true, manifest, lines)

proc restore_state(
    self: EdContext, path: string, to_lsn: int64, allow_schema_mismatch = false
): tuple[max_lsn: int64, max_own_op: int64] =
  ## Snapshot + tail replay onto a fresh context, bounded by `to_lsn`
  ## (int64.high = everything). Caller sets/clears `replaying`.
  assert self.replaying
  var watermark = 0'i64
  let (found, manifest, lines) = load_snapshot(path, to_lsn)
  if found and manifest.schema != 0 and manifest.schema != ED_SCHEMA_VERSION and
      not allow_schema_mismatch:
    # The store was written by a build with a different app-schema version
    # (a persisted type changed shape). tid = hash(name) can't detect that per
    # object, so materializing would deserialize garbage silently. Refuse
    # loudly; `allow_schema_mismatch` is the "I know it's compatible" override.
    raise StoreError.init(
      "store schema version " & $manifest.schema & " != build's " &
        $ED_SCHEMA_VERSION & " (a persisted type changed); pass " &
        "allow_schema_mismatch = true to open anyway"
    )
  if not found:
    # No usable snapshot means the log must reach back to genesis, or the
    # restore would silently canonize a truncated world (retention prunes
    # early segments once a snapshot covers them; if every retained snapshot
    # is damaged, refusing to start is the only honest answer).
    let segments = scan_segments(path)
    if segments.len > 0 and segments[0].after_lsn > 0:
      raise StoreError.init(
        "no valid snapshot, and log history starts after lsn " &
          $segments[0].after_lsn & "; refusing a partial restore"
      )
  if found:
    # Children before parents (reverse manifest order), mirroring
    # add_subscriber's newest-first push: a parent's bin then links real
    # containers instead of placeholders.
    for i in countdown(lines.high, 0):
      let (ok, msg) = parse_entry(lines[i])
      if not ok:
        raise StoreError.init(
          "corrupt snapshot entry: " & manifest.objects[i].file
        )
      self.process_message(msg)
    watermark = manifest.lsn
    self.applied_lsn = manifest.lsn
    self.op_id_counter = manifest.op_id_counter
    result.max_lsn = manifest.lsn

  # Log tail: segments starting at or after the watermark, in (epoch, lsn)
  # name order. Segments from before it hold only covered ops -- and replaying
  # them would resurrect create/destroy pairs the snapshot already resolved
  # (a CREATE is unordered, so the frontier can't drop it; its DESTROY at
  # lsn <= watermark would be dropped -> zombie object).
  block tail:
    for seg in scan_segments(path):
      if found and seg.after_lsn < watermark:
        continue
      for msg in read_entries(seg.path):
        if msg.lsn > to_lsn:
          # Positional cut: state as of `to_lsn` is everything the log
          # recorded up to (and including) that stamped op.
          break tail
        if msg.lsn > 0:
          result.max_lsn = max(result.max_lsn, msg.lsn)
        if msg.origin == self.id and msg.op_id > 0:
          # Rebuild own-op reconciliation state (a later DESTROY deletes its
          # entry again -- set before applying).
          result.max_own_op = max(result.max_own_op, msg.op_id)
          self.latest_op_id[msg.object_id] = msg.op_id
        self.process_message(msg)

  # Counter hygiene. lsn_counter must clear every LSN the log ever stamped --
  # ops dropped during replay (a destroyed object's tail ops) never advanced
  # applied_lsn, so trust the scanned maximum, not the frontier. A reused LSN
  # would be stale-dropped by every surviving follower forever.
  self.applied_lsn = max(self.applied_lsn, result.max_lsn)
  self.lsn_counter = max(self.lsn_counter, result.max_lsn)
  self.op_id_counter = max(self.op_id_counter, result.max_own_op)

  # Registry order: restore materialized children-first, inverting insertion
  # order. add_subscriber pushes newest-first (reversed), so leave it inverted
  # and a post-restart subscriber gets parents before children -- breaking the
  # deferred-fill invariant (publish.nim). Rebuild manifest order, tail
  # arrivals after.
  if found:
    self.pack_objects
    var ordered: OrderedTable[string, ref EdBodyBase]
    for entry in manifest.objects:
      if entry.oid in self.objects:
        ordered[entry.oid] = self.objects[entry.oid]
    for id, body in self.objects:
      if id notin ordered:
        ordered[id] = body
    self.objects = ordered

proc open_store*(
    self: EdContext,
    path: string,
    snapshot_every = 0,
    durability = FlushPerTick,
    retain_snapshots = 2,
    allow_schema_mismatch = false,
): EdStore {.discardable.} =
  ## Attach a durable store to an authority context, restoring any existing
  ## state from it first. A post-init call, before anything subscribes and
  ## before the context holds objects (mirrors `subscribe`); everything the
  ## context does afterwards is logged. The registered-type set must match the
  ## build that wrote the store; opening a store whose `schema` slot differs
  ## from `ED_SCHEMA_VERSION` raises unless `allow_schema_mismatch` is set.
  do_assert self.is_authority,
    "only the authority context persists; a follower replicates from it"
  do_assert self.store == nil, "store already open"
  do_assert self.subscribers.len == 0,
    "open the store before anything subscribes"
  do_assert self.objects.len == 0,
    "open the store before creating objects"

  create_dir(path)
  create_dir(path / LOG_DIR)
  create_dir(path / SNAPSHOTS_DIR)
  for kind, p in walk_dir(path / SNAPSHOTS_DIR):
    if kind == pc_dir and p.extract_filename.starts_with("tmp-"):
      remove_dir(p) # crashed mid-snapshot; the manifest never sealed it

  # Epoch: strictly above anything this store has seen, so a zombie
  # incarnation's ops can never be mistaken for ours.
  var epoch = 0'i64
  for seg in scan_segments(path):
    epoch = max(epoch, seg.epoch)
  let head_path = path / "HEAD"
  if file_exists(head_path):
    let (ok, head) = parse_head(read_file(head_path))
    if ok:
      epoch = max(epoch, head.epoch)

  let store = EdStore(
    path: path,
    epoch: epoch + 1,
    durability: durability,
    snapshot_every: snapshot_every,
    retain_snapshots: max(1, retain_snapshots),
  )

  self.replaying = true
  try:
    discard self.restore_state(path, int64.high, allow_schema_mismatch)
  finally:
    self.replaying = false

  self.epoch = store.epoch
  self.seen_epoch = store.epoch
  let snaps = scan_snapshots(path)
  if snaps.len > 0:
    store.snapshot_name = SNAPSHOTS_DIR / snapshot_dir(snaps[^1].lsn)
  store.open_segment(after_lsn = self.lsn_counter)
  self.store = store
  store.write_head
  debug "store opened",
    path, epoch = store.epoch, objects = self.objects.len,
    lsn = self.lsn_counter
  result = store

proc replay*(
    _: type EdContext,
    path: string,
    to_lsn: int64 = int64.high,
    id = "replay-" & generate_id(),
    allow_schema_mismatch = false,
): EdContext =
  ## A read-only historical view of a store as of `to_lsn` -- the time-travel
  ## debug tool. Fresh non-authority context, no segment opened, no epoch
  ## bump, no HEAD write: it can coexist with the live authority on the same
  ## store directory. Writes on the view are local-only and never persisted.
  ## History below the retention horizon raises StoreError. A schema-version
  ## mismatch raises unless `allow_schema_mismatch` is set (inspecting an
  ## older-build store is a legitimate reason to override).
  let snaps = scan_snapshots(path)
  let segments = scan_segments(path)
  if to_lsn != int64.high:
    var reachable = segments.len > 0 and segments[0].after_lsn == 0
    for (_, lsn) in snaps.items:
      if lsn <= to_lsn:
        reachable = true
    if not reachable:
      raise StoreError.init(
        "lsn " & $to_lsn & " is below retained history; " &
          "increase retain_snapshots"
      )

  result = EdContext.init(id = id)
  result.store = EdStore(path: path, read_only: true)
  result.replaying = true
  try:
    discard result.restore_state(path, to_lsn, allow_schema_mismatch)
  finally:
    result.replaying = false
