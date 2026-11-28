//! Guest networking: netlink I/O, DHCP client for eth0, per-network bridge + DNS responder, container attach.
const std = @import("std");
const sys = @import("sys.zig");
const util = @import("util.zig");
const nl = @import("netlink.zig");
const dns = @import("dnsmsg");
const resolver = @import("resolver.zig");

/// Pinned in the builder's private BuildKit configuration.
pub const builder_bridge = "noodle-bk0";

// ------------------------------------------------------------------ netlink I/O

const NETLINK_ROUTE = 0;
const NETLINK_NETFILTER = 12;

/// Send `msg` on a fresh netlink socket and collect `expect` NLMSG_ERROR replies (acks).
/// Returns 0 on success or a negative errno. If `reply` is non-null the last datagram is copied into it.
fn exchange(proto: usize, msg: []const u8, expect: usize, reply: ?[]u8, reply_len: ?*usize) isize {
    const s = sys.socket(sys.AF_NETLINK, sys.SOCK_RAW, proto);
    if (s < 0) return s;
    defer sys.close(s);
    const addr = sys.SockaddrNl{};
    var rc = sys.bind(s, &addr, @sizeOf(sys.SockaddrNl));
    if (rc < 0) return rc;
    rc = sys.sendto(s, msg, null, 0);
    if (rc < 0) return rc;
    var buf: [8192]u8 = undefined;
    var got: usize = 0;
    var result: isize = 0;
    while (got < expect or (expect == 0 and reply != null and got == 0)) {
        var pfd = sys.PollFd{ .fd = @intCast(s), .events = sys.POLLIN, .revents = 0 };
        const pr = sys.poll(@ptrCast(&pfd), 1, 2000);
        if (pr <= 0) return -sys.E.INTR;
        const n = sys.recvfrom(s, &buf, null, null);
        if (n < 0) return n;
        const data = buf[0..@intCast(n)];
        if (reply) |r| {
            const l = @min(r.len, data.len);
            @memcpy(r[0..l], data[0..l]);
            if (reply_len) |rl| rl.* = l;
            if (expect == 0) return 0;
        }
        // count error/ack messages in this datagram
        var off: usize = 0;
        while (off + 16 <= data.len) {
            const len = std.mem.readInt(u32, data[off..][0..4], .little);
            const t = std.mem.readInt(u16, data[off + 4 ..][0..2], .little);
            if (len < 16 or off + len > data.len) break;
            if (t == 2 and len >= 20) {
                got += 1;
                const e = std.mem.readInt(i32, data[off + 16 ..][0..4], .little);
                if (e != 0 and result == 0) result = e;
            }
            off += (len + 3) & ~@as(usize, 3);
        }
    }
    return result;
}

var seq_counter: u32 = 100;
fn nextSeq() u32 {
    seq_counter += 8;
    return seq_counter;
}

fn rt(msg: []const u8) isize {
    return exchange(NETLINK_ROUTE, msg, 1, null, null);
}

pub fn linkIndex(name: []const u8) isize {
    var buf: [256]u8 = undefined;
    var b = nl.Builder.init(&buf);
    nl.getLink(&b, nextSeq(), name);
    var rep: [2048]u8 = undefined;
    var rl: usize = 0;
    const rc = exchange(NETLINK_ROUTE, b.bytes(), 0, &rep, &rl);
    if (rc < 0) return rc;
    if (nl.firstError(rep[0..rl])) |e| {
        if (e != 0) return e;
    }
    return nl.linkIndex(rep[0..rl]) orelse -sys.E.NODATA;
}

pub fn linkUp(index: i32) isize {
    var buf: [128]u8 = undefined;
    var b = nl.Builder.init(&buf);
    nl.setUp(&b, nextSeq(), index);
    return rt(b.bytes());
}

pub fn linkUpByName(name: []const u8) isize {
    const idx = linkIndex(name);
    if (idx < 0) return idx;
    return linkUp(@intCast(idx));
}

pub fn addAddr(index: i32, ip: [4]u8, prefix: u8) isize {
    var buf: [128]u8 = undefined;
    var b = nl.Builder.init(&buf);
    nl.addAddr(&b, nextSeq(), @intCast(index), ip, prefix);
    return rt(b.bytes());
}

pub fn addAddr6(index: i32, ip: [16]u8, prefix: u8) isize {
    var buf: [128]u8 = undefined;
    var b = nl.Builder.init(&buf);
    nl.addAddr6(&b, nextSeq(), @intCast(index), ip, prefix);
    return rt(b.bytes());
}

pub fn addDefaultRoute6(index: i32, gw: [16]u8) isize {
    var buf: [128]u8 = undefined;
    var b = nl.Builder.init(&buf);
    nl.addDefaultRoute6(&b, nextSeq(), @intCast(index), gw);
    return rt(b.bytes());
}

pub fn addDefaultRoute(gw: [4]u8) isize {
    var buf: [128]u8 = undefined;
    var b = nl.Builder.init(&buf);
    nl.addDefaultRoute(&b, nextSeq(), gw);
    return rt(b.bytes());
}

fn nftMasq(tname: []const u8, subnet: [4]u8, prefix: u8, bridge: []const u8) isize {
    var buf: [2048]u8 = undefined;
    var b = nl.Builder.init(&buf);
    nl.natMasqueradeBatch(&b, nextSeq(), tname, subnet, prefix, bridge);
    return exchange(NETLINK_NETFILTER, b.bytes(), nl.nat_batch_acks, null, null);
}

fn nftInternal(tname: []const u8, bridge: []const u8) isize {
    var buf: [2048]u8 = undefined;
    var b = nl.Builder.init(&buf);
    nl.internalFilterBatch(&b, nextSeq(), tname, bridge);
    return exchange(NETLINK_NETFILTER, b.bytes(), 4, null, null);
}

