#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016,SC2086
# E2E checks: conn-stability. Sourced by tests/e2e.sh; do not run directly.

# --- connection stability and egress defaults

# A TCP stream between two containers keeps flowing while others come and go on the same bridge.
# Host-network container with nftables installed. A failed install is a failure, never a skip.
nf_start() {
  d run -d --name "$1" --network host --cap-add NET_ADMIN "$IMG" sleep 300 >/dev/null || return 1
  # At most 5 * (25s + 2s kill grace) + 4 * 2s backoff = 143s, within the case's 180s budget.
  # Exec returns the install status directly, rather than polling a marker after an exhausted install.
  if d exec "$1" sh -ec '
    for i in 1 2 3 4 5; do
      if timeout -k 2 25 apk add -q --no-cache nftables; then nft --version; exit 0; fi
      [ "$i" = 5 ] || sleep 2
    done
    exit 1
  '; then return 0; fi
  d logs "$1" >&2 || true
  d rm -f "$1" >/dev/null; echo "nftables install failed"; return 1
}

t_netstable_peer_stream_survives_churn() {
  local net; net=e2e-net; d network create "$net" >/dev/null
  d run -d --name "$net-srv" --network "$net" "$IMG" sh -c 'while :; do echo tick; sleep 0.1; done | nc -l -p 9000' >/dev/null
  d run -d --name "$net-cli" --network "$net" "$IMG" sh -c "sleep 0.3; nc $net-srv 9000 > /tmp/out; echo closed > /tmp/closed; sleep 60" >/dev/null
  sleep 1
  local i before after
  before=$(d exec "$net-cli" sh -c 'wc -l < /tmp/out')
  for i in 1 2 3 4 5 6 7 8; do d run --rm --network "$net" "$IMG" true; done
  sleep 1
  after=$(d exec "$net-cli" sh -c 'wc -l < /tmp/out')
  [ "$after" -gt "$before" ] || { echo "stream stalled: $before then $after"; return 1; }
  if d exec "$net-cli" test -e /tmp/closed; then echo "stream closed during churn"; return 1; fi
  d rm -f "$net-srv" "$net-cli" >/dev/null; d network rm "$net" >/dev/null
}

# Reusing a just-freed address and MAC must not take traffic from a live neighbour.
t_netstable_address_reuse_keeps_neighbours() {
  local net; net=e2e-net; d network create --subnet 10.66.9.0/29 "$net" >/dev/null
  d run -d --name "$net-a" --network "$net" "$IMG" sleep 60 >/dev/null
  local ip; ip=$(ip_on "$net-a" "$net")
  local i
  for i in 1 2 3 4 5 6; do
    d run --rm --network "$net" "$IMG" sh -c "ping -c1 -W2 $ip >/dev/null" || { echo "round $i: peer unreachable"; return 1; }
  done
  d rm -f "$net-a" >/dev/null; d network rm "$net" >/dev/null
}

# Sequential and concurrent downloads through NAT while containers start and stop.
t_netstable_downloads_survive_churn() {
  local url=https://dl-cdn.alpinelinux.org/alpine/latest-stable/main/aarch64/APKINDEX.tar.gz
  d run --rm "$IMG" wget -q -T 10 -O /dev/null "$url" || { echo "no uplink"; return 77; }
  local i
  for i in 1 2 3 4 5 6 7 8; do
    d run --rm "$IMG" wget -q -T 20 -O /dev/null "$url" || { echo "sequential download $i failed"; return 1; }
  done
  local name; name=e2e-churn
  d run -d --name "$name" "$IMG" sh -c "n=0; while [ \$n -lt 6 ]; do wget -q -T 20 -O /dev/null $url || { echo failed > /tmp/failed; }; n=\$((n+1)); done; echo done > /tmp/done; sleep 60" >/dev/null
  for i in 1 2 3 4 5 6; do d run --rm "$IMG" true; done
  local tries=0
  until d exec "$name" test -e /tmp/done; do
    tries=$((tries + 1)); [ "$tries" -lt 120 ] || { echo "looping download never finished"; return 1; }
    sleep 0.5
  done
  if d exec "$name" test -e /tmp/failed; then echo "a download failed during churn"; return 1; fi
  d rm -f "$name" >/dev/null
}

# A second network coming and going does not move the first network's bridge address.
t_netstable_bridge_mac_is_stable() {
  local net; net=e2e-net; d network create "$net" >/dev/null
  d run -d --name "$net-a" --network "$net" "$IMG" sleep 60 >/dev/null
  local gw; gw=$(d network inspect -f '{{(index .IPAM.Config 0).Gateway}}' "$net")
  d exec "$net-a" ping -c1 -W2 "$gw" >/dev/null
  local before after i
  before=$(d exec "$net-a" sh -c "ip neigh show $gw | cut -d' ' -f5")
  [ -n "$before" ]
  for i in 1 2 3 4 5; do
    d run -d --name "$net-t$i" --network "$net" "$IMG" sleep 30 >/dev/null
  done
  for i in 1 2 3 4 5; do d rm -f "$net-t$i" >/dev/null; done
  d exec "$net-a" ping -c1 -W2 "$gw" >/dev/null
  after=$(d exec "$net-a" sh -c "ip neigh show $gw | cut -d' ' -f5")
  [ "$before" = "$after" ] || { echo "gateway MAC moved: $before to $after"; return 1; }
  d rm -f "$net-a" >/dev/null; d network rm "$net" >/dev/null
}

