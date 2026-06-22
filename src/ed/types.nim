import ed/[deps]
import pkg/[serialization, json_serialization]

template ed_ignore*() {.pragma.}
  ## Mark a field to be ignored during `Ed` serialization.

type
  EID* = uint16
    ## Callback identifier for tracking registered callbacks.

  Lifetime* = ref object
    ## A set of teardown actions (typically untracking callbacks). An owner — a
    ## Unit or a scope — holds a Lifetime and `finish`es it on teardown, so
    ## everything bound to it cleans up at once with no manual `zid` bookkeeping.
    ## Standalone (not part of EdBase) so an owner holds one directly.
    cleanups: seq[proc() {.gcsafe.}]
    finished: bool

  RefHandle* = ref object
    ## Per-instance registry-cleanup handle on every `EdRef`. When a registered
    ## ref's last reference drops, ORC destroys this handle and its `=destroy`
    ## records the dead instance for removal from its context's `ref_pool`.
    ##
    ## It identifies the context by *value* (a uid, not a reference): the
    ## destructor must never dereference its `EdContext`, because at teardown the
    ## context can be reclaimed in the same ORC cycle-collection batch as the ref
    ## (a dangling-cursor UAF, caught by ASan). So it only appends the dead id to
    ## `pending_dead_refs`; each context prunes its own dead ids before any
    ## `ref_pool` identity read and on tick. The uid (not `id`, which is reused
    ## across contexts) is what lets a freed ref find the right pool with no live
    ## reference. `ctx_uid`/`ref_id` stay unset until the first `ref_pool` add;
    ## until then `=destroy` is a no-op.
    ctx_uid*: int  # owning context's per-instance uid (0 = unset). NOT the id.
    ref_id*: string

  EdRef* = ref object of RootObj
    ## Base for registered (network-syncable) refs. Carries a `RefHandle` so the
    ## registry can clean up `ref_pool` when ORC reclaims the instance, keeping the
    ## pool's non-owning (cursor) hold from dangling — the subtype's own default
    ## destructor stays intact (only the trivial `RefHandle` gets a custom one).
    id*: string
      ## The ref's identity (sync identity rides on it via `ref_id` = tid:id).
      ## Lives on the base so runtime code (the `destroy` method, `own` scopes,
      ## ownership) can use it without knowing the concrete type.
    ref_handle*: RefHandle
    destroyed* {.ed_ignore.}: bool
      ## Idempotency latch for `destroy`, set at its top. `ed_ignore`: local
      ## teardown state, never synced (a received ref must arrive un-destroyed).
    lifetime*: Lifetime
      ## This ref's teardown actions — external subscriptions and (via `own`) its
      ## owned containers. `destroy` runs `lifetime.finish`. Never synced.

  EdFlags* = enum
    ## Flags controlling `Ed` container behavior.
    TRACK_CHILDREN    ## Propagate changes from nested `Ed` objects
    SYNC_LOCAL        ## Sync changes to other local contexts (threads)
    SYNC_REMOTE       ## Sync changes to remote contexts (network)
    SYNC_ALL_NO_OVERWRITE  ## Sync without overwriting existing data
    LAZY              ## Pull-only: closure pushes / deep-fetch serving skip
                      ## this container — it syncs via explicit fetch or per-key
                      ## requests (big voxel tables). Arrives as a placeholder
                      ## otherwise.
    OWNS_MEMBERS      ## This collection's EdRef members are *owned* by the
                      ## collection's owner: membership registers them in
                      ## `owned_by` (removal un-registers), so the owner's
                      ## `destroy_owned` cascades into them. For true child
                      ## collections (a unit's `units`) — NOT reference
                      ## collections (a sign's owner, a selection list).

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
    REQUEST    # partial replica asking the authority for an object by id
    NOT_FOUND  # authority's NACK: the REQUESTed id isn't there (right now)
    RELEASE    # per-key paging: a replica dropped table keys (obj = key batch).
               # Receivers decide by role: a registered partial subscriber's
               # RELEASE retracts its key interest; one arriving from *upstream*
               # is an eviction notice — drop the keys locally and relay
               # downstream. Full clones forward without evicting; the
               # authority terminates it.

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
    # Phase 1: global ordering (see docs/consistency.md)
    epoch*: int64   # authority epoch; bumped on host/leader change
    lsn*: int64     # global sequence number from the authority (0 = unordered)
    op_id*: int64   # originator-generated id for ack/commit correlation (0 = none)
    origin*: string # ctx id that originated the op (for own-op dedup)
    delta*: bool    # true for collection (non-idempotent) ops, false for registers
    deep*: bool     # REQUEST only: also send the ownership closure (everything
                    # the requested id owns via owned_by, recursively)
    follow*: bool   # REQUEST only: register interest so future ops follow — and,
                    # for a missing id, so it's delivered when it's created later
    key_bin*: string # Table ops only: the serialized key, stamped by
                     # build_message so fanout can filter per-key (LAZY tables /
                     # key interest) without deserializing `obj`. Sender-side
                     # only — blanked from the remote body.
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
    # Non-owning index entry: `obj` is a `{.cursor.}`, so `ref_pool` doesn't keep
    # a registered ref alive. Memory is ORC-owned; the real holders are the
    # containers that `track` it plus the app/Godot node. When the last real
    # reference drops, ORC reclaims the instance and its `RefHandle.=destroy` dels
    # this entry — so the cursor can never dangle (ref_pool[id] non-nil ⟺ instance
    # alive). Requires every registered type to inherit `EdRef`.
    obj* {.cursor.}: ref RootObj

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
    # Partial + deep: push the ownership closure of OWNS_MEMBERS collection
    # members (ahead of the collection / the member ADD). A game client wants
    # this — units arrive render-ready; a narrow utility (enu_mcp) doesn't, and
    # deep-fetches the few things it touches. Explicit per subscription for now;
    # the default may later defer to a per-object preference (an EdFlags bit),
    # making it tri-state.
    deep*: bool
    interest*: HashSet[string]
    # Per-key interest (LAZY tables): object_id -> serialized keys this
    # subscriber has requested. A requested key streams its future ops — even
    # one that was missing at request time (an empty-space voxel chunk someone
    # later builds in). RELEASE retracts. Orthogonal to `interest`: a table in
    # `interest` streams *all* its keys.
    key_interest*: Table[string, HashSet[string]]
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

  FetchState* = enum
    ## Where a `fetch` stands. Resolves on a later tick (the request round-trip).
    Pending   ## request sent; no answer yet
    Found     ## the object (or, for a deep owner fetch, its closure) arrived
    NotFound  ## the authority answered NOT_FOUND — it didn't exist *at fetch
              ## time*. With `follow` (the default) it still arrives later if
              ## something creates it; the handle stays NotFound either way.

  Fetch* = ref object
    ## Handle returned by `fetch`. Watch `state`; once `Found`, `obj` links the
    ## container — except for a deep fetch of an *owner* id (a unit), which has
    ## no container of its own: state resolves via its arriving closure and
    ## `obj` stays nil.
    id*: string
    state*: FetchState
    obj*: ref EdBase

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
    # Phase 1: global LSN + appointed leader (docs/consistency.md)
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
    # Per-key releases buffered between ticks, mirroring pending_key_requests:
    # one RELEASE per table per tick. Broadcast to all peers — upstream reads it
    # as an interest retract, downstream as an eviction notice.
    pending_key_releases*: Table[string, seq[string]]
    # Contexts we subscribed *to* (our data sources). An eviction notice
    # (RELEASE) is honored only when it arrives from upstream — we are a clone
    # of that context, so a key it dropped is gone for us too. This is how
    # partiality inherits down a clone chain (a full clone of a full source
    # never receives one); the authority has no upstream and terminates.
    upstream_ctx_ids*: HashSet[string]
    # This context subscribed partial somewhere: it holds data on demand, not
    # by contract. Gates hub shedding — a partial hub that retracts the last
    # downstream interest in a key drops its own copy and chains the release
    # upstream; a *full* clone never sheds (it wants everything).
    partial_replica*: bool
    # Objects we've already logged a dropped-op notice for (once per id).
    warned_missing*: HashSet[string]
    changed_callback_eid: EID
    last_id: int
    # zid -> object id, for context-level `untrack(zid)`. Plain data on
    # purpose: the old shape stored a closure capturing the proxy, which made
    # the context strong-hold every tracked proxy until explicit untrack —
    # never-collected callbacks (caught by the memory tests). Stale entries
    # for proxies that died untracked linger as tiny strings, pinning nothing.
    close_index: Table[EID, string]
    # The body registry: canonical, registry-owned state per id (phase 2 of the
    # proxy/body split). Proxies are minted on demand over these — see
    # `resolve_proxy`; `ctx[id]` still returns the proxy, so the public API is
    # unchanged.
    objects*: OrderedTable[string, ref EdBodyBase]
    objects_need_packing*: bool
    # Ownership index: owner EdRef id -> ids of the containers it owns (whose
    # `owner_id` points back here). Built as containers are created/materialized,
    # pruned as they're destroyed. Lets an owner tear down what it owns
    # (`destroy_owned`) in *any* context — including one that didn't construct it
    # (e.g. the server cleaning up an MCP-created bot after the client drops).
    owned_by*: Table[string, HashSet[string]]
    # In-flight fetches by id; resolved (Found/NotFound) as answers arrive, then
    # removed. Re-fetching after a NotFound mints a fresh handle.
    fetches*: Table[string, Fetch]
    # Request chaining (hubs): wants we couldn't serve locally, forwarded
    # upstream and remembered here. Served when the data arrives; NACK-relayed
    # when the upstream answers NOT_FOUND. The authority never forwards — a
    # miss there is a real NOT_FOUND.
    pending_obj_wants*:
      Table[string, seq[tuple[sub: Subscription, deep: bool, follow: bool]]]
    # object_id -> key_bin -> waiting subscribers (per-key table requests).
    pending_key_wants*: Table[string, Table[string, seq[Subscription]]]
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

  EdBodyBase* = object of RootObj
    ## Registry-side state of a container — the *body* of the proxy/body split
    ## (docs/proxy-body-design.md). Carries the data and everything the wire
    ## needs; the app-facing proxy (`Ed`) forwards here via templates, so call
    ## sites read unchanged. Phase 1 is purely structural: each proxy
    ## strong-holds its body 1:1 and the registry still holds proxies — bodies
    ## become registry-owned (and proxies weak-backref'd) with the identity
    ## map in phase 2.
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
    flags*: set[EdFlags]
    build_message: proc(
      body: ref EdBodyBase, change: BaseChange, id: string, trace: string
    ): Message {.gcsafe.}

    publish_create: proc(
      sub = Subscription(),
      broadcast = false,
      op_ctx = OperationContext(),
      contents = true, # false = handle only (empty-body CREATE; LAZY push)
    ) {.gcsafe.}

    change_receiver:
      proc(body: ref EdBodyBase, msg: Message, op_ctx: OperationContext) {.gcsafe.}

    # Per-key fetch (partial EdTable). Given a serialized key, build the ADD op
    # carrying that key's current value, so a partial subscriber can pull one
    # entry without the whole table. `found = false` if the key isn't present.
    # `nested` lists Ed containers inside the value (a chunk's delta seq) — the
    # server publishes those *before* the entry so the receiver links them
    # (per-key deep, one round trip). nil for non-table containers.
    publish_key:
      proc(
        body: ref EdBodyBase, key_bin: string
      ): tuple[found: bool, msg: Message, nested: seq[string]] {.gcsafe.}

    # Per-key eviction (paging). Given a serialized key, drop the entry locally
    # — fires REMOVED callbacks, no publish — and report whether it was present
    # plus the ids of Ed containers nested in its value (so the caller can shed
    # interest / relay them). The local half of `release` and the receiving half
    # of a RELEASE eviction notice. nil for non-table containers.
    evict_key:
      proc(
        body: ref EdBodyBase, key_bin: string
      ): tuple[found: bool, nested: seq[string]] {.gcsafe.}

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
    # The live proxy for this body, or nil. Non-owning ({.cursor.}): the app
    # and containers own proxies; when the last reference drops, the proxy's
    # ProxyHandle records the death and `prune_dead_proxies` clears this —
    # always *before* an identity read, so the cursor is never read dangling
    # (the RefHandle discipline, applied to containers).
    proxy {.cursor.}: ref EdBase
    proxy_gen: int
    # Typed proxy factory, wired in `defaults` (the only place the concrete
    # Ed[T, O] is known). Mints over this body, sets the backref + handle.
    mint: proc(): ref EdBase {.gcsafe.}
    # Typed context-level untrack (see EdContext.close_index): untracks `zid`
    # on the live proxy, or no-ops — a dead proxy already took its callbacks
    # with it. Captures only the body (the mint pattern).
    untrack_zid: proc(zid: EID) {.gcsafe.}
    # Sweep callbacks registered through a now-dead proxy generation; returns
    # the swept zids so the context can clear its close_index. Typed work
    # behind an untyped hook (the publish_key pattern).
    sweep_gen: proc(gen: int): seq[EID] {.gcsafe.}

  ChangeCallback[O] = proc(
    changes: seq[Change[O]], it: ref EdBase
  ) {.gcsafe.}
    ## Stored callback shape: the live proxy arrives as a *parameter* (`it`),
    ## never a capture — parameters pin nothing, so a watcher written against
    ## `it` lets its proxy die promptly at refcount zero. `it` is nil only for
    ## CLOSED notifications fired after the proxy is already gone.

  EdBody*[T, O] = ref object of EdBodyBase
    ## Typed body: the canonical data AND the callbacks live here — registry-
    ## owned, no reliance on cycle collection (which Nim's ORC empirically
    ## does not perform for closure environments). A closure stored here must
    ## capture nothing that reaches a body or a context, or it leaks for the
    ## registry's lifetime; the `it` parameter exists so it never needs to.
    tracked: T
    changed_callbacks: OrderedTable[EID, ChangeCallback[O]]
    # zid -> proxy generation that registered it. When a dead proxy's gen is
    # pruned, its callbacks sweep with it — deterministic next-tick cleanup.
    callback_gens: Table[EID, int]
    link_eid: EID
    paused_eids: set[EID]

  ProxyHandle* = ref object
    ## Per-proxy registry-cleanup handle (the container twin of `RefHandle`).
    ## When a proxy's last reference drops, ORC destroys its fields and this
    ## handle's `=destroy` records the death for the context to prune — the
    ## destructor dereferences *nothing* (the context, even the body, may be
    ## reclaimed in the same ORC batch). `gen` guards out-of-order prunes: a
    ## body only clears its backref if the dead proxy was its *current* one.
    ctx_uid*: int
    object_id*: string
    gen*: int

  EdBase* = object of RootObj
    ## Base type for all `Ed` containers — the *proxy* side of the split: what
    ## the app holds. Local, handle-scoped state only (change callbacks and
    ## their EID bookkeeping die with the proxy); everything synced forwards
    ## to `body`. Minted by `ctx[id]`/`resolve_proxy` when none is live —
    ## reference identity holds because the body's backref always points at
    ## *the* live proxy (prune-before-read keeps it honest).
    body*: ref EdBodyBase
    proxy_handle: ProxyHandle
    bound_eids: seq[EID]

  EdObject[T, O] = object of EdBase

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

