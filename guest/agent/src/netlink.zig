//! rtnetlink and nfnetlink message builders. Pure byte assembly, no sockets (see net.zig for I/O).
const std = @import("std");

pub const NLM_F_REQUEST = 0x1;
pub const NLM_F_ACK = 0x4;
pub const NLM_F_EXCL = 0x200;
pub const NLM_F_CREATE = 0x400;

pub const RTM_NEWLINK = 16;
pub const RTM_DELLINK = 17;
pub const RTM_GETLINK = 18;
pub const RTM_NEWADDR = 20;
pub const RTM_NEWROUTE = 24;

pub const IFLA_ADDRESS = 1;
pub const IFLA_IFNAME = 3;
pub const IFLA_MASTER = 10;
pub const IFLA_LINKINFO = 18;
pub const IFLA_NET_NS_PID = 19;
pub const IFLA_NET_NS_FD = 28;
pub const IFLA_INFO_KIND = 1;
pub const IFLA_INFO_DATA = 2;
pub const VETH_INFO_PEER = 1;
pub const IFF_UP = 1;

pub const IFA_ADDRESS = 1;
pub const IFA_LOCAL = 2;
pub const RTA_DST = 1;
pub const RTA_OIF = 4;
pub const RTA_GATEWAY = 5;

pub const AF_UNSPEC = 0;
pub const AF_INET = 2;
pub const AF_INET6 = 10;

pub const Builder = struct {
    buf: []u8,
    len: usize = 0,
    msg_start: usize = 0,

    pub fn init(buf: []u8) Builder {
        return .{ .buf = buf };
    }
    pub fn reset(self: *Builder) void {
        self.len = 0;
    }
    pub fn bytes(self: *const Builder) []const u8 {
        return self.buf[0..self.len];
    }
    fn put16(self: *Builder, v: u16) void {
        std.mem.writeInt(u16, self.buf[self.len..][0..2], v, .little);
        self.len += 2;
    }
    fn put32(self: *Builder, v: u32) void {
        std.mem.writeInt(u32, self.buf[self.len..][0..4], v, .little);
        self.len += 4;
    }
    fn putBytes(self: *Builder, b: []const u8) void {
        @memcpy(self.buf[self.len .. self.len + b.len], b);
        self.len += b.len;
        while (self.len % 4 != 0) : (self.len += 1) self.buf[self.len] = 0;
    }

    /// Start a message; returns nothing, call `end()` when done. Multiple messages may be appended (batches).
    pub fn begin(self: *Builder, msg_type: u16, flags: u16, seq: u32) void {
        self.msg_start = self.len;
        self.put32(0); // length, patched in end()
        self.put16(msg_type);
        self.put16(flags);
        self.put32(seq);
        self.put32(0); // pid
    }
    pub fn end(self: *Builder) void {
        std.mem.writeInt(u32, self.buf[self.msg_start..][0..4], @intCast(self.len - self.msg_start), .little);
    }

    pub fn ifinfomsg(self: *Builder, index: i32, flags: u32, change: u32) void {
        self.put16(0); // family AF_UNSPEC + pad
        self.put16(0); // type
        self.put32(@bitCast(index));
        self.put32(flags);
        self.put32(change);
    }
    pub fn ifaddrmsg(self: *Builder, prefix: u8, index: u32) void {
        self.ifaddrmsgFor(AF_INET, prefix, 0, index);
    }
    pub fn ifaddrmsgFor(self: *Builder, family: u8, prefix: u8, flags: u8, index: u32) void {
        self.buf[self.len] = family;
        self.buf[self.len + 1] = prefix;
        self.buf[self.len + 2] = flags;
        self.buf[self.len + 3] = 0; // RT_SCOPE_UNIVERSE
        self.len += 4;
        self.put32(index);
    }
    pub fn rtmsg(self: *Builder, dst_len: u8) void {
        self.rtmsgFor(AF_INET, dst_len);
    }
    pub fn rtmsgFor(self: *Builder, family: u8, dst_len: u8) void {
        // family, dst_len, src_len, tos, table(main=254), protocol(boot=3), scope(universe=0), type(unicast=1), flags
        const b = [_]u8{ family, dst_len, 0, 0, 254, 3, 0, 1 };
        @memcpy(self.buf[self.len .. self.len + 8], &b);
        self.len += 8;
        self.put32(0);
    }
    pub fn nfgenmsg(self: *Builder, family: u8, res_id: u16) void {
        self.buf[self.len] = family;
        self.buf[self.len + 1] = 0;
        self.len += 2;
        std.mem.writeInt(u16, self.buf[self.len..][0..2], res_id, .big);
        self.len += 2;
    }

    pub fn attr(self: *Builder, t: u16, data: []const u8) void {
        self.put16(@intCast(4 + data.len));
        self.put16(t);
        self.putBytes(data);
    }
    pub fn attrStr(self: *Builder, t: u16, s: []const u8) void {
        // NUL terminated
        self.put16(@intCast(4 + s.len + 1));
        self.put16(t);
        @memcpy(self.buf[self.len .. self.len + s.len], s);
        self.len += s.len;
        self.buf[self.len] = 0;
        self.len += 1;
        while (self.len % 4 != 0) : (self.len += 1) self.buf[self.len] = 0;
    }
    pub fn attrU32(self: *Builder, t: u16, v: u32) void {
        self.put16(8);
        self.put16(t);
        self.put32(v);
    }
    pub fn attrU32be(self: *Builder, t: u16, v: u32) void {
        self.put16(8);
        self.put16(t);
        std.mem.writeInt(u32, self.buf[self.len..][0..4], v, .big);
        self.len += 4;
    }
    /// Begin a nested attribute; returns the offset to pass to `nestEnd`.
    pub fn nest(self: *Builder, t: u16) usize {
        const off = self.len;
        self.put16(0);
        self.put16(t | 0x8000); // NLA_F_NESTED
        return off;
    }
    /// Same, without the NESTED flag (rtnetlink legacy attrs like IFLA_LINKINFO).
    pub fn nestPlain(self: *Builder, t: u16) usize {
        const off = self.len;
        self.put16(0);
        self.put16(t);
        return off;
    }
    pub fn nestEnd(self: *Builder, off: usize) void {
        std.mem.writeInt(u16, self.buf[off..][0..2], @intCast(self.len - off), .little);
    }
};