fn nftMasq6(tname: []const u8, subnet: [16]u8, prefix: u8, bridge: []const u8) isize {
    var buf: [2048]u8 = undefined;
    var b = nl.Builder.init(&buf);
    nl.natMasquerade6Batch(&b, nextSeq(), tname, subnet, prefix, bridge);
    return exchange(NETLINK_NETFILTER, b.bytes(), nl.nat_batch_acks, null, null);
}

fn nftHostlo(tname: []const u8, chain: []const u8, hook: u32, bridge: ?[]const u8, gw: [4]u8, port: u16) isize {
    var buf: [2048]u8 = undefined;
    var b = nl.Builder.init(&buf);
    nl.hostLoopbackBatch(&b, nextSeq(), tname, chain, hook, bridge, gw, port);
    return exchange(NETLINK_NETFILTER, b.bytes(), nl.hostlo_batch_acks, null, null);
}

fn nftDelete(tname: []const u8, family: u8) isize {
    var buf: [256]u8 = undefined;
    var b = nl.Builder.init(&buf);
    nl.deleteTableBatch(&b, nextSeq(), tname, family);
    return exchange(NETLINK_NETFILTER, b.bytes(), 1, null, null);
}

// ------------------------------------------------------------------ DHCP

pub var upstream_dns: [4]u8 = .{ 0, 0, 0, 0 };
pub var guest_ip: [4]u8 = .{ 0, 0, 0, 0 };
/// The DHCP router: the Mac, as the VM sees it. Stays null when boot continued without a lease.
pub var vm_gateway: ?[4]u8 = null;

fn dhcpBuild(buf: []u8, xid: u32, mac: [6]u8, msg_type: u8, req_ip: ?[4]u8, server: ?[4]u8) usize {
    @memset(buf[0..300], 0);
    buf[0] = 1; // BOOTREQUEST
    buf[1] = 1; // ethernet
    buf[2] = 6;
    std.mem.writeInt(u32, buf[4..8], xid, .big);
    std.mem.writeInt(u16, buf[10..12], 0x8000, .big); // broadcast flag
    @memcpy(buf[28..34], &mac);
    buf[236] = 99;
    buf[237] = 130;
    buf[238] = 83;
    buf[239] = 99;
    var n: usize = 240;
    buf[n] = 53;
    buf[n + 1] = 1;
    buf[n + 2] = msg_type;
    n += 3;
    buf[n] = 61;
    buf[n + 1] = 7;
    buf[n + 2] = 1;
    @memcpy(buf[n + 3 .. n + 9], &mac);
    n += 9;
    if (req_ip) |ip| {
        buf[n] = 50;
        buf[n + 1] = 4;
        @memcpy(buf[n + 2 .. n + 6], &ip);
        n += 6;
    }
    if (server) |ip| {
        buf[n] = 54;
        buf[n + 1] = 4;
        @memcpy(buf[n + 2 .. n + 6], &ip);
        n += 6;
    }
    buf[n] = 55; // parameter request list: mask, router, dns
    buf[n + 1] = 3;
    buf[n + 2] = 1;
    buf[n + 3] = 3;
    buf[n + 4] = 6;
    n += 5;
    buf[n] = 255;
    n += 1;
    return @max(n, 300);
}

const Lease = struct { ip: [4]u8, prefix: u8, gw: ?[4]u8, dns: ?[4]u8, server: [4]u8 };

fn dhcpParse(pkt: []const u8, xid: u32, want_type: u8) ?Lease {
    @setRuntimeSafety(true); // untrusted wire input: keep bounds/overflow checks in ReleaseSmall
    if (pkt.len < 241 or pkt[0] != 2) return null;
    if (std.mem.readInt(u32, pkt[4..8], .big) != xid) return null;
    if (!(pkt[236] == 99 and pkt[237] == 130 and pkt[238] == 83 and pkt[239] == 99)) return null;
    var l = Lease{ .ip = pkt[16..20].*, .prefix = 24, .gw = null, .dns = null, .server = .{ 0, 0, 0, 0 } };
    var mt: u8 = 0;
    var i: usize = 240;
    while (i + 1 < pkt.len) {
        const code = pkt[i];
        if (code == 255) break;
        if (code == 0) {
            i += 1;
            continue;
        }
        const len = pkt[i + 1];
        if (i + 2 + len > pkt.len) break;
        const v = pkt[i + 2 .. i + 2 + len];
        switch (code) {
            53 => if (len == 1) {
                mt = v[0];
            } else return null,
            1 => if (len == 4) {
                const mask = std.mem.readInt(u32, v[0..4], .big);
                l.prefix = @intCast(@popCount(mask));
            },
            3 => if (len >= 4) {
                l.gw = v[0..4].*;
            },
            6 => if (len >= 4) {
                l.dns = v[0..4].*;
            },
            54 => if (len == 4) {
                l.server = v[0..4].*;
            },
            else => {},
        }
        i += 2 + len;
    }
    if (mt != want_type) return null;
    return l;
}

test "dhcp reply with a zero-length message-type option is rejected" {
    var pkt: [300]u8 = @splat(0);
    pkt[0] = 2;
    std.mem.writeInt(u32, pkt[4..8], 7, .big);
    pkt[236] = 99;
    pkt[237] = 130;
    pkt[238] = 83;
    pkt[239] = 99;
    pkt[240] = 53;
    pkt[241] = 0;
    pkt[242] = 255;
    try std.testing.expect(dhcpParse(&pkt, 7, 2) == null);
    pkt[241] = 1;
    pkt[242] = 2;
    pkt[243] = 255;
    try std.testing.expect(dhcpParse(&pkt, 7, 2) != null);
}

