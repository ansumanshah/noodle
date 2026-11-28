//! Populate an empty named volume from the image before installing runtime mounts.
const std = @import("std");
const sys = @import("sys.zig");
const util = @import("util.zig");

const dir_flags = sys.O.RDONLY | sys.O.DIRECTORY | sys.O.NOFOLLOW;
const no_xdev = 0x01;
pub var last_errno: isize = 0;

fn check(rc: isize) !isize {
    if (rc >= 0) return rc;
    last_errno = -rc;
    return error.Syscall;
}

const Entries = struct {
    buf: [1024]u8 align(8) = undefined,
    off: usize = 0,
    len: usize = 0,

    fn next(self: *Entries, fd: isize) !?[:0]const u8 {
        while (true) {
            if (self.off == self.len) {
                const n = try check(sys.getdents64(fd, &self.buf));
                if (n == 0) return null;
                self.len = @intCast(n);
                self.off = 0;
            }
            const start = self.off;
            self.off += std.mem.readInt(u16, self.buf[start + 16 ..][0..2], .little);
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&self.buf[start + 19])));
            if (util.validChildName(name)) return name;
        }
    }
};

fn procFd(buf: *[64]u8, fd: isize) [:0]const u8 {
    return std.fmt.bufPrintSentinel(buf, "/proc/self/fd/{d}", .{fd}, 0) catch unreachable;
}

const Copy = struct {
    root: isize,
    alloc: std.mem.Allocator,
    links: std.AutoHashMapUnmanaged([2]u64, [:0]const u8) = .empty,
    path: [4096]u8 = undefined,
    names: [65536]u8 = undefined,
    data: [65536]u8 = undefined,

    fn metadata(self: *Copy, src_parent: isize, dst_parent: isize, name: [:0]const u8, dst: isize, st: sys.Stat) !void {
        const flags = sys.AT_EMPTY_PATH | sys.AT_SYMLINK_NOFOLLOW;
        _ = try check(sys.fchownat(dst, "", st.uid, st.gid, flags));
        if (st.mode & sys.S.IFMT != sys.S.IFLNK) _ = try check(sys.chmodFd(dst, st.mode & 0o7777));
        // l*xattr resolves the pinned parent but never follows the image-controlled final component.
        var sb: [320]u8 = undefined;
        var db: [320]u8 = undefined;
        const from = try std.fmt.bufPrintSentinel(&sb, "/proc/self/fd/{d}/{s}", .{ src_parent, name }, 0);
        const to = try std.fmt.bufPrintSentinel(&db, "/proc/self/fd/{d}/{s}", .{ dst_parent, name }, 0);
        const count = sys.llistxattr(from.ptr, &self.names);
        if (count != -sys.E.OPNOTSUPP) {
            const len: usize = @intCast(try check(count));
            var i: usize = 0;
            while (i < len) {
                const attr = std.mem.span(@as([*:0]const u8, @ptrCast(&self.names[i])));
                i += attr.len + 1;
                const n = try check(sys.lgetxattr(from.ptr, attr.ptr, &self.data));
                _ = try check(sys.lsetxattr(to.ptr, attr.ptr, self.data[0..@intCast(n)]));
            }
        }
        const times = [2]sys.Timespec{
            .{ .sec = st.atime, .nsec = st.atime_nsec },
            .{ .sec = st.mtime, .nsec = st.mtime_nsec },
        };
        _ = try check(sys.utimensat(dst, "", &times, flags));
    }

    fn directory(self: *Copy, src: isize, dst: isize, prefix: usize, depth: u32) anyerror!void {
        if (depth > 100) return error.DirectoryTooDeep;
        var entries = Entries{};
        while (try entries.next(src)) |name| {
            const end = prefix + name.len;
            if (end + 1 >= self.path.len) return error.NameTooLong;
            @memcpy(self.path[prefix..end], name);
            const fd = try check(sys.openat2(src, name.ptr, sys.O.PATH | sys.O.NOFOLLOW, 0, no_xdev));
            defer sys.close(fd);
            var st: sys.Stat = undefined;
            _ = try check(sys.fstat(fd, &st));
            const kind = st.mode & sys.S.IFMT;
            if (kind != sys.S.IFDIR and st.nlink > 1) {
                const entry = try self.links.getOrPut(self.alloc, .{ st.dev, st.ino });
                if (entry.found_existing) {
                    _ = try check(sys.linkat(self.root, entry.value_ptr.*.ptr, dst, name.ptr, 0));
                    continue;
                }
                entry.value_ptr.* = try util.dupeZ(self.alloc, self.path[0..end]);
            }
            switch (kind) {
                sys.S.IFDIR => {
                    _ = try check(sys.mkdirat(dst, name.ptr, 0o700));
                    const child = try check(sys.openat(dst, name.ptr, dir_flags, 0));
                    defer sys.close(child);
                    const from = try check(sys.openat(fd, ".", dir_flags, 0));
                    defer sys.close(from);
                    self.path[end] = '/';
                    try self.directory(from, child, end + 1, depth + 1);
                    try self.metadata(src, dst, name, child, st);
                },
                sys.S.IFREG => {
                    var pb: [64]u8 = undefined;
                    const from = try check(sys.open(procFd(&pb, fd).ptr, sys.O.RDONLY, 0));
                    defer sys.close(from);
                    const to = try check(sys.openat(dst, name.ptr, sys.O.WRONLY | sys.O.CREAT | sys.O.EXCL, 0o600));
                    defer sys.close(to);
                    while (true) {
                        const n = try check(sys.read(from, &self.data));
                        if (n == 0) break;
                        _ = try check(sys.writeAll(to, self.data[0..@intCast(n)]));
                    }
                    try self.metadata(src, dst, name, to, st);
                },
                sys.S.IFLNK, sys.S.IFIFO => {
                    if (kind == sys.S.IFLNK) {
                        const n: usize = @intCast(try check(sys.readlinkat(fd, "", &self.data)));
                        if (n == self.data.len) return error.NameTooLong;
                        self.data[n] = 0;
                        _ = try check(sys.symlinkat(@ptrCast(&self.data), dst, name.ptr));
                    } else _ = try check(sys.mknodat(dst, name.ptr, sys.S.IFIFO | 0o600, 0));
                    const to = try check(sys.openat(dst, name.ptr, sys.O.PATH | sys.O.NOFOLLOW, 0));
                    defer sys.close(to);
                    try self.metadata(src, dst, name, to, st);
                },
                else => return error.UnsupportedEntry,
            }
        }
    }
};

