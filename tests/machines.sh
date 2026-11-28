#!/usr/bin/env bash
# Linux machines end to end: the real `noodle machine` CLI on Ubuntu and Alpine.
#
#   tests/machines.sh            run everything
#   tests/machines.sh raw-run    run raw-run checks only (fixture daemon stops before raw runs)
#
# Prints one PASS/FAIL line per check and `SUMMARY pass=N fail=N`. Needs `just daemon` and `just machine`
# (noodled, noodle, noodle-machine, build/resources, build/tools/docker) and network access for the first pull.
# Uses its own NOODLE_HOME. The caller holds the VM lock; this script does not take it.
#
# Environment: NOODLED, NOODLE (CLI), NOODLE_RESOURCES, E2E_KEEP=1 keeps the home and logs.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BIN=${NOODLE_BIN_DIR:-$ROOT/.build/release}
NOODLED=${NOODLED:-$BIN/noodled}
NOODLE=${NOODLE:-$BIN/noodle}
export NOODLE_RESOURCES=${NOODLE_RESOURCES:-$ROOT/build/resources}
export PATH="$ROOT/build/tools:$PATH"
NOODLE_HOME=$(mktemp -d /tmp/nm.XXXXXX)
export NOODLE_HOME
export NOODLE_NAMES_HTTP_PORT=0 NOODLE_NAMES_HTTPS_PORT=0
export DOCKER_HOST=unix://$NOODLE_HOME/run/docker.sock
export DOCKER_CONFIG=$NOODLE_HOME/dockercfg
mkdir -p "$DOCKER_CONFIG" "$NOODLE_HOME/boot"
for f in vmlinux initramfs.cpio.gz; do cp -c "$NOODLE_RESOURCES/$f" "$NOODLE_HOME/boot/$f" 2>/dev/null || cp "$NOODLE_RESOURCES/$f" "$NOODLE_HOME/boot/$f"; done
SHARE=$(mktemp -d /tmp/nm-share.XXXXXX)
MYUID=$(id -u)
ME=$(id -un)
PASS=0
FAIL=0
NOODLED_PID=""

