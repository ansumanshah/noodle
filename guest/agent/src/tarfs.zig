//! Tar <-> filesystem: path-traversal-safe extraction (layers, archive_put) and tar creation
//! (archive_get, export, layer_get, commit).
const std = @import("std");
const sys = @import("sys.zig");
const util = @import("util.zig");
const tar = @import("tar");

pub const Err = error{ Sys, Unsafe };
pub var last_errno: i32 = 0;
pub var last_what: []const u8 = "";

fn fail(what: []const u8, rc: isize) Err {
    last_errno = @intCast(-rc);
    last_what = what;
    return error.Sys;
}

fn procFdPath(buf: []u8, fd: isize, name: []const u8) [*:0]const u8 {
    const s = std.fmt.bufPrint(buf, "/proc/self/fd/{d}/{s}", .{ fd, name }) catch "";
    buf[s.len] = 0;
    return @ptrCast(buf.ptr);
}

pub const Extractor = struct {
    root: isize, // directory fd (not O_PATH required)
    overlay: bool, // convert OCI whiteouts to overlayfs form
    root_owner: bool = false, // ignore tar owners: docker cp without -a creates files as root
    pc_path: [1024]u8 = undefined,
    pc_len: usize = 0,
    pc_fd: isize = -1,
    copy_buf: [64 * 1024]u8 = undefined,

    pub fn deinit(self: *Extractor) void {
        sys.close(self.pc_fd);
        self.pc_fd = -1;
    }

    fn invalidate(self: *Extractor) void {
        sys.close(self.pc_fd);
        self.pc_fd = -1;
        self.pc_len = 0;
    }

    fn openDir(self: *Extractor, rel: []const u8) isize {
        var b: [1100]u8 = undefined;
        const p: [*:0]const u8 = if (rel.len == 0) "." else blk: {
            @memcpy(b[0..rel.len], rel);
            b[rel.len] = 0;
            break :blk @ptrCast(&b);
        };
        return sys.openat2(self.root, p, sys.O.PATH | sys.O.DIRECTORY, 0, sys.RESOLVE_IN_ROOT);
    }

    /// Open (creating missing ancestors) the directory `rel` below root. Result is cached.
    fn parentFd(self: *Extractor, rel: []const u8) Err!isize {
        if (self.pc_fd >= 0 and self.pc_len == rel.len and std.mem.eql(u8, self.pc_path[0..self.pc_len], rel)) return self.pc_fd;
        var fd = self.openDir(rel);
        if (fd == -sys.E.NOENT) {
            // create ancestors one by one, each resolved confined to root
            var i: usize = 0;
            while (i < rel.len) {
                const nxt = std.mem.indexOfScalarPos(u8, rel, i, '/') orelse rel.len;
                const parent = self.openDir(if (i == 0) "" else rel[0 .. i - 1]);
                if (parent < 0) return fail("open parent", parent);
                var nb: [256]u8 = undefined;
                const comp = rel[i..nxt];
                if (comp.len >= nb.len) {
                    sys.close(parent);
                    return error.Unsafe;
                }
                @memcpy(nb[0..comp.len], comp);
                nb[comp.len] = 0;
                const rc = sys.mkdirat(parent, @ptrCast(&nb), 0o755);
                sys.close(parent);
                if (rc < 0 and rc != -sys.E.EXIST) return fail("mkdir ancestor", rc);
                i = nxt + 1;
            }
            fd = self.openDir(rel);
        }
        if (fd < 0) return fail("open dir", fd);
        self.invalidate();
        if (rel.len < self.pc_path.len) {
            @memcpy(self.pc_path[0..rel.len], rel);
            self.pc_len = rel.len;
            self.pc_fd = fd;
        } else {
            // too long to cache: leak-free by caching nothing; caller closes via invalidate on next call
            self.pc_fd = fd;
            self.pc_len = 0;
            self.pc_path[0] = 0xff; // never matches
            self.pc_len = 1;
        }
        return fd;
    }

    fn removeExisting(parent: isize, name: [*:0]const u8) void {
        var st: sys.Stat = undefined;
        if (sys.fstatat(parent, name, &st, sys.AT_SYMLINK_NOFOLLOW) < 0) return;
        util.rmTree(parent, name, 0);
    }

    fn applyEntryMeta(parent: isize, name: [*:0]const u8, e: tar.Entry, expected: u32) Err!void {
        const fd = sys.openat(parent, name, sys.O.PATH | sys.O.NOFOLLOW, 0);
        if (fd < 0) return fail("open entry", fd);
        defer sys.close(fd);
        var st: sys.Stat = undefined;
        if (sys.fstat(fd, &st) < 0 or st.mode & sys.S.IFMT != expected) return error.Unsafe;
        try applyMeta(fd, e);
    }

    fn applyMeta(fd: isize, e: tar.Entry) Err!void {
        const flags = sys.AT_EMPTY_PATH | sys.AT_SYMLINK_NOFOLLOW;
        var rc = sys.fchownat(fd, "", e.uid, e.gid, flags);
        if (rc < 0 and rc != -sys.E.PERM) return fail("chown", rc);
        if (e.kind != .symlink) {
            rc = sys.chmodFd(fd, e.mode);
            if (rc < 0) return fail("chmod", rc);
        }
        const times = [2]sys.Timespec{
            .{ .sec = e.mtime, .nsec = e.mtime_nsec },
            .{ .sec = e.mtime, .nsec = e.mtime_nsec },
        };
        _ = sys.utimensat(fd, "", &times, flags);
        for (e.xattrs) |x| {
            var pb: [64]u8 = undefined;
            var nb: [300]u8 = undefined;
            if (x.name.len >= nb.len) continue;
            @memcpy(nb[0..x.name.len], x.name);
            nb[x.name.len] = 0;
            // The procfs magic link refers to the pinned inode, including an O_PATH symlink itself.
            const pinned = std.fmt.bufPrintSentinel(&pb, "/proc/self/fd/{d}", .{fd}, 0) catch return error.Unsafe;
            const r2 = sys.setxattr(pinned.ptr, @ptrCast(&nb), x.value);
            if (r2 < 0 and r2 != -sys.E.OPNOTSUPP and r2 != -sys.E.PERM) return fail("setxattr", r2);
        }
    }

    pub fn apply(self: *Extractor, entry: tar.Entry, rd: anytype) Err!void {
        var e = entry;
        if (self.root_owner) {
            e.uid = 0;
            e.gid = 0;
        }
        if (e.kind == .char or e.kind == .block) return error.Unsafe;
        var cb: [1024]u8 = undefined;
        const clean = tar.cleanPath(e.name, &cb) orelse return error.Unsafe;
        if (clean.len == 0) return; // "./" root entry
        const slash = std.mem.lastIndexOfScalar(u8, clean, '/');
        const dir = if (slash) |s| clean[0..s] else "";
        const base = if (slash) |s| clean[s + 1 ..] else clean;
        if (base.len == 0 or base.len > 255) return error.Unsafe;
        var nb: [256]u8 = undefined;
        @memcpy(nb[0..base.len], base);
        nb[base.len] = 0;
        const name: [*:0]const u8 = @ptrCast(&nb);

        // whiteouts
        if (self.overlay and std.mem.startsWith(u8, base, ".wh.")) {
            const victim = base[4..];
            if (!util.validChildName(victim)) return error.Unsafe;
            const parent = try self.parentFd(dir);
            if (std.mem.eql(u8, base, ".wh..wh..opq")) {
                var pb: [64]u8 = undefined;
                const pp = procFdPath(&pb, parent, "");
                // path ends with "/": strip to the fd itself
                const fdp = std.fmt.bufPrintSentinel(&pb, "/proc/self/fd/{d}", .{parent}, 0) catch return error.Unsafe;
                _ = pp;
                const rc = sys.sc(.setxattr, @intFromPtr(fdp.ptr), @intFromPtr("trusted.overlay.opaque"), @intFromPtr("y"), 1, 0, 0);
                if (rc < 0) return fail("opaque xattr", rc);
                return;
            }
            @memcpy(nb[0..victim.len], victim);
            nb[victim.len] = 0;
            const vname: [*:0]const u8 = @ptrCast(&nb);
            removeExisting(parent, vname);
            const rc = sys.mknodat(parent, vname, sys.S.IFCHR, 0);
            if (rc < 0) return fail("whiteout mknod", rc);
            return;
        }

        // invalidate the parent cache if we are replacing something it passes through
        if (self.pc_fd >= 0 and e.kind != .dir) {
            if (std.mem.eql(u8, self.pc_path[0..self.pc_len], clean) or
                (self.pc_len > clean.len and std.mem.startsWith(u8, self.pc_path[0..self.pc_len], clean) and self.pc_path[clean.len] == '/'))
                self.invalidate();
        }
        const parent = try self.parentFd(dir);

        switch (e.kind) {
            .dir => {
                var st: sys.Stat = undefined;
                const have = sys.fstatat(parent, name, &st, sys.AT_SYMLINK_NOFOLLOW);
                if (have >= 0 and (st.mode & sys.S.IFMT) != sys.S.IFDIR) {
                    removeExisting(parent, name);
                }
                const rc = sys.mkdirat(parent, name, 0o755);
                if (rc < 0 and rc != -sys.E.EXIST) return fail("mkdir", rc);
                try applyEntryMeta(parent, name, e, sys.S.IFDIR);
            },
            .file, .other => {
                removeExisting(parent, name);
                const fd = sys.openat(parent, name, sys.O.WRONLY | sys.O.CREAT | sys.O.EXCL | sys.O.NOFOLLOW, 0o600);
                if (fd < 0) return fail("create file", fd);
                defer sys.close(fd);
                while (true) {
                    const n = rd.readBody(&self.copy_buf) catch return error.Unsafe;
                    if (n == 0) break;
                    const rc = sys.writeAll(fd, self.copy_buf[0..n]);
                    if (rc < 0) return fail("write file", rc);
                }
                try applyMeta(fd, e);
            },
            .symlink => {
                removeExisting(parent, name);
                var lb: [1100]u8 = undefined;
                if (e.linkname.len >= lb.len) return error.Unsafe;
                @memcpy(lb[0..e.linkname.len], e.linkname);
                lb[e.linkname.len] = 0;
                const rc = sys.symlinkat(@ptrCast(&lb), parent, name);
                if (rc < 0) return fail("symlink", rc);
                try applyEntryMeta(parent, name, e, sys.S.IFLNK);
            },
            .hardlink => {
                var tb: [1024]u8 = undefined;
                const tclean = tar.cleanPath(e.linkname, &tb) orelse return error.Unsafe;
                const ts = std.mem.lastIndexOfScalar(u8, tclean, '/');
                const tdir = if (ts) |s| tclean[0..s] else "";
                const tbase = if (ts) |s| tclean[s + 1 ..] else tclean;
                if (tbase.len == 0 or tbase.len > 255) return error.Unsafe;
                const tfd = self.openDir(tdir);
                if (tfd < 0) return fail("hardlink target dir", tfd);
                defer sys.close(tfd);
                var tn: [256]u8 = undefined;
                @memcpy(tn[0..tbase.len], tbase);
                tn[tbase.len] = 0;
                removeExisting(parent, name);
                const rc = sys.linkat(tfd, @ptrCast(&tn), parent, name, 0);
                if (rc < 0) return fail("hardlink", rc);
            },
            .fifo => {
                removeExisting(parent, name);
                const rc = sys.mknodat(parent, name, sys.S.IFIFO | (e.mode & 0o7777), 0);
                if (rc < 0) return fail("mkfifo", rc);
                try applyEntryMeta(parent, name, e, sys.S.IFIFO);
            },
            .char, .block => unreachable,
        }
    }
};

