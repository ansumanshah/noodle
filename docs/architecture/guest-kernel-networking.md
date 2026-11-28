# Guest kernel: networking options

`Resources/kernel/noodle.config` has a "container networking" block. All options are built in (`=y`); the kernel has no module loader. `scripts/build-kernel.sh` fails the build if kconfig drops any of them. Checked against Linux 6.18.35 Kconfig with `make ARCH=arm64 tinyconfig` plus `olddefconfig`.

| Options | Docker feature |
|---|---|
| `VETH`, `BRIDGE`, `BRIDGE_NETFILTER`, `INET`, `IPV6` | `docker network create` bridges and one veth pair per container; bridged traffic visible to the filter rules; IPv4 and dual-stack networks. No VLAN filtering is enabled. |
| `TUN` | `/dev/net/tun` in privileged containers (VPN clients, tunnels). |
| `IP_ADVANCED_ROUTER`, `IP_MULTIPLE_TABLES`, `IPV6_MULTIPLE_TABLES`, `IPV6_ROUTER_PREF`, `IPV6_ROUTE_INFO` | Containers attached to several networks (`docker network connect`); the VM keeps its IPv6 default route from router advertisements once forwarding is on (`accept_ra` = 2). |
| `NETFILTER`, `NETFILTER_ADVANCED`, `NETFILTER_NETLINK`, `NF_CONNTRACK`, `NF_CONNTRACK_MARK`, `NF_NAT` | Connection tracking and NAT under every rule below. |
| `NF_TABLES`, `NF_TABLES_INET`, `NF_TABLES_IPV4`, `NF_TABLES_IPV6`, `NFT_CT`, `NFT_NAT`, `NFT_MASQ`, `NFT_REDIR`, `NFT_REJECT`, `NFT_LIMIT`, `NFT_COMPAT` | The agent's own nftables tables: masquerade for outbound traffic, DNAT for published ports, drop-in-both-directions for `--internal` networks. `NFT_COMPAT` lets `iptables-nft` inside privileged containers (for example Docker-in-Docker) work. |
| `NETFILTER_XTABLES`, `NETFILTER_XTABLES_LEGACY`, `NETFILTER_XT_NAT`, `NETFILTER_XT_MATCH_{CONNTRACK,ADDRTYPE,MULTIPORT,COMMENT,MARK}`, `NETFILTER_XT_MARK`, `NETFILTER_XT_TARGET_{MASQUERADE,REDIRECT}`, `IP_NF_*`, `IP6_NF_*` | Legacy `iptables` and `ip6tables` in privileged containers: filter, nat, published-port matches (`multiport`, `addrtype`), per-container rules, connection-state matches. |
| `NET_SCHED`, `NET_SCH_HTB`, `NET_SCH_FQ_CODEL`, `NET_SCH_INGRESS`, `NET_CLS_ACT` | `tc` shaping inside privileged containers. |
| `INET_DIAG`, `INET_TCP_DIAG`, `INET_UDP_DIAG`, `UNIX_DIAG`, `PACKET_DIAG` | `ss` and similar tools in containers; `docker top`-style socket listing. |

ICMP echo for non-root users needs only `INET`: the agent sets `net.ipv4.ping_group_range` for each container.
