import std/[locks, intsets, macros, typetraits, strutils]
import std/macrocache except value
import ed/core
import ed/[types {.all.}, zens/contexts, zens/private]
import ./private/global_state

template deref*(o: ref): untyped =
  o[]

template deref*(o: not ref): untyped =
  o

const created_procs = CacheSeq"created_procs"

proc lookup_type*(key: int, registered_type: var RegisteredType): bool =
  if key in local_type_registry:
    registered_type = local_type_registry[key]
    result = true
  elif key in processed_types:
    # we don't want to lookup a type in the global registry if we've already
    # tried, since it needs a lock
    result = false
  else:
    processed_types.incl(key)
    with_lock:
      if key in global_type_registry[]:
        registered_type = global_type_registry[][key]
        local_type_registry[key] = registered_type
        result = true

proc lookup_type*(obj: ref RootObj, registered_type: var RegisteredType): bool =
  result = lookup_type(obj.type_id, registered_type)

  if not result:
    debug "type not registered", type_name = obj.base_type

proc register_type(typ: type) =
  log_defaults
  let key = typ.type_id
  const type_name = $typ

  with_lock:
    assert key notin global_type_registry[], "Type already registered"
    global_type_name_registry[][key] = type_name

  let stringify =
    func (self: ref RootObj): string =
      let self = typ(self)
      var clone = new typ
      clone[] = self[]
      for src, dest in fields(self[], clone[]):
        when src is Ed:
          if ?src:
            # Proxy/body split: a bare `type(src)()` has no body, and `.id`
            # forwards there — mint a husk that carries one.
            dest = type(src).init_husk(src.id)
        elif src is ref:
          dest = nil
        elif src is ptr:
          dest = nil
        elif (src is proc):
          dest = nil
        elif src.has_custom_pragma(ed_ignore):
          dest = dest.type.default
      {.no_side_effect.}:
        result = flatty.to_flatty(clone[])

  let parse =
    func (ctx: EdContext, clone_from: string): ref RootObj =
      var self = typ()
      {.no_side_effect.}:
        self[] = from_flatty(clone_from, self[].type, ctx)
      for field in self[].fields:
        when field is Ed:
          if ?field and field.id in ctx:
            # Direct registry read — `ctx[...]` would blocking-materialize in a
            # `blocking` scope, which deserialization must never do (and a func
            # can't have side effects; resolve_proxy's registry upkeep is cast
            # away as the one tolerated effect).
            {.no_side_effect.}:
              field = type(field)(ctx.resolve_proxy(ctx.objects[field.id]))
      result = self

  let revive =
    func (existing: ref RootObj, incoming: ref RootObj) =
      # Converge a held instance to a freshly-parsed reincarnation without
      # replacing it. `incoming`'s Ed fields are already resolved/relinked by
      # `parse`; copy them and the synced scalars onto `existing`, but LEAVE
      # main-side refs / `ed_ignore` state untouched (the consumer depends on
      # them — e.g. a godot `node`). Mirrors `stringify`'s field handling.
      let src = typ(incoming)
      let dest = typ(existing)
      for s, d in fields(src[], dest[]):
        when s is Ed:
          # Re-link only fields that actually changed identity (a reload gives an
          # owned container a fresh id) or whose current target is stale. Leaving
          # an unchanged, still-valid field alone avoids downgrading it to an
          # incoming placeholder that hasn't materialized here yet.
          if ?s and (not ?d or d.id != s.id):
            d = s
        elif s is ref:
          discard # preserve the existing main-side reference (e.g. a node)
        elif s is ptr:
          discard
        elif (s is proc):
          discard
        elif s.has_custom_pragma(ed_ignore):
          discard # preserve existing local/never-synced state
        else:
          d = s # converge a synced scalar to the new incarnation's value

  with_lock:
    global_type_registry[][key] =
      RegisteredType(stringify: stringify, parse: parse, revive: revive, tid: key)

proc is_zen(node: NimNode): bool =
  if node.kind == nnk_sym and node.str_val == "EdBase":
    return true

  let info = node.get_type_impl

  if info.kind == nnk_ref_ty:
    return is_zen(info[0])
  elif info.kind == nnk_object_ty and info[1].kind == nnk_of_inherit:
    return is_zen(info[1][0])
  elif info.kind == nnk_bracket_expr and not node.eq_ident(info[0]):
    return is_zen(info[0])

proc export_routine(self: NimNode) =
  self[0] = new_nim_node(nnk_postfix).add(ident("*")).add(self[0])

proc get_value_type(self: NimNode): NimNode =
  if self.kind == nnk_sym:
    let def = self.get_impl
    if def.len >= 3 and def[2].kind == nnk_bracket_expr:
      if def[2][0].kind == nnk_sym and def[2][0].str_val == "EdValue":
        return def[2][1]
  elif self.kind == nnk_bracket_expr:
    if self[0].str_val.starts_with("Ed"):
      return self[1]

  error "get_value_type doesn't know how to handle type:\n\n" & self.tree_repr &
    "\n\nThis is probably a ed bug.", self