// ---- rtnetlink message recipes

/// RTM_NEWLINK request that creates a bridge with the given name and MAC. The kernel rejects it when the name exists.
pub fn newBridge(b: *Builder, seq: u32, name: []const u8, mac: [6]u8) void {
    b.begin(RTM_NEWLINK, NLM_F_REQUEST | NLM_F_ACK | NLM_F_CREATE | NLM_F_EXCL, seq);
    b.ifinfomsg(0, 0, 0);
    b.attrStr(IFLA_IFNAME, name);
    b.attr(IFLA_ADDRESS, &mac);
    const li = b.nestPlain(IFLA_LINKINFO);
    b.attrStr(IFLA_INFO_KIND, "bridge");
    b.nestEnd(li);
    b.end();
}

/// Create a veth pair. The peer is moved into the network namespace of `peer_netns_pid` and optionally given a MAC.
pub fn newVeth(b: *Builder, seq: u32, name: []const u8, peer: []const u8, peer_mac: ?[6]u8, peer_netns_pid: u32) void {
    b.begin(RTM_NEWLINK, NLM_F_REQUEST | NLM_F_ACK | NLM_F_CREATE | NLM_F_EXCL, seq);
    b.ifinfomsg(0, 0, 0);
    b.attrStr(IFLA_IFNAME, name);
    const li = b.nestPlain(IFLA_LINKINFO);
    b.attrStr(IFLA_INFO_KIND, "veth");
    const data = b.nestPlain(IFLA_INFO_DATA);
    const pe = b.nestPlain(VETH_INFO_PEER);
    b.ifinfomsg(0, 0, 0);
    b.attrStr(IFLA_IFNAME, peer);
    if (peer_mac) |m| b.attr(IFLA_ADDRESS, &m);
    b.attrU32(IFLA_NET_NS_PID, peer_netns_pid);
    b.nestEnd(pe);
    b.nestEnd(data);
    b.nestEnd(li);
    b.end();
}

pub fn setUp(b: *Builder, seq: u32, index: i32) void {
    b.begin(RTM_NEWLINK, NLM_F_REQUEST | NLM_F_ACK, seq);
    b.ifinfomsg(index, IFF_UP, IFF_UP);
    b.end();
}
pub fn setMaster(b: *Builder, seq: u32, index: i32, master: u32) void {
    b.begin(RTM_NEWLINK, NLM_F_REQUEST | NLM_F_ACK, seq);
    b.ifinfomsg(index, 0, 0);
    b.attrU32(IFLA_MASTER, master);
    b.end();
}
pub fn setName(b: *Builder, seq: u32, index: i32, name: []const u8) void {
    b.begin(RTM_NEWLINK, NLM_F_REQUEST | NLM_F_ACK, seq);
    b.ifinfomsg(index, 0, 0);
    b.attrStr(IFLA_IFNAME, name);
    b.end();
}
pub fn delLink(b: *Builder, seq: u32, index: i32) void {
    b.begin(RTM_DELLINK, NLM_F_REQUEST | NLM_F_ACK, seq);
    b.ifinfomsg(index, 0, 0);
    b.end();
}
pub fn getLink(b: *Builder, seq: u32, name: []const u8) void {
    b.begin(RTM_GETLINK, NLM_F_REQUEST, seq);
    b.ifinfomsg(0, 0, 0);
    b.attrStr(IFLA_IFNAME, name);
    b.end();
}
pub fn addAddr(b: *Builder, seq: u32, index: u32, ip: [4]u8, prefix: u8) void {
    b.begin(RTM_NEWADDR, NLM_F_REQUEST | NLM_F_ACK | NLM_F_CREATE | NLM_F_EXCL, seq);
    b.ifaddrmsg(prefix, index);
    b.attr(IFA_LOCAL, &ip);
    b.attr(IFA_ADDRESS, &ip);
    b.end();
}
pub fn addDefaultRoute(b: *Builder, seq: u32, gw: [4]u8) void {
    b.begin(RTM_NEWROUTE, NLM_F_REQUEST | NLM_F_ACK | NLM_F_CREATE | NLM_F_EXCL, seq);
    b.rtmsg(0);
    b.attr(RTA_GATEWAY, &gw);
    b.end();
}

/// Install a usable IPv6 address immediately with IFA_F_NODAD (0x02).
/// NLM_F_EXCL rejects an address that is already installed.
pub fn addAddr6(b: *Builder, seq: u32, index: u32, ip: [16]u8, prefix: u8) void {
    b.begin(RTM_NEWADDR, NLM_F_REQUEST | NLM_F_ACK | NLM_F_CREATE | NLM_F_EXCL, seq);
    b.ifaddrmsgFor(AF_INET6, prefix, 0x02, index);
    b.attr(IFA_LOCAL, &ip);
    b.attr(IFA_ADDRESS, &ip);
    b.end();
}
pub fn addDefaultRoute6(b: *Builder, seq: u32, index: u32, gw: [16]u8) void {
    b.begin(RTM_NEWROUTE, NLM_F_REQUEST | NLM_F_ACK | NLM_F_CREATE | NLM_F_EXCL, seq);
    b.rtmsgFor(AF_INET6, 0);
    b.attr(RTA_GATEWAY, &gw);
    b.attr(RTA_OIF, std.mem.asBytes(&index));
    b.end();
}

