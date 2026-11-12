import std/[tables, intsets, locks]

import pkg/metrics
export inc, set

import ed/types {.all.}

var active_ctx* {.threadvar.}: EdContext

var local_type_registry* {.threadvar.}: Table[int, RegisteredType]
var processed_types* {.threadvar.}: IntSet
var raw_type_registry: Table[int, RegisteredType]
var global_type_registry* = addr raw_type_registry
var raw_type_name_registry: Table[int, string]
var global_type_name_registry* = addr raw_type_name_registry
var raw_layout_registry: Table[int, tuple[layout: int, name: string]]
var global_layout_registry* = addr raw_layout_registry
  ## Type id -> wire layout hash (see utils/layouts), for every registered type
  ## and every container type this build can materialize. Sent in SUBSCRIBE so
  ## the authority can refuse a peer that disagrees about a shared type.
var type_registry_lock*: Lock
type_registry_lock.init_lock

template with_lock*(body: untyped) =
  {.gcsafe.}:
    locks.with_lock(type_registry_lock):
      body

declare_public_gauge pressure_gauge,
  "Thread channel pressure", name = "zen_pressure", labels = ["ctx_label"]

declare_public_gauge object_pool_gauge,
  "Object pool size", name = "zen_object_pool", labels = ["ctx_label"]

declare_public_gauge ref_pool_gauge,
  "Ref pool size", name = "zen_ref_pool", labels = ["ctx_label"]

declare_public_gauge chan_remaining_gauge,
  "Free channel slots", name = "zen_chan_remaining", labels = ["ctx_label"]

declare_public_gauge buffer_gauge,
  "Buffer size", name = "zen_channel_buffer", labels = ["ctx_label"]

declare_public_counter sent_message_counter,
  "Messages sent", name = "zen_sent_messages", labels = ["ctx_label"]

declare_public_counter received_message_counter,
  "Messages received", name = "zen_received_messages", labels = ["ctx_label"]

declare_public_counter dropped_message_counter,
  "Messages dropped", name = "zen_dropped_messages", labels = ["ctx_label"]

declare_public_counter ticks_counter,
  "Ticks", name = "zen_ticks", labels = ["ctx_label"]