cleanup() {
  trap - EXIT INT TERM
  kill "${LIMIT_PID:-0}" 2>/dev/null
  for p in $(pgrep -f "noodle-machine run --dir $NOODLE_HOME" 2>/dev/null); do kill -TERM "$p" 2>/dev/null; done
  for n in ubu alp shr sd badsd badimage; do
    [ -d "$NOODLE_HOME/machines/$n" ] && T 60 "$NOODLE" machine delete "$n" --yes >/dev/null 2>&1
  done
  if [ -n "$NOODLED_PID" ]; then
    kill -TERM "$NOODLED_PID" 2>/dev/null
    for _ in $(seq 1 20); do kill -0 "$NOODLED_PID" 2>/dev/null || break; sleep 0.5; done
    kill -KILL "$NOODLED_PID" 2>/dev/null
  fi
  if [ "${E2E_KEEP:-0}" != 1 ]; then rm -rf "$NOODLE_HOME" "$SHARE"; else echo "kept $NOODLE_HOME" >&2; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

ok() { PASS=$((PASS + 1)); echo "PASS $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL $1"; if [ -n "${2:-}" ]; then printf '  %s\n' "${2//$'\n'/$'\n  '}"; fi; }
expect() { # name expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi
}
# Every client call has a timeout: a hung guest must fail a check, not the suite.
T() { # seconds cmd...
  local secs=$1; shift
  exec 3<&0
  "$@" <&3 & local p=$!
  exec 3<&-
  ( sleep "$secs"; kill -KILL $p 2>/dev/null ) >/dev/null 2>&1 </dev/null & local w=$!   # detached from the caller's pipe, or $(...) would wait for the sleep
  wait $p 2>/dev/null; local rc=$?
  kill $w 2>/dev/null; wait $w 2>/dev/null
  return $rc
}
sh_() { T 60 "$NOODLE" machine shell "$1" -- "${@:2}" </dev/null; } # name cmd...
foot() { footprint "$1" 2>/dev/null | awk '/Footprint:/ {for (i = 1; i <= NF; i++) if ($i == "Footprint:") {print $(i + 1), $(i + 2); exit}}'; }

# Whole-run limit: kill everything this script started, then the EXIT trap cleans up.
( sleep "${TOTAL_LIMIT:-1200}"; kill -TERM $$ ) >/dev/null 2>&1 </dev/null &
LIMIT_PID=$!
[ -x "$NOODLED" ] && [ -x "$NOODLE" ] || { echo "build first: just daemon && just machine" >&2; exit 2; }

"$NOODLED" >"$NOODLE_HOME/noodled.log" 2>&1 &
NOODLED_PID=$!
for _ in $(seq 1 120); do
  curl -sf --max-time 2 --unix-socket "$NOODLE_HOME/run/docker.sock" http://localhost/_ping >/dev/null 2>&1 && break
  sleep 0.5
done
curl -sf --max-time 2 --unix-socket "$NOODLE_HOME/run/docker.sock" http://localhost/_ping >/dev/null 2>&1 || { echo "daemon did not start"; exit 2; }

if [ "${1:-}" != raw-run ]; then
# ---- nothing runs before the first create
expect "idle-no-machine-process" "0" "$(pgrep -f 'noodle-machine run' | wc -l | tr -d ' ')"
expect "idle-list-empty" "No machines. Create one with \`noodle machine create NAME\`." "$("$NOODLE" machine list)"
if [ -e "$NOODLE_HOME/machines" ]; then bad "idle-no-machines-dir"; else ok "idle-no-machines-dir"; fi
echo "FOOTPRINT noodled before create: $(foot "$NOODLED_PID")"

# ---- create
for pair in "ubu ubuntu" "alp alpine"; do
  read -r -a distro_pair <<< "$pair"
  set -- "${distro_pair[@]}"
  out=$(T 900 "$NOODLE" machine create "$1" --distro "$2" --memory 1G --cpus 2 2>&1)
  rc=$?
  expect "create-$2" "0" "$rc"
  [ $rc != 0 ] && echo "$out" | tail -n 8 | sed 's/^/  /'
done
out=$(T 600 "$NOODLE" machine create shr --distro alpine --memory 512M --share "$SHARE" 2>&1) ; expect "create-alpine-share" "0" "$?"
echo "FOOTPRINT noodled with 3 machines running: $(foot "$NOODLED_PID")"
"$NOODLE" machine list | sed 's/^/LIST /'

for m in ubu alp; do
  # identity and sudo
  expect "$m-uid" "$MYUID" "$(sh_ $m id -u)"
  expect "$m-username" "$ME" "$(sh_ $m id -un)"
  # shellcheck disable=SC2016 # Expand these variables in the guest shell.
  expect "$m-home" "/home/$ME" "$(sh_ $m sh -c 'echo $HOME')"
  expect "$m-sudo-passwordless" "0" "$(sh_ $m sudo -n id -u)"
  # exit code
  sh_ $m sh -c 'exit 42'; expect "$m-exit-code" "42" "$?"
  sh_ $m sh -c 'kill -9 $$'; expect "$m-exit-signaled" "137" "$?"
  # network and DNS
  expect "$m-dns" "ok" "$(sh_ $m sh -c 'getent hosts example.com >/dev/null && echo ok')"
  if [ $m = ubu ]; then
    expect "$m-tcp" "ok" "$(sh_ $m bash -c 'exec 3<>/dev/tcp/1.1.1.1/443 && echo ok')"
  else
    expect "$m-tcp" "ok" "$(sh_ $m sh -c 'nc -w 5 -z 1.1.1.1 443 && echo ok')"
  fi
  # no Mac files without --share
  expect "$m-no-users-dir" "absent" "$(sh_ $m sh -c 'test -e /Users && echo present || echo absent')"
  expect "$m-no-virtiofs" "0" "$(sh_ $m sh -c 'grep -c virtiofs /proc/mounts' | tr -d '\r')"
  expect "$m-no-mnt-share-content" "0" "$(sh_ $m sh -c 'ls -A /mnt/share 2>/dev/null | wc -l' | tr -d ' ')"
  # stdin passes through
  expect "$m-stdin" "hello" "$(echo hello | T 60 "$NOODLE" machine shell $m -- cat)"
  # tty, window size, resize, signals
  tty=$(python3 "$ROOT/tests/machine_tty.py" window "$NOODLE" $m 2>&1)
  expect "$m-tty-window-size" "31 101" "$(echo "$tty" | head -n 1 | tr -d '\r')"
  expect "$m-tty-exit" "exit 0" "$(echo "$tty" | tail -n 1)"
  tty=$(python3 "$ROOT/tests/machine_tty.py" resize "$NOODLE" $m 2>&1)
  expect "$m-tty-resize" "40 120" "$(echo "$tty" | head -n 1 | tr -d '\r')"
  tty=$(python3 "$ROOT/tests/machine_tty.py" signal "$NOODLE" $m 2>&1)
  expect "$m-signal-forwarded" "exit 7" "$(echo "$tty" | tail -n 1)"
  # persistence across stop, start, restart
  # shellcheck disable=SC2016 # Expand these variables in the guest shell.
  sh_ $m sh -c 'echo kept-$$ > ~/marker; echo "$MARK" >/dev/null'; marker=$(sh_ $m cat "/home/$ME/marker")
  T 60 "$NOODLE" machine stop $m >/dev/null 2>&1
  expect "$m-stop-no-host-process" "0" "$(pgrep -f "noodle-machine run --dir $NOODLE_HOME/machines/$m " | wc -l | tr -d ' ')"
  expect "$m-stopped-state" "stopped" "$("$NOODLE" machine list | awk -v n=$m '$1==n {print $2}')"
  T 120 "$NOODLE" machine start $m >/dev/null 2>&1
  expect "$m-persist-stop-start" "${marker:-EMPTY-MARKER}" "$(sh_ $m cat "/home/$ME/marker")"
  T 180 "$NOODLE" machine restart $m >/dev/null 2>&1
  expect "$m-persist-restart" "${marker:-EMPTY-MARKER}" "$(sh_ $m cat "/home/$ME/marker")"
  expect "$m-sudo-after-restart" "0" "$(sh_ $m sudo -n id -u)"
done

# ---- distro identity and systemd statement
# shellcheck disable=SC2016 # Expand these variables in the guest shell.
expect "ubu-is-ubuntu" "ubuntu" "$(sh_ ubu sh -c '. /etc/os-release; echo $ID')"
# shellcheck disable=SC2016 # Expand these variables in the guest shell.
expect "alp-is-alpine" "alpine" "$(sh_ alp sh -c '. /etc/os-release; echo $ID')"
case "$("$NOODLE" machine status ubu)" in *systemd*) ok "status-mentions-systemd" ;; *) bad "status-mentions-systemd" ;; esac

