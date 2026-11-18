## Sugar for objects with synced fields (docs/ed-objects.md).
##
## ```nim
## type Thing* {.ed.} = ref object of RootObj
##   scale*: float                 # synced: a hidden `scale_value: EdValue[float]`
##   things*: seq[Thing]           # synced: `things: EdSeq[Thing]`
##   cache* {.ignore.}: string     # this side only
## Ed.register(Thing)              # plain `scale`/`scale=` accessors
##
## t.scale += 1                    # write back through the setter
## t.xform.origin.x := 5           # write one part of a synced value
## edit t.xform:                   # several parts, one write
##   origin.x = 5
## t.scale.changes:                # watch the field by its own name
##   ...
## ```

import std/[macros, strutils, sequtils]
import ed/types
import ed/components/subscriptions/watch

# --- declaring ---------------------------------------------------------------

proc container_type(field_type: NimNode): NimNode =
  ## The Ed container a field of this written type becomes: `seq[T]` an
  ## `EdSeq[T]`, `Table[K, V]` an `EdTable[K, V]`, `set[T]` an `EdSet[T]`;
  ## nil for a value. A type already written as an Ed is left alone.
  if field_type.kind == nnkBracketExpr and field_type[0].kind == nnkIdent:
    case field_type[0].str_val
    of "seq":
      return nnkBracketExpr.new_tree(ident"EdSeq", field_type[1])
    of "Table":
      return nnkBracketExpr.new_tree(ident"EdTable", field_type[1], field_type[2])
    of "set":
      return nnkBracketExpr.new_tree(ident"EdSet", field_type[1])
    of "Ed", "EdValue", "EdSeq", "EdTable", "EdSet":
      return field_type
  if field_type.kind == nnkIdent and field_type.str_val.starts_with("Ed"):
    return field_type

proc base_name(name: NimNode): NimNode =
  case name.kind
  of nnkPostfix: name[1]
  of nnkAccQuoted: name[0]
  else: name

proc with_name(name, new_name: NimNode): NimNode =
  ## `name` with its identifier replaced, keeping an export marker.
  if name.kind == nnkPostfix:
    nnkPostfix.new_tree(name[0], new_name)
  else:
    new_name

const
  scope_pragmas = ["local", "remote", "unsynced"]
  flag_pragmas = ["owns_members", "reject_stale"]

proc field_flags(pragmas: seq[NimNode], at: NimNode): NimNode =
  ## The flags a field's pragmas ask for, as a set literal, or nil for the
  ## default (`SYNC_LOCAL`, `SYNC_REMOTE`).
  var scope = ""
  var extra: seq[string]
  for p in pragmas:
    let name = p.str_val
    if name in scope_pragmas:
      if scope != "":
        error("a field takes one of `local`, `remote` and `unsynced`", at)
      scope = name
    elif name in flag_pragmas:
      extra.add name
  if scope == "" and extra.len == 0:
    return nil
  result = newNimNode(nnkCurly)
  case scope
  of "": result.add ident"SYNC_LOCAL", ident"SYNC_REMOTE"
  of "local": result.add ident"SYNC_LOCAL"
  of "remote": result.add ident"SYNC_REMOTE"
  else: discard # unsynced
  for name in extra:
    result.add ident(name.to_upper_ascii)

proc rewrite_field(name: NimNode, field_type, default: NimNode): NimNode =
  ## One field of an `{.ed.}` object, rewritten.
  var name = name
  var pragmas = newNimNode(nnkPragma) # passed through to the new field
  var ours: seq[NimNode]              # ignore and the flag pragmas
  if name.kind == nnkPragmaExpr:
    for p in name[1]:
      if p.kind == nnkIdent and
          (p.eq_ident("ignore") or p.str_val in scope_pragmas or
            p.str_val in flag_pragmas):
        ours.add p
      else:
        pragmas.add p
    name = name[0]
  let ignored = ours.any_it(it.eq_ident("ignore"))
  if ignored:
    if ours.len > 1:
      error("an `{.ignore.}` field isn't an Ed, so it takes no sync pragmas", name)
    pragmas.add ident"ed_ignore"
    let named =
      if pragmas.len > 0: nnkPragmaExpr.new_tree(name, pragmas) else: name
    return nnkIdentDefs.new_tree(named, field_type, default)

  let flags = ours.field_flags(name)
  if not flags.is_nil:
    pragmas.add nnkExprColonExpr.new_tree(ident"ed_flags", flags)
  let container = field_type.container_type
  let (new_name, new_type) =
    if not container.is_nil:
      (name, container)
    else:
      let hidden = ident(name.base_name.str_val & "_value")
      (name.with_name(hidden), nnkBracketExpr.new_tree(ident"EdValue", field_type))
  let named =
    if pragmas.len > 0: nnkPragmaExpr.new_tree(new_name, pragmas) else: new_name
  nnkIdentDefs.new_tree(named, new_type, default)

