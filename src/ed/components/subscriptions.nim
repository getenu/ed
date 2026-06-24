## Cross-context and network synchronization. The implementation is split into
## parts under `subscriptions/` (layered wire -> publish -> {eviction, paging} ->
## core, with watch independent); this file is the facade that wires them
## together and re-exports the public API. Import `ed/components/subscriptions`.

import ./subscriptions/[wire, publish, eviction, paging, watch, core]
export wire, publish, eviction, paging, watch, core