# Proxy → body forwarding (proxy/body split, phase 1). Templates expand at the
# call site, so existing field accesses — reads *and* writes — compile
# unchanged; private body fields still require `privileged` there, preserving
# today's visibility discipline. The typed `tracked` forward casts through
# `EdBody[T]`; everything else lives on the untyped base.
template tracked*[T, O](self: Ed[T, O]): untyped =
  EdBody[T, O](self.body).tracked

template typed_body*[T, O](self: Ed[T, O]): EdBody[T, O] =
  EdBody[T, O](self.body)

template id*(self: ref EdBase): untyped =
  self.body.id

template owner_id*(self: ref EdBase): untyped =
  self.body.owner_id

template destroyed*(self: ref EdBase): untyped =
  self.body.destroyed

template placeholder*(self: ref EdBase): untyped =
  self.body.placeholder

template flags*(self: ref EdBase): untyped =
  self.body.flags

template ctx*(self: ref EdBase): untyped =
  self.body.ctx

proc init_husk*[T, O](_: typedesc[Ed[T, O]], id: string): Ed[T, O] =
  ## A bare serialization stand-in: proxy + body carrying only the id. Used by
  ## registered-type `stringify`, which clones a ref and reduces its Ed fields
  ## to their ids — the receiver re-links them from its own registry. Not
  ## registered anywhere; never escapes serialization.
  result = Ed[T, O]()
  result.body = EdBody[T, O](id: id)

