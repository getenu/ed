# Swift bridge for Ed

Status: research / design. Forward-looking — targeted for *after* the Godot 4 port of
enu, to replace some Godot UI with native SwiftUI on Apple platforms (a native settings
screen and editor component to start).

Goal: a **last-mile binding**. Get Ed data in and out of Swift with as little bespoke
glue as possible. The API does not need to mirror Ed's Nim API; it needs to let SwiftUI
read values, write values, and react to changes. Everything that can be pushed down into
Ed itself or a reusable Swift package should live there; only app-specific wiring stays in
the app.

Explicit non-goal: Ed does **not** become a standalone Swift-native peer. We are not
reimplementing the wire protocol, flatty, or the store format in Swift. The bridge is
in-process, linked against the same Nim runtime as enu.

## The five facts that constrain the design

From the current Ed codebase (`src/ed/`):

1. **ORC GC** → Nim-as-a-library FFI is easy. No `setupForeignThreadGc` dance (that was a
   refc-GC requirement). Biggest thing working in our favor.
2. **One `EdContext` per thread**, held in a `{.threadvar.}` (`active_ctx`,
   `src/ed/components/private/global_state.nim`). Contexts are **not** internally locked.
   All reads, writes, `track`/`untrack`, and `tick` for a context must run on that
   context's owning thread. Cross-thread talk is message-passing over `Chan[Message]`
   inboxes drained in `ctx.tick()`. This — not GC, not syntax — is the real design
   problem.
3. **Callbacks fire on the thread that ticks.** Local mutations fire callbacks
   synchronously in-line; cross-context changes are applied (and callbacks fired) when
   *that context's thread* calls `ctx.tick()`. Never on a background thread you don't
   control.
4. **Proxy/body split** (`src/ed/types.nim`). The app holds a proxy (`Ed[T,O]` ref); the
   real data + callbacks live on a registry-owned body keyed by a stable `string` id.
   Proxies are pruned when nothing holds them — a bridge must **root** any handle it hands
   out, or re-resolve via `ctx[id]`.
5. **`Ed.bootstrap` is compile-time.** No runtime "register container type" call — every
   `Ed[T,O]` the UI needs must be *instantiated in Nim code linked into the binary* so the
   bootstrap macro emits its registration. The bridge shim is where those instantiations
   are declared.

Two things that rule out the tempting shortcut: the wire/thread format is **flatty**
(positional binary, native-endian, native-int-width) and the store is JSONL wrapping
base64'd flatty blobs. Neither is a stable cross-language ABI — `docs/decentralization-and-scaling.md`
already calls flatty the wrong long-term codec. Reimplementing the wire protocol in Swift
is the *hardest* path, not the easiest. Bridge at the Nim proc API, in-process.

## Options considered

| # | Approach | Fidelity | Effort | Verdict |
|---|----------|----------|--------|---------|
| 1 | **In-process C ABI static lib** (Nim shim) + Swift package | Full — incl. callbacks; same binary so no endian/flatty ABI concerns | Medium | **Chosen** |
| 2 | Genny-generated C API | Partial — no Swift target; weak callbacks/threading | Low-med | Patterns only, not the tool |
| 3 | Nim `--backend:objc` | Full, but thin ecosystem, more moving parts | High | Not primary |

