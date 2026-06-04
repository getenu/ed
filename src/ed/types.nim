import ed/[deps]
import pkg/[serialization, json_serialization]

type
  EID* = uint16
    ## Callback identifier for tracking registered callbacks.

  EdFlags* = enum
    ## Flags controlling `Ed` container behavior.
    TRACK_CHILDREN    ## Propagate changes from nested `Ed` objects
    SYNC_LOCAL        ## Sync changes to other local contexts (threads)
    SYNC_REMOTE       ## Sync changes to remote contexts (network)
    SYNC_ALL_NO_OVERWRITE  ## Sync without overwriting existing data

  ChangeKind* = enum
    ## Types of changes that can occur on an `Ed` container.
    CREATED   ## Object was created
    ADDED     ## Item was added (sequences, sets, tables)
    REMOVED   ## Item was removed
    MODIFIED  ## Value was modified
    TOUCHED   ## Object was touched without modification
    CLOSED    ## Object was destroyed

  MessageKind* = enum
    BLANK
    CREATE
    DESTROY
    ASSIGN
    UNASSIGN
    TOUCH
    SUBSCRIBE
    PACKED

  BaseChange* = ref object of RootObj
    changes*: set[ChangeKind]
    field_name*: string
    triggered_by*: seq[BaseChange]
    triggered_by_type*: string
    type_name*: string

  OperationContext = object
    source*: HashSet[string]
    origin*: string  # ctx id that originated the op (threaded for own-op dedup)
    op_id*: int64    # originator's op id (threaded so forwards preserve it)
    when defined(ed_trace):
      trace*: string

  PackedMessageOperation* =
    tuple[kind: MessageKind, ref_id: int, change_object_id: string, obj: string]

  IdMapping* = tuple[short_id: uint8, full_id: string]

  Message = object
    kind*: MessageKind
    object_id*: string
    change_object_id*: string
    type_id*: int
    ref_id*: int
    obj*: string
    source*: seq[uint8]  # Short IDs for wire format (Remote)
    source_set*: HashSet[string]  # Full source for internal use (Local) - not serialized
    id_mappings*: seq[IdMapping]  # New mappings for unknown IDs
    flags*: set[EdFlags]
    # Phase 1: global ordering (see docs/phase-1-keystone-spike.md)
    epoch*: int64   # authority epoch; bumped on host/leader change
    lsn*: int64     # global sequence number from the authority (0 = unordered)
    op_id*: int64   # originator-generated id for ack/commit correlation (0 = none)
    origin*: string # ctx id that originated the op (for own-op dedup)
    delta*: bool    # true for collection (non-idempotent) ops, false for registers
    when defined(ed_trace):
      trace*: string
      id*: int
      debug*: string

  CreateInitializer = proc(
    bin: string,
    ctx: EdContext,
    id: string,
    flags: set[EdFlags],
    op_ctx: OperationContext,
  )

  Change*[O] = ref object of BaseChange
    ## Represents a change to an `Ed` container, including the affected item.
    item*: O

  Pair[K, V] = object
    ## Key-value pair used for `EdTable` changes.
    key*: K
    value*: V

  CountedRef = object
    obj*: ref RootObj
    references*: HashSet[string]

  RegisteredType = object
    tid*: int
    stringify*: proc(self: ref RootObj): string {.no_side_effect.}
    parse*:
      proc(ctx: EdContext, clone_from: string): ref RootObj {.no_side_effect.}

  SubscriptionKind* = enum
    BLANK
    LOCAL
    REMOTE

  Subscription* = ref object
    ctx_id*: string
    # Short ID mappings for this connection. Outgoing and incoming are
    # *separate* namespaces — each peer independently allocates short IDs
    # in messages it sends. Sharing the table would let our own outgoing
    # assignments clobber an incoming mapping the peer expects us to use.
    next_short_id*: uint8  # Next outgoing short ID to assign
    id_to_short*: Table[string, uint8]  # full id -> short we send for it
    outgoing_short_to_id*: Table[uint8, string]  # inverse of id_to_short
    incoming_short_to_id*: Table[uint8, string]  # short the peer sends -> full id
    case kind*: SubscriptionKind
    of LOCAL:
      chan*: Chan[Message]
      chan_buffer*: seq[Message]
    of REMOTE:
      connection*: Connection
      last_sent_time*: float64
    else:
      discard

  EdContext* = ref object
    ## Central coordination object managing `Ed` container lifecycle, subscriptions,
    ## and message passing between threads/network.
    id*: string
    # Phase 1: global LSN + appointed leader (docs/phase-1-keystone-spike.md)
    is_authority*: bool   # this context is the sequencer (leader) for its objects
    leader_id*: string    # ctx_id of the authority (own id when is_authority)
    lsn_counter*: int64   # authority-only: next global LSN to assign
    applied_lsn*: int64   # highest global LSN applied (frontier)
    op_id_counter*: int64 # next op id to assign to a write we originate
    latest_op_id*: Table[string, int64]  # object_id -> our highest op id (own-op reconciliation)
    changed_callback_eid: EID
    last_id: int
    close_procs: Table[EID, proc() {.gcsafe.}]
    objects*: OrderedTable[string, ref EdBase]
    objects_need_packing*: bool
    ref_pool: Table[string, CountedRef]
    subscribers*: seq[Subscription]
    chan: Chan[Message]
    freeable_refs: Table[string, MonoTime]
    last_msg_id: Table[string, int]
    last_received_id: Table[string, int]
    reactor*: Reactor
    remote_messages: seq[netty.Message]
    blocking_recv: bool
    buffer: bool
    min_recv_duration: Duration
    max_recv_duration: Duration
    subscribing*: bool
    value_initializers*: seq[proc() {.gcsafe.}]
    dead_connections: seq[Connection]
    unsubscribed*: seq[string]
    metrics_label*: string
    free_queue*: seq[string]
    last_keepalive_tick*: float64
    bytes_sent*: int
    bytes_received*: int
    when defined(ed_debug_messages):
      messages_sent*: int
      messages_received*: int
      obj_bytes_sent*: int
      obj_bytes_received*: int
      pre_compression_bytes*: int  # Total bytes before snappy compression
      messages_by_kind*: array[MessageKind, int]
      messages_sent_by_kind*: array[MessageKind, int]  # Message count sent per kind
      obj_bytes_sent_by_kind*: array[MessageKind, int]
      obj_bytes_recv_by_kind*: array[MessageKind, int]
      obj_bytes_by_id*: Table[string, int]  # Bytes sent per object ID
      obj_bytes_by_type*: Table[int, int]   # Bytes sent per type ID
    when defined(dump_ed_objects):
      dump_at*: MonoTime
      counts*: array[MessageKind, int]

  EdBase* = object of RootObj
    ## Base type for all `Ed` containers. Not used directly.
    id*: string
    destroyed*: bool
    link_eid: EID
    paused_eids: set[EID]
    bound_eids: seq[EID]
    flags*: set[EdFlags]
    build_message: proc(
      self: ref EdBase, change: BaseChange, id: string, trace: string
    ): Message {.gcsafe.}

    publish_create: proc(
      sub = Subscription(), broadcast = false, op_ctx = OperationContext()
    ) {.gcsafe.}

    change_receiver:
      proc(self: ref EdBase, msg: Message, op_ctx: OperationContext) {.gcsafe.}

    ctx*: EdContext

  ChangeCallback[O] = proc(changes: seq[Change[O]]) {.gcsafe.}

  EdObject[T, O] = object of EdBase
    changed_callbacks: OrderedTable[EID, ChangeCallback[O]]
    tracked: T

  Ed*[T, O] = ref object of EdObject[T, O]
    ## Generic reactive container. T is the contained type, O is the change object type.

  EdTable*[K, V] = Ed[Table[K, V], Pair[K, V]]
    ## Reactive table container. Changes report key-value pairs.

  EdSeq*[T] = Ed[seq[T], T]
    ## Reactive sequence container.

  EdSet*[T] = Ed[set[T], T]
    ## Reactive set container.

  EdValue*[T] = Ed[T, T]
    ## Reactive single-value container.

