//! Embedded DNS. A container on a user network asks 127.0.0.11:53. This file opens a UDP socket and a TCP
//! listener for it inside the container's network namespace and polls them from the agent's loop (see
//! dnsredir.zig for why they sit on another port). TCP serves clients that retry after a truncated answer.
//! It answers from the records of every network the container is attached to,
//! and forwards other names to the container's `--dns` servers or to the VM's
//! resolver. No thread, and a timer only while a forwarded query is outstanding.
const std = @import("std");
const sys = @import("sys.zig");
const util = @import("util.zig");
const dns = @import("dnsmsg");
const net = @import("net.zig");
const stream = @import("stream.zig");
const redir = @import("dnsredir.zig");
const container = @import("container.zig");
const Value = @import("json").Value;

const max_servers = 3;
const max_links = 8;
const server_wait_ns: u64 = 1_500_000_000;
const vm_resolver_wait_ns: u64 = 800_000_000;
const host_wait_ns: u64 = 3_000_000_000;
const tcp_idle_ns: u64 = 10_000_000_000;
const max_tcp_conns = 16;
const max_tcp_up = 4;
const max_tcp_per_resolver = 4; // one container cannot take every client slot
/// A message over TCP is at most this long here: queries are capped like the UDP path, answers have room for EDNS sizes.
const max_query = 512;
const max_answer = 4096;

const Link = struct { alias: [64]u8, alen: u8, target: [64]u8, tlen: u8 };

const Resolver = struct {
    is_open: bool,
    /// Listening on the redirect port, so clients need the cgroup programs from dnsredir.zig.
    redirected: bool,
    /// SO_NETNS_COOKIE of the container's namespace, which the redirect programs compare against.
    cookie: u64,
    fd: i32,
    has_tcp: bool,
    tfd: i32,
    servers: [max_servers][4]u8,
    nservers: u8,
    links: [max_links]Link,
    nlinks: u8,
};

var resolvers: [container.max_conts]Resolver = std.mem.zeroes([container.max_conts]Resolver);
var host_ns: i32 = -1;

pub fn isOpen(idx: u32) bool {
    return resolvers[idx].is_open;
}

/// A container that joins the network namespace of `owner_idx` reaches the same 127.0.0.11. When the owner's
/// resolver sits on the redirect port, the joiner's cgroup needs the same redirect programs.
pub fn shareRedirect(owner_idx: u32, cgroup: [*:0]const u8) void {
    const r = &resolvers[owner_idx];
    if (r.is_open and r.redirected) _ = redir.attach(cgroup, r.cookie);
}

/// Sets up the resolver for container `idx`, whose namespace `pid` holds. A
/// failure only costs name resolution, so the container still starts.
pub fn open(idx: u32, spec: Value, pid: i32) void {
    close(idx);
    const r = &resolvers[idx];
    r.nservers = 0;
    for (spec.list("servers")) |s| {
        if (s != .str or r.nservers == max_servers) continue;
        r.servers[r.nservers] = util.parseIp4(s.str) orelse continue;
        r.nservers += 1;
    }
    r.nlinks = 0;
    for (spec.list("links")) |l| {
        const alias = l.strOr("alias", "");
        const target = l.strOr("target", "");
        if (r.nlinks == max_links or alias.len == 0 or alias.len > 64 or target.len == 0 or target.len > 64) continue;
        const link = &r.links[r.nlinks];
        for (alias, 0..) |ch, i| link.alias[i] = std.ascii.toLower(ch);
        for (target, 0..) |ch, i| link.target[i] = std.ascii.toLower(ch);
        link.alen = @intCast(alias.len);
        link.tlen = @intCast(target.len);
        r.nlinks += 1;
    }
    const cgroup = util.zf("/sys/fs/cgroup/noodle/{s}", .{container.conts[idx].idStr()});
    r.cookie = netnsCookie(pid);
    const redirected = r.cookie != 0 and redir.attach(cgroup.ptr, r.cookie);
    const port: u16 = if (redirected) redir.redirect_port else 53;
    var tcp_fd: isize = -1;
    const fd = bindInNetns(pid, port, &tcp_fd);
    if (fd < 0) {
        util.logErr("embedded dns", fd);
        return;
    }
    r.fd = @intCast(fd);
    r.is_open = true;
    r.redirected = redirected;
    _ = sys.epoll_add(util.epfd, fd, sys.EPOLLIN, util.tag(util.Tag.resolver, idx));
    r.has_tcp = tcp_fd >= 0;
    if (r.has_tcp) {
        r.tfd = @intCast(tcp_fd);
        _ = sys.epoll_add(util.epfd, tcp_fd, sys.EPOLLIN, util.tag(util.Tag.resolver_tcp, idx));
    }
}

