## The change-tracking API: track/untrack, lifetime binding, and the `changes`
## sugar with its self-capture static checks. Independent of the sync core --
## callbacks live on the body (sentinel model), the proxy arrives as `it`.

import
  std/[importutils, tables, sets, intsets, times, strutils, macros, os, heapqueue]
import ed/[core, types {.all.}], ed/zens/[contexts, private, initializers {.all.}]
import ed/components/private/global_state
import ed/lifecycle

privileged
proc untrack*[T, O](self: Ed[T, O], zid: EID) =
  privileged
  log_defaults
  assert self.valid

  let body = self.typed_body
  if zid in body.changed_callbacks:
    let callback = body.changed_callbacks[zid]
    if zid notin body.paused_eids:
      callback(@[Change.init(O, {CLOSED})], self)
    self.ctx.close_index.del(zid)
    body.changed_callbacks.del(zid)
    body.callback_gens.del(zid)
  else:
    error "no change callback for zid", zid = zid

proc bind_lifetime*[T, O](self: Ed[T, O], lifetime: Lifetime, zid: EID) =
  ## Bind an already-registered callback (`zid`) to `lifetime`, so it untracks
  ## when the lifetime finishes. Lets sugar that mints its own zid (`changes`,
  ## enu's `watch`) route teardown through an owner's Lifetime without exposing
  ## the privileged untrack path. Guarded so a manual untrack first -- or the
  ## owner dying first -- is safe and idempotent.
  privileged
  lifetime.add proc() {.gcsafe.} =
    if not self.destroyed and zid in self.typed_body.changed_callbacks:
      self.untrack(zid)

proc track*[T, O](
    self: Ed[T, O], callback: proc(changes: seq[Change[O]]) {.gcsafe.}
): EID {.discardable.} =
  ## Register a callback to be called when the container changes. Returns an EID
  ## that can be used to untrack the callback later.
  privileged
  log_defaults

  assert self.valid
  inc self.ctx.changed_callback_eid
  let zid = self.ctx.changed_callback_eid
  let body = self.typed_body
  # Wrap the 1-arg callback in the stored 2-arg shape; the wrapper captures
  # only the user's closure (their captures are their pins).
  body.changed_callbacks[zid] = proc(
      changes: seq[Change[O]], it: ref EdBase
  ) {.gcsafe.} =
    callback(changes)
  body.callback_gens[zid] = body.proxy_gen
  self.ctx.close_index[zid] = self.id
  result = zid

  # Inside an `own` scope, route this callback's untrack through the owner's
  # lifetime too, so it's torn down when the owner is destroyed (the typical
  # case: a subscription on something the owner doesn't itself own). No scope
  # open -> no-op. Idempotent if also bound explicitly.
  {.gcsafe.}:
    if not current_lifetime.is_nil:
      self.bind_lifetime(current_lifetime, zid)

proc track*[T, O](
    self: Ed[T, O], callback: proc(changes: seq[Change[O]], zid: EID) {.gcsafe.}
): EID {.discardable.} =
  assert self.valid
  var zid: EID
  zid = self.track proc(changes: seq[Change[O]]) {.gcsafe.} =
    callback(changes, zid)

  result = zid

proc track*[T, O](
    self: Ed[T, O],
    callback:
      proc(changes: seq[Change[O]], zid: EID, it: Ed[T, O]) {.gcsafe.},
): EID {.discardable.} =
  ## The non-capturing form: the live proxy arrives as `it` each fire, so the
  ## callback needs no reference to the watched object at all -- a proxy
  ## tracked this way still dies promptly when the app drops it. The sugar
  ## (`changes`/`watch`) builds on this.
  privileged
  assert self.valid
  inc self.ctx.changed_callback_eid
  let zid = self.ctx.changed_callback_eid
  let body = self.typed_body
  body.changed_callbacks[zid] = proc(
      changes: seq[Change[O]], it: ref EdBase
  ) {.gcsafe.} =
    callback(changes, zid, Ed[T, O](it))
  body.callback_gens[zid] = body.proxy_gen
  self.ctx.close_index[zid] = self.id
  result = zid
  {.gcsafe.}:
    if not current_lifetime.is_nil:
      self.bind_lifetime(current_lifetime, zid)