const DEFAULT_FLAGS* = {SYNC_LOCAL, SYNC_REMOTE}
  ## Default flags for `Ed` containers: sync both locally and remotely.

template ed_ignore*() {.pragma.}
  ## Mark a field to be ignored during `Ed` serialization.

proc write_value*[T](w: var JsonWriter, self: set[T]) =
  write_value(w, self.to_seq)

proc write_value*(w: var JsonWriter, self: EdContext) =
  write_value(w, self.id)

proc write_value*(w: var JsonWriter, self: Subscription) =
  write_value(w, (ctx_id: self.ctx_id, kind: self.kind))

# Custom flatty serializers for Message to skip source_set (internal use only)
proc to_flatty*(s: var string, msg: Message) =
  s.to_flatty msg.kind
  s.to_flatty msg.object_id
  s.to_flatty msg.change_object_id
  s.to_flatty msg.type_id
  s.to_flatty msg.ref_id
  s.to_flatty msg.obj
  s.to_flatty msg.source
  # Skip source_set - internal use only
  s.to_flatty msg.id_mappings
  s.to_flatty msg.flags
  s.to_flatty msg.epoch
  s.to_flatty msg.lsn
  s.to_flatty msg.op_id
  s.to_flatty msg.origin
  s.to_flatty msg.delta
  when defined(ed_trace):
    s.to_flatty msg.trace
    s.to_flatty msg.id
    s.to_flatty msg.debug

proc from_flatty*(s: string, i: var int, msg: var Message) =
  s.from_flatty(i, msg.kind)
  s.from_flatty(i, msg.object_id)
  s.from_flatty(i, msg.change_object_id)
  s.from_flatty(i, msg.type_id)
  s.from_flatty(i, msg.ref_id)
  s.from_flatty(i, msg.obj)
  s.from_flatty(i, msg.source)
  # source_set not in wire format
  s.from_flatty(i, msg.id_mappings)
  s.from_flatty(i, msg.flags)
  s.from_flatty(i, msg.epoch)
  s.from_flatty(i, msg.lsn)
  s.from_flatty(i, msg.op_id)
  s.from_flatty(i, msg.origin)
  s.from_flatty(i, msg.delta)
  when defined(ed_trace):
    s.from_flatty(i, msg.trace)
    s.from_flatty(i, msg.id)
    s.from_flatty(i, msg.debug)