pub fn close(idx: u32) void {
    const r = &resolvers[idx];
    if (!r.is_open) return;
    forget(r.fd);
    _ = sys.epoll_del(util.epfd, r.fd);
    sys.close(r.fd);
    if (r.has_tcp) {
        _ = sys.epoll_del(util.epfd, r.tfd);
        sys.close(r.tfd);
        r.has_tcp = false;
    }
    for (&conns, 0..) |*cn, i| if (cn.used and cn.ridx == idx) closeConn(i);
    r.is_open = false;
}

/// The namespace cookie of `pid`'s network namespace, 0 when the kernel has no SO_NETNS_COOKIE (the resolver then binds :53).
fn netnsCookie(pid: i32) u64 {
    if (host_ns < 0) {
        const self = sys.open("/proc/self/ns/net", sys.O.RDONLY | sys.O.CLOEXEC, 0);
        if (self < 0) return 0;
        host_ns = @intCast(self);
    }
    const ns = sys.open(util.zf("/proc/{d}/ns/net", .{pid}).ptr, sys.O.RDONLY, 0);
    if (ns < 0) return 0;
    defer sys.close(ns);
    if (sys.setns(ns, sys.CLONE.NEWNET) < 0) return 0;
    defer _ = sys.setns(host_ns, sys.CLONE.NEWNET);
    const s = sys.socket(sys.AF_INET, sys.SOCK_DGRAM | sys.SOCK_CLOEXEC, 0);
    if (s < 0) return 0;
    defer sys.close(s);
    var cookie: u64 = 0;
    var len: u32 = 8;
    const SO_NETNS_COOKIE = 71;
    if (sys.sc(.getsockopt, @bitCast(s), sys.SOL_SOCKET, SO_NETNS_COOKIE, @intFromPtr(&cookie), @intFromPtr(&len), 0) < 0) return 0;
    return cookie;
}

/// A UDP socket (returned) and a TCP listener (`tcp`, -1 if it could not be made) bound to 127.0.0.11:`port` in
/// `pid`'s namespace. The agent has one thread, so it can step into the namespace and back. Sockets stay in the
/// namespace they were made in.
fn bindInNetns(pid: i32, port: u16, tcp: *isize) isize {
    if (host_ns < 0) {
        const self = sys.open("/proc/self/ns/net", sys.O.RDONLY | sys.O.CLOEXEC, 0);
        if (self < 0) return self;
        host_ns = @intCast(self);
    }
    const ns = sys.open(util.zf("/proc/{d}/ns/net", .{pid}).ptr, sys.O.RDONLY, 0);
    if (ns < 0) return ns;
    defer sys.close(ns);
    const entered = sys.setns(ns, sys.CLONE.NEWNET);
    if (entered < 0) return entered;
    defer _ = sys.setns(host_ns, sys.CLONE.NEWNET);
    const s = sys.socket(sys.AF_INET, sys.SOCK_DGRAM | sys.SOCK_NONBLOCK | sys.SOCK_CLOEXEC, 0);
    if (s < 0) return s;
    const a = sys.SockaddrIn{ .port = std.mem.nativeToBig(u16, port), .addr = .{ 127, 0, 0, 11 } };
    const bound = sys.bind(s, &a, @sizeOf(sys.SockaddrIn));
    if (bound < 0) {
        sys.close(s);
        return bound;
    }
    tcp.* = -1;
    const t = sys.socket(sys.AF_INET, sys.SOCK_STREAM | sys.SOCK_NONBLOCK | sys.SOCK_CLOEXEC, 0);
    if (t >= 0) {
        if (sys.bind(t, &a, @sizeOf(sys.SockaddrIn)) >= 0 and sys.listen(t, 8) >= 0) tcp.* = t else sys.close(t);
    }
    return s;
}

