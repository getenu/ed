# Object Lifecycle Redesign — Lifetimes, Teardown, and the Proxy/Body Split

> Goal: make Ed's object teardown far less fragile. Eliminate manual `zid`
> tracking, remove most `free` usage, make consumer `destroy` (e.g. enu's
> `unit.destroy`) trivial and correct-by-default, and make `release`/eviction
> automatic. Land an **80% solution** first (low risk, registry-agnostic), then a
> **proxy/body split** as the v2 object model — built so step two follows a seam
> rather than re-tangling step one.

## Why this is fragile today

Five overlapping teardown mechanisms, with cycles between them:

- **`track → zid`** registers a callback in `obj.changed_callbacks[zid]` *and*
  stores `ctx.close_procs[zid] = proc() = self.untrack(zid)` — a closure on the
  **context** capturing the **object**.
- **`untrack` / `ctx.untrack`** remove a callback, fire `CLOSED`, drop the close
  proc.
- **`bound_eids` + `untrack_on_destroy(owner, zid)`** — "untrack these when
  `owner` dies." An owner-binding mechanism that already exists but is manual.
- **`destroy`** — `untrack_all`, set `destroyed`, `ctx.objects[id] = nil`,
  `publish_destroy`.
- **`free` / `ref_pool` / `CountedRef` / `freeable_refs`** — *semantic* refcounting
  of shared registered refs (graph bookkeeping for sync, **not** memory), partly
  automatic via `ref_count` on ADDED/REMOVED.

enu's `Unit.destroy_impl` is the manual choreography over all of it: recurse
children → free `shared` → `for zid in eids: untrack` → destroy each Ed field →
nil `parent`/`owner`/`shared`/`state.open_*` → remove from parent → `free(self)`.
Every reference *to* the unit and every listener must be severed by hand; miss one
and you leak or dangle. This is where the bugs lived.

## The two hard constraints

1. **The registry is a strong-ref root.** `ctx.objects[id]` (plus the `close_procs`
   closure and the parent collection) strong-ref objects, so an Ed object's
   refcount never naturally hits zero while registered — `=destroy` won't fire on
   its own. *Something* must remove it from the registry, and that's explicit.
2. **Ed objects are thread-local to their context.** Sync copies *values*, not
   refs, so an instance lives on one thread; ORC's non-atomic refcount is only
   safe because of this. Destructors ride that invariant (they run on the owning
   thread) rather than adding a new constraint — but a stray Ed ref escaping to
   another thread is already unsound, destructors or not.

Conclusion: destructors can't be the *trigger* for canonical-object teardown, but
they're ideal for the thread-local, scope-bound leaf — the callbacks. Split the
problem instead of RAII-ing everything.

## Nim/ORC mechanics that matter

- `ref T` is refcounted; last ref → `=destroy` → freed. `ptr T` is non-owning and
  can dangle. Nim has **no first-class weak ref**.
- **`{.cursor.}`** fields are non-owning typed refs that don't count toward the
  refcount — the clean tool for back-references (no `ptr`, no dangling-on-deref).
- `=destroy(x: var T)` can be generic and **`register` can emit it** right after
  the type def. It must be cheap, must not raise, and must not do
  network/complex side effects — defer those to the next `tick`.

---

# Step one — the 80% solution (registry stays strong)

Three changes, each registry-agnostic and individually shippable with green tests.
Together: no manual `zid`, no manual `free`, deterministic cascading teardown, a
trivial `unit.destroy` — without flipping the registry or changing the `ctx[id]`
contract.

### 1. Lifetime — own callbacks, kill `zid`

A standalone **`Lifetime`** concept (its own type, *not* welded to `EdObject`).
Callbacks are owned by a Lifetime; when the Lifetime ends, its callbacks untrack.
Two ergonomic forms over the existing `bound_eids` machinery:

- **Owner-bound** (the workhorse): `obj.track(cb, owner = self)` — the listener
  joins the owner's Lifetime; the owner's teardown untracks it. The
  `for zid in self.eids: untrack` block disappears; you never name a zid.
