import std/strutils

# CRC-32 (IEEE 802.3). Store integrity checks need a checksum that is stable
# across Nim versions and builds -- std/hashes guarantees neither. The threat
# model is torn/corrupted writes, not tampering.

const crc32_table = block:
  var table: array[256, uint32]
  for i in 0 ..< 256:
    var c = uint32(i)
    for _ in 0 ..< 8:
      c =
        if (c and 1) != 0:
          0xedb88320'u32 xor (c shr 1)
        else:
          c shr 1
    table[i] = c
  table

proc crc32*(s: open_array[char]): uint32 =
  result = 0xffffffff'u32
  for ch in s:
    result = crc32_table[(result xor uint32(ch)) and 0xff] xor (result shr 8)
  result = not result

proc crc32_hex*(s: open_array[char]): string =
  crc32(s).to_hex(8).to_lower_ascii
