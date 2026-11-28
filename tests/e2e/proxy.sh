#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016,SC2086
# E2E checks: registry and container proxy settings. Sourced by tests/e2e.sh; do not run directly.

# Each proxy check gets its own persisted settings and deterministic system proxy
# dictionary. No host network preferences are modified.
px_up() {
  [ -n "${NOODLED:-}" ] && [ -x "$NOODLED" ] || { echo 'noodled required'; return 1; }
  PX_HOME=$(mktemp -d /tmp/noodle-px.XXXXXX)
  PX_SOCK=$PX_HOME/run/docker.sock
  PX_SYSTEM=$PX_HOME/system-proxy.json
  PX_PID=''; PX_SERVER=''
  trap px_down EXIT
  mkdir -p "$PX_HOME/boot"
  local f
  for f in vmlinux initramfs.cpio.gz; do
    [ ! -f "$RES/$f" ] || { cp -c "$RES/$f" "$PX_HOME/boot/$f" 2>/dev/null || cp "$RES/$f" "$PX_HOME/boot/$f"; }
  done
  printf '{}\n' >"$PX_SYSTEM"
  [ -z "${1:-}" ] || printf '%s\n' "$1" >"$PX_HOME/proxy.json"
  NOODLE_HOME=$PX_HOME NOODLE_TEST_SYSTEM_PROXY_FILE=$PX_SYSTEM NOODLE_MEMORY_MIB=1024 NOODLE_CPUS=2 \
    NOODLE_NAMES_HTTP_PORT=0 NOODLE_NAMES_HTTPS_PORT=0 "$NOODLED" >"$PX_HOME/noodled.log" 2>&1 &
  PX_PID=$!
  wait_for 60 curl -sf --max-time 2 --unix-socket "$PX_SOCK" http://localhost/_ping
  timeout -k 5 60 "$DOCKER" save "$IMG" >"$PX_HOME/image.tar"
  pd load -i "$PX_HOME/image.tar" >/dev/null
}

px_down() {
  set +e
  [ -z "${PX_SERVER:-}" ] || kill "$PX_SERVER" 2>/dev/null
  if [ -n "${PX_PID:-}" ]; then
    kill -TERM "$PX_PID" 2>/dev/null
    local n
    for n in $(seq 1 20); do kill -0 "$PX_PID" 2>/dev/null || break; sleep 0.5; done
    kill -KILL "$PX_PID" 2>/dev/null
    wait "$PX_PID" 2>/dev/null
  fi
  [ -z "${PX_HOME:-}" ] || rm -rf "$PX_HOME"
  return 0
}

