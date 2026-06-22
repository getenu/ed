import std/[tables, macros]
import logging, timing

var saved_stats {.threadvar.}: Table[string, (int, Duration)]
var next_dump = Monotime.low

proc maybe_dump_stats*() =
  if now() > next_dump:
    for proc_name, r in saved_stats:
      info "STATS", proc_name, calls = r[0], time = r[1]
    next_dump = now() + 5.seconds

proc stats_impl(enabled: bool, proc_def: NimNode): NimNode =
  proc_def.expect_kind(nnk_proc_def)

  let proc_name = proc_def[0].to_str_lit

  var body = proc_def.body
  if enabled:
    body = quote:
      const proc_name = `proc_name`
      # get_mono_time, not now(): the quoted code resolves at the expansion
      # site, where std/times' DateTime now() may also be in scope.
      var start_time = get_mono_time()

      proc sample_stats(name: string) =
        let finish_time = get_mono_time()
        let duration = finish_time - start_time
        if name in saved_stats:
          saved_stats[name][0] += 1
          saved_stats[name][1] += duration
        else:
          saved_stats[name] = (1, duration)

        start_time = finish_time

      template sample(name = "") =
        const line = instantiation_info().line
        var full_name = proc_name & ":" & $line
        if name != "":
          full_name &= " [" & name & "]"
        sample_stats(full_name)

      `body`
      sample("done")
  else:
    body = quote:
      template sample(name = "") =
        discard

      `body`

  proc_def.body = body
  return proc_def

macro stats*(proc_def: untyped): untyped =
  stats_impl(true, proc_def)

macro stats*(enabled: untyped, proc_def: untyped): untyped =
  stats_impl(enabled.bool_val, proc_def)
