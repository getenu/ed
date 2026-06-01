# Ed: Transport Hardening & Schema Compatibility

> How to keep stray/incompatible peers from corrupting an Ed context, and when
> (and when *not*) to bump a protocol version. Captures the "phantom connection"
> discussion. No code yet — design notes for later.

## The phantom-connection problem

A UDP socket bound to a port receives **any** datagram sent there — including from
unrelated processes, a stale prior run, or a **version-skewed peer** (e.g. an old
Enu speaking an incompatible Ed wire format). Ed then tries to `from_flatty` the
garbage and, in the worst case, **crashes the process** (an unhandled
`IndexDefect` on a malformed buffer — observed when a test bound the default port
9632 and received packets from a running old Enu).

This is **accidental cross-talk**, not a malicious actor. So the right tools are
lightweight validation, not crypto. Signing / transport encryption answers a
*different* question (untrusted peers tampering/spoofing) and is overkill here —
it would prevent cross-talk as a side effect, at much higher cost, and wouldn't
help with the most common real cause (version skew). Defer it until Enu actually
needs to defend against hostile players.

### Layered defense (priority order)

1. **Defensive deserialization (do first, independent of identity).** Wrap the
   `uncompress.from_flatty(Message)` in `tick()` in try/except: on any failure,
   **drop the packet and disconnect that connection** instead of crashing. A
   malformed / hostile / wrong-version packet must never take down the process.
   Everything below reduces *how often* this fires; this makes firing harmless.
2. **Protocol magic + version on the Ed payload / handshake.** netty already puts
   a `partMagic` on each packet (filters non-netty traffic); the gap is
   **Ed-payload-level versioning**. Add `[ed_magic: uint32][protocol_version:
   uint16]` to the SUBSCRIBE handshake (and ideally a cheap per-message magic).
   Reject mismatches before deserializing. This is the highest-value identity
   check — version skew during rollout is the common real cause.
3. **Session nonce (complements version).** A random per-instance/per-subscription
   nonce exchanged in SUBSCRIBE/ACK, checked on both ends, rejects *same-version
   but wrong-session* traffic — a stale process at the same address/port, or two
   unrelated Ed instances sharing a port. Cheap; pairs with the existing
   handshake and stale-subscription sweep. Not security (a sniffer can echo it),
   but right-sized for accidental cross-talk.
4. **Signing / encryption — deferred.** For an untrusted-peer threat model
   (authentication + integrity), not phantom connections. If added later it
   subsumes (2)/(3), but you still want (1) (a bad MAC should drop, not crash).

The **SUBSCRIBE handshake is the natural gate**: carry `{magic, version,
session_nonce}`, refuse to establish a subscription on mismatch, tag the
connection, then validate cheaply per message with (1) as the catch-all.

## Two compatibility axes — don't conflate them

The protocol version protects the **envelope**, not the **application schema**.
These change independently.

| Axis | What it covers | Changes | An old peer that disagrees… |
|---|---|---|---|
| **Envelope / transport** | `to_flatty(Message)` field list/order, source encoding, PACKED format, compression, handshake | **rare**, global | misparses *every* message |
| **Application schema** | `type_id`/`tid` registry, the bytes inside `msg.obj` (object/enum layout) | frequent, per type | misparses *one* type, or reads an out-of-range value |

**Key fact:** `tid(T) = hash($T)` — the hash of the type's **name string**, not its
structure (`utils/misc.nim`; ref types hash the type name in `utils/typeids.nim`).
This is what makes the cases below behave the way they do.

### Decision rule for the envelope `protocol_version`

> Bump it **only** when an old peer would misparse the message envelope /
> handshake / transport framing — i.e. you changed `Message`'s wire layout or the
> framing. Nothing else.

The `epoch`/`lsn`/`op_id`/`origin`/`delta` additions on `feat/lsn-leader-ordering`
were exactly such a change. App data-model changes are **not** envelope changes.

### Do these require a bump?

- **Add a new Ed object type** → **No.** New name → new `tid`. Old peers see an
  unknown `type_id` and hit the `type_id notin type_initializers` path (fail
  today, or skip under `ed_partial_subscriber`). Type-registry concern, additive,
  the easy case.
- **Add an `EdSet` with a new enum type** → **No.** `EdSet[NewEnum]` is a new type
  name → new `tid`. Same as above.
- **Add a value to an *existing* enum** → **No envelope bump — and this is the
  dangerous case.** The enum's name is unchanged, so the containing type's `tid`
  is unchanged. An old peer still has an initializer for that `tid`, deserializes
  happily, and reads the new ordinal as an **out-of-range enum value** →
  undefined/corrupt, **silently**. Caught by **neither** the envelope version
  **nor** the name-based `tid`.

## The real gap: silent structural breaks

Because `tid` is name-based and there's no schema check, **any structural change
to an *existing* type — a new field, a reordered field, a new enum value —
silently breaks cross-version peers.** A manually-bumped version "fixes" this only
if you remember every time; that's the fragile dance to avoid.

Better, mostly-automatic options:

1. **Structure-aware `tid` (best lightweight win).** Hash the type's *field layout
   + enum members*, not just `$T`. Then any structural change → different `tid` →
   old peers see an *unknown type* and fail safely (existing `notin
   type_initializers` path) instead of corrupting. You never bump manually — a
   type's identity *is* its shape. Tradeoffs: all-or-nothing per type (a changed
   type simply won't sync across versions — fine for "everyone runs the same
   build", less so for rolling upgrades), and **durable logs then need the schema
   stored to read old entries** (the `TypeSchema` work's job).
2. **Range-checked enum deserialization.** Cheap robustness so an unknown ordinal
   is detected and dropped, never UB. Worth doing regardless.
3. **`TypeSchema` on the wire (the parked work).** The path to *graceful*
   cross-version handling and durable-log/schema evolution, rather than just safe
   failure. See the spike doc — this is its real justification.

## Bottom line

- **Almost never** bump the envelope version for app changes — "new type? new
  enum?" → **no**.
- Bump the envelope version only for `Message`/handshake/transport framing changes
  (rare).
- The thing that actually bites is **structural changes to existing types being
  silent** — a `tid`/schema concern, best solved by **structure-aware tids +
  range-checked enums**, with `TypeSchema` for graceful evolution and durable
  logs. Not a protocol-version counter.

## Open items

- Implement defensive deserialization (try/except + disconnect) — high value,
  independent of everything else.
- Add envelope `ed_magic` + `protocol_version` to the SUBSCRIBE handshake.
- Add a session nonce to SUBSCRIBE/ACK.
- Decide structure-aware `tid` vs `TypeSchema`-on-wire (or both: tids for
  live-sync safety, schema for durable/graceful evolution).
- Range-check enum deserialization.