# ---- systemd: PID 1, shells, cgroup v2, units, and orderly shutdown.
# Removing PID 1 handoff, the session service, or graceful poweroff must fail these checks.
out=$(T 60 "$NOODLE" machine create badsd --distro alpine --systemd 2>&1); rc=$?
if [ "$rc" != 0 ]; then ok "systemd-reject-alpine"; else bad "systemd-reject-alpine" "$out"; fi
case "$out" in *systemd*init*) ok "systemd-image-requirements" ;; *) bad "systemd-image-requirements" "$out" ;; esac
out=$(T 300 "$NOODLE" machine create badimage --image alpine:3.22 --systemd --memory 512M 2>&1); rc=$?
if [ "$rc" != 0 ]; then ok "systemd-reject-image-without-init"; else bad "systemd-reject-image-without-init" "$out"; fi
case "$out" in *systemd*init*) ok "systemd-custom-image-requirements" ;; *) bad "systemd-custom-image-requirements" "$out" ;; esac
if [ -e "$NOODLE_HOME/machines/badimage" ]; then bad "systemd-reject-removes-machine"; else ok "systemd-reject-removes-machine"; fi
out=$(T 900 "$NOODLE" machine create sd --distro ubuntu --systemd --memory 1G 2>&1); rc=$?
expect "systemd-create" "0" "$rc"
if [ "$rc" = 0 ]; then
  expect "systemd-pid1" "systemd" "$(sh_ sd cat /proc/1/comm)"
  state=$(T 120 "$NOODLE" machine shell sd -- systemctl is-system-running --wait </dev/null)
  case "$state" in running|degraded) ok "systemd-running" ;; *) bad "systemd-running" "$state" ;; esac
  expect "systemd-shell" "$MYUID" "$(sh_ sd id -u)"
  expect "systemd-cgroup-v2" "cgroup2fs" "$(sh_ sd stat -fc %T /sys/fs/cgroup)"
  sh_ sd sudo sh -c 'cat > /etc/systemd/system/noodle-test.service <<"UNIT"