/// A container connected to its first user network late: its resolv.conf now
/// names the embedded resolver, with search and options kept.
pub fn pointResolvConf(dir: []const u8) void {
    const path = util.zf("{s}/resolv.conf", .{dir});
    const old = util.readFile(path.ptr, 4096) orelse "";
    var out: [4200]u8 = undefined;
    _ = util.writeFile(path.ptr, util.resolvConfForEmbedded(&out, old), 0o644);
}

fn mapLink(r: *const Resolver, name: []const u8) []const u8 {
    for (r.links[0..r.nlinks]) |*l| {
        if (std.mem.eql(u8, l.alias[0..l.alen], name)) return l.target[0..l.tlen];
    }
    return name;
}

const Found = struct { n: *const net.Network, rec: *const net.Record };
fn lookupFor(c: *const container.Cont, name: []const u8) ?Found {
    for (&c.nets) |*cn| {
        if (!cn.used) continue;
        const n = net.findNet(cn.name[0..cn.nlen]) orelse continue;
        if (net.lookup(n, name)) |rec| return .{ .n = n, .rec = rec };
    }
    return null;
}

/// True when some network the container is on may reach outside.
fn canForward(c: *const container.Cont) bool {
    for (&c.nets) |*cn| {
        if (!cn.used) continue;
        const n = net.findNet(cn.name[0..cn.nlen]) orelse continue;
        if (!n.internal) return true;
    }
    return false;
}

pub fn onQuery(idx: u32) void {
    const r = &resolvers[idx];
    if (!r.is_open) return;
    var pkt: [1500]u8 = undefined;
    var iter: usize = 0;
    while (iter < 32) : (iter += 1) {
        var from: sys.SockaddrIn = undefined;
        var flen: u32 = @sizeOf(sys.SockaddrIn);
        const got = sys.recvfrom(r.fd, &pkt, &from, &flen);
        if (got <= 0) return;
        serve(idx, r.fd, false, from, pkt[0..@intCast(got)]);
    }
}

/// Answers one query that came in on `fd`, over UDP from `from` or over the TCP connection `fd`.
fn serve(idx: u32, fd: i32, tcp: bool, from: sys.SockaddrIn, q: []const u8) void {
    const r = &resolvers[idx];
    const c = &container.conts[idx];
    var out: [1500]u8 = undefined;
    if (dns.isNotimp(q)) {
        sendReply(fd, tcp, &from, out[0..dns.buildNotimp(&out, q)]);
        return;
    }
    if (!dns.isQuery(q)) return;
    const question = dns.parseQuestion(q) orelse return;
    if (question.qclass == 1) {
        if (lookupFor(c, mapLink(r, question.nameSlice()))) |f| {
            const len = net.answer(&out, q, &question, f.n, f.rec);
            sendReply(fd, tcp, &from, out[0..len]);
            return;
        }
    }
    if (!canForward(c)) {
        const len = dns.buildServfail(&out, q, &question);
        sendReply(fd, tcp, &from, out[0..len]);
        return;
    }
    forwardEx(fd, tcp, from, q, &question, r.servers[0..r.nservers]);
}

/// One datagram, or one length-prefixed message on a TCP connection. A TCP write that does not fit shuts the
/// connection instead of leaving half a message in it.
fn sendReply(fd: i32, tcp: bool, to: *const sys.SockaddrIn, data: []const u8) void {
    if (!tcp) {
        _ = sys.sendto(fd, data, to, @sizeOf(sys.SockaddrIn));
        return;
    }
    if (data.len > max_answer) return;
    var f: [2 + max_answer]u8 = undefined;
    std.mem.writeInt(u16, f[0..2], @intCast(data.len), .big);
    @memcpy(f[2..][0..data.len], data);
    if (sys.write(fd, f[0 .. 2 + data.len]) != @as(isize, @intCast(2 + data.len))) _ = sys.shutdown(fd, 2);
}

// ------------------------------------------------------------------ TCP clients