fn readMac(ifname: []const u8) ?[6]u8 {
    const p = util.zf("/sys/class/net/{s}/address", .{ifname});
    const t = util.readFile(p.ptr, 64) orelse return null;
    return util.parseMac(std.mem.trim(u8, t, " \n"));
}

// The lease is the slowest step of a boot and nothing in a `--network none` container uses it, so the handshake runs
// in the agent's event loop and every operation that does need it calls `dhcpFinish` first (control.zig, container.zig).
// Forked children read a marker file instead, because they cannot see the parent's state (stream.zig).
const DhcpPhase = enum { idle, link, discover, request, done };
const dhcp_marker = "/run/noodle-lease-settled";
const dhcp_attempts = 4;
var dhcp_phase: DhcpPhase = .idle;
var dhcp_fd: isize = -1;
var dhcp_idx: i32 = 0;
var dhcp_mac: [6]u8 = undefined;
var dhcp_xid: u32 = 0;
var dhcp_attempt: usize = 0;
var dhcp_deadline: u64 = 0;
var dhcp_leased = false;

fn dhcpBroadcast(pkt: []const u8) void {
    const bcast = sys.SockaddrIn{ .port = std.mem.nativeToBig(u16, 67), .addr = .{ 255, 255, 255, 255 } };
    _ = sys.sendto(dhcp_fd, pkt, &bcast, @sizeOf(sys.SockaddrIn));
}

fn dhcpSettle() void {
    dhcp_phase = .done;
    if (dhcp_fd >= 0) sys.close(dhcp_fd); // closing also drops it from the epoll set
    dhcp_fd = -1;
    _ = util.writeFile(dhcp_marker, "", 0o644);
}

/// Start a DISCOVER round, or settle without a lease when the attempts ran out.
fn dhcpDiscover() void {
    if (dhcp_attempt >= dhcp_attempts) {
        util.log("dhcp: no lease after {d} attempts, continuing without", .{dhcp_attempt});
        dhcpSettle();
        return;
    }
    var pkt: [600]u8 = undefined;
    const n = dhcpBuild(&pkt, dhcp_xid, dhcp_mac, 1, null, null);
    dhcpBroadcast(pkt[0..n]);
    dhcp_phase = .discover;
    dhcp_deadline = sys.boottime_ns() + (@as(u64, 1) << @intCast(@min(dhcp_attempt, 1))) * 1_000_000_000;
}

fn dhcpApply(a: Lease) void {
    var rc = addAddr(@intCast(dhcp_idx), a.ip, a.prefix);
    if (rc < 0 and rc != -sys.E.EXIST) util.logErr("dhcp addr", rc);
    if (a.gw) |gw| {
        rc = addDefaultRoute(gw);
        if (rc < 0 and rc != -sys.E.EXIST) util.logErr("dhcp route", rc);
        vm_gateway = gw;
        hostloApply();
    }
    guest_ip = a.ip;
    if (a.dns) |d| {
        upstream_dns = d;
        var line: [64]u8 = undefined;
        const t = std.fmt.bufPrint(&line, "nameserver {d}.{d}.{d}.{d}\n", .{ d[0], d[1], d[2], d[3] }) catch "";
        _ = util.writeFile("/etc/resolv.conf", t, 0o644);
    }
    util.log("dhcp: {d}.{d}.{d}.{d}/{d}", .{ a.ip[0], a.ip[1], a.ip[2], a.ip[3], a.prefix });
    dhcp_leased = true;
    dhcpSettle();
}

/// Bring eth0 up and open the socket. False: no way to get a lease at all.
fn dhcpOpen() bool {
    const ifname = "eth0";
    const idx = linkIndex(ifname);
    if (idx < 0) {
        util.log("dhcp: no eth0 ({d})", .{idx});
        return false;
    }
    dhcp_idx = @intCast(idx);
    _ = linkUp(dhcp_idx);
    dhcp_mac = readMac(ifname) orelse [6]u8{ 2, 0, 0, 0, 0, 1 };
    const s = sys.socket(sys.AF_INET, sys.SOCK_DGRAM | sys.SOCK_NONBLOCK | sys.SOCK_CLOEXEC, 0);
    if (s < 0) return false;
    _ = sys.setsockopt(s, sys.SOL_SOCKET, sys.SO_BROADCAST, &std.mem.toBytes(@as(i32, 1)));
    _ = sys.setsockopt(s, sys.SOL_SOCKET, sys.SO_REUSEADDR, &std.mem.toBytes(@as(i32, 1)));
    _ = sys.setsockopt(s, sys.SOL_SOCKET, sys.SO_BINDTODEVICE, ifname);
    const local = sys.SockaddrIn{ .port = std.mem.nativeToBig(u16, 68), .addr = .{ 0, 0, 0, 0 } };
    if (sys.bind(s, &local, @sizeOf(sys.SockaddrIn)) < 0) {
        sys.close(s);
        return false;
    }
    dhcp_fd = s;
    dhcp_xid = @truncate(sys.boottime_ns() ^ 0x6e6f6f64);
    dhcp_attempt = 0;
    dhcpWatch();
    return true;
}

fn dhcpLinked() void {
    if (dhcpOpen()) {
        dhcpDiscover();
    } else {
        util.log("continuing without eth0 lease", .{});
        dhcpSettle();
    }
}