[Unit]
Description=Noodle shutdown test
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c "echo started > /var/lib/noodle-unit-start"
ExecStop=/bin/sh -c "echo clean > /var/lib/noodle-unit-stop"
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload && systemctl start noodle-test.service'
  expect "systemd-unit-start" "started" "$(sh_ sd cat /var/lib/noodle-unit-start)"
  expect "systemd-unit-active" "active" "$(sh_ sd systemctl is-active noodle-test.service)"
  T 110 "$NOODLE" machine stop sd >"$NOODLE_HOME/systemd-stop.log" 2>&1
  expect "systemd-stop-within-limit" "0" "$?"
  expect "systemd-stop-no-process" "0" "$(pgrep -f "noodle-machine run --dir $NOODLE_HOME/machines/sd " | wc -l | tr -d ' ')"
  expect "systemd-stopped-state" "stopped" "$("$NOODLE" machine list | awk '$1=="sd" {print $2}')"
  T 120 "$NOODLE" machine start sd >/dev/null 2>&1
  # First session of this boot on purpose: it must find the D-Bus socket already listening.
  expect "systemd-first-session-bus" "ok" "$(sh_ sd sh -c 'systemctl show -p Version --value >/dev/null && echo ok' 2>&1)"
  # The boot must finish without sitting on a device job that times out at 90 s.
  state=$(T 60 "$NOODLE" machine shell sd -- systemctl is-system-running --wait </dev/null 2>&1)
  case "$state" in running|degraded) ok "systemd-boot-under-60s" ;; *) bad "systemd-boot-under-60s" "$state" ;; esac
  expect "systemd-clean-stop" "clean" "$(sh_ sd cat /var/lib/noodle-unit-stop)"
  expect "systemd-restart-pid1" "systemd" "$(sh_ sd cat /proc/1/comm)"
fi
T 110 "$NOODLE" machine delete sd --yes >/dev/null 2>&1

# ---- two machines coexist
if [ "$("$NOODLE" machine list | grep -c running)" -ge 2 ]; then ok "two-running"; else bad "two-running" "$("$NOODLE" machine list)"; fi
expect "distinct-hostnames" "alp ubu" "$(printf '%s\n' "$(sh_ alp hostname)" "$(sh_ ubu hostname)" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')"

# ---- share: only the named folder, owned by the Mac user
echo "from-mac" > "$SHARE/mac.txt"
expect "share-visible" "from-mac" "$(sh_ shr cat /mnt/share/mac.txt)"
expect "share-owner" "$MYUID" "$(sh_ shr stat -c %u /mnt/share/mac.txt)"
sh_ shr sh -c 'echo from-guest > /mnt/share/guest.txt'
expect "share-write-back" "from-guest" "$(cat "$SHARE/guest.txt" 2>/dev/null)"
expect "share-write-owner-on-mac" "$ME" "$(stat -f %Su "$SHARE/guest.txt" 2>/dev/null)"
expect "share-no-users" "absent" "$(sh_ shr sh -c 'test -e /Users && echo present || echo absent')"
expect "share-only-one-mount" "1" "$(sh_ shr sh -c 'grep -c virtiofs /proc/mounts' | tr -d '\r')"
expect "share-cwd-maps" "/mnt/share" "$(cd "$SHARE" && T 60 "$NOODLE" machine shell shr -- pwd </dev/null)"

# ---- docker still works while machines run
expect "docker-run-alongside" "alive" "$(T 180 docker run --rm alpine:3.22 echo alive 2>&1 | tail -n 1)"
echo "FOOTPRINT noodled after docker run: $(foot "$NOODLED_PID")"
for m in ubu alp shr; do
  pid=$(cat "$NOODLE_HOME/machines/$m/lock" 2>/dev/null | tr -d '\n ')
  echo "MACHINE $m helper rss KiB: $(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ') footprint: $(foot "$pid")"
  echo "MACHINE $m guest: $(sh_ $m sh -c 'grep -E "MemTotal|MemAvailable" /proc/meminfo | tr -s " " | tr "\n" ";"')"
