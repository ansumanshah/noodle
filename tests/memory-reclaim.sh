#!/usr/bin/env bash
# Host memory while the VM stays awake: a container allocates RECLAIM_ALLOC_MIB of anonymous memory, frees it, and the
# script samples the Virtualization helper's phys_footprint every 5 s. Prints one JSON object on stdout.
#
#   tests/memory-reclaim.sh [label]
#
# Starts its own noodled and NOODLE_HOME under the VM lock (same lock as tests/e2e.sh), removes both on exit.
# MemAvailable is read through `docker exec` only before the allocation and after the last sample, because API calls
# count as activity. RECLAIM_IDLE=1 runs each step in its own `docker run --rm` with no container left running (the
# idle path); otherwise a long-lived container does the work through `exec` (the busy path).
# Busy path: a process started before the reclaim later allocates RECLAIM_GROW_MIB (default RECLAIM_ALLOC_MIB) with no
# API call, so only the guest's deflate-on-OOM can feed it; `grow_exit` 0 and `oom_kills` 0 mean no OOM. `alloc_ms` and
# `grow_ms` time the first allocation (no balloon) and that one (balloon inflated) inside the guest, 10 ms resolution.
# Idle path: `run_ms` times three `docker run --rm true` through the CLI, the first while the balloon is inflated.
# Idle sleep is 300 s so it stays out of the watch; RECLAIM_IDLE_SLEEP=60 with RECLAIM_WATCH=90 shows when the VM sleeps.
# RECLAIM_MAX_MB makes the script exit 1 when the last sample is above it. Needs `just daemon tools`.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [ -z "${NOODLE_VM_LOCK_HELD:-}" ]; then
  exec /usr/bin/lockf -k "${NOODLE_VM_LOCK:-/tmp/noodle-vm.lock}" /usr/bin/env NOODLE_VM_LOCK_HELD=1 bash "$0" "$@"
fi
LABEL=${1:-run}
IMG=${MEMORY_IMAGE:-alpine:3.22}
ALLOC=${RECLAIM_ALLOC_MIB:-1024}
WATCH=${RECLAIM_WATCH:-60}
DOCKER=${DOCKER_BIN:-$ROOT/build/tools/docker}
NOODLED=${NOODLED:-$ROOT/.build/release/noodled}
export NOODLE_NO_ACTIVATE=1
export NOODLE_MEMORY_MIB=${RECLAIM_MEM:-2048}