/// Loopback, eth0 and the first DISCOVER. Returns at once; the event loop or `dhcpFinish` does the rest.
pub fn dhcpBegin() void {
    const lo = linkIndex("lo");
    if (lo > 0) _ = linkUp(@intCast(lo));
    dhcp_phase = .link;
    // The device may take a moment to appear.
    dhcp_deadline = sys.boottime_ns() + 1_000_000_000;
    if (linkIndex("eth0") >= 0) dhcpLinked();
}

/// Add the socket to the event loop, once both exist. Called from either side, whichever comes second.
pub fn dhcpWatch() void {
    if (dhcp_fd >= 0 and util.epfd >= 0) _ = sys.epoll_add(util.epfd, dhcp_fd, sys.EPOLLIN, util.tag(util.Tag.dhcp, 0));
}

/// Drain replies and act on timeouts. Safe to call on any wakeup.
pub fn dhcpPump() void {
    if (dhcp_phase == .idle or dhcp_phase == .done) return;
    if (dhcp_phase == .link) {
        if (linkIndex("eth0") >= 0 or sys.boottime_ns() >= dhcp_deadline) dhcpLinked();
        return;
    }
    var rx: [1500]u8 = undefined;
    while (dhcp_fd >= 0) {
        const r = sys.recvfrom(dhcp_fd, &rx, null, null);
        if (r <= 0) break;
        if (dhcp_phase == .discover) {
            const o = dhcpParse(rx[0..@intCast(r)], dhcp_xid, 2) orelse continue;
            var pkt: [600]u8 = undefined;
            const n = dhcpBuild(&pkt, dhcp_xid, dhcp_mac, 3, o.ip, o.server);
            dhcpBroadcast(pkt[0..n]);
            dhcp_phase = .request;
            dhcp_deadline = sys.boottime_ns() + 2_000_000_000;
        } else if (dhcpParse(rx[0..@intCast(r)], dhcp_xid, 5)) |a| {
            dhcpApply(a);
            return;
        }
    }
    if (sys.boottime_ns() >= dhcp_deadline) {
        dhcp_attempt += 1;
        dhcpDiscover();
    }
}

/// The event loop's timeout while the handshake is open, -1 once settled so an idle guest has no timer.
pub fn dhcpTimeoutMs() i32 {
    if (dhcp_phase == .idle or dhcp_phase == .done) return -1;
    if (dhcp_phase == .link) return 20;
    const now = sys.boottime_ns();
    if (dhcp_deadline <= now) return 0;
    return @intCast((dhcp_deadline - now) / 1_000_000 + 1);
}

/// Block until the lease settled. Same bound as the handshake itself, about seven seconds when no server answers.
pub fn dhcpFinish() void {
    while (dhcp_phase != .idle and dhcp_phase != .done) {
        if (dhcp_phase == .link) {
            sys.sleep_ms(20);
        } else {
            var pfd = sys.PollFd{ .fd = @intCast(dhcp_fd), .events = sys.POLLIN, .revents = 0 };
            _ = sys.poll(@ptrCast(&pfd), 1, 200);
        }
        dhcpPump();
    }
}

/// For forked children: wait for the parent's event loop to settle the lease. Bounded by more than `dhcpFinish`.
pub fn dhcpAwaitMarker() void {
    var waited: usize = 0;
    while (!util.exists(dhcp_marker) and waited < 12000) : (waited += 5) sys.sleep_ms(5);
}

/// A forked child must not keep port 68 bound or read the parent's replies.
pub fn dhcpCloseInChild() void {
    if (dhcp_fd >= 0) sys.close(dhcp_fd);
    dhcp_fd = -1;
    dhcp_phase = .idle;
}

/// Blocking form, for the machine init: true with a lease.
pub fn dhcpEth0() bool {
    dhcpBegin();
    dhcpFinish();
    return dhcp_leased;
}

// ------------------------------------------------------------------ networks

const max_nets = 64;
const max_records = 128;

pub const Record = struct { name: [64]u8 = undefined, nlen: u8 = 0, ip: ?[4]u8 = null, ip6: ?[16]u8 = null, used: bool = false };

pub const Network = struct {
    used: bool = false,
    name: [64]u8 = undefined,
    nlen: u8 = 0,
    bridge: [16]u8 = undefined,
    blen: u8 = 0,
    gw: [4]u8 = undefined,
    subnet: [4]u8 = undefined,
    prefix: u8 = 0,
    has4: bool = false,
    has6: bool = false,
    gw6: [16]u8 = undefined,
    prefix6: u8 = 0,
    bridge_idx: i32 = 0,
    internal: bool = false,
    /// The Mac loopback redirect is in this network's `noodle-<bridge>` table (removed with it).
    hostlo: bool = false,
    dns_fd: i32 = -1,
    records: [max_records]Record = @splat(.{}),

    pub fn nameStr(self: *const Network) []const u8 {
        return self.name[0..self.nlen];
    }
    pub fn bridgeStr(self: *const Network) []const u8 {
        return self.bridge[0..self.blen];
    }
};

pub var nets: [max_nets]Network = std.mem.zeroes([max_nets]Network); // all-zero => .bss

pub fn findNet(name: []const u8) ?*Network {
    for (&nets) |*n| if (n.used and std.mem.eql(u8, n.nameStr(), name)) return n;
    return null;
}
fn netIndex(n: *Network) u32 {
    return @intCast((@intFromPtr(n) - @intFromPtr(&nets)) / @sizeOf(Network));
}

var uplink_guarded = false;