done

# ---- delete leaves nothing
for m in ubu alp shr; do
  T 60 "$NOODLE" machine delete $m --yes >/dev/null 2>&1
  if [ -e "$NOODLE_HOME/machines/$m" ]; then bad "$m-delete-removes-dir"; else ok "$m-delete-removes-dir"; fi
done
expect "delete-no-process" "0" "$(pgrep -f "noodle-machine run --dir $NOODLE_HOME" | wc -l | tr -d ' ')"
if [ -e "$NOODLE_HOME/machines" ]; then bad "delete-leaves-no-machines-dir" "$(ls -R "$NOODLE_HOME/machines")"; else ok "delete-leaves-no-machines-dir"; fi
expect "share-folder-untouched" "from-mac" "$(cat "$SHARE/mac.txt")"
echo "FOOTPRINT noodled at end: $(foot "$NOODLED_PID")"

fi

# ---- raw-run: the signed helper runs without the daemon or its Docker socket.
# Removing output forwarding, losing the guest status, or reusing the daemon's disk
# must fail these checks. All fixture setup happens before stopping the daemon.
RAW_ROOT="$SHARE/raw-root"
mkdir -p "$RAW_ROOT" "$SHARE/raw-tmp"
T 180 docker pull alpine:3.22 >/dev/null 2>&1 || { bad "raw-run-fixture-pull"; exit 1; }
raw_id=$(T 30 docker create alpine:3.22 true) || exit 1
T 60 docker export "$raw_id" >"$SHARE/root.tar" || exit 1
T 30 docker rm "$raw_id" >/dev/null || exit 1
tar -xf "$SHARE/root.tar" -C "$RAW_ROOT" || exit 1
kill -TERM "$NOODLED_PID"
for _ in $(seq 1 40); do kill -0 "$NOODLED_PID" 2>/dev/null || break; sleep 0.25; done
if kill -0 "$NOODLED_PID" 2>/dev/null; then bad "raw-run-daemon-stopped"; exit 1; fi
wait "$NOODLED_PID" 2>/dev/null
NOODLED_PID=""
expect "raw-run-no-daemon-socket" "absent" "$([ -S "$NOODLE_HOME/run/docker.sock" ] && echo present || echo absent)"
raw_out=$(T 120 env TMPDIR="$SHARE/raw-tmp/" "$NOODLE" debug run "$RAW_ROOT" /bin/sh -c 'echo raw-output; echo raw-error >&2; touch /raw-marker; exit 42' 2>"$SHARE/raw.err")
expect "raw-run-exit-code" "42" "$?"
expect "raw-run-stdout" "raw-output" "$raw_out"
expect "raw-run-stderr" "raw-error" "$(cat "$SHARE/raw.err")"
raw_out=$(T 120 env TMPDIR="$SHARE/raw-tmp/" "$NOODLE" debug run alpine:3.22 /bin/echo stored-image 2>"$SHARE/raw.err")
expect "raw-run-stored-image-exit" "0" "$?"
expect "raw-run-stored-image-output" "stored-image" "$raw_out"
T 30 env TMPDIR="$SHARE/raw-tmp/" "$NOODLE" debug run noodle-missing-raw-image:never true >"$SHARE/missing.out" 2>&1
expect "raw-run-missing-image" "1" "$?"
expect "raw-run-no-daemon-started" "absent" "$([ -S "$NOODLE_HOME/run/docker.sock" ] && echo present || echo absent)"
expect "raw-run-temp-cleanup" "0" "$(find "$SHARE/raw-tmp" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
expect "raw-run-no-helper-left" "0" "$(pgrep -f "noodle-machine raw-run --home $NOODLE_HOME " | wc -l | tr -d ' ')"
expect "raw-run-rootfs-unchanged" "absent" "$([ -e "$RAW_ROOT/raw-marker" ] && echo present || echo absent)"

echo "SUMMARY pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
