//! Negative and positive probes run INSIDE a privileged container (tests/e2e.sh, privileged checks).
//! Static aarch64-linux, no libc. Prints one `name=result` line per probe, where result is `ok` or `errno N`.
//! Build: zig build-exe -target aarch64-linux-none -O ReleaseSmall -fsingle-threaded tests/probe/probe.zig
const std = @import("std");
const linux = std.os.linux;

var out_buf: [256]u8 = undefined;

fn say(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(&out_buf, fmt ++ "\n", args) catch return;
    _ = linux.write(1, s.ptr, s.len);
}

fn err(rc: usize) i32 {
    return @intCast(@intFromEnum(linux.errno(rc)));
}

fn report(name: []const u8, rc: usize) void {
    if (err(rc) == 0) say("{s}=ok", .{name}) else say("{s}=errno {d}", .{ name, err(rc) });
}

const SockaddrVm = extern struct {
    family: u16 = 40,
    reserved: u16 = 0,
    port: u32,
    cid: u32,
    flags: u8 = 0,
    zero: [3]u8 = .{ 0, 0, 0 },
};

fn vsockConnect(name: []const u8, cid: u32, port: u32) void {
    const s = linux.socket(40, 1, 0);
    if (err(s) != 0) return say("{s}=errno {d}", .{ name, err(s) });
    const fd: i32 = @intCast(s);
    defer _ = linux.close(fd);
    const addr = SockaddrVm{ .port = port, .cid = cid };
    report(name, linux.connect(fd, @ptrCast(&addr), @sizeOf(SockaddrVm)));
}

fn makedev(major: u32, minor: u32) u32 {
    return (major << 8) | minor; // fits the old 16-bit encoding, enough for the numbers probed
}

fn mknodOpen(name: []const u8, path: [*:0]const u8, mode: u32, major: u32, minor: u32, flags: u32) void {
    _ = linux.unlinkat(linux.AT.FDCWD, path, 0);
    const rc = linux.mknodat(linux.AT.FDCWD, path, mode, makedev(major, minor));
    if (err(rc) != 0) return say("{s}=mknod errno {d}", .{ name, err(rc) });
    const o = linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = @enumFromInt(flags) }, 0);
    if (err(o) == 0) _ = linux.close(@intCast(o));
    if (err(o) != 0) say("{s}=open errno {d}", .{ name, err(o) }) else say("{s}=ok", .{name});
    _ = linux.unlinkat(linux.AT.FDCWD, path, 0);
}

fn diskNumbers() [2]u32 {
    const fd = linux.openat(linux.AT.FDCWD, "/sys/block/vda/dev", .{}, 0);
    if (err(fd) != 0) return .{ 254, 0 };
    defer _ = linux.close(@intCast(fd));
    var b: [32]u8 = undefined;
    const n = linux.read(@intCast(fd), &b, b.len);
    if (err(n) != 0) return .{ 254, 0 };
    const text = std.mem.trim(u8, b[0..n], " \n");
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return .{ 254, 0 };
    return .{ std.fmt.parseInt(u32, text[0..colon], 10) catch 254, std.fmt.parseInt(u32, text[colon + 1 ..], 10) catch 0 };
}

pub fn main() void {
    // guest control: the agent listens on vsock 1032 (control) and 1033 (stream) for the host only
    vsockConnect("vsock_host_control", 2, 1032);
    vsockConnect("vsock_host_stream", 2, 1033);
    vsockConnect("vsock_local_control", 1, 1032);
    vsockConnect("vsock_self_control", 3, 1032);
    vsockConnect("vsock_self_stream", 3, 1033);
    // host listeners the main VM may dial: the workload VM must get neither the SSH agent nor the Mac loopback relay
    vsockConnect("vsock_host_ssh_agent", 2, 1030);
    vsockConnect("vsock_host_loopback_relay", 2, 1034);
    // file handles would reach any file on the data disk: seccomp answers EPERM before the kernel looks (runs before the device probes below)
    report("open_by_handle_at", linux.syscall3(.open_by_handle_at, @bitCast(@as(isize, -1)), 0, 0));
    // the data disk: no node in /dev, and a new node must not open
    report("dev_vda_open", linux.openat(linux.AT.FDCWD, "/dev/vda", .{}, 0));
    const disk = diskNumbers();
    mknodOpen("disk_mknod_read", "/dev/disk-probe", linux.S.IFBLK | 0o600, disk[0], disk[1], 0);
    mknodOpen("disk_mknod_write", "/dev/disk-probe", linux.S.IFBLK | 0o600, disk[0], disk[1], 2);
    mknodOpen("mem_mknod_read", "/dev/mem-probe", linux.S.IFCHR | 0o600, 1, 1, 0);
    mknodOpen("port_mknod_read", "/dev/port-probe", linux.S.IFCHR | 0o600, 1, 4, 0);
    // allowed nodes still work
    mknodOpen("null_mknod_rw", "/dev/null-probe", linux.S.IFCHR | 0o600, 1, 3, 2);
    mknodOpen("loop_mknod_read", "/dev/loop0-probe", linux.S.IFBLK | 0o600, 7, 0, 0);
    // only the open_by_handle_at filter is installed: io_uring_setup must reach the kernel (EFAULT/EINVAL, not EPERM)
    report("io_uring_setup", linux.syscall2(.io_uring_setup, 1, 0));
}
