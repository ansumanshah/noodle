#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016,SC2086
# E2E checks: container access to Mac services. Sourced by tests/e2e.sh; do not run directly.

# --- a container reaches a Mac service through host.docker.internal and host-gateway.
# The name is the Mac's end of the VM's NAT link. TCP to it goes through the Mac loopback relay, so
# services bound to 127.0.0.1 or ::1 answer too; a service bound only to the NAT address is the relay's last target.
# /usr/bin/python3 is Apple-signed: the Mac's application firewall lets it listen beyond loopback without a dialog.
parity_gaps_mac_service() { # bind-address port [address to probe from the Mac]; sets PG_MAC_PORT and PG_MAC_PID
  local dir; dir=$(mkbind)
  PG_MAC_PORT=$2
  printf 'mac-service' >"$dir/index.html"
  # The time limit ends the server even when a check is killed before it reaches its own kill.
  (cd "$dir" && exec timeout 600 /usr/bin/python3 -m http.server "$PG_MAC_PORT" --bind "$1" >/dev/null 2>&1) &
  PG_MAC_PID=$!
  wait_for 20 curl -sf --noproxy '*' --max-time 2 "http://${3:-$1}:$PG_MAC_PORT/index.html" || { kill $PG_MAC_PID 2>/dev/null; return 1; }
}

parity_gaps_gateway() { # prints the address host.docker.internal resolves to in a container, checked to be IPv4
  local gw
  gw=$(pg_d run --rm "$IMG" awk '$2 == "host.docker.internal" { print $1 }' /etc/hosts) || return 1
  case $gw in
    *[!0-9.]* | "") echo "host.docker.internal is not an IPv4 address: '$gw'" >&2; return 1 ;;
  esac
  printf '%s\n' "$gw"
}

t_host_internal_reaches_mac_service() { # a Mac service on all interfaces
  local rc=0
  parity_gaps_mac_service 0.0.0.0 "$(port 95)" 127.0.0.1 || return 1
  eq "$(pg_d run --rm "$IMG" wget -q -T 10 -O- "http://host.docker.internal:$PG_MAC_PORT/index.html" 2>&1)" mac-service || rc=$?
  kill $PG_MAC_PID 2>/dev/null
  return $rc
}

t_host_gateway_add_host_reaches_mac_service() { # a Mac service on the NAT link's address only
  local rc=0 gw
  gw=$(parity_gaps_gateway) || return 1
  parity_gaps_mac_service "$gw" "$(port 96)" || return 1
  eq "$(pg_d run --rm --add-host mac:host-gateway "$IMG" wget -q -T 10 -O- "http://mac:$PG_MAC_PORT/index.html" 2>&1)" mac-service || rc=$?
  kill $PG_MAC_PID 2>/dev/null
  return $rc
}

t_host_internal_from_host_and_user_networks() {
  local rc=0 gw
  gw=$(parity_gaps_gateway) || return 1
  pg_d network create e2e-pg-mac >/dev/null || return 1
  parity_gaps_mac_service "$gw" "$(port 97)" || return 1
  eq "$(pg_d run --rm --network host "$IMG" wget -q -T 10 -O- "http://host.docker.internal:$PG_MAC_PORT/index.html" 2>&1)" mac-service || rc=$?
  eq "$(pg_d run --rm --network e2e-pg-mac "$IMG" wget -q -T 10 -O- "http://host.docker.internal:$PG_MAC_PORT/index.html" 2>&1)" mac-service || rc=$?
  kill $PG_MAC_PID 2>/dev/null
  return $rc
}

# --- Mac loopback relay: vsock 1034 from the guest, noodled connects as 127.0.0.1.
hostlo_get() { # url [docker run flags...]: the page, or the error text
  local url=$1; shift
  pg_d run --rm "$@" "$IMG" wget -q -T 10 -O- "$url" 2>&1
}

