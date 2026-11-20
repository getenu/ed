# Ed Objects

How an object with synced fields should be declared, read, written and watched.
A design, not yet built. It follows from a bug and an exploration in November
2026; the prototypes it cites lived in a scratch folder and aren't kept, so the
results they produced are recorded here.

## Why

Today a synced object mixes two kinds of field with different rules, and the
difference is invisible at the declaration:

- **Ed fields** (`scale_value*: EdValue[float]`, `things*: EdSeq[Thing]`) sync on
  every change.
- **Plain fields** (`frame*: int`) look local but aren't. `stringify` copies them
  into the CREATE snapshot, and `revive` copies them again whenever a reference to
  a live object arrives inside another value. Only `{.ed_ignore.}` keeps a field
  truly local.

That caused a real bug in enu: opening the code editor sets
`state.player.coding` (an `EdValue[Thing]`), which ships main's copy of the build,
and the worker's live object was revived with main's plain fields. Its
`next_frame_id` went back to 1 on every run, so frames 1-3 shared one frame's
storage. The same path overwrites every other worker-local plain field on `Build`
(`frame`, `run_from_frame`, `bakes`, `baking`, `auto_ramp_*`, ...). Nothing at the
declaration says any of this can happen.

The rest is friction:

- An `EdValue` field has two names: `thing.scale = 5` to write and
  `thing.scale_value.changes:` to watch. Containers don't have this problem.
- `thing.scale += 1` doesn't compile.
- `thing.transform.origin.x = 5` doesn't compile; enu hand-writes `origin=` and
  `basis=` on `EdValue[Transform]` to cover one level of one type.

Cost is no longer a reason to avoid Ed fields. Since 0.34.0 an `EdValue[int]` is
about 600 bytes (it was about 12.6 KB, almost all of it an inline `set[uint16]`).

## Settled

### Declaring

```nim
type Thing* {.ed.} = ref object of Model
  parent* {.cursor, ignore.}: Thing
  things*: seq[Thing]                  # synced: an Ed of seq[Thing]
  scale*: float                        # synced: an Ed of float
  velocity* {.reject_stale.}: Vector3  # Ed flags as field pragmas
  script_ctx* {.ignore.}: ScriptCtx    # this side only, never synced

Ed.register(Thing)
```

- Every field not marked `{.ignore.}` is an Ed of the type written. The type you
  write is the type you read.
- `{.ignore.}` replaces `{.ed_ignore.}`: the field belongs to this side only and is
  never copied, at creation or after.
- The `{.ed.}` pragma rewrites the fields. It names each hidden Ed field
  `<name>_value`, enu's existing convention, so code that names `scale_value`
  keeps compiling while enu migrates type by type.
- Ed flags move from constructor calls to field pragmas. With none, a field
  syncs to other threads and the network (`SYNC_LOCAL`, `SYNC_REMOTE`).

  | Pragma | Flags |
  |---|---|
  | `{.local.}` | `SYNC_LOCAL` only: other threads, not the network |
  | `{.remote.}` | `SYNC_REMOTE` only |
  | `{.unsynced.}` | none: still an Ed you can watch and write with `+=`, `:=` and `edit`, but it never leaves this context |
  | `{.owns_members.}` | adds `OWNS_MEMBERS` (destroying the object destroys the members) |
  | `{.reject_stale.}` | adds `REJECT_STALE` |

  Two scope pragmas on one field, or any of these on an `{.ignore.}` field, is a
  compile error. The macro reads these itself, so ed exports no symbols with
  these names, and outside an `{.ed.}` type they're Nim's `invalid pragma`.
