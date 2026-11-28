#!/usr/bin/env bash
# Legacy data-disk migration acceptance with the real docker CLI.
#
#   tests/migrate-disk.sh
#
# 1. A real daemon creates a journaled disk and a docker volume with ~1 GiB of data.
# 2. The journal is removed with tune2fs (the on-disk state of an old experimental home).
# 3. The daemon must refuse that disk, unmodified, naming the exact `noodle migrate-disk` command.
# 4. `noodle migrate-disk` is SIGKILLed mid-copy: the original stays byte-identical and the disk is still refused.
# 5. A retry migrates; the original is kept as a backup, the disk has a journal and passes a read-only fsck,
#    the daemon starts and the volume's data hashes the same as before.
# Isolation: NOODLE_HOME and DOCKER_CONFIG are fresh temp dirs; ~/.noodle and ~/.docker are never used.
# Env: NOODLED, NOODLE_BIN, NOODLE_RESOURCES, DOCKER_BIN, E2E_IMAGE.
# shellcheck disable=SC2015  # ok and fail only print, so A && B || C is safe here
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
IMG=${E2E_IMAGE:-alpine:3.22}
DOCKER=${DOCKER_BIN:-$ROOT/build/tools/docker}
NOODLED=${NOODLED:-}
if [ -z "$NOODLED" ]; then   # release daemon, ad-hoc signed with the virtualization entitlement (copy; the build output is untouched)
  mkdir -p "$ROOT/build"; NOODLED=$ROOT/build/noodled-migrate-test
  cp "$ROOT/.build/release/noodled" "$NOODLED" && codesign --force --sign - --timestamp=none --entitlements "$ROOT/Resources/noodled.entitlements" "$NOODLED" 2>/dev/null
