# Partial Replicas

A context should hold only the objects it uses. Nested `Ed` objects (the
`EdTable`s inside an `EdSeq[EdTable]`, etc.) don't exist in memory until reached,
and materialize on access. Opt-in and non-breaking: the default is still a full
replica (full push on subscribe, every op fanned out), byte-identical to before.

## Model — reference-driven lazy materialization

A partial subscriber declares a few **root** ids; the authority pushes only those.
The reference graph discovers the rest: a container op that references a
non-resident nested `Ed` (`change_object_id`) mints a typed **placeholder** (an
empty stand-in with the right id and type — `O` gives the type for free, no schema
needed) instead of asserting presence. Reading a placeholder **fetches** it. A
subscriber's interest set is implicitly "what it has reached and not yet dropped."

The pieces:

- **Per-subscriber interest** (`Subscription.partial` + `interest: HashSet[string]`).
  The authority filters every send path against it — initial push
  (`add_subscriber`), ongoing ops (`fanout`/`publish_changes`), and new-object
  broadcasts (`publish_create`). A partial client's *own* created objects auto-join
  its interest so its writes get return-to-source/convergence. DESTROY bypasses the
  filter (a peer may hold self-minted placeholder ids the authority never learned).
- **Fetch protocol.** `REQUEST(object_id)` → the authority adds the id to that
  sub's interest and `publish_create`s it; future ops then follow. `EdContext.fetch`
  drives it. Mirrors the SUBSCRIBE/ACK handshake.
- **Placeholder primitive.** `EdBodyBase.placeholder` + the `loaded` predicate
  (distinguishes "exists but not loaded" from "exists and genuinely empty");
  `Ed.init_placeholder` is the non-broadcasting constructor. A fill clears the bit
  in every restore path and on `from_flatty` of a pre-populated parent (so a
  partial replica receiving a populated parent gets correct cardinality, and a full
  replica that sees a parent before its child fills the placeholder when the child's
  CREATE lands).
- **Materialize-on-access.** `EdContext.materialize` (wired at subscribe time —
  it needs `fetch`/`tick`) is called by the read accessors via `touch_placeholder`.

## Capability handshake

A subscriber advertises its materializable type-ids (its registered
`type_initializers`) on SUBSCRIBE; the authority skips any object whose `type_id`
it isn't in `capabilities`, so a peer **never receives an object it can't
construct** (which would crash or silently corrupt on deserialize — flatty is
positional). `type_id == 0` (DESTROY/control) is exempt. An empty set means
unfiltered — a same-build/local peer or one with no handshake — preserving the
full-replica default.

This depends on the rule that **synced `ref object` payloads must be registered**
with `Ed.register(T)` (value types never need it). An unregistered ref fails late,
on a peer, with a misleading error or silently; the handshake turns that into a
clean "I can't hold this type, don't send it." *(Future: derive capabilities from
the types a consumer actually accesses, not just every tid it can construct — a
tighter interest signal; research only.)*

## The crux: access is synchronous, fetch is asynchronous

A read happens now; a fetch is a round-trip (cross-thread tick or network RTT).
The two consumer modes (see `SyncMode`):

- **`PARTIAL_ASYNC` — placeholder-then-fill (game loop).** Access returns the empty
  placeholder immediately and kicks a fetch; when it lands the placeholder fills and
  a change fires (tagged `Fill`, via the `ctx.filling` flag read in
  `trigger_callbacks`). The standard lazy-load pattern; matches enu's chunk
  snapshot/delta loading.
- **`PARTIAL` — blocking (request/response: MCP, scripts).** A read inside a
  `blocking` scope pumps `tick` until the object fills, **bounded by a 5s deadline**
  so a gone authority can't hang the caller (then it falls back to the empty
  placeholder).

**Silent materialize** keeps the blocking read clean: it applies *only* the fetched
object, silently — `ctx.silent` makes `trigger_callbacks` defer to
`ctx.pending_fills`, and the pump buffers every non-target message to
`ctx.pending_msgs`. Both replay at the start of the next explicit `tick`, so nothing
application-visible happens mid-read (clean reentrancy; deterministic single-thread
tests). `parse_remote` is shared by `tick` and the pump, so the wire decode lives in
one place (no `tick` receive/process split was needed).

## Notes

- Interest is **grows-only** here (roots + fetched ids accumulate); eviction —
  which sheds it — is a later layer (it needs the per-key/eviction machinery, not a
  durable log; the authority serves subsets from memory).
- Builds on the relaxed validation (a replica already tolerates ops for objects it
  doesn't hold) and the per-object reconciliation frontier (delivery is already
  per-object). See `consistency.md`.
