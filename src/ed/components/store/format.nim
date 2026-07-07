import std/[json, base64, strutils]
import ed/types {.all.}
import ed/utils/crc32

# On-disk encodings for the durable store: JSONL log entries, snapshot object
# files (one entry line each), the snapshot manifest, and HEAD. Entries project
# Message fields explicitly rather than dumping `Message.to_flatty` -- the
# flatty layout varies with `ed_trace`, and explicit fields keep the log
# greppable. Payload bins (`obj`/`key`) stay flatty, base64'd; `codec` names
# their encoding so a readable codec can slot in later. Session-coupled fields
# (source, id_mappings) never persist. Every line ends with a `crc` field
# computed over the raw bytes before it, so a torn tail is detectable without
# canonical-JSON games.

const
  STORE_VERSION* = 1
  CODEC_FLATTY* = "flatty"
  LOGGED_KINDS* = {CREATE, DESTROY, ASSIGN, UNASSIGN, TOUCH, PACKED}

type
  ManifestEntry* = object
    file*: string
    oid*: string
    tid*: int
    crc*: string

  Manifest* = object
    version*: int
    epoch*: int64
    lsn*: int64 ## watermark: state as of this LSN inclusive
    op_id_counter*: int64
    codec*: string
    schema*: int ## reserved TypeSchema version (always 0 today)
    endian*: string
    int_bits*: int
    objects*: seq[ManifestEntry] ## registry insertion order = dependency order

  Head* = object
    snapshot*: string
    segment*: string
    epoch*: int64

const
  host_endian = when cpu_endian == little_endian: "little" else: "big"
  host_int_bits = sizeof(int) * 8
  crc_marker = ",\"crc\":\""

proc init*(
    _: type Manifest, epoch, lsn, op_id_counter: int64
): Manifest =
  Manifest(
    version: STORE_VERSION,
    epoch: epoch,
    lsn: lsn,
    op_id_counter: op_id_counter,
    codec: CODEC_FLATTY,
    endian: host_endian,
    int_bits: host_int_bits,
  )

proc platform_ok*(m: Manifest): bool =
  m.endian == host_endian and m.int_bits == host_int_bits

proc seal(line: sink string): string =
  ## Append the crc field computed over everything before it.
  result = line
  result.add crc_marker & crc32_hex(line) & "\"}"

proc check_seal(line: string): bool =
  let idx = line.rfind(crc_marker)
  if idx <= 0:
    return false
  let start = idx + crc_marker.len
  if start + 8 > line.len:
    return false
  line[start ..< start + 8] == crc32_hex(line.to_open_array(0, idx - 1))

proc to_entry_line*(msg: Message): string =
  ## One JSONL line (no trailing newline). Fixed field order, defaults omitted,
  ## crc last.
  result = "{\"v\":" & $STORE_VERSION
  result.add ",\"epoch\":" & $msg.epoch
  result.add ",\"lsn\":" & $msg.lsn
  result.add ",\"txn\":0,\"commit\":true"
  result.add ",\"kind\":\"" & $msg.kind & "\""
  result.add ",\"oid\":" & escape_json(msg.object_id)
  if msg.change_object_id.len > 0:
    result.add ",\"coid\":" & escape_json(msg.change_object_id)
  result.add ",\"tid\":" & $msg.type_id
  if msg.ref_id != 0:
    result.add ",\"rid\":" & $msg.ref_id
  if msg.owner_id.len > 0:
    result.add ",\"owner\":" & escape_json(msg.owner_id)
  if msg.flags != {}:
    result.add ",\"flags\":["
    var first = true
    for flag in msg.flags:
      if not first:
        result.add ","
      result.add "\"" & $flag & "\""
      first = false
    result.add "]"
  if msg.delta:
    result.add ",\"delta\":true"
  if msg.key_bin.len > 0:
    result.add ",\"key\":\"" & encode(msg.key_bin) & "\""
  if msg.obj.len > 0:
    result.add ",\"obj\":\"" & encode(msg.obj) & "\""
  result.add ",\"codec\":\"" & CODEC_FLATTY & "\""
  if msg.origin.len > 0:
    result.add ",\"origin\":" & escape_json(msg.origin)
  if msg.op_id != 0:
    result.add ",\"op\":" & $msg.op_id
  result = seal(result)

