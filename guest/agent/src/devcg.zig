//! Device policy for the workload VM.
//! A cgroup-device eBPF program, attached once to the parent cgroup of every container, that allows a short
//! list of device nodes and denies the rest: the data disk, the console, vsock, mem/kmem/port.
//! Attached with BPF_F_ALLOW_MULTI above the containers: nested runtimes may add filters below it (all must allow), but cannot
//! replace or detach this one. Without the flag, runc in a nested k3s fails to start any pod (attach: operation not permitted).
const std = @import("std");
const sys = @import("sys.zig");
const util = @import("util.zig");

pub const Insn = extern struct { code: u8, regs: u8, off: i16, imm: i32 };

const LDX_W: u8 = 0x61;
const MOV_X: u8 = 0xbf;
const MOV_K: u8 = 0xb7;
const AND_K: u8 = 0x57;
const RSH_K: u8 = 0x77;
const JNE_K: u8 = 0x55;
const EXIT: u8 = 0x95;

const BLOCK = 1;
const CHAR = 2;
const MKNOD = 1;
const READ = 2;
const WRITE = 4;
const ALL = MKNOD | READ | WRITE;
const any = -1;

const Rule = struct { typ: i32, major: i32, minor: i32, access: i32 };
pub const rules = [_]Rule{
    .{ .typ = CHAR, .major = 1, .minor = 3, .access = ALL }, // null
    .{ .typ = CHAR, .major = 1, .minor = 5, .access = ALL }, // zero
    .{ .typ = CHAR, .major = 1, .minor = 7, .access = ALL }, // full
    .{ .typ = CHAR, .major = 1, .minor = 8, .access = ALL }, // random
    .{ .typ = CHAR, .major = 1, .minor = 9, .access = ALL }, // urandom
    .{ .typ = CHAR, .major = 1, .minor = 11, .access = MKNOD | READ }, // kmsg: read only, no log spam into the host file
    .{ .typ = CHAR, .major = 5, .minor = 0, .access = ALL }, // tty
    .{ .typ = CHAR, .major = 5, .minor = 2, .access = ALL }, // ptmx
    .{ .typ = CHAR, .major = 136, .minor = any, .access = ALL }, // pty slaves
    .{ .typ = CHAR, .major = 10, .minor = 229, .access = ALL }, // fuse
    .{ .typ = CHAR, .major = 10, .minor = 200, .access = ALL }, // tun
    .{ .typ = CHAR, .major = 10, .minor = 237, .access = ALL }, // loop-control
    .{ .typ = BLOCK, .major = 7, .minor = any, .access = ALL }, // loop devices (never the virtio disk, major 254)
};

pub const max_insns = 6 + rules.len * 8 + 2;

fn ins(code: u8, dst: u4, src: u4, off: i16, imm: i32) Insn {
    return .{ .code = code, .regs = @as(u8, dst) | (@as(u8, src) << 4), .off = off, .imm = imm };
}

/// struct bpf_cgroup_dev_ctx { u32 access_type /* (access << 16) | type */; u32 major; u32 minor; }
pub fn build(out: []Insn) usize {
    var n: usize = 0;
    out[n] = ins(LDX_W, 2, 1, 0, 0);
    n += 1;
    out[n] = ins(LDX_W, 3, 1, 4, 0);
    n += 1;
    out[n] = ins(LDX_W, 4, 1, 8, 0);
    n += 1;
    out[n] = ins(MOV_X, 5, 2, 0, 0);
    n += 1;
    out[n] = ins(AND_K, 5, 0, 0, 0xffff);
    n += 1;
    out[n] = ins(RSH_K, 2, 0, 0, 16);
    n += 1;
    for (rules) |rl| {
        const start = n;
        const len: usize = if (rl.minor >= 0) 8 else 7;
        out[n] = ins(JNE_K, 5, 0, @intCast(start + len - n - 1), rl.typ);
        n += 1;
        out[n] = ins(JNE_K, 3, 0, @intCast(start + len - n - 1), rl.major);
        n += 1;
        if (rl.minor >= 0) {
            out[n] = ins(JNE_K, 4, 0, @intCast(start + len - n - 1), rl.minor);
            n += 1;
        }
        out[n] = ins(MOV_X, 6, 2, 0, 0);
        n += 1;
        out[n] = ins(AND_K, 6, 0, 0, ~@as(i32, rl.access));
        n += 1;
        out[n] = ins(JNE_K, 6, 0, @intCast(start + len - n - 1), 0);
        n += 1;
        out[n] = ins(MOV_K, 0, 0, 0, 1);
        n += 1;
        out[n] = ins(EXIT, 0, 0, 0, 0);
        n += 1;
    }
    out[n] = ins(MOV_K, 0, 0, 0, 0);
    n += 1;
    out[n] = ins(EXIT, 0, 0, 0, 0);
    n += 1;
    return n;
}

/// True once the policy is attached. Privileged containers are refused until then.
pub var active = false;

var prog: [max_insns]Insn = undefined;
var verifier_log: [4096]u8 = undefined;

const BPF_PROG_LOAD = 5;
const BPF_PROG_ATTACH = 8;
const BPF_PROG_TYPE_CGROUP_DEVICE = 15;
const BPF_CGROUP_DEVICE = 6;
/// Lets a container runtime inside a workload (k3s, kind: runc) stack its own device filter below ours. Every program on the
/// path must allow an access, so a nested filter can only narrow the policy; none can detach or replace this one.
const BPF_F_ALLOW_MULTI: u32 = 1 << 1;

