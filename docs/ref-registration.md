# Ref Registration — a runtime footgun worth a louder guard

> Synced `ref object` payloads must be registered with `Ed.register(T)` (the
> polymorphic registry, `type_registry.nim`). Value types never need it. When a
> ref is *unregistered*, the failure surfaces late, on a peer, with a misleading
> error — or silently. This documents the verified behavior and proposes a fix.

## Registration is required for refs only — verified

Empirically (local cross-thread subscription, authority → client; container tid
registered, varying the ref registry):

| Payload | `Ed.register`? | Result on the receiver |
|---|---|---|
| `int`, `string`, `seq[int]` (value types) | n/a | ✅ sync fine, never needs registration |
| `Animal` (plain ref, **exact** type) | ❌ neither side | 💥 **`IndexDefect` crash** in flatty deserialize |
| `Dog <: Animal` (subtype) | ❌ neither side | 💥 **`IndexDefect` crash** in flatty deserialize |
| `Dog <: Animal` (subtype) | ✅ both sides | ✅ preserved as `Dog`, subclass fields intact |

Two takeaways, one expected and one not:

1. **Registration gates *all* synced refs, not just polymorphic ones.** Even an
   exact-typed, single-class `ref object` crashes the receiver if unregistered —
   registration isn't a "polymorphism" feature, it's the ref wire contract.
2. **The unregistered failure is a hard crash, not a graceful skip.** The
   send side serializes the ref via plain `to_flatty` with `ref_id = 0`
   (`initializers.nim` build_message, "type not registered" branch); the receiver
   takes the `ref_id == 0` path and `from_flatty`s the raw buffer against the
   static type, which mis-frames and indexes off the end →
   `IndexDefect: index N not in 0 .. N-1` deep in `flatty`.

## Why "not alerting well enough" is the right concern (with a twist)

The original worry was that a missing registration fails *silently*. The reality
is two different bad modes depending on *who* registered:

- **Neither peer registered** → **loud but cryptic.** It crashes
  (`IndexDefect` in `flatty.nim`), so it's not silent — but the message points at
  a buffer index, not at "you forgot `Ed.register(Dog)`." And it fires at runtime
  on whichever peer deserializes first, far from the `add` that caused it. On the
  **local/cross-thread path** there's no guard: `process_message`
  (`subscriptions.nim:856`) runs the channel message directly, so the Defect
  propagates and takes down the thread. (The **remote** path has a
  `try/except CatchableError, Defect` around the wire decode at
  `subscriptions.nim:889-893`, so a network peer swallows it — a third,
  inconsistent behavior.)
- **Producer registered, consumer didn't** → **silent drop.** The producer sends
  a real `ref_id`; the consumer's `lookup_type` misses and hits the
  `debug "skipping change for unknown ref type"` skip (`initializers.nim:214`).
  No crash, no user-visible signal — the change just vanishes. *This* is the
  genuinely silent one.

So across the three transports/orderings you get crash, swallow, or silent drop —
none of which says "register this type." That inconsistency is the bug to file,
independent of whether we automate registration.

### Proposed: a louder, earlier, type-named guard

Cheap, non-breaking improvements, roughly in order of value:

1. **Name the type at the failure site.** Where a ref is serialized unregistered
   (build_message, currently `debug "type not registered"`) and where an unknown
   `ref_id` is skipped (initializers.nim:214), log at **warning/error** with the
   type name / `ref_id`, not `debug`. One line turns "cryptic IndexDefect later"
   into "Dog is not registered — call `Ed.register(Dog)`."
2. **Frame unregistered refs so receive fails cleanly.** Have the unregistered
   send path write the same is-registered framing the custom ref `from_flatty`
   (`subscriptions.nim:100-135`) expects, so a missing type is a detected
   "unknown ref" skip everywhere instead of an `IndexDefect` on the local path.
   Makes the three transports behave consistently (skip, not crash).
3. **Optional debug assertion.** Under `-d:ed_strict` (or the existing trace
   flag), `assert`/`fail` with a type-named message when serializing an
   unregistered ref, so it trips in tests at the offending `add`, not later on a
   peer.

## The deeper fix: declaration-site (host-site) registration

The manual manifest (`enu/src/types.nim:473-477`: `Ed.register(Player/Build/…)`)
already closes the gap — every peer that imports the type module registers the
hierarchy, so the runtime registry is correct. Its only weakness is that it's
**hand-maintained and forgettable**: add a 5th `ref object of Unit`, forget the
`Ed.register` line, and you get one of the three failure modes above.

**Declaration-site registration** removes the footgun: declare a syncable ref via
an Ed macro/pragma at its definition ("host") site, which both defines the type
*and* registers it (adds to a compile-time `CacheSeq`; a bootstrap step emits
`register_type` for each entry). Any peer that compiles the declaration registers
it automatically — still fully static, no runtime schema exchange, but you can't
declare a synced subtype without registering it.

Note this buys **no new capability** over the manual manifest — it produces the
identical registry — it only makes the registration **underivable-by-omission**.
So it's a low-priority ergonomic hardening: worth it once the ref hierarchy grows
fast enough (or spreads across enough modules) that "forgot the register line"
becomes a recurring risk; the **louder guard above is the higher-value, smaller
change** and should land first regardless.

## Caveats on the verification

- The crash/skip rows are runtime-verified on a single-process, cross-thread local
  subscription. The "producer-registered/consumer-not → silent drop" row is
  **code-confirmed** (initializers.nim:214) but not runtime-reproduced, because the
  ref registry is process-global and can't be made asymmetric within one process.
- Harness gotcha discovered while verifying: `Ed.bootstrap` snapshots the
  compile-time `INITIALIZERS` list **at its expansion point**, so a type must be
  instantiated *before* `Ed.bootstrap` (e.g. in an imported module, as enu does)
  for its **container** tid to register. Types instantiated *after* bootstrap in
  the same module silently never sync — a separate, related "registration timing"
  sharp edge worth a doc note of its own.
