# Static Type-Usage Spike — "what types does a consumer actually use?"

> Research spike answering: can Ed statically identify which `Ed[T,O]` types a
> consumer (e.g. `enu_mcp`) *actually accesses*, so a partial replica can declare
> interest by **capability** automatically — instead of the coarse "I have a tid
> for it" signal? Short answer: **yes, and it's meaningfully tighter.**

## The problem with "tid exists"

The obvious capability signal is "the set of types I have an initializer for"
(`INITIALIZERS` CacheSeq → a `tid` per type). A partial replica could advertise
those tids and the authority would only send objects whose type it can
materialize. But **instantiation over-includes**: a generic `init`/`defaults`
gets compiled if it's *reachable*, not if it's *used*.

`enu_mcp` is the case in point. It builds `Shared` via `init_ed_fields`, which
transitively instantiates the voxel **edit tables**
(`Ed[Table[EditKey, SnapshotData], …]`, `Ed[Table[EditKey, EdSeq[DeltaUpdate]], …]`)
— so `enu_mcp` *has tids* for them and would advertise interest in the voxel
firehose, even though **no reachable code path in `enu_mcp` ever reads a voxel
edit**. The chunk tables (`Vector3`-keyed) aren't even instantiated; the edit
tables are, purely incidentally. "tid exists" can't tell incidental
instantiation from real use.

## The idea: instrument the *read* API, not construction

A generic **accessor** proc is also only instantiated when called. If we tag every
public read accessor with a compile-time registration, the set of types whose
accessors got instantiated is the set of types **some compiled code reads** —
a "uses" signal independent of "constructs."

The read surface of `Ed` is small and centralized (`zens/operations.nim`,
`zens/tracking.nim`):

| Accessor | Reads |
|---|---|
| `value*[T,O]` | the whole value of an `EdValue`/register |
| `items*`, `pairs*` | iterate a seq/set/table |
| `` `[]`* `` | index a seq/table |
| `contains*`, `len*` | membership / cardinality |

Spike instrumentation: a `static: echo "ACCESS:: ", $Ed[…]` on `value`,
`items` (×2), `pairs`, and both `` `[]` `` overloads, then
`nim check bin/enu_mcp.nim` and collect the distinct lines. (Temporary; reverted.)

## Empirical result (enu_mcp)

| Signal | Count | Includes voxel edit tables? |
|---|---|---|
| **Instantiated** (has a tid) | 17 | **YES** (incidental, via `Shared.init_ed_fields`) |
| **Accessed** (read API called) | 25 | **NO** |

The headline: **the accessed set excludes the voxel edit tables.** The thing we
wanted gone — the incidental, potentially-huge voxel interest — is gone, for free,
because `enu_mcp` constructs those tables but never iterates/indexes/reads them.

### The 25 is not a subset of the 17 — and that's the interesting part

"Accessed" is *not* "instantiated minus the unused." It's a **different
projection**. Eight types are accessed-but-not-instantiated in `enu_mcp`:

```
Ed[types.Config]  Ed[types.Player]  Ed[types.Sign]  Ed[types.Tools]
Ed[system.bool]   Ed[system.int64]  Ed[godotcoretypes.AABB]
Ed[seq[string]]   Ed[seq[tuple[id,normal]]]  Ed[seq[LocalStateFlags]] …
```

These are read by procs in imported model modules (`states`, `players`, `units`)
that `enu_mcp` compiles but that never **construct** those objects on a reachable
path. So:

- **Instantiated** = "types my compiled code can *construct*" → includes
  incidental construction (the edit tables via `init_ed_fields`).
- **Accessed** = "types my compiled code can *read*" → includes reads in
  imported-but-unreached procs (Config/Player/…), excludes construct-only types
  (the edit tables).

### …but accessed *alone* is unsound — you can't materialize 7 of those 8

The accessed-not-instantiated types are a **trap**, not free interest. The
registry that lets a context *receive* an object — `type_initializers[tid]` — is
populated **only** by `create_initializer` (`initializers.nim:15`), which runs on
the **construction** path (`defaults`, line 58). Reading never touches it. So
"accessed but not instantiated" means, by construction, the read accessor compiled
but `create_initializer` did **not** → the type is **not in `INITIALIZERS`**, gets
**no registry entry**, and has **no usable tid**. If the authority sent a `CREATE`
for a `Config`, the client would hit the unknown-type path and drop it. The
accessor code reading those types is **dead** at runtime — nothing on a reachable
path constructs or receives one, so there's no object to read.