const Conn = struct {
    used: bool,
    fd: i32,
    ridx: u32,
    have: u16,
    deadline_ns: u64,
    buf: [2 + max_query]u8,
};
var conns: [max_tcp_conns]Conn = std.mem.zeroes([max_tcp_conns]Conn);
var open_conns: u32 = 0;

pub fn onAccept(idx: u32) void {
    const r = &resolvers[idx];
    if (!r.is_open or !r.has_tcp) return;
    var iter: usize = 0;
    while (iter < 8) : (iter += 1) {
        const fd = sys.sc(.accept4, @intCast(r.tfd), 0, 0, sys.SOCK_NONBLOCK | sys.SOCK_CLOEXEC, 0, 0);
        if (fd < 0) return;
        var slot: ?usize = null;
        var mine: u32 = 0;
        for (&conns, 0..) |*cn, i| {
            if (cn.used and cn.ridx == idx) mine += 1;
            if (!cn.used and slot == null) slot = i;
        }
        if (mine >= max_tcp_per_resolver) slot = null;
        const i = slot orelse {
            sys.close(fd);
            continue;
        };
        conns[i] = .{ .used = true, .fd = @intCast(fd), .ridx = idx, .have = 0, .deadline_ns = sys.boottime_ns() + tcp_idle_ns, .buf = undefined };
        open_conns += 1;
        _ = sys.epoll_add(util.epfd, fd, sys.EPOLLIN, util.tag(util.Tag.dns_conn, @intCast(i)));
    }
}

/// A forked worker must not keep client connections open: the client would see no EOF while the job runs.
pub fn closeConnsInChild() void {
    for (&conns) |*cn| if (cn.used) sys.close(cn.fd);
}

fn closeConn(i: usize) void {
    const cn = &conns[i];
    if (!cn.used) return;
    forget(cn.fd);
    _ = sys.epoll_del(util.epfd, cn.fd);
    sys.close(cn.fd);
    cn.used = false;
    open_conns -= 1;
}

pub fn onConn(i: u32) void {
    const cn = &conns[i];
    if (!cn.used) return;
    // A full buffer would make the read return 0 and look like EOF; a complete message is always consumed below.
    if (cn.have >= cn.buf.len) return closeConn(i);
    const got = sys.read(cn.fd, cn.buf[cn.have..]);
    if (got <= 0) {
        if (got != -sys.E.AGAIN) closeConn(i);
        return;
    }
    cn.have += @intCast(got);
    cn.deadline_ns = sys.boottime_ns() + tcp_idle_ns;
    while (cn.have >= 2) {
        const len: usize = std.mem.readInt(u16, cn.buf[0..2], .big);
        if (len < 12 or len > max_query) return closeConn(i);
        if (cn.have < 2 + len) return;
        var q: [max_query]u8 = undefined;
        @memcpy(q[0..len], cn.buf[2..][0..len]);
        const rest = cn.have - (2 + len);
        std.mem.copyForwards(u8, cn.buf[0..rest], cn.buf[2 + len ..][0..rest]);
        cn.have = @intCast(rest);
        serve(cn.ridx, cn.fd, true, std.mem.zeroes(sys.SockaddrIn), q[0..len]);
        if (!cn.used) return;
    }
}

// ------------------------------------------------------------------ forwarding

const Pending = struct {
    used: bool,
    reply_fd: i32,
    client: sys.SockaddrIn,
    orig_id: u16,
    new_id: u16,
    question: dns.Question,
    /// Servers still to try after `server`.
    servers: [max_servers][4]u8,
    nservers: u8,
    tried: u8,
    asked_host: bool,
    server: [4]u8,
    deadline_ns: u64,
    query: [512]u8,
    qlen: u16,
    /// The client is on TCP, so servers are asked over TCP too: a truncated UDP answer would only send it round again.
    tcp: bool,
    up: i8,
    seq: u64,
};

const max_pending_per_source = 16; // one container cannot churn out the others' in-flight queries
var pending_seq: u64 = 0;

var pending: [64]Pending = std.mem.zeroes([64]Pending);
var active: u32 = 0;
var up_fd: i32 = -1;

