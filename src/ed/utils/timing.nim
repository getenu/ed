## Monotonic time and durations, exported deliberately. std/times' `now()`
## is a calendar DateTime and its `seconds()`/`milliseconds()` return
## TimeInterval -- calendar types whose operators don't mix with Duration.
## Import this (or `ed`) instead of std/times when you mean elapsed time:
## `now()` is a monotonic instant, and the unit helpers below all return
## std Duration.
import std/monotimes
import std/times except seconds, milliseconds, minutes, now

export monotimes
export
  times.Duration, times.DurationZero, times.init_duration, times.in_seconds,
  times.in_milliseconds, times.`+`, times.`-`, times.`+=`, times.`-=`,
  times.`<`, times.`<=`, times.`==`, times.`$`

template now*(): MonoTime =
  get_mono_time()

proc seconds*(n: float | int): Duration {.inline.} =
  init_duration(milliseconds = int(n * 1000))

proc minutes*(n: float | int): Duration {.inline.} =
  init_duration(milliseconds = int(n * 60_000))

proc milliseconds*(n: int): Duration {.inline.} =
  init_duration(milliseconds = n)

template second*(n: float | int): Duration =
  n.seconds

template minute*(n: float | int): Duration =
  n.minutes

template millisecond*(n: int): Duration =
  n.milliseconds