- **Scope-bound**: `let h = obj.track(cb)` where `h` is a handle whose `=destroy`
  untracks at end of scope. Pure RAII, thread-local.

This also removes the `ctx → close_procs → object` cycle (the callback's strong
hold moves to the Lifetime, not a context-held closure).

### 2. `{.cursor.}` on structural back-references

Audit every back-ref (`child.parent`, sign `owner`, etc.) and make it
`{.cursor.}` (non-owning). This breaks the parent↔child cycle deterministically
without `ptr`, so a cascade can free a subtree promptly instead of waiting on
ORC's cycle collector. Forward refs (parent → children, container → entries) stay
strong and *are* the ownership.

### 3. `ref_pool` → ORC + `register`-emitted `=destroy`

Registered refs (Units) are held by collections + app, never by the Ed-container
registry. So ORC's refcount of the Nim ref already *is* the "is anyone still
referencing this" count that `ref_pool`/`CountedRef` maintains by hand. Drop the
manual count; let `register` emit a `=destroy` for the type that **enqueues** sync
cleanup (mark id for `publish_destroy` / dereg on the next `tick` — no side
effects in the destructor). Manual `free(self)` / `free(shared)` calls mostly
vanish: leaving all collections → last ref drops → ORC frees → destructor enqueues.

### What `destroy` / `unit.destroy` becomes

Cascade logic moves *into* Ed (written once, correct once): `destroy` recurses
owned children + Ed fields, untracks via the Lifetime, deregisters. enu's
`destroy_impl` collapses to roughly an `on_destroy` hook for app-only refs
(`state.open_unit = nil`) plus `self.destroy`.

### Precondition to verify

ORC-driven freeing of refs is only correct if **every live Ed object is reachable
from a strong graph root** (root collections, app-held singletons). Confirm enu
has no "floating" objects with no owner; name an owner for any that exist before
relying on automatic freeing.

---

# Step two — the proxy/body split (v2 object model)

Split each `EdObject` into:

- **Body (data)** — id-keyed canonical state (`tracked`, sync-relevant callbacks).
  **Registry-owned, explicit/sync-driven lifetime** (created on receive, freed on
  `DESTROY`/explicit). No GC games on the canonical state — the premature-free /
  dangling hazard of a weak *data* registry evaporates, because the weak thing is
  the cheap, reconstructible proxy.
- **Proxy (handle)** — a thin `ref` the app and graph hold. **GC-owned.** `ctx[id]`
  returns it (a real strong ref, safe to hold; the body stays alive underneath).

The registry holds a **weak backref to the live proxy**. `ctx[id]` returns the
existing proxy if one is alive, else mints a new one over the same body.

### Why it's worth it: proxy liveness is the missing signal

A live proxy = "this context is actively holding/using this object." Its
`=destroy` = "nobody's looking right now." That one signal unifies three things:

1. **Callback lifetime** — local callbacks on the proxy die with it (this *is* the
   Lifetime, for free).
2. **Local-resource eviction** — a Build's Godot node lives on the proxy; no proxy
   → node freed. Automatic `release`/eviction, GC-driven, no manual LRU.
3. **Partial-replica interest** — a live proxy for object X means "keep X
   subscribed/materialized"; proxy gone → candidate to unsubscribe. The per-key
   voxel `release` and object-level interest from the partial-replica work are the
   *same mechanism at two granularities*, and the proxy is that mechanism.

It also reframes "drop the ref and it frees" correctly: dropping the **handle**
frees local resources and signals eviction, while the **canonical data** stays
under sync/explicit control — exactly right for a distributed object that a peer
may still reference.

### Costs (eyes open)

- **Indirection** proxy → body on every access. Minor; watch hot paths (voxels).
- **The identity map is load-bearing**: `ctx[id]` must return *the* live proxy or
  reference-equality (`state.open_unit == self`) breaks. Needs the registry's weak
  proxy backref + resurrect-or-mint. With no Nim weak ref, this is a `ptr` +
  nil-the-backref-in-the-proxy-`=destroy` + `GC_ref`-on-resurrect dance —
  **contained in two places** (`ctx[id]` and the proxy destructor), not smeared
  across the API.