t_netstable_ping_without_root() {
  local gw
  d run --rm --user 1000 "$IMG" sh -c 'gw=$(ip route | sed -n "s/^default via \([0-9.]*\).*/\1/p"); ping -c1 -W2 "$gw"' >/dev/null \
    || { echo "non-root ping failed on bridge"; return 1; }
  local net; net=e2e-net; d network create "$net" >/dev/null
  d run --rm --user 1000 --cap-drop NET_RAW --network "$net" "$IMG" sh -c 'gw=$(ip route | sed -n "s/^default via \([0-9.]*\).*/\1/p"); ping -c1 -W2 "$gw"' >/dev/null \
    || { echo "non-root ping without NET_RAW failed on user network"; return 1; }
  d network rm "$net" >/dev/null
  got=$(d run --rm "$IMG" cat /proc/sys/net/ipv4/ping_group_range)
  local low high extra; read -r low high extra <<<"$got"
  [ "$low $high" = "0 2147483647" ] && [ -z "$extra" ] || { echo "ping_group_range: $got"; return 1; }
}

t_netstable_ping_range_can_be_overridden() {
  got=$(d run --rm --sysctl net.ipv4.ping_group_range="1 0" "$IMG" cat /proc/sys/net/ipv4/ping_group_range)
  local low high extra; read -r low high extra <<<"$got"
  [ "$low $high" = "1 0" ] && [ -z "$extra" ] || { echo "ping_group_range override: $got"; return 1; }
  got=$(d run --rm --sysctl net.ipv4.ip_unprivileged_port_start=1024 "$IMG" cat /proc/sys/net/ipv4/ip_unprivileged_port_start)
  [ "$got" = 1024 ] || { echo "unprivileged port override: $got"; return 1; }
}

# With the VM's resolver gone, names still resolve through the Mac. Blocks port 53 towards it from the VM's own table.
t_netstable_dns_survives_resolver_loss() {
  d run --rm "$IMG" nslookup dl-cdn.alpinelinux.org >/dev/null 2>&1 || { echo "no uplink"; return 77; }
  local nf; nf=e2e-nf
  nf_start "$nf" || return 1
  d exec "$nf" sh -c 'nft add table ip losedns; nft "add chain ip losedns out { type filter hook output priority 0; }"; nft add rule ip losedns out udp dport 53 drop'
  local name=dl-cdn.alpinelinux.org rc=0
  d run --rm "$IMG" nslookup "$name" >/dev/null 2>&1 || rc=1
  local net; net=e2e-net; d network create "$net" >/dev/null
  d run --rm --network "$net" "$IMG" nslookup "$name" >/dev/null 2>&1 || rc=2
  d exec "$nf" nft delete table ip losedns
  d rm -f "$nf" >/dev/null; d network rm "$net" >/dev/null
  [ "$rc" = 0 ] || { echo "resolution failed with the resolver blocked: $rc"; return 1; }
}

# A named --dns server is honoured even when it does not answer: no quiet fallback.
t_netstable_custom_dns_is_not_second_guessed() {
  if d run --rm --dns 10.255.255.1 "$IMG" nslookup -timeout=2 dl-cdn.alpinelinux.org >/dev/null 2>&1; then
    echo "name resolved although the only --dns server is dead"; return 1
  fi
}

# --- nftables per-expression acceptance. Each rule goes through the real nft in a privileged container.
nft_accept() {
  local rule=$1 family=${2:-inet}
  local nf; nf=e2e-nf
  nf_start "$nf" || return 1
  local rc=0
  d exec "$nf" sh -ec "nft add table $family accept_t; nft 'add chain $family accept_t c { type filter hook input priority 0; policy accept; }'; nft add rule $family accept_t c $rule; nft list table $family accept_t" || rc=$?
  d exec "$nf" nft delete table "$family" accept_t >/dev/null 2>&1 || true
  d rm -f "$nf" >/dev/null
  return "$rc"
}
# --- Firewall kernel parity. Keep this block together for additive lane merges.
# All rules stay in a container network namespace, never the VM's host namespace.
# Removing the container removes its rules even after a failed assertion (sweep).
firewall_d() { timeout 60 "$DOCKER" "$@"; }
firewall_prepare() {
  local kind=$1; shift
  FW_NET=e2e-firewall-$kind
  FW_CLIENT=$FW_NET-client
  FW_PEER=$FW_NET-peer
  firewall_d network create "$FW_NET" >/dev/null
  firewall_d run -d --name "$FW_PEER" --network "$FW_NET" --cap-add NET_ADMIN "$IMG" sh -ec '
    printf "%s\n" "#!/bin/sh" '\''printf "HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\nhi\n"'\'' > /tmp/reply
    chmod +x /tmp/reply
    exec nc -lk -p 80 -e /tmp/reply' >/dev/null
  firewall_d run -d --name "$FW_CLIENT" --network "$FW_NET" --cap-add NET_ADMIN "$IMG" sleep 600 >/dev/null
  # A stalled download never fails by itself, so each attempt gets its own limit.
  timeout 150 "$DOCKER" exec "$FW_CLIENT" sh -c 'for i in 1 2 3 4 5; do timeout 25 apk add --no-cache "$@" && exit 0; sleep 2; done; exit 1' sh "$@"
  FW_IP=$(firewall_d inspect -f "{{(index .NetworkSettings.Networks \"$FW_NET\").IPAddress}}" "$FW_PEER")
  nonempty "$FW_IP" firewall-peer-ip
  wait_for 15 firewall_d exec "$FW_CLIENT" wget -q -T 2 -O /dev/null "http://$FW_IP"
  firewall_d exec "$FW_CLIENT" ping -c 1 -W 2 "$FW_IP" >/dev/null
}
firewall_ping() { firewall_d exec "$FW_CLIENT" ping -c 1 -W 2 "$FW_IP" >/dev/null; }
firewall_done() {
  firewall_d rm -f "$FW_CLIENT" "$FW_PEER" >/dev/null
  firewall_d network rm "$FW_NET" >/dev/null
}

