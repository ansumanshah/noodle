//! Streaming tar reader (ustar, GNU long names, PAX) and writer. Pure, no OS dependence.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const block = 512;

pub const Kind = enum { file, hardlink, symlink, char, block, dir, fifo, other };

pub const Xattr = struct { name: []const u8, value: []const u8 };

pub const Entry = struct {
    name: []const u8 = "",
    linkname: []const u8 = "",
    kind: Kind = .file,
    mode: u32 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
    size: u64 = 0,
    mtime: i64 = 0,
    mtime_nsec: u32 = 0,
    devmajor: u32 = 0,
    devminor: u32 = 0,
    xattrs: []const Xattr = &.{},
};

pub const Error = error{ BadHeader, BadChecksum, Truncated, TooLarge, OutOfMemory };

fn trimNul(s: []const u8) []const u8 {
    const i = std.mem.indexOfScalar(u8, s, 0) orelse s.len;
    return s[0..i];
}

fn parseNum(field: []const u8) Error!u64 {
    if (field.len > 0 and (field[0] & 0x80) != 0) {
        // base-256, big endian, high bit marks it
        var v: u64 = field[0] & 0x7f;
        for (field[1..]) |c| {
            if (v > (std.math.maxInt(u64) >> 8)) return error.TooLarge;
            v = (v << 8) | c;
        }
        return v;
    }
    var v: u64 = 0;
    var seen = false;
    for (field) |c| {
        if (c == 0 or c == ' ') {
            if (seen) break;
            continue;
        }
        if (c < '0' or c > '7') return error.BadHeader;
        v = std.math.mul(u64, v, 8) catch return error.TooLarge;
        v += c - '0';
        seen = true;
    }
    return v;
}

