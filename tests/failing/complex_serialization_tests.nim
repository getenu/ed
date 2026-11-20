import std/[unittest, tables, sequtils]
import pkg/[pretty, chronicles]
import ed

proc run*() =
  test "deeply nested object serialization":
    type
      NestedLevel5 = ref object of RootObj
        id: string
        data: string
        
      NestedLevel4 = ref object of RootObj
        id: string
        level5_objects: Ed[seq[NestedLevel5]]
        
      NestedLevel3 = ref object of RootObj
        id: string
        level4_table: Ed[Table[string, NestedLevel4]]
        
      NestedLevel2 = ref object of RootObj
        id: string
        level3_seq: Ed[seq[NestedLevel3]]
        
      NestedLevel1 = ref object of RootObj
        id: string
        level2_value: Ed[NestedLevel2]
    
    # Register all types
    Ed.register(NestedLevel5, false)
    Ed.register(NestedLevel4, false)
    Ed.register(NestedLevel3, false)
    Ed.register(NestedLevel2, false)
    Ed.register(NestedLevel1, false)
    
    var ctx1 = EdContext.init(id = "ctx1")
    var ctx2 = EdContext.init(id = "ctx2")
    
    ctx2.subscribe(ctx1)
    
    # Create deeply nested structure
    var root = NestedLevel1(id: "root")
    root.init_ed_fields(ctx = ctx1)
    
    var level2_obj = NestedLevel2(id: "level2")
    level2_obj.init_ed_fields(ctx = ctx1)
    root.level2_value.value = level2_obj
    
    # Add multiple level3 objects
    for i in 1..5:
      var level3 = NestedLevel3(id: "level3_" & $i)
      level3.init_ed_fields(ctx = ctx1)
      level2_obj.level3_seq += level3
      
      # Add level4 objects to table
      for j in 1..3:
        var level4 = NestedLevel4(id: "level4_" & $i & "_" & $j)
        level4.init_ed_fields(ctx = ctx1)
        level3.level4_table["key_" & $j] = level4
        
        # Add level5 objects
        for k in 1..2:
          var level5 = NestedLevel5(id: "level5_" & $i & "_" & $j & "_" & $k)
          level5.data = "deep_data_" & $i & "_" & $j & "_" & $k
          level4.level5_objects += level5
    
    ctx2.tick()
    
    # Verify the complex structure was serialized and deserialized correctly
    var remote_root = NestedLevel1.init_from(root, ctx = ctx2)
    
    check remote_root.level2_value.value.id == "level2"
    check remote_root.level2_value.value.level3_seq.len == 5
    check remote_root.level2_value.value.level3_seq[0].level4_table.len == 3
    check remote_root.level2_value.value.level3_seq[0].level4_table["key_1"].level5_objects.len == 2
    check remote_root.level2_value.value.level3_seq[0].level4_table["key_1"].level5_objects[0].data == "deep_data_1_1_1"

  test "circular reference serialization":
    type
      NodeA = ref object of RootObj
        id: string
        b_refs: Ed[seq[NodeB]]
        
      NodeB = ref object of RootObj
        id: string
        a_ref: Ed[NodeA]
    
    Ed.register(NodeA, false)
    Ed.register(NodeB, false)
    
    var ctx1 = EdContext.init(id = "ctx1")
    var ctx2 = EdContext.init(id = "ctx2")
    
    ctx2.subscribe(ctx1)
    
    # Create circular references
    var nodeA = NodeA(id: "A")
    var nodeB1 = NodeB(id: "B1")
    var nodeB2 = NodeB(id: "B2")
    
    nodeA.init_ed_fields(ctx = ctx1)
    nodeB1.init_ed_fields(ctx = ctx1)
    nodeB2.init_ed_fields(ctx = ctx1)
    
    # Create the circular references
    nodeA.b_refs += nodeB1
    nodeA.b_refs += nodeB2
    nodeB1.a_ref.value = nodeA
    nodeB2.a_ref.value = nodeA
    
    ctx2.tick()
    
    # This might fail due to circular reference serialization issues
    var remote_nodeA = NodeA.init_from(nodeA, ctx = ctx2)
    check remote_nodeA.b_refs.len == 2
    check remote_nodeA.b_refs[0].a_ref.value == remote_nodeA

  test "large binary data serialization":
    var ctx1 = EdContext.init(id = "ctx1")
    var ctx2 = EdContext.init(id = "ctx2")
    
    ctx2.subscribe(ctx1)
    
    # Create large string data (simulating binary data)
    let large_data = "x".repeat(1_000_000)  # 1MB of data
    var data_container = Ed[string].init(ctx = ctx1, id = "large_data")
    data_container.value = large_data
    
    ctx2.tick()
    
    # Large data serialization might fail or be very slow
    let remote_data = Ed[string](ctx2["large_data"])
    check remote_data.value.len == 1_000_000

  test "complex table with mixed types":
    type
      MixedData = ref object of RootObj
        id: string
        int_val: int
        str_val: string
        nested_table: Ed[Table[string, Ed[seq[Ed[float]]]]]
        
    Ed.register(MixedData, false)
    
    var ctx1 = EdContext.init(id = "ctx1")
    var ctx2 = EdContext.init(id = "ctx2")
    
    ctx2.subscribe(ctx1)
    
    var complex_table = Ed[Table[string, MixedData]].init(ctx = ctx1, id = "complex")
    
    # Create complex nested data
    for i in 1..50:
      var mixed = MixedData(id: "mixed_" & $i, int_val: i, str_val: "string_" & $i)
      mixed.init_ed_fields(ctx = ctx1)
      
      # Add nested table with sequences of values
      for j in 1..5:
        mixed.nested_table["key_" & $j] = Ed[seq[Ed[float]]].init(ctx = ctx1)
        for k in 1..3:
          let float_val = Ed[float].init(ctx = ctx1)
          float_val.value = float(i * j * k) / 10.0
          mixed.nested_table["key_" & $j] += float_val
      
      complex_table["item_" & $i] = mixed
    
    ctx2.tick()
    
    # Complex serialization might fail
    let remote_table = Ed[Table[string, MixedData]](ctx2["complex"])
    check remote_table.len == 50
    check remote_table["item_1"].nested_table["key_1"][0].value == 0.1

when is_main_module:
  Ed.bootstrap
  run()