import std/sets
import ed/types {.all.}
import ed/components/private/global_state
const chronicles_enabled* {.strdefine.} = "off"

when chronicles_enabled == "on":
  import pkg/chronicles
  export chronicles

  # Format types for concise logging
  chronicles.format_it(EdContext): it.id
  chronicles.format_it(Subscription): $it.kind & " sub for " & it.ctx_id
  chronicles.format_it(OperationContext):
    if it.source.len == 0:
      "(no source)"
    else:
      "source=" & $it.source
  chronicles.format_it(Message):
    $it.kind & " " & it.object_id & " obj=" & $it.obj.len & "b"

  # Must be explicitly called from generic procs due to
  # https://github.com/status-im/nim-chronicles/issues/121
  template log_defaults*(log_topics = "ed") =
    log_scope:
      topics = log_topics
      # A thread that only uses explicit contexts never mints the implicit
      # thread ctx -- an unguarded active_ctx.id turns the first emitted
      # warn/notice on it into a nil deref.
      thread_ctx = (if active_ctx == nil: "" else: active_ctx.id)

else:
  # Don't include chronicles unless it's specifically enabled.
  # Use of chronicles in a module requires that the calling module also import
  # chronicles, due to https://github.com/nim-lang/Nim/issues/11225.
  # This has been fixed in Nim, so it may be possible to fix in chronicles.
  template trace*(msg: string, _: varargs[untyped]) =
    discard

  template notice*(msg: string, _: varargs[untyped]) =
    discard

  template debug*(msg: string, _: varargs[untyped]) =
    discard

  template info*(msg: string, _: varargs[untyped]) =
    discard

  template warn*(msg: string, _: varargs[untyped]) =
    discard

  template error*(msg: string, _: varargs[untyped]) =
    discard

  template fatal*(msg: string, _: varargs[untyped]) =
    discard

  template log_scope*(body: untyped) =
    discard

  template log_defaults*(log_topics = "") =
    discard

type EdDefect* = object of Defect
  ## Raised by `invariant` in non-release builds when a state we expect to hold
  ## is violated.

template invariant*(cond: bool, message: string) =
  ## A state we always expect to hold. A violation is a bug, but a recoverable
  ## one: in debug builds raise (so dev/test fails loud), in release log an error
  ## and continue -- a long-lived process shouldn't die over a state it can
  ## safely limp past. Use only where continuing really is safe.
  if not cond:
    when defined(release) or defined(danger):
      error "invariant violated", detail = message
    else:
      raise newException(EdDefect, "invariant violated: " & message)