t_firewall_nft() {
  # Missing nf_tables/inet/counter/reject breaks blocking or the packet counter.
  firewall_prepare nft nftables
  firewall_d exec "$FW_CLIENT" sh -ec '
    nft add table inet parity
    nft "add chain inet parity out { type filter hook output priority 0; policy accept; }"
    nft add rule inet parity out ip daddr "$1" icmp type echo-request counter reject
  ' sh "$FW_IP"
  exit_is 1 firewall_ping
  firewall_d exec "$FW_CLIENT" nft list chain inet parity out | grep -Eq 'counter packets [1-9][0-9]* .*reject'
  firewall_d exec "$FW_CLIENT" nft delete table inet parity
  firewall_ping
  firewall_done
}

t_firewall_iptables() {
  # Both userspace backends must block real traffic and DNAT TCP to the peer.
  firewall_prepare iptables iptables iptables-legacy
  local tool
  for tool in iptables-nft iptables-legacy; do
    case $tool in
      iptables-nft) has "$(firewall_d exec "$FW_CLIENT" "$tool" --version)" nf_tables ;;
      iptables-legacy) has "$(firewall_d exec "$FW_CLIENT" "$tool" --version)" legacy ;;
    esac
    firewall_d exec "$FW_CLIENT" "$tool" -A OUTPUT -d "$FW_IP" -p icmp -m conntrack --ctstate NEW -m comment --comment parity -j REJECT
    exit_is 1 firewall_ping
    firewall_d exec "$FW_CLIENT" "$tool" -nvL OUTPUT | grep -Eq '[1-9][0-9]*[[:space:]]+[0-9]+[[:space:]]+REJECT'
    firewall_d exec "$FW_CLIENT" "$tool" -F OUTPUT
    firewall_ping
    firewall_d exec "$FW_CLIENT" "$tool" -t nat -A OUTPUT -d "$FW_IP" -p tcp --dport 18080 -j DNAT --to-destination "$FW_IP:80"
    eq "$(firewall_d exec "$FW_CLIENT" wget -q -T 3 -O - "http://$FW_IP:18080")" hi
    firewall_d exec "$FW_CLIENT" "$tool" -t nat -F OUTPUT
    # Exercise xtables matches and targets without redirecting unrelated traffic.
    firewall_d exec "$FW_CLIENT" sh -ec '
      t=$1; peer=$2
      "$t" -t mangle -N PARITY
      "$t" -t mangle -A PARITY -p tcp -m multiport --dports 80,443 -m addrtype --dst-type UNICAST -j MARK --set-mark 7
      "$t" -t mangle -A PARITY -m mark --mark 7 -j LOG --log-prefix parity
      "$t" -t nat -N PARITY
      "$t" -t nat -A PARITY -p tcp -j REDIRECT --to-ports 80
      "$t" -t nat -A POSTROUTING -d "$peer" -j MASQUERADE
      "$t" -t nat -A POSTROUTING -d "$peer" -j SNAT --to-source 192.0.2.1
      "$t" -t nat -S
      "$t" -t mangle -S
      "$t" -t nat -F POSTROUTING
    ' sh "$tool" "$FW_IP"
  done
  firewall_done
}

