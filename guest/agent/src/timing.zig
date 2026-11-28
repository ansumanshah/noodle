//! Stage timing for the container start path. Compiled only with `zig build -Dstart-timing`;
//! the shipped agent has `on == false` and every call folds away.
const std = @import("std");
const sys = @import("sys.zig");
const util = @import("util.zig");

pub const on = @import("build_options").start_timing;

pub const Stage = enum(u8) {
    // agent side of `start`
    enter,
    spec,
    cgroup_ready,
    pipes,
    cloned,
    cgroup_moved,
    released,
    exec_seen,
    // container init, between clone3 and execve
    c_first,
    c_go,
    c_net,
    c_cgroupns,
    c_private,
    c_proc_sys,
    c_dev,
    c_etc,
    c_user_mounts,
    c_masked,
    c_pivot,
    c_stdio,
    c_user,
    c_limits,
    c_seccomp,
    c_caps,
};
const count = @intFromEnum(Stage.c_caps) + 1;
const first_child = @intFromEnum(Stage.c_first);

var stamps: [count]u64 = @splat(0);
var pipe_fds: [2]i32 = .{ -1, -1 };

pub inline fn mark(comptime stage: Stage) void {
    if (!on) return;
    stamps[@intFromEnum(stage)] = sys.clock_ns(1); // CLOCK_MONOTONIC: one clock for every namespace
}

/// Agent, before clone3: the pipe the container init reports its stamps on. Close-on-exec.
pub fn open() void {
    if (!on) return;
    stamps = @splat(0);
    if (sys.pipe2(&pipe_fds, 0) < 0) pipe_fds = .{ -1, -1 };
}

/// Container init, last thing before execve.
pub fn childFlush() void {
    if (!on or pipe_fds[1] < 0) return;
    _ = sys.write(pipe_fds[1], std.mem.sliceAsBytes(stamps[first_child..]));
}

/// Agent, after exec was seen (or startup failed): collect the child stamps and log one line.
pub fn report() void {
    if (!on) return;
    sys.close(pipe_fds[1]);
    if (pipe_fds[0] >= 0) {
        _ = sys.readAll(pipe_fds[0], std.mem.sliceAsBytes(stamps[first_child..]));
        sys.close(pipe_fds[0]);
    }
    pipe_fds = .{ -1, -1 };
    var buf: [460]u8 = undefined;
    var w: usize = 0;
    const base = stamps[0];
    inline for (0..count) |i| {
        const us = if (stamps[i] >= base) (stamps[i] - base) / 1000 else 0;
        const s = std.fmt.bufPrint(buf[w..], " " ++ @tagName(@as(Stage, @enumFromInt(i))) ++ "={d}", .{us}) catch "";
        w += s.len;
    }
    util.log("start-timing{s}", .{buf[0..w]});
}
