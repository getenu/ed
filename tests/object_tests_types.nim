import ed

type
  ZenString* = EdValue[string]

  Beep* = ref object of EdRef
    name_value*: EdValue[string]

  Boop* = ref object of Beep
    state_value*: ZenString
    messages*: EdSeq[string]

  Bloop* = ref object of Beep
    age_value*: EdValue[int]

Ed.register(Boop)
Ed.register(Bloop)
