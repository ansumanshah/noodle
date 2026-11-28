#!/usr/bin/env bash
# Memory budget report. Runs an isolated noodled and prints `footprint` numbers:
#   1. noodled idle (VM never started)               budget <= 15 MB
#   2. noodled after the VM has booted and gone to sleep
#   3. the Virtualization helper process(es) the VM lives in (guest RAM shows up here)
#   4. Noodle.app                                    budget <= 20 MB (window closed)
# Numbers are phys_footprint, the same figure Activity Monitor shows as "Memory".
#
# Environment:
#   NOODLED             daemon binary (default .build/release/noodled, then the app bundle)
#   NOODLE_RESOURCES    default build/resources
#   NOODLE_APP          explicitly opt into measuring a menu-bar-only app bundle (default none)
#   MEMORY_IDLE_WAIT    seconds to let noodled settle before measuring (default 5)
#   MEMORY_SLEEP_WAIT   max seconds to wait for the VM to go to sleep (default 120)
#   MEMORY_IMAGE        image used to wake the VM (default alpine:3.22)
#   MEMORY_ENFORCE=1    exit 1 when a budget is exceeded
#
# An opted-in app runs with --menubar-only; this script never opens its main window.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
IMG=${MEMORY_IMAGE:-alpine:3.22}
IDLE_WAIT=${MEMORY_IDLE_WAIT:-5}
SLEEP_WAIT=${MEMORY_SLEEP_WAIT:-120}
APP_WAIT=${MEMORY_APP_WAIT:-8}
APP=${NOODLE_APP:-none}
BUDGET_DAEMON=$((15 * 1048576))
BUDGET_APP=$((20 * 1048576))

if [ -x "$ROOT/build/tools/docker" ]; then DOCKER=$ROOT/build/tools/docker; else DOCKER=$(command -v docker || true); fi
command -v footprint >/dev/null || { echo "memory: footprint(1) not found" >&2; exit 2; }

NOODLE_HOME=$(mktemp -d /tmp/noodle-mem.XXXXXX)
export NOODLE_HOME
export NOODLE_RESOURCES=${NOODLE_RESOURCES:-$ROOT/build/resources}
SOCK=$NOODLE_HOME/run/docker.sock
export DOCKER_HOST=unix://$SOCK
DOCKER_CONFIG=$(mktemp -d "${TMPDIR:-/tmp}/noodle-mem-cfg.XXXXXX")
export DOCKER_CONFIG

NOODLED=${NOODLED:-}
if [ -z "$NOODLED" ]; then
  for c in "$ROOT/.build/release/noodled" "$ROOT/build/Noodle.app/Contents/MacOS/noodled"; do
    [ -x "$c" ] && NOODLED=$c && break
  done
fi
[ -n "$NOODLED" ] && [ -x "$NOODLED" ] || { echo "memory: noodled not built (just daemon)" >&2; exit 2; }

