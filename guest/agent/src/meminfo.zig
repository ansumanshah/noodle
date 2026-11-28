//! /proc/meminfo and /proc/vmstat parsing for the `balloon_hint` and `vm_usage` replies. Pure text in, bytes out, so it runs natively under `zig build test`.
const std = @import("std");

fn fieldBytes(line: []const u8, name: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, line, name)) return null;
    var it = std.mem.tokenizeScalar(u8, line[name.len..], ' ');
    const v = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
    return v *| 1024;
}

/// File page cache the kernel can drop: Cached + Buffers, minus Shmem (tmpfs pages are not droppable).
pub fn fileCache(text: []const u8) u64 {
    var cached: u64 = 0;
    var buffers: u64 = 0;
    var shmem: u64 = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        if (fieldBytes(l, "Cached:")) |v| cached = v;
        if (fieldBytes(l, "Buffers:")) |v| buffers = v;
        if (fieldBytes(l, "Shmem:")) |v| shmem = v;
    }
    return (cached +| buffers) -| shmem;
}

/// Memory the guest is using: MemTotal - MemAvailable minus the balloon's pages. With `DEFLATE_ON_OOM` the balloon
/// does not shrink MemTotal, so its pages would otherwise count as used. Null when either field is missing.
pub fn guestUsed(text: []const u8, balloon_bytes: u64) ?u64 {
    var total: ?u64 = null;
    var avail: ?u64 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        if (fieldBytes(l, "MemTotal:")) |v| total = v;
        if (fieldBytes(l, "MemAvailable:")) |v| avail = v;
    }
    return ((total orelse return null) -| (avail orelse return null)) -| balloon_bytes;
}

/// A `name value` counter from /proc/vmstat.
pub fn vmstat(text: []const u8, name: []const u8) ?u64 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        var it = std.mem.tokenizeScalar(u8, l, ' ');
        if (!std.mem.eql(u8, it.next() orelse continue, name)) continue;
        return std.fmt.parseInt(u64, it.next() orelse return null, 10) catch null;
    }
    return null;
}

/// The fields are disjoint: Shmem is not part of AnonPages. Require all of
/// them so an incomplete procfs read never looks like a valid low estimate.
pub fn memoryUsed(text: []const u8) ?u64 {
    const names = [_][]const u8{ "AnonPages:", "Shmem:", "SUnreclaim:", "KernelStack:", "PageTables:" };
    var values: [names.len]?u64 = @splat(null);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        for (names, 0..) |name, i| {
            if (!std.mem.startsWith(u8, line, name)) continue;
            if (values[i] != null) return null;
            var tokens = std.mem.tokenizeAny(u8, line[name.len..], " \t\r");
            const kb = std.fmt.parseInt(u64, tokens.next() orelse return null, 10) catch return null;
            if (!std.mem.eql(u8, tokens.next() orelse return null, "kB") or tokens.next() != null) return null;
            values[i] = std.math.mul(u64, kb, 1024) catch return null;
        }
    }
    var total: u64 = 0;
    for (values) |value| total = std.math.add(u64, total, value orelse return null) catch return null;
    return total;
}

pub const CpuUsage = struct { busy: u64, total: u64 };

/// Linux includes guest time in user/nice, so only the first eight counters
/// contribute. Idle and iowait are total time but not busy time.
pub fn cpuUsage(text: []const u8) ?CpuUsage {
    const line = std.mem.sliceTo(text, '\n');
    var tokens = std.mem.tokenizeAny(u8, line, " \t\r");
    if (!std.mem.eql(u8, tokens.next() orelse return null, "cpu")) return null;
    var total: u64 = 0;
    var busy: u64 = 0;
    var count: usize = 0;
    while (tokens.next()) |token| : (count += 1) {
        const value = std.fmt.parseInt(u64, token, 10) catch return null;
        if (count >= 8) continue;
        total = std.math.add(u64, total, value) catch return null;
        if (count != 3 and count != 4) busy = std.math.add(u64, busy, value) catch return null;
    }
    if (count < 4) return null;
    return .{ .busy = busy, .total = total };
}

test "vm memory requires all fields and excludes cache" {
    const text = "Cached: 900 kB\nAnonPages: 10 kB\nShmem: 20 kB\nSUnreclaim: 3 kB\nKernelStack: 4 kB\nPageTables: 5 kB\n";
    try std.testing.expectEqual(@as(?u64, 42 * 1024), memoryUsed(text));
    try std.testing.expectEqual(@as(?u64, null), memoryUsed("AnonPages: 1 kB\n"));
    try std.testing.expectEqual(@as(?u64, null), memoryUsed("AnonPages: 1 MB\nShmem: 2 kB\nSUnreclaim: 3 kB\nKernelStack: 4 kB\nPageTables: 5 kB\n"));
}

test "aggregate cpu excludes idle iowait and guest counters" {
    const usage = cpuUsage("cpu  10 20 30 40 50 60 70 80 9 8\ncpu0 1 2 3 4\n").?;
    try std.testing.expectEqual(@as(u64, 270), usage.busy);
    try std.testing.expectEqual(@as(u64, 360), usage.total);
    try std.testing.expect(cpuUsage("cpu0 1 2 3 4\n") == null);
    try std.testing.expect(cpuUsage("cpu 1 2 3\n") == null);
    try std.testing.expect(cpuUsage("cpu 1 2 nope 4\n") == null);
}

test "file cache is Cached plus Buffers minus Shmem" {
    const t = "MemTotal:        2000 kB\nMemFree:  1000 kB\nBuffers:  10 kB\nCached:  500 kB\nSwapCached:  7 kB\nShmem: 20 kB\n";
    try std.testing.expectEqual(@as(u64, 490 * 1024), fileCache(t));
}

test "file cache saturates and tolerates junk" {
    try std.testing.expectEqual(@as(u64, 0), fileCache("Shmem: 500 kB\nCached: 1 kB\n"));
    try std.testing.expectEqual(@as(u64, 0), fileCache(""));
    try std.testing.expectEqual(@as(u64, 0), fileCache("Cached: abc kB\n"));
}

test "guest used is total minus available minus balloon" {
    const t = "MemTotal: 2000 kB\nMemFree: 100 kB\nMemAvailable: 1500 kB\n";
    try std.testing.expectEqual(@as(?u64, 500 * 1024), guestUsed(t, 0));
    try std.testing.expectEqual(@as(?u64, 100 * 1024), guestUsed(t, 400 * 1024));
    try std.testing.expectEqual(@as(?u64, 0), guestUsed(t, 1 << 40));
    try std.testing.expectEqual(@as(?u64, null), guestUsed("MemTotal: 2000 kB\n", 0));
}

test "vmstat reads one counter by exact name" {
    const t = "nr_free_pages 10\nnr_balloon_pages 256\nballoon_inflate 3\n";
    try std.testing.expectEqual(@as(?u64, 256), vmstat(t, "nr_balloon_pages"));
    try std.testing.expectEqual(@as(?u64, null), vmstat(t, "nr_balloon"));
    try std.testing.expectEqual(@as(?u64, null), vmstat("nr_balloon_pages x\n", "nr_balloon_pages"));
}