- `{.id: expr.}` gives a field's Ed a fixed id instead of a generated one, for
  an Ed another context finds by name (enu's `root_things` and `config`). The
  constructor evaluates `expr` with the object's `id` in scope, so
  `{.id: id & ":config".}` gives each object its own; a bare literal is shared
  by every object of the type, so it suits one object per context.
- Flags are set when a field is created and travel in its CREATE, so they can't
  change afterwards. `init_ed_fields` creates every Ed field that doesn't exist
  yet with its declared flags, id and default, so a type without a generated
  constructor (one that isn't an `EdRef`, like enu's `GameState`) can be
  built with `T(plain fields).init_ed_fields`. A subtype that needs different flags on an
  inherited field creates that field first; `init_ed_fields` leaves it alone.

### No plain synced fields

`stringify` and `revive` stop copying plain fields. A field is either Ed (synced
on every change) or `{.ignore.}` (local). "Copied once at creation" is not a third
option: it's the same trap, a field that looks synced and quietly isn't.

An audit of enu found only two plain fields that are really meant to cross:
`Thing.start_transform` and `Build.start_color`, both written on both sides. Two
more, `Sign.text_only` and `Build.bot_collisions`, are set at construction and
read on main. All four become Ed fields. Everything else on `Build`, plus
`Thing.frame_created`, `Thing.spawned_by` and `Player.colliders`, is per-side
state and becomes `{.ignore.}`. `Thing.disabled` appears unused.

ed's own identity (`EdRef.id`) is the exception. It has to reach the receiver, so
it's marked `{.ed_identity.}`, the one plain field `stringify` keeps. (Built:
`stringify` now clears every other plain field, and `revive` only relinks Ed
fields.)

### Registration and accessors

A type pragma can only return the type; it can't emit procs. `Ed.bootstrap`
expands once, in the program's last module, so procs it emitted would be invisible
to the modules that use the type. So:

- **Accessors** are generated by `Ed.register(T)`, next to the type, as today. They
  are plain procs: `proc scale*(self: Thing): float {.ed_accessor.}` returns the
  value, and ``proc `scale=`*(self: Thing, value: float)`` writes it. The
  `{.ed_accessor.}` marker lets the macros below recognize them.
- **Runtime registration** can be recorded by the pragma for `Ed.bootstrap`, which
  is still needed for that.

### Reading

Getters return plain values. Everything behaves like an ordinary field:
`let old = t.scale` is a snapshot, `a.scale == b.scale` compares values, and field
access, `case`, format specs, JSON, hashing and passing values between threads all
work.

A container field gives you the Ed itself, with its full API, as today.

### Watching

```nim
t.scale.changes:
  if added: echo change.item
```

`changes` becomes a macro. Given a call to an accessor (which is what `t.scale`
becomes once Nim has type-checked it), it watches the hidden Ed field; given an Ed,
it watches that, as today. A value copied into a local (`let s = t.scale;
s.changes:`) is a compile error.

### Compound assignment

`+=`, `-=`, `*=` and `&=` become generic typed macros:
`` macro `+=`[T](target: T, amount: T) ``.

- They only get chosen when the left side isn't assignable. system's overloads need
  a `var` and win whenever there is one, so plain variables are unaffected, and
  ed's own container `+=` is unaffected.
- The macro walks the left side down to an accessor call and rewrites it to read,
  change the copy, and write back as one write. That covers parts of a field too:
  `t.xform.origin.x += 3` is one write, which watchers see once. Paths can index
  into the value (`t.grid.cells[i] += 1`, `t.grid.names["a"] := 2`); each index
  is evaluated once.
- Converters and literals work as in plain Nim: `t.size += 2` on a float field
  works, and so does an `int` variable when an `int`-to-`float` converter is in
  scope.
- When the walk finds no accessor, the macro calls system's operator explicitly,
  so code with nothing synced in it gets Nim's own error message.

### Nested writes

Nim can't overload `=` for a field, and a getter can't hand back something that
both reads as a value and notices a later write (see Rejected). So nested writes
get explicit forms:

```nim
t.xform.origin.x := 5   # one write, any depth

edit t.xform:            # several changes, one read and one write
  origin.x = 10
  origin.y = 20
  scale = 3
```

