//! Keeps the embedded resolver off port 53. A container may run its own DNS server on 0.0.0.0:53, and a socket
//! bound to 127.0.0.11:53 would make that bind fail. Instead the resolver listens on 127.0.0.11:redirect_port and
//! three cgroup sock_addr eBPF programs, attached to the container's cgroup, move traffic from 127.0.0.11:53 to
//! it: connect4 (TCP and connected UDP) and sendmsg4 rewrite the destination, recvmsg4 puts :53 back on the source
//! so the client sees the address it asked. Each program compares bpf_get_netns_cookie with the container's own
//! namespace, so a nested network namespace (Docker-in-Docker) in the same cgroup keeps its own 127.0.0.11:53.
//! No packet filter, no per-packet cost, nothing running when idle.
const std = @import("std");
const sys = @import("sys.zig");
const util = @import("util.zig");

/// Above Linux's ephemeral range (no client socket is given it) and clear of mDNS (5353), which containers bind.
pub const redirect_port: u16 = 61053;

pub const Insn = extern struct { code: u8, regs: u8, off: i16, imm: i32 };
const LDX_W: u8 = 0x61;
const ST_W: u8 = 0x62;
const MOV_K: u8 = 0xb7;
const MOV_X: u8 = 0xbf;
const JNE_K: u8 = 0x55;
const JNE_X: u8 = 0x5d;
const LD_IMM64: u8 = 0x18;
const CALL: u8 = 0x85;
const EXIT: u8 = 0x95;
const get_netns_cookie = 122;
pub const prog_len = 13;

fn ins(code: u8, dst: u4, src: u4, off: i16, imm: i32) Insn {
    return .{ .code = code, .regs = @as(u8, dst) | (@as(u8, src) << 4), .off = off, .imm = imm };
}

/// struct bpf_sock_addr: user_ip4 at 4, user_port at 24, both in network order. Little-endian loads see 127.0.0.11
/// as 0x0b00007f and a port with its bytes swapped. Only a socket whose network namespace cookie is `cookie` is rewritten.
fn swap16(p: u16) i32 {
    return @intCast(@byteSwap(p));
}
pub fn build(out: *[prog_len]Insn, from_port: u16, to_port: u16, cookie: u64) void {
    out[0] = ins(MOV_X, 6, 1, 0, 0);
    out[1] = ins(LDX_W, 2, 6, 4, 0);
    out[2] = ins(JNE_K, 2, 0, 8, 0x0b00007f);
    out[3] = ins(LDX_W, 2, 6, 24, 0);
    out[4] = ins(JNE_K, 2, 0, 6, swap16(from_port));
    out[5] = ins(MOV_X, 1, 6, 0, 0);
    out[6] = ins(CALL, 0, 0, 0, get_netns_cookie);
    out[7] = ins(LD_IMM64, 2, 0, 0, @bitCast(@as(u32, @truncate(cookie))));
    out[8] = ins(0, 0, 0, 0, @bitCast(@as(u32, @truncate(cookie >> 32))));
    out[9] = ins(JNE_X, 0, 2, 1, 0);
    out[10] = ins(ST_W, 6, 0, 24, swap16(to_port));
    out[11] = ins(MOV_K, 0, 0, 0, 1);
    out[12] = ins(EXIT, 0, 0, 0, 0);
}

const BPF_PROG_LOAD = 5;
const BPF_PROG_ATTACH = 8;
const BPF_PROG_DETACH = 9;
const BPF_PROG_TYPE_CGROUP_SOCK_ADDR = 18;
const Hook = struct { attach: u32, to_redirect: bool };
const hooks = [_]Hook{
    .{ .attach = 10, .to_redirect = true }, // BPF_CGROUP_INET4_CONNECT
    .{ .attach = 14, .to_redirect = true }, // BPF_CGROUP_UDP4_SENDMSG
    .{ .attach = 19, .to_redirect = false }, // BPF_CGROUP_UDP4_RECVMSG
};

/// 0 not tried, 1 loaded once, 2 unavailable in this kernel.
var state: u8 = 0;

fn put32(attr: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, attr[off..][0..4], v, .little);
}
fn put64(attr: []u8, off: usize, v: u64) void {
    std.mem.writeInt(u64, attr[off..][0..8], v, .little);
}

/// Loads one program for `h`, bound to the namespace `cookie`. The cgroup keeps it alive once attached.
fn load(h: Hook, cookie: u64) isize {
    const license = "GPL\x00";
    var code: [prog_len]Insn = undefined;
    if (h.to_redirect) build(&code, 53, redirect_port, cookie) else build(&code, redirect_port, 53, cookie);
    var attr: [128]u8 align(8) = @splat(0);
    put32(&attr, 0, BPF_PROG_TYPE_CGROUP_SOCK_ADDR);
    put32(&attr, 4, code.len);
    put64(&attr, 8, @intFromPtr(&code));
    put64(&attr, 16, @intFromPtr(license));
    put32(&attr, 68, h.attach); // expected_attach_type
    return sys.sc(.bpf, BPF_PROG_LOAD, @intFromPtr(&attr), attr.len, 0, 0, 0);
}

