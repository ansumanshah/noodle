#!/usr/bin/env bash
# Hard-kill recovery acceptance: SIGKILL noodled while the VM runs, restart immediately,
# and require the next real `docker` CLI use to succeed with the data intact.
#
#   tests/recovery.sh [cycles]      default 3 kill/restart cycles
#
# Evidence (daemon logs per cycle, VM console log, timings) is kept under
# build/recovery/<timestamp>/ and never deleted. Isolation: fresh NOODLE_HOME under /tmp,
# throwaway DOCKER_CONFIG; ~/.noodle and ~/.docker are never touched.
# Env: NOODLED, NOODLE_RESOURCES, DOCKER_BIN, E2E_IMAGE (as in tests/e2e.sh).
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CYCLES=${1:-3}
IMG=${E2E_IMAGE:-alpine:3.22}
DOCKER=${DOCKER_BIN:-$ROOT/build/tools/docker}
NOODLED=${NOODLED:-}
if [ -z "$NOODLED" ]; then
  for c in "$ROOT/.build/release/noodled" "$ROOT/build/Noodle.app/Contents/MacOS/noodled"; do [ -x "$c" ] && NOODLED=$c && break; done
fi
[ -x "$NOODLED" ] && [ -x "$DOCKER" ] || { echo "recovery: need noodled and docker" >&2; exit 2; }
RES=${NOODLE_RESOURCES:-$ROOT/build/resources}
export NOODLE_RESOURCES=$RES
# vm.log is opt-in; the held-disk phase reads B's "VM start attempt" lines from it.
export NOODLE_BOOT_CONSOLE=1
NOODLE_HOME=$(mktemp -d /tmp/noodle-rec.XXXXXX); export NOODLE_HOME
EVID=$ROOT/build/recovery/$(date +%Y%m%d-%H%M%S); mkdir -p "$EVID"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/noodle-rec-work.XXXXXX"); mkdir -p "$WORK/cfg"
export DOCKER_CONFIG=$WORK/cfg DOCKER_HOST=unix://$NOODLE_HOME/run/docker.sock DOCKER_CLI_HINTS=false
unset DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH DOCKER_API_VERSION
mkdir -p "$NOODLE_HOME/boot"
for f in vmlinux initramfs.cpio.gz; do [ -f "$RES/$f" ] && { cp -c "$RES/$f" "$NOODLE_HOME/boot/$f" 2>/dev/null || cp "$RES/$f" "$NOODLE_HOME/boot/$f"; }; done
PID=""
stop_daemon() {
  [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null || return 0
  kill -TERM "$PID" 2>/dev/null
  for _ in $(seq 1 40); do kill -0 "$PID" 2>/dev/null || return 0; sleep 0.5; done
  kill -KILL "$PID" 2>/dev/null
}
cleanup() { trap - EXIT INT TERM; stop_daemon; cp "$NOODLE_HOME/vm.log" "$EVID/vm-final.log" 2>/dev/null; rm -rf "$WORK"; rm -rf "$NOODLE_HOME"; }
trap cleanup EXIT
trap 'exit 130' INT TERM
FAILS=0
fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
start_daemon() { # $1 = log name
  "$NOODLED" >"$EVID/$1.log" 2>&1 & PID=$!
  for _ in $(seq 1 240); do
    curl -sf --max-time 2 --unix-socket "$NOODLE_HOME/run/docker.sock" http://localhost/_ping >/dev/null 2>&1 && return 0
    kill -0 "$PID" 2>/dev/null || return 1
    sleep 0.25
  done
  return 1
}
now() { python3 -c 'import time;print(int(time.time()*1000))'; }

start_daemon boot0 || { fail "initial daemon start"; exit 1; }
"$DOCKER" pull -q "$IMG" >/dev/null || { fail "pull $IMG"; exit 1; }
"$DOCKER" volume create recvol >/dev/null
"$DOCKER" run --rm -v recvol:/v "$IMG" sh -c 'echo seed > /v/seed && sync' || fail "seed write"
for i in $(seq 1 "$CYCLES"); do
  # Keep a workload writing so the kill lands mid-activity.
  "$DOCKER" run -d --name "rec-busy-$i" -v recvol:/v "$IMG" sh -c "while :; do dd if=/dev/zero of=/v/busy bs=1M count=64 conv=fsync 2>/dev/null; done" >/dev/null 2>&1 || fail "cycle $i: start busy"
  sleep 0.5
  kill -KILL "$PID"; wait "$PID" 2>/dev/null
  # Immediate restart: no waiting for the VZ helper to exit.
  t0=$(now)
  start_daemon "boot$i" || fail "cycle $i: daemon did not come back"
  out=$("$DOCKER" run --rm -v recvol:/v "$IMG" sh -c 'cat /v/seed; echo ok' 2>&1); rc=$?
  t1=$(now)
  echo "cycle $i: restart->first docker run ${rc}rc $((t1 - t0)) ms"
  case $out in *seed*ok*) ;; *) fail "cycle $i: volume data or run failed: $out" ;; esac
  grep -h -i "attachment\|attempt" "$EVID/boot$i.log" 2>/dev/null | sed "s/^/  cycle $i evidence| /"
  "$DOCKER" rm -f "rec-busy-$i" >/dev/null 2>&1
