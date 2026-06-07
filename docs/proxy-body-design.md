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

## Sentinel rework — callbacks move to the body (2026-06-07 morning; ed 45f956e/dda7431+)

Driven by an empirical finding: **Nim ORC does not collect closure-environment
cycles** (three pure-Nim repros, no ed involved). Proxy-side callbacks could
therefore never reclaim — a self-capturing watcher pinned its proxy forever.
Settled with Scott:

- **Body owns the callbacks** (`changed_callbacks`/`paused_eids`/`link_eid` on
  `EdBody[T, O]`); the proxy is a *sentinel* — body ref + ProxyHandle, nothing
  else — so it dies promptly at refcount zero, and the next prune sweeps the
  callbacks registered through its generation (`callback_gens`/`sweep_gen`).
  This is the mcp workflow: fetch → watch → drop → reclaimed, no GC heroics.
- **The live proxy reaches callbacks as a parameter** (`it`), never a capture:
  stored shape `proc(changes, it: ref EdBase)`; 1-arg `track` callbacks wrap.
  The `changes`/`watch` sugar injects `it` and no longer captures the proxy
  for pause bookkeeping.
- **Capture rule**: a closure stored on a body must capture nothing that
  reaches a body or context; body self-captures (mint/untrack_zid/sweep_gen)
  are released explicitly at unregistration (`release_closures`).
- **Static warning, narrowly scoped**: the sugar warns only when the watched
  expression is a bare identifier the body references — the genuine
  self-capture footgun. Survey: 0/91 enu watch sites fire (their `self`/
  `state` captures are indirect, Lifetime-managed pins, deliberately out of
  jurisdiction — a root-ident version would have fired on 67/91 = noise).
  ed's own 3 test self-captures migrated to `it` (validating the injection);
  enu builds warning-free.
- Lifetime/untrack discipline remains the contract for side-effecting
  watchers; sentinel collection is the safety net and the scripting-consumer
  default, not a replacement.

## Phase 4 as built — evictor (2026-06-07; ed b3f180f, enu 3558dcbb)

Policy settled with Scott to the simplest defensible shape:
- **CHURN_LIMIT (=8), always on**: a dormant body taking that many ops is pure
  waste (refill is one fetch) — evict regardless of memory. Size-independent.
- **Pure LRU to `mem_limit`**: over budget, shed oldest `last_read` first. Size
  does *not* rank — that's the min-expected-refetch-optimal choice; the earlier
  `× bytes` would have evicted big-recently-left voxels (the player case). Under
  budget, keep everything (instant re-entry).
- Accounting (cheap): `last_read` (read-touch), `bytes` (wire-maintained,
  `used_bytes` running sum), `updates` (churn). `mem_limit` 0 = off (authority,
  full clones). enu: client worker 16 MiB; "ed mem" on the stats screen.
- `evict_candidate` gate: no live proxy, **no downstream interest** (the reverse
  link to our own upstream does not count — the bug that first blocked it), not
  a live-owned piece, has data. `evict_body` = local drop + whole-object RELEASE
  upstream (empty key batch) to retract interest. A received whole-object RELEASE
  is a subscriber's interest-retract, or from upstream an eviction notice that's
  **ignored while we hold it live** (Scott's rule); no downstream relay (the gate
  guarantees nobody below wants it).

Caveats carried forward (validate as data warrants): per-key churn for LAZY
tables not built (whole-body only; LAZY tables are excluded from candidates, so
safe but coarse — a per-key signal is the refinement); `approx_bytes` is
wire-weight, not the Godot mesh memory that actually dominates voxels (un-render
frees that, not ed eviction — measure which pool is the real constraint);
follow=false Fetch handles retain their proxy until ORC reclaims the handle, so
residue evicts a tick or two after the handle drops; temporal LRU misses the
spatial "walking back toward it" case (an enu view-distance hint is the future
lever). The memory-target master dial (adaptive aggressiveness) is designed-for,
not built.