Genny (treeform's binding generator) targets C/Python/Node — not Swift — and its weak
spots are exactly callbacks and threading, which are Ed's whole reason for existing. Use
its *patterns* (`exportRefObject`, variant marshalling), not the tool wholesale.

## Architecture: the bridge is its own Ed context

The key move: **don't reach into enu's Ed context from Swift** — that violates fact #2.
Instead the bridge *is a second `EdContext`*, exactly how Ed is designed to be consumed
across execution contexts. It subscribes (LOCAL, same process) to enu's authority context
and Swift observes *it*.

```
┌─ enu process ───────────────────────────────────────────────┐
│                                                              │
│  enu authority EdContext        Bridge EdContext             │
│  (game/worker threads)  ──LOCAL sub──▶  (1 dedicated thread) │
│                                            │                 │
│                                    ed_context_tick() on a    │
│                                    ~60Hz timer (this thread) │
│                                            │                 │
│                                    C callback fires here     │
│                                            │                 │
│                                    DispatchQueue.main.async  │
│                                            ▼                 │
│                                   SwiftUI @Observable models │
└──────────────────────────────────────────────────────────────┘
```

One serial `DispatchQueue` **is** the bridge context's owning thread. Every `ed_*` call
goes through it; `tick` runs on it; callbacks originate on it; only the final UI update
hops to `MainActor`. That single rule ("all Ed calls on the queue") makes the whole thing
correct.

## C ABI surface (`edbridge.h`)

Opaque **integer** handles (not pointers — sidesteps ORC rooting in Swift), and one
dynamically-typed value struct à la genny's variant / the store's envelope:

```c
#include <stdint.h>
#include <stddef.h>

void NimMain(void);          /* call once, on the owning thread, before anything else */

typedef uint64_t EdCtx;
typedef uint64_t EdHandle;

typedef enum { ED_NIL, ED_STRING, ED_INT, ED_FLOAT, ED_BOOL } EdKind;
typedef struct {
  EdKind      kind;
  int64_t     i;      /* ED_INT / ED_BOOL */
  double      f;      /* ED_FLOAT */
  const char* s;      /* ED_STRING — Ed owns it; copy immediately, don't free  */
  size_t      s_len;
} EdVar;

typedef struct {
  uint32_t    kind_mask;   /* CREATED=1 ADDED=2 REMOVED=4 MODIFIED=8 TOUCHED=16 CLOSED=32 */
  const char* field_name;
  EdVar       item;
} EdChange;

typedef void (*EdCallback)(const EdChange* changes, size_t n, void* user_data);

EdCtx    ed_context_new(const char* id);
void     ed_context_tick(EdCtx ctx);              /* drains inbox, fires callbacks HERE */
void     ed_context_subscribe_local(EdCtx ctx, EdCtx upstream);
void     ed_context_free(EdCtx ctx);

EdHandle ed_value(EdCtx ctx, const char* id);     /* resolve by stable id, rooted Nim-side */
EdVar    ed_get(EdHandle h);
void     ed_set(EdHandle h, EdVar v);
uint16_t ed_track(EdHandle h, EdCallback cb, void* user_data);
void     ed_untrack(EdHandle h, uint16_t zid);
void     ed_release(EdHandle h);                  /* drop the Nim-side strong ref */
```

`nim ... --header:edbridge.h` generates most of this; we hand-write the `EdVar`/`EdChange`
structs.

## The Nim shim (`bridge.nim`)

Declare the concrete `Ed[T,O]` types the UI needs, keep a **handle table that roots
proxies**, wrap Ed's real procs with `exportc, cdecl`. Single-thread-per-context by
contract, so no locks. Illustrative, not compile-ready:

```nim
# Compile:
#   nim c --app:staticlib --noMain --header:edbridge.h \
#         --mm:orc --threads:on --tlsEmulation:off \
#         -d:nim_type_names -d:release -o:libedbridge.a bridge.nim

import std/tables
import ed

type SwiftVal = EdValue[string]          # covers text settings & the editor buffer
Ed.bootstrap                             # runs during NimMain (this module's init)

var
  ctxs: Table[uint64, EdContext]
  vals: Table[uint64, SwiftVal]          # strong refs so ORC won't reap what Swift holds
  next: uint64
template fresh: uint64 = (inc next; next)

type
  EdKind {.pure, size: sizeof(cint).} = enum Nil, String, Int, Float, Bool
  EdVar {.bycopy.} = object
    kind: EdKind
    i: int64
    f: float64
    s: cstring
    s_len: csize_t
  EdChange {.bycopy.} = object
    kind_mask: uint32
    field_name: cstring
    item: EdVar
  EdCallback = proc(changes: ptr EdChange, n: csize_t, ud: pointer) {.cdecl.}

proc strVar(s: string): EdVar =
  EdVar(kind: String, s: s.cstring, s_len: s.len.csize_t)

proc ed_context_new(id: cstring): uint64 {.exportc, cdecl.} =
  let ctx = EdContext.init(id = $id)
  Ed.thread_ctx = ctx                     # bind THIS thread to the context
  result = fresh()
  ctxs[result] = ctx

proc ed_context_tick(h: uint64) {.exportc, cdecl.} =
  if h in ctxs: ctxs[h].tick()            # inbound msgs applied + callbacks fire here

proc ed_value(ctxh: uint64, id: cstring): uint64 {.exportc, cdecl.} =
  let v = SwiftVal(ctxs[ctxh][$id])       # re-resolve proxy from the body registry
  result = fresh()
  vals[result] = v                        # root it → survives until ed_release

proc ed_get(h: uint64): EdVar {.exportc, cdecl.} =
  strVar(vals[h].value)

proc ed_set(h: uint64, v: EdVar) {.exportc, cdecl.} =
  if v.kind == String:
    vals[h].value = $v.s                  # fires local callbacks synchronously

proc ed_track(h: uint64, cb: EdCallback, ud: pointer): uint16 {.exportc, cdecl.} =
  result = vals[h].track proc(changes: seq[Change[string]], it: ref EdBase) {.gcsafe.} =
    var buf = newSeq[EdChange](changes.len)
    for i, c in changes:
      buf[i] = EdChange(
        kind_mask:  cast[uint16](c.changes).uint32,   # set[ChangeKind] → bitmask
        field_name: c.field_name.cstring,
        item:       strVar(c.item))
    cb(if buf.len > 0: addr buf[0] else: nil, buf.len.csize_t, ud)

proc ed_release(h: uint64) {.exportc, cdecl.} =
  vals.del(h)                             # drop the strong ref; ORC reclaims if unused
```

To generalize past strings: switch on `EdVar.kind` and keep a `vals` table per contained
type, or dispatch on the runtime `tid`. As much of this shim as possible should ship *with
Ed* (see "Generalizing the shim" below) so an app writes almost none of it.

## The Swift side

One serial queue = one Ed thread. All `ed_*` calls flow through it; only UI updates hop to
main.

```swift
import Foundation

final class EdBridge: @unchecked Sendable {
    static let shared = EdBridge()
    let q = DispatchQueue(label: "ed.bridge")     // THE context's owning thread
    private var ctx: EdCtx = 0

    private init() {
        q.sync {
            NimMain()                              // once, on the owning thread
            self.ctx = ed_context_new("swift-ui")
            // ed_context_subscribe_local(self.ctx, enuAuthorityCtx)  // wire to enu
        }
        q.async { self.tickLoop() }
    }
    private func tickLoop() {
        ed_context_tick(ctx)
        q.asyncAfter(deadline: .now() + 1.0/60.0) { self.tickLoop() }
    }
    func value(_ id: String) -> EdValueRef { q.sync { EdValueRef(id: id, ctx: ctx, q: q) } }
}

@Observable final class EdValueRef {
    private let handle: EdHandle
    private let q: DispatchQueue
    private var zid: UInt16 = 0
    var text: String = "" {
        didSet {                                   // Swift → Ed (debounce in real code)
            let v = text
            q.async { v.withCString {
                ed_set(self.handle,
                       EdVar(kind: ED_STRING, i: 0, f: 0, s: $0, s_len: strlen($0)))
            } }
        }
    }
    init(id: String, ctx: EdCtx, q: DispatchQueue) {
        self.q = q
        self.handle = id.withCString { ed_value(ctx, $0) }
        q.sync {
            self.text = String(cString: ed_get(handle).s ?? "")
            let box = Unmanaged.passRetained(self).toOpaque()   // keep alive for callback
            self.zid = ed_track(handle, edTrampoline, box)
        }
    }
    fileprivate func apply(_ s: String) {          // Ed → Swift, on the UI thread
        DispatchQueue.main.async { self.text = s }
    }
    deinit { q.async { [h = handle, z = zid] in ed_untrack(h, z); ed_release(h) } }
}

private func edTrampoline(_ changes: UnsafePointer<EdChange>?, _ n: Int,
                          _ ud: UnsafeMutableRawPointer?) {
    guard let ud, let changes, n > 0 else { return }
    let ref = Unmanaged<EdValueRef>.fromOpaque(ud).takeUnretainedValue()
    ref.apply(String(cString: changes[n - 1].item.s ?? ""))
}
```

The settings screen becomes two-way bound:

```swift
struct SettingsView: View {
    @State private var playerName = EdBridge.shared.value("settings/player_name")
    var body: some View {
        Form { TextField("Player name", text: $playerName.text) }  // ⇄ Ed, across threads
    }
}
```

Edit → `ed_set` on the bridge thread → syncs to enu. Change in-game → enu pushes a
`Message` → bridge `tick` fires the callback → `MainActor` updates `text` → SwiftUI
redraws. The editor component is the same mechanism with `EdSeq[string]`/a registered ref
type, its change deltas mapped to a SwiftUI `ForEach`.

## Generalizing the shim (ship it with Ed)

The Swift bridge context slots into the exact role enu's **main/editor context** plays
today. In enu there are two long-lived contexts (`enu-explore/src/game.nim:214` main GUI,
`.../worker.nim:407` worker/authority). The editor mutates `code_value` on the main
context; Ed syncs it to the worker; the worker's `watch_code` (`worker.nim:314`)
recompiles — gated by `change.item.runner == Ed.thread_ctx.id`. A native Swift editor
replaces the Godot editor by being *a third context that does the same thing*: subscribe
to the worker, read/write `code_value`, and the worker recompiles unchanged. No enu logic
moves.

### What lives in the lib (don't write this per-app)

Ships in Ed + a reusable Swift package:

- The whole C ABI, `NimMain` init, context create/tick/free, the handle table + proxy
  rooting, `EdVar` marshalling, the C callback trampoline.
- Swift `EdBridge` (the serial-queue-as-thread + tick loop), and observable wrappers:
  `EdString`/`EdScalar` (one value) and `EdList` (an `EdSeq`/`EdTable`), all `@Observable`
  with `MainActor` delivery.
- **Identity adapters** for the primitives (`string`/`int`/`float`/`bool`) so scalar Ed
  fields need zero app code.
- **Field auto-enumeration**: a macro that walks a registered type's `*_value` fields (the
  same set enu's `build_accessors` already enumerates, `type_registry.nim:146`) and wires
  a bridge accessor per field whose element type has a known adapter. Addressing is
  `(object_id, field_name)`.

### Residual Nim glue (can't be pushed down — it names domain types)

Ed doesn't know about `Code`/`Config`/`Player`, so a small app module supplies adapters
for **compound value objects** and asks the bridge to register the domain types. This sits
next to enu's existing `Ed.register(...)` / `Ed.bootstrap` (`src/types.nim:557`,
`src/enu.nim:16`) and reuses them:

