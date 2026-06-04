import ed/[core, types {.all.}]

proc init*(
    _: type Change, T: type, changes: set[ChangeKind], field_name = ""
): Change[T] =
  Change[T](changes: changes, type_name: $Change[T], field_name: field_name)

proc init*[T](
    _: type Change, item: T, changes: set[ChangeKind], field_name = ""
): Change[T] =
  result = Change[T](
    item: item, changes: changes, type_name: $Change[T], field_name: field_name
  )

proc init*(
    _: type OperationContext,
    source: HashSet[string] = initHashSet[string](),
    ctx: EdContext = nil,
    origin = "",
    op_id: int64 = 0,
): OperationContext =
  result = OperationContext()
  result.source = source
  result.origin = origin
  result.op_id = op_id
  if ?ctx:
    result.source.incl ctx.id
  when defined(ed_trace):
    result.trace = get_stack_trace()

template setup_op_ctx*(self: EdContext) =
  let op_ctx =
    if ?op_ctx:
      op_ctx
    else:
      OperationContext.init(source = [self.id].toHashSet)

template privileged*() =
  private_access EdContext
  private_access EdBase
  private_access EdObject
