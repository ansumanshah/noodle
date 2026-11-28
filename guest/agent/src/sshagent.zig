//! SSH agent and Docker API forwarding (one relay, two sockets). `ensure` opens a unix socket in the VM on first use; each connection to it forks a child that
//! dials the host over vsock and relays bytes. The container sees this socket bind-mounted at its own path. Nothing
//! exists (no socket, no epoll entry) until a container asks for it.
const std = @import("std");
const sys = @import("sys.zig");
const util = @import("util.zig");
const stream = @import("stream.zig");
const net = @import("net.zig");

pub const socket_path = "/run/noodle/ssh-auth.sock";
pub const docker_socket_path = "/run/noodle/docker.sock";
const host_port = 1030;
const docker_port = 1035;
const max_relays = 64;
/// Relay 0 is the SSH agent, relay 1 the Mac's Docker API. The epoll tag id is the relay index.
const paths = [2][:0]const u8{ socket_path, docker_socket_path };
const ports = [2]u32{ host_port, docker_port };
var listeners: [2]isize = .{ -1, -1 };
/// Slots per relay kind, so Docker API streams cannot starve the SSH agent.
var children: [2][max_relays]i32 = @splat(@splat(0));

const SockaddrUn = extern struct {
    family: u16 = sys.AF_UNIX,
    path: [108]u8 = @splat(0),
};

/// Create the listening socket once. Returns 0 or a negative errno.
pub fn ensure(which: usize) isize {
    if (listeners[which] >= 0) return 0;
    const path = paths[which];
    var rc = util.mkdirp("/run/noodle", 0o755);
    if (rc < 0) return rc;
    _ = sys.unlinkat(sys.AT_FDCWD, path.ptr, 0);
    const s = sys.socket(sys.AF_UNIX, sys.SOCK_STREAM, 0);
    if (s < 0) return s;
    var addr = SockaddrUn{};
    @memcpy(addr.path[0..path.len], path);
    rc = sys.bind(s, &addr, @sizeOf(SockaddrUn));
    if (rc < 0) {
        sys.close(s);
        return rc;
    }
    // Any process in a container that mounts it may use the agent, whatever its uid.
    _ = sys.chmodPath(path.ptr, 0o666);
    rc = sys.listen(s, 64);
    if (rc < 0) {
        sys.close(s);
        return rc;
    }
    sys.setNonblock(s);
    _ = sys.epoll_add(util.epfd, s, sys.EPOLLIN, util.tag(util.Tag.ssh_listen, @intCast(which)));
    listeners[which] = s;
    return 0;
}

/// Accepts per event-loop turn (the level-triggered epoll entry brings the agent back for the rest), so a connection
/// flood cannot keep control requests or child reaping waiting. A full slot table drops the connection.
const accepts_per_turn = 8;

pub fn onAccept(which: usize) void {
    for (0..accepts_per_turn) |_| {
        const c = sys.sc(.accept4, @bitCast(listeners[which]), 0, 0, sys.SOCK_CLOEXEC, 0, 0);
        if (c < 0) return;
        defer sys.close(c);
        const slot = freeSlot(which) orelse continue;
        const pid = sys.fork();
        if (pid == 0) relayChild(c, ports[which]);
        if (pid > 0) children[which][slot] = @intCast(pid);
    }
}

/// The agent's SIGCHLD loop reports every reaped child here.
pub fn onReaped(pid: i32) void {
    for (&children) |*kind| for (kind) |*c| if (c.* == pid) {
        c.* = 0;
        return;
    };
}

fn freeSlot(which: usize) ?usize {
    for (children[which], 0..) |c, i| if (c == 0) return i;
    return null;
}

fn relayChild(accepted: isize, port: u32) noreturn {
    net.dhcpCloseInChild();
    _ = sys.sigprocmask(2, 0);
    if (sys.sigprocmask(0, 1 << (@backingInt(std.os.linux.SIG.PIPE) - 1)) < 0) sys.exit(1);
    // Keep only the accepted connection (as fd 3): an inherited container log, tty or socket would otherwise stay open
    // for as long as this relay lives.
    const c: isize = 3;
    if (accepted != c and sys.dup3(accepted, c, 0) < 0) sys.exit(1);
    if (sys.sc(.close_range, 4, 0xffffffff, 0, 0, 0, 0) < 0) sys.exit(1);
    const v = sys.socket(sys.AF_VSOCK, sys.SOCK_STREAM, 0);
    if (v < 0) sys.exit(1);
    const addr = sys.SockaddrVm{ .port = port, .cid = 2 };
    if (sys.connect(v, &addr, @sizeOf(sys.SockaddrVm)) < 0) sys.exit(1);
    _ = stream.relaySockets(c, v, false);
    sys.exit(0);
}

test "slot table frees on reap and each kind has its own" {
    children = @splat(@splat(0));
    try std.testing.expectEqual(@as(?usize, 0), freeSlot(0));
    children[0][0] = 42;
    try std.testing.expectEqual(@as(?usize, 1), freeSlot(0));
    onReaped(42);
    try std.testing.expectEqual(@as(?usize, 0), freeSlot(0));
    children[0] = @splat(7);
    try std.testing.expectEqual(@as(?usize, null), freeSlot(0));
    try std.testing.expectEqual(@as(?usize, 0), freeSlot(1));
    children = @splat(@splat(0));
}
