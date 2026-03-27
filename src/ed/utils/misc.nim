import std/[options, sets, strformat, strutils, hashes]

# Logic

proc intersects*[T](self: set[T], other: set[T]): bool =
  for value in self:
    if value in other:
      return true

template `?`*(self: ref): bool =
  not self.is_nil

template `?`*(self: object): bool =
  self != self.type.default

template `?`*[T](option: Option[T]): bool =
  option.is_some

template `?`*(self: SomeNumber): bool =
  self != 0

template `?`*(self: string): bool =
  self != ""

template `?`*[T](self: open_array[T]): bool =
  self.len > 0

template `?`*[T](self: set[T]): bool =
  self.card > 0

template `?`*[T](self: HashSet[T]): bool =
  self.card > 0

# Ids

# Sequential ids can make debugging easier in some cases, especially when
# diffing logs between runs. Ids will be unique across threads but not across 
# processes, so ensure this is only enabled for a single client.
when defined(zen_sequential_ids):
  import std/atomics
  var id_counter: Atomic[int]
  id_counter.store(0)

  proc generate_id*(): string =
    id_counter += 1
    "id-" & $id_counter.load

else:
  import pkg/nanoid
  proc generate_id*(): string =
    generate(alphabet = "abcdefghijklmnopqrstuvwxyz0123456789", size = 13)

type
  ZenError* = object of CatchableError

  ConnectionError* = object of ZenError

# Exceptions

template fail*(msg: string) =
  raise_assert msg

proc init*[T: Exception](
    kind: type[T], message: string, parent: ref Exception = nil
): ref T =
  (ref kind)(msg: message, parent: parent)

# General

# Workaround for templates not supporting {.discardable.}
proc make_discardable*[T](self: T): T {.discardable, inline.} =
  self

template `\`*(s: string): string =
  var f = fmt(s)
  f.remove_prefix("\n")
  f.remove_suffix(' ')
  f.remove_suffix("\n\n")
  f

func tid*(T: type): int =
  const name = $T
  const h = hash(name)
  when h < 0: -h else: h
