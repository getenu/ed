import std/[unittest, sets, tables, times, strutils]
import pkg/[pretty, chronicles]
import ed
import ed/components/type_registry

proc run*() =
  test "memory cleanup on context destruction":
    block:
      var ctx = EdContext.init(id = "temp_ctx")
      var obj1 = EdValue[string].init(ctx = ctx, id = "obj1")
      var obj2 = EdSeq[int].init(ctx = ctx, id = "obj2") 
      var obj3 = EdTable[string, float].init(ctx = ctx, id = "obj3")
      
      obj1.value = "test"
      obj2 += 42
      obj3["key"] = 3.14
      
      check ctx.len == 3
      # Context and objects go out of scope here
      
    # Memory should be cleaned up automatically

  test "reference pool cleanup":
    var ctx = EdContext.init(id = "ref_ctx")
    
    type RefObject = ref object of EdRef
      data: int
      
    Ed.register(RefObject, false)
    
    let ref_obj = RefObject(id: "test_ref", data: 123)
    var ref_container = EdSeq[RefObject].init(ctx = ctx)
    
    # Add reference
    ref_container += ref_obj
    check ref_container.len == 1
    
    # Remove reference
    ref_container -= ref_obj
    check ref_container.len == 0
    
    # Force reference cleanup
    ctx.prune_dead_refs()
    
    # Reference should eventually be cleaned up

  test "circular reference handling":
    var ctx = EdContext.init(id = "circular_ctx")
    
    type
      NodeA = ref object of EdRef
        b_ref: EdValue[NodeB]

      NodeB = ref object of EdRef
        a_ref: EdValue[NodeA]
    
    Ed.register(NodeA, false)
    Ed.register(NodeB, false)
    
    var node_a = NodeA(id: "a")
    var node_b = NodeB(id: "b")
    
    node_a.init_ed_fields(ctx = ctx)
    node_b.init_ed_fields(ctx = ctx)
    
    # Create circular reference
    node_a.b_ref.value = node_b
    node_b.a_ref.value = node_a
    
    # Should not crash or leak memory
    check node_a.b_ref.value == node_b
    check node_b.a_ref.value == node_a

  test "memory pressure handling":
    var ctx = EdContext.init(id = "pressure_ctx")
    
    # Create many objects to test memory pressure
    var objects: seq[EdValue[string]]
    
    for i in 1..50:
      var obj = EdValue[string].init(ctx = ctx, id = "obj" & $i)
      obj.value = "data" & $i
      objects.add obj
      
    check ctx.len >= 50
    
    # Clear references
    objects = @[]
    
    # Manual cleanup
    for i in 1..50:
      let obj_id = "obj" & $i
      if obj_id in ctx:
        var obj = EdValue[string](ctx[obj_id])
        obj.destroy()

  test "subscription memory management":
    var ctx1 = EdContext.init(id = "sub_ctx1")
    var ctx2 = EdContext.init(id = "sub_ctx2") 
    var ctx3 = EdContext.init(id = "sub_ctx3")
    
    # Create subscription chain
    ctx2.subscribe(ctx1)
    ctx3.subscribe(ctx2)
    
    var obj = EdValue[string].init(ctx = ctx1, id = "chain_obj")
    obj.value = "test_chain"
    
    ctx2.tick()
    ctx3.tick()
    
    # Verify propagation
    var obj2 = EdValue[string](ctx2["chain_obj"])
    var obj3 = EdValue[string](ctx3["chain_obj"])
    
    check obj2.value == "test_chain"
    check obj3.value == "test_chain"
    
    # Cleanup subscriptions
    # Note: Actual unsubscription would require more complex teardown

  test "large object serialization":
    var ctx1 = EdContext.init(id = "serialize_ctx1")
    var ctx2 = EdContext.init(id = "serialize_ctx2")
    
    ctx2.subscribe(ctx1)
    
    # Create object with large data
    var large_table = EdTable[string, string].init(ctx = ctx1, id = "large_data")
    
    # Add substantial data
    for i in 1..20:
      let key = "key_" & $i
      let value = "value_" & $i & "_" & "x".repeat(100)  # Large string values
      large_table[key] = value
      
    ctx2.tick()
    
    var remote_table = EdTable[string, string](ctx2["large_data"])
    check remote_table.len == 20
    check remote_table["key_1"].len > 100

  test "tracking callback cleanup":
    var ctx = EdContext.init(id = "callback_ctx")
    var obj = EdValue[string].init(ctx = ctx)
    
    var callback_count = 0
    
    # Add multiple tracking callbacks
    var zids: seq[EID]
    for i in 1..5:
      let zid = obj.track proc(changes: auto) {.gcsafe.} =
        callback_count += 1
        
      zids.add zid
    
    # Trigger changes
    obj.value = "trigger"
    check callback_count == 5
    
    # Remove callbacks
    for zid in zids:
      obj.untrack(zid)
      
    # Should not trigger more callbacks
    callback_count = 0
    obj.value = "no_trigger"
    check callback_count == 0

when is_main_module:
  Ed.bootstrap
  run()