fp() { footprint "$1" 2>/dev/null | awk '/phys_footprint:/{n=$2;u=$3;s=(u=="GB"?1024:u=="MB"?1:u=="KB"?1/1024:u=="B"?1/1048576:0);printf "%.0f\n", n*s; exit}'; }
vm_pids() { pgrep -f 'com.apple.Virtualization.VirtualMachine' 2>/dev/null | sort -n; }
IDLE=${RECLAIM_IDLE:-0}
in_guest() { if [ "$IDLE" = 1 ]; then timeout 120 "$DOCKER" run --rm "$IMG" "$@"; else timeout 120 "$DOCKER" exec load "$@"; fi; }
avail() { in_guest awk '/^MemAvailable:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null; }

HOME_DIR=$(mktemp -d /tmp/nmr.XXXXXX) # short: unix socket paths are limited to 104 bytes
export NOODLE_HOME=$HOME_DIR NOODLE_RESOURCES=${NOODLE_RESOURCES:-$ROOT/build/resources}
export DOCKER_HOST=unix://$HOME_DIR/run/docker.sock DOCKER_CONFIG=$HOME_DIR/cfg
mkdir -p "$DOCKER_CONFIG"
printf '{"idle_sleep_seconds":%s}' "${RECLAIM_IDLE_SLEEP:-300}" >"$HOME_DIR/vm.json"
DPID=""
cleanup() {
  trap - EXIT INT TERM
  if [ -n "$DPID" ]; then
    kill -TERM "$DPID" 2>/dev/null
    for _ in $(seq 1 20); do kill -0 "$DPID" 2>/dev/null || break; sleep 0.5; done
    kill -KILL "$DPID" 2>/dev/null
  fi
  rm -rf "$HOME_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

before=$(vm_pids)
"$NOODLED" >"$HOME_DIR/noodled.log" 2>&1 &
DPID=$!
ok=0
for _ in $(seq 1 60); do
  curl -sf --max-time 2 --unix-socket "$HOME_DIR/run/docker.sock" http://localhost/_ping >/dev/null 2>&1 && { ok=1; break; }
  kill -0 "$DPID" 2>/dev/null || break
  sleep 0.5
done
[ "$ok" = 1 ] || { echo "memory-reclaim: daemon did not answer" >&2; exit 1; }
timeout 300 "$DOCKER" pull -q "$IMG" >/dev/null 2>"$HOME_DIR/pull.err" || { echo "memory-reclaim: pull failed: $(tail -2 "$HOME_DIR/pull.err")" >&2; tail -5 "$HOME_DIR/noodled.log" >&2; exit 1; }
if [ "$IDLE" = 1 ]; then
  timeout 60 "$DOCKER" run --rm "$IMG" true >/dev/null 2>&1 || { echo "memory-reclaim: first run" >&2; exit 1; }
else
  timeout 60 "$DOCKER" run -d --name load "$IMG" sleep 3600 >/dev/null 2>&1 || { echo "memory-reclaim: load container" >&2; exit 1; }
fi
sleep 3
HELPER=$(comm -13 <(echo "$before") <(vm_pids) | tail -1)
[ -n "$HELPER" ] || { echo "memory-reclaim: no VM helper" >&2; exit 1; }

avail0=$(avail)
base=$(fp "$HELPER")
# busybox dd allocates a bs-sized buffer and fills it from /dev/zero, so this touches ALLOC MiB of anonymous memory.
# The guest command prints "<exit> <ms>": uptime has 10 ms resolution and busybox date has no %N.
timed_dd() {
  printf '%s' "u0=\$(cut -d' ' -f1 /proc/uptime); dd if=/dev/zero of=/dev/null bs=$1M count=1 2>/dev/null; r=\$?;" \
    " u1=\$(cut -d' ' -f1 /proc/uptime); echo \"\$r \$u0 \$u1\" | awk '{printf \"%d %d\", \$1, (\$3-\$2)*1000}'"
}
alloc=$(in_guest sh -c "$(timed_dd "$ALLOC")" 2>/dev/null)
alloc_ms=${alloc#* }; alloc_ms=${alloc_ms:-null}
peak=$(fp "$HELPER")
GROW=${RECLAIM_GROW_MIB:-$ALLOC}
[ "$IDLE" = 1 ] || timeout 20 "$DOCKER" exec -d load sh -c "sleep $((WATCH + 5)); $(timed_dd "$GROW") >/tmp/grow" >/dev/null 2>&1
t0=$(date +%s); t=0; rows=""; last=""
while [ "$t" -le "$WATCH" ]; do
  last=$(fp "$HELPER")
  rows="$rows{\"t\":$t,\"helper_mb\":${last:-null}},"
  t=$((t + 5))
  while [ "$(($(date +%s) - t0))" -lt "$t" ]; do sleep 1; done
done
grow=null grow_ms=null oom=null run_ms=null
if [ "$IDLE" = 1 ]; then
  ms() { perl -MTime::HiRes=time -e 'printf "%d", time*1000'; }
  run_ms=""
  for _ in 1 2 3; do s0=$(ms); timeout 60 "$DOCKER" run --rm "$IMG" true >/dev/null 2>&1; run_ms="$run_ms$(($(ms) - s0)),"; done
  run_ms="[${run_ms%,}]"
else
  while [ "$(($(date +%s) - t0))" -lt $((WATCH + 20)) ]; do sleep 1; done
  g=$(timeout 20 "$DOCKER" exec load cat /tmp/grow 2>/dev/null)
  grow='"missing"' # killed before it wrote a result
  [ -n "$g" ] && { grow=${g% *}; grow_ms=${g#* }; }
  oom=$(timeout 20 "$DOCKER" exec load awk '/^oom_kill /{print $2}' /proc/vmstat 2>/dev/null); oom=${oom:-null}
fi
avail1=$(avail)
printf '{"label":"%s","idle":%s,"commit":"%s","guest_mib":%s,"alloc_mib":%s,"baseline_mb":%s,"after_alloc_mb":%s,"mem_available_before_mib":%s,"mem_available_after_mib":%s,"alloc_ms":%s,"grow_exit":%s,"grow_ms":%s,"oom_kills":%s,"run_ms":%s,"samples":[%s]}\n' \
  "$LABEL" "$IDLE" "$(git -C "$ROOT" rev-parse --short HEAD)" "$NOODLE_MEMORY_MIB" "$ALLOC" "${base:-null}" "${peak:-null}" "${avail0:-null}" "${avail1:-null}" "$alloc_ms" "$grow" "$grow_ms" "$oom" "$run_ms" "${rows%,}"
[ "$grow" = null ] || [ "$grow" = 0 ] || { echo "memory-reclaim: growth after reclaim failed ($grow)" >&2; exit 1; }
[ -z "${RECLAIM_MAX_MB:-}" ] || [ "${last:-999999}" -le "$RECLAIM_MAX_MB" ] || { echo "memory-reclaim: ${last} MB > ${RECLAIM_MAX_MB} MB" >&2; exit 1; }
