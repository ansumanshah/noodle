#!/usr/bin/env bash
# Noodle end-to-end suite: drives the real `docker` CLI against noodled.
#
#   tests/e2e.sh                run everything
#   tests/e2e.sh port volume    run checks whose name contains any argument
#   tests/e2e.sh --list         print check names and exit
#
# Output: one `PASS name`, `FAIL name` or `SKIP name` line per check (failure
# detail is indented under the FAIL line), then `SUMMARY pass=N fail=N skip=N`.
# The suite always continues after a failure. Exit status is 1 if any check failed.
#
# Isolation: noodled runs with NOODLE_HOME in a fresh temp dir, the Docker CLI uses
# a throwaway DOCKER_CONFIG, and ~/.docker is never read or written.
#
# Environment:
#   NOODLED            daemon binary (default .build/release/noodled, then the app bundle)
#   NOODLE_RESOURCES   dir with vmlinux + initramfs.cpio (default build/resources)
#   NOODLE_E2E_EXTERNAL=1   use the daemon already listening at $NOODLE_HOME/run/docker.sock
#   E2E_SOCKET         run against another engine's Docker socket (for example Podman's) and start no daemon
#   E2E_SKIP_FILE      lines of "check-name<TAB>reason": those checks print SKIP with the reason instead of running
#   DOCKER_BIN         docker CLI (default build/tools/docker, then PATH)
#   E2E_IMAGE          base image (default alpine:3.22)
#   E2E_TIMEOUT        per-check seconds (default 180)
#   E2E_PORT_BASE      first host port used by publish checks (default 18400)
#   E2E_HOME_ROOT      parent directory for the throwaway NOODLE_HOME (default /tmp; keep the socket path under 100 bytes)
#   E2E_TRACE=1        set -x inside each check (the last lines show in a failure)
#   E2E_SCAN_TIMEOUT   seconds for each scan-* check (default 1200; the first one downloads Grype and its multi-GB database)
#   E2E_KEEP=1         keep NOODLE_HOME and logs on exit
#   k8s checks         `tests/e2e.sh k8s` (E2E_TIMEOUT=900); they need the noodle CLI (NOODLE_BIN) and download k3s and kubectl, both digest pinned
#   NOODLE_E2E_REAL_TUNNEL=1   enable the public-network link smoke test
#   E2E_RESULTS        per-check timing file, "name<TAB>seconds<TAB>PASS|FAIL|SKIP" (default build/e2e/results-<timestamp>.tsv;
#                      build/e2e/results-latest.tsv links to the newest). The summary also lists the 20 slowest as `SLOW` lines.
#   E2E_JOBS=N         run area files across N isolated daemons (own NOODLE_HOME, socket, VM, port range). Default 1: serial,
#                      unchanged. The serial group (below) runs alone afterwards.
#   E2E_SHARD_MEMORY_MIB   guest memory per shard daemon (default 1024; the serial group keeps the daemon default)
#   E2E_IMAGE_CACHE    read-only seed of $E2E_IMAGE (blobs + images.json) cloned into every NOODLE_HOME (default build/e2e-cache)
#   E2E_SEED_IMAGES    extra images to put in the seed (space separated; default none, so pull checks still pull for real)
#   E2E_AREA=name      run only the cases of tests/e2e/<name>.sh (`just e2e-area name`)
#   E2E_EXACT=1        filters match whole check names instead of substrings
#   E2E_CASES_FILE     file with one exact check name per line (# comments): runs just those (`just e2e-smoke`, `just e2e-failed`)
#
# bash 3.2 compatible (macOS /bin/bash).
# shellcheck disable=SC2016,SC2086  # single quotes are guest-side scripts; id lists are split on purpose
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SELF="${BASH_SOURCE[0]}"
SCRIPT_DIR=$(cd "$(dirname "$SELF")" && pwd)
# Area files, sourced in this order. Registration order is file order, then definition order within a file.
E2E_FILES=(
  "$SCRIPT_DIR/e2e/helpers.sh"
  "$SCRIPT_DIR/e2e/engine.sh"
  "$SCRIPT_DIR/e2e/images.sh"
  "$SCRIPT_DIR/e2e/build.sh"
  "$SCRIPT_DIR/e2e/containers.sh"
  "$SCRIPT_DIR/e2e/exec.sh"
  "$SCRIPT_DIR/e2e/security-and-limits.sh"
  "$SCRIPT_DIR/e2e/privileged-workloads.sh"
  "$SCRIPT_DIR/e2e/mounts-and-volumes.sh"
  "$SCRIPT_DIR/e2e/networking.sh"
  "$SCRIPT_DIR/e2e/workload-vm-boundary.sh"
  "$SCRIPT_DIR/e2e/network-compatibility.sh"
  "$SCRIPT_DIR/e2e/import-from-another-engine.sh"
  "$SCRIPT_DIR/e2e/build-bases.sh"
  "$SCRIPT_DIR/e2e/compose.sh"
  "$SCRIPT_DIR/e2e/ai-apps.sh"
  "$SCRIPT_DIR/e2e/registry.sh"
  "$SCRIPT_DIR/e2e/proxy.sh"
  "$SCRIPT_DIR/e2e/restart-policies.sh"
  "$SCRIPT_DIR/e2e/logs.sh"
  "$SCRIPT_DIR/e2e/diagnostics.sh"
  "$SCRIPT_DIR/e2e/boot-console.sh"
  "$SCRIPT_DIR/e2e/conn-stability.sh"
  "$SCRIPT_DIR/e2e/host-development-processes-and-shared-names.sh"
  "$SCRIPT_DIR/e2e/local-names-and-ssh-agent.sh"
  "$SCRIPT_DIR/e2e/search-resume.sh"
  "$SCRIPT_DIR/e2e/pods.sh"
  "$SCRIPT_DIR/e2e/finder-read-only-webdav.sh"
  "$SCRIPT_DIR/e2e/public-links.sh"
  "$SCRIPT_DIR/e2e/managed-kubernetes.sh"
  "$SCRIPT_DIR/e2e/model-workloads.sh"
  "$SCRIPT_DIR/e2e/model-runner.sh"
  "$SCRIPT_DIR/e2e/local-kubernetes-yaml-workloads.sh"
  "$SCRIPT_DIR/e2e/connections.sh"
  "$SCRIPT_DIR/e2e/run-io.sh"
  "$SCRIPT_DIR/e2e/docker-errors.sh"
  "$SCRIPT_DIR/e2e/host-access.sh"
  "$SCRIPT_DIR/e2e/logs-rotation.sh"
  "$SCRIPT_DIR/e2e/memory-reclaim.sh"
  "$SCRIPT_DIR/e2e/testcontainers.sh"
)
# Serial group: areas that cannot share the machine with another VM, run alone after the shards.
#   managed-kubernetes, local-kubernetes-yaml-workloads  k3s on the host's fixed-name state, API/LB ports and a global `pgrep -f 'noodle kubernetes'`; heavy
#   privileged-workloads, workload-vm-boundary           privileged guests and the workload VM boundary (lsof on the shared workload image)
#   finder-read-only-webdav                              footprint and throughput limits measured against the daemon: timing-sensitive
E2E_SERIAL_AREAS="managed-kubernetes model-workloads local-kubernetes-yaml-workloads privileged-workloads workload-vm-boundary finder-read-only-webdav"
IMG=${E2E_IMAGE:-alpine:3.22}
TIMEOUT=${E2E_TIMEOUT:-180}
PORT_BASE=${E2E_PORT_BASE:-18400}
E2E_ROOT=$ROOT/build/e2e
E2E_BASE=${E2E_BASE_DIR:-$E2E_ROOT}   # under /Users so bind mounts go through virtiofs; each shard gets its own so cleanup never touches another's dirs