fn put32(attr: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, attr[off..][0..4], v, .little);
}
fn put64(attr: []u8, off: usize, v: u64) void {
    std.mem.writeInt(u64, attr[off..][0..8], v, .little);
}

/// Load the program and attach it to `cgroup` (a directory in the cgroup2 mount). Logs the verifier output on failure.
pub fn attach(cgroup: [*:0]const u8) bool {
    const n = build(&prog);
    const license = "GPL\x00";
    // First without a log: a log that does not fit makes a valid load fail with ENOSPC. Retry with one only to explain a failure.
    var fd: isize = -1;
    for ([_]u32{ 0, 1 }) |level| {
        var attr: [128]u8 align(8) = @splat(0);
        put32(&attr, 0, BPF_PROG_TYPE_CGROUP_DEVICE);
        put32(&attr, 4, @intCast(n));
        put64(&attr, 8, @intFromPtr(&prog));
        put64(&attr, 16, @intFromPtr(license));
        if (level > 0) {
            put32(&attr, 24, level);
            put32(&attr, 28, verifier_log.len);
            put64(&attr, 32, @intFromPtr(&verifier_log));
        }
        fd = sys.sc(.bpf, BPF_PROG_LOAD, @intFromPtr(&attr), attr.len, 0, 0, 0);
        if (fd >= 0) break;
    }
    if (fd < 0) {
        const text = std.mem.sliceTo(&verifier_log, 0);
        util.log("device policy: bpf load failed errno {d}: {s}", .{ -fd, text[0..@min(text.len, 300)] });
        return false;
    }
    defer sys.close(fd);
    const dir = sys.open(cgroup, sys.O.RDONLY | sys.O.DIRECTORY | sys.O.CLOEXEC, 0);
    if (dir < 0) {
        util.log("device policy: open cgroup failed errno {d}", .{-dir});
        return false;
    }
    defer sys.close(dir);
    var at: [128]u8 align(8) = @splat(0);
    put32(&at, 0, @intCast(dir));
    put32(&at, 4, @intCast(fd));
    put32(&at, 8, BPF_CGROUP_DEVICE);
    put32(&at, 12, BPF_F_ALLOW_MULTI);
    const rc = sys.sc(.bpf, BPF_PROG_ATTACH, @intFromPtr(&at), at.len, 0, 0, 0);
    if (rc < 0) {
        util.log("device policy: bpf attach failed errno {d}", .{-rc});
        return false;
    }
    active = true;
    util.log("device policy: attached ({d} instructions)", .{n});
    return true;
}

/// Tiny interpreter used by the unit test.
fn run(code: []const Insn, access: u32, typ: u32, major: u32, minor: u32) u64 {
    var r: [11]u64 = @splat(0);
    var pc: usize = 0;
    while (pc < code.len) {
        const x = code[pc];
        const dst: usize = x.regs & 0xf;
        const src: usize = x.regs >> 4;
        switch (x.code) {
            LDX_W => {
                r[dst] = switch (x.off) {
                    0 => (access << 16) | typ,
                    4 => major,
                    8 => minor,
                    else => unreachable,
                };
                pc += 1;
            },
            MOV_X => {
                r[dst] = r[src];
                pc += 1;
            },
            MOV_K => {
                r[dst] = @bitCast(@as(i64, x.imm));
                pc += 1;
            },
            AND_K => {
                r[dst] &= @bitCast(@as(i64, x.imm));
                pc += 1;
            },
            RSH_K => {
                r[dst] >>= @intCast(x.imm);
                pc += 1;
            },
            JNE_K => pc += 1 + (if (r[dst] != @as(u64, @bitCast(@as(i64, x.imm)))) @as(usize, @intCast(x.off)) else 0),
            EXIT => return r[0],
            else => unreachable,
        }
    }
    unreachable;
}

test "device policy allows the short list and denies the disk" {
    var buf: [max_insns]Insn = undefined;
    const n = build(&buf);
    const code = buf[0..n];
    const rw = READ | WRITE;
    try std.testing.expectEqual(@as(u64, 1), run(code, rw, CHAR, 1, 3)); // /dev/null
    try std.testing.expectEqual(@as(u64, 1), run(code, MKNOD, CHAR, 1, 9));
    try std.testing.expectEqual(@as(u64, 1), run(code, rw, CHAR, 136, 77)); // a pty slave
    try std.testing.expectEqual(@as(u64, 1), run(code, ALL, BLOCK, 7, 12)); // loop12
    try std.testing.expectEqual(@as(u64, 1), run(code, READ, CHAR, 1, 11)); // kmsg read
    try std.testing.expectEqual(@as(u64, 0), run(code, WRITE, CHAR, 1, 11)); // kmsg write
    try std.testing.expectEqual(@as(u64, 0), run(code, READ, BLOCK, 254, 0)); // virtio disk
    try std.testing.expectEqual(@as(u64, 0), run(code, MKNOD, BLOCK, 254, 0));
    try std.testing.expectEqual(@as(u64, 0), run(code, rw, BLOCK, 259, 0)); // blkext
    try std.testing.expectEqual(@as(u64, 0), run(code, rw, CHAR, 1, 1)); // /dev/mem
    try std.testing.expectEqual(@as(u64, 0), run(code, rw, CHAR, 1, 4)); // /dev/port
    try std.testing.expectEqual(@as(u64, 0), run(code, rw, CHAR, 10, 122)); // some other misc device
    try std.testing.expectEqual(@as(u64, 0), run(code, rw, CHAR, 7, 3)); // char with a loop major is not loop
    try std.testing.expectEqual(@as(u64, 0), run(code, rw, BLOCK, 1, 3)); // block with null's numbers is not null
}