/// Installs the uplink guard first; forwarding (v4 here, v6 in enableIp6Forward) stays off if that fails.
pub fn setIpForward() isize {
    var buf: [2048]u8 = undefined;
    var b = nl.Builder.init(&buf);
    nl.uplinkGuardBatch(&b, nextSeq(), "noodle-uplink", "eth0");
    const rc = exchange(NETLINK_NETFILTER, b.bytes(), nl.hostlo_batch_acks, null, null);
    if (rc < 0) {
        util.log("uplink forward guard failed: errno {d}", .{-rc});
        return rc;
    }
    uplink_guarded = true;
    _ = util.writeSys("/proc/sys/net/ipv4/ip_forward", "1");
    return 0;
}

var ip6_forwarding = false;

/// Preserve eth0's RA configuration across the transition to an IPv6 router.
/// accept_ra=2 overrides the forwarding-dependent default (Linux IP Sysctl).
fn enableIp6Forward() void {
    if (ip6_forwarding or !uplink_guarded) return;
    _ = util.writeSys("/proc/sys/net/ipv6/conf/eth0/accept_ra", "2");
    if (util.writeSys("/proc/sys/net/ipv6/conf/all/forwarding", "1") >= 0) ip6_forwarding = true;
}

fn parseSubnet6(subnet: []const u8) ?struct { ip: [16]u8, prefix: u8 } {
    const slash = std.mem.indexOfScalar(u8, subnet, '/') orelse return null;
    const ip = util.parseIp6(subnet[0..slash]) orelse return null;
    const p = std.fmt.parseInt(u8, subnet[slash + 1 ..], 10) catch return null;
    if (p > 128) return null;
    return .{ .ip = ip, .prefix = p };
}

fn parseSubnet(subnet: []const u8) ?struct { ip: [4]u8, prefix: u8 } {
    const slash = std.mem.indexOfScalar(u8, subnet, '/') orelse return null;
    const ip = util.parseIp4(subnet[0..slash]) orelse return null;
    const p = std.fmt.parseInt(u8, subnet[slash + 1 ..], 10) catch return null;
    if (p > 32) return null;
    return .{ .ip = ip, .prefix = p };
}

/// Returns 0 or a negative errno.
pub fn createNetwork(name: []const u8, bridge: []const u8, subnet: []const u8, gateway: []const u8, subnet6: []const u8, gateway6: []const u8, internal: bool) isize {
    if (findNet(name) != null) return 0;
    if (name.len == 0 or name.len > 63 or bridge.len == 0 or bridge.len > 15) return -sys.E.INVAL;
    const has4 = subnet.len > 0;
    const has6 = subnet6.len > 0;
    if (!has4 and !has6) return -sys.E.INVAL;
    const sn = if (has4) parseSubnet(subnet) orelse return -sys.E.INVAL else null;
    const gw = if (has4) util.parseIp4(gateway) orelse return -sys.E.INVAL else null;
    const sn6 = if (has6) parseSubnet6(subnet6) orelse return -sys.E.INVAL else null;
    const gw6 = if (has6) util.parseIp6(gateway6) orelse return -sys.E.INVAL else null;
    var slot: ?*Network = null;
    for (&nets) |*n| if (!n.used) {
        slot = n;
        break;
    };
    const n = slot orelse return -sys.E.NOMEM;

    var buf: [512]u8 = undefined;
    var b = nl.Builder.init(&buf);
    const low: [4]u8 = gw orelse gw6.?[12..16].*;
    nl.newBridge(&b, nextSeq(), bridge, .{ 0x02, 0x42, low[0], low[1], low[2], low[3] });
    var rc = rt(b.bytes());
    if (rc < 0 and rc != -sys.E.EXIST) return rc;
    const idx = linkIndex(bridge);
    if (idx < 0) return idx;
    if (sn) |v4| {
        rc = addAddr(@intCast(idx), gw.?, v4.prefix);
        if (rc < 0 and rc != -sys.E.EXIST) return rc;
    }
    rc = linkUp(@intCast(idx));
    if (rc < 0) return rc;
    if (sn6) |v6| {
        rc = addAddr6(@intCast(idx), gw6.?, v6.prefix);
        if (rc < 0 and rc != -sys.E.EXIST) return rc;
    }

    // masquerade (best effort: the kernel may lack nf_tables)
    var tn: [64]u8 = undefined;
    const tname = std.fmt.bufPrint(&tn, "noodle-{s}", .{bridge}) catch "noodle";
    var masked: [4]u8 = @splat(0);
    if (sn) |v4| {
        // normalise the subnet address to its network base
        const mask: u32 = if (v4.prefix == 0) 0 else ~@as(u32, 0) << @intCast(32 - v4.prefix);
        std.mem.writeInt(u32, &masked, std.mem.readInt(u32, &v4.ip, .big) & mask, .big);
    }
    if (internal) {
        // An inet table: it isolates both families.
        const nrc = nftInternal(tname, bridge);
        if (nrc < 0) return nrc;
    } else {
        if (sn) |v4| {
            const nrc = nftMasq(tname, masked, v4.prefix, bridge);
            if (nrc < 0 and nrc != -sys.E.EXIST) util.log("nft masquerade for {s} failed: errno {d}", .{ bridge, -nrc });
        }
        if (sn6) |v6| {
            enableIp6Forward();
            const nrc = nftMasq6(tname, util.maskIp6(v6.ip, v6.prefix), v6.prefix, bridge);
            if (nrc < 0 and nrc != -sys.E.EXIST) util.log("nft ip6 masquerade for {s} failed: errno {d}", .{ bridge, -nrc });
        }
    }

    n.* = .{};
    n.used = true;
    @memcpy(n.name[0..name.len], name);
    n.nlen = @intCast(name.len);
    @memcpy(n.bridge[0..bridge.len], bridge);
    n.blen = @intCast(bridge.len);
    n.has4 = has4;
    n.has6 = has6;
    if (sn) |v4| {
        n.gw = gw.?;
        n.subnet = masked;
        n.prefix = v4.prefix;
    }
    if (sn6) |v6| {
        n.gw6 = gw6.?;
        n.prefix6 = v6.prefix;
    }
    n.bridge_idx = @intCast(idx);
    n.internal = internal;
    hostloNetwork(n);

    // DNS responder on gateway:53. An IPv6-only network has only the per-container resolver.
    const s = if (gw != null) sys.socket(sys.AF_INET, sys.SOCK_DGRAM | sys.SOCK_NONBLOCK, 0) else -1;
    if (s >= 0) {
        _ = sys.setsockopt(s, sys.SOL_SOCKET, sys.SO_REUSEADDR, &std.mem.toBytes(@as(i32, 1)));
        const a = sys.SockaddrIn{ .port = std.mem.nativeToBig(u16, 53), .addr = gw.? };
        // BuildKit uses its own bridge. Only the default resolver accepts cross-device
        // traffic; receiveDefaultDns checks its ingress, including for forged source IPs.
        const scope = if (std.mem.eql(u8, name, "bridge"))
            sys.setsockopt(s, 0, std.os.linux.IP.PKTINFO, &std.mem.toBytes(@as(i32, 1)))
        else
            sys.setsockopt(s, sys.SOL_SOCKET, sys.SO_BINDTODEVICE, bridge);
        if (scope >= 0 and
            sys.bind(s, &a, @sizeOf(sys.SockaddrIn)) >= 0)
        {
            n.dns_fd = @intCast(s);
            _ = sys.epoll_add(util.epfd, s, sys.EPOLLIN, util.tag(util.Tag.dns, netIndex(n)));
        } else sys.close(s);
    }
    util.log("network {s}: bridge {s} ipv4={} ipv6={}", .{ name, bridge, has4, has6 });
    return 0;
}