# --------------------------------------------------------------------------- list
list_checks() { grep -ho '^t_[a-zA-Z0-9_]*' "${E2E_FILES[@]}" | sed 's/^t_//' | tr _ -; }
if [ "${1:-}" = "--list" ]; then list_checks; exit 0; fi
# E2E holds the VM lock (shared host ports and VM memory), so separate checkouts never run two suites at once.
if [ -z "${NOODLE_VM_LOCK_HELD:-}" ]; then
  exec /usr/bin/lockf -k "${NOODLE_VM_LOCK:-/tmp/noodle-vm.lock}" /usr/bin/env NOODLE_VM_LOCK_HELD=1 bash "$SCRIPT_DIR/e2e.sh" "$@"
fi
FILTERS=("$@")
EXACT=${E2E_EXACT:-0}
if [ -n "${E2E_CASES_FILE:-}" ]; then
  [ -f "$E2E_CASES_FILE" ] || { echo "e2e: no cases file $E2E_CASES_FILE" >&2; exit 2; }
  EXACT=1; FILTERS=()
  known=$(list_checks)
  while IFS= read -r line; do
    line=${line%%#*}; line=$(echo $line)
    [ -n "$line" ] || continue
    printf '%s\n' "$known" | grep -qxF -- "$line" || { echo "e2e: unknown check in $E2E_CASES_FILE: $line" >&2; exit 2; }
    FILTERS+=("$line")
  done <"$E2E_CASES_FILE"
  [ ${#FILTERS[@]} -gt 0 ] || { echo "e2e: $E2E_CASES_FILE lists no checks" >&2; exit 2; }
fi
RUN_FILES=("${E2E_FILES[@]}")      # files whose cases run; every file is still sourced for its helpers
if [ -n "${E2E_AREA:-}" ]; then
  area=${E2E_AREA%.sh}; RUN_FILES=("$SCRIPT_DIR/e2e/$area.sh")
  [ -f "${RUN_FILES[0]}" ] || { echo "e2e: no area $area (see tests/e2e/)" >&2; exit 2; }
fi
if [ -n "${E2E_ONLY_FILES:-}" ]; then RUN_FILES=(); for f in $E2E_ONLY_FILES; do RUN_FILES+=("$SCRIPT_DIR/e2e/$f.sh"); done; fi
selected() {
  [ ${#FILTERS[@]} -eq 0 ] && return 0
  local f
  for f in "${FILTERS[@]}"; do
    if [ "$EXACT" = 1 ]; then [ "$1" = "$f" ] && return 0; else case $1 in *"$f"*) return 0 ;; esac; fi
  done
  return 1
}
kill_tree() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$c"; done; kill -KILL "$1" 2>/dev/null; return 0; }
RESULTS_STAMP=$(date +%Y%m%d-%H%M%S)
now() { perl -MTime::HiRes=time -e 'printf "%.2f\n", time'; }

# ----------------------------------------------------------------------- sharding
# E2E_JOBS=N: split the area files over N shards, each a full tests/e2e.sh run with its own daemon, then run the serial group.
if [ "${E2E_JOBS:-1}" -gt 1 ] 2>/dev/null && [ -z "${E2E_SHARD:-}" ] && [ -z "${E2E_SOCKET:-}" ] && [ "${NOODLE_E2E_EXTERNAL:-0}" != 1 ]; then
  JOBS=$E2E_JOBS
  mkdir -p "$E2E_ROOT"
  OUT=$(mktemp -d "${TMPDIR:-/tmp}/noodle-e2e-shards.XXXXXX")
  MERGED=${E2E_RESULTS:-$E2E_ROOT/results-$RESULTS_STAMP.tsv}
  LATEST_IN=$E2E_ROOT/results-latest.tsv
  trap 'for p in $(jobs -p); do kill_tree "$p"; done; rm -rf "$OUT"; exit 130' INT TERM
  # case -> file map, then weight per file: recorded seconds when a results file exists, file size otherwise
  : >"$OUT/map.tsv"; : >"$OUT/sizes.tsv"
  for f in "${RUN_FILES[@]}"; do
    a=$(basename "$f" .sh)
    case " $E2E_SERIAL_AREAS " in *" $a "*) continue ;; esac
    n=0
    for fn in $(grep -ho '^t_[a-zA-Z0-9_]*' "$f"); do
      name=$(echo "${fn#t_}" | tr _ -); selected "$name" || continue
      printf '%s\t%s\n' "$name" "$a" >>"$OUT/map.tsv"; n=$((n + 1))
    done
    [ "$n" -gt 0 ] && printf '%s\t%s\n' "$a" "$(wc -c <"$f" | tr -d ' ')" >>"$OUT/sizes.tsv"
  done
  awk -F'\t' -v jobs="$JOBS" -v res="$LATEST_IN" '
    BEGIN { while ((getline l < res) > 0) { split(l, a, "\t"); t[a[1]] = a[2] } }
    FILENAME ~ /map.tsv$/ { area[$1] = $2; cnt[$2]++; if ($1 in t) { sum[$2] += t[$1]; timed[$2]++ } next }
    { size[$1] = $2 }
    END {
      for (f in size) { tot += sum[f]; tn += timed[f] }
      avg = tn ? tot / tn : 0
      for (f in size) {
        if (tn) { w[f] = sum[f] + (cnt[f] - timed[f]) * (avg ? avg : 10) } else { w[f] = size[f] }
        print w[f] "\t" f
      }
    }' "$OUT/map.tsv" "$OUT/sizes.tsv" | sort -rn >"$OUT/weights.tsv"
  # longest first onto the least loaded shard
  awk -F'\t' -v jobs="$JOBS" '{ m = 1; for (i = 2; i <= jobs; i++) if (load[i] < load[m]) m = i; load[m] += $1; files[m] = files[m] " " $2 }
    END { for (i = 1; i <= jobs; i++) if (files[i] != "") print i "\t" files[i] }' "$OUT/weights.tsv" >"$OUT/plan.tsv"
  # first shard seeds the image cache when it is missing; others wait for it so no shard pulls twice
  CACHE=${E2E_IMAGE_CACHE:-$ROOT/build/e2e-cache}
  PIDS=""; FIRST=1
  while IFS=$'\t' read -r i files; do
    ( export E2E_SHARD=$i E2E_ONLY_FILES="${files# }" E2E_JOBS=1 E2E_PORT_BASE=$(( ${E2E_PORT_BASE:-18400} + i * 200 )) \
        E2E_BASE_DIR=$E2E_ROOT/shard-$i E2E_RESULTS=$OUT/shard-$i.tsv NOODLE_MEMORY_MIB="${NOODLE_MEMORY_MIB:-${E2E_SHARD_MEMORY_MIB:-1024}}" NOODLE_CPUS="${NOODLE_CPUS:-2}"
      exec "$SELF" "${FILTERS[@]+"${FILTERS[@]}"}" ) >"$OUT/shard-$i.out" 2>"$OUT/shard-$i.err" &
    PIDS="$PIDS $!"
    if [ "$FIRST" = 1 ] && [ ! -f "$CACHE/READY" ]; then
      for _ in $(seq 1 240); do [ -f "$CACHE/READY" ] && break; kill -0 $! 2>/dev/null || break; sleep 0.5; done
    fi
    FIRST=0
  done <"$OUT/plan.tsv"
  RC=0
  for p in $PIDS; do wait "$p" || RC=1; done
  # serial group, alone
  SER=""
  for a in $E2E_SERIAL_AREAS; do
    [ -f "$SCRIPT_DIR/e2e/$a.sh" ] || continue
    for rf in "${RUN_FILES[@]}"; do [ "$rf" = "$SCRIPT_DIR/e2e/$a.sh" ] && SER="$SER $a"; done
  done
  if [ -n "$SER" ]; then
    ( export E2E_SHARD=0 E2E_ONLY_FILES="${SER# }" E2E_JOBS=1 E2E_BASE_DIR=$E2E_ROOT/shard-0 E2E_RESULTS=$OUT/shard-0.tsv
      exec "$SELF" "${FILTERS[@]+"${FILTERS[@]}"}" ) >"$OUT/shard-0.out" 2>"$OUT/shard-0.err" || RC=1
  fi
  P=0 F=0 S=0
  for o in "$OUT"/shard-*.out; do
    [ -f "$o" ] || continue
    grep -v '^SUMMARY \|^SLOW ' "$o"
    eval "$(grep '^SUMMARY ' "$o" | sed 's/SUMMARY pass=\([0-9]*\) fail=\([0-9]*\) skip=\([0-9]*\).*/P=$((P+\1)) F=$((F+\2)) S=$((S+\3))/')"
    sed "s|^|e2e[$(basename "$o" .out)]: |" "${o%.out}.err" >&2
  done
  cat "$OUT"/shard-*.tsv >"$MERGED" 2>/dev/null
  ln -sfn "$(basename "$MERGED")" "$E2E_ROOT/results-latest.tsv" 2>/dev/null
  echo "e2e: results $MERGED"
  sort -t$'\t' -k2,2 -rn "$MERGED" | head -n 20 | awk -F'\t' '{ printf "SLOW %ss %s (%s)\n", $2, $1, $3 }'
  echo "SUMMARY pass=$P fail=$F skip=$S total=$((P + F + S))"
  rm -rf "$OUT"
  [ "$F" -eq 0 ] && [ "$RC" -eq 0 ]
  exit $?
fi

# ----------------------------------------------------------------------- environment
if [ -n "${DOCKER_BIN:-}" ]; then DOCKER=$DOCKER_BIN
elif [ -x "$ROOT/build/tools/docker" ]; then DOCKER=$ROOT/build/tools/docker
else DOCKER=$(command -v docker || true); fi
if [ -z "$DOCKER" ]; then echo "e2e: no docker CLI (run scripts/fetch-tools.sh)" >&2; exit 2; fi

EXTERNAL=${NOODLE_E2E_EXTERNAL:-0}
CREATED_HOME=0
if [ -n "${E2E_SOCKET:-}" ]; then
  # Another engine: its socket, and a scratch NOODLE_HOME so checks that look at Noodle's files fail visibly instead of crashing.
  EXTERNAL=1
  NOODLE_HOME=$(mktemp -d "${E2E_HOME_ROOT:-/tmp}/noodle-e2e.XXXXXX"); CREATED_HOME=1
  mkdir -p "$NOODLE_HOME/run"
elif [ "$EXTERNAL" = 1 ]; then
  : "${NOODLE_HOME:?NOODLE_E2E_EXTERNAL=1 needs NOODLE_HOME}"
else
  NOODLE_HOME=$(mktemp -d "${E2E_HOME_ROOT:-/tmp}/noodle-e2e.XXXXXX")   # short: unix socket paths cap at 104 bytes
  CREATED_HOME=1
fi
export NOODLE_HOME
# A small commit cap so the oversized-commit case needs 80 MB, not 16 GB.
export NOODLE_MAX_COMMIT_BYTES=${NOODLE_MAX_COMMIT_BYTES:-67108864}
export NOODLE_HTTP_PORT=${NOODLE_HTTP_PORT:-$((${E2E_PORT_BASE:-18400} + 90))}   # local names fallback port, used because the standard ports are switched off below
export NOODLE_HTTPS_PORT=${NOODLE_HTTPS_PORT:-$((${E2E_PORT_BASE:-18400} + 91))}
# This run must not take the real 80 and 443 (the user's daemon or another lane may hold them). The standard-port cases start their own daemon.
export NOODLE_NAMES_HTTP_PORT=0 NOODLE_NAMES_HTTPS_PORT=0
RES=${NOODLE_RESOURCES:-$ROOT/build/resources}
export NOODLE_RESOURCES=$RES

WORK=$(mktemp -d "${TMPDIR:-/tmp}/noodle-e2e-work.XXXXXX")
mkdir -p "$WORK/log" "$WORK/dockercfg" "$E2E_BASE"
[ -d "$ROOT/build/tools/cli-plugins" ] && ln -sfn "$ROOT/build/tools/cli-plugins" "$WORK/dockercfg/cli-plugins"

SOCK=${E2E_SOCKET:-$NOODLE_HOME/run/docker.sock}
unset DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH DOCKER_API_VERSION
export DOCKER_HOST=unix://$SOCK
export DOCKER_CONFIG=$WORK/dockercfg
export DOCKER_CLI_HINTS=false
export BUILDX_NO_DEFAULT_ATTESTATIONS=1

NOODLED_PID=""
stop_test_daemon() {
  local pid=${1:-}
  case $pid in ''|*[!0-9]*) return ;; esac
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.5
    done
    kill -KILL "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
}
cleanup() {
  trap - EXIT INT TERM
  if [ "$CREATED_HOME" = 1 ] && [ -f "$NOODLE_HOME/models/session.json" ] && [ -x "${K8S_NOODLE:-}" ]; then
    "$K8S_NOODLE" model stop >/dev/null 2>&1 || true
  fi
  # Restart cases replace the original daemon and record the current PID here.
  # Wait for its final state write before removing the isolated home.
  if [ -f "$WORK/noodled.pid" ]; then
    stop_test_daemon "$(cat "$WORK/noodled.pid")"
  fi
  # Only signal the original PID while it is still our child; it may have been
  # reaped and reused after a restart case.
  if [ -n "$NOODLED_PID" ] && [ "$(ps -p "$NOODLED_PID" -o ppid= 2>/dev/null | tr -d ' ')" = "$$" ]; then
    stop_test_daemon "$NOODLED_PID"
  fi
  if [ "${E2E_KEEP:-0}" != 1 ]; then
    rm -rf "$WORK" "$E2E_BASE"/ctx.* "$E2E_BASE"/bind.* 2>/dev/null
    [ "$CREATED_HOME" = 1 ] && rm -rf "$NOODLE_HOME"
  else
    echo "e2e: kept NOODLE_HOME=$NOODLE_HOME logs=$WORK/log" >&2
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

DAEMON_UP=0
if [ "$EXTERNAL" != 1 ]; then
  # Today's NoodlePaths reads the kernel and initramfs from $NOODLE_HOME/boot; stage them there
  # as well as exporting NOODLE_RESOURCES so either lookup finds them.
  mkdir -p "$NOODLE_HOME/boot"
  for f in vmlinux initramfs.cpio.gz; do
    [ -f "$RES/$f" ] && { cp -c "$RES/$f" "$NOODLE_HOME/boot/$f" 2>/dev/null || cp "$RES/$f" "$NOODLE_HOME/boot/$f"; }
  done
  [ -f "${E2E_IMAGE_CACHE:-$ROOT/build/e2e-cache}/READY" ] && "$SCRIPT_DIR/e2e-seed.sh" apply "${E2E_IMAGE_CACHE:-$ROOT/build/e2e-cache}" "$NOODLE_HOME"
  NOODLED=${NOODLED:-}
  if [ -z "$NOODLED" ]; then
    for c in "$ROOT/.build/release/noodled" "$ROOT/build/Noodle.app/Contents/MacOS/noodled" "$ROOT/.build/debug/noodled"; do
      [ -x "$c" ] && NOODLED=$c && break
    done
  fi
  if [ -z "$NOODLED" ] || [ ! -x "$NOODLED" ]; then
    echo "e2e: noodled not built (run 'just daemon' or 'just app')" >&2
  else
    "$NOODLED" >"$NOODLE_HOME/noodled.log" 2>&1 &
    NOODLED_PID=$!
  fi
fi
for _ in $(seq 1 120); do
  [ "$EXTERNAL" != 1 ] && [ -z "$NOODLED_PID" ] && break
  if [ -S "$SOCK" ] && curl -sf --max-time 2 --unix-socket "$SOCK" http://localhost/_ping >/dev/null 2>&1; then
    DAEMON_UP=1; break
  fi
  [ -n "$NOODLED_PID" ] && ! kill -0 "$NOODLED_PID" 2>/dev/null && break
  sleep 0.5
done
if [ "$DAEMON_UP" != 1 ]; then
  echo "e2e: daemon not reachable at $SOCK; every check will FAIL" >&2
  [ -f "$NOODLE_HOME/noodled.log" ] && sed 's/^/  noodled| /' <(tail -n 10 "$NOODLE_HOME/noodled.log") >&2
fi

# --------------------------------------------------------------------------- helpers
d() { "$DOCKER" "$@"; }
port() { echo $((PORT_BASE + $1)); }
skip() { echo "SKIP: $*"; exit 77; }

eq() { [ "$1" = "$2" ] || { echo "expected: $2"; echo "     got: $1"; return 1; }; }
has() { case $1 in *"$2"*) return 0 ;; esac; echo "expected to contain: $2"; echo "got: $1"; return 1; }
lacks() { case $1 in *"$2"*) echo "expected NOT to contain: $2"; echo "got: $1"; return 1 ;; esac; }
nonempty() { [ -n "$1" ] || { echo "expected non-empty value${2:+ ($2)}"; return 1; }; }
# A timeout (124, or 137 after timeout -k) is a hang, not the expected failure.
fails() {
  local rc=0; "$@" >/dev/null 2>&1 || rc=$?
  case $rc in
    0) echo "expected failure: $*"; return 1 ;;
    124|137) echo "expected failure, got timeout (exit $rc): $*"; return 1 ;;
  esac
}
exit_is() { local want=$1 got=0; shift; "$@" >/dev/null 2>&1 || got=$?; eq "$got" "$want"; }
wait_for() { # seconds cmd...
  local n=$(( $1 * 2 )); shift
  while [ "$n" -gt 0 ]; do "$@" >/dev/null 2>&1 && return 0; sleep 0.5; n=$((n - 1)); done
  echo "timed out waiting for: $*"; return 1
}
insp() { d inspect -f "$2" "$1"; }
is_running() { [ "$(insp "$1" '{{.State.Running}}' 2>/dev/null)" = true ]; }
is_healthy() { [ "$(insp "$1" '{{.State.Health.Status}}' 2>/dev/null)" = healthy ]; }
http_get() { curl -sf --max-time 5 "$1"; }
mkctx() { mktemp -d "$E2E_BASE/ctx.XXXXXX"; }
mkbind() { mktemp -d "$E2E_BASE/bind.XXXXXX"; }
serve() { # name [docker run flags...]: answer HTTP requests with "hi" on :80
  local name=$1; shift
  d run -d --name "$name" "$@" "$IMG" sh -c '
    printf "%s\n" "#!/bin/sh" '\''printf "HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\nhi\n"'\'' > /tmp/reply
    chmod +x /tmp/reply
    exec nc -lk -p 80 -e /tmp/reply' >/dev/null
}
sleeper() { local name=$1; shift; d run -d --name "$name" "$@" "$IMG" sleep 600 >/dev/null; }
with_tty() { command -v script >/dev/null || skip "script(1) missing"; script -q /dev/null "$@"; }

