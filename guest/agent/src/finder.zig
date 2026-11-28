//! Descriptor-pinned, bounded on-demand Finder reads. Runs only in a stream child.
const std = @import("std");
const sys = @import("sys.zig");
const util = @import("util.zig");
const json = @import("json");
const frame = @import("frame");
const container = @import("container.zig");
const stream = @import("stream.zig");
const resolve = sys.RESOLVE_IN_ROOT | sys.RESOLVE_NO_MAGICLINKS | 0x04;

fn send(fd: isize, bytes: []const u8) bool {
    const h = frame.encodeHeader(@intCast(bytes.len));
    return sys.writeAll(fd, &h) >= 0 and sys.writeAll(fd, bytes) >= 0;
}
fn validPath(path: []const u8) bool {
    if (path.len > 4095 or std.mem.indexOfScalar(u8, path, 0) != null or std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    return true;
}
// A proc directory descriptor retains process identity even if the numeric PID is reused.
fn runningRoot(c: *container.Cont) isize {
    const procfd = sys.open(util.zf("/proc/{d}", .{c.pid}).ptr, sys.O.PATH | sys.O.DIRECTORY | sys.O.NOFOLLOW, 0);
    if (procfd < 0) return procfd;
    defer sys.close(procfd);
    const cgfd = sys.openat(procfd, "cgroup", sys.O.RDONLY | sys.O.NOFOLLOW, 0);
    if (cgfd < 0) return cgfd;
    defer sys.close(cgfd);
    var buf: [4096]u8 = undefined;
    var len: usize = 0;
    while (true) {
        if (len == buf.len) return -sys.E.ACCES;
        const n = sys.read(cgfd, buf[len..]);
        if (n == -sys.E.INTR) continue;
        if (n < 0) return n;
        if (n == 0) break;
        len += @intCast(n);
    }
    var expected_buf: [128]u8 = undefined;
    const expected = std.fmt.bufPrint(&expected_buf, "0::/noodle/{s}", .{c.idStr()}) catch return -sys.E.ACCES;
    var lines = std.mem.splitScalar(u8, buf[0..len], '\n');
    var matched = false;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "0::")) {
            if (!std.mem.eql(u8, line, expected) or matched) return -sys.E.ACCES;
            matched = true;
        }
    }
    if (!matched) return -sys.E.ACCES;
    // Only this trusted proc magic link is followed; user paths use confined().
    return sys.openat(procfd, "root", sys.O.PATH | sys.O.DIRECTORY, 0);
}
fn confined(root: isize, path: []const u8) isize {
    var buf: [4096]u8 = undefined;
    const p = if (path.len == 0) "/" else path;
    @memcpy(buf[0..p.len], p);
    buf[p.len] = 0;
    return sys.openat2(root, buf[0..p.len :0].ptr, sys.O.PATH, 0, resolve);
}
fn kind(mode: u32) []const u8 {
    return switch (mode & sys.S.IFMT) {
        sys.S.IFREG => "file",
        sys.S.IFDIR => "directory",
        sys.S.IFLNK => "symlink",
        else => "other",
    };
}
fn metadata(conn: isize, name: ?[]const u8, st: sys.Stat) bool {
    var storage: [8192]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var b = json.Buf.init(fixed.allocator());
    b.raw("{") catch return false;
    if (name) |n| {
        b.raw("\"name\":") catch return false;
        b.str(n) catch return false;
        b.raw(",") catch return false;
    }
    b.print("\"kind\":\"{s}\",\"size\":{d},\"mtime\":{d}}}", .{ kind(st.mode), @max(st.size, 0), st.mtime }) catch return false;
    return b.bytes().len <= 4096 and send(conn, b.bytes());
}
fn listError(conn: isize, eno: isize) i32 {
    var buf: [128]u8 = undefined;
    const bytes = std.fmt.bufPrint(&buf, "{{\"error\":\"directory read failed\",\"errno\":{d}}}", .{@abs(eno)}) catch return 1;
    _ = send(conn, bytes);
    return 1;
}
fn list(conn: isize, fd: isize) i32 {
    var buf: [4096]u8 align(8) = undefined;
    while (true) {
        const n = sys.getdents64(fd, &buf);
        if (n == -sys.E.INTR) continue;
        if (n < 0) return listError(conn, n);
        if (n == 0) return if (send(conn, "{\"end\":true}")) 0 else 1;
        var off: usize = 0;
        const len: usize = @intCast(n);
        while (off < len) {
            if (len - off < 20) return listError(conn, sys.E.IO);
            const reclen = std.mem.readInt(u16, buf[off + 16 ..][0..2], .little);
            if (reclen < 20 or reclen > len - off) return listError(conn, sys.E.IO);
            const tail = buf[off + 19 .. off + reclen];
            const end = std.mem.indexOfScalar(u8, tail, 0) orelse return listError(conn, sys.E.IO);
            const name = tail[0..end :0];
            off += reclen;
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            var st: sys.Stat = undefined;
            const rc = sys.fstatat(fd, name.ptr, &st, sys.AT_SYMLINK_NOFOLLOW);
            if (rc == -sys.E.NOENT) continue;
            if (rc < 0) return listError(conn, rc);
            if (!metadata(conn, name, st)) return 1;
        }
    }
}