// ------------------------------------------------------------------ Mac loopback relay

/// Nonzero once the host sent `host_loopback`: the guest port the redirect rules point at.
pub var hostlo_port: u16 = 0;
var hostlo_base = false;
/// The input guard is installed: only redirected connections reach the relay listener. hostlo.zig serves nothing before it.
pub var hostlo_guarded = false;

fn nftHostloGuard(port: u16) isize {
    var buf: [2048]u8 = undefined;
    var b = nl.Builder.init(&buf);
    nl.hostLoopbackGuardBatch(&b, nextSeq(), "noodle-hostlo", port);
    return exchange(NETLINK_NETFILTER, b.bytes(), nl.hostlo_batch_acks, null, null);
}

/// Internal networks never get the rule: only this allow path adds one, and it skips them.
fn hostloNetwork(n: *Network) void {
    if (hostlo_port == 0 or !hostlo_guarded or n.internal or !n.has4 or n.hostlo) return;
    const gw = vm_gateway orelse return;
    var tn: [64]u8 = undefined;
    const tname = std.fmt.bufPrint(&tn, "noodle-{s}", .{n.bridgeStr()}) catch return;
    const rc = nftHostlo(tname, "hostlo", nl.NF_INET_PRE_ROUTING, n.bridgeStr(), gw, hostlo_port);
    if (rc < 0) {
        util.log("mac loopback redirect for {s} failed: errno {d}", .{ n.bridgeStr(), -rc });
        return;
    }
    n.hostlo = true;
}

/// Install every redirect the relay needs. Runs at `host_loopback` and again when the lease names the Mac.
pub fn hostloApply() void {
    if (hostlo_port == 0) return;
    const gw = vm_gateway orelse return;
    if (!hostlo_guarded) {
        const rc = nftHostloGuard(hostlo_port);
        if (rc < 0) {
            // Without the guard a direct dial could pass for a redirect, so no redirect is installed either.
            util.log("mac loopback guard failed: errno {d}; relay stays off", .{-rc});
            return;
        }
        hostlo_guarded = true;
    }
    if (!hostlo_base) {
        // The VM's own traffic (`--network host`, the BuildKit daemon), then BuildKit's RUN bridge.
        const out = nftHostlo("noodle-hostlo", "output", nl.NF_INET_LOCAL_OUT, null, gw, hostlo_port);
        const bk = if (out >= 0) nftHostlo("noodle-hostlo", "prerouting", nl.NF_INET_PRE_ROUTING, builder_bridge, gw, hostlo_port) else out;
        if (bk < 0) util.log("mac loopback redirect failed: errno {d}", .{-bk}) else hostlo_base = true;
    }
    for (&nets) |*n| if (n.used) hostloNetwork(n);
}

pub fn removeNetwork(name: []const u8) isize {
    const n = findNet(name) orelse return 0;
    if (n.dns_fd >= 0) {
        resolver.forget(n.dns_fd);
        _ = sys.epoll_del(util.epfd, n.dns_fd);
        sys.close(n.dns_fd);
    }
    var tn: [64]u8 = undefined;
    const tname = std.fmt.bufPrint(&tn, "noodle-{s}", .{n.bridgeStr()}) catch "noodle";
    if (n.internal) {
        _ = nftDelete(tname, nl.NFPROTO_INET);
    } else {
        if (n.has4) _ = nftDelete(tname, nl.NFPROTO_IPV4);
        if (n.has6) _ = nftDelete(tname, nl.NFPROTO_IPV6);
    }
    var buf: [128]u8 = undefined;
    var b = nl.Builder.init(&buf);
    nl.delLink(&b, nextSeq(), n.bridge_idx);
    const rc = rt(b.bytes());
    n.used = false;
    return if (rc < 0 and rc != -sys.E.NOENT) rc else 0;
}

// ------------------------------------------------------------------ DNS