hostlo_probe() { # url [docker run flags...]: wget inside a container, bracketed so a refusal proves the probe ran
  local url=$1; shift
  pg_d run --rm "$@" "$IMG" sh -c 'echo PROBE-START; wget -q -T 5 -O- "$1" 2>&1; echo "PROBE-RC=$?"' probe "$url" 2>&1
}

hostlo_probe_on() { # socket url [docker run flags...]: the same probe through another daemon
  local sock=$1 url=$2; shift 2
  DOCKER_HOST=unix://$sock timeout -k 5 60 "$DOCKER" run --rm "$@" "$IMG" \
    sh -c 'echo PROBE-START; wget -q -T 5 -O- "$1" 2>&1; echo "PROBE-RC=$?"' probe "$url" 2>&1
}

# A refusal counts only when the container ran, the name resolved, wget failed at the connection, and no page came back.
hostlo_refused() { # out what
  case $1 in *mac-service*) echo "$2 reached the Mac service: $1"; return 1 ;; esac
  has "$1" "PROBE-START" || { echo "$2: the probe container never ran"; return 1; }
  case $1 in *PROBE-RC=0*) echo "$2: wget succeeded: $1"; return 1 ;; *PROBE-RC=*) ;; *) echo "$2: the probe did not finish: $1"; return 1 ;; esac
  lacks "$1" "bad address"
  case $1 in
    *refused* | *reset* | *"timed out"* | *unreachable* | *"error getting response"* | *"can't connect"* | *"No route"*) ;;
    *) echo "$2: failed for a reason other than the connection: $1"; return 1 ;;
  esac
}

# The guest's relay port on the Mac: a probe aimed at it would reach this if anything forwarded it.
hostlo_canary_61034() { # sets HOSTLO_CANARY_PID
  curl -s --noproxy '*' --max-time 1 -o /dev/null http://127.0.0.1:61034/ && skip "127.0.0.1:61034 is in use on this Mac"
  local pid_before=${PG_MAC_PID:-}
  parity_gaps_mac_service 127.0.0.1 61034 || return 1
  HOSTLO_CANARY_PID=$PG_MAC_PID; PG_MAC_PID=$pid_before
}

hostlo_holder() { # port: a Mac service that accepts and never answers or closes; sets HOSTLO_HOLD_PID
  /usr/bin/python3 -c '
import socket, sys
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(512); held = []
while True: held.append(s.accept()[0])' "$1" >/dev/null 2>&1 &
  HOSTLO_HOLD_PID=$!
  wait_for 10 nc -z 127.0.0.1 "$1"
}

t_host_internal_reaches_mac_loopback() {
  local rc=0
  parity_gaps_mac_service 127.0.0.1 "$(port 98)" || return 1
  eq "$(hostlo_get "http://host.docker.internal:$PG_MAC_PORT/index.html")" mac-service || rc=$?
  kill $PG_MAC_PID 2>/dev/null
  return $rc
}

t_host_gateway_add_host_reaches_mac_loopback() {
  local rc=0
  parity_gaps_mac_service 127.0.0.1 "$(port 170)" || return 1
  eq "$(hostlo_get "http://mac:$PG_MAC_PORT/index.html" --add-host mac:host-gateway)" mac-service || rc=$?
  kill $PG_MAC_PID 2>/dev/null
  return $rc
}

t_host_internal_reaches_mac_loopback_ipv6() { # Vite and Node bind localhost to ::1 only
  local rc=0
  parity_gaps_mac_service ::1 "$(port 171)" '[::1]' || return 1
  eq "$(hostlo_get "http://host.docker.internal:$PG_MAC_PORT/index.html")" mac-service || rc=$?
  kill $PG_MAC_PID 2>/dev/null
  return $rc
}

t_host_internal_loopback_from_host_and_user_networks() {
  local rc=0
  pg_d network create e2e-hostlo-user >/dev/null || return 1
  parity_gaps_mac_service 127.0.0.1 "$(port 172)" || return 1
  eq "$(hostlo_get "http://host.docker.internal:$PG_MAC_PORT/index.html" --network host)" mac-service || rc=$?
  eq "$(hostlo_get "http://host.docker.internal:$PG_MAC_PORT/index.html" --network e2e-hostlo-user)" mac-service || rc=$?
  kill $PG_MAC_PID 2>/dev/null
  pg_d network rm e2e-hostlo-user >/dev/null 2>&1
  return $rc
}