macro build_accessors(T: type, public: bool): untyped =
  result = new_stmt_list()
  var type_sym = T
  var base_type = T
  var names: seq[string]

  while type_sym.kind != nnk_empty and type_sym != bind_sym("RootObj") and
      type_sym != bind_sym("RootRef"):
    base_type = type_sym
    let type_impl = type_sym.get_impl

    for def in type_impl[2][0][2]:
      assert def.kind == nnk_ident_defs

      var def_count = def.len - 1
      if def[^1].kind == nnk_empty:
        dec def_count
      var field_defs = def[0 ..< def_count]
      var type_def = def[def_count]

      for ident in field_defs:
        var ident = ident
        if ident.kind == nnk_postfix:
          ident = ident[1]

        if ident.kind != nnk_ident:
          continue

        let name = ident.str_val
        if name.to_lower.ends_with("value") and is_zen(type_def):
          let getter_name =
            if name.ends_with("_value"):
              name[0 ..^ 7]
            else:
              name[0 ..^ 6]
          names.add getter_name

          let
            sym = ident(name)
            getter = ident(getter_name)
            setter = ident(getter_name & "=")
            id = ident(type_sym.repr & " " & name)
            value_type = get_value_type(type_def)

          var create_accessors = true

          for proc_id in created_procs:
            if proc_id.str_val == id.str_val:
              create_accessors = false
              break

          if create_accessors:
            created_procs.incl(id)

            var accessors = quote:
              proc `getter`(self: `type_sym`): `value_type` =
                value(self.`sym`)

              proc `setter`(self: `type_sym`, value: `value_type`) =
                self.`sym`.value = value

            if public.bool_val:
              accessors[0].export_routine
              accessors[1].export_routine
            result.add accessors

    type_sym =
      if type_impl[2][0][1].kind == nnk_of_inherit:
        type_impl[2][0][1][0]
      else:
        new_empty_node()

template build_accessors*(
    _: type Ed, T: type[ref object], public: bool = true
): untyped =
  build_accessors(T, public)

macro register*(_: type Ed, typ: type, public = true): untyped =
  result = new_stmt_list()
  result.add quote do:
    register_type(`typ`)
    Ed.build_accessors(`typ`, `public`)

proc ref_id*[T: ref RootObj](value: T): string {.inline.} =
  $value.type_id & ":" & $value.id

proc ref_count*[O](self: EdContext, changes: seq[Change[O]], ed_id: string) =
  privileged
  log_defaults

  for change in changes:
    if not ?change.item:
      continue
    # Only registered refs belong in `ref_pool`. It's the serialization identity
    # index (from_flatty dedup / find_ref), and now a *cursor* index, so an
    # instance in it must carry a `RefHandle` to clean itself out on free — i.e.
    # it must be an `EdRef`. Non-registered refs that happen to live in an Ed
    # container are never looked up and have no cleanup handle, so they must
    # never enter the pool (their cursor would dangle on free). Widen to the
    # common base first: `change.item`'s static type may be an unrelated ref
    # (a sibling of EdRef), which can't be converted to EdRef directly — but the
    # runtime `of` check + downcast through RootRef is always valid.
    let item = RootRef(change.item)
    if not (item of EdRef):
      continue
    let id = change.item.ref_id
    if ADDED in change.changes:
      if id notin self.ref_pool:
        debug "saving ref", id
        self.ref_pool[id] = CountedRef()
      self.ref_pool[id].references.incl(ed_id)
      self.ref_pool[id].obj = change.item
      # Wire the per-instance cleanup handle the first time we see this instance.
      # The pool's `obj` hold is non-owning (cursor); this handle is what keeps
      # it from dangling — when ORC reclaims the instance its RefHandle.=destroy
      # dels this exact context's `ref_pool` entry. The handle carries the
      # instance's own ctx, the one thing a bare registered ref can't know under
      # multiple contexts per thread.
      let handle_owner = EdRef(item)
      if handle_owner.ref_handle.is_nil:
        handle_owner.ref_handle = RefHandle(ctx_uid: self.uid, ref_id: id)
      # The instance's own context, for destroy's owner cascade — the one
      # context it lives in (see EdRef.ctx). Cursor, so no cycle.
      handle_owner.ctx = self
    if REMOVED in change.changes:
      # REMOVE only unlinks — it never frees. A body is freed by ORC when its
      # last real reference drops (RefHandle then cleans `ref_pool`), or later by
      # eviction; a container removal just updates the reachability hint. This is
      # what gives move-identity for free: a removed-then-readded replica re-links
      # the same instance for any gap, with no grace timer.
      if id in self.ref_pool:
        self.ref_pool[id].references.excl(ed_id)

    # Member ownership: an OWNS_MEMBERS collection's EdRef members belong to the
    # collection's *owner* — membership drives the `owned_by` index, and removal
    # un-registers, so an independently-removed member just drops out of the
    # cascade. Entries are ref_pool keys (tid:id); `destroy_owned` resolves them
    # there and cascades through the EdRef `destroy` method. Runs identically on
    # every context that applies the ADD/REMOVE, so the index needs no extra sync.
    let container = self.objects.getOrDefault(ed_id)
    if not container.is_nil and OWNS_MEMBERS in container.flags:
      # An ownerless flagged collection (the root units list) indexes members
      # under its own id instead: nothing cascades into them, but the closure
      # push / deep fetch can still find them.
      let owner =
        if container.owner_id.len > 0:
          container.owner_id
        else:
          ed_id
      if ADDED in change.changes:
        self.owned_by.mgetOrPut(owner, initHashSet[string]()).incl(id)
      if REMOVED in change.changes and owner in self.owned_by:
        self.owned_by[owner].excl(id)