/// Extract a whole tar from `Src` (anything with `read([]u8) usize`) into `root`.
var scratch_mem: [2 << 20]u8 = undefined; // per-entry strings and PAX records; reset for every entry

pub fn extractAll(src: anytype, root: isize, overlay: bool) !void {
    return extractWith(src, Extractor{ .root = root, .overlay = overlay });
}

pub fn extractAs(src: anytype, root: isize, root_owner: bool) !void {
    return extractWith(src, Extractor{ .root = root, .overlay = false, .root_owner = root_owner });
}

fn extractWith(src: anytype, config: Extractor) !void {
    const Src = std.meta.Child(@TypeOf(src));
    var rd = tar.Reader(Src).init(src);
    var ex = config;
    defer ex.deinit();
    var scratch = std.heap.FixedBufferAllocator.init(&scratch_mem);
    while (true) {
        scratch.reset();
        const e = (try rd.next(scratch.allocator())) orelse break;
        ex.apply(e, &rd) catch |err| {
            util.log("extract {s}: {s} errno {d} ({s})", .{ e.name, @errorName(err), last_errno, last_what });
            return err;
        };
    }
    rd.drain();
}

// ----------------------------------------------------------------------------------- creation

pub const FdSink = struct {
    fd: isize,
    buf: [64 * 1024]u8 = undefined,
    len: usize = 0,
    failed: bool = false,
    pub fn writeAll(self: *FdSink, bytes: []const u8) !void {
        var b = bytes;
        while (b.len > 0) {
            if (self.len == self.buf.len) try self.flush();
            const n = @min(b.len, self.buf.len - self.len);
            @memcpy(self.buf[self.len .. self.len + n], b[0..n]);
            self.len += n;
            b = b[n..];
        }
    }
    pub fn flush(self: *FdSink) !void {
        if (self.len == 0) return;
        const rc = sys.writeAll(self.fd, self.buf[0..self.len]);
        self.len = 0;
        if (rc < 0) {
            self.failed = true;
            return error.WriteFailed;
        }
    }
};