/// `Src` must provide `fn read(self: *Src, buf: []u8) usize` returning 0 only at EOF.
pub fn Reader(comptime Src: type) type {
    return struct {
        const Self = @This();
        src: *Src,
        remaining: u64 = 0, // body bytes of current entry not yet consumed
        pad: u64 = 0, // padding after body
        done: bool = false,

        pub fn init(src: *Src) Self {
            return .{ .src = src };
        }

        fn readFull(self: *Self, buf: []u8) Error!usize {
            var off: usize = 0;
            while (off < buf.len) {
                const n = self.src.read(buf[off..]);
                if (n == 0) break;
                off += n;
            }
            return off;
        }

        pub fn skip(self: *Self, n_: u64) Error!void {
            var n = n_;
            var tmp: [4096]u8 = undefined;
            while (n > 0) {
                const want: usize = @intCast(@min(n, tmp.len));
                const got = try self.readFull(tmp[0..want]);
                if (got < want) return error.Truncated;
                n -= got;
            }
        }

        /// Read up to buf.len bytes of the current entry's body.
        pub fn readBody(self: *Self, buf: []u8) Error!usize {
            if (self.remaining == 0) return 0;
            const want: usize = @intCast(@min(self.remaining, buf.len));
            const got = try self.readFull(buf[0..want]);
            if (got == 0) return error.Truncated;
            self.remaining -= got;
            return got;
        }

        /// Drain the rest of the stream (trailing zero blocks, compressor padding) so a hash covers all bytes.
        pub fn drain(self: *Self) void {
            var tmp: [4096]u8 = undefined;
            while (true) {
                const n = self.src.read(&tmp);
                if (n == 0) break;
            }
        }

        fn finishEntry(self: *Self) Error!void {
            try self.skip(self.remaining + self.pad);
            self.remaining = 0;
            self.pad = 0;
        }

        fn readBlob(self: *Self, a: Allocator, size: u64, limit: u64) Error![]u8 {
            if (size > limit) return error.TooLarge;
            const n: usize = @intCast(size);
            const out = try a.alloc(u8, n);
            const got = try self.readFull(out);
            if (got < n) return error.Truncated;
            const padn = (block - (n % block)) % block;
            try self.skip(padn);
            return out;
        }

        /// Returns the next entry or null at end of archive. Strings are allocated from `a`.
        pub fn next(self: *Self, a: Allocator) Error!?Entry {
            if (self.done) return null;
            try self.finishEntry();
            var long_name: ?[]const u8 = null;
            var long_link: ?[]const u8 = null;
            var pax_path: ?[]const u8 = null;
            var pax_link: ?[]const u8 = null;
            var pax_size: ?u64 = null;
            var pax_uid: ?u64 = null;
            var pax_gid: ?u64 = null;
            var pax_mtime: ?struct { s: i64, ns: u32 } = null;
            var xattrs: std.ArrayList(Xattr) = .empty;
            while (true) {
                var h: [block]u8 = undefined;
                const got = try self.readFull(&h);
                if (got == 0) {
                    self.done = true;
                    return null;
                }
                if (got < block) return error.Truncated;
                if (std.mem.allEqual(u8, &h, 0)) {
                    self.done = true;
                    return null;
                }
                // checksum
                const want = try parseNum(h[148..156]);
                var sum: u64 = 0;
                for (h, 0..) |c, i| sum += if (i >= 148 and i < 156) ' ' else c;
                if (sum != want) return error.BadChecksum;

                const typeflag = h[156];
                const size = try parseNum(h[124..136]);
                switch (typeflag) {
                    'L' => {
                        long_name = std.mem.trimEnd(u8, try self.readBlob(a, size, 1 << 20), "\x00");
                        continue;
                    },
                    'K' => {
                        long_link = std.mem.trimEnd(u8, try self.readBlob(a, size, 1 << 20), "\x00");
                        continue;
                    },
                    'g' => {
                        _ = try self.readBlob(a, size, 1 << 20);
                        continue;
                    },
                    'x' => {
                        const body = try self.readBlob(a, size, 1 << 20);
                        var i: usize = 0;
                        while (i < body.len) {
                            const sp = std.mem.indexOfScalarPos(u8, body, i, ' ') orelse break;
                            const rec_len = std.fmt.parseInt(usize, body[i..sp], 10) catch break;
                            if (rec_len == 0 or rec_len > body.len - i or rec_len < sp - i + 1) break;
                            var rec = body[sp + 1 .. i + rec_len];
                            if (rec.len > 0 and rec[rec.len - 1] == '\n') rec = rec[0 .. rec.len - 1];
                            i += rec_len;
                            const eq = std.mem.indexOfScalar(u8, rec, '=') orelse continue;
                            const k = rec[0..eq];
                            if (std.mem.indexOfScalar(u8, k, 0) != null) return error.BadHeader;
                            const v = rec[eq + 1 ..];
                            if (std.mem.eql(u8, k, "path")) {
                                pax_path = v;
                            } else if (std.mem.eql(u8, k, "linkpath")) {
                                pax_link = v;
                            } else if (std.mem.eql(u8, k, "size")) {
                                pax_size = std.fmt.parseInt(u64, v, 10) catch null;
                            } else if (std.mem.eql(u8, k, "uid")) {
                                pax_uid = std.fmt.parseInt(u64, v, 10) catch null;
                            } else if (std.mem.eql(u8, k, "gid")) {
                                pax_gid = std.fmt.parseInt(u64, v, 10) catch null;
                            } else if (std.mem.eql(u8, k, "mtime")) {
                                const dot = std.mem.indexOfScalar(u8, v, '.');
                                const whole = if (dot) |d| v[0..d] else v;
                                const s = std.fmt.parseInt(i64, whole, 10) catch 0;
                                var ns: u32 = 0;
                                if (dot) |d| {
                                    var frac: [9]u8 = @splat('0');
                                    const fl = @min(9, v.len - d - 1);
                                    @memcpy(frac[0..fl], v[d + 1 .. d + 1 + fl]);
                                    ns = std.fmt.parseInt(u32, &frac, 10) catch 0;
                                }
                                pax_mtime = .{ .s = s, .ns = ns };
                            } else if (std.mem.startsWith(u8, k, "SCHILY.xattr.")) {
                                try xattrs.append(a, .{ .name = k["SCHILY.xattr.".len..], .value = v });
                            }
                        }
                        continue;
                    },
                    else => {},
                }

                var e = Entry{};
                // name = prefix + "/" + name for ustar
                const nm = trimNul(h[0..100]);
                const is_ustar = std.mem.startsWith(u8, h[257..263], "ustar");
                const pfx = if (is_ustar) trimNul(h[345..500]) else "";
                if (pfx.len > 0) {
                    const joined = try a.alloc(u8, pfx.len + 1 + nm.len);
                    @memcpy(joined[0..pfx.len], pfx);
                    joined[pfx.len] = '/';
                    @memcpy(joined[pfx.len + 1 ..], nm);
                    e.name = joined;
                } else e.name = try a.dupe(u8, nm);
                e.linkname = try a.dupe(u8, trimNul(h[157..257]));
                if (long_name) |l| e.name = l;
                if (long_link) |l| e.linkname = l;
                if (pax_path) |l| e.name = l;
                if (pax_link) |l| e.linkname = l;
                if (std.mem.indexOfScalar(u8, e.name, 0) != null or std.mem.indexOfScalar(u8, e.linkname, 0) != null) return error.BadHeader;
                e.mode = @intCast((try parseNum(h[100..108])) & 0o7777);
                e.uid = std.math.cast(u32, pax_uid orelse try parseNum(h[108..116])) orelse return error.BadHeader;
                e.gid = std.math.cast(u32, pax_gid orelse try parseNum(h[116..124])) orelse return error.BadHeader;
                e.size = pax_size orelse size;
                if (e.size > std.math.maxInt(u64) - 512) return error.BadHeader; // remaining + pad must not overflow
                if (pax_mtime) |m| {
                    e.mtime = m.s;
                    e.mtime_nsec = m.ns;
                } else e.mtime = std.math.cast(i64, try parseNum(h[136..148])) orelse return error.BadHeader;
                e.devmajor = std.math.cast(u32, try parseNum(h[329..337])) orelse return error.BadHeader;
                e.devminor = std.math.cast(u32, try parseNum(h[337..345])) orelse return error.BadHeader;
                e.xattrs = xattrs.items;
                e.kind = switch (typeflag) {
                    '0', 0, '7' => .file,
                    '1' => .hardlink,
                    '2' => .symlink,
                    '3' => .char,
                    '4' => .block,
                    '5' => .dir,
                    '6' => .fifo,
                    else => .other,
                };
                // a trailing slash on a regular-typed entry means directory
                if (e.kind == .file and e.name.len > 0 and e.name[e.name.len - 1] == '/') e.kind = .dir;
                // hardlinks, symlinks, dirs and devices carry no body
                const has_body = e.kind == .file or e.kind == .other;
                if (has_body) {
                    self.remaining = e.size;
                    self.pad = (block - (e.size % block)) % block;
                } else {
                    self.remaining = 0;
                    self.pad = 0;
                }
                return e;
            }
        }
    };
}