sweep() {
  local ids
  ids=$(d ps -aq --filter name=e2e 2>/dev/null) && [ -n "$ids" ] && d rm -f -v $ids >/dev/null 2>&1
  ids=$(d network ls -q --filter name=e2e 2>/dev/null) && [ -n "$ids" ] && d network rm $ids >/dev/null 2>&1
  ids=$(d volume ls -q --filter name=e2e 2>/dev/null) && [ -n "$ids" ] && d volume rm -f $ids >/dev/null 2>&1
  ids=$(d images -q --filter 'reference=e2e/*' 2>/dev/null | sort -u) && [ -n "$ids" ] && d rmi -f $ids >/dev/null 2>&1
  return 0
}


# ===================================================================== checks (tests/e2e/*.sh)
for f in "${E2E_FILES[@]}"; do
  # shellcheck disable=SC1090
  . "$f"
done

PASS=0 FAIL=0 SKIP=0
RESULTS=${E2E_RESULTS:-$E2E_ROOT/results-$RESULTS_STAMP.tsv}
mkdir -p "$(dirname "$RESULTS")"; : >"$RESULTS"
record() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$RESULTS"; }
run_check() {
  local fn=$1 name log rc pid wd limit=$TIMEOUT t0 t1 res
  name=$(echo "${fn#t_}" | tr _ -)
  selected "$name" || return 0
  # The first scan imports a multi-GB vulnerability database (see E2E_SCAN_TIMEOUT).
  case $name in
    scan-*) limit=${E2E_SCAN_TIMEOUT:-1200} ;;
    model-workloads) limit=${E2E_MODEL_TIMEOUT:-900} ;;
  esac
  if [ "$DAEMON_UP" != 1 ]; then
    echo "FAIL $name"; echo "  daemon unreachable"; FAIL=$((FAIL + 1)); record "$name" 0 FAIL; return 0
  fi
  if [ -n "${E2E_SKIP_FILE:-}" ]; then
    local why; why=$(awk -F'\t' -v n="$name" '$1 == n { print $2; exit }' "$E2E_SKIP_FILE")
    if [ -n "$why" ]; then echo "SKIP $name"; echo "  | $why"; SKIP=$((SKIP + 1)); record "$name" 0 SKIP; return 0; fi
  fi
  t0=$(now)
  log=$WORK/log/$name.log
  rm -f "$log.timeout"
  ( set -eo pipefail; set -u; [ -z "${E2E_TRACE:-}" ] || set -x; "$fn" ) >"$log" 2>&1 </dev/null &
  pid=$!
  ( sleep "$limit"; : >"$log.timeout"; kill_tree "$pid" ) >/dev/null 2>&1 &
  wd=$!
  { wait "$pid"; } 2>/dev/null; rc=$?
  kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
  t1=$(now)
  if [ -f "$log.timeout" ]; then
    echo "FAIL $name"; echo "  timed out after ${limit}s"; sed 's/^/  | /' <(tail -n 6 "$log")
    FAIL=$((FAIL + 1)); res=FAIL
  elif [ "$rc" = 0 ]; then
    echo "PASS $name"; PASS=$((PASS + 1)); res=PASS
  elif [ "$rc" = 77 ]; then
    echo "SKIP $name"; sed 's/^/  | /' <(tail -n 2 "$log"); SKIP=$((SKIP + 1)); res=SKIP
  else
    echo "FAIL $name"; sed 's/^/  | /' <(tail -n 12 "$log"); FAIL=$((FAIL + 1)); res=FAIL
  fi
  record "$name" "$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.2f", b - a }')" "$res"
  sweep >/dev/null 2>&1
}

