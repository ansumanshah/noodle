#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016,SC2086
# E2E checks: search-resume. Sourced by tests/e2e.sh; do not run directly.

# --- docker search and partial blob pull resume (search/resume lane)
# Search needs the real Docker Hub; a missing network skips instead of failing.
t_search_hub_limit_and_official_filter() {
  local out; out=$(timeout 60 "$DOCKER" search alpine 2>&1) || skip "Docker Hub unreachable: $out"
  has "$out" "NAME"; has "$out" "alpine"
  eq "$(timeout 60 "$DOCKER" search --limit 3 --format '{{.Name}}' alpine | count)" 3
  local official; official=$(timeout 60 "$DOCKER" search --filter is-official=true --format '{{.Name}} {{.IsOfficial}}' alpine)
  has "$official" "alpine [OK]"
  lacks "$(printf '%s\n' "$official" | grep -v '\[OK\]' || true)" "/"
  [ "$(timeout 60 "$DOCKER" search --filter stars=1000000000 --format '{{.Name}}' alpine | count)" = 0 ]
}
t_search_failure_is_an_error_not_an_empty_list() {
  # Point the daemon's proxy at a port nobody listens on: the upstream failure must surface as an error.
  local api="curl -sf --unix-socket $SOCK -H Content-Type:application/json" dead; dead=$(port 150)
  # Freeze the local client command before this function returns and EXIT runs.
  # shellcheck disable=SC2064
  trap "$api -X POST http://localhost/noodle/proxy -d '{\"mode\":\"off\",\"exceptions\":[],\"injectIntoContainers\":false}' >/dev/null" EXIT
  $api -X POST http://localhost/noodle/proxy -d "{\"mode\":\"custom\",\"url\":\"http://127.0.0.1:$dead\",\"exceptions\":[],\"injectIntoContainers\":false}" >/dev/null
  local out status=0; out=$(timeout 60 "$DOCKER" search alpine 2>&1) || status=$?
  $api -X POST http://localhost/noodle/proxy -d '{"mode":"off","exceptions":[],"injectIntoContainers":false}' >/dev/null
  [ "$status" != 0 ] || { echo "search against an unreachable Hub succeeded: $out"; return 1; }
  has "$out" "search failed"
  fails timeout 20 "$DOCKER" search --limit 101 alpine
  fails timeout 20 "$DOCKER" search --filter bogus=1 alpine
}

# Registry (real registry:2) behind tests/fault-registry.py. Sets FREF (pull via the proxy), FSUM, FCTRL, FLOG.
fault_setup() { # slot
  local up; up=$(port "$1"); local pp; pp=$(port $(($1 + 1)))
  d run -d --name "e2e-frg$1" -p "$up:5000" registry:2 >/dev/null
  wait_for 30 curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$up/v2/"
  local src="127.0.0.1:$up/e2e/fault" c; c=$(mkctx)
  head -c 4000000 /dev/urandom >"$c/payload"
  printf 'FROM %s\nCOPY payload /payload\n' "$IMG" >"$c/Dockerfile"
  d build -q -t "$src:1" "$c" >/dev/null
  FSUM=$(shasum -a 256 <"$c/payload" | cut -d' ' -f1)
  d push -q "$src:1" >/dev/null
  d rmi "$src:1" >/dev/null
  FCTRL=$WORK/fault-$1.ctl; FLOG=$WORK/fault-$1.log; echo pass >"$FCTRL"; : >"$FLOG"
  python3 "$(dirname "$SELF")/fault-registry.py" --listen "$pp" --upstream "127.0.0.1:$up" --log "$FLOG" --control "$FCTRL" >"$WORK/fault-$1.out" 2>&1 &
  FPID=$!
  trap 'kill $FPID 2>/dev/null; true' EXIT
  wait_for 10 curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$pp/v2/"
  FREF="127.0.0.1:$pp/e2e/fault:1"
  : >"$FLOG"
}
fault_pull() { timeout -k 2 120 "$DOCKER" pull -q "$FREF" >/dev/null 2>&1; }
fault_has_image() { [ -n "$(d images -q "$FREF")" ]; }
fault_partials() { find "$NOODLE_HOME/partial" -name '*.part' -size +0c 2>/dev/null; }
# Blob GETs that asked for a range starting past zero.
fault_ranged() { grep -cE 'blobs/sha256:.* range=bytes=[1-9][0-9]*- ' "$FLOG" || true; }
fault_verify() { eq "$(d run --rm "$FREF" sha256sum /payload 2>/dev/null | cut -d' ' -f1)" "$FSUM" || return 1; d rmi "$FREF" >/dev/null 2>&1 || true; }

