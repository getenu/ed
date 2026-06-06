import ed/[deps]
import pkg/[serialization, json_serialization]

template ed_ignore*() {.pragma.}
  ## Mark a field to be ignored during `Ed` serialization.

type
  EID* = uint16
    ## Callback identifier for tracking registered callbacks.

  Lifetime* = ref object
    ## Owns a set of teardown actions (typically untracking callbacks). An owner
    ## — a Unit, a scope, and eventually an object proxy — holds a Lifetime and
    ## `finish`es it on teardown, so everything bound to it cleans up at once with
    ## no manual `zid` bookkeeping. Standalone on purpose (not welded to EdBase):
    ## under the future proxy/body split it becomes the proxy's cleanup set with
    ## no change to call sites.
    cleanups: seq[proc() {.gcsafe.}]
    finished: bool

  RefHandle* = ref object
    ## Per-instance registry-cleanup handle carried by every `EdRef`. When a
    ## registered ref's last reference drops, ORC destroys its fields and this
    ## handle's `=destroy` records the (now-dead) instance for removal from its
    ## context's `ref_pool`. It identifies the context by *value* — a uid, not a
    ## reference — on purpose: the destructor must never dereference its
    ## `EdContext`, because at teardown the context can be reclaimed in the *same*
    ## ORC cycle-collection batch as the ref (a dangling-cursor UAF, caught by
    ## ASan). So instead of touching `ctx.ref_pool` directly it appends to a
    ## thread-local pending list (`pending_dead_refs`); each context prunes its
    ## own dead ids before any identity read and on tick. A bare registered ref
    ## carries no such handle — and `Ed.thread_ctx` is wrong under multiple
    ## contexts per thread (load-bearing for sync identity: two contexts hold
    ## different instances of one ref_id) — which is why the uid lives here.
    ## `ctx_uid`/`ref_id` stay unset until the instance's first ADD into a
    ## `ref_pool`; until then `=destroy` is a no-op.
    ctx_uid*: int  # owning context's per-instance uid (0 = unset). NOT the id.
    ref_id*: string

  EdRef* = ref object of RootObj
    ## Base for registered (network-syncable) refs. Carries a `RefHandle` so the
    ## registry can clean up `ref_pool` when ORC reclaims the instance — keeping
    ## the registry's non-owning (cursor) hold from dangling, with the Unit's own
    ## DEFAULT destructor intact (only the trivial `RefHandle` gets a custom
    ## one, so fields don't leak). enu's `Model` and the test's `RefType`
    ## inherit this; the eviction-phase proxy/observability hangs off the same
    ## base.
    ref_handle*: RefHandle
    destroyed* {.ed_ignore.}: bool
      ## Idempotency latch for `destroy`, set at its top. Mirrors
      ## `EdBase.destroyed` (containers). `ed_ignore`: it's local teardown state,
      ## never synced (a freshly received ref must arrive un-destroyed).
    lifetime*: Lifetime
      ## Owns this ref's teardown actions — external subscriptions, and (via the
      ## `own` scope) its owned containers. `destroy` runs `lifetime.finish`. Local
      ## state: it's a ref, so stringify nils it, and the `Lifetime` flatty skip
      ## covers the rest — never synced.

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

  ChangeReason* = enum
    ## Why a change fired, orthogonal to `ChangeKind`. (Unrelated to
    ## `Change.triggered_by`, which is the upstream changes that caused this one.)
    Update    ## An ordinary live change — a mutation or touch
    Initial   ## Replay of existing contents at `track` time (reserved)
    Fill      ## A placeholder materialized (partial-replica fetch landed)

  MessageKind* = enum
    BLANK
    CREATE
    DESTROY
    ASSIGN
    UNASSIGN
    TOUCH
    SUBSCRIBE
    PACKED
    REQUEST  # partial replica asking the authority for an object by id

  BaseChange* = ref object of RootObj
    changes*: set[ChangeKind]
    reason*: ChangeReason
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
    owner_id*: string  # CREATE only: the EdRef that owns this container (synced
                       # ownership; "" = unowned). Lets a non-creator destroy it.
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
    # Non-owning index entry: `obj` is a `{.cursor.}`, so `ref_pool` no longer
    # keeps a registered ref alive (it once did — the old strong hold + 10s
    # grace). Memory is ORC-owned; the real holders are the containers that
    # `track` it (strong) plus the app/Godot node. When the last real reference
    # drops, ORC reclaims the instance and its `RefHandle.=destroy` dels this
    # entry — so the cursor can never dangle (ref_pool[id] non-nil ⟺ instance
    # alive). Requires every registered type to inherit `EdRef`.
    obj* {.cursor.}: ref RootObj
    # Which Ed containers currently hold this ref. REFRAMED: a reachability hint
    # only (used by the future evictor), NOT a free trigger — `card == 0` no
    # longer schedules anything.
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
    # Partial replicas: when `partial`, this subscriber only receives objects in
    # `interest` (its roots + ids it has fetched). Default (not partial) gets
    # everything — the existing full-replica behavior.
    partial*: bool
    interest*: HashSet[string]
    # Capability filter: the set of container type-ids this subscriber can
    # materialize (its registered `type_initializers`). The authority skips any
    # object whose `type_id` isn't here, so a peer never receives an object it
    # can't construct (which would crash/drop on deserialize). Empty = unfiltered
    # (no handshake / same-build peer) — preserves the full-replica default.
    capabilities*: HashSet[int]
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
    # Per-instance unique id (distinct from `id`, which is user-supplied and
    # reused across contexts). Keys `pending_dead_refs` so a registered ref freed
    # after its context is gone can't prune a *new* same-`id` context's ref_pool.
    # Assigned from a thread-local counter at init; refs are freed on their
    # context's home thread, so the counter and the pending list stay consistent.
    uid*: int
    # Phase 1: global LSN + appointed leader (docs/phase-1-keystone-spike.md)
    is_authority*: bool   # this context is the sequencer (leader) for its objects
    leader_id*: string    # ctx_id of the authority (own id when is_authority)
    lsn_counter*: int64   # authority-only: next global LSN to assign
    applied_lsn*: int64   # highest global LSN applied (frontier)
    op_id_counter*: int64 # next op id to assign to a write we originate
    latest_op_id*: Table[string, int64]  # object_id -> our highest op id (own-op reconciliation)
    # Materialize-on-access (partial replicas). `materialize` is wired up at
    # subscribe time (it needs fetch/tick) and called by the read accessors when
    # they touch a placeholder. When `blocking`, that call pumps I/O until the
    # object fills; otherwise it kicks a fetch and returns the empty placeholder.
    materialize*: proc(self: EdContext, id: string) {.gcsafe.}
    blocking*: bool
    filling*: bool        # set while a placeholder fill applies → tags Fill changes
    silent*: bool         # silent (blocking) materialize: defer callbacks to next tick
    pending_msgs*: seq[Message]            # received-but-deferred during a silent pump
    pending_fills*: seq[proc() {.gcsafe.}] # Fill callbacks deferred to the next tick
    # Per-key fetch requests buffered between ticks (table object_id -> serialized
    # keys). A frame's worth of request() calls collapse into one REQUEST per
    # table, flushed on the next tick.
    pending_key_requests*: Table[string, seq[string]]
    changed_callback_eid: EID
    last_id: int
    close_procs: Table[EID, proc() {.gcsafe.}]
    objects*: OrderedTable[string, ref EdBase]
    objects_need_packing*: bool
    # Ownership index: owner EdRef id -> ids of the containers it owns (whose
    # `owner_id` points back here). Built as containers are created/materialized,
    # pruned as they're destroyed. Lets an owner tear down what it owns
    # (`destroy_owned`) in *any* context — including one that didn't construct it
    # (e.g. the server cleaning up an MCP-created bot after the client drops).
    owned_by*: Table[string, HashSet[string]]
    ref_pool: Table[string, CountedRef]
    subscribers*: seq[Subscription]
    chan: Chan[Message]
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
    # The EdRef (by id) that owns this container, or "" if unowned. Set when the
    # container is created inside an `own` scope, and on materialize from the
    # synced CREATE envelope, so it's the same in every context. Indexed in
    # `EdContext.owned_by`; the owner's `destroy_owned` tears these down. Mutable
    # on purpose — ownership transfer (re-home a live object) will reset it.
    owner_id*: string
    destroyed*: bool
    # Partial replicas: a placeholder is a non-broadcasting stand-in for a
    # not-yet-materialized object (its contents are empty until fetched). Reading
    # it triggers a fetch; when the real state arrives the bit clears and a Fill
    # change fires. Default false = a normal, fully-loaded object.
    placeholder*: bool
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

    # Per-key fetch (partial EdTable). Given a serialized key, build the ADD op
    # carrying that key's current value, so a partial subscriber can pull one
    # entry without the whole table. `found = false` if the key isn't present.
    # nil for non-table containers.
    publish_key:
      proc(self: ref EdBase, key_bin: string): tuple[found: bool, msg: Message] {.
        gcsafe
      .}

    # Back-reference to the owning context. `{.cursor.}` (non-owning): the
    # context owns its objects via `objects*` (a strong OrderedTable), so this
    # is the back-edge of that cycle. Marking it a cursor breaks the
    # object<->context reference cycle so a freed object/subtree is reclaimed
    # promptly instead of waiting on ORC's cycle collector. Safe because the
    # context strictly outlives its objects (it holds the only registry refs;
    # teardown that touches `self.ctx` — untrack/destroy — is explicit and runs
    # while the context is alive, and no Ed object has an ORC `=destroy` that
    # dereferences `ctx`). Validated under AddressSanitizer (tests/asan.sh).
    ctx* {.cursor.}: EdContext

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