hostlo_int_down() {
  [ -n "${PG_MAC_PID:-}" ] && kill "$PG_MAC_PID" 2>/dev/null
  [ -n "${HOSTLO_CANARY_PID:-}" ] && kill "$HOSTLO_CANARY_PID" 2>/dev/null
  pg_d network rm e2e-hostlo-int e2e-hostlo-overlap >/dev/null 2>&1
  return 0
}

t_host_internal_loopback_blocked_on_internal_network() { # by name, and by dialling the guest relay port directly
  local rc=0 out igw bgw gw made
  trap hostlo_int_down EXIT
  hostlo_canary_61034 || return 1
  # The canary is real: an ordinary container reaches it through the relay, as it should.
  eq "$(hostlo_get "http://host.docker.internal:61034/index.html")" mac-service || return 1
  pg_d network create --internal e2e-hostlo-int >/dev/null || return 1
  parity_gaps_mac_service 127.0.0.1 "$(port 173)" || return 1
  igw=$(pg_d network inspect -f '{{(index .IPAM.Config 0).Gateway}}' e2e-hostlo-int)
  bgw=$(pg_d network inspect -f '{{(index .IPAM.Config 0).Gateway}}' bridge)
  hostlo_refused "$(hostlo_probe "http://host.docker.internal:$PG_MAC_PORT/index.html" --network e2e-hostlo-int)" "internal network by name" || rc=1
  hostlo_refused "$(hostlo_probe "http://$igw:61034/index.html" --network e2e-hostlo-int)" "internal network to the relay port" || rc=1
  hostlo_refused "$(hostlo_probe "http://$bgw:61034/index.html")" "bridge container to the relay port" || rc=1
  # Finding 1: an internal network whose gateway is the Mac's own NAT address passes an address check; the guest's
  # input guard still drops it, because no redirect rewrote the connection.
  gw=$(parity_gaps_gateway) || return 1
  if made=$(pg_d network create --internal --subnet "${gw%.*}.0/24" --gateway "$gw" e2e-hostlo-overlap 2>&1); then
    hostlo_refused "$(hostlo_probe "http://$gw:61034/index.html" --network e2e-hostlo-overlap)" "internal network sharing the Mac's gateway" || rc=1
  else
    echo "overlapping internal network refused at create (also safe): $made"
  fi
  return $rc
}

t_host_internal_loopback_refuses_noodle_ports() { # a stand-in for the model server on its default port
  local out rc=0
  curl -s --noproxy '*' --max-time 1 -o /dev/null http://127.0.0.1:11345/ && skip "127.0.0.1:11345 is in use on this Mac"
  parity_gaps_mac_service 127.0.0.1 11345 || return 1
  out=$(hostlo_probe "http://host.docker.internal:11345/index.html")
  kill $PG_MAC_PID 2>/dev/null
  hostlo_refused "$out" "a container through the relay to Noodle's model port" || rc=$?
  return $rc
}

t_host_internal_loopback_closed_port_fails_fast() { # nothing listens: a reset after connect, not a hang
  local out t0 t1
  t0=$(date +%s)
  out=$(hostlo_get "http://host.docker.internal:$(port 174)/") && { echo "got a page from a closed port: $out"; return 1; }
  t1=$(date +%s)
  lacks "$out" "bad address"
  [ $((t1 - t0)) -le 5 ] || { echo "closed port took $((t1 - t0)) s (wget -T 10)"; return 1; }
}