```nim
# enu_bridge.nim — the only app-specific Nim the bridge adds.
import ed, ed/swift_bridge          # pushed-down helper
import enu/types                    # Code, Config, Player, Unit, Sign ...

# Code is a plain object {owner, runner, nim}; Swift only wants the text.
# Project it to a string exactly like the editor does today (code.nim / Code.init).
ed_bridge_adapter(Code,
  to   = proc(c: Code): string = c.nim,
  from = proc(s: string): Code = Code.init(s))

# Config is one EdValue[Config] holding ~35 plain scalar fields (id "config").
# Auto-generate a per-field bridge accessor for each; the whole Config still swaps
# atomically underneath, so field observers all fire on any change (fine for settings).
ed_bridge_value_object(Config)      # macro enumerates Config's fields

# Wire the reactive containers. Reuses enu's *_value field enumeration; primitives
# are covered by identity adapters, Code by the adapter above.
ed_bridge_register(Player)          # rotation, cursor_position, ...
ed_bridge_register(Unit)            # code (via Code adapter), scale, glow, speed, ...
ed_bridge_register(Sign)            # message, more, width, billboard, ...
ed_bridge_register(GameState)       # config, level_name, ...
```

That's the whole "type registration" story: enu already instantiates every `Ed[T,O]` (so
`Ed.bootstrap` covers them) and already registers its ref types; the bridge adds
field-projection registration on top. Nothing is maintained in two places.

