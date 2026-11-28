#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016,SC2086
# E2E checks: network-compatibility. Sourced by tests/e2e.sh; do not run directly.

# ===================================================================== checks: network compatibility (net lane)
# POST to the Docker API directly, for server checks the CLI would catch first. Prints the body.
api_post() { curl -s --max-time 30 --unix-socket "$SOCK" -H 'Content-Type: application/json' -d "$2" "http://localhost$1"; }
# Docker 29 clients print a missing address (a zero netip.Addr) as "invalid IP"; callers want empty.
noaddr() { sed 's/^invalid IP$//'; }
ip_on() { insp "$1" "{{(index .NetworkSettings.Networks \"$2\").IPAddress}}" | noaddr; }

t_ipam_range_allocates_inside() {
  d network create e2e-r --subnet 10.77.1.0/24 --gateway 10.77.1.1 --ip-range 10.77.1.128/25 >/dev/null
  eq "$(d network inspect -f '{{(index .IPAM.Config 0).IPRange}}' e2e-r)" 10.77.1.128/25
  sleeper e2e-r1 --network e2e-r; eq "$(ip_on e2e-r1 e2e-r)" 10.77.1.128
  sleeper e2e-r2 --network e2e-r --ip 10.77.1.50; eq "$(ip_on e2e-r2 e2e-r)" 10.77.1.50
  sleeper e2e-r3 --network e2e-r; eq "$(ip_on e2e-r3 e2e-r)" 10.77.1.129
}
t_ipam_aux_addresses_reserved() {
  d network create e2e-a --subnet 10.77.2.0/29 --gateway 10.77.2.1 --aux-address one=10.77.2.2 --aux-address two=10.77.2.3 >/dev/null
  local aux; aux=$(d network inspect -f '{{json (index .IPAM.Config 0).AuxAddress}}' e2e-a)
  has "$aux" '"one":"10.77.2.2"'; has "$aux" '"two":"10.77.2.3"'
  sleeper e2e-a1 --network e2e-a; eq "$(ip_on e2e-a1 e2e-a)" 10.77.2.4
  has "$(d run --rm --network e2e-a --ip 10.77.2.2 "$IMG" true 2>&1)" "Address already in use"
}
t_ipam_invalid_pools_refused() {
  fails d network create e2e-b1 --subnet 10.77.4.0/24 --gateway 10.77.5.1
  fails d network create e2e-b2 --subnet 10.77.4.0/24 --ip-range 10.77.5.0/25
  fails d network create e2e-b3 --subnet 10.77.4.0/24 --aux-address a=10.77.5.1
  # The CLI catches those first; the server must refuse them too.
  has "$(api_post /networks/create '{"Name":"e2e-b4","IPAM":{"Config":[{"Subnet":"10.77.4.0/24","Gateway":"10.77.5.1"}]}}')" "no matching subnet for gateway 10.77.5.1"
  has "$(api_post /networks/create '{"Name":"e2e-b5","IPAM":{"Config":[{"Subnet":"10.77.4.0/24","IPRange":"10.77.5.0/25"}]}}')" "no matching subnet for range 10.77.5.0/25"
  has "$(api_post /networks/create '{"Name":"e2e-b6","IPAM":{"Config":[{"Subnet":"10.77.4.0/24","AuxiliaryAddresses":{"a":"10.77.5.1"}}]}}')" "no matching subnet for aux-address 10.77.5.1"
  lacks "$(d network ls --format '{{.Name}}')" e2e-b
}
t_ipam_subnet_overlap_refused() {
  d network create e2e-o1 --subnet 10.77.6.0/24 >/dev/null
  has "$(d network create e2e-o2 --subnet 10.77.6.128/25 2>&1)" "Pool overlaps with other one on this address space"
  has "$(d network create e2e-o3 --subnet 10.77.0.0/16 2>&1)" "Pool overlaps with other one on this address space"
  # An automatic pool steps around a subnet already in use.
  d network create e2e-o4 --subnet 172.19.0.0/16 >/dev/null
  d network create e2e-o5 >/dev/null
  lacks "$(d network inspect -f '{{(index .IPAM.Config 0).Subnet}}' e2e-o5)" 172.19.0.0
}
t_ipam_static_ip_errors() {
  d network create e2e-s --subnet 10.77.7.0/24 --gateway 10.77.7.1 >/dev/null
  d network create e2e-s2 >/dev/null
  has "$(d run --rm --network e2e-s --ip 10.77.8.5 "$IMG" true 2>&1)" "no configured subnet or ip-range contain the IP address 10.77.8.5"
  has "$(d run --rm --ip 172.18.0.77 "$IMG" true 2>&1)" "user specified IP address is supported on user defined networks only"
  has "$(d run --rm --network e2e-s2 --ip 172.19.0.77 "$IMG" true 2>&1)" "user specified IP address is supported only when connecting to networks with user configured subnets"
  has "$(d run --rm --network e2e-s --ip 10.77.7.1 "$IMG" true 2>&1)" "Address already in use"
  sleeper e2e-s1 --network e2e-s --ip 10.77.7.9
  has "$(d run --rm --network e2e-s --ip 10.77.7.9 "$IMG" true 2>&1)" "Address already in use"
  has "$(api_post /containers/create?name=e2e-s9 "{\"Image\":\"$IMG\",\"NetworkingConfig\":{\"EndpointsConfig\":{\"e2e-s\":{\"IPAMConfig\":{\"IPv4Address\":\"banana\"}}}}}")" "invalid IPv4 address: banana"
}
t_ipam_static_ip_on_connect() {
  d network create e2e-c --subnet 10.77.9.0/24 --gateway 10.77.9.1 >/dev/null
  sleeper e2e-c1
  has "$(d network connect --ip 10.77.10.5 e2e-c e2e-c1 2>&1)" "no configured subnet or ip-range contain the IP address"
  lacks "$(insp e2e-c1 '{{json .NetworkSettings.Networks}}')" e2e-c\"
  d network connect --ip 10.77.9.7 e2e-c e2e-c1
  eq "$(ip_on e2e-c1 e2e-c)" 10.77.9.7
  has "$(d exec e2e-c1 ip -4 addr)" 10.77.9.7/24
  eq "$(insp e2e-c1 '{{(index .NetworkSettings.Networks "e2e-c").IPAMConfig.IPv4Address}}')" 10.77.9.7
}
t_ipam_address_exhaustion() {
  d network create e2e-x --subnet 10.77.11.0/30 --gateway 10.77.11.1 >/dev/null
  sleeper e2e-x1 --network e2e-x; eq "$(ip_on e2e-x1 e2e-x)" 10.77.11.2
  has "$(d run --rm --network e2e-x "$IMG" true 2>&1)" "no available IPv4 addresses on this network's address pools: e2e-x"
  d rm -f e2e-x1 >/dev/null
  exit_is 0 d run --rm --network e2e-x "$IMG" true
}
t_ipam_default_pool_exhaustion() {
  local i=0 msg=""
  while [ "$i" -lt 40 ]; do
    i=$((i + 1))
    msg=$(d network create "e2e-p$i" 2>&1) || break
    msg=""
  done
  has "$msg" "could not find an available, non-overlapping IPv4 address pool among the defaults"
  d network rm e2e-p1 >/dev/null
  exit_is 0 d network create e2e-p-again
}
t_ipam_twenty_networks_in_use() {
  local i=0
  while [ "$i" -lt 20 ]; do
    i=$((i + 1))
    d network create "e2e-m$i" >/dev/null
    exit_is 0 d run --rm --network "e2e-m$i" "$IMG" true || { echo "failed on network $i"; return 1; }
  done
}
t_ipam_inspect_output() {
  d network create e2e-i --subnet 10.77.12.0/24 --gateway 10.77.12.254 --ip-range 10.77.12.0/25 --aux-address a=10.77.12.2 >/dev/null
  sleeper e2e-i1 --network e2e-i --ip 10.77.12.40 --network-alias api --mac-address 02:42:0a:4d:0c:28
  local f='index .NetworkSettings.Networks "e2e-i"'
  eq "$(insp e2e-i1 "{{($f).IPPrefixLen}} {{($f).Gateway}} {{($f).MacAddress}}")" "24 10.77.12.254 02:42:0a:4d:0c:28"
  eq "$(insp e2e-i1 "{{($f).IPAMConfig.IPv4Address}}")" 10.77.12.40
  has "$(insp e2e-i1 "{{json ($f).Aliases}}")" api
  has "$(d network inspect -f '{{range .Containers}}{{.IPv4Address}} {{.MacAddress}}{{end}}' e2e-i)" "10.77.12.40/24 02:42:0a:4d:0c:28"
  eq "$(d network inspect -f '{{(index .IPAM.Config 0).Gateway}} {{(index .IPAM.Config 0).IPRange}}' e2e-i)" "10.77.12.254 10.77.12.0/25"
  # Dynamic allocation skips the reserved subnet address and aux address.
  sleeper e2e-i2 --network e2e-i
  eq "$(ip_on e2e-i2 e2e-i)" 10.77.12.1
  sleeper e2e-i3 --network e2e-i
  eq "$(ip_on e2e-i3 e2e-i)" 10.77.12.3
}
t_netdns_custom_server_keeps_peer_names() {
  d network create e2e-d >/dev/null
  serve e2e-dweb --network e2e-d
  sleeper e2e-dcli --network e2e-d --dns 192.0.2.1
  eq "$(insp e2e-dcli '{{json .HostConfig.Dns}}')" '["192.0.2.1"]'
  has "$(d exec e2e-dcli cat /etc/resolv.conf)" "nameserver 127.0.0.11"
  wait_for 20 d exec e2e-dcli wget -qO- http://e2e-dweb
  # The container's own server answers everything else, with no quiet fallback.
  fails d exec e2e-dcli nslookup -timeout=1 -retry=1 example.com
  has "$(d run --rm --network e2e-d --dns 1.1.1.1 "$IMG" nslookup example.com)" Address
}
t_netdns_search_and_options_on_user_network() {
  d network create e2e-d2 >/dev/null
  sleeper e2e-d2a --network e2e-d2 --network-alias api.corp.test
  local r; r=$(d run --rm --network e2e-d2 --dns-search corp.test --dns-option ndots:3 "$IMG" sh -c 'cat /etc/resolv.conf; getent hosts api')
  has "$r" "search corp.test"; has "$r" "options ndots:3"; has "$r" "nameserver 127.0.0.11"
  has "$r" "$(ip_on e2e-d2a e2e-d2)"
  eq "$(d run --rm --dns-search corp.test --dns-option ndots:3 --name e2e-d2b "$IMG" sh -c 'grep -c "^search corp.test\|^options ndots:3" /etc/resolv.conf')" 2
}
t_netdns_domainname() {
  d network create e2e-d3 >/dev/null
  sleeper e2e-d3a --network e2e-d3 --hostname h1 --domainname corp.test
  eq "$(insp e2e-d3a '{{.Config.Domainname}}')" corp.test
  eq "$(d exec e2e-d3a cat /proc/sys/kernel/domainname)" corp.test
  has "$(d exec e2e-d3a cat /etc/hosts)" "h1.corp.test h1"
}
t_netdns_embedded_resolver_address() {
  d network create e2e-d4 >/dev/null
  sleeper e2e-d4a --network e2e-d4
  has "$(d exec e2e-d4a cat /etc/resolv.conf)" "nameserver 127.0.0.11"
  has "$(d run --rm --network e2e-d4 "$IMG" nslookup e2e-d4a 127.0.0.11)" "$(ip_on e2e-d4a e2e-d4)"
  has "$(d run --rm --network e2e-d4 "$IMG" nslookup example.com 127.0.0.11)" Address
  lacks "$(d run --rm "$IMG" cat /etc/resolv.conf)" 127.0.0.11
}
t_netdns_resolves_on_every_attached_network() {
  d network create e2e-d5a >/dev/null; d network create e2e-d5b >/dev/null
  sleeper e2e-d5p --network e2e-d5a; sleeper e2e-d5q --network e2e-d5b
  sleeper e2e-d5m --network e2e-d5a
  d network connect e2e-d5b e2e-d5m
  has "$(d exec e2e-d5m nslookup e2e-d5p)" "$(ip_on e2e-d5p e2e-d5a)"
  has "$(d exec e2e-d5m nslookup e2e-d5q)" "$(ip_on e2e-d5q e2e-d5b)"
  d network disconnect e2e-d5b e2e-d5m
  fails d exec e2e-d5m nslookup e2e-d5q
  # Started on the default bridge, connected later: it gets the embedded resolver then.
  sleeper e2e-d5n
  d network connect e2e-d5b e2e-d5n
  has "$(d exec e2e-d5n cat /etc/resolv.conf)" "nameserver 127.0.0.11"
  has "$(d exec e2e-d5n nslookup e2e-d5q)" "$(ip_on e2e-d5q e2e-d5b)"
}
t_netdns_default_bridge_has_no_names() {
  sleeper e2e-d6a
  fails d run --rm "$IMG" nslookup -timeout=2 -retry=1 e2e-d6a
  has "$(d run --rm "$IMG" nslookup example.com)" Address
}
t_netlink_default_bridge() {
  sleeper e2e-l1 --env SECRET_FLAVOR=mint --expose 80/tcp
  local tip; tip=$(insp e2e-l1 '{{.NetworkSettings.IPAddress}}')
  sleeper e2e-l2 --link e2e-l1:db
  eq "$(insp e2e-l2 '{{json .HostConfig.Links}}')" '["/e2e-l1:/e2e-l2/db"]'
  local hosts; hosts=$(d exec e2e-l2 cat /etc/hosts)
  has "$hosts" "$tip"; has "$hosts" " db"; has "$hosts" e2e-l1
  exit_is 0 d exec e2e-l2 ping -c 1 -W 3 db
  local env; env=$(d exec e2e-l2 env)
  has "$env" "DB_NAME=/e2e-l2/db"; has "$env" "DB_ENV_SECRET_FLAVOR=mint"
  has "$env" "DB_PORT=tcp://$tip:80"; has "$env" "DB_PORT_80_TCP_ADDR=$tip"
  # No alias: the target's own name.
  has "$(d run --rm --link e2e-l1 "$IMG" cat /etc/hosts)" e2e-l1
}
t_netlink_errors() {
  sleeper e2e-l3; d stop -t 0 e2e-l3 >/dev/null
  has "$(d run --rm --link e2e-nope:x "$IMG" true 2>&1)" "could not get container for e2e-nope"
  has "$(d run --rm --link e2e-l3:x "$IMG" true 2>&1)" "non running container"
}
t_netstart_failure_ends_run_and_removes() {
  d network create e2e-f --subnet 10.77.30.0/24 >/dev/null
  sleeper e2e-f1 --network e2e-f --ip 10.77.30.9
  local out rc=0
  out=$(timeout 30 "$DOCKER" run --rm --name e2e-f2 --network e2e-f --ip 10.77.30.9 "$IMG" true 2>&1) || rc=$?
  eq "$rc" 125
  has "$out" "Address already in use"
  local i=0
  while d inspect e2e-f2 >/dev/null 2>&1; do i=$((i + 1)); [ "$i" -lt 50 ] || { echo "not removed"; return 1; }; sleep 0.1; done
  exit_is 0 d run --rm --network e2e-f "$IMG" true
}
t_netlink_user_network_alias_is_private() {
  d network create e2e-l >/dev/null
  sleeper e2e-l4 --network e2e-l
  sleeper e2e-l5 --network e2e-l --link e2e-l4:db
  sleeper e2e-l6 --network e2e-l
  has "$(d exec e2e-l5 nslookup db)" "$(ip_on e2e-l4 e2e-l)"
  fails d exec e2e-l6 nslookup -timeout=2 -retry=1 db
  has "$(insp e2e-l5 '{{json (index .NetworkSettings.Networks "e2e-l").Links}}')" "e2e-l4:db"
  # The alias follows the target's address across a restart.
  d stop -t 0 e2e-l4 >/dev/null; sleeper e2e-l7 --network e2e-l; d start e2e-l4 >/dev/null
  has "$(d exec e2e-l5 nslookup db)" "$(ip_on e2e-l4 e2e-l)"
}