// ---- nftables (nfnetlink). One table per network with a nat postrouting chain and a masquerade rule.

const NFNL_SUBSYS_NFTABLES = 10;
const NFNL_MSG_BATCH_BEGIN = 0x10;
const NFNL_MSG_BATCH_END = 0x11;
const NFT_MSG_NEWTABLE = 0;
const NFT_MSG_DELTABLE = 2;
const NFT_MSG_NEWCHAIN = 3;
const NFT_MSG_NEWRULE = 6;
pub const NFPROTO_INET = 1;
pub const NFPROTO_IPV4 = 2;
pub const NFPROTO_IPV6 = 10;

fn nftType(m: u16) u16 {
    return (NFNL_SUBSYS_NFTABLES << 8) | m;
}

fn expr(b: *Builder, name: []const u8) usize {
    const el = b.nest(1); // NFTA_LIST_ELEM
    b.attrStr(1, name); // NFTA_EXPR_NAME
    return el;
}

fn dataValue(b: *Builder, t: u16, v: []const u8) void {
    const n = b.nest(t);
    b.attr(1, v); // NFTA_DATA_VALUE
    b.nestEnd(n);
}

/// Number of messages in the batch whose ACKs the caller should expect (excluding BATCH_BEGIN/END, which are silent).
pub const nat_batch_acks = 3;

/// Batch: create table `tname`, chain "postrouting" (nat, hook postrouting, prio 100), rule
/// `ip saddr subnet/prefix oifname != bridge masquerade`.
pub fn natMasqueradeBatch(b: *Builder, seq: u32, tname: []const u8, subnet: [4]u8, prefix: u8, bridge: []const u8) void {
    natBatch(b, seq, tname, NFPROTO_IPV4, 12, &subnet, prefix, bridge);
}

/// The same for `ip6 saddr`, in a table of the ip6 family. The source field sits at offset 8.
pub fn natMasquerade6Batch(b: *Builder, seq: u32, tname: []const u8, subnet: [16]u8, prefix: u8, bridge: []const u8) void {
    natBatch(b, seq, tname, NFPROTO_IPV6, 8, &subnet, prefix, bridge);
}

fn natBatch(b: *Builder, seq: u32, tname: []const u8, family: u8, offset: u32, subnet: []const u8, prefix: u8, bridge: []const u8) void {
    b.begin(NFNL_MSG_BATCH_BEGIN, NLM_F_REQUEST, seq);
    b.nfgenmsg(AF_UNSPEC, NFNL_SUBSYS_NFTABLES);
    b.end();

    b.begin(nftType(NFT_MSG_NEWTABLE), NLM_F_REQUEST | NLM_F_ACK | NLM_F_CREATE, seq + 1);
    b.nfgenmsg(family, 0);
    b.attrStr(1, tname); // NFTA_TABLE_NAME
    b.end();

    b.begin(nftType(NFT_MSG_NEWCHAIN), NLM_F_REQUEST | NLM_F_ACK | NLM_F_CREATE, seq + 2);
    b.nfgenmsg(family, 0);
    b.attrStr(1, tname); // NFTA_CHAIN_TABLE
    b.attrStr(3, "postrouting"); // NFTA_CHAIN_NAME
    const hook = b.nest(4); // NFTA_CHAIN_HOOK
    b.attrU32be(1, 4); // NF_INET_POST_ROUTING
    b.attrU32be(2, 100); // srcnat priority
    b.nestEnd(hook);
    b.attrStr(7, "nat"); // NFTA_CHAIN_TYPE
    b.end();

    b.begin(nftType(NFT_MSG_NEWRULE), NLM_F_REQUEST | NLM_F_ACK | NLM_F_CREATE, seq + 3);
    b.nfgenmsg(family, 0);
    b.attrStr(1, tname); // NFTA_RULE_TABLE
    b.attrStr(2, "postrouting"); // NFTA_RULE_CHAIN
    const exprs = b.nest(4); // NFTA_RULE_EXPRESSIONS
    {
        // payload: reg1 = ip saddr (network header offset 12, 4 bytes)
        const e = expr(b, "payload");
        const d = b.nest(2);
        b.attrU32be(1, 1); // DREG
        b.attrU32be(2, 1); // BASE network header
        b.attrU32be(3, offset); // OFFSET
        b.attrU32be(4, @intCast(subnet.len)); // LEN
        b.nestEnd(d);
        b.nestEnd(e);
    }
    {
        // bitwise: reg1 &= mask
        var mask: [16]u8 = @splat(0);
        const zero: [16]u8 = @splat(0);
        var i: usize = 0;
        while (i < subnet.len) : (i += 1) {
            const bits: i32 = @as(i32, prefix) - @as(i32, @intCast(i * 8));
            mask[i] = if (bits >= 8) 0xff else if (bits <= 0) 0 else @as(u8, 0xff) << @intCast(8 - bits);
        }
        const e = expr(b, "bitwise");
        const d = b.nest(2);
        b.attrU32be(1, 1); // SREG
        b.attrU32be(2, 1); // DREG
        b.attrU32be(3, @intCast(subnet.len)); // LEN
        dataValue(b, 4, mask[0..subnet.len]); // MASK
        dataValue(b, 5, zero[0..subnet.len]); // XOR
        b.nestEnd(d);
        b.nestEnd(e);
    }
    {
        // cmp reg1 == subnet
        const e = expr(b, "cmp");
        const d = b.nest(2);
        b.attrU32be(1, 1);
        b.attrU32be(2, 0); // EQ
        dataValue(b, 3, subnet);
        b.nestEnd(d);
        b.nestEnd(e);
    }
    {
        // meta: reg1 = oifname
        const e = expr(b, "meta");
        const d = b.nest(2);
        b.attrU32be(2, 7); // KEY NFT_META_OIFNAME
        b.attrU32be(1, 1); // DREG
        b.nestEnd(d);
        b.nestEnd(e);
    }
    {
        // cmp reg1 != bridge name (IFNAMSIZ = 16 bytes)
        var nm: [16]u8 = @splat(0);
        const l = @min(bridge.len, 15);
        @memcpy(nm[0..l], bridge[0..l]);
        const e = expr(b, "cmp");
        const d = b.nest(2);
        b.attrU32be(1, 1);
        b.attrU32be(2, 1); // NEQ
        dataValue(b, 3, &nm);
        b.nestEnd(d);
        b.nestEnd(e);
    }
    {
        const e = expr(b, "masq");
        const d = b.nest(2);
        b.nestEnd(d);
        b.nestEnd(e);
    }
    b.nestEnd(exprs);
    b.end();

    b.begin(NFNL_MSG_BATCH_END, NLM_F_REQUEST, seq + 4);
    b.nfgenmsg(AF_UNSPEC, NFNL_SUBSYS_NFTABLES);
    b.end();
}