proc find_ref*[T](self: EdContext, value: var T): bool =
  privileged

  # Drop entries for instances ORC already reclaimed before reading `obj` — the
  # cursor would otherwise dangle (see prune_dead_refs / RefHandle).
  self.prune_dead_refs()
  if ?value:
    let id = value.ref_id
    if id in self.ref_pool:
      let existing = self.ref_pool[id].obj
      if existing.is_nil:
        discard
      elif not (existing of EdRef):
        value = T(existing)
        result = true
      else:
        # Dedup to the pooled instance, but REVIVE it: converge the freshly-parsed
        # incarnation (`value`) onto it — re-linking owned fields a reload gave
        # fresh ids — and clear any destroyed latch. This merges a same-id
        # destroy+recreate into an in-place update: identity is preserved, so a
        # consumer still holding the instance converges to the new state instead
        # of being left on dead fields. (Replaces the old "refuse a destroyed
        # instance and mint fresh", which dangled held references.)
        var registered_type: RegisteredType
        if lookup_type(existing, registered_type) and
            registered_type.revive != nil:
          registered_type.revive(existing, value)
        if EdRef(existing).destroyed:
          EdRef(existing).destroyed = false
        value = T(existing)
        result = true

when defined(dump_ed_objects):
  import std/[os, algorithm]

proc can_free*(
    self: EdContext, value: ref RootObj, id: string
): tuple[freeable: bool, references: seq[string], missing: bool] =
  privileged

  # "Freeable" now means: registered, and no container still holds it. (The old
  # model gated on a 10s timer in `freeable_refs`; that grace is gone — see
  # docs/step4-body-protocol-sketch.md.) Deregistering only drops the cursor
  # index entry; ORC owns the memory and reclaims when the last holder releases.
  if id notin self.ref_pool:
    result.missing = true
  elif self.ref_pool[id].references.card == 0:
    result.freeable = true
  else:
    result.references = self.ref_pool[id].references.to_seq

proc free_impl(self: EdContext, value: ref RootObj, id: string) =
  privileged

  debug "freeing ref", id
  let query = self.can_free(value, id)
  if not query.freeable:
    let references = query.references.join(", ")
    when defined(zen_lax_free):
      error "Free error", id, references = query.references
      self.ref_pool.del(id)
      return

    if not query.missing:
      fail \"ref `{id}` has {query.references.len} references from " &
        \"{references}. Can't free."
    else:
      fail \"unable to find ref_id `{id}` in ref_pool. Double free?"

  # Deregister the index entry. Memory is ORC-owned, so this doesn't free the
  # instance — it just forgets it. If the instance is still alive (e.g. an app
  # handle held it), its later RefHandle.=destroy will `del` again, which is a
  # harmless no-op on an absent key.
  self.ref_pool.del(id)

proc free*[T: ref RootObj](self: EdContext, value: T) =
  self.free_impl(value, value.ref_id)

proc queue_free*[T: ref RootObj](self: EdContext, value: T) =
  let id = value.ref_id
  let query = self.can_free(value, id)
  if query.freeable:
    # if it's missing we can't free it, but we try anyway so we don't have to 
    # reproduce the error logic here
    self.free(value)
  elif not query.missing:
    self.free_queue.add(id)

proc free_refs*(self: EdContext) =
  privileged

  when defined(dump_ed_objects):
    let now = get_mono_time()
    if now > self.dump_at:
      self.pack_objects
      write_file(self.id, self.objects.keys.to_seq.reversed.join("\n"))
      var counts = ""
      for kind in MessageKind:
        counts &= $kind & ": " & $self.counts[kind] & "\n"
      write_file(self.id & "-counts", counts)
      self.dump_at = now + init_duration(seconds = 10)

  # Prune entries for instances ORC reclaimed since the last tick (RefHandle
  # can't touch ref_pool itself — see prune_dead_refs).
  self.prune_dead_refs()

  # Drain any explicitly queued frees. The old 10s-grace sweep over
  # `freeable_refs` is gone: an unreferenced ref is no longer time-freed here —
  # ORC reclaims it when its last holder drops, and RefHandle.=destroy records
  # the index entry for pruning. (`free_queue` survives for the explicit
  # `queue_free` path, which enu is retiring; once retired this loop is empty.)
  let queue = self.free_queue
  self.free_queue.set_len(0)
  for id in queue:
    if id in self.ref_pool:
      self.free_impl(self.ref_pool[id].obj, id)

when is_main_module:
  import ./subscriptions
  type Unit = ref object of RootObj
    id*: string
    name*: string

  Ed.register(Unit)