if [ "$DAEMON_UP" = 1 ]; then
  d pull -q "$IMG" >/dev/null 2>&1 || echo "e2e: warning: could not pre-pull $IMG" >&2
  # Build the shared read-only seed once (blobs + catalog of $IMG and E2E_SEED_IMAGES only; images whose pulls are under test stay out).
  if [ "$EXTERNAL" != 1 ] && [ ! -f "${E2E_IMAGE_CACHE:-$ROOT/build/e2e-cache}/READY" ]; then
    for si in ${E2E_SEED_IMAGES:-}; do d pull -q "$si" >/dev/null 2>&1; done
    "$SCRIPT_DIR/e2e-seed.sh" build "${E2E_IMAGE_CACHE:-$ROOT/build/e2e-cache}" "$NOODLE_HOME" "$IMG" ${E2E_SEED_IMAGES:-} \
      || echo "e2e: warning: could not build the image seed" >&2
  fi
fi
while read -r fn <&3; do run_check "$fn"; done 3< <(grep -ho "^t_[a-zA-Z0-9_]*" "${RUN_FILES[@]}")
if [ -z "${E2E_SHARD:-}" ]; then
  ln -sfn "$(basename "$RESULTS")" "$E2E_ROOT/results-latest.tsv" 2>/dev/null
  echo "e2e: results $RESULTS" >&2
fi
sort -t"$(printf '\t')" -k2,2 -rn "$RESULTS" | head -n 20 | awk -F'\t' '{ printf "SLOW %ss %s (%s)\n", $2, $1, $3 }'
echo "SUMMARY pass=$PASS fail=$FAIL skip=$SKIP total=$((PASS + FAIL + SKIP))"
[ "$FAIL" -eq 0 ]