// Isolate an internal bridge from every other interface in both directions.
pub fn internalFilterBatch(b: *Builder, seq: u32, tname: []const u8, bridge: []const u8) void {
    b.begin(NFNL_MSG_BATCH_BEGIN, NLM_F_REQUEST, seq);
    b.nfgenmsg(AF_UNSPEC, NFNL_SUBSYS_NFTABLES);
    b.end();
    b.begin(nftType(NFT_MSG_NEWTABLE), NLM_F_REQUEST | NLM_F_ACK | NLM_F_CREATE | NLM_F_EXCL, seq + 1);
    b.nfgenmsg(1, 0); // NFPROTO_INET: IPv4 and IPv6
    b.attrStr(1, tname);
    b.end();
    b.begin(nftType(NFT_MSG_NEWCHAIN), NLM_F_REQUEST | NLM_F_ACK | NLM_F_CREATE, seq + 2);
    b.nfgenmsg(1, 0);
    b.attrStr(1, tname);
    b.attrStr(3, "forward");
    const hook = b.nest(4);
    b.attrU32be(1, 2); // NF_INET_FORWARD
    b.attrU32be(2, 0);
    b.nestEnd(hook);
    b.attrStr(7, "filter");
    b.end();
    for (0..2) |direction| {
        b.begin(nftType(NFT_MSG_NEWRULE), NLM_F_REQUEST | NLM_F_ACK | NLM_F_CREATE, seq + 3 + @as(u32, @intCast(direction)));
        b.nfgenmsg(1, 0);
        b.attrStr(1, tname);
        b.attrStr(2, "forward");
        const exprs = b.nest(4);
        for (0..2) |match| {
            const e = expr(b, "meta");
            const d = b.nest(2);
            b.attrU32be(1, 1);
            b.attrU32be(2, if ((direction == 0) == (match == 0)) 6 else 7); // iifname / oifname
            b.nestEnd(d);
            b.nestEnd(e);
            const c = expr(b, "cmp");
            const cd = b.nest(2);
            b.attrU32be(1, 1);
            b.attrU32be(2, @intCast(match)); // == bridge, then != bridge
            var nm: [16]u8 = @splat(0);
            @memcpy(nm[0..bridge.len], bridge);
            dataValue(b, 3, &nm);
            b.nestEnd(cd);
            b.nestEnd(c);
        }
        const e = expr(b, "immediate");
        const d = b.nest(2);
        b.attrU32be(1, 0); // NFT_REG_VERDICT
        const data = b.nest(2);
        const verdict = b.nest(2);
        b.attrU32be(1, 0); // NF_DROP
        b.nestEnd(verdict);
        b.nestEnd(data);
        b.nestEnd(d);
        b.nestEnd(e);
        b.nestEnd(exprs);
        b.end();
    }
    b.begin(NFNL_MSG_BATCH_END, NLM_F_REQUEST, seq + 5);
    b.nfgenmsg(AF_UNSPEC, NFNL_SUBSYS_NFTABLES);
    b.end();
}

fn cmpExpr(b: *Builder, op: u32, value: []const u8) void {
    const e = expr(b, "cmp");
    const d = b.nest(2);
    b.attrU32be(1, 1); // SREG reg1
    b.attrU32be(2, op); // 0 EQ, 1 NEQ
    dataValue(b, 3, value);
    b.nestEnd(d);
    b.nestEnd(e);
}

fn metaExpr(b: *Builder, key: u32) void {
    const e = expr(b, "meta");
    const d = b.nest(2);
    b.attrU32be(2, key);
    b.attrU32be(1, 1); // DREG reg1
    b.nestEnd(d);
    b.nestEnd(e);
}

fn payloadExpr(b: *Builder, base: u32, offset: u32, len: u32) void {
    const e = expr(b, "payload");
    const d = b.nest(2);
    b.attrU32be(1, 1); // DREG reg1
    b.attrU32be(2, base); // 1 network header, 2 transport header
    b.attrU32be(3, offset);
    b.attrU32be(4, len);
    b.nestEnd(d);
    b.nestEnd(e);
}

pub const hostlo_batch_acks = 3;
pub const NF_INET_PRE_ROUTING: u32 = 0;
pub const NF_INET_LOCAL_OUT: u32 = 3;

