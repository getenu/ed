import std/[unittest]
import pkg/[pretty, chronicles]
import ed

proc run*() =
  test "network connection timeout":
    var ctx = EdContext.init(id = "test_ctx")
    
    # This should fail with ConnectionError for nonexistent host
    expect(ConnectionError):
      ctx.subscribe("nonexistent.host.invalid:9999")

  test "network connection refused":
    var ctx = EdContext.init(id = "test_ctx")
    
    # This should fail when connecting to a closed port
    expect(ConnectionError):
      ctx.subscribe("127.0.0.1:9999")

  test "network connection timeout during subscription":
    var ctx1 = EdContext.init(id = "ctx1", listen_address = "127.0.0.1")
    var ctx2 = EdContext.init(id = "ctx2")
    
    # Create object before subscription
    var obj = Ed[string].init(ctx = ctx1, id = "test_obj")
    obj.value = "test_data"
    
    # Forcibly close the listening context
    ctx1.close()
    
    # This should handle the connection failure gracefully
    # But currently might not
    expect(ConnectionError):
      ctx2.subscribe("127.0.0.1")

  test "network message corruption handling":
    # This would test handling of corrupted network messages
    # Currently the library might not handle this gracefully
    var ctx1 = EdContext.init(id = "ctx1", listen_address = "127.0.0.1")
    var ctx2 = EdContext.init(id = "ctx2")
    
    ctx2.subscribe("127.0.0.1")
    
    # The library should handle network corruption, but might not
    # This is hard to test directly without lower-level network manipulation
    
    ctx1.close()

when is_main_module:
  Ed.bootstrap
  run()