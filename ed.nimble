version = "0.30.4"
author = "Scott Wadden"
description = "Nothing for now"
license = "MIT"
srcDir = "src" # atlas doesn't like src_dir

requires(
  "https://github.com/treeform/pretty >= 0.2.0", "threading", "chronicles",
  "https://github.com/getenu/flatty >= 0.4.1", "netty", "supersnappy",
  "https://github.com/getenu/nanoid.nim >= 0.2.1", "metrics#a1296ca",
)