/// Mac loopback relay. Batch: table `tname` (ip, created if missing), nat chain `chain` on `hook` at dstnat
/// priority -100, and the rule `[iifname bridge] ip daddr gw meta l4proto tcp tcp dport != 53 redirect to :port`.
/// A null bridge matches any interface (the output hook: the VM's own traffic).
pub fn hostLoopbackBatch(b: *Builder, seq: u32, tname: []const u8, chain: []const u8, hook: u32, bridge: ?[]const u8, gw: [4]u8, port: u16) void {
    b.begin(NFNL_MSG_BATCH_BEGIN, NLM_F_REQUEST, seq);
    b.nfgenmsg(AF_UNSPEC, NFNL_SUBSYS_NFTABLES);
    b.end();

    b.begin(nftType(NFT_MSG_NEWTABLE), NLM_F_REQUEST | NLM_F_ACK | NLM_F_CREATE, seq + 1);
    b.nfgenmsg(NFPROTO_IPV4, 0);
    b.attrStr(1, tname);
    b.end();

    b.begin(nftType(NFT_MSG_NEWCHAIN), NLM_F_REQUEST | NLM_F_ACK | NLM_F_CREATE, seq + 2);
    b.nfgenmsg(NFPROTO_IPV4, 0);
    b.attrStr(1, tname);
    b.attrStr(3, chain);
    const h = b.nest(4);
    b.attrU32be(1, hook);
    b.attrU32be(2, @bitCast(@as(i32, -100)));
    b.nestEnd(h);
    b.attrStr(7, "nat");
    b.end();

    b.begin(nftType(NFT_MSG_NEWRULE), NLM_F_REQUEST | NLM_F_ACK | NLM_F_CREATE, seq + 3);
    b.nfgenmsg(NFPROTO_IPV4, 0);
    b.attrStr(1, tname);
    b.attrStr(2, chain);
    const exprs = b.nest(4);
    if (bridge) |br| {
        var nm: [16]u8 = @splat(0);
        const l = @min(br.len, 15);
        @memcpy(nm[0..l], br[0..l]);
        metaExpr(b, 6); // NFT_META_IIFNAME
        cmpExpr(b, 0, &nm);
    }
    payloadExpr(b, 1, 16, 4); // ip daddr
    cmpExpr(b, 0, &gw);
    metaExpr(b, 16); // NFT_META_L4PROTO
    cmpExpr(b, 0, &.{6}); // IPPROTO_TCP
    payloadExpr(b, 2, 2, 2); // tcp dport
    cmpExpr(b, 1, &.{ 0, 53 });
    {
        var pbe: [2]u8 = undefined;
        std.mem.writeInt(u16, &pbe, port, .big);
        const e = expr(b, "immediate");
        const d = b.nest(2);
        b.attrU32be(1, 1); // DREG reg1
        dataValue(b, 2, &pbe);
        b.nestEnd(d);
        b.nestEnd(e);
    }
    {
        const e = expr(b, "redir");
        const d = b.nest(2);
        b.attrU32be(1, 1); // NFTA_REDIR_REG_PROTO_MIN = reg1
        b.attrU32be(2, 1); // NFTA_REDIR_REG_PROTO_MAX = reg1
        b.nestEnd(d);
        b.nestEnd(e);
    }
    b.nestEnd(exprs);
    b.end();

    b.begin(NFNL_MSG_BATCH_END, NLM_F_REQUEST, seq + 4);
    b.nfgenmsg(AF_UNSPEC, NFNL_SUBSYS_NFTABLES);
    b.end();
}

pub const NF_INET_LOCAL_IN: u32 = 1;

/// The relay listener's input guard: table `tname` (ip), filter chain "input" on the local-in hook, and the rule
/// `meta l4proto tcp tcp dport port ct status & dnat == 0 drop`. Only connections that a redirect rule rewrote reach
/// the listener, whatever address a container dials (an internal bridge may even share the Mac's gateway address).
pub fn hostLoopbackGuardBatch(b: *Builder, seq: u32, tname: []const u8, port: u16) void {
    b.begin(NFNL_MSG_BATCH_BEGIN, NLM_F_REQUEST, seq);
    b.nfgenmsg(AF_UNSPEC, NFNL_SUBSYS_NFTABLES);
    b.end();

    b.begin(nftType(NFT_MSG_NEWTABLE), NLM_F_REQUEST | NLM_F_ACK | NLM_F_CREATE, seq + 1);
    b.nfgenmsg(NFPROTO_IPV4, 0);
    b.attrStr(1, tname);
    b.end();

    b.begin(nftType(NFT_MSG_NEWCHAIN), NLM_F_REQUEST | NLM_F_ACK | NLM_F_CREATE, seq + 2);
    b.nfgenmsg(NFPROTO_IPV4, 0);
    b.attrStr(1, tname);
    b.attrStr(3, "input");
    const h = b.nest(4);
    b.attrU32be(1, NF_INET_LOCAL_IN);
    b.attrU32be(2, 0);
    b.nestEnd(h);
    b.attrStr(7, "filter");
    b.end();

    b.begin(nftType(NFT_MSG_NEWRULE), NLM_F_REQUEST | NLM_F_ACK | NLM_F_CREATE, seq + 3);
    b.nfgenmsg(NFPROTO_IPV4, 0);
    b.attrStr(1, tname);
    b.attrStr(2, "input");
    const exprs = b.nest(4);
    metaExpr(b, 16); // NFT_META_L4PROTO
    cmpExpr(b, 0, &.{6});
    var pbe: [2]u8 = undefined;
    std.mem.writeInt(u16, &pbe, port, .big);
    payloadExpr(b, 2, 2, 2); // tcp dport
    cmpExpr(b, 0, &pbe);
    {
        const e = expr(b, "ct");
        const d = b.nest(2);
        b.attrU32be(2, 2); // NFTA_CT_KEY = NFT_CT_STATUS (enum nft_ct_keys: STATE 0, DIRECTION 1, STATUS 2)
        b.attrU32be(1, 1); // NFTA_CT_DREG = reg1
        b.nestEnd(d);
        b.nestEnd(e);
    }
    {
        // ct status is a host-order u32; IPS_DST_NAT is bit 5. The guest is little-endian aarch64.
        const e = expr(b, "bitwise");
        const d = b.nest(2);
        b.attrU32be(1, 1);
        b.attrU32be(2, 1);
        b.attrU32be(3, 4);
        dataValue(b, 4, &.{ 0x20, 0, 0, 0 });
        dataValue(b, 5, &.{ 0, 0, 0, 0 });
        b.nestEnd(d);
        b.nestEnd(e);
    }
    cmpExpr(b, 0, &.{ 0, 0, 0, 0 });
    {
        const e = expr(b, "immediate");
        const d = b.nest(2);
        b.attrU32be(1, 0); // NFT_REG_VERDICT
        const data = b.nest(2);
        const verdict = b.nest(2);
        b.attrU32be(1, 0); // NF_DROP
        b.nestEnd(verdict);
        b.nestEnd(data);
        b.nestEnd(d);
        b.nestEnd(e);
    }
    b.nestEnd(exprs);
    b.end();

    b.begin(NFNL_MSG_BATCH_END, NLM_F_REQUEST, seq + 4);
    b.nfgenmsg(AF_UNSPEC, NFNL_SUBSYS_NFTABLES);
    b.end();
}

