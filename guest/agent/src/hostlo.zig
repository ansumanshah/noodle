//! Mac loopback relay (protocol.md "Port 1034"). `host_loopback` opens one TCP listener and asks net.zig to
//! install nftables `redirect` rules that send TCP for the Mac's NAT address here. Each accepted connection whose
//! original destination really was that address forks a child that dials the host over vsock, sends the 8-byte
//! header and relays bytes, like the SSH agent relay. Idle cost: one socket in the epoll set, no timer.
const std = @import("std");
const sys = @import("sys.zig");
const util = @import("util.zig");
const stream = @import("stream.zig");
const net = @import("net.zig");

pub const listen_port: u16 = 61034; // above Linux's ephemeral range, so no client socket is ever given it
const host_port = 1034;
const max_relays = 64;
const SOL_IP = 0;
const SO_ORIGINAL_DST = 80;
var listener: isize = -1;
var children: [max_relays]i32 = @splat(0);

/// Open the listener once and install the redirects the lease allows. Returns 0 or a negative errno.
pub fn enable() isize {
    if (listener < 0) {
        const s = sys.socket(sys.AF_INET, sys.SOCK_STREAM | sys.SOCK_NONBLOCK, 0);
        if (s < 0) return s;
        _ = sys.setsockopt(s, sys.SOL_SOCKET, sys.SO_REUSEADDR, &std.mem.toBytes(@as(i32, 1)));
        const a = sys.SockaddrIn{ .port = std.mem.nativeToBig(u16, listen_port), .addr = .{ 0, 0, 0, 0 } };
        var rc = sys.bind(s, &a, @sizeOf(sys.SockaddrIn));
        if (rc >= 0) rc = sys.listen(s, 64);
        if (rc < 0) {
            sys.close(s);
            return rc;
        }
        _ = sys.epoll_add(util.epfd, s, sys.EPOLLIN, util.tag(util.Tag.hostlo_listen, 0));
        listener = s;
    }
    net.hostlo_port = listen_port;
    net.hostloApply();
    return 0;
}

/// Accepts per event-loop turn, like the resolver's TCP listener. The level-triggered epoll entry brings the agent
/// back for the rest, so a connection flood cannot keep control requests or child reaping waiting.
const accepts_per_turn = 8;

pub fn onAccept() void {
    for (0..accepts_per_turn) |_| {
        const c = sys.sc(.accept4, @bitCast(listener), 0, 0, sys.SOCK_CLOEXEC, 0, 0);
        if (c < 0) return;
        defer sys.close(c);
        if (!net.hostlo_guarded) continue;
        // Only redirected connections: a container that dials this port directly, or dials it on another address
        // (its own bridge gateway, an internal network's gateway), has a different original destination.
        const dst = originalDst(c) orelse continue;
        const gw = net.vm_gateway orelse continue;
        if (!std.mem.eql(u8, &dst.addr, &gw)) continue;
        const slot = freeSlot() orelse continue;
        const pid = sys.fork();
        if (pid == 0) relayChild(c, dst);
        if (pid > 0) children[slot] = @intCast(pid);
    }
}

/// The agent's SIGCHLD loop reports every reaped child here.
pub fn onReaped(pid: i32) void {
    for (&children) |*c| if (c.* == pid) {
        c.* = 0;
        return;
    };
}

fn freeSlot() ?usize {
    for (children, 0..) |c, i| if (c == 0) return i;
    return null;
}

fn originalDst(c: isize) ?sys.SockaddrIn {
    var a = sys.SockaddrIn{ .port = 0, .addr = .{ 0, 0, 0, 0 } };
    var len: u32 = @sizeOf(sys.SockaddrIn);
    if (sys.sc(.getsockopt, @bitCast(c), SOL_IP, SO_ORIGINAL_DST, @intFromPtr(&a), @intFromPtr(&len), 0) < 0) return null;
    if (a.family != sys.AF_INET or a.port == 0) return null;
    return a;
}

/// Version 1, family 4, port and address as the container dialled them (both already in network order).
fn header(dst: sys.SockaddrIn) [8]u8 {
    var h: [8]u8 = .{ 1, 4, 0, 0, 0, 0, 0, 0 };
    @memcpy(h[2..4], std.mem.asBytes(&dst.port));
    @memcpy(h[4..8], &dst.addr);
    return h;
}

fn relayChild(accepted: isize, dst: sys.SockaddrIn) noreturn {
    net.dhcpCloseInChild();
    _ = sys.sigprocmask(2, 0);
    if (sys.sigprocmask(0, 1 << (@backingInt(std.os.linux.SIG.PIPE) - 1)) < 0) sys.exit(1);
    // Keep only the accepted connection (as fd 3), like buildkit.zig: an inherited container log, tty or socket would
    // otherwise stay open, and its disk space allocated, for as long as this relay lives.
    const c: isize = 3;
    if (accepted != c and sys.dup3(accepted, c, 0) < 0) sys.exit(1);
    if (sys.sc(.close_range, 4, 0xffffffff, 0, 0, 0, 0) < 0) sys.exit(1);
    // A removed container's namespace takes its socket away without a FIN reaching this side. Keepalive (about 30 s,
    // kernel timers only while the connection lives) ends the relay instead of holding its slot forever.
    const one = std.mem.toBytes(@as(i32, 1));
    _ = sys.setsockopt(c, sys.SOL_SOCKET, 9, &one); // SO_KEEPALIVE
    _ = sys.setsockopt(c, 6, 4, &std.mem.toBytes(@as(i32, 15))); // IPPROTO_TCP, TCP_KEEPIDLE
    _ = sys.setsockopt(c, 6, 5, &std.mem.toBytes(@as(i32, 5))); // TCP_KEEPINTVL
    _ = sys.setsockopt(c, 6, 6, &std.mem.toBytes(@as(i32, 3))); // TCP_KEEPCNT
    const v = sys.socket(sys.AF_VSOCK, sys.SOCK_STREAM, 0);
    if (v < 0) sys.exit(1);
    const addr = sys.SockaddrVm{ .port = host_port, .cid = 2 };
    if (sys.connect(v, &addr, @sizeOf(sys.SockaddrVm)) < 0) sys.exit(1);
    const h = header(dst);
    var sent: usize = 0;
    while (sent < h.len) {
        const n = sys.write(v, h[sent..]);
        if (n <= 0) sys.exit(1);
        sent += @intCast(n);
    }
    _ = stream.relaySockets(c, v, false);
    sys.exit(0);
}
