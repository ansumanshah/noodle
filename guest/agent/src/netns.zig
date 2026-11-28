//! One network namespace made ahead of the next container start.
//!
//! Creating a network namespace is the largest single part of `clone3` on the start path. `create`
//! asks for one here; a short-lived helper thread builds it on the other vCPU while the agent
//! finishes `create` and the host turns the request around. `start` then enters that namespace
//! for the length of the `clone3` call, so the container's init is born in it. Every container
//! still gets its own new namespace: one is never reused, and at most one waits.
//!
//! The helper touches only its own stack and the three words below, and makes raw syscalls. It
//! never allocates or formats, so the agent stays single-threaded everywhere else.
const std = @import("std");
const sys = @import("sys.zig");
const util = @import("util.zig");

var home: i32 = -1; // the agent's own network namespace
var ready: i32 = -1; // a prepared namespace, written by the helper as its last act
var helper_tid: i32 = 0; // nonzero while the helper runs; the kernel clears it and wakes the futex at exit
var stack: [16 * 1024]u8 align(16) = undefined;

const CLONE_VM = 0x100;
const CLONE_FS = 0x200;
const CLONE_FILES = 0x400;
const CLONE_SIGHAND = 0x800;
const CLONE_THREAD = 0x10000;
const CLONE_SYSVSEM = 0x40000;
const CLONE_PARENT_SETTID = 0x100000;
const CLONE_CHILD_CLEARTID = 0x200000;

inline fn load(ptr: *i32) i32 {
    return @as(*volatile i32, ptr).*;
}

/// Start building a namespace unless one is ready or on its way. Never blocks; failure only means
/// the next start makes its own with CLONE_NEWNET.
pub fn prepare() void {
    if (load(&helper_tid) != 0) return;
    // The helper stored `ready` before the kernel cleared its tid; the barrier keeps this core from reading them out of order.
    asm volatile ("dmb ish" ::: .{ .memory = true });
    if (load(&ready) >= 0) return;
    if (home < 0) {
        const fd = sys.open("/proc/self/ns/net", sys.O.RDONLY, 0);
        if (fd < 0) return;
        home = @intCast(fd);
    }
    @as(*volatile i32, &helper_tid).* = 1; // PARENT_SETTID replaces it with the real tid before clone returns
    const flags = CLONE_VM | CLONE_FS | CLONE_FILES | CLONE_SIGHAND | CLONE_THREAD | CLONE_SYSVSEM | CLONE_PARENT_SETTID | CLONE_CHILD_CLEARTID;
    const rc: isize = @bitCast(std.os.linux.clone(&build, @intFromPtr(&stack) + stack.len, flags, 0, &helper_tid, 0, &helper_tid));
    if (rc < 0) @as(*volatile i32, &helper_tid).* = 0;
}

/// The prepared namespace, if there is one. Waits for a helper that is still running (it needs
/// well under a millisecond). The caller owns the descriptor.
pub fn take() ?i32 {
    const deadline = sys.boottime_ns() + 200_000_000;
    while (true) {
        const tid = load(&helper_tid);
        if (tid == 0) break;
        if (sys.boottime_ns() >= deadline) return null; // its namespace serves a later start
        const ts = sys.Timespec{ .sec = 0, .nsec = 50_000_000 };
        _ = sys.sc(.futex, @intFromPtr(&helper_tid), 0, @as(usize, @intCast(tid)), @intFromPtr(&ts), 0, 0); // FUTEX_WAIT
    }
    asm volatile ("dmb ish" ::: .{ .memory = true });
    const fd = load(&ready);
    if (fd < 0) return null;
    @as(*volatile i32, &ready).* = -1;
    return fd;
}

/// Move the agent into `fd` so the next clone3 inherits it. Pair with `leave`.
pub fn enter(fd: i32) isize {
    return sys.setns(fd, sys.CLONE.NEWNET);
}

/// Back to the agent's own namespace. The agent cannot keep serving from a container's
/// namespace, so a failure here ends it and the host restarts the VM.
pub fn leave() void {
    const rc = sys.setns(home, sys.CLONE.NEWNET);
    if (rc < 0) {
        util.log("cannot return to the agent network namespace: errno {d}", .{-rc});
        sys.exit(1);
    }
}

const Ifreq = extern struct { name: [16]u8 = @splat(0), flags: i16 = 0, pad: [22]u8 = @splat(0) };

fn sysctl(path: [*:0]const u8, value: []const u8) bool {
    const fd = sys.open(path, sys.O.WRONLY, 0);
    if (fd < 0) return false;
    const n = sys.write(fd, value);
    sys.close(fd);
    return n == @as(isize, @intCast(value.len));
}

/// What a container's init would otherwise do itself in a new namespace: loopback up,
/// unprivileged low ports and ping sockets.
fn configure() bool {
    const s = sys.socket(sys.AF_INET, sys.SOCK_DGRAM, 0);
    if (s < 0) return false;
    defer sys.close(s);
    var req = Ifreq{};
    req.name[0] = 'l';
    req.name[1] = 'o';
    if (sys.ioctl(s, 0x8913, @intFromPtr(&req)) < 0) return false; // SIOCGIFFLAGS
    req.flags |= 1; // IFF_UP
    if (sys.ioctl(s, 0x8914, @intFromPtr(&req)) < 0) return false; // SIOCSIFFLAGS
    return sysctl("/proc/sys/net/ipv4/ip_unprivileged_port_start", "0") and
        sysctl("/proc/sys/net/ipv4/ping_group_range", "0 2147483647");
}

fn build(_: usize) callconv(.c) u8 {
    if (sys.unshare(sys.CLONE.NEWNET) < 0) return 1;
    if (!configure()) return 1;
    const fd = sys.open("/proc/thread-self/ns/net", sys.O.RDONLY, 0);
    if (fd < 0) return 1;
    @as(*volatile i32, &ready).* = @intCast(fd);
    return 0;
}
