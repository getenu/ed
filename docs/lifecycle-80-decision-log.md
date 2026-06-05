# Lifecycle 80% — Decision Log

Running log of decisions, trade-offs, and uncertainties while building the 80% of
the object-lifecycle redesign (everything before the proxy/body split). Plan:
`object-lifecycle-design.md`. Confidence tags: ✅ tested-and-certain,
⚠️ tested-mechanically-but-needs-enu-depth, 🔶 judgement call worth review.

## 1a — standalone Lifetime + owner-bound track  ✅ (prior commit 2a367af)

- `Lifetime` is a free-standing `ref object` holding `cleanups: seq[proc()]`, not
  welded to `EdBase` — so it transfers to the proxy under step 2 unchanged.
- `track(self, lifetime, cb)` binds untrack to `lifetime.finish()`. Cleanup
  captures `self` + `zid` and guards `not self.destroyed and zid in
  changed_callbacks` (idempotent, safe if the object died first).
- `add` on an already-finished Lifetime runs the cleanup immediately (can't leak).
- `finish` is idempotent.
- 🔶 `untrack` fires a `CLOSED` change before removing — so a lifetime-finish
  delivers one final `CLOSED` to each callback. Kept (consistent with existing
  `untrack`); tests count only non-CLOSED.

## 1a.1 — `changes(lifetime)` template DEFERRED  🔶

Tried `changes*(self, lifetime: Lifetime, body)` (reuse the base template + bind
the returned zid). It **collides** with the existing `changes*(self, pause_me,
body)`: `pause_me` is `untyped`, so it shadows any 3-arg call and broke unrelated
`obj.changes:` sites (e.g. `basic_tests:847`). Reverted.
- **Fix when we do the enu phase:** type `pause_me` as `bool` (so a `Lifetime`
  arg can't match it), or give the lifetime form a distinct entry point. The
  underlying primitive — `track(self, lifetime, cb)` — already exists, so enu's
  `watch`/`changes` wrappers can bind to a Lifetime without this sugar.

## 2 — `{.cursor.}` back-ref pass — design only, NOT landed  ⚠️ (hazard found)

The obvious win is `EdBase.ctx {.cursor.}` to break the object↔context cycle
(context owns objects via the registry; object→ctx is a back-ref). **Hazard:** an
object's teardown (`untrack_all` → `self.ctx.…`, `destroy` → `self.ctx.objects`)
touches its context. With `ctx` as a cursor, ORC may free the context *before* its
objects, dangling that access (use-after-free). This won't reliably surface in the
suite. **Required before landing:** guarantee the context strictly outlives its
objects (it owns them — but verify `clear`/context-destroy frees objects first and
that no Ed ref outlives its context), or make teardown stop touching ctx after
context-free. **Decision: do not land cursor changes without enu + a sanitizer
(`-d:useMalloc` / ASan) run** — exactly the runtime validation I can't do solo.
This is the right gate, not timidity: a wrong cursor is a silent UAF.

## 3 — `ref_pool` → ORC + `register`-emitted `=destroy` — design notes, NOT landed

Same risk class as #2, larger. Sketch for when we can validate at runtime:
- `register(T)` emits `proc =destroy(x: var typeof(T()[]))` that, when the last ref
  to a registered value drops, **enqueues** id-based cleanup (publish_destroy /
  dereg) for the next `tick` — never doing network/complex work in the destructor.
- Drop the manual `CountedRef` counting; ORC's refcount of the Nim ref (held by
  collections) *is* the "still referenced?" signal. Precondition (per the design
  doc): every live object reachable from a strong graph root — must be confirmed in
  enu, since premature `=destroy` on a still-needed object is the failure mode.
- `free`/`queue_free`/`free_refs` collapse into the destructor + the tick drain.
- Framework-cascading `destroy`: the `register`-emitted `=destroy` also finishes a
  `lifetime` field (if present) and destroys the type's Ed fields — this is the
  logic that lets enu's `destroy_impl` shrink to a hook.

## Sanitizer harness — `tests/asan.sh`  ✅ baseline clean

AddressSanitizer is the validation gate for the cursor / ref_pool memory work
(the failure mode is silent UAF, which functional green can't catch). Apple
Silicon runs ASan natively — no VM. `tests/asan.sh` builds + runs the full suite
with `-d:useMalloc` (ORC via malloc, so ASan sees the heap) and runs it.

- **Baseline: clean** — 94 tests, 0 ASan errors on the current branch. So any new
  UAF/overflow after a memory change is a real regression.
- **supersnappy trips ASan** (heap-buffer-overflow in `nimCopyMem` from its snappy
  fast-path over-read — benign third-party, not our bug; the `src:` ignorelist
  didn't catch it because the access is inlined). Worked around with a guarded
  pass-through: `ed_compress`/`ed_uncompress` are identity under
  `-d:ed_no_compress`. Default builds still compress (94 green confirmed). The
  sanitizer build sets the flag; in-process sync uses one build so the wire format
  stays consistent.
- **Leaks: not covered on macOS** (no LeakSanitizer). ASan here catches the UAF
  that the cursor work risks; *leak* validation for `ref_pool`→ORC wants the Linux
  path (`detect_leaks=1`, or Valgrind) — recipe in `asan.sh`'s footer. Worth a
  Docker/Linux run when that step lands.

## Status / where to resume

- **Landed + tested (Ed suite, 94 green):** standalone `Lifetime` + `track(self,
  lifetime, cb)`.
- **Designed, deliberately not landed** (need enu + sanitizer runtime validation,
  which is the next phase): the `{.cursor.}` pass and `ref_pool`→ORC/cascade. These
  are memory-management changes whose failure mode is silent UAF/leak; landing them
  blind at the tail of an isolated session would be reckless. They should be built
  *with* the enu integration phase so each step is validated against a real graph.
- The `changes(lifetime)` sugar is a small, separable fix (type `pause_me`).
