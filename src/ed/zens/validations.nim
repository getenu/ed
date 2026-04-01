import ed/[core, types]

proc valid*[T: ref EdBase](self: T): bool =
  log_defaults
  result = ?self and not self.destroyed
  if not result:
    let id = if ?self: self.id else: "nil"

    error "Ed invalid", id, type_name = $T, trace = get_stack_trace()

proc valid*[T: ref EdBase, V: ref EdBase](self: T, value: V): bool =
  self.valid and value.valid and self.ctx == value.ctx