t_pull_resumes_after_dropped_connection() {
  fault_setup 130
  echo drop-once >"$FCTRL"
  fault_pull || { echo "pull did not survive one dropped connection"; cat "$FLOG"; return 1; }
  [ "$(fault_ranged)" -ge 1 ] || { echo "retry did not use a Range past zero"; cat "$FLOG"; return 1; }
  has "$(cat "$FLOG")" "dropped after"
  [ -z "$(fault_partials)" ] || { echo "partial left behind after a finished pull"; return 1; }
  fault_verify
}
t_pull_interrupted_leaves_nothing_visible_then_resumes() {
  fault_setup 132
  echo drop-always >"$FCTRL"
  ! fault_pull || { echo "pull succeeded though every download was cut"; return 1; }
  ! fault_has_image || { echo "an interrupted pull left an image in docker images"; return 1; }
  eq "$(d images --format '{{.Repository}}:{{.Tag}}' | grep -cF "$FREF" || true)" 0
  [ -n "$(fault_partials)" ] || { echo "no partial kept for resume"; return 1; }
  echo pass >"$FCTRL"; : >"$FLOG"
  fault_pull || { echo "resume failed"; cat "$FLOG"; return 1; }
  [ "$(fault_ranged)" -ge 1 ] || { echo "resume did not send a Range past zero"; cat "$FLOG"; return 1; }
  has "$(grep -E 'blobs/sha256:.* range=bytes=[1-9]' "$FLOG" | head -1)" "-> 206"
  fault_verify
}
t_pull_server_ignoring_range_restarts_cleanly() {
  fault_setup 134
  echo drop-always >"$FCTRL"
  ! fault_pull || return 1
  [ -n "$(fault_partials)" ] || { echo "no partial kept"; return 1; }
  echo ignore-range >"$FCTRL"; : >"$FLOG"
  fault_pull || { echo "pull against a server that ignores Range failed"; cat "$FLOG"; return 1; }
  has "$(cat "$FLOG")" "range ignored"
  fault_verify
}
t_pull_range_not_satisfiable_discards_partial() {
  fault_setup 136
  echo drop-always >"$FCTRL"
  ! fault_pull || return 1
  echo range-416 >"$FCTRL"; : >"$FLOG"
  fault_pull || { echo "pull after a 416 failed"; cat "$FLOG"; return 1; }
  has "$(cat "$FLOG")" "-> 416"
  fault_verify
}
t_pull_corrupt_partial_is_detected_and_refetched() {
  fault_setup 138
  echo drop-always >"$FCTRL"
  ! fault_pull || return 1
  local part; part=$(fault_partials | head -1); nonempty "$part" "partial file"
  printf 'CORRUPT-CORRUPT-' | dd of="$part" bs=1 seek=1000 conv=notrunc 2>/dev/null
  echo pass >"$FCTRL"; : >"$FLOG"
  fault_pull || { echo "pull with a corrupt partial failed"; cat "$FLOG"; return 1; }
  [ "$(fault_ranged)" -ge 1 ] || { echo "the corrupt partial was not even resumed"; cat "$FLOG"; return 1; }
  # after the ranged attempt failed verification the blob was fetched whole again
  [ "$(grep -c "blobs/sha256:$(basename "$part" .part) range=- " "$FLOG" || true)" -ge 1 ] || { echo "no full refetch after corruption"; cat "$FLOG"; return 1; }
  fault_verify
}
t_pull_partials_are_pruned() {
  fault_setup 140
  echo drop-always >"$FCTRL"
  ! fault_pull || return 1
  [ -n "$(fault_partials)" ] || { echo "no partial kept"; return 1; }
  d image prune -f >/dev/null
  [ -z "$(find "$NOODLE_HOME/partial" -name '*.part' 2>/dev/null)" ] || { echo "image prune left partials"; return 1; }
}