### Residual Swift (what the app author actually writes)

Just SwiftUI + a handle per thing observed. **Settings screen** — addressing the real
`"config"` value object's fields and the `"level_name"` scalar:

```swift
struct SettingsView: View {
    @State private var world     = EdBridge.shared.string("config", field: "world")
    @State private var fontSize  = EdBridge.shared.int("config", field: "font_size")
    @State private var fullScreen = EdBridge.shared.bool("config", field: "full_screen")
    @State private var level     = EdBridge.shared.string("level_name")   // top-level scalar

    var body: some View {
        Form {
            TextField("World", text: $world.value)
            Stepper("Font size: \(fontSize.value)", value: $fontSize.value, in: 8...48)
            Toggle("Fullscreen", isOn: $fullScreen.value)
            TextField("Level", text: $level.value)
        }
    }
}
```

**Editor component** — bind to the open unit's `code` field; the worker recompiles on
write via its existing subscription:

```swift
struct CodeEditor: View {
    @State private var code: EdString
    init(unitID: String) {
        _code = State(wrappedValue: EdBridge.shared.string(unitID, field: "code"))
    }
    var body: some View {
        TextEditor(text: $code.value)      // ⇄ code_value.nim; edit → worker recompiles
            .font(.system(.body, design: .monospaced))
    }
}
```