// PID 1 serializes starts. The caller excludes volumes already mounted by another container.
pub fn prepare(root: isize, volumes: isize, work: isize, name: [:0]const u8, target: [:0]const u8, skip_copy: bool) !void {
    last_errno = 0;
    if (!util.validVolumeName(name) or !@import("mount_path.zig").valid(target)) return error.InvalidMount;
    const made = sys.mkdirat(volumes, name.ptr, 0o755);
    if (made != -sys.E.EXIST) _ = try check(made);
    const volume = try check(sys.openat(volumes, name.ptr, dir_flags, 0));
    defer sys.close(volume);
    if (skip_copy) return;
    var entries = Entries{};
    if (try entries.next(volume) != null) return;

    const src = sys.openat2(root, target.ptr, sys.O.RDONLY | sys.O.DIRECTORY, 0, sys.RESOLVE_IN_ROOT | sys.RESOLVE_NO_MAGICLINKS | no_xdev);
    if (src == -sys.E.NOENT) return;
    _ = try check(src);
    defer sys.close(src);
    // A killed start can leave a partial tree only inside this container's private work directory.
    const stage = "volume-seed";
    util.rmTree(work, stage, 0);
    _ = try check(sys.mkdirat(work, stage, 0o700));
    defer util.rmTree(work, stage, 0);
    const dst = try check(sys.openat(work, stage, dir_flags, 0));
    defer sys.close(dst);
    var st: sys.Stat = undefined;
    _ = try check(sys.fstat(src, &st));
    var copy = Copy{ .root = dst, .alloc = util.arena() };
    try copy.directory(src, dst, 0, 0);
    try copy.metadata(src, dst, ".", dst, st);
    // renameat fails atomically if the destination has acquired even one entry.
    const rc = sys.renameat(work, stage, volumes, name.ptr);
    if (rc != -sys.E.NOTEMPTY and rc != -sys.E.EXIST) _ = try check(rc);
}