proc rewrite_fields(recs: NimNode): NimNode =
  result = newNimNode(nnkRecList)
  for def in recs:
    case def.kind
    of nnkIdentDefs:
      for name in def[0 ..^ 3]:
        result.add rewrite_field(name, def[^2], def[^1])
    else:
      error("`{.ed.}` objects support plain fields only (no case objects yet)", def)

macro ed*(def: untyped): untyped =
  ## `type Thing {.ed.} = ref object ...`: every field becomes an Ed of the type
  ## written -- a value field a hidden `<name>_value: EdValue[T]`, a `seq`,
  ## `Table` or `set` field the matching Ed container under its own name --
  ## unless it's `{.ignore.}`, which keeps it on this side only. Follow the
  ## type with `Ed.register(Thing)` for the value fields' accessors.
  expect_kind def, nnkTypeDef
  result = def.copy
  # drop our own pragma from the type's name
  if result[0].kind == nnkPragmaExpr:
    var pragmas = newNimNode(nnkPragma)
    for p in result[0][1]:
      if not (p.kind == nnkIdent and p.eq_ident("ed")):
        pragmas.add p
    result[0] =
      if pragmas.len == 0: result[0][0]
      else: nnkPragmaExpr.new_tree(result[0][0], pragmas)
  var obj = result[2]
  if obj.kind == nnkRefTy:
    obj = obj[0]
  expect_kind obj, nnkObjectTy
  if obj[2].kind == nnkRecList:
    obj[2] = obj[2].rewrite_fields

# --- recognizing a synced field ----------------------------------------------

proc is_ed_accessor(call: NimNode): bool =
  ## `call` is `getter(owner)` for a getter `Ed.register` generated.
  if call.kind notin {nnkCall, nnkCommand} or call.len != 2 or
      call[0].kind != nnkSym:
    return false
  let impl = call[0].get_impl
  if impl.kind notin {nnkProcDef, nnkFuncDef}:
    return false
  for p in impl.pragma:
    if p.kind == nnkSym and p.eq_ident("ed_accessor"):
      return true

proc synced_root(target: NimNode): tuple[root: NimNode, path: seq[NimNode]] =
  ## Walk `owner.field.a.b` down to the accessor call for `field`; `path` is
  ## the parts below it (`a`, `b`). `root` is nil if there's no synced field.
  var node = target
  while true:
    if node.is_ed_accessor:
      return (node, result.path)
    case node.kind
    of nnkDotExpr:
      result.path.insert node[1], 0
      node = node[0]
    of nnkHiddenDeref, nnkHiddenAddr, nnkHiddenStdConv, nnkHiddenSubConv:
      node = node[0]
    else:
      return (nil, @[])

proc ed_field(accessor: NimNode): NimNode =
  ## `scale(owner)` -> `owner.scale_value`
  nnkDotExpr.new_tree(accessor[1], ident(accessor[0].str_val & "_value"))

proc setter_of(accessor: NimNode): NimNode =
  nnkAccQuoted.new_tree(ident(accessor[0].str_val & "="))

proc write_back(target, value: NimNode, op: string): NimNode =
  ## Read the synced field under `target`, set (or `op`-combine) the part
  ## `target` names, write the field back: one write. nil if `target` has no
  ## synced field under it.
  let (root, path) = target.synced_root
  if root.is_nil:
    return nil
  let getter = ident(root[0].str_val)
  let setter = root.setter_of
  let owner = root[1]
  let copy = gensym(nskVar, "copy")
  var part = copy
  for p in path:
    part = nnkDotExpr.new_tree(part, ident(p.str_val))
  let new_value =
    if op == "": value
    else: newCall(nnkAccQuoted.new_tree(ident(op)), part, value)
  result = quote do:
    block:
      let obj = `owner`
      var `copy` = `getter`(obj)
      `part` = `new_value`
      `setter`(obj, `copy`)