pub const CreateOpts = struct {
    /// Convert overlayfs whiteouts/opaque dirs into OCI `.wh.` entries (commit, layer_get).
    oci_whiteouts: bool = false,
    /// Skip the container-managed mountpoints and files at the top level (proc, sys, dev, etc/hosts...).
    skip_runtime: bool = false,
};

const HardKey = struct { dev: u64, ino: u64 };
const HardSlot = struct { key: HardKey, path_off: u32, path_len: u32, used: bool };

pub const Creator = struct {
    w: tar.Writer(FdSink),
    sink: *FdSink,
    opts: CreateOpts,
    hard: [8192]HardSlot = @splat(.{ .key = .{ .dev = 0, .ino = 0 }, .path_off = 0, .path_len = 0, .used = false }),
    names: [256 * 1024]u8 = undefined,
    names_len: usize = 0,
    copy_buf: [64 * 1024]u8 = undefined,

    fn hardLookup(self: *Creator, st: *const sys.Stat, path: []const u8) ?[]const u8 {
        var h: usize = @intCast((st.ino *% 0x9E3779B97F4A7C15 ^ st.dev) >> 40);
        var probes: usize = 0;
        while (probes < 64) : (probes += 1) {
            const slot = &self.hard[h % self.hard.len];
            if (!slot.used) {
                if (self.names_len + path.len <= self.names.len) {
                    @memcpy(self.names[self.names_len .. self.names_len + path.len], path);
                    slot.* = .{ .key = .{ .dev = st.dev, .ino = st.ino }, .path_off = @intCast(self.names_len), .path_len = @intCast(path.len), .used = true };
                    self.names_len += path.len;
                }
                return null;
            }
            if (slot.key.dev == st.dev and slot.key.ino == st.ino) return self.names[slot.path_off .. slot.path_off + slot.path_len];
            h += 1;
        }
        return null;
    }

    fn isRuntimeSkip(rel_in_root: []const u8) bool {
        const skips = [_][]const u8{ "proc", "sys", "dev", "etc/hosts", "etc/resolv.conf", "etc/hostname", ".dockerenv" };
        for (skips) |s| if (std.mem.eql(u8, rel_in_root, s)) return true;
        return false;
    }

    /// Add the file or tree at `dirfd`/`name` under the tar name `tname` (no leading slash).
    pub fn addTree(self: *Creator, dirfd: isize, name: [*:0]const u8, tname: []const u8, depth: u32) !void {
        if (depth > 100) return fail("tree deeper than 100 levels", -sys.E.NAMETOOLONG);
        var st: sys.Stat = undefined;
        const rc = sys.fstatat(dirfd, name, &st, sys.AT_SYMLINK_NOFOLLOW);
        if (rc < 0) return fail("stat", rc);
        const a = util.arena();
        // names, xattrs and the child list die with this entry; a 1.5M-file export must not exhaust the arena
        const mark = util.arenaMark();
        defer util.arenaRewind(mark);
        const fmt = st.mode & sys.S.IFMT;

        var e = tar.Entry{
            .name = tname,
            .mode = st.mode & 0o7777,
            .uid = st.uid,
            .gid = st.gid,
            .mtime = st.mtime,
            .mtime_nsec = @intCast(st.mtime_nsec),
        };
        var xattrs: [1]tar.Xattr = undefined;
        // security.capability is the only xattr worth carrying
        if (fmt != sys.S.IFLNK) {
            var pb: [600]u8 = undefined;
            const full = procFdPath(&pb, dirfd, std.mem.span(name));
            var vb: [64]u8 = undefined;
            const n = sys.lgetxattr(full, "security.capability", &vb);
            if (n > 0) {
                xattrs[0] = .{ .name = "security.capability", .value = a.dupe(u8, vb[0..@intCast(n)]) catch "" };
                e.xattrs = xattrs[0..1];
            }
        }

        // overlay whiteout char device 0:0
        if (self.opts.oci_whiteouts and fmt == sys.S.IFCHR and st.rdev == 0) {
            const slash = std.mem.lastIndexOfScalar(u8, tname, '/');
            const wh = if (slash) |s| util.sf("{s}/.wh.{s}", .{ tname[0..s], tname[s + 1 ..] }) else util.sf(".wh.{s}", .{tname});
            e.name = wh;
            e.kind = .file;
            e.size = 0;
            e.mode = 0;
            e.xattrs = &.{};
            try self.w.begin(a, e);
            try self.w.endEntry(0);
            return;
        }

        switch (fmt) {
            sys.S.IFDIR => {
                e.kind = .dir;
                e.name = util.sf("{s}/", .{tname});
                try self.w.begin(a, e);
                try self.w.endEntry(0);
                const fd = sys.openat(dirfd, name, sys.O.RDONLY | sys.O.DIRECTORY | sys.O.NOFOLLOW, 0);
                if (fd < 0) return fail("open dir", fd);
                defer sys.close(fd);
                if (self.opts.oci_whiteouts) {
                    var pb: [64]u8 = undefined;
                    const fdp = std.fmt.bufPrintSentinel(&pb, "/proc/self/fd/{d}", .{fd}, 0) catch unreachable;
                    var vb: [4]u8 = undefined;
                    const n2 = sys.sc(.getxattr, @intFromPtr(fdp.ptr), @intFromPtr("trusted.overlay.opaque"), @intFromPtr(&vb), vb.len, 0, 0);
                    if (n2 > 0 and vb[0] == 'y') {
                        var oe = tar.Entry{ .name = util.sf("{s}/.wh..wh..opq", .{tname}), .kind = .file, .mode = 0, .size = 0, .mtime = st.mtime };
                        oe.uid = 0;
                        try self.w.begin(a, oe);
                        try self.w.endEntry(0);
                    }
                }
                // collect names first (we recurse and the buffer is reused)
                var names: std.ArrayList([:0]u8) = .empty;
                var dbuf: [4096]u8 align(8) = undefined;
                while (true) {
                    const n = sys.getdents64(fd, &dbuf);
                    if (n <= 0) break;
                    var off: usize = 0;
                    while (off < @as(usize, @intCast(n))) {
                        const reclen = std.mem.readInt(u16, dbuf[off + 16 ..][0..2], .little);
                        const nm: [*:0]const u8 = @ptrCast(&dbuf[off + 19]);
                        const s = std.mem.span(nm);
                        if (!(std.mem.eql(u8, s, ".") or std.mem.eql(u8, s, ".."))) {
                            try names.append(a, try util.dupeZ(a, s));
                        }
                        off += reclen;
                    }
                }
                std.mem.sort([:0]u8, names.items, {}, struct {
                    fn lt(_: void, x: [:0]u8, y: [:0]u8) bool {
                        return std.mem.lessThan(u8, x, y);
                    }
                }.lt);
                for (names.items) |child| {
                    const cmark = util.arenaMark();
                    defer util.arenaRewind(cmark);
                    const ct = util.sf("{s}/{s}", .{ tname, child });
                    if (self.opts.skip_runtime and isRuntimeSkip(ct)) continue;
                    try self.addTree(fd, child.ptr, ct, depth + 1);
                }
            },
            sys.S.IFLNK => {
                var lb: [4100]u8 = undefined;
                const n = sys.readlinkat(dirfd, name, &lb);
                if (n < 0) return fail("readlink", n);
                e.kind = .symlink;
                e.linkname = a.dupe(u8, lb[0..@intCast(n)]) catch "";
                try self.w.begin(a, e);
                try self.w.endEntry(0);
            },
            sys.S.IFREG => {
                if (st.nlink > 1) {
                    if (self.hardLookup(&st, tname)) |first| {
                        e.kind = .hardlink;
                        e.linkname = first;
                        try self.w.begin(a, e);
                        try self.w.endEntry(0);
                        return;
                    }
                }
                e.kind = .file;
                e.size = @intCast(st.size);
                const fd = sys.openat(dirfd, name, sys.O.RDONLY | sys.O.NOFOLLOW, 0);
                if (fd < 0) return fail("open file", fd);
                defer sys.close(fd);
                try self.w.begin(a, e);
                var left: u64 = e.size;
                while (left > 0) {
                    const want: usize = @intCast(@min(left, self.copy_buf.len));
                    const n = sys.read(fd, self.copy_buf[0..want]);
                    if (n < 0) return fail("read file", n);
                    if (n == 0) {
                        // file shrank: pad with zeros so the archive stays consistent
                        @memset(self.copy_buf[0..want], 0);
                        try self.w.data(self.copy_buf[0..want]);
                        left -= want;
                        continue;
                    }
                    try self.w.data(self.copy_buf[0..@intCast(n)]);
                    left -= @intCast(n);
                }
                try self.w.endEntry(e.size);
            },
            sys.S.IFCHR, sys.S.IFBLK, sys.S.IFIFO => {
                e.kind = if (fmt == sys.S.IFCHR) .char else if (fmt == sys.S.IFBLK) .block else .fifo;
                e.devmajor = @intCast(((st.rdev >> 8) & 0xfff) | ((st.rdev >> 32) & ~@as(u64, 0xfff)));
                e.devminor = @intCast((st.rdev & 0xff) | ((st.rdev >> 12) & ~@as(u64, 0xff)));
                try self.w.begin(a, e);
                try self.w.endEntry(0);
            },
            else => {}, // sockets are skipped
        }
    }
};