To respond to a model-side change (in-game code edit, executing-line move) there's nothing
extra to write — `EdString.value` is `@Observable`, so the `TextEditor` redraws when the
worker pushes a `code_value` change through the bridge context's `tick`. That is the same
event enu's editor handles today at `editor.nim:248` (`if added or touched: change.item.nim`),
just delivered to SwiftUI instead of a Godot `TextEdit`.

The "which unit is open" selection is context-local in enu (`open_unit_value` is
`{SYNC_LOCAL}`, `states.nim:166`), so the Swift context owns its own open-unit state — it
gets the unit id from the UI (a click) and resolves `("<unit-id>", "code")`. Units
themselves sync from the worker with default flags, so they're all present in the bridge
context.

## Threadsafe objects — the actor model, not locks

**Status: backlog.** Good idea, no current need found — the one concrete motivation (voxel
duplication) dissolves into cheaper subscription/architecture fixes (below). Revisit if a
genuine shared-single-copy need appears (many worker threads, or data that truly can't be
replicated). The design below is captured so it doesn't have to be re-derived.

Motivation: share one copy of memory-hungry data across many threads without a context per
thread (`SYNC_LOCAL` replication gives N copies by design). The first instinct — "put a
lock around each value" — is wrong, because a write is never object-local: it reaches into
`ctx.objects`, subscriber fanout, `ref_pool`/`owned_by`, the `op_id`/`lsn` counters, and
the store append (`tracking.nim:171`, `publish.nim:171-289`, `contexts.nim:143`). A
per-object lock would protect `tracked` while the registry races, and would leave callbacks
firing on the foreign writer's thread against the wrong `active_ctx` (`tracking.nim:53`,
`contexts.nim:128`, `operations.nim:539`).

The right model keeps the **context single-threaded and treats it as an actor**: foreign
threads don't mutate the graph, they hand work to the owning thread. A channel for writes,
a tiny lock for reads:

- **Owner thread** → today's fast path, unchanged.
- **Foreign write** (`value=`/`add`/`[]=`) → enqueue a command (body id + `EdVar`) onto the
  context's inbox; the owner, in `tick`, runs the *real* accessor. Reusing the actual
  accessor is what preserves LSN stamping, fanout, store append, and callbacks — no
  reimplementing write semantics. Callbacks therefore always fire on the owner thread with
  the correct `active_ctx`.
