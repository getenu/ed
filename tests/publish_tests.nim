import std/[tables, sugar, unittest]
import pkg/[flatty, chronicles, pretty]
import ed
import ed/[types, components/type_registry]
from std/times import init_duration

proc run*() =
  type
    Unit = ref object of EdRef

    Build = ref object of Unit
      build_stuff: string

    Bot = ref object of Unit
      bot_stuff: string

  Ed.register(Build, false)
  Ed.register(Bot, false)

  test "object publish inheritance":
    var
      ctx1 = EdContext.init(id = "ctx1")
      ctx2 = EdContext.init(id = "ctx2")
      build = Build(id: "some_build", build_stuff: "asdf")
      bot = Bot(id: "some_bot", bot_stuff: "wasd")
      units1 = EdSeq[Unit].init(id = "units", ctx = ctx1)
      units2 = EdSeq[Unit].init(id = "units", ctx = ctx2)

    ctx2.subscribe(ctx1)

    units1 += build
    units1 += bot

    ctx2.tick

    check units1.len == 2
    check units1[0] of Build
    check units1[1] of Bot

    check units2.len == 2
    check units2[0] of Build
    check units2[1] of Bot

  test "object mass assign inheritance":
    var
      ctx1 = EdContext.init(id = "ctx1")
      ctx2 = EdContext.init(id = "ctx2")
      build = Build(id: "some_build", build_stuff: "asdf")
      bot = Bot(id: "some_bot", bot_stuff: "wasd")
      units1 = EdSeq[Unit].init(id = "units", ctx = ctx1)
      units2 = EdSeq[Unit].init(id = "units", ctx = ctx2)

    ctx2.subscribe(ctx1)

    var units: seq[Unit]
    units.add build
    units.add bot

    units1.value = units

    ctx2.tick

    check units1.len == 2
    check units1[0] of Build
    check units1[1] of Bot

    check units2.len == 2
    check units2[0] of Build
    check units2[1] of Bot

  test "object publish on subscribe inheritance":
    var
      ctx1 = EdContext.init(id = "ctx1")
      ctx2 = EdContext.init(id = "ctx2")
      build = Build(id: "some_build", build_stuff: "asdf")
      bot = Bot(id: "some_bot", bot_stuff: "wasd")
      units1 = EdSeq[Unit].init(id = "units", ctx = ctx1)
      units2 = EdSeq[Unit].init(id = "units", ctx = ctx2)

    units1 += build
    units1 += bot

    ctx2.subscribe(ctx1)

    check units1.len == 2
    check units1[0] of Build
    check units1[1] of Bot

    check units2.len == 2
    check units2[0] of Build
    check units2[1] of Bot

  test "no sync objects are created remotely, but their value doesn't sync":
    var
      flags = {TRACK_CHILDREN}
      ctx1 = EdContext.init(id = "ctx1")
      ctx2 = EdContext.init(id = "ctx2")
      a = EdValue[string].init(id = "test1", ctx = ctx1, flags = flags)
      b = EdValue[string].init(id = "test1", ctx = ctx2, flags = flags)
      c = EdValue[string].init(id = "test2", ctx = ctx1, flags = flags)
      d: EdValue[string]

    check "test1" in ctx2
    check "test2" notin ctx2

    a.value = "fizz"
    c.value = "buzz"

    ctx2.subscribe(ctx1)

    check "test2" in ctx2

    d = d.type()(ctx2["test2"])

    check a.value == "fizz"
    check c.value == "buzz"
    check b.value == ""
    check d.value == ""

    b.value = "hello"
    d.value = "world"

    check a.value == "fizz"
    check b.value == "hello"
    check c.value == "buzz"
    check d.value == "world"

when is_main_module:
  Ed.bootstrap
  run()