pub const Rec = struct { name: []const u8, ip: ?[4]u8, ip6: ?[16]u8 };
pub fn setRecords(n: *Network, recs: []const Rec) void {
    for (&n.records) |*r| r.used = false;
    for (recs) |r| _ = addRecord(n, r.name, r.ip, r.ip6);
}

/// One slot per (name, address): containers sharing an alias all answer. False when the table is full.
pub fn addRecord(n: *Network, name: []const u8, ip: ?[4]u8, ip6: ?[16]u8) bool {
    if (name.len == 0 or name.len > 63) return true;
    var slot: ?*Record = null;
    for (&n.records) |*r| {
        if (r.used and r.nlen == name.len and std.ascii.eqlIgnoreCase(r.name[0..r.nlen], name) and
            ((ip != null and r.ip != null and std.mem.eql(u8, &ip.?, &r.ip.?)) or
            (ip6 != null and r.ip6 != null and std.mem.eql(u8, &ip6.?, &r.ip6.?))))
        {
            slot = r;
            break;
        }
        if (!r.used and slot == null) slot = r;
    }
    const r = slot orelse {
        util.log("dns: record table full, {s} not added", .{name});
        return false;
    };
    r.used = true;
    r.nlen = @intCast(name.len);
    for (name, 0..) |c, i| r.name[i] = std.ascii.toLower(c);
    r.ip = ip;
    r.ip6 = ip6;
    return true;
}

pub fn removeRecordsFor(n: *Network, ip: ?[4]u8, ip6: ?[16]u8) void {
    for (&n.records) |*r| {
        if (!r.used) continue;
        const same4 = ip != null and r.ip != null and std.mem.eql(u8, &ip.?, &r.ip.?);
        const same6 = ip6 != null and r.ip6 != null and std.mem.eql(u8, &ip6.?, &r.ip6.?);
        if (same4 or same6) r.used = false;
    }
}

pub fn lookup(n: *const Network, name: []const u8) ?*const Record {
    for (&n.records) |*r| if (r.used and std.mem.eql(u8, r.name[0..r.nlen], name)) return r;
    return null;
}

/// The reply to a question about a name we hold: every address of every record under that name, up to
/// `dns.max_answers`. The family it lacks gets an empty answer.
pub fn answer(out: []u8, q: []const u8, question: *const dns.Question, n: *const Network, rec: *const Record) usize {
    var v4: [dns.max_answers][4]u8 = undefined;
    var v6: [dns.max_answers][16]u8 = undefined;
    var c4: usize = 0;
    var c6: usize = 0;
    for (&n.records) |*x| {
        if (!x.used or x.nlen != rec.nlen or !std.mem.eql(u8, x.name[0..x.nlen], rec.name[0..rec.nlen])) continue;
        if (x.ip) |a| if (c4 < v4.len) {
            v4[c4] = a;
            c4 += 1;
        };
        if (x.ip6) |a| if (c6 < v6.len) {
            v6[c6] = a;
            c6 += 1;
        };
    }
    return switch (question.qtype) {
        dns.TYPE_A => dns.buildResponseMany(out, q, question, v4[0..c4]),
        dns.TYPE_AAAA => dns.buildResponse6Many(out, q, question, v6[0..c6]),
        else => dns.buildResponse(out, q, question, null),
    };
}

/// A source address alone cannot enforce internal-network isolation: NET_RAW permits
/// spoofing it. Use the kernel's ingress interface and fail closed without packet info.
fn receiveDefaultDns(n: *const Network, pkt: []u8, from: *sys.SockaddrIn) isize {
    const linux = std.os.linux;
    const Info = extern struct { header: linux.cmsghdr, packet: linux.in_pktinfo };
    var control: Info = undefined;
    var iov = [_]std.posix.iovec{.{ .base = pkt.ptr, .len = pkt.len }};
    var msg = linux.msghdr{
        .name = @ptrCast(from),
        .namelen = @sizeOf(sys.SockaddrIn),
        .iov = &iov,
        .iovlen = iov.len,
        .control = &control,
        .controllen = @sizeOf(Info),
        .flags = 0,
    };
    const rc = sys.sc(.recvmsg, @intCast(n.dns_fd), @intFromPtr(&msg), 0, 0, 0, 0);
    if (rc <= 0) return rc;
    const needed = @sizeOf(linux.cmsghdr) + @sizeOf(linux.in_pktinfo);
    if (msg.flags & (linux.MSG.CTRUNC | linux.MSG.TRUNC) != 0 or msg.controllen < needed or
        control.header.len != needed or control.header.level != 0 or control.header.type != linux.IP.PKTINFO)
        return -sys.E.ACCES;
    const ingress = control.packet.ifindex;
    if (ingress <= 0) return -sys.E.ACCES;
    if (ingress == n.bridge_idx or ingress == linkIndex("lo") or ingress == linkIndex(builder_bridge)) return rc;
    return -sys.E.ACCES;
}