- **Foreign read** (`value`/`[]`) → `withLock body.cell: result = body.tracked`, a value
  copy, skipping evictor accounting and proxy minting. Owner-side `tracked =` writes take
  the same cell lock, but only when the object is flagged.

This defeats all three objections to the naive lock (foreign-thread callbacks, registry
races, `link_child` deadlock) because no lock is ever held across a callback and only the
owner mutates the graph.

Known costs / scope (verified against current code):

- **No `owner_tid` on `EdContext` today** — only a `get_thread_id()`-derived string id
  (`contexts.nim:77`). Add one, captured when the context binds to its thread (enu does
  this explicitly via `Ed.thread_ctx = ctx`).
- **`tracked =` is ~8 scattered sites** (`tracking.nim:282-293`, `operations.nim:97-347`,
  initializers) — the cell lock wraps the owner-side writes behind a `set_tracked` helper.
- **Foreign reads return value copies, not proxies** → clean for scalars/value-objects
  (`EdValue[float|Code|Config]`), leaky for containers-of-refs (`EdSeq[Unit]`). Restrict.
- **Async writes** → no read-your-writes on a foreign thread until the owner ticks.
- **`LAZY`/partial objects can't be read foreign** (materialize is owner-thread I/O);
  require flagged objects to be resident.

### What this means for the bridge

The bridge does **not** depend on this feature — build it on the replica model (its own
context, its own tick) now. But if actor-model shared objects land, a leaner bridge becomes
possible: Swift holds handles straight into enu's worker context — reads via the cell lock,
writes via the command queue, change callbacks firing on the worker's `tick` and
`DispatchQueue.main.async` to the UI — dropping the bridge's replica and tick loop entirely
(zero data duplication). The only coupling: a Swift `track` callback runs on the worker's
tick, so it must stay trivial (just `main.async`).

Decouple the decisions: the threadsafe-object work is motivated by voxel-scale data and
many-worker-thread setups; the bridge merely gets to ride it for free if it exists.

### Voxel memory: measured, the feature is the wrong lever there

The original motivation was enu's `PackedChunk` voxels being duplicated across the main and
worker contexts. Quantified against `enu-explore`, that motivation doesn't hold:

- The Ed-synced layer (`Build.packed_chunks`/`chunk_deltas`, `{SYNC_LOCAL, SYNC_REMOTE,
  LAZY}`, `builds.nim:424`) is **compressed** (RLE/sparse, `PackedChunk = {data: string}`).
  For 1 M voxels: ~1.7 KB solid, ~3 MB scattered *per copy*. The worker copy is already
  capped at 16 MB (LAZY paging); main holds it all but it's small.
- The real resident cost is the **decoded `local_voxels` table** (`~75 MB per million per
  copy`), rebuilt *independently* on both main and worker (`setup_packed_chunk_watches`),
  plus the Godot mesh/VRAM on main. **None of these are Ed objects** — a shared single Ed
  copy can't touch them.

So the actor-model feature would dedupe ~4% of voxel RAM (the compressed layer) and leave
the ~75 MB/copy decoded tables and the mesh untouched. It also can't touch the irreducible
part: **wired (interest-region) objects are pinned and never evicted**, so every voxel
within the player's interest radius (~200 m) is duplicated on main+worker regardless — that
working set is the floor, and it's decoded on both threads.

Cheaper, higher-leverage levers than the feature, in order:

1. **Make main a partial replica** instead of a full clone (`game.nim:213`). Main is the
   *unbounded* copy — it currently holds the whole world, compressed and decoded (its
   `local_voxels` decode follows what it holds). A partial main with an interest region
   drops to ~its interest set, reclaiming the entire far tail on the bigger copy — a
   subscription-flag change, no ed feature. Caveat: main is the render thread, so the
   interest region must cover the view distance or the horizon pops/pages; full-clone-main
   may have been chosen to avoid exactly that. Confirm render coverage first.