- **`:=`** uses the same walk as `+=`. It's the only candidate that both parses
  like `=` and reads as assignment (see Rejected for the others). It works at any
  depth, `t.size := 5` included, and has no other meaning in Nim or ed, so it can
  give its own error when nothing synced is involved.
- **`edit`** takes an accessor (`edit t.xform:`) or an Ed (`edit t.xform_value:`)
  and replaces enu's `value:` template. Fields are written unqualified: an
  assignment whose target starts with one of the value's fields (`origin.x = 10`,
  `scale += 1`) goes to the copy. Locals and calls in the body are left alone.
  (`std/with`, which enu's `value:` uses, can't take a path like `origin.x`, and
  passes the copy to every call in the body, `echo` included.)
- Together they replace enu's hand-written `origin=` and `basis=` on
  `EdValue[Transform]`.

### Constructing

Hidden Ed fields can't be set with `Thing(scale: 1.0)`, and an Ed field left
uncreated is nil and crashes on first read. So `Ed.register(T)` generates a
constructor:

```nim
proc init*(_: type Ed, T: type Bot, id = "bot_" & generate_id(),
           start_transform = Transform.init, speed = 0.0, ...,
           ed_ctx = Ed.thread_ctx, ed_flags: tuple = ()): Bot
```

- One parameter per field, Ed and plain (refs included: `parent`, `clone_of`),
  base type first, in declaration order, so the first few can be passed
  positionally. The parameters ed adds are prefixed (`ed_ctx`, `ed_flags`) so they
  don't take names from your fields; a field named `ed_ctx` or `ed_flags` is a
  compile error.
- `id` defaults to the type's name in snake case plus a generated id.
- It runs inside the object's ownership scope, creates every Ed field with its
  declared flags, and passes each value with the field's CREATE (not a create
  and then a write). Defaults come from the declaration (`scale*: float = 1.0`
  in an `{.ed.}` type) or the value type's default.
- It works for types not declared with `{.ed.}` too: a `scale_value` field
  becomes a `scale` parameter, a container keeps its name, and flags and a
  fixed id come from `{.ed_flags: {...}.}` and `{.ed_id: expr.}` pragmas on
  the field (what `{.ed.}` rewrites its own pragmas to).
- `ed_flags = (transform: DEFAULT_FLAGS + {REJECT_STALE})` replaces one field's
  flags for this object; a name that isn't an Ed field of the type is a compile
  error. It's the only generic parameter, so the rest stay plain types. Anything
  stranger is built by hand: construct the object with those Ed fields filled,
  inside `id.own:`, then call `init_ed_fields`, which creates only what's
  missing.

`Ed.register(T, constructor = true)` (the default) also generates `T.init`,
forwarding to `Ed.init(T, ...)`. A type with setup of its own passes
`constructor = false` and writes its own `T.init`, which calls `Ed.init(T, ...)`
and then does the setup. No hook or method is involved, and the hand-written
`init` owns its signature (parameter names, overloads, subtype defaults like a
bot's `speed = 1.0`).

To free `Ed.init(T, ...)` for this, `Ed.init(SomeType)` (an empty container of
the kind a type implies) is removed, and `ed(value)` takes `id`, `ctx` and
`flags` and picks the container kind from the value (a seq makes an `EdSeq`, a
set an `EdSet`, a Table an `EdTable`). `EdValue[T].init(value)` and the other
typed forms are unchanged.

## Rejected

- **Getters that return the `EdValue`, with a converter to the value.** Comparing
  two fields picked ed's identity `==` (two things with scale 2.0 compared
  unequal), and `let old = t.scale` was a live alias that changed with the field.