pub fn handleDns(idx: u32) void {
    const n = &nets[idx];
    if (!n.used or n.dns_fd < 0) return;
    var pkt: [1500]u8 = undefined;
    var out: [1500]u8 = undefined;
    var iter: usize = 0;
    while (iter < 32) : (iter += 1) {
        var from: sys.SockaddrIn = undefined;
        var flen: u32 = @sizeOf(sys.SockaddrIn);
        const r = if (std.mem.eql(u8, n.nameStr(), "bridge"))
            receiveDefaultDns(n, &pkt, &from)
        else
            sys.recvfrom(n.dns_fd, &pkt, &from, &flen);
        if (r == -sys.E.ACCES) continue;
        if (r <= 0) return;
        const q = pkt[0..@intCast(r)];
        if (dns.isNotimp(q)) {
            _ = sys.sendto(n.dns_fd, out[0..dns.buildNotimp(&out, q)], &from, @sizeOf(sys.SockaddrIn));
            continue;
        }
        if (!dns.isQuery(q)) continue;
        const question = dns.parseQuestion(q) orelse continue;
        if (question.qclass == 1) {
            if (lookup(n, question.nameSlice())) |rec| {
                const len = answer(&out, q, &question, n, rec);
                _ = sys.sendto(n.dns_fd, out[0..len], &from, @sizeOf(sys.SockaddrIn));
                continue;
            }
        }
        if (n.internal) {
            const len = dns.buildServfail(&out, q, &question);
            _ = sys.sendto(n.dns_fd, out[0..len], &from, @sizeOf(sys.SockaddrIn));
            continue;
        }
        resolver.forward(n.dns_fd, from, q, &question, &.{});
    }
}

// ------------------------------------------------------------------ container attach

pub const AttachSpec = struct {
    net: *Network,
    ip: ?[4]u8,
    prefix: u8,
    gateway: ?[4]u8,
    ip6: ?[16]u8 = null,
    prefix6: u8 = 0,
    gateway6: ?[16]u8 = null,
    mac: ?[6]u8,
    ifname: []const u8, // name inside the container (eth0, eth1...)
    host_if: []const u8, // name of the host-side veth
};

/// Create the veth pair for `pid`'s network namespace and configure the container side.
/// Returns 0 or a negative errno.
pub fn attachBridge(pid: i32, a: AttachSpec) isize {
    var peer_buf: [16]u8 = undefined;
    const peer = std.fmt.bufPrint(&peer_buf, "p{s}", .{a.host_if[1..]}) catch return -sys.E.INVAL;
    var buf: [512]u8 = undefined;
    var b = nl.Builder.init(&buf);
    nl.newVeth(&b, nextSeq(), a.host_if, peer, a.mac, @intCast(pid));
    var rc = rt(b.bytes());
    if (rc < 0) return rc;
    const hidx = linkIndex(a.host_if);
    if (hidx < 0) return hidx;
    b.reset();
    nl.setMaster(&b, nextSeq(), @intCast(hidx), @intCast(a.net.bridge_idx));
    rc = rt(b.bytes());
    if (rc < 0) return rc;
    rc = linkUp(@intCast(hidx));
    if (rc < 0) return rc;
    return inNetns(pid, peer, a);
}

/// Bring up lo only (network_mode none).
fn inNetns(pid: i32, peer: []const u8, a_opt: ?AttachSpec) isize {
    const child = sys.fork();
    if (child < 0) return child;
    if (child == 0) {
        _ = sys.sigprocmask(2, 0);
        const code = netnsBody(pid, peer, a_opt);
        sys.exit(@intCast(code));
    }
    var status: u32 = 0;
    while (true) {
        const w = sys.wait4(child, &status, 0);
        if (w == -sys.E.INTR) continue;
        break;
    }
    const code = (status >> 8) & 0xff;
    if (code == 0) return 0;
    return -@as(isize, code);
}

fn netnsBody(pid: i32, peer: []const u8, a_opt: ?AttachSpec) u32 {
    const path = util.zf("/proc/{d}/ns/net", .{pid});
    const fd = sys.open(path.ptr, sys.O.RDONLY, 0);
    if (fd < 0) return @intCast(-fd);
    const rc = sys.setns(fd, sys.CLONE.NEWNET);
    if (rc < 0) return @intCast(-rc);
    const lo = linkIndex("lo");
    if (lo > 0) _ = linkUp(@intCast(lo));
    const a = a_opt orelse return 0;
    const pidx = linkIndex(peer);
    if (pidx < 0) return @intCast(-pidx);
    var buf: [256]u8 = undefined;
    var b = nl.Builder.init(&buf);
    nl.setName(&b, nextSeq(), @intCast(pidx), a.ifname);
    var r2 = rt(b.bytes());
    if (r2 < 0) return @intCast(-r2);
    // Before the link comes up, so an IPv4-only interface never sends a neighbour or listener report.
    const v6_key = if (a.ip6 != null) "accept_dad" else "disable_ipv6";
    _ = util.writeSys(util.zf("/proc/sys/net/ipv6/conf/{s}/{s}", .{ a.ifname, v6_key }).ptr, if (a.ip6 != null) "0" else "1");
    if (a.ip) |ip| {
        r2 = addAddr(@intCast(pidx), ip, a.prefix);
        if (r2 < 0) return @intCast(-r2);
    }
    r2 = linkUp(@intCast(pidx));
    if (r2 < 0) return @intCast(-r2);
    if (a.gateway) |gw| {
        r2 = addDefaultRoute(gw);
        if (r2 < 0 and r2 != -sys.E.EXIST) return @intCast(-r2);
    }
    if (a.ip6) |ip6| {
        r2 = addAddr6(@intCast(pidx), ip6, a.prefix6);
        if (r2 < 0) return @intCast(-r2);
        // Internal networks carry no IPv6 default route (peers are on-link); the nft filter drops forwarding as well.
        if (a.gateway6) |gw6| if (!a.net.internal) {
            r2 = addDefaultRoute6(@intCast(pidx), gw6);
            if (r2 < 0 and r2 != -sys.E.EXIST) return @intCast(-r2);
        };
    }
    return 0;
}

pub fn deleteLinkByName(name: []const u8) void {
    const idx = linkIndex(name);
    if (idx < 0) return;
    var buf: [128]u8 = undefined;
    var b = nl.Builder.init(&buf);
    nl.delLink(&b, nextSeq(), @intCast(idx));
    _ = rt(b.bytes());
}