/// Normalise a tar member name to a relative path without "." and ".." components.
/// Returns null if it escapes the root. Writes into `out`.
pub fn cleanPath(name: []const u8, out: []u8) ?[]const u8 {
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, name, '/');
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, ".")) continue;
        if (std.mem.eql(u8, comp, "..")) {
            // pop one component; refuse to climb above root
            if (n == 0) return null;
            const idx = std.mem.lastIndexOfScalar(u8, out[0..n], '/');
            n = idx orelse 0;
            continue;
        }
        const need = comp.len + @intFromBool(n > 0);
        if (n + need > out.len) return null;
        if (n > 0) {
            out[n] = '/';
            n += 1;
        }
        @memcpy(out[n .. n + comp.len], comp);
        n += comp.len;
    }
    return out[0..n];
}

// ---------------------------------------------------------------- writer

fn putOctal(dst: []u8, v: u64) void {
    // right-aligned octal, NUL terminated, zero padded
    @memset(dst, '0');
    dst[dst.len - 1] = 0;
    var x = v;
    var i = dst.len - 1;
    while (i > 0) {
        i -= 1;
        dst[i] = '0' + @as(u8, @intCast(x & 7));
        x >>= 3;
        if (x == 0) break;
    }
}

fn putNum(dst: []u8, v: u64) bool {
    const max: u64 = (@as(u64, 1) << @intCast((dst.len - 1) * 3)) - 1;
    if (v <= max) {
        putOctal(dst, v);
        return true;
    }
    return false;
}

fn typeByte(k: Kind) u8 {
    return switch (k) {
        .file, .other => '0',
        .hardlink => '1',
        .symlink => '2',
        .char => '3',
        .block => '4',
        .dir => '5',
        .fifo => '6',
    };
}