t_firewall_ipset() {
  # A set-backed legacy rule must follow membership changes on real packets.
  firewall_prepare ipset ipset iptables iptables-legacy
  firewall_d exec "$FW_CLIENT" sh -ec '
    ipset create peers hash:ip
    ipset add peers "$1"
    ipset create groups list:set
    ipset add groups peers
    ipset test peers "$1"
    iptables-legacy -A OUTPUT -p icmp -m set --match-set groups dst -j REJECT
  ' sh "$FW_IP"
  exit_is 1 firewall_ping
  firewall_d exec "$FW_CLIENT" ipset del peers "$FW_IP"
  firewall_ping
  firewall_d exec "$FW_CLIENT" ipset list groups | grep -q peers
  # Remaining hash types need no traffic topology; creating/listing catches a
  # type omitted from a no-modules kernel, including the kube-router variants.
  firewall_d exec "$FW_CLIENT" sh -ec '
    n=0
    for type in hash:mac hash:ip,mac hash:net hash:net,net hash:ip,port hash:net,port hash:ip,port,ip hash:ip,port,net hash:net,port,net hash:net,iface hash:ip,mark; do
      n=$((n + 1))
      ipset create "hash$n" "$type"
      ipset list "hash$n" | grep -F "Type: $type"
    done
  '
  firewall_done
}

t_firewall_ipvs() {
  firewall_prepare ipvs ipvsadm
  # End-to-end NAT needs a routed VIP and backend return route. Assert service,
  # scheduler, real-server and Masq listings inside this isolated namespace.
  local scheduler
  for scheduler in rr wrr lc sh; do
    firewall_d exec "$FW_CLIENT" ipvsadm -A -t 192.0.2.100:8080 -s "$scheduler"
    firewall_d exec "$FW_CLIENT" ipvsadm -a -t 192.0.2.100:8080 -r "$FW_IP:80" -m -w 1
    local listing; listing=$(firewall_d exec "$FW_CLIENT" ipvsadm -Ln)
    has "$listing" "192.0.2.100:8080 $scheduler"
    has "$listing" "$FW_IP:80"
    has "$listing" Masq
    firewall_d exec "$FW_CLIENT" ipvsadm -D -t 192.0.2.100:8080
  done
  firewall_done
}

t_firewall_tc() {
  # netem loss must interrupt real peer traffic, and deletion must restore it.
  firewall_prepare tc iproute2-tc
  firewall_d exec "$FW_CLIENT" tc qdisc add dev eth0 root netem loss 100%
  exit_is 1 firewall_ping
  has "$(firewall_d exec "$FW_CLIENT" tc qdisc show dev eth0)" 'loss 100%'
  firewall_d exec "$FW_CLIENT" tc qdisc del dev eth0 root
  firewall_ping
  firewall_d exec "$FW_CLIENT" sh -ec '
    tc qdisc add dev eth0 root handle 1: htb default 10
    tc class add dev eth0 parent 1: classid 1:10 htb rate 10mbit
    tc qdisc add dev eth0 parent 1:10 handle 10: fq_codel
    tc filter add dev eth0 parent 1: protocol ip pref 1 u32 match ip dst "$1/32" flowid 1:10
    tc filter add dev eth0 parent 1: protocol ip pref 2 flower dst_ip "$1" classid 1:10
    tc filter add dev eth0 parent 1: protocol all pref 3 matchall classid 1:10
    tc filter add dev eth0 parent 1: protocol all pref 4 handle 1 cgroup
    tc filter add dev eth0 parent 1: protocol all pref 5 bpf bytecode "1,6 0 0 1" flowid 1:10
    tc class show dev eth0 | grep "htb 1:10"
    tc qdisc show dev eth0 | grep fq_codel
    for kind in u32 flower matchall cgroup bpf; do
      tc filter show dev eth0 parent 1: | grep "$kind"
    done
  ' sh "$FW_IP"
  firewall_ping
  firewall_done
}
# --- End firewall kernel parity.

t_nft_reject() { nft_accept 'tcp dport 65001 reject with tcp reset'; }
t_nft_queue() { nft_accept 'tcp dport 65002 queue num 7 bypass'; }
t_nft_ct_label() { nft_accept 'tcp dport 65003 ct label set 5'; }
t_nft_socket() { nft_accept 'tcp dport 65004 socket transparent 1 accept'; }
t_nft_log() { nft_accept 'tcp dport 65005 log prefix "noodle-e2e "'; }
t_nft_limit() { nft_accept 'tcp dport 65006 limit rate 5/second accept'; }
t_nft_quota() { nft_accept 'tcp dport 65007 quota over 1 mbytes drop'; }
t_nft_tproxy() {
  local nf; nf=e2e-nf
  nf_start "$nf" || return 1
  local rc=0
  d exec "$nf" sh -ec "nft add table ip accept_t; nft 'add chain ip accept_t c { type filter hook prerouting priority -150; }'; nft add rule ip accept_t c tcp dport 65008 tproxy to 127.0.0.1:65009; nft list table ip accept_t" || rc=$?
  d exec "$nf" nft delete table ip accept_t >/dev/null 2>&1 || true
  d rm -f "$nf" >/dev/null
  return "$rc"
}