proc track*[T, O](
    self: Ed[T, O],
    lifetime: Lifetime,
    callback: proc(changes: seq[Change[O]]) {.gcsafe.},
): EID {.discardable.} =
  ## Like `track`, but the callback's removal is owned by `lifetime`: when the
  ## owner calls `lifetime.finish` the callback untracks automatically -- no
  ## manual `zid` bookkeeping.
  result = self.track(callback)
  self.bind_lifetime(lifetime, result)

proc untrack_on_destroy*(self: ref EdBase, zid: EID) =
  self.bound_eids.add(zid)

proc find_bare_return(n: NimNode): NimNode =
  if n.kind == nnk_return_stmt:
    return n
  if n.kind in {nnk_proc_def, nnk_func_def, nnk_lambda, nnk_do}:
    return nil
  for child in n:
    let found = find_bare_return(child)
    if found != nil:
      return found

macro check_no_return*(body: untyped): untyped =
  ## Passthrough macro: emits a compile error if body contains a bare return.
  ## Use inside changes bodies -- return exits the callback proc, not the
  ## enclosing proc, and skips remaining changes in the seq.
  let ret = find_bare_return(body)
  if ret != nil:
    error(
      "return is not valid inside a changes body; " &
        "use if/else instead of early return",
      ret,
    )
  result = body

macro warn_self_capture(watched: untyped, body: untyped): untyped =
  ## Bare-identifier self-capture detection for the `changes`/`watch` sugar:
  ## a callback body that references the watched *variable* captures it,
  ## pinning the object until untracked (closure cycles are not collected).
  ## Deliberately narrow -- only a bare identifier, only outside dot-RHS
  ## positions -- so it stays near-zero false positives (enu fires none).
  result = new_empty_node()
  if watched.kind in {nnk_ident, nnk_sym}:
    let name = watched.str_val
    proc references(n: NimNode): bool =
      if n.kind in {nnk_ident, nnk_sym} and eq_ident(n, name):
        return true
      for i in 0 ..< n.len:
        if n.kind == nnk_dot_expr and i == 1:
          continue # `x.foo` -- foo is a field, not a capture
        if references(n[i]):
          return true
    if references(body):
      warning(
        "callback closes over '" & name &
          "', pinning it until untracked -- use `it` (the injected live " &
          "proxy) or bind a Lifetime",
        watched,
      )

template changes*[T, O](self: Ed[T, O], pause_me, body) =
  warn_self_capture(self, body)
  make_discardable block:
    {.line.}:
      track self, proc(
          changes: seq[Change[O]], zid {.inject.}: EID, it {.inject.}: Ed[T, O]
      ) {.gcsafe.} =
        # `it` is the live proxy, delivered as a parameter -- referencing it
        # captures nothing, so sugar watchers never pin their object.
        let pause_zid = if pause_me: zid else: 0
        it.pause(pause_zid):
          for change {.inject.} in changes:
            template added(): bool =
              ADDED in change.changes

            template added(obj: O): bool =
              change.item == obj and added()

            template removed(): bool =
              REMOVED in change.changes

            template removed(obj: O): bool =
              change.item == obj and removed()

            template modified(): bool =
              MODIFIED in change.changes

            template modified(obj: O): bool =
              change.item == obj and modified()

            template touched(): bool =
              TOUCHED in change.changes

            template touched(obj: O): bool =
              change.item == obj and touched()

            template closed(): bool =
              CLOSED in change.changes

            {.line.}:
              check_no_return(body)

template changes*[T, O](self: Ed[T, O], body) =
  changes(self, true, body)