/// `Sink` must provide `fn writeAll(self: *Sink, bytes: []const u8) !void`.
pub fn Writer(comptime Sink: type) type {
    return struct {
        const Self = @This();
        sink: *Sink,
        body_left: u64 = 0,

        pub fn init(sink: *Sink) Self {
            return .{ .sink = sink };
        }

        fn rawHeader(self: *Self, name: []const u8, linkname: []const u8, typeflag: u8, e: Entry, size: u64) !void {
            var h: [block]u8 = @splat(0);
            const nlen: usize = @min(name.len, 100);
            @memcpy(h[0..nlen], name[0..nlen]);
            _ = putNum(h[100..108], e.mode & 0o7777);
            if (!putNum(h[108..116], e.uid)) putOctal(h[108..116], 0);
            if (!putNum(h[116..124], e.gid)) putOctal(h[116..124], 0);
            if (!putNum(h[124..136], size)) putOctal(h[124..136], 0);
            putOctal(h[136..148], @intCast(@max(e.mtime, 0)));
            h[156] = typeflag;
            const llen: usize = @min(linkname.len, 100);
            @memcpy(h[157 .. 157 + llen], linkname[0..llen]);
            @memcpy(h[257..263], "ustar\x00");
            h[263] = '0';
            h[264] = '0';
            _ = putNum(h[329..337], e.devmajor);
            _ = putNum(h[337..345], e.devminor);
            @memset(h[148..156], ' ');
            var sum: u32 = 0;
            for (h) |c| sum += c;
            // chksum field: 6 octal digits, NUL, space
            var sx: [7]u8 = undefined;
            putOctal(&sx, sum);
            @memcpy(h[148..154], sx[0..6]);
            h[154] = 0;
            h[155] = ' ';
            try self.sink.writeAll(&h);
        }

        fn paxRecord(buf: []u8, key: []const u8, val: []const u8) usize {
            // "<len> <key>=<val>\n" where len counts itself
            const base = key.len + val.len + 3; // space, '=', '\n'
            var digits: usize = 1;
            while (true) {
                const total = base + digits;
                var d: usize = 1;
                var t = total;
                while (t >= 10) : (t /= 10) d += 1;
                if (d == digits) break;
                digits = d;
            }
            const total = base + digits;
            const s = std.fmt.bufPrint(buf, "{d} {s}={s}\n", .{ total, key, val }) catch return 0;
            return s.len;
        }

        /// Write a header for `e` (with PAX records when needed). Follow with `data()` calls totalling e.size, then `endEntry()`.
        pub fn begin(self: *Self, a: Allocator, e: Entry) !void {
            var pax: std.ArrayList(u8) = .empty;
            defer pax.deinit(a);
            const has_body = e.kind == .file or e.kind == .other;
            const size: u64 = if (has_body) e.size else 0;
            var tmp: [4096]u8 = undefined;
            if (e.name.len > 100) {
                try paxRecordAlloc(a, &pax, "path", e.name);
            }
            if (e.linkname.len > 100) try paxRecordAlloc(a, &pax, "linkpath", e.linkname);
            if (size > 0o77777777777) {
                const s = std.fmt.bufPrint(&tmp, "{d}", .{size}) catch unreachable;
                try paxRecordAlloc(a, &pax, "size", s);
            }
            if (e.uid > 0o7777777) {
                const s = std.fmt.bufPrint(&tmp, "{d}", .{e.uid}) catch unreachable;
                try paxRecordAlloc(a, &pax, "uid", s);
            }
            if (e.gid > 0o7777777) {
                const s = std.fmt.bufPrint(&tmp, "{d}", .{e.gid}) catch unreachable;
                try paxRecordAlloc(a, &pax, "gid", s);
            }
            if (e.mtime_nsec != 0) {
                const s = std.fmt.bufPrint(&tmp, "{d}.{d:0>9}", .{ e.mtime, e.mtime_nsec }) catch unreachable;
                try paxRecordAlloc(a, &pax, "mtime", s);
            }
            for (e.xattrs) |x| {
                var kb: [256]u8 = undefined;
                const k = std.fmt.bufPrint(&kb, "SCHILY.xattr.{s}", .{x.name}) catch continue;
                try paxRecordAlloc(a, &pax, k, x.value);
            }
            if (pax.items.len > 0) {
                const px = Entry{ .mode = 0o644, .size = pax.items.len, .mtime = e.mtime };
                try self.rawHeader("PaxHeader", "", 'x', px, pax.items.len);
                try self.sink.writeAll(pax.items);
                const padn = (block - (pax.items.len % block)) % block;
                const zeros: [block]u8 = @splat(0);
                try self.sink.writeAll(zeros[0..padn]);
            }
            try self.rawHeader(e.name, e.linkname, typeByte(e.kind), e, size);
            self.body_left = size;
        }

        fn paxRecordAlloc(a: Allocator, list: *std.ArrayList(u8), key: []const u8, val: []const u8) !void {
            const need = key.len + val.len + 16;
            const old = list.items.len;
            try list.resize(a, old + need);
            const n = paxRecord(list.items[old..], key, val);
            list.shrinkRetainingCapacity(old + n);
        }

        pub fn data(self: *Self, bytes: []const u8) !void {
            try self.sink.writeAll(bytes);
            self.body_left -= bytes.len;
        }

        pub fn endEntry(self: *Self, total_size: u64) !void {
            const zeros: [block]u8 = @splat(0);
            const padn = (block - (total_size % block)) % block;
            try self.sink.writeAll(zeros[0..padn]);
        }

        pub fn finish(self: *Self) !void {
            const zeros: [block * 2]u8 = @splat(0);
            try self.sink.writeAll(&zeros);
        }
    };
}

