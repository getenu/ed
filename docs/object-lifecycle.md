# Object Lifecycle — Lifetimes, Ownership, Teardown

How Ed tears objects down without manual `zid`/`free` choreography. This is the
"80%" layer; the proxy/body split that builds on it is in `proxy-body.md`.

## Two hard constraints

1. **The registry is a strong-ref root.** `ctx.objects[id]` strong-refs every
   container, so a container's refcount never naturally hits zero while registered
   — `=destroy` won't fire on its own. So a destructor can't be the *trigger* for
   canonical-object teardown; removal from the registry is always explicit
   (`destroy`/`DESTROY`). Destructors are used only for the thread-local, scope-
   bound leaf (callbacks, registry-index cleanup).
2. **Objects are thread-local to their context.** Sync copies *values*, not refs,
   so an instance lives on one thread; ORC's non-atomic refcount is sound only
   because of this. A stray Ed ref crossing threads is already unsound.

## The pieces

- **`Lifetime`** — a standalone set of teardown actions (untrack closures),
  *not* welded to the object. An owner (a Unit, a scope) holds one and `finish`es
  it on teardown, so everything bound to it cleans up at once — no manual `zid`.
  Standalone on purpose: under the proxy/body split it becomes the proxy's cleanup
  set with no call-site change. `track` consults a thread-local `current_lifetime`
  (set by the `own` scope) and auto-binds.

- **`{.cursor.}` back-references.** Structural back-refs (`EdRef.ctx`,
  `EdBodyBase.ctx`, the body→proxy link) are non-owning cursors, so they don't
  count toward the refcount and a cascade frees a subtree promptly instead of
  waiting on ORC's cycle collector. Forward refs (collection → entries) stay strong
  and *are* the ownership. Safe because the context strictly outlives its objects
  and teardown that reads `ctx` is explicit, on the home thread. Validated under
  AddressSanitizer (`tests/asan.sh`).

- **`ref_pool` → ORC.** Registered refs (Units) are held by collections + the app,
  never by the container registry — so ORC's refcount already *is* the "is anyone
  still referencing this" count the old `CountedRef` maintained by hand (with a 10s
  grace timer). That manual count and grace are gone: `ref_pool` is now a non-owning
  (cursor) index, and memory is ORC-owned. Every registered type inherits `EdRef`,
  which carries a `RefHandle` whose `=destroy` records the now-dead instance for
  removal from `ref_pool`.

  **The RefHandle discipline (load-bearing).** The handle's `=destroy` must never
  dereference its `EdContext`: at teardown the context can be reclaimed in the
  *same* ORC cycle-collection batch as the ref, so touching it is a use-after-free
  (caught by ASan). Instead it appends the dead `ref_id` to a pending list keyed by
  the context's per-instance **uid** (a value, not a reference) — `pending_dead_refs`
  — and each context prunes its own dead ids (`prune_dead_refs`) *before any
  `ref_pool` identity read* and on tick. The uid (not `id`, which is reused across
  contexts; not `Ed.thread_ctx`, which is wrong under multiple contexts per thread)
  is what lets a freed ref find the right pool without a live reference.

  *Precondition:* every live registered ref must be reachable from a strong graph
  root that is *not* `ref_pool`. A ref held only by `ref_pool` would free
  prematurely; one held by nothing leaks/UAFs. Name an owner for any floating ref.

## Synced ownership + cascading destroy

Containers and refs can be **owned**, so an owner tears down everything it owns in
*any* context — including one that didn't construct it (the server cleaning up an
MCP-created bot after the client drops).

- A container created inside an `own` scope records `owner_id` (baked into the
  container, synced on its CREATE envelope) and is indexed in `EdContext.owned_by`
  (owner id → owned ids). `own` comes in two forms: `self.own:` (by the owner
  object, also sets the callback `Lifetime`) and `id.own:` (by an id you already
  hold — for construction, before the owner exists).
- `OWNS_MEMBERS` collections register their `EdRef` members under the collection's
  owner via `ref_count`, so membership drives ownership (removal un-registers).
  `set_owner` does the same for standalone refs — keyed by the `ref_pool` key
  (`tid:id`), matching how `destroy_owned` resolves members, or the ref escapes the
  cascade.
- `destroy_owned(owner_id)` tears down owned refs (via their `destroy` method) then
  owned containers (via the same `change_receiver` path a received DESTROY takes).
  The owner's `lifetime.finish` handles its callbacks separately — ownership drives
  *container* teardown, the Lifetime drives *callbacks*.

The result: enu's hand-written `destroy_impl` choreography collapses to roughly an
`on_destroy` hook for app-only refs plus `self.destroy`.
