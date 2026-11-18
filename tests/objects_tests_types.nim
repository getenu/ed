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

Ed.register(Gadget)