// ---------------------------------------------------------------- tests

const SliceSrc = struct {
    data: []const u8,
    pos: usize = 0,
    pub fn read(self: *SliceSrc, buf: []u8) usize {
        const n = @min(buf.len, self.data.len - self.pos);
        @memcpy(buf[0..n], self.data[self.pos .. self.pos + n]);
        self.pos += n;
        return n;
    }
};

const ListSink = struct {
    list: std.ArrayList(u8) = .empty,
    pub fn writeAll(self: *ListSink, b: []const u8) !void {
        try self.list.appendSlice(std.testing.allocator, b);
    }
};

test "writer/reader roundtrip incl. long name, symlink, dir, hardlink, xattr" {
    var sink = ListSink{};
    defer sink.list.deinit(std.testing.allocator);
    var w = Writer(ListSink).init(&sink);
    const a = std.testing.allocator;
    const long = "very/" ++ ("long/" ++ "long/" ++ "long/" ++ "long/" ++ "long/" ++ "long/" ++ "long/" ++ "long/" ++ "long/" ++ "long/" ++ "long/" ++ "long/" ++ "long/" ++ "long/" ++ "long/" ++ "long/" ++ "long/" ++ "long/" ++ "long/" ++ "long/" ++ "long/") ++ "file.txt";
    try w.begin(a, .{ .name = "dir/", .kind = .dir, .mode = 0o755, .uid = 1000, .gid = 1000, .mtime = 1700000000 });
    try w.endEntry(0);
    try w.begin(a, .{ .name = long, .kind = .file, .mode = 0o644, .size = 5, .mtime = 1700000000, .mtime_nsec = 500, .xattrs = &.{.{ .name = "user.x", .value = "yz" }} });
    try w.data("hello");
    try w.endEntry(5);
    try w.begin(a, .{ .name = "ln", .kind = .symlink, .linkname = "dir", .mode = 0o777 });
    try w.endEntry(0);
    try w.begin(a, .{ .name = "hl", .kind = .hardlink, .linkname = long, .mode = 0o644 });
    try w.endEntry(0);
    try w.finish();

    var src = SliceSrc{ .data = sink.list.items };
    var rd = Reader(SliceSrc).init(&src);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const e1 = (try rd.next(arena.allocator())).?;
    try std.testing.expectEqual(Kind.dir, e1.kind);
    try std.testing.expectEqual(@as(u32, 1000), e1.uid);
    const e2 = (try rd.next(arena.allocator())).?;
    try std.testing.expectEqualStrings(long, e2.name);
    try std.testing.expectEqual(@as(u64, 5), e2.size);
    try std.testing.expectEqual(@as(u32, 500), e2.mtime_nsec);
    try std.testing.expectEqual(@as(usize, 1), e2.xattrs.len);
    try std.testing.expectEqualStrings("user.x", e2.xattrs[0].name);
    try std.testing.expectEqualStrings("yz", e2.xattrs[0].value);
    var body: [16]u8 = undefined;
    const n = try rd.readBody(&body);
    try std.testing.expectEqualStrings("hello", body[0..n]);
    const e3 = (try rd.next(arena.allocator())).?;
    try std.testing.expectEqual(Kind.symlink, e3.kind);
    try std.testing.expectEqualStrings("dir", e3.linkname);
    const e4 = (try rd.next(arena.allocator())).?;
    try std.testing.expectEqual(Kind.hardlink, e4.kind);
    try std.testing.expectEqualStrings(long, e4.linkname);
    try std.testing.expect((try rd.next(arena.allocator())) == null);
}

