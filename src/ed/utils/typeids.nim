import std/[hashes]

proc base_type*(obj: RootObj): cstring =
  when not defined(nim_type_names):
    {.error: "you need to compile this with '-d:nim_type_names'".}
  {.emit: "result = `obj`->m_type->name;".}

proc base_type*(obj: ref RootObj): cstring =
  obj[].base_type

proc type_id*(obj: ref RootObj): int =
  int obj.base_type.hash

proc type_id*(T: type[ref RootObj]): int =
  T().type_id

when is_main_module:
  import std/unittest
  type
    One = ref object of RootObj
    Two = ref object of One
    Three = ref object
    Four = ref object of RootObj

  var
    a = One()
    b = Two()
    c = Three()
    d = Four()
    f: One = Two()
    g: RootRef = Four()

  check a.type_id == One.type_id
  check b.type_id == Two.type_id
  check f.type_id == Two.type_id
  check d.type_id == Four.type_id
  check d.type_id == g.type_id