DPID=""
APID=""
# shellcheck disable=SC2329  # invoked via trap
cleanup() {
  trap - EXIT INT TERM
  [ -n "$APID" ] && kill -TERM "$APID" 2>/dev/null
  if [ -n "$DPID" ]; then
    kill -TERM "$DPID" 2>/dev/null
    for _ in $(seq 1 20); do kill -0 "$DPID" 2>/dev/null || break; sleep 0.5; done
    kill -KILL "$DPID" 2>/dev/null
  fi
  rm -rf "$NOODLE_HOME" "$DOCKER_CONFIG"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

parse_footprint() {
  awk '/phys_footprint:/{n=$2; u=$3; scale=(u=="GB"?1073741824:u=="MB"?1048576:u=="KB"?1024:u=="B"?1:0); if(scale) printf "%.0f\n", n*scale; exit}'
}
fp_bytes() { footprint "$1" 2>/dev/null | parse_footprint; }
mb() { [ -n "${1:-}" ] || { printf 'unavailable'; return; }; awk -v b="$1" 'BEGIN{printf "%7.1f MB", b/1048576}'; }
vm_pids() { pgrep -f 'com.apple.Virtualization.VirtualMachine' 2>/dev/null | sort -n; }
row() { # label bytes budget(optional)
  local verdict=""
  if [ -z "${2:-}" ]; then verdict="not measured"; OVER=1; fi
  if [ -n "${3:-}" ] && [ -n "${2:-}" ]; then
    if [ "$2" -le "$3" ]; then verdict="ok   (budget $(mb "$3" | tr -d ' '))"; else verdict="OVER (budget $(mb "$3" | tr -d ' '))"; OVER=1; fi
  fi
  printf '%-44s %s  %s\n' "$1" "$(mb "$2")" "$verdict"
}
OVER=0

if [ "${1:-}" = --self-test ]; then
  [ "$(printf 'phys_footprint: 2 MB\n' | parse_footprint)" = 2097152 ] || exit 1
  [ "$(printf 'phys_footprint: 3232 KB\n' | parse_footprint)" = 3309568 ] || exit 1
  [ "$(printf 'phys_footprint: 1.5 GB\n' | parse_footprint)" = 1610612736 ] || exit 1
  [ "$(printf 'phys_footprint: 4096 B\n' | parse_footprint)" = 4096 ] || exit 1
  [ "$(printf 'measurement failed\n' | parse_footprint)" = "" ] || exit 1
  exit 0
fi

before_vms=$(vm_pids)
"$NOODLED" >"$NOODLE_HOME/noodled.log" 2>&1 &
DPID=$!
for _ in $(seq 1 60); do
  [ -S "$SOCK" ] && curl -sf --max-time 2 --unix-socket "$SOCK" http://localhost/_ping >/dev/null 2>&1 && break
  kill -0 "$DPID" 2>/dev/null || { echo "memory: noodled exited early:"; tail -n 10 "$NOODLE_HOME/noodled.log"; exit 1; }
  sleep 0.5
done
curl -sf --max-time 2 --unix-socket "$SOCK" http://localhost/_ping >/dev/null 2>&1 || { echo "memory: daemon never answered _ping"; exit 1; }

echo "noodled pid $DPID  ($NOODLED)"
sleep "$IDLE_WAIT"
row "noodled idle, VM not started" "$(fp_bytes "$DPID")" "$BUDGET_DAEMON"

if [ -z "$DOCKER" ]; then
  echo "memory: no docker CLI, skipping VM phases (scripts/fetch-tools.sh)"
elif ! "$DOCKER" run --rm "$IMG" true >/dev/null 2>&1; then
  echo "memory: could not run a container; skipping VM phases"
else
  new_vms=$(comm -13 <(echo "$before_vms") <(vm_pids))
  row "noodled, VM awake (just ran a container)" "$(fp_bytes "$DPID")"
  for p in $new_vms; do row "  VM helper pid $p, awake" "$(fp_bytes "$p")"; done

  echo "waiting up to ${SLEEP_WAIT}s for the VM to sleep..."
  t=0
  while [ "$t" -lt "$SLEEP_WAIT" ]; do
    alive=""
    for p in $new_vms; do kill -0 "$p" 2>/dev/null && alive="$alive $p"; done
    [ -z "$alive" ] && break
    sleep 2; t=$((t + 2))
  done
  if [ -z "$new_vms" ]; then
    echo "note: no new com.apple.Virtualization.VirtualMachine process seen (VM may run in-process)"
    row "noodled, VM sleeping (after ${t}s)" "$(fp_bytes "$DPID")"
  elif [ -z "${alive:-}" ]; then
    echo "VM helper exited after ~${t}s"
    row "noodled, VM sleeping (after ${t}s)" "$(fp_bytes "$DPID")"
  else
    echo "VM helper still running after ${SLEEP_WAIT}s; guest RAM is still resident"
    row "noodled, VM still resident" "$(fp_bytes "$DPID")"
    for p in $alive; do row "  VM helper pid $p, still resident" "$(fp_bytes "$p")"; done
  fi
fi

if [ "$APP" != none ] && [ -d "$APP" ]; then
  "$APP/Contents/MacOS/Noodle" --menubar-only >/dev/null 2>&1 &
  APID=$!
  sleep "$APP_WAIT"
  if kill -0 "$APID" 2>/dev/null; then row "Noodle.app (menu bar only)" "$(fp_bytes "$APID")" "$BUDGET_APP"
  else echo "memory: app did not start"; fi
else
  echo "memory: no app bundle at $APP (just app); skipping app"
fi

[ "${MEMORY_ENFORCE:-0}" = 1 ] && [ "$OVER" = 1 ] && exit 1
exit 0
