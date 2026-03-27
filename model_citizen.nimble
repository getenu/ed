version = "0.20.1"
author = "Scott Wadden"
description = "Nothing for now"
license = "MIT"
srcDir = "src" # atlas doesn't like src_dir

requires(
  "https://github.com/treeform/pretty >= 0.2.0", "threading", "chronicles",
  "flatty", "netty", "supersnappy",
  "https://github.com/getenu/nanoid.nim >= 0.2.1", "metrics#51f1227",
)

include tasks
