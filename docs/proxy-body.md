# Proxy/Body Split

The v2 container object model, building on `object-lifecycle.md`. Each container is
two objects: a registry-owned **body** (the data + everything the wire needs) and a
GC-owned **proxy** (the thin `ref` the app holds). `ctx[id]` returns the proxy;
field access on the proxy forwards to the body through templates, so call sites
(and all of enu) compile unchanged.

## Why

A mostly-unloaded world shouldn't pay for per-id object shells — a husk costs
~300+ bytes (six per-instance closure envs), and every referenced-but-unloaded id
paid it. Bodies make cold objects cheap and persistable; the proxy is the cheap,
reconstructible handle whose liveness drives local-resource and interest decisions.

## Settled decisions

- **True ref proxy.** The proxy is a `ref`; `==` is reference identity, never an id
  override. No value proxies, no tombstones. `ctx[id]` must return *the* live proxy
  while one exists, or `state.open_unit == self` breaks — so identity is
  load-bearing (`resolve_proxy`).
- **Registry-owned bodies.** `EdContext.objects` maps `id → ref EdBodyBase`
  (strong). The body carries `tracked`, sync state, and the sync closures
  (`build_message`/`change_receiver`/`publish_*`/per-key). Storage is a tier seam:
  `id → live body | serialized bin | absent`; evicting on a replica drops to absent
  (upstream re-serves), persisting later demotes to bin — the CREATE bin already
  *is* the serialization format.
- **Identity map via deferred prune (not `GC_ref`).** The body holds a *non-owning*
  (`{.cursor.}`) backref to the live proxy. The proxy's `ProxyHandle.=destroy`
  dereferences nothing — it records `(ctx_uid, object_id, gen)` on a lock-guarded
  global pending list; `prune_dead_proxies` clears dead backrefs *before any
  identity read* and on tick. `resolve_proxy` returns the live proxy via the
  backref or mints one over the body. `gen` guards an out-of-order prune from
  clearing a newer proxy. This is exactly the `RefHandle`/`ref_pool` discipline,
  applied to containers — the old "weak-backref + GC_ref dance" risk is solved.

  *Cross-thread (load-bearing):* the pending tables are lock-guarded **globals**,
  not threadvars — a context can be minted on one thread and live on another — and
  once global, `EdContext.uid` must be a **process-global atomic** (two threadvar
  counters both minting uid 1 drained each other's deaths: a silent UAF only
  client_smoke caught).

## Callbacks live on the body (sentinel model)

Empirically, **Nim ORC does not collect closure-environment cycles** (reproduced
with no ed involved). So a proxy-side self-capturing watcher could never reclaim.
The fix:

- **The body owns the callbacks** (`changed_callbacks`/`paused_eids`/`link_eid` on
  `EdBody[T, O]`). The proxy is a *sentinel* — body ref + `ProxyHandle`, nothing
  else — so it dies promptly at refcount zero, and the next prune sweeps the
  callbacks registered through its generation (`callback_gens`/`sweep_gen`). This is
  the scripting workflow: fetch → watch → drop → reclaimed, no GC heroics.
- **The live proxy reaches a callback as a parameter (`it`), never a capture** —
  stored shape `proc(changes, it: ref EdBase)`; 1-arg `track` callbacks wrap. So a
  watcher written against `it` pins nothing and dies with its proxy.
- **Capture rule:** a closure stored on a body must capture nothing that reaches a
  body or context. The body's own self-capturing closures
  (`mint`/`untrack_zid`/`sweep_gen`, and `publish_create`, which also reaches the
  context) are released explicitly at unregistration (`release_closures`) — leaving
  them set re-introduces the object↔context cycle the cursor backref broke, and ORC
  won't collect it.
- A **narrow static warning** fires only when a `changes`/`watch` body references
  the watched container as a bare identifier — the genuine self-capture footgun
  (a root-ident version was 67/91 noise on enu; the bare-ident version: 0).

Lifetime/untrack remains the contract for side-effecting watchers; sentinel
collection is the safety net and the scripting default.

## Notes

- Proxy→body indirection is on every access; hot read paths (voxel render) were
  benchmarked across the mechanical split.
- Paging out (per-key evict) also unregisters an evicted entry's nested container
  bodies (the orphaned `chunk_deltas` seqs) — identity is intentionally *not*
  preserved across page-out (re-page-in resolves a fresh body+proxy; watchers died
  with the proxy, the Lifetime story working as designed).
- The touch/LRU evictor that uses proxy-liveness as its safety gate is in
  `partial-replicas.md` (the eviction layer).