fn ctMasked(b: *Builder, key: u32, mask: u8) void {
    const e = expr(b, "ct");
    const d = b.nest(2);
    b.attrU32be(2, key); // NFT_CT_STATE 0, NFT_CT_STATUS 2
    b.attrU32be(1, 1);
    b.nestEnd(d);
    b.nestEnd(e);
    const be = expr(b, "bitwise");
    const bd = b.nest(2);
    b.attrU32be(1, 1);
    b.attrU32be(2, 1);
    b.attrU32be(3, 4);
    dataValue(b, 4, &.{ mask, 0, 0, 0 }); // host-order u32 on little-endian aarch64
    dataValue(b, 5, &.{ 0, 0, 0, 0 });
    b.nestEnd(bd);
    b.nestEnd(be);
}

/// Uplink guard: table `tname` (inet, IPv4 and IPv6), forward-hook filter chain, rule
/// `iifname uplink ct state new ct status & dnat == 0 drop`. Both VMs share one NAT subnet and forward for their
/// bridges; only replies to container-originated flows may arrive from the uplink, never a new connection.
/// Published ports are dialed by the agent locally, not forwarded, so they do not pass here.
pub fn uplinkGuardBatch(b: *Builder, seq: u32, tname: []const u8, uplink: []const u8) void {
    b.begin(NFNL_MSG_BATCH_BEGIN, NLM_F_REQUEST, seq);
    b.nfgenmsg(AF_UNSPEC, NFNL_SUBSYS_NFTABLES);
    b.end();
    b.begin(nftType(NFT_MSG_NEWTABLE), NLM_F_REQUEST | NLM_F_ACK | NLM_F_CREATE, seq + 1);
    b.nfgenmsg(NFPROTO_INET, 0);
    b.attrStr(1, tname);
    b.end();
    b.begin(nftType(NFT_MSG_NEWCHAIN), NLM_F_REQUEST | NLM_F_ACK | NLM_F_CREATE, seq + 2);
    b.nfgenmsg(NFPROTO_INET, 0);
    b.attrStr(1, tname);
    b.attrStr(3, "forward");
    const h = b.nest(4);
    b.attrU32be(1, 2); // NF_INET_FORWARD
    b.attrU32be(2, 0);
    b.nestEnd(h);
    b.attrStr(7, "filter");
    b.end();
    b.begin(nftType(NFT_MSG_NEWRULE), NLM_F_REQUEST | NLM_F_ACK | NLM_F_CREATE, seq + 3);
    b.nfgenmsg(NFPROTO_INET, 0);
    b.attrStr(1, tname);
    b.attrStr(2, "forward");
    const exprs = b.nest(4);
    metaExpr(b, 6); // NFT_META_IIFNAME
    var nm: [16]u8 = @splat(0);
    @memcpy(nm[0..uplink.len], uplink);
    cmpExpr(b, 0, &nm);
    ctMasked(b, 0, 0x08); // IP_CT_NEW is bit 3 of the state mask
    cmpExpr(b, 1, &.{ 0, 0, 0, 0 });
    ctMasked(b, 2, 0x20); // IPS_DST_NAT
    cmpExpr(b, 0, &.{ 0, 0, 0, 0 });
    {
        const e = expr(b, "immediate");
        const d = b.nest(2);
        b.attrU32be(1, 0);
        const data = b.nest(2);
        const verdict = b.nest(2);
        b.attrU32be(1, 0); // NF_DROP
        b.nestEnd(verdict);
        b.nestEnd(data);
        b.nestEnd(d);
        b.nestEnd(e);
    }
    b.nestEnd(exprs);
    b.end();
    b.begin(NFNL_MSG_BATCH_END, NLM_F_REQUEST, seq + 4);
    b.nfgenmsg(AF_UNSPEC, NFNL_SUBSYS_NFTABLES);
    b.end();
}

pub fn deleteTableBatch(b: *Builder, seq: u32, tname: []const u8, family: u8) void {
    b.begin(NFNL_MSG_BATCH_BEGIN, NLM_F_REQUEST, seq);
    b.nfgenmsg(AF_UNSPEC, NFNL_SUBSYS_NFTABLES);
    b.end();
    b.begin(nftType(NFT_MSG_DELTABLE), NLM_F_REQUEST | NLM_F_ACK, seq + 1);
    b.nfgenmsg(family, 0);
    b.attrStr(1, tname);
    b.end();
    b.begin(NFNL_MSG_BATCH_END, NLM_F_REQUEST, seq + 2);
    b.nfgenmsg(AF_UNSPEC, NFNL_SUBSYS_NFTABLES);
    b.end();
}

