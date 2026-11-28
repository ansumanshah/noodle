#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016,SC2086
# E2E checks: networking. Sourced by tests/e2e.sh; do not run directly.

# ===================================================================== checks: networking
t_net_default_bridge_ip() {
  sleeper e2e-b1; sleeper e2e-b2
  local ip; ip=$(insp e2e-b2 '{{.NetworkSettings.IPAddress}}')
  nonempty "$ip" bridge-ip
  exit_is 0 d exec e2e-b1 ping -c 1 -W 3 "$ip"
}
t_net_outbound_http() { exit_is 0 d run --rm "$IMG" wget -q -T 15 -O /dev/null http://example.com; }
t_net_outbound_http_host() { exit_is 0 d run --rm --network host "$IMG" wget -q -T 15 -O /dev/null http://example.com; }
t_net_bridge_cleanup() {
  local links='ip -o link show | grep -c "v[0-9a-f]*-0" || true'
  sleeper e2e-ncleanup
  # while the container lives its peer interface is visible to the host namespace
  local before; before=$(d run --rm --network host "$IMG" sh -c "$links")
  [ "$before" -ge 1 ] || { echo "no bridge peer interface seen while the container ran"; return 1; }
  d rm -f e2e-ncleanup >/dev/null
  # Linux reclaims the namespace and its peer asynchronously.
  wait_for 10 sh -c "[ \"\$('$DOCKER' run --rm --network host '$IMG' sh -c '$links')\" -lt $before ]"
}
t_net_create_inspect_rm() {
  d network create e2e-n1 --subnet 172.30.10.0/24 >/dev/null
  has "$(d network ls --format '{{.Name}}')" e2e-n1
  eq "$(d network inspect -f '{{(index .IPAM.Config 0).Subnet}}' e2e-n1)" 172.30.10.0/24
  d network rm e2e-n1 >/dev/null
  fails d network inspect e2e-n1
}
t_net_dns_by_container_name() {
  d network create e2e-n2 >/dev/null
  serve e2e-web --network e2e-n2
  sleeper e2e-cli --network e2e-n2
  wait_for 20 d exec e2e-cli wget -qO- http://e2e-web
  eq "$(d exec e2e-cli wget -qO- http://e2e-web)" hi
}
t_net_alias() {
  d network create e2e-n3 >/dev/null
  serve e2e-ali --network e2e-n3 --network-alias api
  sleeper e2e-alc --network e2e-n3
  wait_for 20 d exec e2e-alc wget -qO- http://api
  eq "$(d exec e2e-alc wget -qO- http://api)" hi
}
t_net_connect_disconnect() {
  d network create e2e-n4 >/dev/null
  sleeper e2e-cd
  d network connect e2e-n4 e2e-cd
  has "$(insp e2e-cd '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}')" e2e-n4
  has "$(d exec e2e-cd ls /sys/class/net)" eth1
  d network disconnect e2e-n4 e2e-cd
  lacks "$(insp e2e-cd '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}')" e2e-n4
}
t_net_static_ip() {
  d network create e2e-n5 --subnet 172.31.20.0/24 >/dev/null
  sleeper e2e-ip --network e2e-n5 --ip 172.31.20.10
  eq "$(insp e2e-ip '{{(index .NetworkSettings.Networks "e2e-n5").IPAddress}}')" 172.31.20.10
  has "$(d exec e2e-ip ip -4 addr show eth0)" 172.31.20.10
}
t_net_mac_address() {
  sleeper e2e-mac --mac-address 02:42:ac:11:00:99
  eq "$(d exec e2e-mac cat /sys/class/net/eth0/address)" 02:42:ac:11:00:99
  eq "$(insp e2e-mac '{{.NetworkSettings.MacAddress}}')" 02:42:ac:11:00:99
}
t_net_mode_none() {
  eq "$(d run --rm --network none "$IMG" ls /sys/class/net)" lo
}
# The namespace comes ready from create on a first start and from clone3 on a restart. Both must look the same inside.
t_net_mode_none_same_on_restart() {
  local probe first again
  probe='cat /sys/class/net/lo/flags /proc/sys/net/ipv4/ip_unprivileged_port_start /proc/sys/net/ipv4/ping_group_range; ls /sys/class/net; ping -c1 -W1 127.0.0.1 >/dev/null && echo loopback-ok'
  first=$(d run --name e2e-none-again --network none "$IMG" sh -c "$probe")
  has "$first" loopback-ok
  d start e2e-none-again >/dev/null
  d wait e2e-none-again >/dev/null
  again=$(d logs e2e-none-again)
  eq "$again" "$first
$first"
}
t_net_mode_none_namespaces_are_separate() {
  local a b host
  d run -d --name e2e-none-a --network none "$IMG" sleep 600 >/dev/null
  d run -d --name e2e-none-b --network none "$IMG" sleep 600 >/dev/null
  a=$(d exec e2e-none-a readlink /proc/self/ns/net)
  b=$(d exec e2e-none-b readlink /proc/self/ns/net)
  host=$(d run --rm --network host "$IMG" readlink /proc/self/ns/net)
  nonempty "$a" && nonempty "$b"
  [ "$a" != "$b" ] || { echo "two --network none containers share $a"; return 1; }
  [ "$a" != "$host" ] && [ "$b" != "$host" ] || { echo "a --network none container is in the VM namespace $host"; return 1; }
}
t_net_mode_host() {
  exit_is 0 d run --rm --network host "$IMG" test -e /sys/class/net/eth0
}
t_net_mode_container() {
  sleeper e2e-nc1
  eq "$(d run --rm --network container:e2e-nc1 "$IMG" cat /sys/class/net/eth0/address)" \
     "$(d exec e2e-nc1 cat /sys/class/net/eth0/address)"
}
t_net_internal_blocks_egress() {
  d network create --internal e2e-n6 >/dev/null
  serve e2e-internal-web --network e2e-n6 --network-alias internal-api
  sleeper e2e-internal-client --network e2e-n6 --cap-add NET_ADMIN
  wait_for 20 d exec e2e-internal-client wget -qO- http://e2e-internal-web
  eq "$(d exec e2e-internal-client wget -qO- http://e2e-internal-web)" hi
  local gw target ordinary_gw answer
  gw=$(insp e2e-internal-client '{{.NetworkSettings.Gateway}}')
  ordinary_gw=$(d network inspect -f '{{(index .IPAM.Config 0).Gateway}}' bridge)
  target=$(insp e2e-internal-web '{{.NetworkSettings.IPAddress}}')
  answer=$(d exec e2e-internal-client nslookup internal-api "$gw")
  has "$answer" "$target"
  answer=$(d run --rm "$IMG" nslookup -timeout=2 example.com "$ordinary_gw")
  has "$answer" example.com
  fails d exec e2e-internal-client nslookup example.com "$gw"
  d exec e2e-internal-client ip route replace default via "$gw"
  fails d exec e2e-internal-client nslookup -timeout=2 example.com "$ordinary_gw"
  fails d exec e2e-internal-client wget -q -T 5 -O /dev/null http://1.1.1.1
  fails d run --rm "$IMG" wget -q -T 5 -O /dev/null "http://$target"
}
t_net_dns_flags_and_add_host() {
  local r; r=$(d run --rm --dns 9.9.9.9 --dns-search example.test --dns-option ndots:2 --add-host foo.test:1.2.3.4 \
    "$IMG" sh -c 'cat /etc/resolv.conf /etc/hosts')
  has "$r" "nameserver 9.9.9.9"; has "$r" "example.test"; has "$r" "ndots:2"; has "$r" "1.2.3.4"
}
t_port_publish_tcp() {
  local p; p=$(port 10)
  serve e2e-p1 -p "$p:80"
  wait_for 20 http_get "http://127.0.0.1:$p/"
  eq "$(http_get "http://127.0.0.1:$p/")" hi
  has "$(d port e2e-p1 80/tcp)" ":$p"
}
t_port_publish_loopback_only() {
  local p; p=$(port 11)
  serve e2e-p2 -p "127.0.0.1:$p:80"
  wait_for 20 http_get "http://127.0.0.1:$p/"
  eq "$(http_get "http://127.0.0.1:$p/")" hi
}
t_port_publish_random_P() {
  serve e2e-p3 --expose 80 -P
  local hp; hp=$(d port e2e-p3 80/tcp | head -1 | sed 's/.*://')
  nonempty "$hp" random-port
  wait_for 20 http_get "http://127.0.0.1:$hp/"
  eq "$(http_get "http://127.0.0.1:$hp/")" hi
}
t_port_publish_udp() {
  local p; p=$(port 12)
  d run -d --name e2e-p4 -p "$p:5000/udp" "$IMG" sh -c 'nc -u -l -p 5000 | head -n 1' >/dev/null
  sleep 2

  for _ in 1 2 3 4 5; do
    printf 'ping-udp\n' | nc -u -w1 127.0.0.1 "$p" || true
    case $(d logs e2e-p4 2>&1) in *ping-udp*) return 0 ;; esac
    sleep 1
  done
  echo "datagram never arrived; logs: $(d logs e2e-p4 2>&1)"; return 1
}
t_port_conflict_rejected() {
  local p; p=$(port 13)
  serve e2e-p5 -p "$p:80"
  fails d run -d --name e2e-p6 -p "$p:80" "$IMG" sleep 5
}
t_port_publish_released_on_stop() {
  local p; p=$(port 14)
  serve e2e-p7 -p "$p:80"
  wait_for 20 http_get "http://127.0.0.1:$p/"
  d rm -f e2e-p7 >/dev/null
  sleep 1
  fails curl -sf --max-time 3 "http://127.0.0.1:$p/"
  serve e2e-p8 -p "$p:80"
}

# Back-to-back new connections: closing one must not touch the next one, which can get the same descriptor number.
t_port_publish_connection_burst_no_drops() {
  local p; p=$(port 15)
  serve e2e-p9 -p "127.0.0.1:$p:80"
  wait_for 20 http_get "http://127.0.0.1:$p/"
  python3 -I - "$p" <<'PY'
import http.client, sys
port, failed = int(sys.argv[1]), 0
for _ in range(1000):
    try:
        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        connection.request("GET", "/")
        response = connection.getresponse()
        response.read()
        connection.close()
        failed += response.status != 200
    except (OSError, http.client.HTTPException):
        failed += 1
sys.exit(f"{failed} of 1000 connections failed" if failed else 0)
PY
}

t_filter_network_ls() {
  d network create --label e2e.team=a e2e-fn-a >/dev/null
  d network create e2e-fn-b >/dev/null
  d network create e2e-fn-ab >/dev/null
  eq "$(d network ls --filter label=e2e.team=a --format '{{.Name}}')" e2e-fn-a
  eq "$(d network ls --filter label=e2e.team --format '{{.Name}}')" e2e-fn-a
  eq "$(d network ls --filter name=e2e-fn-a --format '{{.Name}}' | names_of)" "e2e-fn-a e2e-fn-ab "
  eq "$(d network ls --filter 'name=^e2e-fn-a$' --format '{{.Name}}')" e2e-fn-a
  eq "$(d network ls --filter driver=bridge --filter name=e2e-fn- --format '{{.Name}}' | names_of)" "e2e-fn-a e2e-fn-ab e2e-fn-b "
  eq "$(d network ls --filter driver=overlay --filter name=e2e-fn- -q | count)" 0
  eq "$(d network ls --filter type=custom --filter name=e2e-fn- -q | count)" 3
  local builtin; builtin=$(d network ls --filter type=builtin --format '{{.Name}}' | names_of)
  has "$builtin" "bridge "; has "$builtin" "host "; has "$builtin" "none "
  lacks "$builtin" e2e-fn-
  local id; id=$(d network inspect -f '{{.Id}}' e2e-fn-b)
  eq "$(d network ls --filter "id=${id:0:12}" --format '{{.Name}}')" e2e-fn-b
  eq "$(d network ls --no-trunc -q --filter 'name=^e2e-fn-b$')" "$id"
  fails d network ls --filter bogus=1
}