test "reader skips unread bodies and rejects bad checksum" {
    var sink = ListSink{};
    defer sink.list.deinit(std.testing.allocator);
    var w = Writer(ListSink).init(&sink);
    const a = std.testing.allocator;
    try w.begin(a, .{ .name = "a", .size = 700, .mode = 0o600 });
    try w.data(&@as([700]u8, @splat('x')));
    try w.endEntry(700);
    try w.begin(a, .{ .name = "b", .size = 1, .mode = 0o600 });
    try w.data("y");
    try w.endEntry(1);
    try w.finish();
    var src = SliceSrc{ .data = sink.list.items };
    var rd = Reader(SliceSrc).init(&src);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = (try rd.next(arena.allocator())).?;
    const e = (try rd.next(arena.allocator())).?; // skips the 700 byte body
    try std.testing.expectEqualStrings("b", e.name);

    sink.list.items[3] ^= 0xff; // corrupt first header name
    var src2 = SliceSrc{ .data = sink.list.items };
    var rd2 = Reader(SliceSrc).init(&src2);
    try std.testing.expectError(error.BadChecksum, rd2.next(arena.allocator()));
}

test "embedded NUL cannot truncate an extended archive path" {
    for ([_]u8{ 'x', 'L', 'K' }) |kind| {
        var sink = ListSink{};
        defer sink.list.deinit(std.testing.allocator);
        var w = Writer(ListSink).init(&sink);
        const body = if (kind == 'x') "16 path=..\x00/foo\n" else "..\x00/foo\x00";
        try w.rawHeader("extended", "", kind, .{}, body.len);
        try sink.writeAll(body);
        try w.endEntry(body.len);
        try w.rawHeader("file", "", '0', .{}, 0);
        var src = SliceSrc{ .data = sink.list.items };
        var rd = Reader(SliceSrc).init(&src);
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectError(error.BadHeader, rd.next(arena.allocator()));
    }
}

test "hostile pax records and oversized numeric fields do not trap" {
    for ([_]struct { kind: u8, body: []const u8 }{
        .{ .kind = 'x', .body = "1 path=x\n" },
        .{ .kind = 'x', .body = "18446744073709551615 path=x\n" },
        .{ .kind = 'x', .body = "19 uid=99999999999\n" },
        .{ .kind = 'x', .body = "28 size=18446744073709551615\n" },
    }) |c| {
        var sink = ListSink{};
        defer sink.list.deinit(std.testing.allocator);
        var w = Writer(ListSink).init(&sink);
        try w.rawHeader("extended", "", c.kind, .{}, c.body.len);
        try sink.writeAll(c.body);
        try w.endEntry(c.body.len);
        try w.rawHeader("file", "", '0', .{}, 0);
        var src = SliceSrc{ .data = sink.list.items };
        var rd = Reader(SliceSrc).init(&src);
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const got = rd.next(arena.allocator());
        // the uid record is exactly 19 bytes, so it must reach the numeric conversion and be rejected
        if (std.mem.startsWith(u8, c.body, "19 uid=")) try std.testing.expectError(error.BadHeader, got) else _ = got catch {};
    }
}

test "cleanPath blocks traversal" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("a/b", cleanPath("./a//b/", &buf).?);
    try std.testing.expectEqualStrings("b", cleanPath("a/../b", &buf).?);
    try std.testing.expect(cleanPath("../etc/passwd", &buf) == null);
    try std.testing.expect(cleanPath("a/../../x", &buf) == null);
    try std.testing.expectEqualStrings("etc/passwd", cleanPath("/etc/passwd", &buf).?);
    try std.testing.expectEqualStrings("", cleanPath(".", &buf).?);
}

test "base256 numbers" {
    var f: [12]u8 = @splat(0);
    f[0] = 0x80;
    f[11] = 0x10;
    f[10] = 0x01;
    try std.testing.expectEqual(@as(u64, 0x110), try parseNum(&f));
}

test "pax allocation failure is reported, not a truncated name" {
    var sink = ListSink{};
    defer sink.list.deinit(std.testing.allocator);
    var w = Writer(ListSink).init(&sink);
    const long: [160]u8 = @splat('a');
    var fa = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, w.begin(fa.allocator(), .{ .name = &long, .kind = .dir }));
}