2. **Drop the redundant decode on main.** Confirmed lead: `render_snapshot_direct`/
   `render_delta_direct` (voxels.nim:761,797) render from the *compressed* snapshot
   (`decode_chunk` → transient buffer → `voxel_tool.set_voxel`/`paste`) and never read
   `local_voxels`. But `main_thread_joined` calls `setup_packed_chunk_watches()`
   unconditionally (builds.nim:573), decoding every chunk into `local_voxels` (~75 MB/M),
   while `worker_thread_joined` gates it to clients only (builds.nim:552). Main's render —
   its whole job — doesn't use that table. Remaining `local_voxels` readers to check before
   removing: voxel queries (`get_voxel`/`all_voxels`, scripts/VM, host_bridge.nim:1314), the
   edit path (`add_voxel`/`del_voxel`), and bounds (builds.nim:120). If main hits none of
   those, the decode is pure waste on main.
3. Bound the decoded table like the compressed layer already is.

These three are the actual voxel-memory work. None require the threadsafe-object feature.

Measurement hook: the stats overlay already shows `worker_ctx.used_bytes` ("ed mem",
`game.nim:127`) and Godot VRAM (`game.nim:207`), but `used_bytes` counts only the worker's
*compressed* bytes (main is a full clone and skips accounting), and nothing counts the
decoded tables. Saves persist only *manual* edits (tutorial "engage" world ≈ 12,364 manual
voxels ≈ 37 KB); computed voxels are re-derived by scripts, so live RAM must be measured in
a running session, not from the save file.

**Net: the threadsafe-object feature stands on its own merit for the bridge (shed the
replica) and many-thread cases, but is not justified by the voxel-memory argument.**

## Rules that will bite (write these down)

- **Every `ed_*` call on the owning thread.** The C ABI is single-thread-per-context by
  contract, not locked. The serial queue enforces it.
- **`NimMain()` once**, on that thread, before any other call. With `--nimMainPrefix:ed`
  it's `edNimMain`.
- **Root every handle.** Swift holds an integer; Nim's `vals` table holds the strong ref.
  Match every `ed_value` with an `ed_release`.
- **Retained callback box.** `passRetained` on track, balanced by `Unmanaged.release` on
  untrack/deinit, or the model leaks.
- **Returned `cstring`s are Ed-owned and transient** — copy into a Swift `String`
  immediately; never `free` them.
- **Same build flags as enu's Nim**, same Nim version: `--mm:orc --threads:on
  --tlsEmulation:off -d:nim_type_names`. In-process → native-endian is a non-issue.

## Phased plan

- **Phase 0 — toolchain proof.** `--app:staticlib --header` "hello" called from Swift on
  macOS. Confirm `NimMain` + ORC + threads link cleanly and `-d:nim_type_names` compiles.
- **Phase 1 — read-only scalar.** `EdValue[string]` `get` + `track`; one SwiftUI label
  updating live from a Nim-side write. Proves the thread/tick/callback plumbing.
- **Phase 2 — two-way + settings screen.** `ed_set`, `Binding`, `EdVar` generalized to
  int/float/bool. A handful of typed scalars.
- **Phase 3 — collections.** `EdSeq`/`EdTable` with change deltas → SwiftUI `ForEach`
  (script list, editor line buffer).
- **Phase 4 — domain objects.** `Ed.register`-style ref types exposed as structured
  values — the editor component proper.

## Decisions to make when we pick this up

1. **Dynamic `EdVar` variant vs generated typed accessors** per schema.
2. **Static lib vs emit-C-into-Xcode** (`nim c -c --os:ios --noMain`).
3. **Tick cadence owner** — plain timer, run-loop observer, or `CADisplayLink`.
4. **Threadsafe contexts/objects** (under evaluation) — would change the threading model
   the bridge assumes. See below.

## References

- genny — https://github.com/treeform/genny
- Nim backend integration — https://nim-lang.github.io/Nim/backends.html
- Nim compiler guide (`--app:staticlib`, `--nimMainPrefix`) — https://nim-lang.org/docs/nimc.html
- ARC/ORC (easier FFI) — https://nim-lang.org/blog/2020/10/15/introduction-to-arc-orc-in-nim.html