# The sync closures: the call-arity procs forward invocations (a dotted call
# through a proc field parses as a call of the *symbol*, so a field-resolving
# template alone can't take the arguments). Assignment and nil checks go
# through `self.body.X` directly under `privileged`.
proc build_message*(
    self: ref EdBase, slf: ref EdBase, change: BaseChange, id, trace: string
): Message {.gcsafe.} =
  self.body.build_message(slf.body, change, id, trace)

proc publish_create*(
    self: ref EdBase,
    sub = Subscription(),
    broadcast = false,
    op_ctx = OperationContext(),
    contents = true,
) {.gcsafe.} =
  self.body.publish_create(sub, broadcast, op_ctx, contents)

proc change_receiver*(
    self: ref EdBase, slf: ref EdBase, msg: Message, op_ctx: OperationContext
) {.gcsafe.} =
  self.body.change_receiver(slf.body, msg, op_ctx)

proc publish_key*(
    self: ref EdBase, slf: ref EdBase, key_bin: string
): tuple[found: bool, msg: Message, nested: seq[string]] {.gcsafe.} =
  self.body.publish_key(slf.body, key_bin)

proc evict_key*(
    self: ref EdBase, slf: ref EdBase, key_bin: string
): tuple[found: bool, nested: seq[string]] {.gcsafe.} =
  self.body.evict_key(slf.body, key_bin)