pub fn serve(conn: isize, req: json.Value) i32 {
    var path = req.strOr("path", "/");
    if (!validPath(path)) {
        stream.ackErr(conn, "invalid finder path", sys.E.ACCES);
        return 1;
    }
    var root: isize = -1;
    const volume = req.strOr("volume", "");
    const id = req.strOr("container", "");
    if (volume.len > 0 and id.len == 0 and util.validVolumeName(volume)) {
        root = sys.openat2(sys.AT_FDCWD, util.zf("{s}/volumes/{s}", .{ util.base, volume }).ptr, sys.O.PATH | sys.O.DIRECTORY, 0, 0x04);
    } else if (volume.len == 0) {
        const c = container.find(id) orelse {
            stream.ackErr(conn, "no such container", sys.E.NOENT);
            return 1;
        };
        if (c.state == .running and c.pid > 0) {
            root = runningRoot(c);
        } else {
            root = sys.openat2(sys.AT_FDCWD, util.zf("{s}/containers/{s}/merged", .{ util.base, c.idStr() }).ptr, sys.O.PATH | sys.O.DIRECTORY, 0, 0x04);
            if (root >= 0) {
                const spec = container.loadSpec(id) catch {
                    sys.close(root);
                    stream.ackErr(conn, "cannot load container spec", sys.E.IO);
                    return 1;
                };
                const clean = std.mem.trim(u8, path, "/");
                var best: []const u8 = "";
                var source: []const u8 = "";
                for (spec.list("mounts")) |m| {
                    if (!std.mem.eql(u8, m.strOr("kind", ""), "volume")) continue;
                    const target = std.mem.trim(u8, m.strOr("target", ""), "/");
                    if (!validPath(target) or target.len == 0 or target.len < best.len) continue;
                    if (!std.mem.eql(u8, clean, target) and !(clean.len > target.len and std.mem.startsWith(u8, clean, target) and clean[target.len] == '/')) continue;
                    best = target;
                    source = m.strOr("source", "");
                }
                if (best.len > 0) {
                    const targetfd = confined(root, best);
                    if (targetfd < 0 and targetfd != -sys.E.NOENT) {
                        sys.close(root);
                        stream.ackErr(conn, "unsafe volume target", @intCast(-targetfd));
                        return 1;
                    }
                    if (targetfd >= 0) sys.close(targetfd);
                    sys.close(root);
                    root = if (util.validVolumeName(source)) sys.openat2(sys.AT_FDCWD, util.zf("{s}/volumes/{s}", .{ util.base, source }).ptr, sys.O.PATH | sys.O.DIRECTORY, 0, 0x04) else -sys.E.ACCES;
                    path = if (clean.len == best.len) "" else clean[best.len + 1 ..];
                }
            }
        }
    } else {
        stream.ackErr(conn, "invalid finder root", sys.E.INVAL);
        return 1;
    }
    if (root < 0) {
        stream.ackErr(conn, "open finder root", @intCast(-root));
        return 1;
    }
    defer sys.close(root);
    const pinned = confined(root, path);
    if (pinned < 0) {
        stream.ackErr(conn, "open finder path", @intCast(-pinned));
        return 1;
    }
    defer sys.close(pinned);
    var st: sys.Stat = undefined;
    const rc = sys.fstat(pinned, &st);
    if (rc < 0 or (st.mode & sys.S.IFMT != sys.S.IFREG and st.mode & sys.S.IFMT != sys.S.IFDIR)) {
        stream.ackErr(conn, "finder requires file or directory", if (rc < 0) @intCast(-rc) else sys.E.ACCES);
        return 1;
    }
    // Reopen the pinned inode through trusted proc, never the mutable user path.
    const fd = sys.open(util.zf("/proc/self/fd/{d}", .{pinned}).ptr, sys.O.RDONLY | sys.O.NONBLOCK, 0);
    if (fd < 0) {
        stream.ackErr(conn, "open finder descriptor", @intCast(-fd));
        return 1;
    }
    defer sys.close(fd);
    if (!stream.ackOk(conn) or !metadata(conn, null, st)) return 1;
    var hdr: [4]u8 = undefined;
    if (sys.readAll(conn, &hdr) != 4) return 1;
    const len = frame.getU32(&hdr);
    if (len > 1024) return 1;
    var selection: [1024]u8 = undefined;
    if (sys.readAll(conn, selection[0..len]) != len) return 1;
    var memory: [16384]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&memory);
    const choice = json.parse(fixed.allocator(), selection[0..len]) catch return 1;
    const action = choice.strOr("action", "");
    if (std.mem.eql(u8, action, "stat")) return 0;
    if (std.mem.eql(u8, action, "list")) return if (st.mode & sys.S.IFMT == sys.S.IFDIR) list(conn, fd) else listError(conn, sys.E.NOTDIR);
    if (!std.mem.eql(u8, action, "read") or st.mode & sys.S.IFMT != sys.S.IFREG) return 1;
    const ov = choice.get("offset") orelse return 1;
    const cv = choice.get("count") orelse return 1;
    if (ov != .int or cv != .int) return 1;
    var offset = ov.int;
    var count = cv.int;
    if (offset < 0 or count < 0 or offset > st.size or count > st.size - offset) return 1;
    var buf: [65536]u8 = undefined;
    while (count > 0) {
        const n = sys.pread(fd, buf[0..@intCast(@min(count, buf.len))], @intCast(offset));
        if (n == -sys.E.INTR) continue;
        if (n <= 0) return 1;
        if (sys.writeAll(conn, buf[0..@intCast(n)]) < 0) return 1;
        offset += n;
        count -= n;
    }
    return 0;
}
