import std/[os, algorithm, strutils]
import ed/types {.all.}
import ed/utils/[misc, logging]
import ./format

# The append/segment half of the durable store (docs/persistence.md). A segment
# is append-only JSONL; a fresh one opens on every store open (epoch bump) and
# on every snapshot, so all non-active segments are immutable. `commit` is the
# single durability decision point: appends buffer into the File, and when they
# become durable is policy (`StoreDurability`), not mechanism.

const
  LOG_DIR* = "log"
  SNAPSHOTS_DIR* = "snapshots"

when defined(posix):
  import std/posix

  proc fsync_file*(f: File) =
    f.flush_file
    discard fsync(f.get_os_file_handle)

else:
  proc fsync_file*(f: File) =
    f.flush_file

proc commit*(store: EdStore) =
  ## Make buffered appends durable per the store's durability level. The
  ## first-class commit point: future rungs (quorum replication) extend this,
  ## not the append path.
  if store.segment == nil or not store.dirty:
    return
  if store.durability in {FsyncPerTick, FsyncPerOp}:
    store.segment.fsync_file
  else:
    store.segment.flush_file
  store.dirty = false

proc append*(
    store: EdStore, msg: Message, epoch: int64, flags: set[EdFlags]
) =
  ## Append one canonical op. `flags` are the container's -- an object synced
  ## nowhere (no SYNC flag) is ephemeral by contract and doesn't persist either.
  ## The entry is a copy: the fanned-out message is never mutated here.
  do_assert not store.read_only, "can't append to a read-only store"
  assert msg.kind in LOGGED_KINDS
  if flags * {SYNC_LOCAL, SYNC_REMOTE} == {}:
    return
  var entry = msg
  entry.epoch = epoch
  entry.flags = flags
  store.segment.write_line entry.to_entry_line
  store.dirty = true
  inc store.entries_since_snapshot
  if store.durability == FsyncPerOp:
    store.commit

proc open_segment*(store: EdStore, after_lsn: int64) =
  ## Open a fresh append segment whose entries all follow `after_lsn`. The
  ## previous segment (if any) becomes immutable.
  do_assert not store.read_only
  if store.segment != nil:
    store.commit
    store.segment.close
  create_dir(store.path / LOG_DIR)
  store.segment_name = LOG_DIR / segment_file(store.epoch, after_lsn)
  store.segment = open(store.path / store.segment_name, fm_append)
  store.dirty = false

proc close_store*(store: EdStore) =
  ## Flush and close. Idempotent.
  if store.segment != nil:
    store.commit
    store.segment.close
    store.segment = nil

proc write_head*(store: EdStore) =
  ## HEAD is a hint rewritten atomically at open/rotate; recovery validates
  ## manifests/segments itself and never trusts HEAD blindly.
  let head =
    Head(
      snapshot: store.snapshot_name,
      segment: store.segment_name,
      epoch: store.epoch,
    )
  write_file(store.path / "HEAD.tmp", head.to_head)
  move_file(store.path / "HEAD.tmp", store.path / "HEAD")

proc scan_segments*(
    root: string
): seq[tuple[path: string, epoch, after_lsn: int64]] =
  ## All segments, name-sorted (zero-padded names make lexical = numeric order).
  let dir = root / LOG_DIR
  if not dir_exists(dir):
    return
  for kind, path in walk_dir(dir):
    if kind == pc_file:
      let (ok, epoch, after_lsn) = parse_segment_file(path.extract_filename)
      if ok:
        result.add((path, epoch, after_lsn))
  result.sort

proc scan_snapshots*(root: string): seq[tuple[dir: string, lsn: int64]] =
  ## Snapshot dirs, oldest first. tmp-* (crashed mid-write) never parse and are
  ## skipped; open_store deletes them.
  let dir = root / SNAPSHOTS_DIR
  if not dir_exists(dir):
    return
  for kind, path in walk_dir(dir):
    if kind == pc_dir:
      let (ok, lsn) = parse_snapshot_dir(path.extract_filename)
      if ok:
        result.add((path, lsn))
  result.sort

iterator read_entries*(path: string): Message =
  ## Entries of one segment in file order, streamed a line at a time (a segment
  ## can grow large between snapshots). A torn final line (mid-write crash) is
  ## dropped with a notice; a bad line anywhere else is real corruption and
  ## raises StoreError -- silently skipping history would be data loss.
  log_defaults
  let f = open(path, fm_read)
  try:
    var line = ""
    var line_num = 0
    while f.read_line(line):
      inc line_num
      let (ok, msg) = parse_entry(line)
      if not ok:
        # Only EOF distinguishes a torn tail from mid-file corruption; the
        # stdio EOF flag isn't set until a read past the end fails, so probe.
        var lookahead = ""
        if f.read_line(lookahead):
          raise StoreError.init(
            "corrupt store entry at " & path & ":" & $line_num
          )
        notice "dropping torn tail entry", path, line = line_num
        break
      yield msg
  finally:
    f.close