var next_ctx_uid*: Atomic[int]
  ## Global source of `EdContext.uid`. Must be process-wide: the dead-handle
  ## pending tables are global (a context can be created on one thread and
  ## live on another), so colliding uids across threads would misattribute
  ## deaths — a thread-local counter did exactly that (two threads' first
  ## contexts both got uid 1, one drained the other's records, and the
  ## undrained backref cursor dangled).

var dead_handles_lock: Lock
dead_handles_lock.init_lock

var pending_dead_refs*: Table[int, seq[string]]
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
      dead_handles_lock.acquire()
      pending_dead_refs.mget_or_put(h.ctx_uid, @[]).add(h.ref_id)
      dead_handles_lock.release()
  `=destroy`(h.ref_id)

var pending_dead_proxies*: Table[int, seq[(string, int)]]
  ## ctx uid -> (object_id, gen) of container proxies ORC has reclaimed.
  ## Populated by `ProxyHandle.=destroy` (which must touch nothing); drained by
  ## `prune_dead_proxies` before any proxy-identity read and on tick. Global +
  ## lock-guarded (NOT a threadvar): a context can be created on one thread —
  ## minting proxies there — and then live on another (the threading tests'
  ## worker handoff), so deaths must be visible to the pruning thread.

proc `=destroy`(h: var typeof(ProxyHandle()[])) =
  ## Records a dead proxy for its context to prune. Dereferences nothing — the
  ## body and even the context may be reclaimed in the same ORC batch. A custom
  ## `=destroy` replaces field destruction, so `object_id` is freed by hand.
  if h.ctx_uid != 0 and h.object_id.len > 0:
    {.cast(gcsafe).}:
      dead_handles_lock.acquire()
      pending_dead_proxies.mget_or_put(h.ctx_uid, @[]).add((h.object_id, h.gen))
      dead_handles_lock.release()
  `=destroy`(h.object_id)