/// Parse a netlink reply buffer. Returns the first NLMSG_ERROR code (0 = ack, negative errno), or null if none present.
pub fn firstError(reply: []const u8) ?i32 {
    var off: usize = 0;
    while (off + 16 <= reply.len) {
        const len = std.mem.readInt(u32, reply[off..][0..4], .little);
        const t = std.mem.readInt(u16, reply[off + 4 ..][0..2], .little);
        if (len < 16 or off + len > reply.len) return null;
        if (t == 2 and len >= 20) return std.mem.readInt(i32, reply[off + 16 ..][0..4], .little);
        off += (len + 3) & ~@as(usize, 3);
    }
    return null;
}

/// Find the ifi_index in an RTM_NEWLINK reply (for getLink).
pub fn linkIndex(reply: []const u8) ?i32 {
    var off: usize = 0;
    while (off + 32 <= reply.len) {
        const len = std.mem.readInt(u32, reply[off..][0..4], .little);
        const t = std.mem.readInt(u16, reply[off + 4 ..][0..2], .little);
        if (len < 16 or off + len > reply.len) return null;
        if (t == RTM_NEWLINK) return std.mem.readInt(i32, reply[off + 20 ..][0..4], .little);
        off += (len + 3) & ~@as(usize, 3);
    }
    return null;
}

test "veth message is well formed and aligned" {
    var buf: [512]u8 = undefined;
    var b = Builder.init(&buf);
    newVeth(&b, 1, "vabcd", "pabcd", .{ 2, 0, 0, 0, 0, 1 }, 1234);
    const m = b.bytes();
    try std.testing.expectEqual(@as(u32, @intCast(m.len)), std.mem.readInt(u32, m[0..4], .little));
    try std.testing.expectEqual(@as(usize, 0), m.len % 4);
    try std.testing.expectEqual(@as(u16, RTM_NEWLINK), std.mem.readInt(u16, m[4..6], .little));
    try std.testing.expect(std.mem.indexOf(u8, m, "veth") != null);
    try std.testing.expect(std.mem.indexOf(u8, m, "pabcd") != null);
}

test "address and route" {
    var buf: [256]u8 = undefined;
    var b = Builder.init(&buf);
    addAddr(&b, 2, 5, .{ 172, 18, 0, 2 }, 16);
    const m = b.bytes();
    try std.testing.expectEqual(@as(u8, 16), m[17]);
    try std.testing.expectEqual(@as(usize, 0), m.len % 4);
    b.reset();
    addDefaultRoute(&b, 3, .{ 172, 18, 0, 1 });
    try std.testing.expectEqual(@as(usize, 0), b.bytes().len % 4);
}

test "nat batch contains three acked messages and correct mask" {
    var buf: [2048]u8 = undefined;
    var b = Builder.init(&buf);
    natMasqueradeBatch(&b, 10, "noodle-br0", .{ 172, 18, 0, 0 }, 16, "br0");
    const m = b.bytes();
    // walk messages
    var off: usize = 0;
    var count: usize = 0;
    while (off < m.len) {
        const len = std.mem.readInt(u32, m[off..][0..4], .little);
        try std.testing.expect(len >= 16 and off + len <= m.len);
        count += 1;
        off += (len + 3) & ~@as(usize, 3);
    }
    try std.testing.expectEqual(@as(usize, 5), count); // begin, table, chain, rule, end
    const meta = std.mem.indexOf(u8, m, "meta\x00") orelse return error.TestUnexpectedResult;
    // NFTA_META_KEY must select the outgoing interface; IIFNAME (6) skips container NAT.
    try std.testing.expectEqualSlices(u8, &.{ 8, 0, 2, 0, 0, 0, 0, 7 }, m[meta + 12 ..][0..8]);
}

test "internal filter isolates both directions for IPv4 and IPv6" {
    var buf: [2048]u8 = undefined;
    var b = Builder.init(&buf);
    internalFilterBatch(&b, 10, "noodle-br0", "br0");
    const m = b.bytes();
    var off: usize = 0;
    var count: usize = 0;
    while (off < m.len) {
        const len = std.mem.readInt(u32, m[off..][0..4], .little);
        try std.testing.expect(len >= 20 and off + len <= m.len);
        if (count > 0 and count < 5) try std.testing.expectEqual(@as(u8, 1), m[off + 16]);
        count += 1;
        off += (len + 3) & ~@as(usize, 3);
    }
    try std.testing.expectEqual(@as(usize, 6), count);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, m, "immediate\x00"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, m, &.{ 8, 0, 2, 0, 0, 0, 0, 6 }));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, m, &.{ 8, 0, 2, 0, 0, 0, 0, 7 }));
}

test "IPv6 address carries no-DAD and the route names the device" {
    var buf: [256]u8 = undefined;
    var b = Builder.init(&buf);
    const ip = [16]u8{ 0xfd, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2 };
    addAddr6(&b, 2, 5, ip, 64);
    const m = b.bytes();
    try std.testing.expectEqual(@as(u8, AF_INET6), m[16]);
    try std.testing.expectEqual(@as(u8, 64), m[17]);
    try std.testing.expectEqual(@as(u8, 0x02), m[18]);
    try std.testing.expect(std.mem.indexOf(u8, m, &ip) != null);
    try std.testing.expectEqual(@as(usize, 0), m.len % 4);
    b.reset();
    addDefaultRoute6(&b, 3, 5, ip);
    const r = b.bytes();
    try std.testing.expectEqual(@as(u8, AF_INET6), r[16]);
    try std.testing.expectEqual(@as(u8, 0), r[17]);
    try std.testing.expect(std.mem.indexOf(u8, r, &ip) != null);
    try std.testing.expectEqual(@as(usize, 0), r.len % 4);
}