# --------------------------------------------------------------------- IPv6 dual stack (net lane)
ip6_on() { insp "$1" "{{(index .NetworkSettings.Networks \"$2\").GlobalIPv6Address}}" | noaddr; }
ip6_pool() { d network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' "$1"; }

t_ipv6_v4_network_has_no_v6_address() {
  d network create e2e-v4 >/dev/null
  eq "$(d network inspect -f '{{.EnableIPv6}}' e2e-v4)" false
  eq "$(d network inspect -f '{{.EnableIPv4}}' e2e-v4)" true
  sleeper e2e-v41 --network e2e-v4
  eq "$(ip6_on e2e-v41 e2e-v4)" ""
  lacks "$(d exec e2e-v41 ip -6 addr show eth0)" inet6
  has "$(d exec e2e-v41 ip -6 addr show lo)" ::1
}
t_ipv6_default_bridge_stays_v4() {
  eq "$(d network inspect -f '{{.EnableIPv6}}' bridge)" false
  sleeper e2e-b1
  eq "$(insp e2e-b1 '{{.NetworkSettings.GlobalIPv6Address}}')" ""
  nonempty "$(insp e2e-b1 '{{.NetworkSettings.IPAddress}}')" "bridge IPv4"
}
t_ipv6_auto_pool_is_ula_and_distinct() {
  d network create --ipv6 e2e-a1 >/dev/null
  d network create --ipv6 e2e-a2 >/dev/null
  local a b; a=$(ip6_pool e2e-a1); b=$(ip6_pool e2e-a2)
  has "$a" "fd"; has "$a" "/64"; has "$b" "/64"
  [ "$a" != "$b" ] || { echo "both networks got $a"; return 1; }
  eq "$(d network inspect -f '{{.EnableIPv6}}' e2e-a1)" true
  nonempty "$(d network inspect -f '{{(index .IPAM.Config 0).Subnet}}' e2e-a1)" "IPv4 pool stays"
}
t_ipv6_explicit_subnet_and_gateway() {
  d network create --ipv6 --subnet fd77:1::/64 --gateway fd77:1::fe e2e-e1 >/dev/null
  has "$(ip6_pool e2e-e1)" fd77:1::/64
  eq "$(d network inspect -f '{{range .IPAM.Config}}{{.Gateway}} {{end}}' e2e-e1 | tr ' ' '\n' | grep -c fd77:1::fe)" 1
  sleeper e2e-e11 --network e2e-e1
  eq "$(ip6_on e2e-e11 e2e-e1)" fd77:1::1
  eq "$(insp e2e-e11 '{{(index .NetworkSettings.Networks "e2e-e1").IPv6Gateway}}')" fd77:1::fe
  eq "$(insp e2e-e11 '{{(index .NetworkSettings.Networks "e2e-e1").GlobalIPv6PrefixLen}}')" 64
  has "$(d exec e2e-e11 ip -6 route)" "default via fd77:1::fe"
}
t_ipv6_pool_rules() {
  d network create --ipv6 --subnet fd77:2::/64 e2e-o1 >/dev/null
  local out
  out=$(d network create --ipv6 --subnet fd77:2::/80 e2e-o2 2>&1) && { echo "overlap accepted"; return 1; }
  has "$out" "overlaps"
  fails d network create --ipv6 --subnet fd77:zz::/64 e2e-o3
  out=$(d network create --ipv6 --subnet fd77:3::/64 --gateway fd77:4::1 e2e-o4 2>&1) && { echo "gateway outside accepted"; return 1; }
  has "$out" "gateway"
  # Without --ipv6 a v6 pool is ignored rather than refused.
  d network create --subnet fd77:5::/64 e2e-o5 >/dev/null
  eq "$(d network inspect -f '{{.EnableIPv6}}' e2e-o5)" false
  lacks "$(ip6_pool e2e-o5)" fd77:5
}
t_ipv6_ip_range_and_aux_address() {
  d network create --ipv6 --subnet fd77:6::/64 --ip-range fd77:6::80/121 --aux-address router=fd77:6::81 e2e-rg >/dev/null
  sleeper e2e-rg1 --network e2e-rg; eq "$(ip6_on e2e-rg1 e2e-rg)" fd77:6::80
  sleeper e2e-rg2 --network e2e-rg; eq "$(ip6_on e2e-rg2 e2e-rg)" fd77:6::82
}
t_ipv6_peers_ping_by_address_and_name() {
  d network create --ipv6 --subnet fd77:7::/64 e2e-pp >/dev/null
  sleeper e2e-pp1 --network e2e-pp; sleeper e2e-pp2 --network e2e-pp
  local ip; ip=$(ip6_on e2e-pp2 e2e-pp)
  has "$(d exec e2e-pp2 ip -6 addr show eth0)" "$ip/64"
  d exec e2e-pp1 ping -6 -c1 -W5 "$ip" >/dev/null
  d exec e2e-pp1 ping -6 -c1 -W5 e2e-pp2 >/dev/null
}
t_ipv6_hosts_has_localhost_and_own_address() {
  d network create --ipv6 --subnet fd77:8::/64 e2e-hs >/dev/null
  sleeper e2e-hs1 --network e2e-hs
  local h; h=$(d exec e2e-hs1 cat /etc/hosts)
  has "$h" "ip6-localhost"
  has "$h" "fd77:8::2"
}
t_ipv6_aaaa_and_a_records() {
  d network create --ipv6 --subnet fd77:9::/64 e2e-dn >/dev/null
  sleeper e2e-dn1 --network e2e-dn; sleeper e2e-dn2 --network e2e-dn
  local ip; ip=$(ip6_on e2e-dn2 e2e-dn)
  has "$(d exec e2e-dn1 nslookup -type=AAAA e2e-dn2 127.0.0.11)" "$ip"
  has "$(d exec e2e-dn1 nslookup -type=A e2e-dn2 127.0.0.11)" "$(ip_on e2e-dn2 e2e-dn)"
}
t_ipv6_aaaa_is_empty_on_a_v4_network() {
  d network create e2e-d4 >/dev/null
  sleeper e2e-d41 --network e2e-d4; sleeper e2e-d42 --network e2e-d4
  lacks "$(d exec e2e-d41 nslookup -type=AAAA e2e-d42 127.0.0.11 2>&1)" "fd6e:"
  has "$(d exec e2e-d41 nslookup -type=A e2e-d42 127.0.0.11)" "$(ip_on e2e-d42 e2e-d4)"
}
t_ipv6_static_address_rules() {
  d network create --ipv6 --subnet fd77:a::/64 e2e-st >/dev/null
  sleeper e2e-st1 --network e2e-st --ip6 fd77:a::50
  eq "$(ip6_on e2e-st1 e2e-st)" fd77:a::50
  eq "$(insp e2e-st1 '{{(index .NetworkSettings.Networks "e2e-st").IPAMConfig.IPv6Address}}')" fd77:a::50
  has "$(d exec e2e-st1 ip -6 addr show eth0)" fd77:a::50/64
  local out
  out=$(d run -d --name e2e-st2 --network e2e-st --ip6 fd77:a::50 "$IMG" sleep 60 2>&1) && { echo "address in use accepted"; return 1; }
  has "$out" "in use"
  fails d run -d --name e2e-st3 --network e2e-st --ip6 fd77:b::1 "$IMG" sleep 60
  fails d run -d --name e2e-st4 --network e2e-st --ip6 not-an-ip "$IMG" sleep 60
}
t_ipv6_static_address_needs_a_user_subnet() {
  d network create e2e-sv >/dev/null
  fails d run -d --name e2e-sv1 --network e2e-sv --ip6 fd77:c::5 "$IMG" sleep 60
  d network create --ipv6 e2e-sa >/dev/null
  fails d run -d --name e2e-sa1 --network e2e-sa --ip6 "$(ip6_pool e2e-sa | tr ' ' '\n' | sed -n 's#::/64#::99#p')" "$IMG" sleep 60
  fails d run -d --name e2e-sb1 --ip6 fd77:d::5 "$IMG" sleep 60
}
t_ipv6_static_address_survives_restart() {
  d network create --ipv6 --subnet fd77:e::/64 e2e-sr >/dev/null
  sleeper e2e-sr1 --network e2e-sr --ip6 fd77:e::77
  d restart -t 0 e2e-sr1 >/dev/null
  eq "$(ip6_on e2e-sr1 e2e-sr)" fd77:e::77
  has "$(d exec e2e-sr1 ip -6 addr show eth0)" fd77:e::77/64
}
t_ipv6_connect_with_static_address() {
  d network create --ipv6 --subnet fd77:f::/64 e2e-cn >/dev/null
  sleeper e2e-cn1
  d network connect --ip6 fd77:f::33 e2e-cn e2e-cn1
  eq "$(ip6_on e2e-cn1 e2e-cn)" fd77:f::33
  has "$(d network inspect -f '{{range .Containers}}{{.IPv6Address}}{{end}}' e2e-cn)" fd77:f::33/64
  sleeper e2e-cn2 --network e2e-cn
  d exec e2e-cn2 ping -6 -c1 -W5 fd77:f::33 >/dev/null
  d network disconnect e2e-cn e2e-cn1
  sleeper e2e-cn3 --network e2e-cn --ip6 fd77:f::33
  eq "$(ip6_on e2e-cn3 e2e-cn)" fd77:f::33
}
t_ipv6_only_network() {
  fails d network create --ipv4=false e2e-no
  d network create --ipv4=false --ipv6 --subnet fd78:1::/64 e2e-v6 >/dev/null
  eq "$(d network inspect -f '{{.EnableIPv4}}' e2e-v6)" false
  eq "$(ip6_pool e2e-v6)" "fd78:1::/64 "
  sleeper e2e-v61 --network e2e-v6; sleeper e2e-v62 --network e2e-v6
  eq "$(ip_on e2e-v61 e2e-v6)" ""
  eq "$(ip6_on e2e-v61 e2e-v6)" fd78:1::2
  lacks "$(d exec e2e-v61 ip -4 addr show eth0)" inet
  d exec e2e-v61 ping -6 -c1 -W5 e2e-v62 >/dev/null
  has "$(d exec e2e-v61 nslookup -type=AAAA e2e-v62 127.0.0.11)" fd78:1::3
  lacks "$(d exec e2e-v61 nslookup -type=A e2e-v62 127.0.0.11 2>&1)" "Address: fd78"
}
t_ipv6_only_network_ignores_v4_pool() {
  d network create --ipv4=false --ipv6 --subnet 10.78.0.0/24 --subnet fd78:2::/64 e2e-v7 >/dev/null
  lacks "$(ip6_pool e2e-v7)" 10.78
  has "$(ip6_pool e2e-v7)" fd78:2::/64
}
t_ipv6_container_can_opt_out() {
  d network create --ipv6 --subnet fd78:3::/64 e2e-oo >/dev/null
  sleeper e2e-oo1 --network e2e-oo --sysctl net.ipv6.conf.all.disable_ipv6=1
  sleeper e2e-oo2 --network e2e-oo
  eq "$(ip6_on e2e-oo1 e2e-oo)" ""
  nonempty "$(ip_on e2e-oo1 e2e-oo)" "IPv4 stays"
  lacks "$(d exec e2e-oo2 nslookup -type=AAAA e2e-oo1 127.0.0.11 2>&1)" fd78:3
}
t_ipv6_second_network_adds_a_family() {
  d network create e2e-m4 >/dev/null
  d network create --ipv4=false --ipv6 --subnet fd78:4::/64 e2e-m6 >/dev/null
  sleeper e2e-m1 --network e2e-m4
  d network connect e2e-m6 e2e-m1
  has "$(d exec e2e-m1 ip -6 addr)" fd78:4::
  nonempty "$(ip_on e2e-m1 e2e-m4)" "IPv4 on the first network"
}
t_ipv6_port_lists_both_families() {
  serve e2e-pa -p "$(port 70):80"
  wait_for 10 http_get "http://127.0.0.1:$(port 70)/"
  local out; out=$(d port e2e-pa 80)
  has "$out" "0.0.0.0:$(port 70)"
  has "$out" "[::]:$(port 70)"
  has "$(http_get "http://127.0.0.1:$(port 70)/")" hi
  has "$(http_get "http://[::1]:$(port 70)/")" hi
}
t_ipv6_localhost_publish_only_binds_v6() {
  serve e2e-pl -p "[::1]:$(port 71):80"
  eq "$(d port e2e-pl 80)" "[::1]:$(port 71)"
  wait_for 10 http_get "http://[::1]:$(port 71)/"
  has "$(http_get "http://[::1]:$(port 71)/")" hi
  fails curl -sf --max-time 2 "http://127.0.0.1:$(port 71)/"
}
t_ipv6_ephemeral_publish_shares_one_port() {
  serve e2e-pe -p 80
  local a b
  a=$(d port e2e-pe 80 | sed -n 's/^0\.0\.0\.0://p'); b=$(d port e2e-pe 80 | sed -n 's/^\[::\]://p')
  nonempty "$a" "IPv4 port"
  eq "$b" "$a"
}
t_ipv6_publish_conflict_on_v6_refused() {
  serve e2e-pc -p "[::1]:$(port 72):80"
  local out
  out=$(d run -d --name e2e-pc2 -p "[::1]:$(port 72):80" "$IMG" sleep 60 2>&1) && { echo "second bind accepted"; return 1; }
  has "$out" "already allocated"
  wait_for 10 http_get "http://[::1]:$(port 72)/"
}
# A Mac program holding the port is named after Docker's own message.
t_port_conflict_names_mac_program() {
  local p; p=$(port 190)
  python3 -c 'import socket,sys,time; s=socket.socket(); s.bind(("0.0.0.0",int(sys.argv[1]))); s.listen(1); time.sleep(60)' "$p" &
  local holder=$!
  wait_for 5 nc -z 127.0.0.1 "$p" || { kill "$holder"; echo "holder did not start"; return 1; }
  local out rc=0
  out=$(d run -d --name e2e-pn -p "$p:80" "$IMG" sleep 60 2>&1) || rc=$?
  kill "$holder" 2>/dev/null; d rm -f e2e-pn >/dev/null 2>&1
  [ "$rc" != 0 ] || { echo "publish onto a held port succeeded"; return 1; }
  has "$out" "port is already allocated (in use by "
  has "$out" "pid $holder"
}
t_ipv6_only_container_published_on_v4_localhost() {
  d network create --ipv4=false --ipv6 --subnet fd78:5::/64 e2e-p6 >/dev/null
  serve e2e-p61 --network e2e-p6 -p "127.0.0.1:$(port 73):80"
  wait_for 10 http_get "http://127.0.0.1:$(port 73)/"
  has "$(http_get "http://127.0.0.1:$(port 73)/")" hi
}
t_ipv6_dual_stack_publish_reaches_v6_address() {
  d network create --ipv6 --subnet fd78:6::/64 e2e-p7 >/dev/null
  serve e2e-p71 --network e2e-p7 -p "$(port 74):80"
  wait_for 10 http_get "http://[::1]:$(port 74)/"
  has "$(http_get "http://[::1]:$(port 74)/")" hi
  has "$(http_get "http://127.0.0.1:$(port 74)/")" hi
}
t_ipv6_udp_publish_on_v6_localhost() {
  d run -d --name e2e-pu -p "[::1]:$(port 75):7000/udp" "$IMG" sh -c 'nc -u -l -p 7000 | head -n 1' >/dev/null
  local tries=0
  while [ "$tries" -lt 10 ]; do
    printf 'ping-v6\n' | nc -6 -u -w1 ::1 "$(port 75)" || true
    case $(d logs e2e-pu 2>&1) in *ping-v6*) return 0 ;; esac
    tries=$((tries + 1)); sleep 0.5
  done
  echo "datagram never arrived"; return 1
}
t_ipv6_nat66_reaches_out_when_uplink_has_v6() {
  d network create --ipv6 --subnet fd78:7::/64 e2e-eg >/dev/null
  sleeper e2e-eg1 --network e2e-eg
  d exec e2e-eg1 ping -6 -c1 -W5 fd78:7::1 >/dev/null
  # Most uplinks have no IPv6, so a miss from the VM itself is a skip and not a failure.
  d run --rm --network host "$IMG" ping -6 -c1 -W5 2001:4860:4860::8888 >/dev/null 2>&1 || skip "VM uplink has no IPv6 route"
  d exec e2e-eg1 ping -6 -c1 -W5 2001:4860:4860::8888 >/dev/null
}
# uplinkGuardBatch: an inet forward-hook table drops NEW, non-DNAT flows that enter on the uplink (eth0).
# The guard stops outside peers (the other VM, the LAN) from opening connections into containers, so a container cannot
# dial it from inside. The case checks the installed rule, and that container-originated flows (replies) still pass.
t_ipv6_uplink_guard_drops_new_inbound_and_keeps_replies() {
  local nf=e2e-ug rules; nf_start "$nf" || return 1
  rules=$(d exec "$nf" nft list table inet noodle-uplink)
  has "$rules" 'hook forward'
  has "$rules" 'iifname "eth0"'
  has "$rules" drop
  d run --rm --network host "$IMG" ping -6 -c1 -W5 2001:4860:4860::8888 >/dev/null 2>&1 || skip "VM uplink has no IPv6 route"
  d network create --ipv6 --subnet fd78:b::/64 e2e-ugn >/dev/null
  sleeper e2e-ug1 --network e2e-ugn
  d exec e2e-ug1 ping -6 -c1 -W5 2001:4860:4860::8888 >/dev/null
  d run --rm "$IMG" ping -6 -c1 -W5 ::1 >/dev/null
}
t_ipv6_internal_network_has_no_egress() {
  d network create --internal --ipv6 --subnet fd78:8::/64 e2e-in >/dev/null
  sleeper e2e-in1 --network e2e-in; sleeper e2e-in2 --network e2e-in
  d exec e2e-in1 ping -6 -c1 -W5 e2e-in2 >/dev/null
  lacks "$(d exec e2e-in1 ip -6 route)" default
  fails d exec e2e-in1 ping -6 -c1 -W2 2001:4860:4860::8888
}
t_ipv6_network_removal_frees_the_pool() {
  d network create --ipv6 --subnet fd78:9::/64 e2e-fr >/dev/null
  sleeper e2e-fr1 --network e2e-fr
  d rm -f e2e-fr1 >/dev/null
  d network rm e2e-fr >/dev/null
  d network create --ipv6 --subnet fd78:9::/64 e2e-fr >/dev/null
  sleeper e2e-fr2 --network e2e-fr
  eq "$(ip6_on e2e-fr2 e2e-fr)" fd78:9::2
}
t_ipv6_nft_ip6_family_accepts_rules() {
  local nf; nf=e2e-nf
  nf_start "$nf" || return 1
  d exec "$nf" sh -c "nft add table ip6 e2e_t6; nft 'add chain ip6 e2e_t6 c { type filter hook input priority 0; }'; nft add rule ip6 e2e_t6 c tcp dport 65010 counter accept"
  d exec "$nf" nft delete table ip6 e2e_t6
}
t_ipv6_compose_enable_ipv6() {
  [ -x "$ROOT/build/tools/cli-plugins/docker-compose" ] || skip "compose plugin missing (scripts/fetch-tools.sh)"
  local c; c=$(mkctx)
  cat >"$c/compose.yaml" <<YML
services:
  fixed:
    image: $IMG
    command: sleep 600
    networks:
      dual:
        ipv6_address: fd78:a::20
  auto:
    image: $IMG
    command: sleep 600
    networks: [ula]
networks:
  dual:
    enable_ipv6: true
    ipam:
      config:
        - subnet: fd78:a::/64
  ula:
    enable_ipv6: true
YML
  local rc=0 fixed auto
  d compose -p e2e-v6c -f "$c/compose.yaml" up -d >/dev/null 2>&1 || rc=$?
  if [ "$rc" = 0 ]; then
    fixed=$(d compose -p e2e-v6c -f "$c/compose.yaml" ps -q fixed)
    auto=$(d compose -p e2e-v6c -f "$c/compose.yaml" ps -q auto)
    eq "$(ip6_on "$fixed" e2e-v6c_dual)" fd78:a::20 || rc=1
    has "$(ip6_on "$auto" e2e-v6c_ula)" fd || rc=1
  fi
  d compose -p e2e-v6c -f "$c/compose.yaml" down -v >/dev/null 2>&1
  return "$rc"
}