done

# Phase 2: deterministic version of the race. A second daemon (home B) shares the data disk's
# inode with the first (home A). While A's VM holds the disk, B's VM start gets the real
# "storage device attachment is invalid" error; killing A releases it and B must recover.
stop_daemon
A=$(mktemp -d /tmp/noodle-recA.XXXXXX); B=$(mktemp -d /tmp/noodle-recB.XXXXXX)
for h in "$A" "$B"; do mkdir -p "$h/boot"; cp "$NOODLE_HOME"/boot/* "$h/boot/"; done
cleanup2() { kill -KILL "$PA" "$PB" 2>/dev/null; rm -rf "$A" "$B"; }
trap 'cleanup2; cleanup' EXIT
NOODLE_HOME=$A "$NOODLED" >"$EVID/held-A.log" 2>&1 & PA=$!
sockA=$A/run/docker.sock; sockB=$B/run/docker.sock
for _ in $(seq 1 120); do curl -sf --unix-socket "$sockA" http://localhost/_ping >/dev/null 2>&1 && break; sleep 0.25; done
DOCKER_HOST=unix://$sockA "$DOCKER" pull -q "$IMG" >/dev/null || fail "held: pull on A"
DOCKER_HOST=unix://$sockA "$DOCKER" run --rm "$IMG" true || fail "held: A boot"
ln "$A/data.img" "$B/data.img"
NOODLE_HOME=$B "$NOODLED" >"$EVID/held-B.log" 2>&1 & PB=$!
for _ in $(seq 1 120); do curl -sf --unix-socket "$sockB" http://localhost/_ping >/dev/null 2>&1 && break; sleep 0.25; done
( DOCKER_HOST=unix://$sockB "$DOCKER" run --rm "$IMG" echo recovered >"$EVID/held-run.out" 2>&1; echo $? >"$EVID/held-run.rc" ) &
RUNP=$!
sleep 3
kill -KILL "$PA"; wait "$PA" 2>/dev/null          # A hard-killed; its VM helper must release the disk
wait "$RUNP"
if [ "$(cat "$EVID/held-run.rc")" = 0 ] && grep -q recovered "$EVID/held-run.out"; then
  echo "held-disk: B started after A was killed"
else
  fail "held-disk: B did not recover: $(cat "$EVID/held-run.out")"
fi
n=$(grep -c "VM start attempt" "$B/vm.log" 2>/dev/null)
echo "held-disk: B logged ${n:-0} failed start attempts"
[ "${n:-0}" -ge 1 ] || fail "held-disk: no retry evidence in B vm.log (race not exercised)"
grep "VM start attempt" "$B/vm.log" | sed 's/^/  evidence| /'
cp "$B/vm.log" "$EVID/held-B-vm.log" 2>/dev/null
kill -KILL "$PB" 2>/dev/null; wait "$PB" 2>/dev/null
[ "$FAILS" = 0 ] && echo "PASS recovery cycles=$CYCLES evidence=$EVID" || echo "FAIL recovery failures=$FAILS evidence=$EVID"
[ "$FAILS" = 0 ]