fn upstreamSocket() i32 {
    if (up_fd >= 0) return up_fd;
    const s = sys.socket(sys.AF_INET, sys.SOCK_DGRAM | sys.SOCK_NONBLOCK | sys.SOCK_CLOEXEC, 0);
    if (s < 0) return -1;
    up_fd = @intCast(s);
    _ = sys.epoll_add(util.epfd, s, sys.EPOLLIN, util.tag(util.Tag.dns_up, 0));
    return up_fd;
}

fn servfail(p: *const Pending) void {
    var out: [600]u8 = undefined;
    const len = dns.buildServfail(&out, p.query[0..p.qlen], &p.question);
    dns.setId(out[0..len], p.orig_id);
    sendReply(p.reply_fd, p.tcp, &p.client, out[0..len]);
}

fn release(p: *Pending) void {
    dropUp(p);
    p.used = false;
    active -= 1;
}

/// A random ID no outstanding query has, or null.
fn freshId() ?u16 {
    var v: u16 = undefined;
    for (0..16) |_| {
        if (sys.sc(.getrandom, @intFromPtr(&v), @sizeOf(u16), 1, 0, 0, 0) != @sizeOf(u16)) return null;
        var taken = false;
        for (&pending) |*p| {
            if (p.used and p.new_id == v) taken = true;
        }
        if (!taken) return v;
    }
    return null;
}

/// Asks `servers` (or, when empty, the VM's resolver and then the Mac) and replies
/// to `client` on `reply_fd` when the answer comes. Queries that can't go out get SERVFAIL.
pub fn forward(reply_fd: i32, client: sys.SockaddrIn, q: []const u8, question: *const dns.Question, servers: []const [4]u8) void {
    forwardEx(reply_fd, false, client, q, question, servers);
}

fn forwardEx(reply_fd: i32, tcp: bool, client: sys.SockaddrIn, q: []const u8, question: *const dns.Question, servers: []const [4]u8) void {
    const fd = upstreamSocket();
    const id = freshId();
    if (fd < 0 or id == null or q.len > 512) {
        var out: [1500]u8 = undefined;
        const len = dns.buildServfail(&out, q, question);
        sendReply(reply_fd, tcp, &client, out[0..len]);
        return;
    }
    var slot: *Pending = &pending[id.? % pending.len];
    var free: ?*Pending = null;
    var mine: u32 = 0;
    var oldest: ?*Pending = null;
    for (&pending) |*p| {
        if (!p.used) {
            if (free == null) free = p;
        } else if (if (tcp) p.tcp and p.reply_fd == reply_fd else !p.tcp and p.reply_fd == reply_fd and std.mem.eql(u8, &p.client.addr, &client.addr)) {
            mine += 1;
            if (oldest == null or p.seq < oldest.?.seq) oldest = p;
        }
    }
    if (mine >= max_pending_per_source) slot = oldest.? else if (free) |f| slot = f;
    if (slot.used) {
        servfail(slot); // the evicted query gets an answer instead of silence
        dropUp(slot);
    } else active += 1;
    slot.* = std.mem.zeroes(Pending);
    slot.used = true;
    slot.up = -1;
    pending_seq += 1;
    slot.seq = pending_seq;
    slot.tcp = tcp;
    slot.reply_fd = reply_fd;
    slot.client = client;
    slot.orig_id = dns.id(q);
    slot.new_id = id.?;
    slot.question = question.*;
    slot.nservers = @intCast(servers.len);
    for (servers, 0..) |s, i| slot.servers[i] = s;
    @memcpy(slot.query[0..q.len], q);
    slot.qlen = @intCast(q.len);
    dns.setId(slot.query[0..q.len], slot.new_id);
    if (!sendNext(slot)) {
        servfail(slot);
        release(slot);
    }
}

/// Sends the query to whoever is next. False when nobody is left.
fn sendNext(p: *Pending) bool {
    dropUp(p);
    while (true) {
        if (p.nservers > 0) {
            if (p.tried >= p.nservers) return false;
            if (send(p, p.servers[p.tried], server_wait_ns)) return true;
        } else if (p.tried == 0 and !std.mem.eql(u8, &net.upstream_dns, &[4]u8{ 0, 0, 0, 0 })) {
            if (send(p, net.upstream_dns, vm_resolver_wait_ns)) return true;
        } else {
            if (p.asked_host) return false;
            p.asked_host = true;
            p.deadline_ns = sys.boottime_ns() + host_wait_ns;
            return stream.emitDnsQuery(p.new_id, p.query[0..p.qlen]);
        }
    }
}