var next_ctx_uid* {.threadvar.}: int
  ## Thread-local source of `EdContext.uid`. Per-thread is enough: a context is
  ## created on, ticks on, and frees its refs on, one home thread, and
  ## `pending_dead_refs` is thread-local too — so uids only ever collide across
  ## threads, where the separate pending tables keep them apart.

var pending_dead_refs* {.threadvar.}: Table[int, seq[string]]
  ## ctx uid -> ref_ids whose registered instance ORC has reclaimed. Populated by
  ## `RefHandle.=destroy`, which must NOT touch its `EdContext` (it may already be
  ## freed — even within the same cycle-collection batch). Each context drains its
  ## own uid via `prune_dead_refs` before any `ref_pool` identity read and on tick.
  ## Entries for a context that dies without draining just linger (bounded; freed
  ## at thread exit) and can't be misattributed, since the key is the uid.

proc `=destroy`(h: var typeof(RefHandle()[])) =
  ## Registry cleanup for a registered ref. Runs when ORC reclaims the handle
  ## (its owning `EdRef`'s last reference dropped). It must not dereference the
  ## context (see RefHandle), so it only *records* the dead instance for the
  ## context to prune later. A custom `=destroy` replaces field destruction, so
  ## `ref_id` is freed by hand (`ctx_uid` is a plain int, nothing to free). No-op
  ## until the registry sets `ctx_uid`/`ref_id` on the instance's first ADD.
  if h.ctx_uid != 0 and h.ref_id.len > 0:
    {.cast(gcsafe).}:
      pending_dead_refs.mget_or_put(h.ctx_uid, @[]).add(h.ref_id)
  `=destroy`(h.ref_id)