fi
NOODLE=${NOODLE_BIN:-$ROOT/.build/release/noodle}
RES=${NOODLE_RESOURCES:-$ROOT/build/resources}
for f in "$NOODLED" "$NOODLE" "$DOCKER" "$RES/e2fsck" "$RES/tune2fs"; do [ -x "$f" ] || { echo "migrate-disk: missing $f" >&2; exit 2; }; done
while pgrep -f bench/compare.py >/dev/null 2>&1; do sleep 5; done
export NOODLE_RESOURCES=$RES
mkdir -p "$ROOT/build"
NOODLE_HOME=$(mktemp -d "$ROOT/build/migrate-home.XXXXXX"); export NOODLE_HOME
EVID=$ROOT/build/migrate-disk-evidence; rm -rf "$EVID"; mkdir -p "$EVID"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/noodle-mig-work.XXXXXX"); mkdir -p "$WORK/cfg"
export DOCKER_CONFIG=$WORK/cfg DOCKER_HOST=unix://$NOODLE_HOME/run/docker.sock DOCKER_CLI_HINTS=false
unset DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH DOCKER_API_VERSION
mkdir -p "$NOODLE_HOME/boot"
for f in vmlinux initramfs.cpio.gz; do cp -c "$RES/$f" "$NOODLE_HOME/boot/$f" 2>/dev/null || cp "$RES/$f" "$NOODLE_HOME/boot/$f"; done
PID=""; MPID=""
stop_daemon() {
  [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null || { PID=""; return 0; }
  kill -TERM "$PID" 2>/dev/null
  for _ in $(seq 1 60); do kill -0 "$PID" 2>/dev/null || break; sleep 0.5; done
  kill -KILL "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; PID=""
}
cleanup() { trap - EXIT INT TERM; [ -n "$MPID" ] && kill -KILL "$MPID" 2>/dev/null; stop_daemon; cp "$NOODLE_HOME/vm.log" "$EVID/vm-final.log" 2>/dev/null; rm -rf "$WORK" "$NOODLE_HOME"; }
trap cleanup EXIT
trap 'exit 130' INT TERM
FAILS=0
fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
ok() { echo "ok   $*"; }
# Hash of size + every allocated range (the disk is a 64 GiB sparse file; hashing the holes would take minutes).
sum() { python3 -I - "$1" <<'PY'
import hashlib, os, sys
f = open(sys.argv[1], 'rb', buffering=0); size = os.fstat(f.fileno()).st_size
h = hashlib.sha256(str(size).encode()); pos = 0
while pos < size:
    try: start = os.lseek(f.fileno(), pos, os.SEEK_DATA)
    except OSError: break
    end = os.lseek(f.fileno(), start, os.SEEK_HOLE); f.seek(start); h.update(str(start).encode())
    while start < end:
        b = f.read(min(1 << 22, end - start)); 
        if not b: break
        h.update(b); start += len(b)
    pos = end
print(h.hexdigest())
PY
}
start_daemon() {
  "$NOODLED" >"$EVID/$1.log" 2>&1 & PID=$!
  for _ in $(seq 1 240); do
    curl -sf --max-time 2 --unix-socket "$NOODLE_HOME/run/docker.sock" http://localhost/_ping >/dev/null 2>&1 && return 0
    kill -0 "$PID" 2>/dev/null || return 1
    sleep 0.25
  done
  return 1
}
journal() { "$RES/tune2fs" -l "$1" 2>/dev/null | awk -F: '/features/ {print ($2 ~ /has_journal/) ? "yes" : "no"}'; }

# 1. Real daemon, real volume data (~1 GiB so a copy is long enough to interrupt).
start_daemon boot0 || { fail "initial daemon start"; exit 1; }
"$DOCKER" pull -q "$IMG" >/dev/null || { fail "pull $IMG"; exit 1; }
"$DOCKER" volume create migvol >/dev/null
"$DOCKER" run --rm -v migvol:/v "$IMG" sh -c 'echo legacy-canary > /v/canary; head -c 1073741824 /dev/zero | tr "\0" "q" > /v/big; sync' || fail "seed volume"
EXPECT=$("$DOCKER" run --rm -v migvol:/v "$IMG" sh -c 'cat /v/canary; wc -c < /v/big; md5sum < /v/big')
echo "seeded: $EXPECT" | tr '\n' ' '; echo
stop_daemon
sleep 2   # let the VM helper release the disk

# 2. Turn it into an old-style disk: same data, no journal.
DISK=$NOODLE_HOME/data.img
[ "$(journal "$DISK")" = yes ] || fail "fixture disk should start with a journal"
"$RES/e2fsck" -fp "$DISK" >"$EVID/fixture-fsck.log" 2>&1
"$RES/tune2fs" -O ^has_journal "$DISK" >"$EVID/fixture-tune.log" 2>&1 || fail "could not strip journal: $(cat "$EVID/fixture-tune.log")"
[ "$(journal "$DISK")" = no ] && ok "fixture is a non-journaled disk holding docker volume data" || fail "fixture still has a journal"
ORIG=$(sum "$DISK"); echo "original sha256 $ORIG"

# 3. The daemon refuses it, unchanged, and says exactly what to run.
start_daemon refused
OUT=$("$DOCKER" pull -q "$IMG" 2>&1; curl -s --unix-socket "$NOODLE_HOME/run/docker.sock" -X POST "http://localhost/images/create?fromImage=alpine&tag=3.22"); RC=$?
echo "$OUT" >"$EVID/refusal.txt"; cat "$NOODLE_HOME/vm.log" >>"$EVID/refusal.txt" 2>/dev/null
stop_daemon
if grep -q "migrate-disk" "$EVID/refusal.txt" && grep -q "NOODLE_HOME=" "$EVID/refusal.txt"; then ok "refusal names the command: $(grep -o "NOODLE_HOME=[^\`]*migrate-disk" "$EVID/refusal.txt" | head -1)"; else fail "refusal message lacks the command (rc=$RC): $OUT"; fi
[ "$(sum "$DISK")" = "$ORIG" ] && ok "refusal left the disk byte-identical" || fail "disk changed by the refused start"

# Dry run changes nothing and reports the space it needs.
"$NOODLE" migrate-disk --dry-run >"$EVID/dry-run.txt" 2>&1; rc=$?
grep -q "Needs .* MiB free" "$EVID/dry-run.txt" && [ $rc = 0 ] && ok "dry run: $(cat "$EVID/dry-run.txt")" || fail "dry run: $(cat "$EVID/dry-run.txt")"
[ "$(sum "$DISK")" = "$ORIG" ] && [ ! -e "$DISK.migrating" ] || fail "dry run changed files"

# 4. Interrupt a real migration mid-copy.
"$NOODLE" migrate-disk >"$EVID/migrate-killed.txt" 2>&1 & MPID=$!
for _ in $(seq 1 400); do
  [ -e "$DISK.migrating" ] && [ "$(stat -f %z "$DISK.migrating")" -gt 0 ] && [ "$(( $(stat -f %b "$DISK.migrating") * 512 ))" -gt 134217728 ] && break
  kill -0 "$MPID" 2>/dev/null || break
  sleep 0.05
done
if kill -0 "$MPID" 2>/dev/null; then
  kill -KILL "$MPID"; wait "$MPID" 2>/dev/null; MPID=""
  ok "SIGKILLed migrate-disk mid-copy ($(( $(stat -f %b "$DISK.migrating") / 2048 )) MiB staged)"
else
  wait "$MPID"; MPID=""; fail "migration finished before it could be interrupted (fixture too small); see $EVID/migrate-killed.txt"
fi
[ "$(sum "$DISK")" = "$ORIG" ] && ok "after the kill the original is byte-identical" || fail "original changed by the interrupted migration"
[ "$(journal "$DISK")" = no ] && ok "after the kill the disk is still refused (no half-migrated disk in place)" || fail "disk was switched during an interrupted run"

# 5. Retry to completion.
"$NOODLE" migrate-disk >"$EVID/migrate.txt" 2>&1; rc=$?
cat "$EVID/migrate.txt"
[ $rc = 0 ] && ok "migrate-disk exit 0" || fail "migrate-disk exit $rc"
BACKUP=$NOODLE_HOME/data.img.legacy-backup
[ -f "$BACKUP" ] && [ "$(sum "$BACKUP")" = "$ORIG" ] && ok "original kept untouched as $(basename "$BACKUP")" || fail "backup missing or modified"
[ ! -e "$DISK.migrating" ] && ok "no staging file left behind" || fail "staging file left behind"
[ "$(journal "$DISK")" = yes ] && ok "data.img now has a journal" || fail "data.img has no journal"
"$RES/e2fsck" -fn "$DISK" >"$EVID/final-fsck.log" 2>&1 && ok "read-only fsck of migrated disk is clean" || fail "fsck of migrated disk: $(tail -3 "$EVID/final-fsck.log")"
"$NOODLE" migrate-disk 2>&1 | grep -q "already has a journal" && ok "second run is a no-op" || fail "second run was not a no-op"

start_daemon migrated || fail "daemon did not start on the migrated disk"
GOT=$("$DOCKER" run --rm -v migvol:/v "$IMG" sh -c 'cat /v/canary; wc -c < /v/big; md5sum < /v/big' 2>&1)
[ "$GOT" = "$EXPECT" ] && ok "docker volume data identical after migration" || fail "volume data differs: got [$GOT] expected [$EXPECT]"
"$DOCKER" run --rm "$IMG" echo works >/dev/null 2>&1 && ok "docker run works on the migrated disk" || fail "docker run failed after migration"
stop_daemon

[ "$FAILS" = 0 ] && echo "PASS migrate-disk evidence=$EVID" || echo "FAIL migrate-disk failures=$FAILS evidence=$EVID"
[ "$FAILS" = 0 ]
