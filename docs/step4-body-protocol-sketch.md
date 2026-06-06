# Step 4 — Body Protocol + ref_pool Move/Eviction Model (sketch)

First concrete piece of the v2 object model. Captures decisions reached in design
discussion; **a plan, not final code.**

## Decisions carried in

- **Two registries kept** (`objects` = Ed containers, `ref_pool` = registered refs).
  They have different lifecycles; step-4's new behavior lands mostly on `ref_pool`.
  Share a *protocol*, not a table. (See `step3-reachability-audit.md` for why.)
- **Honest `ref` identity** — `==` means reference identity, never an id-equality
  override.
- **Eviction is touch/LRU + interest**, never GC-liveness ("dropped the handle →
  evict" would thrash voxels).
- **Registry-strong body, `REMOVE` ≠ `DESTROY`** — a body is freed only by an
  explicit/sync `DESTROY` (registry releases) or by eviction; a container removal
  just unlinks. This is what gives move-identity for free.
- **ORC owns *memory*; the `references` set is *not* a memory refcount** — per the
  reachability audit, Ed containers strong-hold registered refs via `tracked`, so
  ORC reclaims when the registry and all holders release. `references` survives only
  as a *reachability hint* (see eviction).

## Removal discipline in enu (verified — closes the 4a risk)

Traced how units are actually removed. **enu always destroys on removal; there is no
move-preserving reparent.** Removing a unit from any units collection fires `REMOVED`,
watched on *both* threads — node side (`node_controllers`: `remove_from_scene →
destroy + queue_free`, at all three levels) and worker side (`for_all_units`:
`unmap + destroy`). And `remove_from_scene`/`destroy` are reached *only* through those
removal watchers, never directly. So `-=` is already the universal destroy trigger.

Consequences: (1) the 10s grace / cross-tick move-identity is **dead code from enu's
view** — nothing depends on a body surviving a `REMOVE`, so dropping the grace is safe;
(2) the goal "`-=` is enough (once all proxy refs are gone)" is a *cleanup*, not a new
model — enu is already removal-driven. The delta is: today the watchers hand-choreograph
teardown and destroy **unconditionally** (a latent dangling-ref hazard if anything still
holds the unit); the goal lets ORC's `=destroy` fire only when the unit is **truly
unreferenced**, and auto-enqueue the dereg.

## The clarified role of a proxy (important)

The original design pitched "proxy liveness IS the eviction signal." We rejected
that (touch/LRU instead). So what is a proxy *for*? **Safe-eviction observability.**
Eviction needs two independent conditions:

- **policy:** the body is cold (touch/LRU) and/or outside the interest set, AND
- **safety:** nothing local still references it — otherwise dropping it splits
  identity (a held ref + a re-synced fresh instance = two objects for one id).

Touch/LRU answers *policy*. The thing that answers *safety* — "is any local handle
still alive?" — is a single observable handle whose liveness the registry can see.
That, and only that, is what justifies a proxy. **So the proxy is needed exactly
when we start evicting — i.e. the partial-replica phase — and not before.**

Consequence: **the first piece needs no proxy split.** Full replicas free on
`DESTROY`; nothing is evicted; bodies are the registered refs themselves, strong-
held by `ref_pool`, released on `DESTROY`. Move-identity falls out. The proxy +
observability land later, with eviction.

## The shared body protocol

A minimal contract both registries satisfy (mixed into / parallel to the existing
records, not a forced common base type):

```
BodyMeta = object
  id: string
  destroyed: bool          # the only survivor of the "tombstone" — drives `?`
  last_touched: MonoTime    # for the future touch/LRU evictor
  # later (eviction phase only):
  # live_handle {.cursor.}: <proxy>   # non-owning; the one live handle, for safety
```

Invariants:
- The registry holds the body **strong** while alive.
- `?body` ≙ `not body.destroyed and not body.placeholder` (usable/materialized).
- A container `REMOVE` never sets `destroyed`. Only a `DESTROY` (or evict) does.
- On `DESTROY`: set `destroyed`, registry releases its strong ref. Any other holder
  keeps the memory valid (ORC); it's reclaimed when the last holder drops.

Operations (registry-side): `lookup(id)`, `mark_destroyed(id)`, `touch(id)`, and —
eviction phase only — `evict_candidates()` / `reclaim`.

## `ref_pool` → body registry (the first piece)

Today:
```
CountedRef = object
  obj*: ref RootObj            # strong hold (identity map + keep-alive)
  references*: HashSet[string]  # which Ed containers hold it (memory refcount)
# ref_count: on last REMOVE -> freeable_refs[id] = now+10s ; free_refs sweeps after
```

After (4a):
```
RefBody = object
  obj: ref RootObj            # still the strong, canonical instance (the "body")
  references: HashSet[string]  # REFRAMED: reachability hint, not a free trigger
  meta: BodyMeta
```
Changes:
- **`REMOVE` no longer schedules a free.** Drop `freeable_refs` + the 10s grace +
  the `free_refs` sweep. `ref_count` still maintains `references` (for reachability),
  but `references.card == 0` is *not* a free trigger anymore.
- **Free only on `DESTROY`** (or, later, evict): `DESTROY` sets `meta.destroyed` and
  removes the id from `ref_pool`. ORC reclaims `obj` once containers/app also release.
- **`from_flatty` dedup unchanged in spirit** — still `if ref_id in ref_pool: reuse`
  (subscriptions.nim:125). Because the body now persists across a `REMOVE`, a
  cross-tick replica move re-links the same instance with **no timer** — strictly
  better than the 10s window, which it replaces.

Move-identity, restated in the new model: a replica gets `REMOVE` (unlink, body
stays) then later `ADD` (re-link by id → same `obj`). Identity holds for any gap.

## What `objects` (container registry) does

Less. Containers are created in place, owned by their registered ref, and die by
**owner-cascade** (a Unit's `destroy` already walks `self[].fields`). They don't
move and aren't independently evicted, so they need neither move-identity nor (in
4a) the proxy treatment. They adopt the same "registry-strong body, freed on
owner-destroy" rule; that's it.

(Caveat for the partial-replica phase: per-key voxel `release` evicts *within* a
container — finer granularity than whole-object. That's where a container might gain
its own eviction handle. Out of scope for 4a.)

## The mechanism (sharpened): ref_pool non-owning + `register`-emitted `=destroy`

The crux the audit found: `ref_pool[id].obj` strong-holds the ref, so ORC never sees
refcount 0 and can't drive freeing. To make lifetime ORC-driven (the "`-=` is enough"
goal), **`ref_pool`'s hold becomes non-owning** (`{.cursor.}` / pointer), and the
ref's real lifetime is its Nim refcount (collections' `tracked` + app + Godot node).
When the last real ref drops, ORC frees → a **`register`-emitted `=destroy`** runs and:
1. dels the `ref_pool[id]` entry (so the cursor never dangles — same deterministic-ORC
   safety as the proxy slot: `ref_pool[id]` non-nil ⟺ ref alive, because `=destroy`
   removes it synchronously on free), and
