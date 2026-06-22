import std/[unittest]
import ed
import ed/zens/validations

proc run*() =
  test "zen validation - valid objects":
    var ctx = EdContext.init(id = "test_ctx")
    var zen_obj = EdValue[string].init(ctx = ctx, id = "test_obj")
    
    # Valid object should pass validation
    check zen_obj.valid == true
    
    # Object with value should pass validation  
    zen_obj.value = "test"
    check zen_obj.valid == true

  test "zen validation - invalid objects":
    var ctx = EdContext.init(id = "test_ctx")
    var zen_obj = EdValue[string].init(ctx = ctx, id = "test_obj")
    
    # Destroyed object should fail validation
    zen_obj.destroy()
    check zen_obj.valid == false
    
    # Nil object should fail validation
    var nil_obj: EdValue[string] = nil
    check nil_obj.valid == false

  test "zen cross-validation - same context":
    var ctx = EdContext.init(id = "test_ctx")
    var obj1 = EdValue[string].init(ctx = ctx, id = "obj1")
    var obj2 = EdValue[int].init(ctx = ctx, id = "obj2")
    
    # Objects from same context should validate together
    check obj1.valid(obj2) == true

  test "zen cross-validation - different contexts":
    var ctx1 = EdContext.init(id = "ctx1")
    var ctx2 = EdContext.init(id = "ctx2")
    var obj1 = EdValue[string].init(ctx = ctx1, id = "obj1")
    var obj2 = EdValue[int].init(ctx = ctx2, id = "obj2")
    
    # Objects from different contexts should fail cross-validation
    check obj1.valid(obj2) == false

  test "zen cross-validation - invalid objects":
    var ctx = EdContext.init(id = "test_ctx")
    var obj1 = EdValue[string].init(ctx = ctx, id = "obj1")
    var obj2 = EdValue[int].init(ctx = ctx, id = "obj2")
    
    # Destroy one object
    obj2.destroy()
    
    # Should fail when one object is invalid
    check obj1.valid(obj2) == false
    
    # Should fail when both objects are invalid
    obj1.destroy()
    check obj1.valid(obj2) == false

  test "validation with nil references":
    var ctx = EdContext.init(id = "test_ctx") 
    var valid_obj = EdValue[string].init(ctx = ctx, id = "valid")
    var nil_obj: EdValue[int] = nil
    
    # Valid object with nil should fail
    check valid_obj.valid(nil_obj) == false

when is_main_module:
  Ed.bootstrap
  run()