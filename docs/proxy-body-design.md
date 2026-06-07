# Proxy/Body Split — Settled Design + Plan

> Status: **plan of record** (2026-06-07). Supersedes the step-two section of
> `object-lifecycle-design.md` (the value-proxy/tombstone fork is dead) and picks
> up where `step4-body-protocol-sketch.md` deferred ("the proxy + live_handle
> observability, touch/LRU policy, interest-set integration"). Registered refs
> (EdRef/RefHandle) are done; this is the **container** half.

## Settled decisions

- **True ref semantics.** The proxy is a `ref`; `==` is reference identity, never
  an id override. No value proxies, no tombstones. `ctx[id]` must return *the*
  live proxy while one exists.
- **Registry-owned bodies.** Data storage moves out of the app-held object into
  an id-keyed body record. A mostly-unloaded world holds registry entries (or
  nothing — see storage tiers), not per-id object shells: husks today cost ~300+
  bytes each (six per-instance closure envs), and every referenced-but-unloaded
  id pays it. Bodies make cold = cheap and persistable.
- **Identity map via deferred prune, not GC_ref.** The registry holds a
  *non-owning* backref to the live proxy. The proxy's `=destroy` dereferences
  nothing: it records `(ctx_uid, object_id)` in a thread-local pending list; the
  registry prunes before identity reads and on `tick`. This is the exact pattern
  `RefHandle` shipped for `ref_pool` (see step4 sketch's IMPLEMENTED note) — the
  original "weak-backref + GC_ref dance" risk is solved, not accepted.
- **Eviction = touch/LRU + interest (policy) gated on no-live-proxy (safety).**
  Never GC-liveness alone (thrashes). Partial replicas evict freely (re-fetch
  upstream is always possible — same guarantee paging relies on); the
  **authority never evicts** until the durable log exists (eviction without
  backing = data loss).
- **Two callback homes.** Sync-relevant callbacks live on the body (they must
  survive proxy churn); app `track`/`watch` callbacks live on the proxy and die
  with it — which *is* the Lifetime story, for free.

## Object model

```
Body = object                     # registry-owned, id-keyed
  id, owner_id, flags, destroyed, placeholder
  last_touched: MonoTime          # coarse touch (below)
  tracked: T                      # the data
  # sync machinery: build_message/change_receiver/publish_* closures,
  # link state, frontier bits — everything the wire needs
  proxy: ptr                      # non-owning backref to the live proxy ("" = none)

Ed[T, O] = ref object             # the proxy — what the app holds; stays the
  ctx {.cursor.}: EdContext       # public type, so call sites don't change
  body: <resolved via registry>   # cursor/ptr; prune discipline keeps it valid
  changed_callbacks               # local watches die with the proxy
  handle                          # =destroy -> pending list (RefHandle pattern)
```

`ctx[id]`: live proxy via backref → return it; else mint a proxy over the body
(or over a placeholder body for unknown ids — existing materialize machinery).
Two lookups are reference-equal; `state.open_unit == self` keeps working.

## Storage tiers (the persistence seam)

The registry maps `id → live Body | serialized bin | absent`. Evicting on a
replica = drop to absent (upstream re-serves). Persisting (authority, later) =
demote to bin / flush to disk — the CREATE bin *is* the serialization format, and
the type initializer is the loader, both already battle-tested by the network
path. Disk tiering becomes a registry concern; holders never know.

## Touch

Coarse events only: materialize/fetch/request, `track`, and writes stamp
`last_touched`. Hot read paths (voxel rendering) stay unstamped — LRU is
approximate, which is fine for "is this *cold*?". Revisit only if eviction
decisions prove wrong in practice.

## Plan

1. **Mechanical split, API frozen.** Introduce `Body` behind `Ed[T, O]`; move
   `tracked` + sync closures into it; proxy forwards. Registry still strong-holds
   both, nothing evicts. Gate: full suite green (this step is pure refactor).
2. **Identity map + deferred prune.** Registry holds body strong + proxy backref
   non-owning; proxy `=destroy` → pending list → prune-before-read/tick.
   Gate: ASan (`tests/asan.sh`) — this is the UAF-class step.
3. **Close the paging gap.** Per-key evict (RELEASE/`release`) also drops an
   evicted entry's nested container bodies (the orphaned `chunk_deltas` seqs
   pinned in `ctx.objects` today). "ed objects" in the stats screen starts
   moving with paging.
4. **Evictor.** Touch/LRU sweep on partial replicas: cold body + no live proxy +
   outside interest → drop to absent, retract interest upstream (per-key
   machinery generalized to object granularity). Unit-level paging (registered
   refs + members) rides the same sweep later — out of scope for the first cut.
5. **enu validation.** world_tests + client_smoke + manual walk; Valgrind leak
   pass on Linux remains the standing follow-up for the leak half.

## Costs being accepted

- Proxy→body indirection on every access — watch the voxel render loops
  (benchmark before/after step 1).
- The mechanical split touches everything in `zens/` — big diff, but step 1 is
  semantics-preserving and the suite is the net.
- Two callback registries (body=sync, proxy=local) — clarifies, but migration
  must sort existing callbacks correctly (`trigger_callbacks` fans to both).

## Open (decide when reached)

- Eviction scope for registered refs (unit paging) — phase 4 follow-up.
- Whether `flags`/`owner_id` reads need the body resident or get mirrored on the
  proxy (likely mirror: they're tiny and identity-stable).

## As built — phases 1–3 (2026-06-07, overnight; ed d3b87a8/37950ec/8da225b/ee4be04)

Gates at every step: suite green, ASan clean, enu builds **untouched** +
world_tests; client_smoke 10/10 after the last fix. Decisions taken solo,
flagged 🔶 for review:

- 🔶 **EID bookkeeping (link_eid/paused_eids/bound_eids) stayed on the proxy.**
  Links register in the *child's* callback table, and child proxies are
  strong-held via the parent body's `tracked` — so links live exactly as long
  as both ends are held. The planned body-level `sync_callbacks` home turned
  out unnecessary: all callbacks are app-side; publish is separate.
- 🔶 **change_receiver / per-key closures resolve (mint) the proxy at call
  time.** Mint-on-receive churn for un-held objects is accepted for now; a
  body-direct apply path (skip minting when no live proxy and no links) is the
  obvious optimization if profiling complains.
- 🔶 **Evicted-but-held nested bodies:** a holder keeps a frozen husk; re-page-
  in resolves a *fresh* body+proxy. Identity is intentionally not preserved
  across eviction ("drop to absent") — nothing in enu durably holds delta seqs
  across page-out (watchers die with the proxy, which is the Lifetime story
  working as designed).
- **Two cross-thread bugs the pattern-copy hid** (both would have been silent
  UAFs): the pending dead-handle tables must be **lock-guarded globals**, not
  threadvars — a context can be created on one thread and live on another
  (threading tests' worker handoff) — and once global, `EdContext.uid` must be
  **process-global** (atomic counter): two threads' threadvar counters both
  minted uid 1 and drained each other's deaths. The unit suite caught the
  first; only client_smoke caught the second. `pending_dead_refs`/`RefHandle`
  had both hazards latently and got the same fix.
- The `tracked`/field forwarding templates + call-arity procs keep every call
  site and the entire enu source compiling unchanged — the "big invasive
  refactor" cost from the original doc largely didn't materialize.
- **Phase 4 (touch/LRU evictor) deliberately not built overnight** — its
  policy knobs (sweep cadence, coldness threshold, interest interaction, what
  counts as a touch) are review-first material.