proc prune_dead_refs*(self: EdContext) =
  ## Remove from `ref_pool` the entries whose instances ORC has reclaimed (see
  ## `pending_dead_refs`). Must run before any `ref_pool` identity lookup so a
  ## dangling cursor is never read, and on tick to keep the pool tidy. Idempotent;
  ## cheap when nothing is pending.
  if self.uid in pending_dead_refs:
    {.cast(gcsafe).}:
      for ref_id in pending_dead_refs[self.uid]:
        self.ref_pool.del(ref_id)
      pending_dead_refs.del(self.uid)

proc to_flatty*(s: var string, x: RefHandle) =
  ## The registry-cleanup handle is per-context-local state (a context uid + id),
  ## never part of the synced value — its uid is meaningless in another context.
  ## Skip it; `ref_count` re-mints the handle on the receiver's first ADD. Defined
  ## here (with the Message overrides) so it's visible where `type_registry`'s
  ## `stringify` instantiates flatty. Mirrors the Lifetime/proc skips in
  ## subscriptions.nim.
  discard

proc from_flatty*(s: string, i: var int, x: var RefHandle) =
  discard

proc new_lifetime*(): Lifetime =
  Lifetime()

proc add*(self: Lifetime, cleanup: proc() {.gcsafe.}) =
  ## Register a teardown action. If the Lifetime has already finished, the action
  ## runs immediately (so binding to a dead Lifetime can't leak).
  if self.finished:
    cleanup()
  else:
    self.cleanups.add cleanup

proc finish*(self: Lifetime) =
  ## Run every registered teardown action, once. Idempotent.
  if self.finished:
    return
  self.finished = true
  let cleanups = self.cleanups
  self.cleanups = @[]
  for cleanup in cleanups:
    cleanup()

proc finished*(self: Lifetime): bool =
  self.finished

var current_lifetime* {.threadvar.}: Lifetime
  ## The lifetime an open `own` scope binds *callbacks* to (thread-local; nil = no
  ## scope). `track` consults it: a callback registered inside `self.own:` untracks
  ## when `self.lifetime.finish` runs. nil outside a scope → no auto-binding.

var current_owner_id* {.threadvar.}: string
  ## The id of the EdRef an open `own` scope attributes new *containers* to. A
  ## container created inside the scope records it (`owner_id` + the `owned_by`
  ## index); the owner's `destroy_owned` then tears those containers down. So
  ## `lifetime` carries callbacks while container ownership is the baked-in
  ## `owner_id`. "" outside a scope → containers are unowned.

template own*[T: EdRef](self: T, body: untyped) =
  ## Within this scope, every Ed container created records `self` as its owner
  ## (so `self`'s teardown destroys them via `destroy_owned`), and every callback
  ## tracked binds its untrack to `self.lifetime` (lazily created). Generic on the
  ## concrete type so `self.id` resolves (EdRef has no `id` of its own). Scopes
  ## nest by save/restore — innermost wins, control returns to the enclosing owner
  ## on exit. It's a *dynamic* scope: things constructed in procs called from the
  ## body attribute here too, so keep blocks tight.
  if self.lifetime.is_nil:
    self.lifetime = new_lifetime()
  let prev_lifetime = current_lifetime
  let prev_owner_id = current_owner_id
  current_lifetime = self.lifetime
  current_owner_id = self.id
  try:
    body
  finally:
    current_lifetime = prev_lifetime
    current_owner_id = prev_owner_id

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
  s.to_flatty msg.owner_id
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
  s.from_flatty(i, msg.owner_id)
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
