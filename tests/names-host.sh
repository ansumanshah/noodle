#!/usr/bin/env bash
# Names for host processes: `noodle names add` against an isolated daemon (temp HOME and NOODLE_HOME), real loopback HTTP.
# No VM, no root, no hosts file. Run after building: NOODLE_BIN=.build/debug/noodle NOODLED_BIN=.build/debug/noodled tests/names-host.sh
set -euo pipefail
noodle=${NOODLE_BIN:?set NOODLE_BIN to the built noodle executable}
noodled=${NOODLED_BIN:?set NOODLED_BIN to the built noodled executable}
work=$(mktemp -d /tmp/noodle-names-host.XXXXXX)
pids=()
cleanup() {
    for p in "${pids[@]:-}"; do [ -n "$p" ] && { kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true; }; done
    rm -rf "$work"
}
trap cleanup EXIT
mkdir -p "$work/home" "$work/data" "$work/www"
echo hello-from-host > "$work/www/index.html"
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
(cd "$work/www" && exec python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1) &
pids+=($!)
export HOME="$work/home" NOODLE_HOME="$work/data" NOODLE_NO_LAUNCHCTL=1 NOODLE_NO_ACTIVATE=1
export NOODLE_NAMES_HTTP_PORT=0 NOODLE_NAMES_HTTPS_PORT=0 NOODLE_HTTP_PORT=0 NOODLE_HTTPS_PORT=0
start_daemon() {
    "$noodled" >"$work/daemon.log" 2>&1 < /dev/null &
    daemon=$!
    for _ in $(seq 100); do [ -S "$NOODLE_HOME/run/docker.sock" ] && return; sleep 0.1; done
    echo "daemon did not start"; cat "$work/daemon.log"; exit 1
}
start_daemon
for _ in $(seq 50); do curl -s --noproxy '*' --unix-socket "$NOODLE_HOME/run/docker.sock" http://localhost/_ping >/dev/null && break; sleep 0.1; done

"$noodle" names add demo "$port"
"$noodle" names add api.demo "$port"
if "$noodle" names add Bad_Name "$port" 2>/dev/null; then echo "invalid name accepted"; exit 1; fi
json=$("$noodle" names --json)
router=$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert {n["kind"] for n in d["names"]}=={"host"}; print(d["port"])' "$json")

check() {
    out=$(curl -s --noproxy '*' --max-time 10 -w '\n%{http_code}' "http://$1.localhost:$router/")
    echo "curl http://$1.localhost:$router/ -> $(echo "$out" | tail -1) $(echo "$out" | head -1)"
    [ "$(echo "$out" | tail -1)" = 200 ]
}
check demo
check api.demo

# Persistence across a daemon restart.
kill "$daemon"; wait "$daemon" 2>/dev/null || true; rm -f "$NOODLE_HOME/run/docker.sock"
start_daemon
for _ in $(seq 50); do curl -s --noproxy '*' --unix-socket "$NOODLE_HOME/run/docker.sock" http://localhost/_ping >/dev/null && break; sleep 0.1; done
router=$("$noodle" names --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["port"])')
check demo

# Error shape: unknown name is JSON for scripts and HTML for browsers; the hop header is refused.
curl -s --noproxy '*' -H 'Host: nothing.localhost' "http://127.0.0.1:$router/" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["name"]=="nothing.localhost" and d["hint"]'
curl -s --noproxy '*' -H 'Host: nothing.localhost' -H 'Accept: text/html' "http://127.0.0.1:$router/" | grep -q '<h1>'
[ "$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' -H 'Noodle-Hop: 1' "http://demo.localhost:$router/")" = 508 ]

"$noodle" names remove demo
[ "$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' "http://demo.localhost:$router/")" = 404 ]
kill "$daemon"; wait "$daemon" 2>/dev/null || true
echo "names-host: ok"
