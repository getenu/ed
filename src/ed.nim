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

import ed/[types, zens, components, utils]
export types, zens, components, utils

import ed/client
export client
