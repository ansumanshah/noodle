#!/usr/bin/env bash
# Disk and memory cost of the guest page-cache bound. Starts its own isolated noodled under the VM lock and prints one
# JSON object per pass on stdout. Every wait is bounded.
#
#   RES=<resources dir> tests/io-bench.sh [label]     # RES defaults to build/resources, so two builds can be compared
#
# Timings are seconds on the host around one `docker` call (per-call overhead is the same in both builds).
# Needs a built noodled and build/tools (just daemon tools).
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LABEL=${1:-run}
IMG=${MEMORY_IMAGE:-alpine:3.22}
RES=${RES:-$ROOT/build/resources}
DOCKER=$ROOT/build/tools/docker
NOODLED=${NOODLED:-$ROOT/.build/release/noodled}
LOCK=${NOODLE_VM_LOCK:-$(git -C "$ROOT" rev-parse --git-common-dir)/noodle-vm.lock}
case $LOCK in /*) ;; *) LOCK=$ROOT/$LOCK ;; esac
export NOODLE_NO_ACTIVATE=1
export NOODLE_MEMORY_MIB=${BENCH_MEM:-2048}

now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
# timed <cmd...>: seconds, bounded to 300 s
timed() { local a b; a=$(now); timeout 300 "$@" >/dev/null 2>&1; b=$(now); perl -e "printf '%.3f', $b-$a"; }
fp() { footprint "$1" 2>/dev/null | awk '/phys_footprint:/{n=$2;u=$3;s=(u=="GB"?1024:u=="MB"?1:u=="KB"?1/1024:u=="B"?1/1048576:0);printf "%.1f\n", n*s; exit}'; }
vm_pids() { pgrep -f 'com.apple.Virtualization.VirtualMachine' 2>/dev/null | sort -n; }

got=0
for _ in $(seq 1 240); do
  if mkdir "$LOCK" 2>/dev/null; then echo "io-bench $LABEL $$" >"$LOCK/owner"; got=1; break; fi
  sleep 5
done
[ "$got" = 1 ] || { echo "io-bench: VM lock busy" >&2; exit 3; }

HOME_DIR=$(mktemp -d /tmp/nib.XXXXXX)
export NOODLE_HOME=$HOME_DIR NOODLE_RESOURCES=$RES
export DOCKER_HOST=unix://$HOME_DIR/run/docker.sock DOCKER_CONFIG=$HOME_DIR/cfg
mkdir -p "$DOCKER_CONFIG"
DPID=""
SAMPLER=""
cleanup() {
  trap - EXIT INT TERM
  [ -n "$SAMPLER" ] && kill "$SAMPLER" 2>/dev/null
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
[ "$ok" = 1 ] || { echo "io-bench: daemon did not answer" >&2; exit 1; }
timeout 300 "$DOCKER" pull -q "$IMG" >/dev/null 2>&1 || { echo "io-bench: pull failed" >&2; exit 1; }
for _ in $(seq 1 10); do timeout 60 "$DOCKER" run --rm "$IMG" true >/dev/null 2>&1; done
"$DOCKER" volume create benchvol >/dev/null
timeout 60 "$DOCKER" run -d --name load -v benchvol:/vol "$IMG" sleep 7200 >/dev/null 2>&1 || { echo "io-bench: load container" >&2; exit 1; }
sleep 3
HELPER=$(comm -13 <(echo "$before") <(vm_pids) | tail -1)
[ -n "$HELPER" ] || { echo "io-bench: no VM helper" >&2; exit 1; }
# BENCH_SYSCTL="vm.dirty_bytes=N ..." applies plain vm sysctls through a privileged container (test of the no-agent-change option)
for kv in ${BENCH_SYSCTL:-}; do
  "$DOCKER" run --rm --privileged "$IMG" sh -c "echo ${kv#*=} >/proc/sys/$(echo "${kv%%=*}" | tr . /)" >/dev/null 2>&1
done
x() { timeout 300 "$DOCKER" exec load sh -c "$1"; }

# peak helper footprint while a command runs (sampled every 0.5 s)
peak_during() {
  local f=$HOME_DIR/peak; : >"$f"
  ( while :; do fp "$HELPER" >>"$f"; sleep 0.5; done ) &
  SAMPLER=$!
  "$@" >/dev/null 2>&1; fp "$HELPER" >>"$f"
  kill "$SAMPLER" 2>/dev/null; wait "$SAMPLER" 2>/dev/null; SAMPLER=""
  sort -n "$f" | tail -1
}

json=""
add() { json="$json\"$1\":$2,"; }
add base_mb "$(fp "$HELPER")"

# memory first (a later write or allocation would raise the helper's high-water mark): 400 MB write and 2 GB write,
# peak helper footprint during the write and the value 50 s after
add dd400_peak_mb "$(peak_during x 'dd if=/dev/zero of=/var/tmp/m bs=1M count=400; sync')"
sleep 50
add dd400_50s_mb "$(fp "$HELPER")"
x 'rm -f /var/tmp/m; sync' >/dev/null 2>&1
add dd2g_peak_mb "$(peak_during x 'dd if=/dev/zero of=/var/tmp/m bs=1M count=2048; sync')"
sleep 20
add dd2g_20s_mb "$(fp "$HELPER")"
add dd2g_size "$(x 'wc -c </var/tmp/m' 2>/dev/null | tr -dc 0-9)"
x 'rm -f /var/tmp/m; sync' >/dev/null 2>&1

# tree of 20000 files
x 'mkdir -p /vol/tree; for d in $(seq 1 100); do mkdir -p /vol/tree/d$d; (cd /vol/tree/d$d && seq 1 200 | xargs touch); done; sync' >/dev/null 2>&1


# volume and overlay: sequential write+sync, warm read, cold read (drop caches needs a privileged helper)
for where in vol:/vol/w tmp:/var/tmp/w; do
  k=${where%%:*}; p=${where#*:}
  add "${k}_write1g_s" "$(timed "$DOCKER" exec load sh -c "dd if=/dev/zero of=$p bs=1M count=1024 2>/dev/null; sync")"
  add "${k}_size" "$(x "wc -c <$p" 2>/dev/null | tr -dc 0-9)"
  add "${k}_read1g_warm_s" "$(timed "$DOCKER" exec load sh -c "dd if=$p of=/dev/null bs=1M 2>/dev/null")"
  "$DOCKER" run --rm --privileged -v benchvol:/vol "$IMG" sh -c 'sync; echo 3 >/proc/sys/vm/drop_caches' >/dev/null 2>&1
  add "${k}_read1g_cold_s" "$(timed "$DOCKER" exec load sh -c "dd if=$p of=/dev/null bs=1M 2>/dev/null")"
  x "rm -f $p; sync" >/dev/null 2>&1
done

# 400 MB written, then re-read at once
x 'dd if=/dev/zero of=/var/tmp/r bs=1M count=400 2>/dev/null; sync' >/dev/null 2>&1
add reread400_s "$(timed "$DOCKER" exec load sh -c "dd if=/var/tmp/r of=/dev/null bs=1M 2>/dev/null")"
x 'rm -f /var/tmp/r' >/dev/null 2>&1

# many-file tree: first call after the writes above, then a repeat
add find_s "$(timed "$DOCKER" exec load sh -c 'find /vol/tree -type f | wc -l')"
add du_s "$(timed "$DOCKER" exec load sh -c 'du -a /vol/tree | wc -l')"
add find2_s "$(timed "$DOCKER" exec load sh -c 'find /vol/tree -type f | wc -l')"

# docker build of a small image
mkdir -p "$HOME_DIR/ctx"
printf 'FROM %s\nRUN dd if=/dev/urandom of=/blob bs=1M count=64 2>/dev/null\nRUN sha256sum /blob > /sum\nRUN cat /sum /blob | wc -c > /n\n' "$IMG" >"$HOME_DIR/ctx/Dockerfile"
add build_s "$(timed "$DOCKER" build --no-cache -q -t benchimg "$HOME_DIR/ctx")"

# docker run p50 of 30 after 5 warm-ups
p50=$(perl -MTime::HiRes=time -e '
  my ($d,$i)=@ARGV; my @t;
  for (1..35) { my $a=time; system("$d run --rm $i true >/dev/null 2>&1"); push @t,(time-$a)*1000 if $_>5 }
  @t=sort {$a<=>$b} @t; printf "%.2f", $t[int(@t/2)]' "$DOCKER" "$IMG")
add run_p50_ms "${p50:-null}"

# anonymous 1.5 GB: allocate and touch (awk keeps 1536 distinct 1 MiB strings). Last, it raises the helper's high-water mark.
add anon_s "$(timed "$DOCKER" exec load awk 'BEGIN{s=sprintf("%1048576s","x"); for(i=0;i<1536;i++) a[i]=s"" i}')"
add anon_oom "$("$DOCKER" inspect -f '{{.State.OOMKilled}}' load)"

printf '{"label":"%s","commit":"%s","res":"%s",%s"end":true}\n' "$LABEL" "$(git -C "$ROOT" rev-parse --short HEAD)" "$RES" "$json"