test "IPv6 nat batch reads the source at offset 8 and masks 16 bytes" {
    var buf: [2048]u8 = undefined;
    var b = Builder.init(&buf);
    const subnet = [16]u8{ 0xfd, 0x6e, 0x6f, 0x6f, 0x64, 0x6c, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0 };
    natMasquerade6Batch(&b, 1, "noodle-br", subnet, 64, "br");
    const m = b.bytes();
    // nfgenmsg family of the table message (after the 20-byte batch begin and its 16-byte header).
    try std.testing.expectEqual(@as(u8, NFPROTO_IPV6), m[20 + 16]);
    try std.testing.expect(std.mem.indexOf(u8, m, &subnet) != null);
    const mask = [16]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0, 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expect(std.mem.indexOf(u8, m, &mask) != null);
    const offset8 = [_]u8{ 8, 0, 3, 0, 0, 0, 0, 8 }; // NFTA_PAYLOAD_OFFSET
    try std.testing.expect(std.mem.indexOf(u8, m, &offset8) != null);
    const len16 = [_]u8{ 8, 0, 4, 0, 0, 0, 0, 16 }; // NFTA_PAYLOAD_LEN
    try std.testing.expect(std.mem.indexOf(u8, m, &len16) != null);
}

test "host loopback redirect batch: gateway, tcp, not port 53, redirect to the relay port" {
    var buf: [2048]u8 = undefined;
    var b = Builder.init(&buf);
    hostLoopbackBatch(&b, 10, "noodle-br0", "hostlo", NF_INET_PRE_ROUTING, "br0", .{ 192, 168, 64, 1 }, 61034);
    const m = b.bytes();
    var off: usize = 0;
    var count: usize = 0;
    while (off < m.len) {
        const len = std.mem.readInt(u32, m[off..][0..4], .little);
        try std.testing.expect(len >= 16 and off + len <= m.len);
        count += 1;
        off += (len + 3) & ~@as(usize, 3);
    }
    try std.testing.expectEqual(@as(usize, 5), count); // begin, table, chain, rule, end
    try std.testing.expectEqual(@as(u8, NFPROTO_IPV4), m[20 + 16]);
    const prio = [_]u8{ 8, 0, 2, 0, 0xff, 0xff, 0xff, 0x9c }; // dstnat priority -100
    try std.testing.expect(std.mem.indexOf(u8, m, &prio) != null);
    const gw = [_]u8{ 8, 0, 1, 0, 192, 168, 64, 1 }; // NFTA_DATA_VALUE of the daddr cmp
    try std.testing.expect(std.mem.indexOf(u8, m, &gw) != null);
    const neq53 = [_]u8{ 8, 0, 2, 0, 0, 0, 0, 1 }; // cmp NEQ ...
    const dport53 = [_]u8{ 6, 0, 1, 0, 0, 53 }; // ... data 0x0035
    const neq_at = std.mem.indexOf(u8, m, &neq53) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, m[neq_at..], &dport53) != null);
    const relay = [_]u8{ 6, 0, 1, 0, 0xee, 0x6a }; // immediate 61034, big endian
    try std.testing.expect(std.mem.indexOf(u8, m, &relay) != null);
    try std.testing.expect(std.mem.indexOf(u8, m, "redir\x00") != null);
    try std.testing.expect(std.mem.indexOf(u8, m, "br0\x00") != null);

    b.reset();
    hostLoopbackBatch(&b, 20, "noodle-hostlo", "output", NF_INET_LOCAL_OUT, null, .{ 192, 168, 64, 1 }, 61034);
    const o = b.bytes();
    try std.testing.expect(std.mem.indexOf(u8, o, "br0\x00") == null);
    const out_hook = [_]u8{ 8, 0, 1, 0, 0, 0, 0, 3 };
    try std.testing.expect(std.mem.indexOf(u8, o, &out_hook) != null);
}

test "host loopback guard drops relay-port traffic that no redirect rewrote" {
    var buf: [2048]u8 = undefined;
    var b = Builder.init(&buf);
    hostLoopbackGuardBatch(&b, 30, "noodle-hostlo", 61034);
    const m = b.bytes();
    var off: usize = 0;
    var count: usize = 0;
    while (off < m.len) {
        const len = std.mem.readInt(u32, m[off..][0..4], .little);
        try std.testing.expect(len >= 16 and off + len <= m.len);
        count += 1;
        off += (len + 3) & ~@as(usize, 3);
    }
    try std.testing.expectEqual(@as(usize, 5), count);
    const in_hook = [_]u8{ 8, 0, 1, 0, 0, 0, 0, 1 }; // NF_INET_LOCAL_IN
    try std.testing.expect(std.mem.indexOf(u8, m, &in_hook) != null);
    try std.testing.expect(std.mem.indexOf(u8, m, "filter\x00") != null);
    try std.testing.expect(std.mem.indexOf(u8, m, "ct\x00") != null);
    const status_key = [_]u8{ 8, 0, 2, 0, 0, 0, 0, 2 }; // NFTA_CT_KEY = NFT_CT_STATUS, not DIRECTION (1)
    try std.testing.expect(std.mem.indexOf(u8, m, &status_key) != null);
    const dnat_mask = [_]u8{ 8, 0, 1, 0, 0x20, 0, 0, 0 }; // IPS_DST_NAT, host order
    try std.testing.expect(std.mem.indexOf(u8, m, &dnat_mask) != null);
    const relay = [_]u8{ 6, 0, 1, 0, 0xee, 0x6a }; // tcp dport 61034
    try std.testing.expect(std.mem.indexOf(u8, m, &relay) != null);
    // The verdict is a drop, not an accept.
    try std.testing.expect(std.mem.indexOf(u8, m, "immediate\x00") != null);
}

test "firstError parses ack" {
    var reply: [36]u8 = @splat(0);
    std.mem.writeInt(u32, reply[0..4], 36, .little);
    std.mem.writeInt(u16, reply[4..6], 2, .little);
    std.mem.writeInt(i32, reply[16..20], -17, .little);
    try std.testing.expectEqual(@as(?i32, -17), firstError(&reply));
}