// Detach the directory before reclaiming it. A retry first finishes any interrupted deletion.
pub fn remove(name: [:0]const u8) !void {
    last_errno = 0;
    if (!util.validVolumeName(name)) return error.InvalidMount;
    const volumes = try check(sys.open(util.base ++ "/volumes", dir_flags, 0));
    defer sys.close(volumes);
    const made = sys.mkdirat(sys.AT_FDCWD, util.base ++ "/volume-trash", 0o700);
    if (made != -sys.E.EXIST) _ = try check(made);
    const trash = try check(sys.open(util.base ++ "/volume-trash", dir_flags, 0));
    defer sys.close(trash);
    _ = try check(util.rmTreeChecked(trash, name.ptr));
    const rc = sys.renameat(volumes, name.ptr, trash, name.ptr);
    if (rc == -sys.E.NOENT) return;
    _ = try check(rc);
    _ = try check(util.rmTreeChecked(trash, name.ptr));
}

test "volume seeding preserves files and metadata, confines links, and publishes only complete copies" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    util.initArena();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const outer = tmp.dir.handle;
    for ([_][*:0]const u8{ "image", "volumes", "work" }) |d| _ = try check(sys.mkdirat(outer, d, 0o700));
    const root = try check(sys.openat(outer, "image", dir_flags, 0));
    defer sys.close(root);
    const volumes = try check(sys.openat(outer, "volumes", dir_flags, 0));
    defer sys.close(volumes);
    const work = try check(sys.openat(outer, "work", dir_flags, 0));
    defer sys.close(work);
    _ = try check(sys.mkdirat(root, "data", 0o755));
    const src = try check(sys.openat(root, "data/file", sys.O.CREAT | sys.O.EXCL | sys.O.WRONLY, 0o640));
    defer sys.close(src);
    _ = try check(sys.writeAll(src, "payload"));
    _ = try check(sys.linkat(root, "data/file", root, "data/hard", 0));
    _ = try check(sys.symlinkat("../../sentinel", root, "data/link"));
    _ = try check(sys.symlinkat("../work", root, "escape"));
    _ = try check(sys.symlinkat("../canary", root, "data/canary-link"));
    const read_canary = try check(sys.openat(root, "canary", sys.O.CREAT | sys.O.WRONLY, 0o600));
    defer sys.close(read_canary);
    const write_canary = try check(sys.openat(work, "canary", sys.O.CREAT | sys.O.WRONLY, 0o600));
    defer sys.close(write_canary);
    const sentinel = try check(sys.openat(outer, "sentinel", sys.O.CREAT | sys.O.EXCL | sys.O.WRONLY, 0o600));
    defer sys.close(sentinel);
    const times: [2]sys.Timespec = @splat(.{ .sec = 42, .nsec = 13 });
    _ = try check(sys.utimensat(src, "", &times, sys.AT_EMPTY_PATH));
    var pb: [64]u8 = undefined;
    _ = try check(sys.setxattr(procFd(&pb, src).ptr, "user.volume-test", "copied"));
    _ = try check(sys.setxattr(procFd(&pb, read_canary).ptr, "user.canary", "source"));
    _ = try check(sys.setxattr(procFd(&pb, write_canary).ptr, "user.canary", "private"));
    _ = try check(sys.utimensat(root, "data/canary-link", &times, sys.AT_SYMLINK_NOFOLLOW));
    var linkbuf: [128]u8 = undefined;
    const source_link = try std.fmt.bufPrintSentinel(&linkbuf, "/proc/self/fd/{d}/data/canary-link", .{root}, 0);
    const link_attr = sys.lsetxattr(source_link.ptr, "trusted.volume-test", "link");
    if (link_attr != -sys.E.PERM and link_attr != -sys.E.OPNOTSUPP) _ = try check(link_attr);
    try prepare(root, volumes, work, "seed", "/data", false);
    var file: sys.Stat = undefined;
    var other: sys.Stat = undefined;
    _ = try check(sys.fstatat(volumes, "seed/file", &file, 0));
    _ = try check(sys.fstatat(volumes, "seed/hard", &other, 0));
    try std.testing.expectEqual(file.ino, other.ino);
    try std.testing.expectEqual(@as(u32, 0o640), file.mode & 0o7777);
    try std.testing.expectEqual(@as(i64, 42), file.mtime);
    try std.testing.expectEqual(@as(i64, 13), file.mtime_nsec);
    var buf: [64]u8 = undefined;
    const copied = try check(sys.openat(volumes, "seed/file", sys.O.RDONLY, 0));
    defer sys.close(copied);
    try std.testing.expectEqualStrings("payload", buf[0..@intCast(try check(sys.read(copied, &buf)))]);
    const n = try check(sys.sc(.getxattr, @intFromPtr(procFd(&pb, copied).ptr), @intFromPtr("user.volume-test"), @intFromPtr(&buf), buf.len, 0, 0));
    try std.testing.expectEqualStrings("copied", buf[0..@intCast(n)]);
    try std.testing.expectEqualStrings("../../sentinel", buf[0..@intCast(try check(sys.readlinkat(volumes, "seed/link", &buf)))]);
    const canary_n = try check(sys.sc(.fgetxattr, @intCast(write_canary), @intFromPtr("user.canary"), @intFromPtr(&buf), buf.len, 0, 0));
    try std.testing.expectEqualStrings("private", buf[0..@intCast(canary_n)]);
    _ = try check(sys.fstatat(volumes, "seed/canary-link", &other, sys.AT_SYMLINK_NOFOLLOW));
    try std.testing.expectEqual(@as(i64, 42), other.mtime);
    try std.testing.expectEqual(@as(i64, 13), other.mtime_nsec);
    if (link_attr >= 0) {
        const copied_link = try std.fmt.bufPrintSentinel(&linkbuf, "/proc/self/fd/{d}/seed/canary-link", .{volumes}, 0);
        const attr_n = try check(sys.lgetxattr(copied_link.ptr, "trusted.volume-test", &buf));
        try std.testing.expectEqualStrings("link", buf[0..@intCast(attr_n)]);
    }
    _ = try check(sys.fstat(sentinel, &other));
    try std.testing.expectEqual(@as(u32, 0o600), other.mode & 0o7777);
    try std.testing.expect(other.mtime != 42);

    try prepare(root, volumes, work, "nocopy", "/data", true);
    try std.testing.expectEqual(-@as(isize, sys.E.NOENT), sys.fstatat(volumes, "nocopy/file", &other, 0));
    _ = try check(sys.mkdirat(work, "outside", 0o700));
    try prepare(root, volumes, work, "escape", "/escape", false);
    try std.testing.expectEqual(-@as(isize, sys.E.NOENT), sys.fstatat(volumes, "escape/outside", &other, 0));
    _ = try check(sys.symlinkat("../work", volumes, "badvol"));
    try std.testing.expectError(error.Syscall, prepare(root, volumes, work, "badvol", "/data", false));
    try std.testing.expectEqual(-@as(isize, sys.E.NOENT), sys.fstatat(work, "file", &other, 0));

    // An unsupported image entry cannot publish earlier entries or replace the original empty inode.
    const socket = try check(sys.socket(sys.AF_UNIX, sys.SOCK_STREAM, 0));
    defer sys.close(socket);
    var addr = std.os.linux.sockaddr.un{ .path = undefined };
    const path = try std.fmt.bufPrintSentinel(&addr.path, "/proc/self/fd/{d}/data/socket", .{root}, 0);
    _ = try check(sys.bind(socket, &addr, @offsetOf(std.os.linux.sockaddr.un, "path") + path.len + 1));
    _ = try check(sys.mkdirat(volumes, "failed", 0o751));
    _ = try check(sys.fstatat(volumes, "failed", &other, 0));
    const original = other;
    try std.testing.expectError(error.UnsupportedEntry, prepare(root, volumes, work, "failed", "/data", false));
    _ = try check(sys.fstatat(volumes, "failed", &other, 0));
    try std.testing.expectEqual(original.ino, other.ino);
    try std.testing.expectEqual(original.mode, other.mode);
    try std.testing.expectEqual(-@as(isize, sys.E.NOENT), sys.fstatat(volumes, "failed/file", &other, 0));
    try std.testing.expectEqual(-@as(isize, sys.E.NOENT), sys.fstatat(work, "volume-seed", &other, 0));
    try prepare(root, volumes, work, "seed", "/data", false);
    _ = try check(sys.fstatat(volumes, "seed/file", &other, 0));
    try std.testing.expectEqual(file.ino, other.ino);
}