t_host_internal_loopback_build_run() {
  local ctx out rc=0
  parity_gaps_mac_service 127.0.0.1 "$(port 175)" || return 1
  ctx=$(mkctx)
  printf 'FROM %s\nRUN wget -q -T 10 -O- http://host.docker.internal:%s/index.html\n' "$IMG" "$PG_MAC_PORT" >"$ctx/Dockerfile"
  out=$(timeout -k 5 180 "$DOCKER" build --no-cache --progress=plain --add-host host.docker.internal:host-gateway -t e2e/hostlo-build "$ctx" 2>&1) || rc=1
  kill $PG_MAC_PID 2>/dev/null
  pg_d rmi -f e2e/hostlo-build >/dev/null 2>&1
  [ "$rc" -eq 0 ] || { echo "$out" | tail -n 20; return 1; }
  has "$out" "mac-service"
}

t_priv_host_internal_does_not_reach_mac_loopback() { # stated difference: the workload VM has no relay
  local out rc=0
  parity_gaps_mac_service 127.0.0.1 "$(port 176)" || return 1
  out=$(timeout -k 5 120 "$DOCKER" run --rm --privileged "$IMG" \
    sh -c 'echo PROBE-START; wget -q -T 5 -O- "$1" 2>&1; echo "PROBE-RC=$?"' probe "http://host.docker.internal:$PG_MAC_PORT/index.html" 2>&1)
  kill $PG_MAC_PID 2>/dev/null
  hostlo_refused "$out" "a privileged container" || rc=$?
  return $rc
}

# A second daemon with its own NOODLE_HOME and VM: the off switch is read at start, and claims must cross daemons.
hostlo_b_down() {
  [ -n "${HOSTLO_B_PID:-}" ] && stop_test_daemon "$HOSTLO_B_PID"
  [ -n "${PG_MAC_PID:-}" ] && kill "$PG_MAC_PID" 2>/dev/null
  [ -n "${HOSTLO_B_HOME:-}" ] && rm -rf "$HOSTLO_B_HOME"
  d rm -f e2e-hostlo-nm >/dev/null 2>&1
  return 0
}

hostlo_b_up() { # vm.json contents; sets HOSTLO_B_SOCK
  local f
  [ -n "${NOODLED:-}" ] && [ -x "$NOODLED" ] || { echo "noodled not built"; return 1; }
  HOSTLO_B_HOME=$(mktemp -d /tmp/noodle-hostlo.XXXXXX); HOSTLO_B_PID=""
  trap hostlo_b_down EXIT
  mkdir -p "$HOSTLO_B_HOME/boot"
  for f in vmlinux initramfs.cpio.gz; do
    [ ! -f "$RES/$f" ] || cp -c "$RES/$f" "$HOSTLO_B_HOME/boot/$f" 2>/dev/null || cp "$RES/$f" "$HOSTLO_B_HOME/boot/$f"
  done
  printf '%s\n' "$1" >"$HOSTLO_B_HOME/vm.json"
  HOSTLO_B_SOCK=$HOSTLO_B_HOME/run/docker.sock
  NOODLE_HOME="$HOSTLO_B_HOME" NOODLE_MEMORY_MIB=1024 NOODLE_CPUS=2 NOODLE_NAMES_HTTP_PORT=0 NOODLE_NAMES_HTTPS_PORT=0 \
    NOODLE_HTTP_PORT="$(port 178)" NOODLE_HTTPS_PORT="$(port 179)" "$NOODLED" >>"$HOSTLO_B_HOME/noodled.log" 2>&1 &
  HOSTLO_B_PID=$!
  wait_for 60 curl -sf --max-time 2 --unix-socket "$HOSTLO_B_SOCK" http://localhost/_ping || return 1
  DOCKER_HOST=unix://$HOSTLO_B_SOCK timeout -k 5 120 "$DOCKER" pull -q "$IMG" >/dev/null
}

t_host_internal_loopback_off_setting_refuses() {
  hostlo_b_up '{"host_loopback":false}' || return 1
  parity_gaps_mac_service 127.0.0.1 "$(port 177)" || return 1
  hostlo_refused "$(hostlo_probe_on "$HOSTLO_B_SOCK" "http://host.docker.internal:$PG_MAC_PORT/index.html")" \
    "with host_loopback false, a container"
}