# --- watching -----------------------------------------------------------------

macro changes*[T](target: T, body: untyped): untyped =
  ## `t.scale.changes:` -- watch a synced field by its own name. (An Ed picks
  ## the Ed overload instead.)
  if not target.is_ed_accessor:
    error("`changes` watches an Ed or a synced field", target)
  let field = target.ed_field
  result = quote do:
    watch.changes(`field`, `body`)

macro changes*[T](target: T, pause_me, body: untyped): untyped =
  if not target.is_ed_accessor:
    error("`changes` watches an Ed or a synced field", target)
  let field = target.ed_field
  result = quote do:
    watch.changes(`field`, `pause_me`, `body`)

# --- writing ------------------------------------------------------------------

proc compound(target, amount: NimNode, op: string): NimNode =
  result = write_back(target, amount, op)
  if result.is_nil:
    # nothing synced here: let Nim report it as it would without ed
    result = newCall(
      newDotExpr(ident"system", nnkAccQuoted.new_tree(ident(op & "="))),
      target, amount)

macro `+=`*[T](target: T, amount: T): untyped =
  ## `t.scale += n`: only chosen when the left side isn't assignable (system's
  ## `+=` needs a `var`), so plain variables are unaffected.
  compound(target, amount, "+")

macro `-=`*[T](target: T, amount: T): untyped =
  compound(target, amount, "-")

macro `*=`*[T](target: T, amount: T): untyped =
  compound(target, amount, "*")

macro `&=`*[T](target: T, amount: T): untyped =
  compound(target, amount, "&")

macro `:=`*(target: typed, value: untyped): untyped =
  ## `t.xform.origin.x := 5`: write one part of a synced field (or the whole
  ## field), as one write.
  result = write_back(target, value, "")
  if result.is_nil:
    error("`:=` writes to a synced field or a part of one", target)

proc field_names(value_type: NimNode): seq[string] =
  ## The fields of an object type (following `ref` and inheritance).
  var t = value_type
  if t.kind == nnkBracketExpr: # EdValue[T]: the value is the last parameter
    t = t[^1]
  var impl = t.get_type_impl
  if impl.kind == nnkRefTy:
    impl = impl[0].get_type_impl
  if impl.kind != nnkObjectTy:
    return
  for def in impl[2]:
    if def.kind == nnkIdentDefs:
      for name in def[0 ..^ 3]:
        result.add name.base_name.str_val

proc qualify(body: NimNode, copy: NimNode, fields: seq[string]): NimNode =
  ## Prefix `copy.` to every assignment target that starts with one of
  ## `fields` (`origin.x = 1` -> `copy.origin.x = 1`, `scale += 2` too).
  ## Anything else -- locals, calls, `echo` -- is left alone.
  proc fix_target(n: NimNode): NimNode =
    case n.kind
    of nnkIdent:
      if n.str_val in fields: nnkDotExpr.new_tree(copy, n) else: n
    of nnkDotExpr, nnkBracketExpr:
      var n = n.copy
      n[0] = n[0].fix_target
      n
    else:
      n
  result = body.copy
  case result.kind
  of nnkAsgn:
    result[0] = result[0].fix_target
  of nnkInfix:
    if result[0].kind == nnkIdent and result[0].str_val.ends_with("=") and
        result[0].str_val notin ["==", "<=", ">=", "!="]:
      result[1] = result[1].fix_target
  else:
    for i in 0 ..< result.len:
      result[i] = result[i].qualify(copy, fields)

macro edit*(target: typed, body: untyped): untyped =
  ## ```nim
  ## edit t.xform:
  ##   origin.x = 10
  ##   scale = 3
  ## ```
  ## Change several parts of a synced field, or of an `EdValue`, in one write.
  ## Assignments whose target starts with one of the value's fields are made
  ## to the copy; locals and calls are left alone.
  let copy = gensym(nskVar, "copy")
  if target.is_ed_accessor:
    let getter = ident(target[0].str_val)
    let setter = target.setter_of
    let owner = target[1]
    let body = body.qualify(copy, target.get_type_inst.field_names)
    result = quote do:
      block:
        let obj = `owner`
        var `copy` = `getter`(obj)
        `body`
        `setter`(obj, `copy`)
  else:
    let body = body.qualify(copy, target.get_type_inst.field_names)
    result = quote do:
      block:
        let field = `target`
        var `copy` = field.value
        `body`
        field.value = `copy`
