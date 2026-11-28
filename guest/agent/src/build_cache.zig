//! The caller holds an exclusive flock on the pinned private BuildKit directory.
//! Only the two cache names below can be moved or removed.
const std = @import("std");
const sys = @import("sys.zig");
const util = @import("util.zig");

const marker = "cache-clean-v2"; // v2: overlayfs snapshotter, v1 caches hold native-snapshotter trees
const detached = "cache-discarded";
const cache = "cache";
const Error = error{CacheRecovery};

pub fn begin(parent: isize) Error!void {
    // An interrupted cleanup can leave the previous retired tree behind.
    if (util.rmTreeChecked(parent, detached) < 0) return error.CacheRecovery;
    const consumed = sys.unlinkat(parent, marker, sys.AT_REMOVEDIR);
    if (consumed == -sys.E.NOENT) {
        const moved = sys.renameat(parent, cache, parent, detached);
        if (moved < 0 and moved != -sys.E.NOENT) return error.CacheRecovery;
        if (moved == 0) {
            if (sys.fsync(parent) < 0 or util.rmTreeChecked(parent, detached) < 0) return error.CacheRecovery;
            util.log("discarded interrupted or unversioned BuildKit cache", .{});
        }
    } else if (consumed < 0) return error.CacheRecovery;
    const created = sys.mkdirat(parent, cache, 0o700);
    if (created < 0 and created != -sys.E.EXIST) return error.CacheRecovery;
    const fd = sys.openat(parent, cache, sys.O.DIRECTORY | sys.O.NOFOLLOW | sys.O.RDONLY, 0);
    if (fd < 0) return error.CacheRecovery;
    sys.close(fd);
    // No worker may mutate a cache until removal of its good marker is durable.
    if (sys.fsync(parent) < 0) return error.CacheRecovery;
}

pub fn commit(parent: isize) Error!void {
    // Snapshotter writes span the tree, including files not explicitly fsynced by BuildKit.
    if (sys.syncfs(parent) < 0) return error.CacheRecovery;
    if (sys.mkdirat(parent, marker, 0o700) < 0 or sys.fsync(parent) < 0) return error.CacheRecovery;
}

test "only completed worker caches survive a subsequent begin" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = sys.openat(tmp.dir.handle, ".", sys.O.RDONLY | sys.O.DIRECTORY, 0);
    try std.testing.expect(dir >= 0);
    defer sys.close(dir);
    try std.testing.expectEqual(@as(isize, 0), sys.mkdirat(dir, "volume", 0o700));
    try begin(dir);
    try std.testing.expectEqual(@as(isize, 0), sys.mkdirat(dir, "cache/check", 0o700));
    try commit(dir);
    try begin(dir);
    var st: sys.Stat = undefined;
    try std.testing.expectEqual(@as(isize, 0), sys.fstatat(dir, "cache/check", &st, 0));
    // Simulate a killed owner after begin, and a malicious link in its incomplete tree.
    try std.testing.expectEqual(@as(isize, 0), sys.symlinkat("../volume", dir, "cache/link"));
    try begin(dir);
    try std.testing.expectEqual(@as(isize, -sys.E.NOENT), sys.fstatat(dir, "cache/check", &st, 0));
    try std.testing.expectEqual(@as(isize, 0), sys.fstatat(dir, "volume", &st, 0));
}
