import ed

type
  Vec* = object
    x*, y*: float

  Xform* = object
    origin*: Vec
    scale*: float

  Gadget* {.ed.} = ref object of EdRef
    size*: float
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

Ed.register(Gadget)
