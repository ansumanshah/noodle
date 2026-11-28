#!/usr/bin/env bash
# Supervisor-only termination during an active classic build, through the real `docker` CLI.
#
#   tests/supervisor-kill.sh [cycles]      default 3
#
# A build RUN keeps writing while the guest build supervisor (not the VM, not the daemon) is
# SIGKILLed. The next build starts immediately and must succeed: cleanup has to wait for the
# old worker's descendants to stop (worker cgroup drain), not just for the lock to drop.
#
# The kill needs a guest built with `-Dtest-hooks=true` (fault injection that makes the
# supervisor SIGKILL itself when the build log contains NOODLE_TEST_KILL_SUPERVISOR). This
# script builds that agent into build/zig-hooks and a private initramfs; the shipped agent has
# no such code. Evidence per cycle is kept under build/supervisor-kill/<timestamp>/.
# Isolation: fresh NOODLE_HOME under /tmp, throwaway DOCKER_CONFIG; ~/.noodle and
# ~/.docker are never touched. Env: NOODLED, DOCKER_BIN, ZIG, E2E_IMAGE, NOODLE_RESOURCES.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CYCLES=${1:-3}
IMG=${E2E_IMAGE:-alpine:3.22}
DOCKER=${DOCKER_BIN:-$ROOT/build/tools/docker}
ZIG=${ZIG:-$ROOT/scripts/zig.sh}
NOODLED=${NOODLED:-}
if [ -z "$NOODLED" ]; then
  for c in "$ROOT/.build/out/Products/Release/noodled" "$ROOT/.build/release/noodled" "$ROOT/build/Noodle.app/Contents/MacOS/noodled"; do [ -x "$c" ] && NOODLED=$c && break; done