proc parse_entry*(line: string): tuple[ok: bool, msg: Message] =
  ## ok = false on any JSON/crc/schema failure. Unknown fields are ignored
  ## (forward compat); an unknown version or codec is a refusal, not a crash.
  if not check_seal(line):
    return
  var node: JsonNode
  try:
    node = parse_json(line)
    if node{"v"}.get_int(int.high) > STORE_VERSION:
      return
    var msg = Message(
      epoch: node{"epoch"}.get_biggest_int,
      lsn: node{"lsn"}.get_biggest_int,
      kind: parse_enum[MessageKind](node["kind"].get_str),
      object_id: node["oid"].get_str,
      change_object_id: node{"coid"}.get_str,
      type_id: node{"tid"}.get_int,
      ref_id: node{"rid"}.get_int,
      owner_id: node{"owner"}.get_str,
      delta: node{"delta"}.get_bool,
      origin: node{"origin"}.get_str,
      op_id: node{"op"}.get_biggest_int,
    )
    if "flags" in node:
      for flag in node["flags"]:
        msg.flags.incl parse_enum[EdFlags](flag.get_str)
    if "key" in node:
      msg.key_bin = decode(node["key"].get_str)
    if "obj" in node:
      msg.obj = decode(node["obj"].get_str)
    if node{"codec"}.get_str(CODEC_FLATTY) != CODEC_FLATTY:
      return
    result = (true, msg)
  except CatchableError:
    return

proc to_manifest*(m: Manifest): string =
  result = "{\"v\":" & $m.version
  result.add ",\"epoch\":" & $m.epoch
  result.add ",\"lsn\":" & $m.lsn
  result.add ",\"op_id_counter\":" & $m.op_id_counter
  result.add ",\"codec\":\"" & m.codec & "\""
  result.add ",\"schema\":" & $m.schema
  result.add ",\"endian\":\"" & m.endian & "\""
  result.add ",\"int_bits\":" & $m.int_bits
  result.add ",\"objects\":["
  for i, entry in m.objects:
    if i > 0:
      result.add ","
    result.add "{\"file\":" & escape_json(entry.file)
    result.add ",\"oid\":" & escape_json(entry.oid)
    result.add ",\"tid\":" & $entry.tid
    result.add ",\"crc\":\"" & entry.crc & "\"}"
  result.add "]"
  result = seal(result)

proc parse_manifest*(s: string): tuple[ok: bool, manifest: Manifest] =
  if not check_seal(s):
    return
  try:
    let node = parse_json(s)
    if node{"v"}.get_int(int.high) > STORE_VERSION:
      return
    var m = Manifest(
      version: node["v"].get_int,
      epoch: node{"epoch"}.get_biggest_int,
      lsn: node{"lsn"}.get_biggest_int,
      op_id_counter: node{"op_id_counter"}.get_biggest_int,
      codec: node{"codec"}.get_str(CODEC_FLATTY),
      schema: node{"schema"}.get_int,
      endian: node{"endian"}.get_str,
      int_bits: node{"int_bits"}.get_int,
    )
    if m.codec != CODEC_FLATTY:
      return
    for entry in node["objects"]:
      m.objects.add ManifestEntry(
        file: entry["file"].get_str,
        oid: entry["oid"].get_str,
        tid: entry{"tid"}.get_int,
        crc: entry{"crc"}.get_str,
      )
    result = (true, m)
  except CatchableError:
    return

proc to_head*(h: Head): string =
  "{\"snapshot\":" & escape_json(h.snapshot) & ",\"segment\":" &
    escape_json(h.segment) & ",\"epoch\":" & $h.epoch & "}"

proc parse_head*(s: string): tuple[ok: bool, head: Head] =
  try:
    let node = parse_json(s)
    result = (
      true,
      Head(
        snapshot: node{"snapshot"}.get_str,
        segment: node{"segment"}.get_str,
        epoch: node{"epoch"}.get_biggest_int,
      ),
    )
  except CatchableError:
    return

# Path/name conventions. Segment and snapshot names zero-pad epoch/lsn so
# lexical order = numeric order.

proc segment_file*(epoch, after_lsn: int64): string =
  align($epoch, 6, '0') & "-" & align($after_lsn, 15, '0') & ".jsonl"

proc parse_segment_file*(
    name: string
): tuple[ok: bool, epoch, after_lsn: int64] =
  if not name.ends_with(".jsonl"):
    return
  let parts = name[0 ..< ^6].split('-')
  if parts.len != 2:
    return
  try:
    result = (true, parse_biggest_int(parts[0]), parse_biggest_int(parts[1]))
  except ValueError:
    return

proc snapshot_dir*(lsn: int64): string =
  align($lsn, 15, '0')

proc parse_snapshot_dir*(name: string): tuple[ok: bool, lsn: int64] =
  try:
    result = (true, parse_biggest_int(name))
  except ValueError:
    return

proc object_file*(idx: int, oid: string): string =
  var sanitized = ""
  for ch in oid:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_', '-'}:
      sanitized.add ch
    if sanitized.len == 40:
      break
  "obj-" & align($idx, 6, '0') & "-" & sanitized & ".json"
