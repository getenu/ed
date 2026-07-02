version = "0.30.4"
author = "Scott Wadden"
description = "Nothing for now"
license = "MIT"
srcDir = "src" # atlas doesn't like src_dir

requires(
  "pretty", "threading", "chronicles",
  "flatty >= 0.4.1", "netty", "supersnappy",
  "nanoid >= 0.2.1", "metrics#a1296ca",
)