# ---- embedded DNS over TCP and beside a container's own DNS server. Needs dig and dnsmasq, so one test image carries both.
dnsbox() {
  d image inspect e2e/dnsbox:1 >/dev/null 2>&1 && return 0
  local c; c=$(mkctx)
  printf 'FROM %s\nRUN apk add --no-cache bind-tools dnsmasq\n' "$IMG" >"$c/Dockerfile"
  DOCKER_BUILDKIT=0 d build -q -t e2e/dnsbox:1 "$c" >/dev/null
}
dnsbox_up() { # name [run flags...]: a long-lived dnsbox container
  local name=$1; shift
  d run -d --name "$name" "$@" e2e/dnsbox:1 sleep 600 >/dev/null
}
cip() { insp "$1" "{{(index .NetworkSettings.Networks \"$2\").IPAddress}}"; }
t_netdns_tcp_resolves_container_name() {
  dnsbox || return 1
  d network create e2e-dt >/dev/null
  sleeper e2e-dtweb --network e2e-dt
  dnsbox_up e2e-dtcli --network e2e-dt
  local ip; ip=$(cip e2e-dtweb e2e-dt)
  wait_for 20 d exec e2e-dtcli dig +short +tcp +time=3 +tries=1 @127.0.0.11 e2e-dtweb
  eq "$(d exec e2e-dtcli dig +short +tcp @127.0.0.11 e2e-dtweb)" "$ip"
  # Several queries down one connection, and a name that does not exist.
  eq "$(d exec e2e-dtcli dig +short +tcp +keepopen +time=3 @127.0.0.11 e2e-dtweb e2e-dtweb | sort -u)" "$ip"
  has "$(d exec e2e-dtcli dig +tcp +time=3 +tries=1 @127.0.0.11 e2e-no-such-host.invalid)" "status:"
  # The UDP path still works beside it.
  eq "$(d exec e2e-dtcli dig +short +notcp @127.0.0.11 e2e-dtweb)" "$ip"
}
t_netdns_truncated_answer_falls_back_to_tcp() {
  dnsbox || return 1
  d network create e2e-dz >/dev/null
  local txt='' i
  for i in 1 2 3 4 5 6 7 8; do txt="$txt,$(printf 'x%.0s' $(seq 1 240))$i"; done
  # A DNS server whose TXT answer is about 2 KB: over every UDP size a client advertises.
  dnsbox_up e2e-dzsrv --network e2e-dz
  d exec -d e2e-dzsrv dnsmasq -k --no-hosts --no-resolv --user=root --txt-record="big.test$txt" --address=/small.test/10.9.8.7
  local sip; sip=$(cip e2e-dzsrv e2e-dz)
  dnsbox_up e2e-dzcli --network e2e-dz --dns "$sip"
  wait_for 20 d exec e2e-dzcli dig +short +time=2 +tries=1 @127.0.0.11 small.test
  # Without the TCP retry the client sees the truncated flag.
  has "$(d exec e2e-dzcli dig +ignore +time=3 +tries=1 @127.0.0.11 big.test TXT)" " tc"
  # With it (dig's default) the whole answer arrives, through the embedded resolver, over TCP.
  # (one TXT record of 8 strings: dig prints it on one line, strings separated by '" "')
  eq "$(d exec e2e-dzcli sh -c 'dig +time=3 +tries=1 @127.0.0.11 big.test TXT +short | grep -o "\" \"" | wc -l' | tr -d ' ')" 7
  eq "$(d exec e2e-dzcli sh -c 'dig +tcp +time=3 +tries=1 @127.0.0.11 big.test TXT +short | grep -o "\" \"" | wc -l' | tr -d ' ')" 7
}
t_netdns_container_dns_server_on_port_53() {
  dnsbox || return 1
  d network create e2e-do >/dev/null
  dnsbox_up e2e-dopeer --network e2e-do
  dnsbox_up e2e-doown --network e2e-do
  d exec -d e2e-doown dnsmasq -k --no-hosts --no-resolv --user=root --address=/own.test/10.9.8.7
  local oip pip; oip=$(cip e2e-doown e2e-do); pip=$(cip e2e-dopeer e2e-do)
  wait_for 20 d exec e2e-doown dig +short +time=1 +tries=1 @127.0.0.1 own.test
  # The container's server answers its own queries, over UDP and TCP, on every address it listens on.
  eq "$(d exec e2e-doown dig +short +time=2 +tries=1 @127.0.0.1 own.test)" 10.9.8.7
  eq "$(d exec e2e-doown dig +short +tcp +time=2 +tries=1 @127.0.0.1 own.test)" 10.9.8.7
  eq "$(d exec e2e-doown dig +short +time=2 +tries=1 @"$oip" own.test)" 10.9.8.7
  # Embedded DNS still resolves names for it and for its peers.
  eq "$(d exec e2e-doown dig +short +time=2 +tries=1 @127.0.0.11 e2e-dopeer)" "$pip"
  eq "$(d exec e2e-doown dig +short +tcp +time=2 +tries=1 @127.0.0.11 e2e-dopeer)" "$pip"
  eq "$(d exec e2e-doown getent hosts e2e-dopeer | cut -d' ' -f1)" "$pip"
  eq "$(d exec e2e-dopeer dig +short +time=2 +tries=1 @127.0.0.11 e2e-doown)" "$oip"
  eq "$(d exec e2e-dopeer dig +short +time=2 +tries=1 @"$oip" own.test)" 10.9.8.7
}