2. **enqueues** id-based sync cleanup (dereg / `DESTROY` broadcast) for the next
   `tick` — never network/complex work in the destructor.

This collapses, in one coupled change (they can't land piecemeal and stay green):
- `freeable_refs` + the 10s grace + `free_refs`'s grace sweep → **gone**.
- `ref_count`'s `references` book-keeping → keep only as a reachability hint (no longer
  a free trigger); on a replica a ref freed by `REMOVE`+ORC is the new normal.
- explicit `ctx.free(self)` / `queue_free` (units.nim:204, node_controllers.nim:158)
  → **retire**; the ref dies when unreferenced. Godot `node.queue_free()` stays.
- `from_flatty` dedup (`subscriptions.nim:125`) → unchanged in spirit, reads the
  now-non-owning `ref_pool[id]` (alive by the invariant above).

Emission site: the `register` macro (`type_registry.nim:189`), alongside
`register_type` / `build_accessors`.

### Costs / gates
- **UAF-class change — ASan-gated.** The cursor-in-ref_pool + destructor is exactly the
  silent-UAF risk the lifecycle decision log said not to land on functional-green alone.
  Validate with `tests/asan.sh` after.
- **Move-identity goes away** (immediate free on last ref, no grace). Safe for enu
  (no move-preserving reparent — verified above), but the `basic_tests` "free refs"
  test encodes the *old* grace contract (`==` within 10s, `!=` after) and must be
  rewritten to the new "freed when unreferenced" semantics.