proc prune_dead_proxies*(self: EdContext) =
  ## Clear body→proxy backrefs whose proxies ORC has reclaimed. Must run before
  ## any backref read so a dangling cursor is never returned; `gen` ensures a
  ## late prune can't clear a *newer* proxy minted after the death was recorded.
  {.cast(gcsafe).}:
    var dead: seq[(string, int)]
    dead_handles_lock.acquire()
    if self.uid in pending_dead_proxies:
      dead = pending_dead_proxies[self.uid]
      pending_dead_proxies.del(self.uid)
    dead_handles_lock.release()
    for (object_id, gen) in dead:
      if object_id in self.objects and self.objects[object_id] != nil and
          self.objects[object_id].proxy_gen == gen:
        let body = self.objects[object_id]
        body.proxy = nil
        # The dead proxy's callbacks die with it — registered through it,
        # cleaned when it goes (the sentinel model). Deterministic: next
        # prune, not cycle-collector cadence.
        if body.sweep_gen != nil:
          for zid in body.sweep_gen(gen):
            self.close_index.del(zid)

proc resolve_proxy*(self: EdContext, body: ref EdBodyBase): ref EdBase =
  ## The identity map: the one live proxy for `body`, minting if none. Two
  ## resolutions of the same id are reference-equal while anything holds the
  ## proxy — honest `ref` identity (docs/proxy-body-design.md).
  if body == nil:
    return nil
  self.prune_dead_proxies
  if body.proxy != nil:
    return body.proxy
  if body.mint != nil:
    return body.mint()

