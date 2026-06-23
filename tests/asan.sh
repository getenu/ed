#!/usr/bin/env bash
# Build + run the Ed test suite under AddressSanitizer -- the validation gate for
# the lifecycle memory work (`{.cursor.}` back-refs, ref_pool -> ORC + =destroy).
# Apple Silicon runs ASan natively (no VM needed).
#
# Catches: use-after-free, heap-buffer-overflow, double-free, stack-use-after-
# scope. Does NOT catch leaks (macOS has no LeakSanitizer) -- see the leak note
# at the bottom for the Linux path.
#
# Flags:
#   -d:useMalloc       ORC allocates via malloc so ASan tracks Ed's heap.
#   -d:ed_no_compress  Skip supersnappy -- its snappy fast-path over-reads within
#                      an allocation, which trips ASan (benign third-party, not our
#                      bug). In-process sync uses one build, so the wire format
#                      stays consistent across both sides.
#
# Baseline (lifecycle-80 branch): CLEAN -- 0 ASan errors, all tests pass. After a
# memory change, any NEW ASan error is a real regression to fix before landing.
set -euo pipefail
cd "$(dirname "$0")"

nim c --mm:orc -d:useMalloc -d:ed_no_compress \
  --passC:"-fsanitize=address -fno-omit-frame-pointer -g" \
  --passL:"-fsanitize=address" \
  --hints:off -o:tests_asan tests.nim

ASAN_OPTIONS=detect_leaks=0:abort_on_error=1 timeout -s9 300 ./tests_asan

# --- Leak checking (no LeakSanitizer on macOS) ---------------------------------
# Run the same build on Linux (Docker/VM) and flip detect_leaks on:
#     ASAN_OPTIONS=detect_leaks=1 ./tests_asan
# or Valgrind on Linux:
#     valgrind --leak-check=full --error-exitcode=1 ./tests
# Leak checks matter most for the ref_pool -> ORC step (does freeing actually
# happen); UAF (the cursor hazard) is fully covered by macOS ASan above.