t_publish_address_setting_binds_unaddressed_ports_to_loopback() {
  local p1 p2 ports
  hostlo_b_up '{"publish_address":"127.0.0.1"}' || return 1
  p1=$(port 184); p2=$(port 185)
  ( export DOCKER_HOST=unix://$HOSTLO_B_SOCK; serve e2e-pub-lo -p "$p1:80" -p "0.0.0.0:$p2:80" ) || return 1
  # No address asked: IPv4 loopback only, nothing on a wildcard. An address asked for is still honoured.
  ports=$(DOCKER_HOST=unix://$HOSTLO_B_SOCK "$DOCKER" port e2e-pub-lo 80/tcp | sort | tr '\n' ' ')
  eq "$ports" "0.0.0.0:$p2 127.0.0.1:$p1 " || return 1
  wait_for 20 sh -c "curl -sf --max-time 3 http://127.0.0.1:$p1/ | grep -qx hi"
}

t_host_internal_loopback_invalid_settings_refuse_start() { # finding 4: fail closed, never fall back to on
  local home log pid
  [ -n "${NOODLED:-}" ] && [ -x "$NOODLED" ] || { echo "noodled not built"; return 1; }
  home=$(mktemp -d /tmp/noodle-hostlo.XXXXXX); log=$home/noodled.log
  printf '{"host_loopback":false,"cpus":"8"}\n' >"$home/vm.json"
  NOODLE_HOME="$home" NOODLE_NAMES_HTTP_PORT=0 NOODLE_NAMES_HTTPS_PORT=0 "$NOODLED" >"$log" 2>&1 &
  pid=$!
  wait_for 20 sh -c "! kill -0 $pid 2>/dev/null" || { stop_test_daemon "$pid"; rm -rf "$home"; echo "noodled kept running on an invalid vm.json"; return 1; }
  wait "$pid" 2>/dev/null || true
  local text; text=$(cat "$log"); rm -rf "$home"
  has "$text" "vm.json is not valid Noodle settings"
}

t_host_internal_loopback_refuses_other_daemons_name_router() { # finding 2: claims cross NOODLE_HOME
  local out
  serve e2e-hostlo-nm --expose 80   # no -p: reachable from the Mac only through this daemon's name router
  wait_for 20 test "$(curl -sf --max-time 3 -H 'Host: e2e-hostlo-nm.localhost' "http://127.0.0.1:$NOODLE_HTTP_PORT/")" = hi || return 1
  hostlo_b_up '{}' || return 1
  parity_gaps_mac_service 127.0.0.1 "$(port 180)" || return 1
  # Daemon B's relay works ...
  out=$(hostlo_probe_on "$HOSTLO_B_SOCK" "http://host.docker.internal:$PG_MAC_PORT/index.html")
  has "$out" "mac-service" || return 1
  # ... but not into daemon A's name router, and so not into A's unpublished container.
  out=$(DOCKER_HOST=unix://$HOSTLO_B_SOCK timeout -k 5 60 "$DOCKER" run --rm "$IMG" sh -c \
    'echo PROBE-START; wget -q -T 5 -O- --header "Host: e2e-hostlo-nm.localhost" "$1" 2>&1; echo "PROBE-RC=$?"' \
    probe "http://host.docker.internal:$NOODLE_HTTP_PORT/" 2>&1)
  printf '%s\n' "$out" | grep -qx hi && { echo "daemon B reached daemon A's container through A's name router: $out"; return 1; }
  hostlo_refused "$out" "daemon B to daemon A's name router"
}

hostlo_flood_down() {
  d rm -f e2e-hostlo-flood e2e-hostlo-log e2e-hostlo-hold >/dev/null 2>&1
  [ -n "${HOSTLO_HOLD_PID:-}" ] && kill "$HOSTLO_HOLD_PID" 2>/dev/null
  [ -n "${PG_MAC_PID:-}" ] && kill "$PG_MAC_PID" 2>/dev/null
  return 0
}

t_host_internal_loopback_flood_recovers() { # finding 5: the agent stays responsive and the slots come back
  local hold t0 t1
  trap hostlo_flood_down EXIT
  hold=$(port 181)
  hostlo_holder "$hold" || return 1
  d run -d --name e2e-hostlo-flood "$IMG" sh -c \
    "for i in \$(seq 200); do sleep 120 | nc host.docker.internal $hold & done; wait" >/dev/null || return 1
  sleep 5
  t0=$(date +%s)
  pg_d run --rm "$IMG" true || { echo "a container could not run during the flood"; return 1; }
  eq "$(pg_d exec e2e-hostlo-flood echo alive)" alive || return 1
  t1=$(date +%s)
  [ $((t1 - t0)) -le 20 ] || { echo "control path took $((t1 - t0)) s during the flood"; return 1; }
  # The flooding container goes away without a FIN reaching the guest (keepalive ends those relays), and the holder,
  # which ignores EOF on purpose, goes too; relays held by a Mac service that never closes end only at VM stop.
  d rm -f e2e-hostlo-flood >/dev/null || return 1
  kill "$HOSTLO_HOLD_PID" 2>/dev/null; HOSTLO_HOLD_PID=""
  parity_gaps_mac_service 127.0.0.1 "$(port 182)" || return 1
  wait_for 75 sh -c "[ \"\$(\"$DOCKER\" run --rm \"$IMG\" wget -q -T 5 -O- http://host.docker.internal:$PG_MAC_PORT/index.html 2>&1)\" = mac-service ]" \
    || { echo "relay slots did not come back after the flood"; return 1; }
}

hostlo_used_kb() { pg_d run --rm "$IMG" df -k / | awk 'NR == 2 { print $3 }'; }

t_host_internal_loopback_relay_does_not_pin_logs() { # finding 7: a relay child holds no other container's files
  local hold before after
  trap hostlo_flood_down EXIT
  hold=$(port 183)
  hostlo_holder "$hold" || return 1
  d run -d --name e2e-hostlo-log "$IMG" sh -c \
    'dd if=/dev/zero bs=1048576 count=200 2>/dev/null | tr "\0" a; echo; echo LOG-DONE; exec sleep 600' >/dev/null || return 1
  wait_for 90 sh -c "[ \"\$(\"$DOCKER\" logs --tail 1 e2e-hostlo-log 2>/dev/null)\" = LOG-DONE ]" || return 1
  # Opened while the 200 MB log is open in the agent, so the relay child is forked with it.
  d run -d --name e2e-hostlo-hold "$IMG" sh -c "sleep 300 | nc host.docker.internal $hold" >/dev/null || return 1
  sleep 3
  before=$(hostlo_used_kb) || return 1
  d rm -f e2e-hostlo-log >/dev/null || return 1
  for _ in $(seq 1 15); do
    after=$(hostlo_used_kb) || return 1
    [ $((before - after)) -ge 150000 ] && return 0
    sleep 1
  done
  echo "removing a 200 MB log freed $((before - after)) KB while a relay stayed open"
  return 1
}

t_add_host_lines_for_ipv6_and_host_gateway() {
  local hosts
  hosts=$(pg_d run --rm --add-host v6:2001:db8::7 --add-host 'v6b:[2001:db8::8]' --add-host mac:host-gateway --add-host host.docker.internal:10.9.8.7 "$IMG" cat /etc/hosts) || return 1
  has "$hosts" "2001:db8::7 v6"
  has "$hosts" "2001:db8::8 v6b"
  has "$hosts" "10.9.8.7 host.docker.internal"
  lacks "$hosts" "host-gateway"
  printf '%s\n' "$hosts" | awk '$2 == "mac" { found = 1; if ($1 !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) bad = 1 } END { exit !(found && !bad) }' \
    || { echo "no IPv4 line for mac in: $hosts"; return 1; }
  [ "$(printf '%s\n' "$hosts" | grep -c 'host.docker.internal')" = 1 ] || { echo "user's host.docker.internal did not replace the default: $hosts"; return 1; }
}