t_build_dns_internal_cannot_query_default() {
  # Reusing bridge DNS for BuildKit must not give an internal network Mac DNS access.
  # The existing DNS fixture includes dig, allowing both UDP and TCP checks.
  d() { timeout -k 5 120 "$DOCKER" "$@"; }
  dnsbox
  local gateway transport
  gateway=$(parity_d network inspect -f '{{(index .IPAM.Config 0).Gateway}}' bridge)
  nonempty "$gateway" bridge-gateway
  parity_d network create --internal e2e-build-dns-internal >/dev/null
  for transport in +notcp +tcp; do
    parity_d run --rm --network e2e-build-dns-internal e2e/dnsbox:1 sh -ec '
      out=$(dig +time=2 +tries=1 "$@" 2>&1) || exit 0
      printf "%s\n" "$out"
      if printf "%s\n" "$out" | grep -q "status: NOERROR"; then
        echo "internal network reached the default bridge resolver"
        exit 1
      fi' sh "$transport" "@$gateway" example.com
  done
}

t_netdns_tcp_cap_leaves_other_containers_resolving() {
  d network create e2e-tcpcap >/dev/null
  sleeper e2e-tcpp --network e2e-tcpcap
  d run -d --name e2e-tcphog --network e2e-tcpcap "$IMG" sh -c '
    for i in 1 2 3 4 5 6 7 8; do sleep 20 | nc 127.0.0.11 53 >/dev/null 2>&1 & done
    wait' >/dev/null
  sleep 2
  sleeper e2e-tcpother --network e2e-tcpcap
  has "$(d exec e2e-tcpother nslookup e2e-tcpp 127.0.0.11)" "$(ip_on e2e-tcpp e2e-tcpcap)"
  has "$(d run --rm "$IMG" nslookup example.com)" Address
}