fn cgroupOp(op: usize, dir: isize, fd: isize, attach_type: u32) isize {
    var at: [128]u8 align(8) = @splat(0);
    put32(&at, 0, @intCast(dir));
    put32(&at, 4, @intCast(fd));
    put32(&at, 8, attach_type);
    return sys.sc(.bpf, op, @intFromPtr(&at), at.len, 0, 0, 0);
}

/// Attaches the three programs to `cgroup` for the namespace `cookie` (SO_NETNS_COOKIE). False means the resolver has
/// to bind port 53 itself, with nothing left attached.
pub fn attach(cgroup: [*:0]const u8, cookie: u64) bool {
    if (state == 2) return false;
    const dir = sys.open(cgroup, sys.O.RDONLY | sys.O.DIRECTORY | sys.O.CLOEXEC, 0);
    if (dir < 0) return false;
    defer sys.close(dir);
    for (hooks, 0..) |h, i| {
        const fd = load(h, cookie);
        if (fd < 0) {
            util.log("embedded dns redirect: bpf load failed errno {d}, resolver stays on port 53", .{-fd});
            if (state == 0) state = 2;
            detach(dir, i);
            return false;
        }
        state = 1;
        defer sys.close(fd);
        const rc = cgroupOp(BPF_PROG_ATTACH, dir, fd, h.attach);
        if (rc < 0) {
            util.log("embedded dns redirect: attach failed errno {d}", .{-rc});
            detach(dir, i);
            return false;
        }
    }
    return true;
}

/// Undo the first `n` attachments, so a half-attached set never redirects while the resolver sits on port 53.
fn detach(dir: isize, n: usize) void {
    for (hooks[0..n]) |h| _ = cgroupOp(BPF_PROG_DETACH, dir, 0, h.attach);
}

/// The same instruction semantics as the kernel's, for the unit test. `actual` is the cookie of the socket's namespace.
fn run(code: []const Insn, ip: u32, port_wire: u32, actual: u64) struct { ret: u64, port: u32 } {
    var port = port_wire;
    var r0: u64 = 0;
    var r2: u64 = 0;
    var pc: usize = 0;
    while (true) {
        const x = code[pc];
        switch (x.code) {
            LDX_W => {
                r2 = if (x.off == 4) ip else port;
                pc += 1;
            },
            JNE_K => pc += 1 + (if (r2 != @as(u64, @intCast(x.imm))) @as(usize, @intCast(x.off)) else 0),
            JNE_X => pc += 1 + (if (r0 != r2) @as(usize, @intCast(x.off)) else 0),
            CALL => {
                std.debug.assert(x.imm == get_netns_cookie);
                r0 = actual;
                pc += 1;
            },
            LD_IMM64 => {
                r2 = @as(u64, @as(u32, @bitCast(x.imm))) | (@as(u64, @as(u32, @bitCast(code[pc + 1].imm))) << 32);
                pc += 2;
            },
            ST_W => {
                port = @intCast(x.imm);
                pc += 1;
            },
            MOV_X => pc += 1,
            MOV_K => {
                r0 = @intCast(x.imm);
                pc += 1;
            },
            EXIT => return .{ .ret = r0, .port = port },
            else => unreachable,
        }
    }
}

test "only 127.0.0.11 port 53 in the container's namespace is moved, and moved back" {
    const w = struct {
        fn f(p: u16) u32 {
            return @intCast(swap16(p));
        }
    }.f;
    const cookie: u64 = 0x1234_5678_9abc_def0;
    var fwd: [prog_len]Insn = undefined;
    var back: [prog_len]Insn = undefined;
    build(&fwd, 53, redirect_port, cookie);
    build(&back, redirect_port, 53, cookie);
    const ip: u32 = 0x0b00007f;
    try std.testing.expectEqual(w(redirect_port), run(&fwd, ip, w(53), cookie).port);
    try std.testing.expectEqual(w(53), run(&back, ip, w(redirect_port), cookie).port);
    try std.testing.expectEqual(w(80), run(&fwd, ip, w(80), cookie).port);
    try std.testing.expectEqual(w(53), run(&fwd, 0x0100007f, w(53), cookie).port); // 127.0.0.1 is untouched
    try std.testing.expectEqual(w(redirect_port), run(&back, 0x0100007f, w(redirect_port), cookie).port);
    // A nested network namespace in the same cgroup keeps its own 127.0.0.11:53, and the call still succeeds.
    try std.testing.expectEqual(w(53), run(&fwd, ip, w(53), cookie + 1).port);
    try std.testing.expectEqual(@as(u64, 1), run(&fwd, ip, w(53), cookie + 1).ret);
    try std.testing.expectEqual(w(redirect_port), run(&back, ip, w(redirect_port), cookie + (1 << 32)).port);
}

test "redirect port is outside the ephemeral range and mDNS" {
    try std.testing.expect(redirect_port > 60999 and redirect_port != 61034);
}