fn send(p: *Pending, server: [4]u8, wait_ns: u64) bool {
    p.server = server;
    p.tried += 1;
    p.deadline_ns = sys.boottime_ns() + wait_ns;
    if (p.tcp) return startUpTcp(p, server);
    const to = sys.SockaddrIn{ .port = std.mem.nativeToBig(u16, 53), .addr = server };
    _ = sys.sendto(up_fd, p.query[0..p.qlen], &to, @sizeOf(sys.SockaddrIn));
    return true;
}

// ------------------------------------------------------------------ TCP to servers

const UpTcp = struct {
    used: bool,
    fd: i32,
    pend: u8,
    sent: bool,
    have: u16,
    buf: [2 + max_answer]u8,
};
var ups: [max_tcp_up]UpTcp = std.mem.zeroes([max_tcp_up]UpTcp);

fn pendingIndex(p: *Pending) u8 {
    return @intCast((@intFromPtr(p) - @intFromPtr(&pending)) / @sizeOf(Pending));
}

fn dropUp(p: *Pending) void {
    if (p.up < 0) return;
    const u = &ups[@intCast(p.up)];
    _ = sys.epoll_del(util.epfd, u.fd);
    sys.close(u.fd);
    u.used = false;
    p.up = -1;
}

/// Opens a connection to `server`:53; the query goes out once it is connected.
fn startUpTcp(p: *Pending, server: [4]u8) bool {
    var slot: ?usize = null;
    for (&ups, 0..) |*u, i| if (!u.used) {
        slot = i;
        break;
    };
    const i = slot orelse return false;
    const fd = sys.socket(sys.AF_INET, sys.SOCK_STREAM | sys.SOCK_NONBLOCK | sys.SOCK_CLOEXEC, 0);
    if (fd < 0) return false;
    const to = sys.SockaddrIn{ .port = std.mem.nativeToBig(u16, 53), .addr = server };
    const rc = sys.connect(fd, &to, @sizeOf(sys.SockaddrIn));
    if (rc < 0 and rc != -sys.E.INPROGRESS) {
        sys.close(fd);
        return false;
    }
    ups[i] = .{ .used = true, .fd = @intCast(fd), .pend = pendingIndex(p), .sent = false, .have = 0, .buf = undefined };
    p.up = @intCast(i);
    _ = sys.epoll_add(util.epfd, fd, sys.EPOLLIN | sys.EPOLLOUT, util.tag(util.Tag.dns_up_tcp, @intCast(i)));
    return true;
}

pub fn onUpTcp(i: u32) void {
    const u = &ups[i];
    if (!u.used) return;
    const p = &pending[u.pend];
    if (!p.used or p.up != @as(i8, @intCast(i))) return;
    if (!u.sent) {
        var err: i32 = 0;
        var elen: u32 = 4;
        if (sys.sc(.getsockopt, @intCast(u.fd), sys.SOL_SOCKET, 4, @intFromPtr(&err), @intFromPtr(&elen), 0) < 0 or err != 0) return upFailed(p);
        var f: [2 + max_query]u8 = undefined;
        std.mem.writeInt(u16, f[0..2], p.qlen, .big);
        @memcpy(f[2..][0..p.qlen], p.query[0..p.qlen]);
        if (sys.write(u.fd, f[0 .. 2 + p.qlen]) != @as(isize, 2 + p.qlen)) return upFailed(p);
        u.sent = true;
        _ = sys.epoll_mod(util.epfd, u.fd, sys.EPOLLIN, util.tag(util.Tag.dns_up_tcp, i));
        return;
    }
    const got = sys.read(u.fd, u.buf[u.have..]);
    if (got == -sys.E.AGAIN) return;
    if (got <= 0) return upFailed(p);
    u.have += @intCast(got);
    if (u.have < 2) return;
    const len: usize = std.mem.readInt(u16, u.buf[0..2], .big);
    if (len < 12 or len > max_answer) return upFailed(p);
    if (u.have < 2 + len) return;
    const resp = u.buf[2..][0..len];
    if (!dns.matchesReply(resp, p.new_id, &p.question, p.server, 53, p.server)) return upFailed(p);
    const rcode = resp[3] & 0x0f;
    if ((rcode == 2 or rcode == 5) and sendNext(p)) return;
    dns.setId(resp, p.orig_id);
    sendReply(p.reply_fd, true, &p.client, resp);
    release(p);
}

