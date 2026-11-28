#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016,SC2086
# E2E checks: local-names-and-ssh-agent. Sourced by tests/e2e.sh; do not run directly.

# ===================================================================== checks: local names and SSH agent (mac lane)
name_url() { echo "http://$1:$NOODLE_HTTP_PORT/"; }
names_json() { curl -sf --max-time 5 --unix-socket "$SOCK" http://localhost/noodle/names; }
t_names_container_name_serves_http() {
  serve e2e-nm-basic --expose 80
  wait_for 20 test "$(curl -sf --max-time 3 "$(name_url e2e-nm-basic.localhost)")" = hi
  eq "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 -H 'Host: nobody.localhost' "http://127.0.0.1:$NOODLE_HTTP_PORT/")" 404
}
t_names_compose_and_custom_domain() {
  serve e2e-nm-web --expose 80 --label com.docker.compose.project=e2eproj --label com.docker.compose.service=web --label app.noodle.domain=e2e-custom
  wait_for 20 test "$(curl -sf --max-time 3 "$(name_url web.e2eproj.localhost)")" = hi
  eq "$(curl -sf --max-time 3 "$(name_url e2eproj.localhost)")" hi
  eq "$(curl -sf --max-time 3 "$(name_url e2e-custom.localhost)")" hi
}
t_names_label_port_without_published_port() {
  d run -d --name e2e-nm-port --label app.noodle.http.port=8080 "$IMG" sh -c '
    printf "%s\n" "#!/bin/sh" '\''printf "HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\nok8\n"'\'' > /tmp/r; chmod +x /tmp/r
    exec nc -lk -p 8080 -e /tmp/r' >/dev/null
  wait_for 20 test "$(curl -sf --max-time 3 "$(name_url e2e-nm-port.localhost)")" = ok8
}
t_names_collision_keeps_both_reachable() {
  serve e2e-nm-one --expose 80 --label app.noodle.domain=e2e-dup
  wait_for 20 test "$(curl -sf --max-time 3 "$(name_url e2e-dup.localhost)")" = hi
  sleep 1
  serve e2e-nm-two --expose 80 --label app.noodle.domain=e2e-dup
  local id2; id2=$(insp e2e-nm-two '{{.Id}}')
  wait_for 20 test "$(curl -sf --max-time 3 "$(name_url "e2e-dup-${id2:0:6}.localhost")")" = hi
  # The first owner keeps the plain host; the second got the suffixed one (checked above). JSON key order is not stable.
  names_json | python3 -c 'import json,sys; id=sys.argv[1]; sys.exit(0 if any(n["host"]=="e2e-dup.localhost" and n["containerID"]==id for n in json.load(sys.stdin)["names"]) else 1)' "$(insp e2e-nm-one '{{.Id}}')"
}
t_names_stop_restart_remove() {
  serve e2e-nm-cycle --expose 80
  wait_for 20 test "$(curl -sf --max-time 3 "$(name_url e2e-nm-cycle.localhost)")" = hi
  d stop -t 1 e2e-nm-cycle >/dev/null
  # the only named container stopped: the listener is gone, not just the name
  wait_for 10 fails curl -s --max-time 2 "$(name_url e2e-nm-cycle.localhost)"
  d start e2e-nm-cycle >/dev/null
  wait_for 20 test "$(curl -sf --max-time 3 "$(name_url e2e-nm-cycle.localhost)")" = hi
  d rm -f e2e-nm-cycle >/dev/null
  wait_for 10 fails curl -s --max-time 2 "$(name_url e2e-nm-cycle.localhost)"
}
t_names_no_listener_without_named_container() {
  sleeper e2e-nm-idle
  fails curl -s --max-time 2 "http://127.0.0.1:$NOODLE_HTTP_PORT/"
}
# Standard-port names (80/443 on the wildcard address). A second daemon with its own home takes test port numbers in place
# of 80 and 443, so the mechanism is the real one but no case needs the privileged numbers or the user's own daemon.
NM_HTTP=$((PORT_BASE + 92)); NM_HTTPS=$((PORT_BASE + 93)); NM_HTTP_FB=$((PORT_BASE + 94)); NM_HTTPS_FB=$((PORT_BASE + 95))
nm_up() { # starts the second daemon; sets NM_HOME NM_SOCK NM_PID, defines nd
  [ -n "${NOODLED:-}" ] || skip "noodled not built"
  NM_HOME=$(mktemp -d /tmp/noodle-nm.XXXXXX); NM_SOCK=$NM_HOME/run/docker.sock; NM_PID=""
  mkdir -p "$NM_HOME/boot"
  for f in vmlinux initramfs.cpio.gz; do [ -f "$RES/$f" ] && { cp -c "$RES/$f" "$NM_HOME/boot/$f" 2>/dev/null || cp "$RES/$f" "$NM_HOME/boot/$f"; }; done
  trap nm_down EXIT
  NOODLE_HOME=$NM_HOME NOODLE_MEMORY_MIB=1024 NOODLE_CPUS=2 NOODLE_NAMES_HTTP_PORT=$NM_HTTP NOODLE_NAMES_HTTPS_PORT=$NM_HTTPS \
    NOODLE_HTTP_PORT=$NM_HTTP_FB NOODLE_HTTPS_PORT=$NM_HTTPS_FB "$NOODLED" >"$NM_HOME/noodled.log" 2>&1 &
  NM_PID=$!
  wait_for 60 curl -sf --max-time 2 --unix-socket "$NM_SOCK" http://localhost/_ping
  nd pull -q "$IMG" >/dev/null
}
nm_down() {
  set +e
  [ -n "${NM_PID:-}" ] && { kill -TERM "$NM_PID" 2>/dev/null; for _ in $(seq 1 20); do kill -0 "$NM_PID" 2>/dev/null || break; sleep 0.5; done; kill -KILL "$NM_PID" 2>/dev/null; }
  [ -n "${NM_HELD:-}" ] && kill "$NM_HELD" 2>/dev/null
  [ -n "${NM_HOME:-}" ] && rm -rf "$NM_HOME"
  return 0
}
nd() { DOCKER_HOST=unix://$NM_SOCK timeout -k 5 120 "$DOCKER" "$@"; }
nm_serve() { # name [flags]: "hi" on :80 inside the second daemon
  local name=$1; shift
  nd run -d --name "$name" "$@" "$IMG" sh -c '
    printf "%s\n" "#!/bin/sh" '\''printf "HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\nhi\n"'\'' > /tmp/reply
    chmod +x /tmp/reply
    exec nc -lk -p 80 -e /tmp/reply' >/dev/null
}
nm_says_hi() { [ "$(curl -sf --max-time 10 "$@")" = hi ]; }
nm_json() { curl -sf --max-time 5 --unix-socket "$NM_SOCK" http://localhost/noodle/names; }
nm_json_field() { nm_json | python3 -c 'import json,sys; v=json.load(sys.stdin).get(sys.argv[1]); print("" if v is None else v)' "$1"; }
nm_listening() { lsof -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | grep -q .; }
nm_lan_ip() { ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || ifconfig | awk '/inet / && $2 !~ /^127\./ && $2 !~ /^169\.254\./ {print $2; exit}'; }

t_names_standard_ports_loopback_only_and_torn_down() {
  nm_up
  local lan; lan=$(nm_lan_ip); [ -n "$lan" ] || skip "no LAN address on this Mac"
  # nothing listens before the first named container
  fails nm_listening "$NM_HTTP"; fails nm_listening "$NM_HTTPS"
  nm_serve e2e-nm-std --expose 80
  wait_for 30 nm_says_hi "http://e2e-nm-std.localhost:$NM_HTTP/"
  # test ports sit above 1024, so the listeners bind loopback directly (port 80 itself: names-port80-without-port-not-reachable-from-vm)
  has "$(lsof -nP -iTCP:"$NM_HTTP" -sTCP:LISTEN)" "127.0.0.1:$NM_HTTP"
  has "$(lsof -nP -iTCP:"$NM_HTTPS" -sTCP:LISTEN)" "127.0.0.1:$NM_HTTPS"
  eq "$(nm_json_field port)" "$NM_HTTP"
  eq "$(nm_json_field notice)" ""
  # a client that is not loopback is closed before a byte is served: nothing comes back on either port
  local out; out=$(mktemp "$NM_HOME/lan.XXXXXX")
  local rc=0; curl -s --max-time 4 -o "$out" -H 'Host: e2e-nm-std.localhost' "http://$lan:$NM_HTTP/" || rc=$?
  [ "$rc" != 0 ] || { echo "LAN client was served"; return 1; }
  eq "$(wc -c <"$out" | tr -d ' ')" 0
  eq "$(printf 'GET / HTTP/1.0\r\nHost: e2e-nm-std.localhost\r\n\r\n' | nc -w 3 "$lan" "$NM_HTTP" 2>/dev/null | wc -c | tr -d ' ')" 0
  eq "$(printf 'GET / HTTP/1.0\r\nHost: e2e-nm-std.localhost\r\n\r\n' | nc -w 3 "$lan" "$NM_HTTPS" 2>/dev/null | wc -c | tr -d ' ')" 0
  fails curl -sk --max-time 4 "https://$lan:$NM_HTTPS/" -H 'Host: e2e-nm-std.localhost'
  # the loopback client still works afterwards
  eq "$(curl -sf --max-time 3 "http://e2e-nm-std.localhost:$NM_HTTP/")" hi
  # the last name goes: both listeners are gone, not just the names
  nd rm -f e2e-nm-std >/dev/null
  wait_for 20 sh -c "! lsof -nP -iTCP:$NM_HTTP -sTCP:LISTEN | grep -q ." || { echo "http listener still bound"; return 1; }
  wait_for 20 sh -c "! lsof -nP -iTCP:$NM_HTTPS -sTCP:LISTEN | grep -q ." || { echo "https listener still bound"; return 1; }
  fails curl -s --max-time 2 "http://e2e-nm-std.localhost:$NM_HTTP/"
}

t_names_port80_without_port_not_reachable_from_vm() {
  # The real standard ports, unprivileged: wildcard sockets with the loopback peer check. Skipped when another program holds 80.
  nm_listening 80 && skip "port 80 is in use on this Mac"
  local NM_HTTP=80 NM_HTTPS=443
  nm_up
  nm_serve e2e-nm-80 --expose 80
  wait_for 30 nm_says_hi "http://e2e-nm-80.localhost/"
  eq "$(curl -sf --max-time 3 http://e2e-nm-80.localhost/)" hi
  eq "$(nm_json_field port)" 80
  [ "$(id -u)" = 0 ] || has "$(lsof -nP -iTCP:80 -sTCP:LISTEN)" "*:80"
  # Two VM paths to the Mac: the gateway goes through Noodle's loopback relay (which refuses Noodle's own ports), the
  # Mac's LAN address goes over the VM network and reaches the socket itself, so only the loopback peer check stops it.
  local gw lan; gw=$(nd run --rm --network host "$IMG" ip route | awk '/^default/ {print $3; exit}'); lan=$(nm_lan_ip)
  nonempty "$gw" "Mac address on the VM network"; nonempty "$lan" "Mac LAN address"
  # control: a Mac listener on every interface answers a bridge container on both paths
  local cport=$((PORT_BASE + 96))
  python3 -c 'import socket,sys
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(("0.0.0.0",int(sys.argv[1]))); s.listen(5)
while True:
    c,_=s.accept(); c.recv(4096); c.sendall(b"HTTP/1.0 200 OK\r\nContent-Length: 4\r\n\r\nctl\n"); c.close()' "$cport" &
  NM_HELD=$!
  wait_for 10 nm_listening "$cport"
  local addr
  for addr in "$gw" "$lan"; do
    eq "$(nd run --rm "$IMG" wget -qO- -T 5 "http://$addr:$cport/")" ctl
    # port 80 serves nothing to the VM: no byte comes back, with or without a known Host
    fails nd run --rm "$IMG" wget -qO- -T 5 "http://$addr:80/"
    eq "$(nd run --rm "$IMG" sh -c "printf 'GET / HTTP/1.0\r\nHost: e2e-nm-80.localhost\r\n\r\n' | nc -w 3 $addr 80 | wc -c" | tr -d ' ')" 0
  done
  # loopback still served afterwards
  eq "$(curl -sf --max-time 3 http://e2e-nm-80.localhost/)" hi
}

t_names_standard_port_taken_falls_back_with_message() {
  nm_up
  # one process holds the HTTP port on every address, another holds the HTTPS port on loopback only
  python3 - "$NM_HTTP" "$NM_HTTPS" <<'PY' &
import socket, sys, time
a = socket.socket(); a.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); a.bind(("0.0.0.0", int(sys.argv[1]))); a.listen(5)
b = socket.socket(); b.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); b.bind(("127.0.0.1", int(sys.argv[2]))); b.listen(5)
time.sleep(600)
PY
  NM_HELD=$!
  wait_for 10 sh -c "lsof -nP -iTCP:$NM_HTTPS -sTCP:LISTEN | grep -q ."
  nm_serve e2e-nm-fb --expose 80
  wait_for 30 nm_says_hi "http://e2e-nm-fb.localhost:$NM_HTTP_FB/"
  eq "$(nm_json_field port)" "$NM_HTTP_FB"
  eq "$(nm_json_field httpsPort)" "$NM_HTTPS_FB"
  local notice; notice=$(nm_json_field notice)
  has "$notice" "port $NM_HTTP is in use"
  has "$notice" "held by"
  has "$notice" "http://e2e-nm-fb.localhost:$NM_HTTP_FB/"
  has "$notice" "port $NM_HTTPS is in use"
  has "$notice" "https://e2e-nm-fb.localhost:$NM_HTTPS_FB/"
  has "$(cat "$NM_HOME/noodled.log")" "local names: port $NM_HTTP is in use"
  # the fallback ports are loopback only
  has "$(lsof -nP -iTCP:"$NM_HTTP_FB" -sTCP:LISTEN)" "127.0.0.1:$NM_HTTP_FB"
  # the other holder was not disturbed
  kill -0 "$NM_HELD"
}

t_names_https_selects_certificate_by_sni() {
  nm_up
  local ca=$NM_HOME/tls/ca.pem
  nm_serve e2e-nm-s1 --expose 80
  nm_serve e2e-nm-s2 --expose 80
  wait_for 30 nm_says_hi "http://e2e-nm-s1.localhost:$NM_HTTP/"
  wait_for 30 nm_says_hi "http://e2e-nm-s2.localhost:$NM_HTTP/"
  # the daemon creates the CA on first HTTPS use; trusting it in the Mac is a separate manual step (`noodle names trust`)
  wait_for 30 nm_says_hi --cacert "$ca" "https://e2e-nm-s1.localhost:$NM_HTTPS/" 2>/dev/null
  eq "$(curl -sf --max-time 20 --cacert "$ca" "https://e2e-nm-s2.localhost:$NM_HTTPS/")" hi
  # each name gets its own certificate, chosen by SNI
  local c1 c2
  c1=$(echo | timeout 15 /usr/bin/openssl s_client -connect "127.0.0.1:$NM_HTTPS" -servername e2e-nm-s1.localhost 2>/dev/null | /usr/bin/openssl x509 -noout -text | grep -o 'DNS:[^ ,]*' | tr '\n' ' ')
  c2=$(echo | timeout 15 /usr/bin/openssl s_client -connect "127.0.0.1:$NM_HTTPS" -servername e2e-nm-s2.localhost 2>/dev/null | /usr/bin/openssl x509 -noout -text | grep -o 'DNS:[^ ,]*' | tr '\n' ' ')
  eq "$c1" "DNS:e2e-nm-s1.localhost "
  eq "$c2" "DNS:e2e-nm-s2.localhost "
  # a client that trusts the CA verifies the leaf; a client that does not, refuses it
  local rc=0; curl -s --max-time 10 -o /dev/null "https://e2e-nm-s1.localhost:$NM_HTTPS/" || rc=$?
  eq "$rc" 60
  # an unknown name gets no certificate at all
  fails curl -s --max-time 10 --cacert "$ca" --connect-to "nobody.localhost:$NM_HTTPS:127.0.0.1:$NM_HTTPS" "https://nobody.localhost:$NM_HTTPS/"
  # the key never leaves the user: private folder, key and bundles readable by the owner only
  eq "$(stat -f %Lp "$NM_HOME/tls")" 700
  eq "$(stat -f %Lp "$NM_HOME/tls/ca.key")" 600
  eq "$(stat -f %Lp "$NM_HOME/tls/leaf")" 700
  eq "$(stat -f %Lp "$NM_HOME/tls/leaf/e2e-nm-s1.localhost.p12")" 600
}

t_ssh_agent_forwarding_signs_without_a_private_key() {
  if ! command -v ssh-agent >/dev/null || ! command -v ssh-keygen >/dev/null; then skip "OpenSSH tools missing"; fi
  local dir pid; dir=$(mktemp -d /tmp/noodle-ssh.XXXXXX)
  eval "$(ssh-agent -a "$dir/agent.sock" -s)" >/dev/null; pid=$SSH_AGENT_PID
  # Expanded now: pid and dir are locals and are gone when the EXIT trap fires after the function returns.
  # shellcheck disable=SC2064
  trap "kill $pid 2>/dev/null || true; rm -rf '$dir' '$NOODLE_HOME/ssh-auth-sock'; true" EXIT
  ssh-keygen -q -t ed25519 -N '' -C e2e-throwaway -f "$dir/key"
  SSH_AUTH_SOCK=$dir/agent.sock ssh-add -q "$dir/key"
  rm -f "$dir/key"                      # only the agent holds the private key now
  printf '%s' "$dir/agent.sock" >"$NOODLE_HOME/ssh-auth-sock"
  printf 'noodle-challenge-%s' "$$" >"$dir/msg"
  local out
  out=$(d run --rm -i -v /run/host-services/ssh-auth.sock:/run/host-services/ssh-auth.sock \
    -e SSH_AUTH_SOCK=/run/host-services/ssh-auth.sock "$IMG" sh -c '
      apk add -q openssh-keygen openssh-client >/dev/null 2>&1 || exit 41
      ssh-add -L > /tmp/pub || exit 42
      ls /root/.ssh /tmp/key 2>/dev/null | grep -q . && exit 43
      cat > /tmp/msg
      ssh-keygen -Y sign -q -f /tmp/pub -n noodle-e2e /tmp/msg || exit 44
      cat /tmp/msg.sig' <"$dir/msg")
  printf '%s\n' "$out" >"$dir/sig"
  printf 'e2e %s\n' "$(cat "$dir/key.pub")" >"$dir/allowed"
  has "$(ssh-keygen -Y verify -f "$dir/allowed" -I e2e -n noodle-e2e -s "$dir/sig" <"$dir/msg")" 'Good "noodle-e2e" signature'
}


t_ssh_agent_relay_cap_keeps_daemon_responsive() {
  if ! command -v ssh-agent >/dev/null; then skip "OpenSSH tools missing"; fi
  local dir pid; dir=$(mktemp -d /tmp/noodle-ssh.XXXXXX)
  eval "$(ssh-agent -a "$dir/agent.sock" -s)" >/dev/null; pid=$SSH_AGENT_PID
  # shellcheck disable=SC2064
  trap "kill $pid 2>/dev/null || true; rm -rf '$dir' '$NOODLE_HOME/ssh-auth-sock'; true" EXIT
  printf '%s' "$dir/agent.sock" >"$NOODLE_HOME/ssh-auth-sock"
  d run -d --name e2e-sshcap -v /run/host-services/ssh-auth.sock:/run/host-services/ssh-auth.sock \
    -e SSH_AUTH_SOCK=/run/host-services/ssh-auth.sock "$IMG" sh -c '
      apk add -q socat >/dev/null 2>&1 || exit 41
      i=0
      while [ $i -lt 200 ]; do (sleep 15 | socat - UNIX-CONNECT:$SSH_AUTH_SOCK >/dev/null 2>&1) & i=$((i+1)); done
      sleep 5
      pgrep -x socat | wc -l >/tmp/alive
      sleep 600' >/dev/null
  wait_for 60 d exec e2e-sshcap test -s /tmp/alive
  timeout 10 "$DOCKER" ps >/dev/null || { echo "daemon unresponsive under 200 agent connections"; return 1; }
  local alive; alive=$(d exec e2e-sshcap cat /tmp/alive | tr -d ' ')
  # the relay holds at most 64; the rest were closed, not left hanging
  [ "$alive" -lt 200 ] || { echo "no cap: $alive connections alive"; return 1; }
}