/// Allocate a Creator in the arena (it is large).
pub fn newCreator(sink: *FdSink, opts: CreateOpts) ?*Creator {
    const c = util.arena().create(Creator) catch return null;
    c.* = .{ .w = tar.Writer(FdSink).init(sink), .sink = sink, .opts = opts };
    // `hard` default-initialised above; names is left undefined on purpose (large)
    return c;
}

test "archive metadata stays on the extracted inode after a symlink swap" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const outer = tmp.dir.handle;
    try std.testing.expectEqual(@as(isize, 0), sys.mkdirat(outer, "extract", 0o700));
    const root = sys.openat(outer, "extract", sys.O.RDONLY | sys.O.DIRECTORY, 0);
    try std.testing.expect(root >= 0);
    defer sys.close(root);
    const sentinel = sys.openat(outer, "sentinel", sys.O.WRONLY | sys.O.CREAT | sys.O.EXCL, 0o600);
    try std.testing.expect(sentinel >= 0);
    defer sys.close(sentinel);
    var ex = Extractor{ .root = root, .overlay = false };
    defer ex.deinit();
    var reader = struct {
        root: isize,
        fn readBody(self: @This(), _: []u8) !usize {
            try std.testing.expectEqual(@as(isize, 0), sys.renameat(self.root, "entry", self.root, "original"));
            try std.testing.expectEqual(@as(isize, 0), sys.symlinkat("../sentinel", self.root, "entry"));
            return 0;
        }
    }{ .root = root };
    try ex.apply(.{ .name = "entry", .mode = 0o750, .mtime = 42, .xattrs = &.{.{ .name = "user.archive-test", .value = "ok" }} }, &reader);
    // A symlink entry may carry metadata, but it cannot alter its target.
    try ex.apply(.{ .name = "link", .kind = .symlink, .linkname = "../sentinel", .mtime = 42, .xattrs = &.{.{ .name = "user.archive-test", .value = "bad" }} }, &reader);
    var attr: [8]u8 = undefined;
    var path: [128]u8 = undefined;
    const got = sys.lgetxattr(procFdPath(&path, outer, "sentinel"), "user.archive-test", &attr);
    try std.testing.expect(got == -sys.E.NODATA or got == -sys.E.OPNOTSUPP);
    var st: sys.Stat = undefined;
    try std.testing.expectEqual(@as(isize, 0), sys.fstat(sentinel, &st));
    try std.testing.expectEqual(@as(u32, 0o600), st.mode & 0o777);
    try std.testing.expect(st.mtime != 42);
    try std.testing.expectEqual(@as(isize, 0), sys.fstatat(root, "original", &st, 0));
    try std.testing.expectEqual(@as(u32, 0o750), st.mode & 0o777);
    try std.testing.expectEqual(@as(i64, 42), st.mtime);
    for ([_]bool{ false, true }) |is_layer| {
        ex.overlay = is_layer;
        for ([_]tar.Kind{ .char, .block }) |kind| {
            try std.testing.expectError(error.Unsafe, ex.apply(.{ .name = "original", .kind = kind, .devmajor = 1, .devminor = 5 }, &reader));
        }
        try std.testing.expectEqual(@as(isize, 0), sys.fstatat(root, "original", &st, 0));
        try std.testing.expectEqual(@as(u32, sys.S.IFREG), st.mode & sys.S.IFMT);
    }
}

test "a tree deeper than the limit is an error, not a silent skip" {
    var sink = FdSink{ .fd = -1 };
    const cr = try std.heap.page_allocator.create(Creator);
    defer std.heap.page_allocator.destroy(cr);
    cr.* = .{ .w = tar.Writer(FdSink).init(&sink), .sink = &sink, .opts = .{} };
    try std.testing.expectError(error.Sys, cr.addTree(sys.AT_FDCWD, "x", "x", 101));
}
