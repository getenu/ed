## Wire layouts: a structural fingerprint of what flatty writes for a type, so two
## builds can tell whether they agree on a type before trading it. Type ids are
## name hashes, so a peer built from older sources still claims the same ids;
## flatty is positional, so a changed field list decodes into the wrong fields.
## Comparing layouts per type id at subscribe catches that up front.
##
## Only what reaches the wire counts. A registered type drops the fields its
## `stringify` drops (`ed_ignore`, plain refs, ptrs, procs), so builds can differ
## in local-only state, procs and initializers and still agree. Registered refs
## nested anywhere travel by id; their own layout is checked on their own type id.
##
## Signatures are purely structural. `$T` reports whichever alias of a type is in
## scope (`int` prints as `Hash` in some builds), so names would make two
## builds of the same types disagree depending on what else they import.

import std/[macros, hashes, typetraits, strutils]
import ed/types

macro enum_members(T: typedesc): string =
  var impl = T.get_type_inst[1].get_type_impl
  var names: seq[string]
  for i in 1 ..< impl.len:
    names.add impl[i].repr
  new_lit names.join(",")

proc layout_sig[T](_: typedesc[T], seen: var seq[string]): string

proc ed_item[A, B](_: typedesc[Ed[A, B]]): A =
  discard

proc ed_change[A, B](_: typedesc[Ed[A, B]]): B =
  discard

proc set_item[E](_: typedesc[set[E]]): E =
  discard

proc fields_sig[T](
    _: typedesc[T], registered: static bool, seen: var seq[string]
): string =
  # `$T` is only an identity within this one walk, never part of the output.
  const name = $T
  let depth = seen.find(name)
  if depth >= 0:
    return "rec" & $(seen.len - depth)
  seen.add name
  result = "{"
  var value: T
  for field_name, field in value.field_pairs:
    when registered and (
      field.has_custom_pragma(ed_ignore) or (field is ref and field isnot Ed) or
      field is ptr or field is proc
    ):
      discard
    else:
      result.add field_name & ":" & layout_sig(typeof(field), seen) & ";"
  result.add "}"
  seen.set_len(seen.len - 1)

proc layout_sig[T](_: typedesc[T], seen: var seq[string]): string =
  when T is Ed:
    "Ed[" & layout_sig(typeof(ed_item(T)), seen) & "," &
      layout_sig(typeof(ed_change(T)), seen) & "]"
  elif T is EdRef:
    "edref"
  elif T is ptr or T is pointer:
    "ptr"
  elif (T is proc):
    "proc"
  elif T is ref:
    "ref " & layout_sig(pointer_base(T), seen)
  elif T is enum:
    "enum(" & enum_members(T) & ")"
  elif T is distinct:
    layout_sig(distinct_base(T), seen)
  elif T is string:
    "string"
  elif T is cstring:
    "cstring"
  elif T is bool:
    "bool"
  elif T is char:
    "char"
  elif T is SomeSignedInt:
    "i" & $sizeof(T)
  elif T is SomeUnsignedInt:
    "u" & $sizeof(T)
  elif T is SomeFloat:
    "f" & $sizeof(T)
  elif T is seq:
    "seq[" & layout_sig(typeof(default(T)[0]), seen) & "]"
  elif T is array:
    "array[" & $len(default(T)) & "," & layout_sig(typeof(default(T)[0]), seen) &
      "]"
  elif T is set:
    "set[" & layout_sig(typeof(set_item(T)), seen) & "]"
  elif T is object or T is tuple:
    fields_sig(T, false, seen)
  else:
    "opaque" & $sizeof(T)

proc layout_signature*(T: typedesc): string =
  ## The layout of an Ed container or plain value type, as flatty writes it.
  var seen: seq[string]
  layout_sig(T, seen)

proc registered_layout_signature*(T: typedesc[ref object]): string =
  ## The layout of a registered type, as its `stringify` writes it.
  var seen: seq[string]
  fields_sig(pointer_base(T), true, seen)

proc layout_hash*(T: typedesc): int =
  const sig = layout_signature(T)
  hash(sig)

proc registered_layout_hash*(T: typedesc[ref object]): int =
  const sig = registered_layout_signature(T)
  hash(sig)