- **Proxy must be stateless or its state is intentionally handle-scoped** (render
  node). Proxy thrash would churn that state — keep proxies cached while in-scene.
- **Two callback registries** (sync on body, local on proxy).
- A **big, invasive refactor** of the core object model.

### Ref proxy vs value proxy (open; **value proxy leading**)

The proxy can be a `ref` or a **value type** (`==` overridden to compare ids). The
value form is attractive because it **dissolves the identity-map machinery**: with
`==` by id you just mint a proxy whenever asked and they compare equal — no
weak-backref, no resurrect-or-mint, no `GC_ref` dance (the scariest part of the
ref version disappears). Trade-offs:

- **Body lifetime moves to a tombstone model.** A value proxy can't sanely *own*
  the body (counted body-refs churn as value copies come and go; a raw `ptr`
  dangles if the body is freed under a stored proxy). The workable shape:
  **registry-strong body + tombstone** — `destroy` marks the body dead (`?proxy`
  checks `body.destroyed`) and memory is reclaimed on a delayed sweep, not
  immediately. Ed already half-lives here (`objects[id] = nil`, `freeable_refs`).
- **No GC-liveness eviction signal.** Value proxies are created/destroyed
  constantly, so "no live proxy → evict" is meaningless — eviction becomes
  **touch/LRU-based** (which we wanted anyway for auto-eviction, and which is more
  predictable than GC timing). So the "proxy liveness is the missing signal"
  framing above applies to the *ref* proxy; under value proxies that signal is
  replaced by touch-eviction + graph reachability.
- **Pervasive `ref` → value change** at every usage site (mechanical; mutation
  through any copy still hits the shared body, so semantics hold).

Leaning value-proxy: trading the subtle identity map for a tombstone body + touch
eviction is the better deal. Decide at implementation time; the rest of the design
is proxy-form-agnostic.

### Handle semantics — unmaterialized objects (decided)

