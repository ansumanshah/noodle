#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016,SC2086
# E2E checks: boot console capture. Sourced by tests/e2e.sh; do not run directly.

# Developer console capture uses explicit opt-in and reads only a bounded tail.
t_debug_boot_console() {
  local cli=${NOODLE_CLI:-$ROOT/.build/release/noodle}
  [ -x "$cli" ] || skip "noodle CLI not found (set NOODLE_CLI)"
  local dh="$WORK/debug-console-home"
  mkdir -p "$dh"
  env NOODLE_HOME="$dh" "$cli" debug boot-console >"$dh/out" 2>"$dh/err"
  [ -f "$dh/vm.log.enabled" ]
  [ ! -f "$dh/vm.log" ]
  printf 'noodle-init: ready\n' >"$dh/vm.log"
  eq "$(env NOODLE_HOME="$dh" "$cli" debug boot-console)" 'noodle-init: ready'
  env NOODLE_HOME="$dh" "$cli" debug boot-console --disable >/dev/null
  [ ! -f "$dh/vm.log.enabled" ]
  fails env NOODLE_HOME="$dh" "$cli" debug boot-console --bogus
  rm -rf "$dh"
}

# The first boot stays silent by default; the next captures real guest boot output.
t_debug_boot_console_capture_opt_in_and_ring() {
  export NOODLE_BOOT_CONSOLE=0
  imp_up
  DOCKER_HOST=unix://$IMP_SOCK timeout -k 5 120 "$DOCKER" run --rm "$IMG" true
  [ ! -e "$IMP_HOME/vm.log" ]
  imp_down
  set -e # imp_down relaxes errexit for cleanup; assertions below must still fail the check.
  export NOODLE_BOOT_CONSOLE=1
  imp_up
  # Seed more than the ring capacity before boot; the next boot must bound it.
  python3 - "$IMP_HOME/vm.log" <<'PYCONSOLE'
import sys
with open(sys.argv[1], 'wb') as f:
    f.write(b'x' * 300000)
PYCONSOLE
  DOCKER_HOST=unix://$IMP_SOCK timeout -k 5 120 "$DOCKER" run --rm "$IMG" true
  # The file is cut to 256 KiB at open and may grow to twice that before the next cut.
  [ "$(stat -f %z "$IMP_HOME/vm.log")" -lt 300000 ]
  has "$(cat "$IMP_HOME/vm.log")" 'noodle-init: ready'
  imp_down
}
