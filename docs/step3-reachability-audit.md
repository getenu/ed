# Step 3 — Graph-Root Reachability Audit

Precondition for `ref_pool`→ORC (step 3): **every live registered ref (enu `Unit`)
must be reachable from a strong graph root that is *not* `ref_pool`.** If a Unit is
held only by `ref_pool`, dropping the manual hold frees it prematurely; if it's held
by nothing, ORC leaks/UAFs. This audit maps the roots and reports the result.

## What `ref_pool` actually holds (ed)

`EdContext.ref_pool: Table[string, CountedRef]` (`types.nim:187`). `ref_count`
(`type_registry.nim:198`) maintains it on ADD/REMOVE of a registered ref to/from an
Ed container:

- `ref_pool[id].obj = change.item` — a **strong** ref to the Unit.
- `ref_pool[id].references` — the set of Ed-container ids currently holding it.
- On last REMOVE (`references.card == 0`): `freeable_refs[id] = now + 10s`; the
  per-tick `free_refs` sweep (`type_registry.nim:279`, called from `tick`
  `subscriptions.nim:945`) deletes it from `ref_pool` after the 10s grace.

**Crucial: `ref_pool` is redundant for storage.** Ed containers store registered
refs directly and strongly: `EdObject.tracked: T` (`types.nim:272`), so
`EdSeq[Unit].tracked` is `seq[Unit]` and `EdValue[Player].tracked` is `Player` —
real Nim refs, independent of `ref_pool`. `ref_pool` exists for two *other* jobs:

1. **Memory keep-alive / refcount** — the `references` count + `obj` hold.
2. **Sync identity map + 10s grace** — `from_flatty` dedups a received ref by id
   via `ref_pool[ref_id].obj` (`subscriptions.nim:125`), so the same `ref_id` across
   multiple synced containers resolves to *one* instance, and a ref that just left
   all local containers survives 10s in case a late remote op references it again.

## enu's Unit roots (the reachability map)

Strong roots, all via Ed-container `tracked` (independent of `ref_pool`):

| Root | Field | Holds |
|---|---|---|
| Top-level units | `state.units: EdSeq[Unit]` (`types.nim:177`) | every root Unit |
| Subtree (ownership) | `Unit.units: EdSeq[Unit]` (`types.nim:258`) | each Unit's children |
| Player | `state.player_value: EdValue[Player]` (`176`) | the player |
| Editor open unit/sign | `state.open_unit_value` / `open_sign_value` (`168/186`) | also in `state.units` |
| Sign owner | `Sign.owner_value: EdValue[Unit]` | owner (also in tree) |

Non-Ed strong roots:

- **Godot node → model**: `BuildNode.model: Build`, `BotNode.model: Unit`. While the
  node is in the scene tree (Godot-refcounted) it strong-refs the Unit. This forms a
  **strong Nim cycle** with `Unit.node: Spatial` (`types.nim:209`), broken *manually*
  in `remove_from_scene` (`node.model = nil; node.queue_free(); node = nil`,
  `node_controllers.nim:32-39`).
- **Module globals** `previous_build` / `current_build` (`node_controllers.nim`) —
  strong `Build` refs; niled on remove (`15-18`) and reset (`109-110`).

Non-owning (correctly do **not** root): `Unit.parent` and `Unit.clone_of`
(`{.cursor.}` after step 2). A Unit is never reachable *only* via these — they point
at the parent/proto, which are themselves rooted by `state.units`.

## Result: precondition HOLDS

In steady state every live Unit is reachable from a strong, non-`ref_pool` root:
top-level Units from `state.units`; descendants from their parent's `units` EdSeq
(transitively rooted); the player from `player_value`. No floating/ownerless Units
were found. **So ORC-driven *memory* freeing is sound** — when a Unit leaves all
containers/app/node refs, ORC can reclaim it. Step 2's `parent`/`clone_of` cursors
do not orphan anything (confirmed: nothing is reachable solely through them).

## Caveats step 3 must handle (not blockers, but in-scope work)

1. **`ref_pool`'s identity-map + grace role is NOT memory — ORC won't replace it.**
   Naively deleting `ref_pool` breaks sync: `from_flatty` dedup (one instance per
   `ref_id`) and the 10s window for a late remote op referencing a just-removed ref.
   Step 3 must preserve this separately (a weak id→instance map, and/or the
   "`=destroy` enqueues dereg for the next tick" deferral) — or defer it to step 4's
   body registry, which *is* the identity map. **This is the real scope of step 3,
   not "drop the count."**

2. **Godot node cycle gates freeing.** Because `Unit.node ↔ node.model` is a strong
   cycle broken only in `remove_from_scene`, a Unit will not ORC-free on
   collection-drop alone until the node link is severed. So scene-removal remains the
   effective teardown trigger. Candidate: make `Unit.node {.cursor.}` to break the
   cycle — but Godot node refcounting is separate (`queue_free`), so evaluate
   carefully; not done here.

3. **Module globals are non-obvious roots.** `previous_build`/`current_build` pin a
   Build until niled. They are niled in `remove_from_scene`; step 3's ORC freeing
   won't collect a Build still pinned by one, so keep the nil-ing.

4. **`Shared` is subtree-shared.** `init_shared` sets `child.shared = parent.shared`
   (`units.nim:14`), so one `Shared` is referenced by every unit's `shared_value` in
   a tree. The explicit `free(shared)` at root-unit teardown (`units.nim:180`)
   becomes ORC-driven — fine, it frees when the whole subtree drops, but verify no
   path holds a `Shared` after its units are gone.

5. **Grace-window / late-sync access.** The one behavior ORC can't replicate is
   "kept alive 10s after leaving all containers." Real consumers are sync-side
   (re-add / late op via `from_flatty` dedup), not local synchronous access — but
   confirm no enu code touches a Unit synchronously *after* removing it from all
   containers expecting it to still be alive.

## Explicit free-sites that step 3 retires

`ctx.free(self)` (`units.nim:204`, the `destroy_impl` tail), `ctx.free(shared)`
(`units.nim:180`), `ctx.queue_free(unit)` (`node_controllers.nim:158`). The Godot
`node.queue_free()` (`node_controllers.nim:39`) stays — that's the Godot lifecycle,
not ed's.
