import std/[unittest, monotimes, tables, strutils]
import ed
import ed/utils/[stats, misc, typeids]
from std/times import seconds, init_duration

proc run*() =
  test "misc utilities":
    # Test intersects function
    type SmallRange = range[0 .. 10]
    check:
      {SmallRange(1), SmallRange(2), SmallRange(3)}.intersects(
        {SmallRange(2), SmallRange(4), SmallRange(5)}
      ) == true
      {SmallRange(1), SmallRange(2), SmallRange(3)}.intersects(
        {SmallRange(4), SmallRange(5), SmallRange(6)}
      ) == false

    let empty_set: set[SmallRange] = {}
    check empty_set.intersects({SmallRange(1), SmallRange(2)}) == false

    # Test ? operator overloads
    type TestRange = range[0 .. 10]
    var
      nil_ref: ref int = nil
      some_ref = new int
      empty_str = ""
      filled_str = "hello"
      empty_seq: seq[int] = @[]
      filled_seq = @[1, 2, 3]
      empty_test_set: set[TestRange] = {}
      filled_test_set = {TestRange(1), TestRange(2), TestRange(3)}
      zero_num = 0
      nonzero_num = 42

    check:
      not ?nil_ref
      ?some_ref
      not ?empty_str
      ?filled_str
      not ?empty_seq
      ?filled_seq
      not ?empty_test_set
      ?filled_test_set
      not ?zero_num
      ?nonzero_num

    # Test ID generation (both sequential and nanoid modes)
    let id1 = generate_id()
    let id2 = generate_id()
    check:
      id1 != id2
      id1.len > 0
      id2.len > 0

    # Test exception initialization
    let exc = ConnectionError.init("test connection failed")
    check:
      exc.msg == "test connection failed"
      exc of ConnectionError
      exc of ZenError

  test "stats functionality":
    # Test stats macros
    var call_count = 0

    proc test_stats_enabled() {.stats.} =
      call_count += 1
      sample("checkpoint1")
      call_count += 1
      sample("checkpoint2")
      call_count += 1

    proc test_stats_disabled() {.stats(false).} =
      call_count += 1
      sample("should_not_track")
      call_count += 1

    test_stats_enabled()
    test_stats_disabled()

    check call_count == 5

    # Test timing functions
    let start = now()
    let duration = 0.5.seconds
    # Duration exists and is usable

    # Test maybe_dump_stats (won't actually dump in test)
    maybe_dump_stats()

  test "type IDs":
    type
      TestRef1 = ref object of RootObj
        id: string

      TestRef2 = ref object of TestRef1
        extra: int

      TestRef3 = ref object of RootObj
        different: bool

    let obj1 = TestRef1(id: "test1")
    let obj2 = TestRef2(id: "test2", extra: 42)
    let obj3 = TestRef3(different: true)
    let obj4 = TestRef1(id: "test4")

    check:
      obj1.type_id == TestRef1.type_id
      obj2.type_id == TestRef2.type_id
      obj3.type_id == TestRef3.type_id
      obj4.type_id == obj1.type_id
      obj1.type_id != obj2.type_id
      obj1.type_id != obj3.type_id
      obj2.type_id != obj3.type_id

  test "string formatting":
    # Test backslash string formatting
    let formatted =
      \"""
    This is a test
    with multiple lines

    """
    check formatted.contains("This is a test")
    check not formatted.starts_with("\n")

  test "make_discardable helper":
    # Test discardable wrapper
    proc returns_int(): int =
      42

    # This should compile without warnings
    returns_int().make_discardable()
    check returns_int().make_discardable() == 42

when is_main_module:
  Ed.bootstrap
  run()
