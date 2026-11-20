import ed

type
  ZenString* = Ed[string]

  Beep* = ref object of EdRef
    name_value*: Ed[string]

  Boop* = ref object of Beep
    state_value*: ZenString
    messages*: Ed[seq[string]]

  Bloop* = ref object of Beep
    age_value*: Ed[int]

Ed.register(Boop)
Ed.register(Bloop)
