#!/usr/bin/env bash
# Host memory after a 400 MB write, one pass per run. Starts its own isolated noodled under the VM lock.
# Prints one JSON object per pass on stdout.
#
#   tests/reclaim-bench.sh [label]
#
# Procedure: pull, 20 warm runs, a long-lived load container, helper footprint (baseline), `dd` 400 MB through exec,
# then helper footprint at 10 s steps until RECLAIM_WATCH seconds. With RECLAIM_GUEST=1 each step also reads
# /proc/meminfo in the guest; those reads are activity and deflate the balloon, so use it for diagnosis only.
# Every wait is bounded. Needs a built noodled (just daemon tools).
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LABEL=${1:-run}
IMG=${MEMORY_IMAGE:-alpine:3.22}
WATCH=${RECLAIM_WATCH:-140}
GUEST=${RECLAIM_GUEST:-0}
DOCKER=$ROOT/build/tools/docker
NOODLED=${NOODLED:-$ROOT/.build/release/noodled}
LOCK=${NOODLE_VM_LOCK:-$(git -C "$ROOT" rev-parse --git-common-dir)/noodle-vm.lock}
case $LOCK in /*) ;; *) LOCK=$ROOT/$LOCK ;; esac
export NOODLE_NO_ACTIVATE=1
export NOODLE_MEMORY_MIB=${RECLAIM_MEM:-2048}   # the guest size of the recorded passes

fp() { footprint "$1" 2>/dev/null | awk '/phys_footprint:/{n=$2;u=$3;s=(u=="GB"?1024:u=="MB"?1:u=="KB"?1/1024:u=="B"?1/1048576:0);printf "%.1f\n", n*s; exit}'; }
vm_pids() { pgrep -f 'com.apple.Virtualization.VirtualMachine' 2>/dev/null | sort -n; }

# Lock: mkdir, owner file, release only if ours. Bounded wait of 20 minutes.
got=0
for _ in $(seq 1 240); do
  if mkdir "$LOCK" 2>/dev/null; then echo "reclaim-bench $LABEL $$" >"$LOCK/owner"; got=1; break; fi
  o=$(awk '{print $NF}' "$LOCK/owner" 2>/dev/null)
  if [ -n "$o" ] && ! kill -0 "$o" 2>/dev/null; then echo "stale lock owner $o (dead); not removing, waiting" >&2; fi
  sleep 5
done
[ "$got" = 1 ] || { echo "reclaim-bench: VM lock busy" >&2; exit 3; }

# Short path: unix socket paths are limited to 104 bytes. Removed on exit.
HOME_DIR=$(mktemp -d /tmp/nrb.XXXXXX)
export NOODLE_HOME=$HOME_DIR NOODLE_RESOURCES=$ROOT/build/resources
export DOCKER_HOST=unix://$HOME_DIR/run/docker.sock DOCKER_CONFIG=$HOME_DIR/cfg
mkdir -p "$DOCKER_CONFIG"
DPID=""
cleanup() {
  trap - EXIT INT TERM
  if [ -n "$DPID" ]; then
    kill -TERM "$DPID" 2>/dev/null
    for _ in $(seq 1 20); do kill -0 "$DPID" 2>/dev/null || break; sleep 0.5; done
    kill -KILL "$DPID" 2>/dev/null
  fi
  rm -rf "$HOME_DIR"
  if [ "$(awk '{print $NF}' "$LOCK/owner" 2>/dev/null)" = "$$" ]; then rm -rf "$LOCK"; fi
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
[ "$ok" = 1 ] || { echo "reclaim-bench: daemon did not answer" >&2; exit 1; }

timeout 300 "$DOCKER" pull -q "$IMG" >/dev/null 2>&1 || { echo "reclaim-bench: pull failed" >&2; exit 1; }
for _ in $(seq 1 20); do timeout 60 "$DOCKER" run --rm "$IMG" true >/dev/null 2>&1; done
timeout 60 "$DOCKER" run -d --name load "$IMG" sleep 3600 >/dev/null 2>&1 || { echo "reclaim-bench: load container" >&2; exit 1; }
sleep 3
HELPER=$(comm -13 <(echo "$before") <(vm_pids) | tail -1)
[ -n "$HELPER" ] || { echo "reclaim-bench: no VM helper" >&2; exit 1; }

meminfo() { timeout 20 "$DOCKER" exec load sh -c 'grep -E "^(MemTotal|MemFree|Cached|Dirty|Writeback|AnonPages):" /proc/meminfo | tr -s " " | tr "\n" ";"; grep -E "^balloon_(inflate|deflate)" /proc/vmstat | tr " \n" "=;"' 2>/dev/null; }

base=$(fp "$HELPER")
detail() { [ -n "${RECLAIM_DETAIL:-}" ] && { footprint "$HELPER" >"$RECLAIM_DETAIL.$1" 2>&1; vmmap -summary "$HELPER" >"$RECLAIM_DETAIL.$1.vmmap" 2>&1; }; return 0; }
detail base
dd_out=$(timeout 120 "$DOCKER" exec load sh -c 'dd if=/dev/zero of=/var/tmp/dd.bin bs=1M count=400 2>&1 | tail -1' 2>&1)
t0=$(date +%s)
rows=""
t=0
while [ "$t" -le "$WATCH" ]; do
  kill -0 "$HELPER" 2>/dev/null || { rows="$rows{\"t\":$t,\"helper_mb\":null,\"note\":\"helper gone\"},"; break; }
  v=$(fp "$HELPER")
  g=""
  [ "$GUEST" = 1 ] && g=$(meminfo)
  rows="$rows{\"t\":$t,\"helper_mb\":${v:-null},\"guest\":\"$g\"},"
  next=$((t + 10))
  while [ "$(( $(date +%s) - t0 ))" -lt "$next" ]; do sleep 1; done
  t=$next
done
detail end
printf '{"label":"%s","commit":"%s","guest_probe":%s,"baseline_mb":%s,"dd":"%s","samples":[%s]}\n' \
  "$LABEL" "$(git -C "$ROOT" rev-parse --short HEAD)" "$([ "$GUEST" = 1 ] && echo true || echo false)" "${base:-null}" "$dd_out" "${rows%,}"