(Airtight, not just empirical: a registered type's nested Ed fields get their
`defaults` instantiated *inside* the parent's initializer, so they'd be in the
instantiated set too. Config isn't → genuinely unregistered.)

So the two projections each admit a *different, disqualifying* failure mode:

- **Instantiated** = "types I can *materialize*" → over-includes **construct-only**
  types (the edit tables: registered but never read → pure waste to sync).
- **Accessed** = "types I can *read*" → over-includes **read-in-dead-code** types
  (Config/Player/…: read in unreached procs but **unmaterializable** → broken to
  request).

### The sound signal is the intersection

What partial-replica interest actually wants is **instantiated ∧ accessed** —
"types I can *both* materialize *and* will read":

| | Materializable | Read | Interest |
|---|:---:|:---:|:---:|
| voxel edit tables | ✓ | ✗ | **no** — never read it |
| Config / Player / Sign / Tools | ✗ | ✓ | **no** — *can't* materialize it |
| Unit, Shared, McpQuery, … | ✓ | ✓ | **yes** |

Intersection eliminates *both* failure modes at once. This corrects an earlier
draft of this doc that treated intersection as needless tightening and the
accessed-only extras as "harmless small singletons" — they're not harmless, they're
**unmaterializable**, so intersection is required for **soundness**, not just
precision.

## Caveats (what "accessed" does *not* give you)

1. **It's an over-approximation of reachable use.** Accessor instantiation fires
   for any *compiled* read, including reads in imported procs that `enu_mcp`'s
   `main` never calls (that's why Config/Player/Sign/Tools show up — read somewhere
   in the `states`/`players` modules). It is **not** "read on a live path from
   main." For the **accessed** projection this over-inclusion is what produces the
   unmaterializable types above; the **intersection** with instantiated removes
   them, since you can't construct what you never compile a constructor for.
   Eliminating the residual dead-code over-inclusion entirely would need
   whole-program call-graph analysis (below) — not worth it once intersection has
   removed the disqualifying cases.
2. **Reads must go through the public accessors.** Ed values are encapsulated
   (you read via `.value`/`.items`/`[]`), so in practice this holds. Code that
   reaches into `.tracked` directly would bypass the signal — but that's Ed
   internals, not consumer code.
3. **Ed-internal reads don't pollute it.** The reconciliation/serialization paths
   move bytes (`change_receiver`, flatty) without calling the public typed
   accessors, so internal machinery touching the edit tables does **not** register
   them as accessed. Confirmed empirically — zero edit-table reads in the accessed
   set despite the tables being live, synced internals.
4. **Static, not per-object.** It tells you *types*, not *which instances*. It's a
   **capability/type-interest** filter (drop whole voxel type) — orthogonal to the
   per-object `interest` set in `partial-replicas-spike.md` (which object ids).
   They compose: type filter trims the firehose categorically; object interest
   trims within a kept type.

## The menu of approaches considered

| Approach | What | Verdict |
|---|---|---|
| **tid exists** (instantiated) | Advertise the `INITIALIZERS` tids | Baseline. Over-includes **construct-only** types (the edit tables) → syncs the voxel firehose. What we're trying to beat. |
| **Accessed-only** | A CacheSeq populated by the public read accessors; "accessed types" → type-interest | **Unsound on its own.** Over-includes **unmaterializable** types (Config/Player/…: read in dead code, no registered initializer) → requests objects the client can't construct. Excludes the firehose, but trades one bad failure mode for another. |
| **Intersection** (instantiated ∧ accessed) | Types both materializable *and* read | **Recommended.** The only projection with neither failure mode: drops construct-only types (firehose) *and* unmaterializable reads. Two CacheSeqs (reuse `INITIALIZERS` + add `ACCESSED_TYPES`), intersect their tids at bootstrap. |
| **Whole-program call-graph** | Macro/analysis pass: only reads reachable from `main` | Most precise, but heavy and fragile against Nim's generic/dispatch model. Not worth it for a few small over-included singletons. |
| **Effect-system tagging** | Annotate procs with the Ed types they touch; propagate as effects | Compiler-enforced and precise, but **manual** — defeats "automatic." A documentation/lint tool, not an interest source. |
| **Runtime access-report** | Instrument live accesses; report the types actually touched at runtime | Complementary, not competing. Catches dynamic reality the static pass can't, and is the natural feed for **eviction** (Phase 4). Pair it with the static signal. |

## Recommendation — design it into Ed

Add an **`ACCESSED_TYPES` CacheSeq**, populated the same way `INITIALIZERS` is, but
from the public read accessors (`value`, `items`, `pairs`, `[]`, optionally
`contains`/`len`). At bootstrap, **intersect** its tids with the already-registered
`INITIALIZERS` tids → `Ed.interest_tids` (the `hash($T)` of each type that is both
materializable and read). Then:

- A partial/capability-filtered subscriber advertises `interest_types =
  Ed.interest_tids` **automatically** — "send me only types I can build *and* will
  read." The authority drops objects whose `type_id` isn't in that set before it
  ever consults per-object interest.
- This is strictly better than "tid exists" and requires no annotation from the
  consumer — `enu_mcp` gets voxel-free sync *by virtue of not reading voxels*,
  which is exactly the invariant the user wanted to encode — while the intersection
  guarantees every advertised type is one the client can actually materialize.

Compose with the existing per-object `interest` (object ids) from the partial
replicas work: **type-interest** is the categorical/capability cut (cheap, static,
kills the firehose); **object-interest** is the fine cut (which instances). And
keep the **runtime access-report** on the roadmap as the dynamic counterpart that
feeds eviction.

### Open questions before building

1. Which accessors to tag — reads only (`value`/`items`/`pairs`/`[]`), or also
   `contains`/`len`? (Reads-only is the cleanest "I consume the contents" signal;
   `len`/`contains` is "I probe existence" — arguably still interest.)
2. Wire it into the handshake: does the subscriber send `accessed_tids` at
   subscribe time (authority filters), or does the authority send a type
   manifest and the subscriber replies with the subset it can read? (The former
   is simpler and matches `transport-and-schema-compatibility.md`'s capability
   handshake.)
3. Same-build subtlety (`enu_mcp`): it *does* have tids for the edit tables (same
   source tree), so a pure tid handshake wouldn't help — which is exactly why the
   **accessed** signal, not the **instantiated** one, is the right thing to put on
   the wire.