/// The server could not be reached or spoke nonsense: the next one, or SERVFAIL.
fn upFailed(p: *Pending) void {
    if (sendNext(p)) return;
    servfail(p);
    release(p);
}

/// The host's answer to a `dns_query` event, as base64.
pub fn onHostAnswer(id_value: i64, answer: []const u8) void {
    for (&pending) |*p| {
        if (!p.used or !p.asked_host or @as(i64, p.new_id) != id_value) continue;
        var pkt: [4096]u8 = undefined;
        const n = std.base64.standard.Decoder.calcSizeForSlice(answer) catch 0;
        if (n >= 12 and n <= pkt.len and std.meta.isError(std.base64.standard.Decoder.decode(pkt[0..n], answer)) == false and
            dns.matchesReply(pkt[0..n], p.new_id, &p.question, p.server, 53, p.server))
        {
            dns.setId(pkt[0..n], p.orig_id);
            sendReply(p.reply_fd, p.tcp, &p.client, pkt[0..n]);
        } else servfail(p);
        release(p);
        return;
    }
}

pub fn onUpstream() void {
    if (up_fd < 0) return;
    var pkt: [4096]u8 = undefined;
    var iter: usize = 0;
    while (iter < 32) : (iter += 1) {
        var from: sys.SockaddrIn = undefined;
        var flen: u32 = @sizeOf(sys.SockaddrIn);
        const got = sys.recvfrom(up_fd, &pkt, &from, &flen);
        if (got < 0) return;
        if (got < 12 or flen < @sizeOf(sys.SockaddrIn) or from.family != sys.AF_INET) continue;
        const resp = pkt[0..@intCast(got)];
        const id = dns.id(resp);
        for (&pending) |*p| {
            if (!p.used or p.tcp or p.new_id != id) continue;
            if (!dns.matchesReply(resp, p.new_id, &p.question, from.addr, std.mem.bigToNative(u16, from.port), p.server)) continue;
            const rcode = resp[3] & 0x0f;
            // A server that refuses or fails hands over to the next one.
            if ((rcode == 2 or rcode == 5) and sendNext(p)) break;
            dns.setId(resp, p.orig_id);
            sendReply(p.reply_fd, false, &p.client, resp);
            release(p);
            break;
        }
    }
}

/// Poll delay for the earliest pending request or TCP connection deadline.
/// Idle returns -1; an expired deadline returns 0; positive delays round up and cap at 60 seconds.
pub fn nextTimeoutMs() i32 {
    if (active == 0 and open_conns == 0) return -1;
    const now = sys.boottime_ns();
    var soonest: u64 = std.math.maxInt(u64);
    for (&pending) |*p| {
        if (p.used and p.deadline_ns < soonest) soonest = p.deadline_ns;
    }
    for (&conns) |*cn| {
        if (cn.used and cn.deadline_ns < soonest) soonest = cn.deadline_ns;
    }
    if (soonest <= now) return 0;
    return @intCast(@min((soonest - now) / 1_000_000 + 1, 60_000));
}

pub fn onTimer() void {
    if (active == 0 and open_conns == 0) return;
    const now = sys.boottime_ns();
    for (&conns, 0..) |*cn, i| if (cn.used and cn.deadline_ns <= now) closeConn(i);
    for (&pending) |*p| {
        if (!p.used or p.deadline_ns > now) continue;
        if (sendNext(p)) continue;
        servfail(p);
        release(p);
    }
}

/// `fd` is closing: nothing may reply on it, or on whatever gets its number next.
pub fn forget(fd: i32) void {
    if (active == 0) return;
    for (&pending) |*p| {
        if (p.used and p.reply_fd == fd) release(p);
    }
}