- Leak validation (no premature retention) wants the Linux/Valgrind path; macOS ASan
  catches the UAF half only.

### SUPERSEDED — a `register`-emitted `=destroy` on the bare ref won't work

Trying to emit the destructor directly on the registered type hits a wall: the cleanup
must `del` the **per-context** `ref_pool`, but a bare registered ref (`ref RootObj`)
carries **no context back-ref**, and `Ed.thread_ctx` is wrong under multiple contexts
per thread (which the test suite does, and which is load-bearing for sync identity —
the two contexts hold *different* instances of one `ref_id`). A global per-type
destructor can't know the instance's context. Empirically confirmed along the way:
custom `=destroy` *replaces* field destruction (fields leak unless destroyed by hand)
but dispatches correctly through inheritance; manual `for f in x.fields: =destroy(f)`
is exact-once. Use the field-handle approach below instead.

## Resolved shape: the proxy is a per-instance ed-owned field (`EdRef` + `RefHandle`)

The cleanup carrier must be **per-instance** (only a per-instance thing knows its own
ctx). So it's a small ed-owned object held *as a field* of the registered ref:

```nim
RefHandle = ref object
  ctx {.cursor.}: EdContext   # set on first ADD into this ctx's ref_pool
  ref_id: string
proc `=destroy`(h: var typeof(RefHandle()[])) =
  if not h.ctx.is_nil and h.ref_id.len > 0:
    {.cast(gcsafe).}: h.ctx.ref_pool.del(h.ref_id)
  `=destroy`(h.ref_id)
```

Registered types carry it via an ed base they inherit:
`EdRef = ref object of RootObj` (holds the `RefHandle`). enu: `Model of EdRef`; the
test's `RefType of EdRef`.

When the registered ref's last reference drops, ORC runs its **default** destructor →
destroys its fields → the `RefHandle`'s tiny `=destroy` cleans the *correct* `ref_pool`.

Why this is the chosen shape:
- **Solves context identity** — each instance's `RefHandle.ctx` is its own ctx, so
  multi-ctx-per-thread is correct by construction.
- **Sidesteps the leak hazard** — no custom destructor on the Unit (default field
  destruction, no leak); the only custom `=destroy` is the trivial `RefHandle`.
- **Not the big field-split** — `Unit` keeps its data and API; the proxy sits
  underneath. Dovetails with step 1's per-`Unit` `lifetime` field (`RefHandle` is its
  registry-cleanup sibling).

### Implementation sequence
1. ed: `RefHandle` + `EdRef` base + destructors (self-contained, compile-only).
2. ed: `ref_pool` obj → `{.cursor.}`; `ref_count` sets `handle.ctx/ref_id` on first
   ADD; delete the grace (`freeable_refs`/`free_refs` sweep). ← UAF-gated.
3. enu: `Model of EdRef`; retire explicit `ctx.free`/`queue_free`.
4. test: rewrite "free refs" to "freed when unreferenced"; `RefType of EdRef`.
5. ASan (UAF half) + flag the leak half for Linux/Valgrind follow-up.

## Deferred to the partial-replica/eviction phase

The proxy + `live_handle` observability, touch/LRU policy, interest-set integration,
and per-key (voxel) eviction. 4a lays the body protocol + move-identity substrate
they'll build on.

## Open question for next

Eviction granularity: whole-registered-ref vs per-key-within-a-container (voxels).
Decides whether *containers* ever get their own eviction handle, or only registered
refs do. Doesn't block 4a.