fi
[ -x "$NOODLED" ] && [ -x "$DOCKER" ] || { echo "supervisor-kill: need noodled and docker" >&2; exit 2; }
BASE_RES=${NOODLE_RESOURCES:-$ROOT/build/resources}
(cd "$ROOT/guest/agent" && "$ZIG" build -Dtest-hooks=true --prefix "$ROOT/build/zig-hooks") || { echo "supervisor-kill: hooked agent build failed" >&2; exit 2; }
EVID=$ROOT/build/supervisor-kill/$(date +%Y%m%d-%H%M%S); mkdir -p "$EVID"
RES=$(mktemp -d /tmp/noodle-sk-res.XXXXXX)
for f in "$BASE_RES"/*; do cp -c "$f" "$RES/" 2>/dev/null || cp "$f" "$RES/"; done
"$ROOT/scripts/mkinitramfs" -i "$ROOT/build/zig-hooks/bin/init" -o "$RES/initramfs.cpio" >/dev/null || { echo "supervisor-kill: initramfs failed" >&2; exit 2; }
export NOODLE_RESOURCES=$RES
NOODLE_HOME=$(mktemp -d /tmp/noodle-sk.XXXXXX); export NOODLE_HOME
WORK=$(mktemp -d "${TMPDIR:-/tmp}/noodle-sk-work.XXXXXX"); mkdir -p "$WORK/cfg"
export DOCKER_CONFIG=$WORK/cfg DOCKER_HOST=unix://$NOODLE_HOME/run/docker.sock DOCKER_CLI_HINTS=false DOCKER_BUILDKIT=0
unset DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH DOCKER_API_VERSION
mkdir -p "$NOODLE_HOME/boot"
for f in vmlinux initramfs.cpio.gz; do cp -c "$RES/$f" "$NOODLE_HOME/boot/$f" 2>/dev/null || cp "$RES/$f" "$NOODLE_HOME/boot/$f"; done
PID=""
cleanup() {
  trap - EXIT INT TERM
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    kill -TERM "$PID" 2>/dev/null
    for _ in $(seq 1 40); do kill -0 "$PID" 2>/dev/null || break; sleep 0.5; done
    kill -KILL "$PID" 2>/dev/null
  fi
  cp "$NOODLE_HOME/vm.log" "$EVID/vm-final.log" 2>/dev/null
  rm -rf "$WORK" "$NOODLE_HOME" "$RES"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
FAILS=0
fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
now() { python3 -c 'import time;print(int(time.time()*1000))'; }

"$NOODLED" >"$EVID/daemon.log" 2>&1 & PID=$!
for _ in $(seq 1 240); do
  curl -sf --max-time 2 --unix-socket "$NOODLE_HOME/run/docker.sock" http://localhost/_ping >/dev/null 2>&1 && break
  kill -0 "$PID" 2>/dev/null || { fail "daemon exited"; exit 1; }
  sleep 0.25
done
"$DOCKER" pull -q "$IMG" >/dev/null || { fail "pull $IMG"; exit 1; }
"$DOCKER" volume create skvol >/dev/null
"$DOCKER" run --rm -v skvol:/v "$IMG" sh -c 'echo seed > /v/seed && sync' || fail "seed write"

# Bounded wait on a background job (no coreutils timeout on macOS).
wait_job() { # pid seconds
  local p=$1 n=$(($2 * 4))
  while [ "$n" -gt 0 ] && kill -0 "$p" 2>/dev/null; do sleep 0.25; n=$((n - 1)); done
  if kill -0 "$p" 2>/dev/null; then kill -KILL "$p" 2>/dev/null; wait "$p" 2>/dev/null; return 124; fi
  wait "$p"
}

for i in $(seq 1 "$CYCLES"); do
  c=$WORK/ctx-$i; mkdir -p "$c"
  cat >"$c/Dockerfile" <<DF
FROM $IMG
RUN echo NOODLE_TEST_KILL_\$(echo SUPERVISOR); n=0; while :; do dd if=/dev/zero of=/spin.\$((n % 40)) bs=256k count=4 2>/dev/null; n=\$((n + 1)); done
DF
  "$DOCKER" build --no-cache -t sk/victim:"$i" "$c" >"$EVID/victim-$i.log" 2>&1 & vp=$!
  wait_job "$vp" 60; vrc=$?
  if [ "$vrc" = 0 ]; then fail "cycle $i: victim build unexpectedly succeeded (hook did not fire)"; continue; fi
  [ "$vrc" = 124 ] && { fail "cycle $i: victim build hung after supervisor death"; continue; }
  # The marker is assembled at run time, so the hook can only fire on output of the running RUN.
  grep -q 'builder closed without reporting' "$EVID/victim-$i.log" || fail "cycle $i: victim did not end by supervisor loss: $(tail -2 "$EVID/victim-$i.log")"
  # Successor starts with no pause at all.
  printf 'FROM scratch\nCOPY file /file\n' >"$c/Dockerfile.next"; echo "cycle $i" >"$c/file"
  t0=$(now)
  "$DOCKER" build -f "$c/Dockerfile.next" -t sk/next:"$i" "$c" >"$EVID/next-$i.log" 2>&1 & np=$!
  wait_job "$np" 120; nrc=$?
  t1=$(now)
  echo "cycle $i: victim rc=$vrc, immediate successor build rc=$nrc in $((t1 - t0)) ms"
  [ "$nrc" = 0 ] || { fail "cycle $i: successor build failed: $(tail -3 "$EVID/next-$i.log")"; continue; }
  "$DOCKER" image inspect "sk/next:$i" >/dev/null 2>&1 || fail "cycle $i: successor image missing"
done

out=$("$DOCKER" run --rm -v skvol:/v "$IMG" cat /v/seed 2>&1)
[ "$out" = seed ] || fail "volume data lost: $out"
"$DOCKER" image inspect "$IMG" >/dev/null 2>&1 || fail "base image lost"
[ "$FAILS" = 0 ] && echo "PASS supervisor-kill cycles=$CYCLES evidence=$EVID" || echo "FAIL supervisor-kill failures=$FAILS evidence=$EVID"
[ "$FAILS" = 0 ]
