## `Ed` - Reactive Data Framework for Enu
##
## `Ed` provides thread-safe, network-synchronized reactive data containers.
##
## **Warning:** Data consistency is eventual, not guaranteed. Do not use for
## critical data. Full consistency support planned for future versions.
##
## Basic usage:
## ```nim
## import ed
##
## Ed.bootstrap
## let name = ed("Enu")
## name.track proc(changes: auto) =
##   for change in changes:
##     echo "Changed: ", change.item
## name.value = "World"
## ```

import std/[monotimes]
export monotimes

import pkg/[threading/channels, flatty]
export channels, flatty

import ed/[types, zens, components, utils, lifecycle]
# The core container type and its helpers stay internal: apps name containers
# as `Ed[T]`.
export types except EdContainer, ed_core, as_ed
export zens, components, utils, lifecycle

import ed/client
export client

import ed/objects
export objects
