## Partial-replica paging: serving and chaining per-key/whole-object wants
## (request routing upstream, want bookkeeping) and the app-facing `fetch`, plus
## the per-frame flush of batched key requests/releases. Builds on `wire`/`publish`.

import std/[importutils, tables, sets]
import pkg/flatty
import ed/[core, types {.all.}], ed/zens/[contexts, private]
import ed/components/private/global_state
import ed/lifecycle
import ./wire

privileged
proc serve_key_wants(self: EdContext, object_id: string) =
  ## Serve chained per-key wants that can now be answered -- entries for
  ## `object_id` may have just arrived (see forward_request).
  privileged
  if object_id notin self.pending_key_wants or object_id notin self:
    return
  let obj = self.objects[object_id]
  var done: seq[string]
  for key_bin, waiters in self.pending_key_wants[object_id]:
    let reply = obj.publish_key(obj, key_bin)
    if reply.found:
      for waiter in waiters:
        # Handle-first (see the REQUEST handler): the waiter may not hold the
        # container, and an ADD for an unknown object drops silently.
        if not obj.placeholder:
          obj.publish_create(waiter, contents = false)
        # Per-key deep: nested containers (a chunk's delta seq) go first so
        # the receiver's parse links them -- and they're followed, so their
        # future ops stream.
        for nested_id in reply.nested:
          if nested_id in self and not self.objects[nested_id].placeholder:
            waiter.interest.incl nested_id
            self.objects[nested_id].publish_create(waiter)
        self.send(waiter, reply.msg, OperationContext(), DEFAULT_FLAGS)
      done.add key_bin
  for key_bin in done:
    self.pending_key_wants[object_id].del key_bin
  if self.pending_key_wants[object_id].len == 0:
    self.pending_key_wants.del object_id

proc request_targets(self: EdContext): seq[Subscription] =
  ## Who to send a REQUEST to: our upstreams (the contexts we page from).
  ## Never downstream -- a clone's copy of us is stale-by-definition, and
  ## letting it answer can overwrite fresher local state with its echo. Only a
  ## non-authority forwards, and a non-authority pages from a recorded upstream,
  ## so this is non-empty in practice. An empty result means a degenerate
  ## topology (a non-authority with no upstream); rather than fall back to all
  ## subscribers -- which could route the request downstream -- treat it as a bug
  ## (assert in debug, log in release) and forward nowhere.
  for sub in self.subscribers:
    if sub.ctx_id in self.upstream_ctx_ids:
      result.add sub
  if result.len == 0:
    error "request_with_no_upstream", ctx = self.id
    assert false, "request_targets: forwarding with no recorded upstream"

proc forward_request(self: EdContext, requester: Subscription, msg: Message) =
  ## Chain a request we can't serve: send it to our upstream(s).
  ## The forward makes *us* the requester there, so the answer lands here and
  ## the want-serving hooks relay it back to the original asker. The authority
  ## never forwards (its miss is a real NOT_FOUND), which also terminates any
  ## forwarding cycle in a bidirectional pair.
  var fwd = msg
  fwd.source = @[]
  fwd.id_mappings = @[]
  for sub in self.request_targets:
    if sub.ctx_id == requester.ctx_id:
      continue
    self.send(sub, fwd, OperationContext(), DEFAULT_FLAGS)

proc add_obj_want(self: EdContext, requester: Subscription, msg: Message) =
  ## Remember + chain a whole-object want. Dedup: only the first want for an
  ## id forwards upstream; later askers just join the waiters.
  if msg.object_id in self.pending_obj_wants:
    for want in self.pending_obj_wants[msg.object_id]:
      if want.sub.ctx_id == requester.ctx_id:
        return
    self.pending_obj_wants[msg.object_id].add (requester, msg.deep)
  else:
    self.pending_obj_wants[msg.object_id] = @[(requester, msg.deep)]
    self.forward_request(requester, msg)

proc fetch*(
    self: EdContext, object_id: string, deep = false
): Fetch {.discardable.} =
  ## Ask the authority for `object_id`. Returns a handle that resolves on a
  ## later tick: `Found` (with `obj` linking the container) when it arrives, or
  ## `NotFound` if the authority NACKs. Already holding it loaded resolves
  ## immediately; fetching an id already in flight returns the same handle.
  ##
  ## Always registers interest, so future ops follow -- and a *missing* id is
  ## delivered whenever something creates it (the handle still resolves NotFound
  ## for "not there right now"). To stop following, drop your reference: with no
  ## live proxy the object becomes an eviction candidate and its interest is
  ## retracted upstream when it's reclaimed (see the evictor / `mem_limit`).
  ##
  ## `deep` also fetches everything the id *owns* (the synced-ownership closure,
  ## recursively) -- so an owner id (a unit, which isn't itself a container) pulls
  ## its whole owned state in one request. The already-loaded short-circuit is
  ## skipped for deep fetches: holding the root says nothing about the closure.
  if not deep and object_id in self and not self.objects[object_id].placeholder:
    return Fetch(
      id: object_id,
      state: Found,
      obj: self.resolve_proxy(self.objects[object_id]),
    )
  if object_id in self.fetches and self.fetches[object_id].state == Pending:
    return self.fetches[object_id]
  result = Fetch(id: object_id, state: Pending)
  self.fetches[object_id] = result
  var msg = Message(kind: REQUEST, object_id: object_id, deep: deep)
  for sub in self.request_targets:
    self.send(sub, msg, OperationContext(), DEFAULT_FLAGS)
  self.tick_reactor

proc flush_key_requests(self: EdContext) =
  ## Send the per-key fetches buffered since the last tick -- one REQUEST per
  ## table, carrying the batch of serialized keys in `obj`. The authority replies
  ## with an ADD op per found key (see the REQUEST handler).
  if self.pending_key_requests.len == 0:
    return
  let pending = self.pending_key_requests
  self.pending_key_requests.clear
  for object_id, keys in pending:
    let msg = Message(kind: REQUEST, object_id: object_id, obj: keys.to_flatty)
    for sub in self.request_targets:
      self.send(sub, msg, OperationContext(), DEFAULT_FLAGS)
  self.tick_reactor

proc flush_key_releases(self: EdContext) =
  ## Send the per-key releases buffered since the last tick -- one RELEASE per
  ## table, broadcast to every peer. Upstream reads it as an interest retract
  ## (ops for those keys stop flowing); downstream clones read it as an
  ## eviction notice and drop the keys too (see the RELEASE handler).
  if self.pending_key_releases.len == 0:
    return
  let pending = self.pending_key_releases
  self.pending_key_releases.clear
  for object_id, keys in pending:
    let msg = Message(kind: RELEASE, object_id: object_id, obj: keys.to_flatty)
    for sub in self.subscribers:
      self.send(sub, msg, OperationContext(), DEFAULT_FLAGS)
  self.tick_reactor