pd() { DOCKER_HOST=unix://$PX_SOCK timeout -k 5 60 "$DOCKER" "$@"; }

px_set() { curl -sf --max-time 10 --unix-socket "$PX_SOCK" -H Content-Type:application/json -X POST http://localhost/noodle/proxy -d "$1"; }

px_env() { pd inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1"; }

px_no_env() {
  local envs; envs=$(px_env "$1") || { echo "inspect of $1 failed"; return 1; }
  [ -n "$envs" ] || { echo "no environment returned for $1"; return 1; }
  ! printf '%s\n' "$envs" | grep -E '^(http_proxy|https_proxy|no_proxy|HTTP_PROXY|HTTPS_PROXY|NO_PROXY)='
}

px_six() {
  local envs=$1 http=$2 https=$3 bypass=$4 key
  for key in HTTP_PROXY http_proxy; do has "$envs" "$key=$http"; done
  for key in HTTPS_PROXY https_proxy; do has "$envs" "$key=$https"; done
  for key in NO_PROXY no_proxy; do
    local value; value=$(printf '%s\n' "$envs" | sed -n "s/^$key=//p")
    has "$value" "$bypass"
  done
}

t_proxy_registry_custom_exceptions_off() {
  d() { timeout -k 5 60 "$DOCKER" "$@"; }
  authreg 7
  local pp; pp=$(port 8) log=$WORK/proxy.log; : >"$log"
  cat >"$WORK/proxy.py" <<'PYTHON'
import base64, http.client, http.server, sys, threading, urllib.parse
PORT, LOG, WANT = int(sys.argv[1]), sys.argv[2], sys.argv[3]
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def handle_one(self):
        auth = self.headers.get("Proxy-Authorization", "")
        ok = auth == "Basic " + base64.b64encode(WANT.encode()).decode()
        with open(LOG, "a") as f: f.write(("OK " if ok else "DENY ") + self.command + " " + self.path + "\n")
        if not ok:
            self.send_response(407); self.send_header("Proxy-Authenticate", 'Basic realm="e2e"')
            self.send_header("Content-Length", "0"); self.end_headers(); return
        u = urllib.parse.urlsplit(self.path)
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else None
        c = http.client.HTTPConnection(u.hostname, u.port or 80, timeout=60)
        hdrs = {k: v for k, v in self.headers.items() if k.lower() not in ("proxy-authorization", "proxy-connection", "connection")}
        c.request(self.command, u.path + ("?" + u.query if u.query else ""), body, hdrs)
        r = c.getresponse(); data = r.read()
        self.send_response(r.status)
        for k, v in r.getheaders():
            if k.lower() not in ("transfer-encoding", "connection", "content-length"): self.send_header(k, v)
        self.send_header("Content-Length", str(len(data))); self.end_headers()
        if self.command != "HEAD": self.wfile.write(data)
    do_GET = do_PUT = do_POST = do_PATCH = do_HEAD = do_DELETE = handle_one
    def do_CONNECT(self):
        with open(LOG, "a") as f: f.write("CONNECT " + self.path + "\n")
        self.send_response(502); self.send_header("Content-Length", "0"); self.end_headers()
http.server.ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
PYTHON
  python3 "$WORK/proxy.py" "$pp" "$log" "proxyuser:proxy-secret-7q" &
  local srv=$!
  # shellcheck disable=SC2064  # srv is a local that is gone when the EXIT trap runs
  trap "kill $srv 2>/dev/null || true" EXIT
  wait_for 10 curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$pp/"
  d login -u "$RUSER" -p "$RPASS" "$REG" >/dev/null
  d tag "$IMG" "$REG/e2e/px:1"
  d push -q "$REG/e2e/px:1" >/dev/null
  d rmi "$REG/e2e/px:1" >/dev/null
  local api="curl -sf --max-time 10 --unix-socket $SOCK -H Content-Type:application/json"
  # default (system): the daemon does not use our test proxy
  d pull -q "$REG/e2e/px:1" >/dev/null; d rmi "$REG/e2e/px:1" >/dev/null
  eq "$(grep -c '^OK' "$log")" 0
  # custom with credentials: registry traffic goes through the proxy
  $api -X POST http://localhost/noodle/proxy -d "{\"mode\":\"custom\",\"url\":\"http://proxyuser:proxy-secret-7q@127.0.0.1:$pp\",\"exceptions\":[],\"injectIntoContainers\":false}" >"$WORK/proxy.set"
  lacks "$(cat "$WORK/proxy.set")" "proxy-secret-7q"
  lacks "$($api http://localhost/noodle/proxy)" "proxy-secret-7q"
  d pull -q "$REG/e2e/px:1" >/dev/null
  [ "$(grep -c '^OK' "$log")" -ge 3 ] || { echo "registry traffic bypassed the proxy"; cat "$log"; return 1; }
  d push -q "$REG/e2e/px:1" >/dev/null
  d search --limit 1 alpine >/dev/null 2>&1 || true
  # exception: the registry host skips the proxy
  local n; n=$(grep -c '^OK' "$log")
  $api -X POST http://localhost/noodle/proxy -d "{\"mode\":\"custom\",\"url\":\"http://proxyuser:***@127.0.0.1:$pp\",\"exceptions\":[\"127.0.0.1\"],\"injectIntoContainers\":false}" >/dev/null
  d rmi "$REG/e2e/px:1" >/dev/null; d pull -q "$REG/e2e/px:1" >/dev/null
  eq "$(grep -c '^OK' "$log")" "$n"
  # off
  $api -X POST http://localhost/noodle/proxy -d '{"mode":"off","exceptions":[],"injectIntoContainers":false}' >/dev/null
  d rmi "$REG/e2e/px:1" >/dev/null; d pull -q "$REG/e2e/px:1" >/dev/null
  eq "$(grep -c '^OK' "$log")" "$n"
  # wrong proxy password: the pull fails instead of falling back
  $api -X POST http://localhost/noodle/proxy -d "{\"mode\":\"custom\",\"url\":\"http://proxyuser:nope@127.0.0.1:$pp\",\"exceptions\":[]}" >/dev/null
  d rmi "$REG/e2e/px:1" >/dev/null
  fails d pull -q "$REG/e2e/px:1"
  # injection uses a credential-free URL; registry-only credentials must never enter containers
  $api -X POST http://localhost/noodle/proxy -d "{\"mode\":\"custom\",\"url\":\"http://192.0.2.10:$pp\",\"exceptions\":[\"*.corp.test\"],\"injectIntoContainers\":true}" >/dev/null
  d create --name e2e-pxc "$IMG" true >/dev/null
  local envs; envs=$(insp e2e-pxc '{{json .Config.Env}}')
  has "$envs" "HTTP_PROXY=http://192.0.2.10:$pp"
  has "$envs" ".corp.test"
  lacks "$envs" "proxy-secret-7q"
  d create --name e2e-pxc2 -e HTTP_PROXY=http://mine:1 "$IMG" true >/dev/null
  has "$(insp e2e-pxc2 '{{json .Config.Env}}')" "HTTP_PROXY=http://mine:1"
  # nothing sensitive in logs, the stored file is private
  lacks "$(cat "$NOODLE_HOME/noodled.log" 2>/dev/null)" "proxy-secret-7q"
  eq "$(stat -f %Lp "$NOODLE_HOME/proxy.json")" 600
  $api -X POST http://localhost/noodle/proxy -d '{"mode":"system","exceptions":[],"injectIntoContainers":false}' >/dev/null
  kill "$srv" 2>/dev/null || true
  d logout "$REG" >/dev/null
}

t_proxy_injection_opt_in_user_values_snapshot_and_off() {
  px_up
  pd create --name e2e-px-default "$IMG" true >/dev/null
  px_no_env e2e-px-default
  px_set '{"mode":"custom","url":"http://192.0.2.10:18281","exceptions":["*.corp.test"],"injectIntoContainers":true}' >/dev/null
  pd create --name e2e-px-injected "$IMG" true >/dev/null
  px_six "$(px_env e2e-px-injected)" http://192.0.2.10:18281 http://192.0.2.10:18281 .corp.test
  pd create --name e2e-px-user -e HTTP_PROXY=upper-http -e http_proxy=lower-http \
    -e HTTPS_PROXY=upper-https -e https_proxy=lower-https -e NO_PROXY=upper-no -e no_proxy=lower-no "$IMG" true >/dev/null
  local envs; envs=$(px_env e2e-px-user)
  has "$envs" HTTP_PROXY=upper-http; has "$envs" http_proxy=lower-http
  has "$envs" HTTPS_PROXY=upper-https; has "$envs" https_proxy=lower-https
  has "$envs" NO_PROXY=upper-no; has "$envs" no_proxy=lower-no
  px_set '{"mode":"off","injectIntoContainers":true}' >/dev/null
  pd create --name e2e-px-off "$IMG" true >/dev/null
  px_no_env e2e-px-off
  px_six "$(px_env e2e-px-injected)" http://192.0.2.10:18281 http://192.0.2.10:18281 .corp.test
}

t_proxy_system_dictionary_refresh_registry_exceptions() {
  px_up
  local pp; pp=$(port 81)
  # Registry traffic runs on the Mac and can use a loopback-bound proxy.
  cat >"$PX_HOME/endpoint.py" <<'PYTHON'
import http.client, http.server, sys, urllib.parse
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith('http://127.0.0.1:'):
            with open(sys.argv[2], 'a') as log: log.write(self.path + '\n')
            u = urllib.parse.urlsplit(self.path)
            c = http.client.HTTPConnection(u.hostname, u.port, timeout=10)
            c.request(self.command, u.path + ('?' + u.query if u.query else ''), headers={k: v for k, v in self.headers.items() if k.lower() not in ('connection', 'proxy-connection')})
            r = c.getresponse(); data = r.read()
            self.send_response(r.status)
            for k, v in r.getheaders():
                if k.lower() not in ('content-length', 'transfer-encoding', 'connection'): self.send_header(k, v)
            self.send_header('Content-Length', str(len(data))); self.end_headers()
            if self.command != 'HEAD': self.wfile.write(data)
            return
        body = b'proxy-reached' if self.path == 'http://proxy-test.invalid/check' else b'wrong-path'
        self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
    do_HEAD = do_GET
    def log_message(self, *args): pass
http.server.ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
PYTHON
  python3 "$PX_HOME/endpoint.py" "$pp" "$PX_HOME/registry-proxy.log" & PX_SERVER=$!
  wait_for 10 curl -sf --max-time 2 "http://127.0.0.1:$pp/"
  printf '{"HTTPEnable":1,"HTTPProxy":"127.0.0.1","HTTPPort":%s,"HTTPSEnable":1,"HTTPSProxy":"localhost","HTTPSPort":%s}\n' "$pp" "$pp" >"$PX_SYSTEM"
  px_set '{"mode":"system","injectIntoContainers":false}' >/dev/null
  pd create --name e2e-px-system "$IMG" true >/dev/null
  px_no_env e2e-px-system
  # Registry sessions must take the same fresh system snapshot as creates.
  d() { timeout -k 5 60 "$DOCKER" "$@"; }
  authreg 82
  d login -u "$RUSER" -p "$RPASS" "$REG" >/dev/null
  d tag "$IMG" "$REG/e2e/system-proxy:1"
  d push -q "$REG/e2e/system-proxy:1" >/dev/null
  pd login -u "$RUSER" -p "$RPASS" "$REG" >/dev/null
  pd pull -q "$REG/e2e/system-proxy:1" >/dev/null
  [ -s "$PX_HOME/registry-proxy.log" ] || { echo 'system registry pull bypassed proxy'; return 1; }
  local requests; requests=$(wc -l <"$PX_HOME/registry-proxy.log" | tr -d ' ')
  # A later request sees a system exception and bypasses the proxy.
  printf '{"HTTPEnable":1,"HTTPProxy":"127.0.0.1","HTTPPort":%s,"ExceptionsList":["127.0.0.1"]}\n' "$pp" >"$PX_SYSTEM"
  pd rmi "$REG/e2e/system-proxy:1" >/dev/null
  pd pull -q "$REG/e2e/system-proxy:1" >/dev/null
  eq "$(wc -l <"$PX_HOME/registry-proxy.log" | tr -d ' ')" "$requests"
  printf '{}\n' >"$PX_SYSTEM"
  pd rmi "$REG/e2e/system-proxy:1" >/dev/null
  pd pull -q "$REG/e2e/system-proxy:1" >/dev/null
  eq "$(wc -l <"$PX_HOME/registry-proxy.log" | tr -d ' ')" "$requests"
  d logout "$REG" >/dev/null
  # Injection preserves non-loopback addresses and separate HTTP and HTTPS endpoints.
  printf '{"HTTPEnable":1,"HTTPProxy":"192.0.2.10","HTTPPort":3128,"HTTPSEnable":1,"HTTPSProxy":"192.0.2.11","HTTPSPort":3129,"ExceptionsList":["*.corp.test"]}\n' >"$PX_SYSTEM"
  px_set '{"mode":"system","injectIntoContainers":true}' >/dev/null
  pd create --name e2e-px-system-injected "$IMG" true >/dev/null
  px_six "$(px_env e2e-px-system-injected)" http://192.0.2.10:3128 http://192.0.2.11:3129 .corp.test
  printf '{}\n' >"$PX_SYSTEM"
  pd create --name e2e-px-system-direct "$IMG" true >/dev/null
  px_no_env e2e-px-system-direct
  px_six "$(px_env e2e-px-system-injected)" http://192.0.2.10:3128 http://192.0.2.11:3129 .corp.test
}

t_proxy_loopback_injection_refused() {
  px_up
  local host code message
  message="containers cannot reach a loopback-only proxy; listen on a non-loopback address or set proxy variables per container"
  # Registry-only use is allowed; automatic injection must refuse each loopback form.
  for host in localhost localhost. app.localhost 127.0.0.1 127.12.34.56 127.1 2130706433 '[::1]' '[0:0:0:0:0:0:0:1]' '[::ffff:127.0.0.1]'; do
    px_set "{\"mode\":\"custom\",\"url\":\"http://$host:3128\",\"injectIntoContainers\":false}" >/dev/null
    code=$(curl -s --max-time 10 --unix-socket "$PX_SOCK" -H Content-Type:application/json -X POST http://localhost/noodle/proxy \
      -d "{\"mode\":\"custom\",\"url\":\"http://$host:3128\",\"injectIntoContainers\":true}" -o "$PX_HOME/loopback-error" -w '%{http_code}')
    eq "$code" 400
    has "$(cat "$PX_HOME/loopback-error")" "$message"
  done
  pd create --name e2e-px-loopback-registry-only "$IMG" true >/dev/null
  px_no_env e2e-px-loopback-registry-only
  # Explicit per-container values remain the caller's choice when injection is off.
  pd create --name e2e-px-explicit-loopback -e HTTP_PROXY=http://127.0.0.1:3128 "$IMG" true >/dev/null
  has "$(px_env e2e-px-explicit-loopback)" HTTP_PROXY=http://127.0.0.1:3128
  # A system proxy may change after injection was enabled, so create validates again.
  px_set '{"mode":"system","injectIntoContainers":true}' >/dev/null
  printf '{"HTTPEnable":1,"HTTPProxy":"127.0.0.1","HTTPPort":3128}\n' >"$PX_SYSTEM"
  if pd create --name e2e-px-system-loopback "$IMG" true >"$PX_HOME/system-create-error" 2>&1; then
    echo 'system loopback proxy injection unexpectedly succeeded'; return 1
  fi
  has "$(cat "$PX_HOME/system-create-error")" "$message"
  eq "$(pd ps -aq --filter name=e2e-px-system-loopback)" ''
  code=$(curl -s --max-time 10 --unix-socket "$PX_SOCK" -H Content-Type:application/json -X POST http://localhost/noodle/proxy \
    -d '{"mode":"system","injectIntoContainers":true}' -o "$PX_HOME/system-set-error" -w '%{http_code}')
  eq "$code" 400
  has "$(cat "$PX_HOME/system-set-error")" "$message"
}

t_proxy_legacy_loopback_injection_rejected_on_create() {
  px_up '{"mode":"custom","url":"http://127.0.0.1:3128","injectIntoContainers":true}'
  if pd create --name e2e-px-legacy-loopback "$IMG" true >"$PX_HOME/create-error" 2>&1; then
    echo 'legacy loopback proxy injection unexpectedly succeeded'; return 1
  fi
  has "$(cat "$PX_HOME/create-error")" 'containers cannot reach a loopback-only proxy'
  has "$(cat "$PX_HOME/create-error")" 'listen on a non-loopback address or set proxy variables per container'
  eq "$(pd ps -aq --filter name=e2e-px-legacy-loopback)" ''
}

t_proxy_cli_settings_round_trip_rejects_credentials() {
  px_up
  local cli=${NOODLE_CLI:-${NOODLE:-$(dirname "$NOODLED")/noodle}} out
  [ -x "$cli" ] || { echo 'noodle CLI required for proxy settings check'; return 1; }
  out=$(NOODLE_HOME=$PX_HOME timeout -k 5 30 "$cli" proxy --json)
  printf '%s' "$out" | python3 -c 'import json,sys; s=json.load(sys.stdin); assert s["mode"] == "system"; assert s["injectIntoContainers"] is False'
  printf '%s\n' '{"mode":"custom","url":"http://192.0.2.10:18283","exceptions":["*.cli.test"],"injectIntoContainers":true}' | \
    NOODLE_HOME=$PX_HOME timeout -k 5 30 "$cli" proxy set --stdin >"$PX_HOME/cli-set"
  out=$(NOODLE_HOME=$PX_HOME timeout -k 5 30 "$cli" proxy)
  printf '%s' "$out" | python3 -c 'import json,sys; s=json.load(sys.stdin); assert s["mode"] == "custom"; assert s["injectIntoContainers"] is True; assert s["url"] == "http://192.0.2.10:18283"'
  pd create --name e2e-px-cli "$IMG" true >/dev/null
  px_six "$(px_env e2e-px-cli)" http://192.0.2.10:18283 http://192.0.2.10:18283 .cli.test
  if printf '%s\n' '{"mode":"custom","url":"http://localhost:3128","injectIntoContainers":true}' | \
      NOODLE_HOME=$PX_HOME timeout -k 5 30 "$cli" proxy set --stdin >"$PX_HOME/cli-loopback" 2>&1; then
    echo 'CLI accepted loopback proxy injection'; return 1
  fi
  has "$(cat "$PX_HOME/cli-loopback")" 'containers cannot reach a loopback-only proxy'
  has "$(cat "$PX_HOME/cli-loopback")" 'listen on a non-loopback address or set proxy variables per container'
  printf '%s\n' '{"mode":"custom","url":"http://cli-proxy-user:cli-proxy-secret-27@127.0.0.1:18283","exceptions":[],"injectIntoContainers":false}' | \
    NOODLE_HOME=$PX_HOME timeout -k 5 30 "$cli" proxy set --stdin >"$PX_HOME/cli-private-set"
  out=$(NOODLE_HOME=$PX_HOME timeout -k 5 30 "$cli" proxy --json)
  lacks "$out" cli-proxy-user; lacks "$out" cli-proxy-secret-27
  lacks "$(cat "$PX_HOME/cli-private-set")" cli-proxy-user
  lacks "$(cat "$PX_HOME/cli-private-set")" cli-proxy-secret-27
  if printf '%s\n' '{"mode":"custom","url":"http://cli-proxy-user:cli-proxy-secret-27@127.0.0.1:18283","exceptions":[],"injectIntoContainers":true}' | \
      NOODLE_HOME=$PX_HOME timeout -k 5 30 "$cli" proxy set --stdin >"$PX_HOME/cli-rejected" 2>&1; then
    echo 'CLI accepted credentialed injection'; return 1
  fi
  lacks "$(cat "$PX_HOME/cli-rejected")" cli-proxy-user
  lacks "$(cat "$PX_HOME/cli-rejected")" cli-proxy-secret-27
  # Rejected settings leave the previous registry-only choice intact.
  out=$(NOODLE_HOME=$PX_HOME timeout -k 5 30 "$cli" proxy --json)
  printf '%s' "$out" | python3 -c 'import json,sys; s=json.load(sys.stdin); assert s["injectIntoContainers"] is False'
  pd create --name e2e-px-cli-private "$IMG" true >/dev/null
  px_no_env e2e-px-cli-private
}

t_proxy_legacy_credentialed_injection_rejected_on_create() {
  # Settings saved by an older daemon must also pass create-time validation.
  px_up '{"mode":"custom","url":"http://legacyuser:legacy-proxy-secret-51@127.0.0.1:1","exceptions":[],"injectIntoContainers":true}'
  if pd create --name e2e-px-legacy "$IMG" true >"$PX_HOME/create-failure" 2>&1; then
    echo 'legacy credentialed injection unexpectedly created a container'; return 1
  fi
  lacks "$(cat "$PX_HOME/create-failure")" legacy-proxy-secret-51
  eq "$(pd ps -aq --filter name=e2e-px-legacy)" ''
  lacks "$(cat "$PX_HOME/noodled.log")" legacy-proxy-secret-51
}

t_proxy_credentials_rejected_for_injection_and_failures_scrubbed() {
  px_up
  local code body secret=proxy-secret-e2e-93
  body="{\"mode\":\"custom\",\"url\":\"http://proxyuser:$secret@127.0.0.1:1\",\"injectIntoContainers\":true}"
  code=$(curl -s --max-time 10 --unix-socket "$PX_SOCK" -H Content-Type:application/json -X POST http://localhost/noodle/proxy -d "$body" -o "$PX_HOME/rejected" -w '%{http_code}')
  eq "$code" 400
  lacks "$(cat "$PX_HOME/rejected")" "$secret"
  px_set "{\"mode\":\"custom\",\"url\":\"http://proxyuser:$secret@127.0.0.1:1\",\"injectIntoContainers\":false}" >/dev/null
  pd create --name e2e-px-private "$IMG" true >/dev/null
  px_no_env e2e-px-private
  if pd pull 127.0.0.1:1/e2e/proxy-failure:latest >"$PX_HOME/failure" 2>&1; then echo 'pull unexpectedly succeeded'; return 1; fi
  lacks "$(cat "$PX_HOME/failure")" "$secret"
  lacks "$(pd inspect e2e-px-private)" "$secret"
  lacks "$(pd events --since 0 --until "$(date +%s)")" "$secret"
  lacks "$(cat "$PX_HOME/noodled.log")" "$secret"
  local cli=${NOODLE_CLI:-${NOODLE:-$(dirname "$NOODLED")/noodle}}
  [ -x "$cli" ] || { echo 'noodle CLI required for diagnostics secrecy check'; return 1; }
  lacks "$(NOODLE_HOME=$PX_HOME timeout -k 5 30 "$cli" logs)" "$secret"
  NOODLE_HOME=$PX_HOME timeout -k 5 30 "$cli" diagnostics -o "$PX_HOME/diagnostics.tar.gz" >/dev/null
  mkdir "$PX_HOME/diagnostics"
  tar -xzf "$PX_HOME/diagnostics.tar.gz" -C "$PX_HOME/diagnostics"
  if rg -l --fixed-strings "$secret" "$PX_HOME/diagnostics"; then echo 'proxy credential leaked into diagnostics'; return 1; fi
}
