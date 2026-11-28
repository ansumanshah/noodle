//! `fs_poke`: make the guest kernel report an attribute change for paths the Mac just changed.
//!
//! virtiofs does not push host-side changes to the guest, so inotify watchers inside containers stay silent
//! when an editor saves on the Mac. The host lists changed paths (relative to /mnt/host) and this chmods each
//! one to the mode the host reports right now. The mode does not change; the kernel still emits IN_ATTRIB.
//! Never follows symlinks and never leaves /mnt/host.
const std = @import("std");
const sys = @import("sys.zig");
const util = @import("util.zig");
const mount_path = @import("mount_path.zig");

pub const max_paths = 256;
const RESOLVE_NO_SYMLINKS = 0x04;
const RESOLVE_BENEATH = 0x08;
const AT_STATX_FORCE_SYNC = 0x2000;
const STATX_TYPE = 0x1;
const STATX_MODE = 0x2;

/// Share key first ("k<24 hex><r|w>"), then optional components. No empty, "." or ".." components, no NUL.
pub fn validRel(rel: []const u8) bool {
    if (rel.len < mount_path.key_len or rel.len > 4000 or std.mem.indexOfScalar(u8, rel, 0) != null) return false;
    if (!mount_path.validKey(rel[0..mount_path.key_len]) or (rel.len > mount_path.key_len and rel[mount_path.key_len] != '/')) return false;
    var parts = std.mem.splitScalar(u8, rel, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

pub const Result = enum { poked, missing, stale };

/// `stale`: the guest still holds a dentry for a name the Mac has since deleted or replaced (atomic save). virtiofs
/// keeps answering from that dentry for about a second, so a container reading the file right after the event
/// would see ENOENT. The caller drops the unused dentries so the next lookup asks the Mac.
pub fn poke(host_dir: isize, rel: []const u8) Result {
    if (!validRel(rel)) return .missing;
    const fd = sys.openat2(host_dir, util.zf("{s}", .{rel}).ptr, sys.O.PATH | sys.O.NOFOLLOW, 0, RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS | sys.RESOLVE_NO_MAGICLINKS);
    if (fd < 0) return .missing;
    defer sys.close(fd);
    var stx: std.os.linux.Statx = undefined;
    var rc = sys.sc(.statx, @bitCast(fd), @intFromPtr(""), sys.AT_EMPTY_PATH | AT_STATX_FORCE_SYNC, STATX_MODE | STATX_TYPE, @intFromPtr(&stx), 0);
    if (rc == -sys.E.NOENT or rc == -116) return .stale; // 116 = ESTALE
    // The root of a share rejects a forced getattr; its mode comes from the cache then.
    if (rc != 0) rc = sys.sc(.statx, @bitCast(fd), @intFromPtr(""), sys.AT_EMPTY_PATH, STATX_MODE | STATX_TYPE, @intFromPtr(&stx), 0);
    if (rc != 0) return .missing;
    // A replaced file still answers getattr through its old node but fails to open: that is the stale case.
    if (stx.mode & sys.S.IFMT == sys.S.IFREG) {
        const probe = sys.openat2(host_dir, util.zf("{s}", .{rel}).ptr, sys.O.RDONLY | sys.O.NOFOLLOW | sys.O.NONBLOCK, 0, RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS | sys.RESOLVE_NO_MAGICLINKS);
        if (probe == -sys.E.NOENT or probe == -116) return .stale;
        sys.close(probe);
    }
    if (sys.chmodFd(fd, stx.mode & 0o7777) >= 0) return .poked;
    // The root of a share refuses every attribute change (chmod, chown, utimens: EPERM), so a watcher on the
    // top folder of a bind mount only hears about files that still exist, not about deletions directly inside it.
    return .missing;
}

var last_drop_ns: u64 = 0;
const drop_interval_ns = 100 * std.time.ns_per_ms;

pub const Outcome = struct { poked: usize = 0, stale: usize = 0 };

/// Poke every path. `stale` counts paths that stayed stale because a cache drop ran too recently; the host retries them.
pub fn pokeAll(paths: []const []const u8) Outcome {
    const dir = sys.open("/mnt/host", sys.O.PATH | sys.O.DIRECTORY, 0);
    if (dir < 0) return .{};
    defer sys.close(dir);
    var n: usize = 0;
    var stale: [max_paths][]const u8 = undefined;
    var stale_n: usize = 0;
    for (paths[0..@min(paths.len, max_paths)]) |p| {
        switch (poke(dir, p)) {
            .poked => n += 1,
            .stale => {
                stale[stale_n] = p;
                stale_n += 1;
            },
            .missing => {},
        }
    }
    if (stale_n == 0) return .{ .poked = n };
    // Rate limited: dropping dentries also cools the caches of unrelated trees. Then poke again so watchers on
    // the replaced file hear about it too.
    const now = sys.boottime_ns();
    if (now -% last_drop_ns > drop_interval_ns) {
        last_drop_ns = now;
        // Twice: the first pass only clears the referenced flag on dentries used recently, which ours just were.
        _ = util.writeSys("/proc/sys/vm/drop_caches", "2");
        _ = util.writeSys("/proc/sys/vm/drop_caches", "2");
    }
    var still: usize = 0;
    for (stale[0..stale_n]) |p| {
        switch (poke(dir, p)) {
            .poked => n += 1,
            .stale => still += 1,
            .missing => {},
        }
    }
    return .{ .poked = n, .stale = still };
}

test "poke paths stay inside a share" {
    const k = "k0123456789abcdef01234567w";
    try std.testing.expect(validRel(k));
    try std.testing.expect(validRel(k ++ "/src/app.js"));
    try std.testing.expect(!validRel(""));
    try std.testing.expect(!validRel("/etc/passwd"));
    try std.testing.expect(!validRel(k ++ "/../x"));
    try std.testing.expect(!validRel(k ++ "//x"));
    try std.testing.expect(!validRel(k ++ "/./x"));
    try std.testing.expect(!validRel(k ++ "x/y"));
    try std.testing.expect(!validRel("other"));
    try std.testing.expect(!validRel("sabc_0/x"));
    try std.testing.expect(!validRel(k ++ "/a\x00b"));
}
