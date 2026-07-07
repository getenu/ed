import std/[os, algorithm, tables]
import ed/[core, types {.all.}]
import ed/zens/[contexts, private]
import ed/utils/[logging, crc32]
import ./format, ./log

# Snapshot writing + retention (docs/persistence.md). A snapshot is a
# directory of per-object files (each one CREATE-shaped entry line, full
# contents) sealed by a manifest written last -- the manifest is the commit
# marker, so a crash mid-snapshot leaves an ignorable tmp dir, never a
# half-trusted snapshot. The active segment rotates at the watermark, so every
# non-active segment is immutable.

privileged

proc write_file_synced(path, content: string) =
  var f = open(path, fm_write)
  try:
    f.write(content)
    f.fsync_file
  finally:
    f.close

when defined(posix):
  import std/posix

  proc fsync_dir(path: string) =
    let fd = posix.open(path.cstring, O_RDONLY)
    if fd >= 0:
      discard fsync(fd)
      discard close(fd)

else:
  proc fsync_dir(path: string) =
    discard

proc prune_retention(store: EdStore) =
  ## Keep the newest `retain_snapshots` snapshot dirs; older ones go, along
  ## with every segment fully covered by the oldest retained watermark.
  ## Retention bounds replay_to: history below it is gone.
  let snaps = scan_snapshots(store.path)
  if snaps.len <= store.retain_snapshots:
    return
  let oldest_kept = snaps[snaps.len - store.retain_snapshots].lsn
  for (dir, lsn) in snaps.items:
    if lsn < oldest_kept:
      remove_dir(dir)
  let segments = scan_segments(store.path)
  for i, seg in segments:
    # A segment is disposable once a *later* segment starts at or below the
    # oldest retained watermark -- everything in it predates retained history.
    # The active segment is never a candidate (nothing starts after it).
    if i + 1 < segments.len and segments[i + 1].after_lsn <= oldest_kept:
      remove_file(seg.path)

proc snapshot*(self: EdContext): string {.discardable.} =
  ## Write a full-state snapshot at the current watermark, rotate the segment,
  ## prune retention. Returns the snapshot directory.
  log_defaults
  do_assert self.logs_ops,
    "snapshot requires an authority with a writable store"
  self.pack_objects
  let store = self.store
  # The authority applies its own writes synchronously and appends at stamp
  # time, so every op <= lsn_counter is already in the log -- lsn_counter *is*
  # the watermark. (applied_lsn is wrong here: the authority never advances it
  # for its own stamps.)
  let watermark = self.lsn_counter
  # The log must durably contain everything <= watermark before a snapshot
  # claims to cover it.
  store.commit

  var manifest = Manifest.init(store.epoch, watermark, self.op_id_counter)
  let final_name = SNAPSHOTS_DIR / snapshot_dir(watermark)
  let tmp_dir = store.path / SNAPSHOTS_DIR / ("tmp-" & snapshot_dir(watermark))
  let final_dir = store.path / final_name

  # A valid snapshot at this watermark already covers current state: anything
  # since it (lsn-0 CREATEs -- stamped ops would have moved the watermark)
  # lives in the post-rotation segments and replays as tail. Keep it --
  # replacing it would open a crash window between delete and rename where the
  # only retained snapshot is gone and its covered segments are already pruned.
  if dir_exists(final_dir) and
      file_exists(final_dir / "manifest.json") and
      parse_manifest(read_file(final_dir / "manifest.json")).ok:
    store.entries_since_snapshot = 0
    return final_dir
  remove_dir(final_dir) # invalid/damaged leftover; was never trusted
  remove_dir(tmp_dir)
  create_dir(tmp_dir)

  var idx = 0
  for id, body in self.objects:
    if body == nil or body.destroyed:
      continue
    if body.placeholder:
      # Placeholders self-heal: a parent's bin re-mints them on restore.
      # Persisting one as a normal record would restore a real-but-empty
      # object -- silent corruption.
      continue
    if body.flags * {SYNC_LOCAL, SYNC_REMOTE} == {}:
      # Same predicate as append: what the log never sees, the snapshot must
      # not contain, or snapshot != replay(log).
      continue
    inc idx
    var msg = body.build_create(body, true)
    msg.epoch = store.epoch
    let line = msg.to_entry_line
    let file = object_file(idx, id)
    write_file_synced(tmp_dir / file, line & "\n")
    manifest.objects.add ManifestEntry(
      file: file, oid: id, tid: msg.type_id, crc: crc32_hex(line)
    )

  write_file_synced(tmp_dir / "manifest.json", manifest.to_manifest & "\n")
  fsync_dir(tmp_dir)
  move_dir(tmp_dir, final_dir)
  fsync_dir(store.path / SNAPSHOTS_DIR)

  store.snapshot_name = final_name
  store.open_segment(after_lsn = watermark)
  store.write_head
  store.entries_since_snapshot = 0
  store.prune_retention
  debug "snapshot written", watermark, objects = manifest.objects.len
  result = final_dir