proc release_closures*(body: ref EdBodyBase) =
  ## Break the body's self-capturing closures (mint/untrack_zid/sweep_gen all
  ## capture the body). Required at unregistration: ORC does not collect
  ## closure cycles, so an unreleased body would leak with its environment.
  body.mint = nil
  body.untrack_zid = nil
  body.sweep_gen = nil

proc drop_nested_bodies*(self: EdContext, nested: seq[string]) =
  ## Unregister the nested container bodies an evicted entry carried (a paged-
  ## out chunk's delta seq): the registry releases its strong hold, so the
  ## memory frees once any remaining holder drops, and the id resolves fresh
  ## on re-page-in. Local only — eviction never destroys upstream data.
  for id in nested:
    if id in self.objects:
      let body = self.objects[id]
      if body != nil:
        if body.owner_id.len > 0 and body.owner_id in self.owned_by:
          self.owned_by[body.owner_id].excl id
        body.release_closures
      self.objects.del id


proc prune_dead_refs*(self: EdContext) =
  ## Remove from `ref_pool` the entries whose instances ORC has reclaimed (see
  ## `pending_dead_refs`). Must run before any `ref_pool` identity lookup so a
  ## dangling cursor is never read, and on tick to keep the pool tidy. Idempotent;
  ## cheap when nothing is pending.
  {.cast(gcsafe).}:
    var dead: seq[string]
    dead_handles_lock.acquire()
    if self.uid in pending_dead_refs:
      dead = pending_dead_refs[self.uid]
      pending_dead_refs.del(self.uid)
    dead_handles_lock.release()
    for ref_id in dead:
      self.ref_pool.del(ref_id)

proc to_flatty*(s: var string, x: RefHandle) =
  ## Per-context-local state (uid + id), never synced — its uid is meaningless in
  ## another context. Skip it; `ref_count` re-mints the handle on the receiver's
  ## first ADD.
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

template own*(owner_id: string, body: untyped) =
  ## Like `self.own:`, but keyed by an owner *id* — for construction, where you
  ## have the id but the owner object doesn't exist yet. Every Ed container created
  ## in the block (including by procs it calls — the scope is dynamic) records
  ## `owner_id`. No lifetime is set; callbacks bind via the `EdRef` form once the
  ## owner exists.
  let prev_owner_id = current_owner_id
  current_owner_id = owner_id
  try:
    body
  finally:
    current_owner_id = prev_owner_id

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
  s.to_flatty msg.deep
  s.to_flatty msg.follow
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
  s.from_flatty(i, msg.deep)
  s.from_flatty(i, msg.follow)
  when defined(ed_trace):
    s.from_flatty(i, msg.trace)
    s.from_flatty(i, msg.id)
    s.from_flatty(i, msg.debug)
