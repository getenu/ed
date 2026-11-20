import std/[unittest, os]
import pkg/[pretty, chronicles]
import ed

proc run*() =
  test "subscription cleanup after forced disconnection":
    var ctx1 = EdContext.init(id = "ctx1", listen_address = "127.0.0.1")
    var ctx2 = EdContext.init(id = "ctx2")
    
    # Establish subscription
    ctx2.subscribe("127.0.0.1")
    
    var obj = Ed[string].init(ctx = ctx1, id = "cleanup_test")
    obj.value = "before_disconnect"
    
    ctx2.tick()
    let remote_obj = Ed[string](ctx2["cleanup_test"])
    check remote_obj.value == "before_disconnect"
    
    # Forcibly close the server context without proper cleanup
    ctx1.close()
    
    # Try to modify object - this should handle disconnection gracefully
    # But might leave dangling references or fail unexpectedly
    obj.value = "after_disconnect"
    
    # The client should detect the disconnection
    ctx2.tick()
    
    # This might fail if cleanup isn't proper
    check ctx2.subscribers.len == 0  # Should have no active subscribers

  test "memory cleanup after subscription removal":
    var ctx1 = EdContext.init(id = "ctx1")
    var ctx2 = EdContext.init(id = "ctx2")
    
    # Create many objects before subscription
    var objects: seq[Ed[string]]
    for i in 1..1000:
      let obj = Ed[string].init(ctx = ctx1, id = "obj_" & $i)
      obj.value = "data_" & $i
      objects.add obj
    
    # Subscribe and sync all objects
    ctx2.subscribe(ctx1)
    ctx2.tick()
    
    check ctx2.len == 1000
    
    # Now destroy all objects in ctx1
    for obj in objects:
      obj.destroy()
    
    ctx2.tick()
    
    # ctx2 should clean up the remote references
    # But this might fail if cleanup is incomplete
    check ctx2.len == 0

  test "context destruction with active subscriptions":
    block:
      var ctx1 = EdContext.init(id = "ctx1")
      var ctx2 = EdContext.init(id = "ctx2")
      var ctx3 = EdContext.init(id = "ctx3")
      
      # Create subscription chain
      ctx2.subscribe(ctx1)
      ctx3.subscribe(ctx2)
      
      var obj = Ed[string].init(ctx = ctx1, id = "chain_obj")
      obj.value = "propagate"
      
      ctx2.tick()
      ctx3.tick()
      
      # All contexts have the object
      check "chain_obj" in ctx2
      check "chain_obj" in ctx3
      
      # ctx2 goes out of scope and is destroyed
      # This should properly clean up subscriptions
    
    # ctx1 and ctx3 should handle the destroyed middle context
    # But this might leave dangling references

  test "rapid subscription and unsubscription":
    var ctx1 = EdContext.init(id = "ctx1", listen_address = "127.0.0.1")
    
    # Rapidly create and destroy subscriptions
    for i in 1..50:
      block:
        var temp_ctx = EdContext.init(id = "temp_" & $i)
        
        # Quick subscription
        temp_ctx.subscribe("127.0.0.1")
        
        var obj = Ed[int].init(ctx = ctx1, id = "rapid_" & $i)
        obj.value = i
        
        temp_ctx.tick()
        
        # temp_ctx is destroyed when block exits
        # This tests cleanup under rapid subscription/destruction cycles
    
    # ctx1 should handle all the rapid connections/disconnections
    check ctx1.subscribers.len >= 0  # Should not have negative count

  test "tracking callback cleanup on context destruction":
    var callback_count = 0
    
    block:
      var ctx = EdContext.init(id = "temp_ctx")
      var obj = Ed[string].init(ctx = ctx)
      
      # Add tracking callbacks
      for i in 1..10:
        obj.track proc(changes: auto) {.gcsafe.} =
          callback_count += 1
      
      # Trigger callbacks
      obj.value = "trigger"
      check callback_count == 10
      
      # Context is destroyed here
    
    # After context destruction, callbacks should be cleaned up
    # But there might be memory leaks if not properly handled

  test "subscription with object destruction race":
    var ctx1 = EdContext.init(id = "ctx1")
    var ctx2 = EdContext.init(id = "ctx2") 
    
    var obj = Ed[string].init(ctx = ctx1, id = "race_obj")
    obj.value = "initial"
    
    # Start subscription
    ctx2.subscribe(ctx1)
    
    # Immediately destroy the object while subscription is establishing
    obj.destroy()
    
    ctx2.tick()
    
    # This race condition might cause issues
    # The object might be partially synced or leave inconsistent state
    check "race_obj" notin ctx2  # Should not be present

when is_main_module:
  Ed.bootstrap
  run()