- **A read type carrying the value and the field (`EdRead[T]`).** It fixed both of
  those and gave `+=`, but Nim only treats it as `T` where a converter applies.
  Measured failures: `t.pos.x` and `t.xform.origin.x` don't compile (no converters
  on field access); a value whose type has fields named like the read type's own
  (`value`, `cell`) silently returns the wrong thing; `case t.mode`, `&"{x:.1f}"`
  and `%x` don't compile; `var tf = t.xform; tf.origin.x = 5` doesn't compile; and
  `hash` disagreed with `==`, so sets and tables of reads missed equal values.
  Every stored read also keeps its field alive, and would carry a context's proxy
  across threads.
- **Generic dot operators (`` `.` `` / `` `.=` ``) instead of generated accessors.**
  They work, but they're experimental, need enabling wherever they're used, lose to
  any proc named like a field, and editors can't complete them.
- **A blanket `+=` macro or a term-rewriting template.** The first is ambiguous with
  system's and ed's overloads; the second never fires, because Nim rewrites only
  after type-checking and the expression fails first.
- **A constructor named `create`, or `Ed.new(T, ...)`.** ed would take a name
  from every registered type, and `system.create` exists. With `constructor =
  false` a type keeps `init` for itself.
- **A `setup` method called by the generated constructor.** It needs manual
  `procCall` chaining, and a forgotten chain silently skips the parent's setup.
- **Moving types into their own modules with `{.cyclic.}` imports.** Types cross
  a cycle, but procs a macro generates (accessors, constructors) don't take part
  in the cycle's phases: whether a module sees another's accessors depends on
  which one was imported first (tested with Nim 2.4.0).
- **A guard whose destructor writes back.** Nim destroyed the temporary at the end
  of the enclosing proc, not the statement, so the guard wrote its old copy back
  over later writes.
- **Operators that don't parse like `=`.** `~=` (model_citizen's) binds tighter
  than `+`, so `t.x ~= a + 1` is `(t.x ~= a) + 1`. `<-`, `=<` and `<<=` parse at
  comparison precedence, so `t.flag <- a == b` is `(t.flag <- a) == b`. `=>` parses
  fine but is `std/sugar`'s lambda. Of the operators that do parse like `=`
  (`:=`, `@=`, `|=`, `^=`, `$=`), only `:=` reads as assignment.
- **`with` as the block's name.** It already means "chain these calls" in Nim, so
  readers can't tell a write-back happens, and `std/with` takes any typed argument,
  so the two collide wherever both are imported (enu imports `std/with`).

## Related: moves and destroys

Separate from the field rules, but found alongside them. Both are built
(`docs/object-lifecycle.md` has the details):

- **Moves.** A registered ref removed from a collection is held until the next
  tick, so a move within the tick -- removed here, added there -- finds the same
  object on every side, even where nothing else holds it. A remove and add that
  land in different ticks (a relay, the network) still get a new object on the
  far side; enu covers that today with its synced `TRANSFERRING` flag.
- **Destroys are final.** Revive used to turn a same-id recreate into an update
  of the old object, so code holding a thing across a reload kept working. It
  ran on every pooled hit, though, which is how a live object got overwritten,
  and it brought destroyed objects back. It's gone. Each object carries an
  `incarnation`; an object arriving under an id whose pooled object is destroyed,
  or is another incarnation, is a new object. A destroy reaches every context
  (`REF_DESTROY`, naming the incarnation it ends), and `on_destroy` listeners
  tell holders to let go.

## Open

- **One-parameter `Ed[T]`.** A one-parameter alias that works out the change type
  (`Ed[int]` a value, `Ed[seq[int]]` an `EdSeq`) works, matching what `ed(value)`
  already does. Taking the name `Ed` for it needs the two-parameter core renamed,
  and a check that `Ed.register`, `Ed.bootstrap` and `Ed.thread_ctx` still work.
- **`+=` next to other libraries.** A non-generic `+=` in another library still
  wins, but a generic one taking a non-`var` left side of the same type could be
  ambiguous with ed's. Test against enu's dependencies before shipping.
