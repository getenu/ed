import std/tables
import ed

type
  Vec* = object
    x*, y*: float

  Xform* = object
    origin*: Vec
    scale*: float

  Grid* = object
    cells*: seq[int]
    rows*: seq[Vec]
    names*: Table[string, int]

  Gadget* {.ed.} = ref object of EdRef
    size*: float = 1.5
    count*: int
    label*: string
    xform*: Xform
    parts*: seq[int]
    cache* {.ignore.}: string
    note* {.local.}: string
    beacon* {.remote.}: string
    scratch* {.unsynced.}: int
    gadgets* {.owns_members.}: seq[Gadget]
    pos* {.reject_stale.}: Vec
    grid*: Grid

Ed.register(Gadget)

type Widget* = ref object of EdRef
  note*: string                   # a plain field: stays on its own side
  name_value*: EdValue[string]

Ed.register(Widget)

type
  Base* {.ed.} = ref object of EdRef
    name*: string = "base"
    owner* {.ignore.}: Base
  Derived* {.ed.} = ref object of Base
    level*: int
    marks* {.local.}: seq[int]

Ed.register(Derived, constructor = false)

proc init*(_: type Derived, level: int): Derived =
  ## hand-written: its own signature, then its own setup
  result = Ed.init(Derived, level = level * 10)
  result.marks += 1

type Settings* {.ed.} = ref object of EdRef
  level_name* {.id: "settings_level_name", local.}: string
  parts* {.id: id & ":parts".}: seq[int]
  scale*: float

Ed.register(Settings)