t_netdns_shared_alias_returns_every_container() {
  d network create e2e-shal >/dev/null
  sleeper e2e-shal-a --network e2e-shal --network-alias e2e-shared
  sleeper e2e-shal-b --network e2e-shal --network-alias e2e-shared
  sleeper e2e-shal-c --network e2e-shal
  local out; out=$(d exec e2e-shal-c nslookup e2e-shared 127.0.0.11)
  has "$out" "$(ip_on e2e-shal-a e2e-shal)"
  has "$out" "$(ip_on e2e-shal-b e2e-shal)"
}

# dnsredir.zig: the 127.0.0.11:53 rewrite only touches the container's own netns (cookie match), so a nested netns
# (Docker-in-Docker) keeps its inner dockerd's embedded DNS, which in turn forwards to the outer resolver.
t_dind_inner_container_resolves_names() {
  local img=docker:28-dind i
  timeout -k 5 300 "$DOCKER" pull "$img" >/dev/null 2>&1 || skip "$img cannot be pulled"
  d network create e2e-dindn >/dev/null
  sleeper e2e-dindp --network e2e-dindn
  d run -d --name e2e-dind --privileged --network e2e-dindn -e DOCKER_TLS_CERTDIR= "$img" >/dev/null
  wait_for 60 d exec e2e-dind docker info || { d logs e2e-dind 2>&1 | tail -n 20; skip "inner dockerd did not start in 60s"; }
  # the inner pull needs the uplink; without it there is nothing to resolve against
  timeout -k 5 180 "$DOCKER" exec e2e-dind docker pull alpine:3.22 >/dev/null 2>&1 || skip "inner dockerd cannot pull alpine"
  # outer container on the same user network, by name, through the inner bridge
  has "$(d exec e2e-dind docker run --rm alpine:3.22 nslookup e2e-dindp 2>&1)" "Address"
  # an external name; the inner container asks the inner embedded DNS, which forwards to the outer one
  for i in 1 2 3; do
    d exec e2e-dind docker run --rm alpine:3.22 nslookup dl-cdn.alpinelinux.org >/dev/null 2>&1 && return 0
    sleep 2
  done
  echo "inner container could not resolve an external name"; return 1
}
