#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016,SC2086
# E2E checks: host-development-processes-and-shared-names. Sourced by tests/e2e.sh; do not run directly.

# ===================================================================== checks: host development processes and shared names
# Every child and repository is confined to WORK; these checks never use the user's checkout.
dev_setup() {
  DEV_CLI=${NOODLE_CLI:-$ROOT/.build/release/noodle}
  [ -x "$DEV_CLI" ] || skip "noodle CLI not found (set NOODLE_CLI)"
  DEV_DIR=$(mktemp -d "$WORK/dev.XXXXXX"); DEV_PIDS=""
  trap dev_cleanup EXIT
  cat >"$DEV_DIR/server.py" <<'PY'
import base64, hashlib, http.server, json, os, pathlib, signal, sys
root = pathlib.Path(os.environ['DEV_EVIDENCE'])
root.joinpath('env.json').write_text(json.dumps(dict(host=os.environ['HOST'], port=int(os.environ['PORT']), pid=os.getpid())))
def stopped(signum, frame):
    root.joinpath('signal').write_text(str(signum))
    raise SystemExit(128 + signum)
signal.signal(signal.SIGTERM, stopped)
signal.signal(signal.SIGINT, stopped)
if "--ignore-term" in sys.argv: signal.signal(signal.SIGTERM, signal.SIG_IGN)
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def do_GET(self):
        if self.headers.get('Upgrade', '').lower() == 'websocket':
            key = self.headers['Sec-WebSocket-Key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
            self.send_response(101)
            self.send_header('Upgrade', 'websocket'); self.send_header('Connection', 'Upgrade')
            self.send_header('Sec-WebSocket-Accept', base64.b64encode(hashlib.sha1(key.encode()).digest()).decode())
            self.end_headers(); self.wfile.flush()
            head = self.rfile.read(2); length = head[1] & 127
            mask = self.rfile.read(4); data = self.rfile.read(length)
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
            self.wfile.write(bytes([0x81, len(payload)]) + payload); self.wfile.flush()
            return
        body = b'host-dev-ok\n'
        self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args): pass
http.server.ThreadingHTTPServer((os.environ['HOST'], int(os.environ['PORT'])), Handler).serve_forever()
PY
}
dev_cleanup() {
  set +e
  local pid file
  for pid in $DEV_PIDS; do kill -TERM "$pid" 2>/dev/null; done
  for file in "$DEV_DIR"/evidence.*/env.json; do
    [ -f "$file" ] || continue
    pid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$file")
    kill -TERM "$pid" 2>/dev/null
    kill -KILL "$pid" 2>/dev/null
  done
  for pid in $DEV_PIDS; do wait "$pid" 2>/dev/null; done
  rm -rf "$DEV_DIR"
  return 0
}
dev_launch() { # working directory, then exact dev arguments; sets DEV_PID and DEV_EVIDENCE
  local dir=$1; shift
  DEV_EVIDENCE=$(mktemp -d "$DEV_DIR/evidence.XXXXXX")
  ( cd "$dir" && exec env DEV_EVIDENCE="$DEV_EVIDENCE" "$DEV_CLI" dev "$@" ) >"$DEV_EVIDENCE/cli.log" 2>&1 &
  DEV_PID=$!; DEV_PIDS="$DEV_PIDS $DEV_PID"
  wait_for 15 test -s "$DEV_EVIDENCE/env.json"
}
dev_env() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$DEV_EVIDENCE/env.json" "$1"; }
dev_names_has() { names_json | python3 -c 'import json,sys; sys.exit(0 if any(n["host"]==sys.argv[1] for n in json.load(sys.stdin)["names"]) else 1)' "$1"; }
dev_names_lacks() { ! dev_names_has "$1"; }
dev_http() { curl --noproxy '*' -sf --max-time 3 --resolve "$1:$NOODLE_HTTP_PORT:127.0.0.1" "http://$1:$NOODLE_HTTP_PORT/"; }
dev_says_ok() { [ "$(dev_http "$1")" = host-dev-ok ]; }
dev_ready() { wait_for 15 dev_names_has "$1"; wait_for 15 dev_says_ok "$1"; }
dev_stop() { kill -TERM "$DEV_PID"; wait "$DEV_PID" 2>/dev/null || true; }
dev_post() { curl -sf --max-time 5 --unix-socket "$SOCK" -H 'Content-Type: application/json' -d "$1" http://localhost/noodle/dev; }
dev_field() { python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"; }

t_dev_explicit_name_exports_free_loopback_port() {
  dev_setup
  dev_launch "$DEV_DIR" e2e-dev-env -- python3 "$DEV_DIR/server.py"
  eq "$(dev_env host)" 127.0.0.1
  [ "$(dev_env port)" -gt 0 ]; [ "$(dev_env port)" -lt 65536 ]
  dev_ready e2e-dev-env.localhost
  eq "$(curl --noproxy '*' -sf "http://127.0.0.1:$(dev_env port)/")" host-dev-ok
}
t_dev_concurrent_processes_get_distinct_free_ports() {
  dev_setup
  dev_launch "$DEV_DIR" e2e-dev-first -- python3 "$DEV_DIR/server.py"
  dev_ready e2e-dev-first.localhost
  local first; first=$(dev_env port)
  dev_launch "$DEV_DIR" e2e-dev-second -- python3 "$DEV_DIR/server.py"
  dev_ready e2e-dev-second.localhost
  [ "$(dev_env port)" != "$first" ]
  dev_ready e2e-dev-first.localhost
}
t_dev_default_package_name_and_executable_ambiguity() {
  dev_setup
  printf '{"name":"@scope/Package App"}\n' >"$DEV_DIR/package.json"
  dev_launch "$DEV_DIR" python3 "$DEV_DIR/server.py"
  dev_ready package-app.localhost
}
t_dev_default_git_root_name() {
  dev_setup
  local repo=$DEV_DIR/e2e-dev-repo
  mkdir -p "$repo/nested"; git -C "$repo" init -q
  dev_launch "$repo/nested" -- python3 "$DEV_DIR/server.py"
  dev_ready e2e-dev-repo.localhost
}
t_dev_default_folder_name() {
  dev_setup
  local dir=$DEV_DIR/e2e-dev-folder; mkdir -p "$dir"
  dev_launch "$dir" -- python3 "$DEV_DIR/server.py"
  dev_ready e2e-dev-folder.localhost
}
t_dev_worktree_prefix_uses_sanitized_last_branch_segment() {
  dev_setup
  local repo=$DEV_DIR/e2e-dev-main wt=$DEV_DIR/linked
  mkdir -p "$repo"; git -C "$repo" init -q
  git -C "$repo" -c user.name=E2E -c user.email=e2e@example.invalid commit --allow-empty -qm initial
  printf '{"name":"e2e-dev-pkg"}\n' >"$repo/package.json"
  git -C "$repo" add package.json
  git -C "$repo" -c user.name=E2E -c user.email=e2e@example.invalid commit -qm package
  git -C "$repo" worktree add -qb feature/My_Branch "$wt"
  dev_launch "$wt" -- python3 "$DEV_DIR/server.py"
  dev_ready my-branch.e2e-dev-pkg.localhost
  dev_stop
  dev_launch "$wt" e2e-dev-explicit -- python3 "$DEV_DIR/server.py"
  dev_ready my-branch.e2e-dev-explicit.localhost
  dev_stop
  rm "$wt/package.json"
  dev_launch "$wt" -- python3 "$DEV_DIR/server.py"
  dev_ready my-branch.e2e-dev-main.localhost
}
t_dev_explicit_separator_allows_executable_name() {
  dev_setup
  dev_launch "$DEV_DIR" python3 -- python3 "$DEV_DIR/server.py"
  dev_ready python3.localhost
}
t_dev_exit_status_and_registration_removal() {
  dev_setup
  exit_is 37 "$DEV_CLI" dev e2e-dev-exit -- sh -c 'exit 37'
  wait_for 15 dev_names_lacks e2e-dev-exit.localhost
}
t_dev_last_route_removal_closes_both_listeners() {
  dev_setup
  dev_launch "$DEV_DIR" e2e-dev-last -- python3 "$DEV_DIR/server.py"
  dev_ready e2e-dev-last.localhost
  dev_stop
  wait_for 15 dev_names_lacks e2e-dev-last.localhost
  wait_for 15 fails nm_listening "$NOODLE_HTTP_PORT"
  wait_for 15 fails nm_listening "$NOODLE_HTTPS_PORT"
}
t_dev_term_forwards_signal_and_removes_name() {
  dev_setup
  dev_launch "$DEV_DIR" e2e-dev-term -- python3 "$DEV_DIR/server.py"
  dev_ready e2e-dev-term.localhost
  dev_stop
  eq "$(cat "$DEV_EVIDENCE/signal")" 15
  wait_for 15 dev_names_lacks e2e-dev-term.localhost
}
t_dev_term_ignored_by_child_still_unregisters_route() {
  dev_setup
  dev_launch "$DEV_DIR" e2e-dev-ignore-term -- python3 "$DEV_DIR/server.py" --ignore-term
  dev_ready e2e-dev-ignore-term.localhost
  local child; child=$(dev_env pid)
  kill -TERM "$DEV_PID"
  wait_for 5 dev_names_lacks e2e-dev-ignore-term.localhost
  kill -0 "$child"
  # The route belongs to the CLI: an uncooperative child must not keep it published.
  kill -KILL "$child"
  wait "$DEV_PID" 2>/dev/null || true
}
t_dev_int_forwards_signal_and_removes_name() {
  dev_setup
  dev_launch "$DEV_DIR" e2e-dev-int -- python3 "$DEV_DIR/server.py"
  dev_ready e2e-dev-int.localhost
  kill -INT "$DEV_PID"; wait "$DEV_PID" 2>/dev/null || true
  eq "$(cat "$DEV_EVIDENCE/signal")" 2
  wait_for 15 dev_names_lacks e2e-dev-int.localhost
}
t_dev_killed_owner_is_reaped() {
  dev_setup
  dev_launch "$DEV_DIR" e2e-dev-killed -- python3 "$DEV_DIR/server.py"
  dev_ready e2e-dev-killed.localhost
  kill -KILL "$DEV_PID"; wait "$DEV_PID" 2>/dev/null || true
  wait_for 20 dev_names_lacks e2e-dev-killed.localhost
}
t_dev_api_registration_delete_and_collision() {
  dev_setup
  dev_launch "$DEV_DIR" e2e-dev-api -- python3 "$DEV_DIR/server.py"
  dev_ready e2e-dev-api.localhost
  local response token code
  response=$(dev_post "{\"host\":\"e2e-dev-alias.localhost\",\"port\":$(dev_env port),\"ownerPID\":$DEV_PID}")
  token=$(printf '%s' "$response" | dev_field token)
  nonempty "$token"
  eq "$(printf '%s' "$response" | dev_field host)" e2e-dev-alias.localhost
  eq "$(printf '%s' "$response" | dev_field port)" "$NOODLE_HTTP_PORT"
  dev_ready e2e-dev-alias.localhost
  code=$(curl -s --max-time 5 --unix-socket "$SOCK" -o "$DEV_DIR/collision.json" -w '%{http_code}' -H 'Content-Type: application/json' \
    -d "{\"host\":\"e2e-dev-api.localhost\",\"port\":$(dev_env port),\"ownerPID\":$DEV_PID}" http://localhost/noodle/dev)
  eq "$code" 409
  dev_ready e2e-dev-api.localhost
  curl -sf --max-time 5 --unix-socket "$SOCK" -X DELETE "http://localhost/noodle/dev/$token" >/dev/null
  wait_for 15 dev_names_lacks e2e-dev-alias.localhost
  dev_ready e2e-dev-api.localhost
}
t_dev_api_rejects_invalid_host_port_and_owner() {
  dev_setup
  dev_launch "$DEV_DIR" e2e-dev-validation -- python3 "$DEV_DIR/server.py"
  dev_ready e2e-dev-validation.localhost
  local request code
  for request in \
    "{\"host\":\"e2e-dev-invalid.localhost\",\"port\":0,\"ownerPID\":$DEV_PID}" \
    "{\"host\":\"e2e-dev-invalid.localhost\",\"port\":65536,\"ownerPID\":$DEV_PID}" \
    "{\"host\":\"e2e-dev-invalid.localhost\",\"port\":$(dev_env port),\"ownerPID\":0}" \
    "{\"host\":\"e2e-dev-invalid.localhost\",\"port\":$(dev_env port),\"ownerPID\":-1}" \
    "{\"host\":\"e2e-dev-invalid.example.com\",\"port\":$(dev_env port),\"ownerPID\":$DEV_PID}" \
    "{\"host\":\"../e2e-dev-invalid.localhost\",\"port\":$(dev_env port),\"ownerPID\":$DEV_PID}"; do
    code=$(curl -s --max-time 5 --unix-socket "$SOCK" -o "$DEV_DIR/validation.json" -w '%{http_code}' \
      -H 'Content-Type: application/json' -d "$request" http://localhost/noodle/dev)
    eq "$code" 400
  done
  dev_names_lacks e2e-dev-invalid.localhost
  dev_ready e2e-dev-validation.localhost
}
t_names_dev_and_container_collision_keeps_container_reachable() {
  dev_setup
  serve e2e-dev-container --expose 80 --label app.noodle.domain=e2e-dev-shared
  wait_for 20 nm_says_hi --resolve "e2e-dev-shared.localhost:$NOODLE_HTTP_PORT:127.0.0.1" "$(name_url e2e-dev-shared.localhost)"
  local message
  if message=$(cd "$DEV_DIR" && "$DEV_CLI" dev e2e-dev-shared -- python3 "$DEV_DIR/server.py" 2>&1); then   # cwd outside any checkout: dev prefixes names with the worktree name
    echo "dev unexpectedly claimed a container's name"; return 1
  fi
  has "$message" "already in use"
  eq "$(dev_http e2e-dev-shared.localhost)" hi
}
t_names_container_after_dev_collision_gets_suffixed_alias() {
  dev_setup
  dev_launch "$DEV_DIR" e2e-dev-first-owner -- python3 "$DEV_DIR/server.py"
  dev_ready e2e-dev-first-owner.localhost
  serve e2e-dev-late-container --expose 80 --label app.noodle.domain=e2e-dev-first-owner
  local id alias
  id=$(insp e2e-dev-late-container '{{.Id}}')
  alias="e2e-dev-first-owner-${id:0:6}.localhost"
  wait_for 20 nm_says_hi --resolve "$alias:$NOODLE_HTTP_PORT:127.0.0.1" "$(name_url "$alias")"
  dev_ready e2e-dev-first-owner.localhost
  names_json | python3 -c 'import json,sys; assert any(n["host"]==sys.argv[1] and n["containerID"]==sys.argv[2] for n in json.load(sys.stdin)["names"])' "$alias" "$id"
}
t_names_dev_and_container_have_independent_lifetimes() {
  dev_setup
  serve e2e-dev-peer --expose 80
  dev_launch "$DEV_DIR" e2e-dev-alongside -- python3 "$DEV_DIR/server.py"
  dev_ready e2e-dev-alongside.localhost
  wait_for 20 nm_says_hi --resolve "e2e-dev-peer.localhost:$NOODLE_HTTP_PORT:127.0.0.1" "$(name_url e2e-dev-peer.localhost)"
  d rm -f e2e-dev-peer >/dev/null
  wait_for 15 dev_names_lacks e2e-dev-peer.localhost
  dev_ready e2e-dev-alongside.localhost
  serve e2e-dev-peer --expose 80
  dev_stop
  wait_for 15 dev_names_lacks e2e-dev-alongside.localhost
  wait_for 20 nm_says_hi --resolve "e2e-dev-peer.localhost:$NOODLE_HTTP_PORT:127.0.0.1" "$(name_url e2e-dev-peer.localhost)"
}
t_names_dev_https_uses_noodle_ca() {
  dev_setup
  dev_launch "$DEV_DIR" e2e-dev-tls -- python3 "$DEV_DIR/server.py"
  dev_ready e2e-dev-tls.localhost
  local status ca https
  status=$(names_json); ca=$(printf '%s' "$status" | dev_field ca); https=$(printf '%s' "$status" | dev_field httpsPort)
  wait_for 15 test -f "$ca"
  eq "$(curl --noproxy '*' -sf --max-time 5 --resolve "e2e-dev-tls.localhost:$https:127.0.0.1" --cacert "$ca" "https://e2e-dev-tls.localhost:$https/")" host-dev-ok
}
t_names_dev_tls13_and_h2_falls_back_to_http11() {
  dev_setup
  dev_launch "$DEV_DIR" e2e-dev-alpn -- python3 "$DEV_DIR/server.py"
  dev_ready e2e-dev-alpn.localhost
  local status ca https
  status=$(names_json); ca=$(printf '%s' "$status" | dev_field ca); https=$(printf '%s' "$status" | dev_field httpsPort)
  wait_for 15 test -f "$ca"
  # h2 is deliberately unimplemented: negotiation must select the supported HTTP/1.1 protocol.
  python3 - "$ca" "$https" <<'PY'
import http.client, socket, ssl, sys
ctx = ssl.create_default_context(cafile=sys.argv[1]); ctx.minimum_version = ssl.TLSVersion.TLSv1_3
ctx.set_alpn_protocols(['h2', 'http/1.1'])
with ctx.wrap_socket(socket.create_connection(('127.0.0.1', int(sys.argv[2])), timeout=5), server_hostname='e2e-dev-alpn.localhost') as s:
    assert s.version() == 'TLSv1.3', s.version()
    assert s.selected_alpn_protocol() == 'http/1.1', s.selected_alpn_protocol()
    s.sendall(b'GET / HTTP/1.1\r\nHost: e2e-dev-alpn.localhost\r\nConnection: close\r\n\r\n')
    response = http.client.HTTPResponse(s); response.begin()
    assert response.version == 11 and response.status == 200, (response.version, response.status)
    assert response.read() == b'host-dev-ok\n'
PY
}
t_names_dev_websocket_upgrade_echo() {
  dev_setup
  dev_launch "$DEV_DIR" e2e-dev-ws -- python3 "$DEV_DIR/server.py"
  dev_ready e2e-dev-ws.localhost
  local status ca https
  status=$(names_json); ca=$(printf '%s' "$status" | dev_field ca); https=$(printf '%s' "$status" | dev_field httpsPort)
  wait_for 15 test -f "$ca"
  python3 - "$NOODLE_HTTP_PORT" "$https" "$ca" <<'PY'
import base64, hashlib, socket, ssl, sys
key = 'dGhlIHNhbXBsZSBub25jZQ=='
for encrypted in (False, True):
    s = socket.create_connection(('127.0.0.1', int(sys.argv[2 if encrypted else 1])), timeout=5)
    if encrypted:
        context = ssl.create_default_context(cafile=sys.argv[3]); context.set_alpn_protocols(['http/1.1'])
        s = context.wrap_socket(s, server_hostname='e2e-dev-ws.localhost')
    with s:
        s.sendall(('GET /socket HTTP/1.1\r\nHost: e2e-dev-ws.localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: '+key+'\r\n\r\n').encode())
        response = b''
        while not response.endswith(b'\r\n\r\n'):
            byte = s.recv(1)
            assert byte, response
            response += byte
        assert b' 101 ' in response, response
        accept = base64.b64encode(hashlib.sha1((key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest())
        assert accept.lower() in response.lower(), response
        payload = b'noodle-echo'; mask = b'1234'
        s.sendall(bytes([0x81, 0x80 | len(payload)]) + mask + bytes(b ^ mask[i % 4] for i,b in enumerate(payload)))
        stream = s.makefile('rb'); header = stream.read(2)
        assert header == bytes([0x81, len(payload)]), header
        assert stream.read(len(payload)) == payload
        stream.close()
PY
}
t_names_real_compose_restart_and_down() {
  [ -x "$ROOT/build/tools/cli-plugins/docker-compose" ] || skip "compose plugin missing (scripts/fetch-tools.sh)"
  local c; c=$(mkctx)
  cat >"$c/compose.yaml" <<YML
services:
  web:
    image: $IMG
    command:
      - sh
      - -c
      - |
        printf '%s\n' '#!/bin/sh' 'printf "HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\nhi\n"' > /tmp/reply
        chmod +x /tmp/reply
        exec nc -lk -p 80 -e /tmp/reply
    expose: ["80"]
YML
  local dc=(d compose -p e2e-names-compose -f "$c/compose.yaml")
  "${dc[@]}" up -d
  wait_for 30 nm_says_hi --resolve "web.e2e-names-compose.localhost:$NOODLE_HTTP_PORT:127.0.0.1" "$(name_url web.e2e-names-compose.localhost)"
  "${dc[@]}" restart web
  wait_for 30 nm_says_hi --resolve "e2e-names-compose.localhost:$NOODLE_HTTP_PORT:127.0.0.1" "$(name_url e2e-names-compose.localhost)"
  "${dc[@]}" down
  wait_for 15 dev_names_lacks web.e2e-names-compose.localhost
  wait_for 15 dev_names_lacks e2e-names-compose.localhost
}
t_names_daemon_restart_restores_compose_routes() {
  [ -x "$ROOT/build/tools/cli-plugins/docker-compose" ] || skip "compose plugin missing (scripts/fetch-tools.sh)"
  nm_up
  local c=$NM_HOME/compose
  mkdir -p "$c"
  cat >"$c/compose.yaml" <<YML
services:
  web:
    image: $IMG
    restart: unless-stopped
    command:
      - sh
      - -c
      - |
        printf '%s\n' '#!/bin/sh' 'printf "HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\nhi\n"' > /tmp/reply
        chmod +x /tmp/reply
        exec nc -lk -p 80 -e /tmp/reply
    expose: ["80"]
YML
  local dc=(nd compose -p e2e-names-restart -f "$c/compose.yaml")
  "${dc[@]}" up -d
  wait_for 30 nm_says_hi --resolve "web.e2e-names-restart.localhost:$NM_HTTP:127.0.0.1" "http://web.e2e-names-restart.localhost:$NM_HTTP/"
  kill -TERM "$NM_PID"; wait "$NM_PID" || true
  NOODLE_HOME=$NM_HOME NOODLE_MEMORY_MIB=1024 NOODLE_CPUS=2 NOODLE_NAMES_HTTP_PORT=$NM_HTTP NOODLE_NAMES_HTTPS_PORT=$NM_HTTPS \
    NOODLE_HTTP_PORT=$NM_HTTP_FB NOODLE_HTTPS_PORT=$NM_HTTPS_FB "$NOODLED" >>"$NM_HOME/noodled.log" 2>&1 </dev/null &
  NM_PID=$!
  wait_for 60 curl -sf --max-time 2 --unix-socket "$NM_SOCK" http://localhost/_ping
  wait_for 60 nm_says_hi --resolve "web.e2e-names-restart.localhost:$NM_HTTP:127.0.0.1" "http://web.e2e-names-restart.localhost:$NM_HTTP/"
  nm_json | python3 -c 'import json,sys; assert any(n["host"]=="e2e-names-restart.localhost" for n in json.load(sys.stdin)["names"])'
  "${dc[@]}" down
  nm_json | python3 -c 'import json,sys; assert not any(n["host"].endswith("e2e-names-restart.localhost") for n in json.load(sys.stdin)["names"])'
}