A partial replica holds objects it knows exist (via shape) but hasn't loaded. The
handle carries that state; you can get/hold/pass/**listen on** it, you just can't
read its data:

- **Object-returning access returns the handle even when unmaterialized** —
  `ctx[id]`, and `table[key]` when the value type is itself an Ed object. No throw
  on *access*. (This supersedes the earlier `[]` → `Unmaterialized`-on-access
  plan.) **Value-returning** access — `EdTable[_, SnapshotData][key]` — has no
  handle to hand back, so it keeps the loaded / `get(): Option` / blocking
  semantics.
- **`?obj` means "usable/materialized,"** not merely "non-nil." Existence is
  `id in collection` (shape); usability is `?obj` (≈ loaded). For a full replica
  these coincide. Redefining `?` needs an audit of enu's `?unit`/`?field` sites
  (e.g. `destroy_impl`, asserts) to confirm none mean "structurally exists."
- **Reading the data throws** until materialized (`.value`/`.items`/`[]`).
- **Listeners are allowed on unmaterialized handles; reads are not.** `track` is
  data-independent (it appends to the callback list, never touches `tracked`), so
  you wire up reactivity *before* load — the intended partial flow. `track` stays
  **decoupled from fetch** (listen-without-forcing-load is a valid passive mode;
  an opt-in `track(eager = true)` that also requests is a later nicety).
  Initial-contents replay is empty for an unmaterialized handle.
- **Materialization fires `ADDED` + `reason == Fill`;** the *structural* entry of
  an unmaterialized handle fires nothing. This makes enu's existing
  `if added: render(change.item)` work unchanged (the item is usable when it
  fires), keeps shape (`in`/`len`/iteration) reflecting the handle immediately, and
  is *forced* by "listen on unmaterialized": a listener attached pre-load must catch
  the fill, so the fill has to be the real event. (A handle removed before it ever
  materialized fired no `ADDED`, so its removal fires nothing — needs an explicit
  rule.) Listeners live on the **body**, so they survive placeholder → materialized.

---

# How much of step one survives step two

**The split is internal to Ed's object implementation, not its API.** The app
still holds an `EdSeq`/`EdTable` ref and calls `.value`/`.track`/`.destroy`; that
ref just becomes a proxy. So all consumer-side work (Lifetime usage, the trivial
`unit.destroy`, the tests) carries over untouched.

| Step-one piece | Fate under the split |
|---|---|
| Lifetime / owner-binding | **Survives — it's the seam.** Proxy-bound callbacks *are* the Lifetime; only the internal trigger moves. (Requires it be standalone.) |
| `{.cursor.}` back-refs | Survives; "back-refs don't own" is universal. Minor re-pointing. |
| `ref_pool` → ORC | Survives, orthogonal — registered refs are graph-owned in both worlds. |
| Cascading `destroy` | Logic reused, **relocated** across the body/proxy seam. Refactor, not rewrite. |

Net-new at split time (additive, not throwaway): the proxy/body allocation, the
handle semantics, and — *only under a ref proxy* — the identity map. (A value
proxy has no identity map; `ctx[id]` just mints a value.) Either way `ctx[id]`
gets a smarter body, nothing in step one is undone.

Step-one piece 1a marked done: standalone `Lifetime` + `track(self, lifetime, cb)`
landed and tested (`tests/lifetime_tests.nim`).

### The two guardrails that keep step-one waste at ~zero

1. **Build Lifetime free-standing** — callbacks belong to a Lifetime, not to
   `EdObject`. Then they move to the proxy for free.
2. **Keep "identity/data" vs "handle" conceptually separate even while it's one
   object** — route anything handle-shaped (local callbacks, local resources, the
   eviction signal) through the Lifetime/handle concept from day one; keep
   anything identity-shaped (id, `tracked`, sync) on the data side. Then the split
   is drawing a line along a seam that's already there.

---

# Migration order

1. **Lifetime** (standalone) + owner-bound/scope-bound `track`. **1a done**
   (primitive + tests). **1b next:** migrate enu's `Unit.eids` to owner-binding,
   shrink `destroy_impl`. *(registry-agnostic, ship + green tests)*
2. **`{.cursor.}` back-ref pass** — audit and annotate; verify graph-root
   reachability precondition.
3. **`ref_pool` → ORC** — `register`-emitted `=destroy` enqueuing sync cleanup;
   remove manual `free` calls; framework-cascading `destroy`; collapse
   `unit.destroy` to an `on_destroy` hook + `self.destroy`.
4. **Proxy/body split** — body to registry (strong, explicit, tombstone teardown);
   proxy as value-or-ref (value leading); handle semantics (unmaterialized handles,
   `?` = usable, listen-not-read, `ADDED`+`Fill` on materialization); eviction via
   touch/LRU (value proxy) and/or proxy liveness (ref proxy); wire to
   partial-replica interest/eviction.

Steps 1–3 are the 80% and de-risk the core. Step 4 is the v2 model and is also the
substrate the partial-replica **eviction** phase wants — so it's likely where the
proxy split stops being elegance and starts doing real work.

## Open questions

- **Ref proxy vs value proxy** — decide at step 4 (value leading; trades the
  identity map for a tombstone body + touch eviction).
- **Materialization-event rule for the removed-before-materialized edge** — a handle
  dropped before it ever filled fired no `ADDED`; define what (if anything) its
  removal fires.
- Confirm graph-root reachability in enu (no floating, ownerless objects).
- `?` redefinition (usable vs non-nil) — audit enu's `?unit`/`?field` sites.
- Identity-map resurrection details (`ptr` + `GC_ref`) — *only if* we choose a ref
  proxy; prototype in isolation first.
- Threading invariant: assert no Ed ref crosses a thread boundary (already
  required for ORC correctness).
