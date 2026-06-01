import std/net

proc free_port*(): int =
  ## Ask the OS for a free UDP port on loopback, then release it so the caller
  ## can bind it. Avoids hard-coded ports (e.g. 9632) colliding with a running
  ## Enu instance or with other tests.
  let s = newSocket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
  try:
    s.bindAddr(Port(0), "127.0.0.1")
    result = s.getLocalAddr()[1].int
  finally:
    s.close()

proc free_addr*(): string =
  ## "127.0.0.1:<free-port>", for use as both listen_address and subscribe target.
  "127.0.0.1:" & $free_port()
