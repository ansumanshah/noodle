//! Layer store: unpack (gzip/zstd/tar) into overlay lowerdirs, compute diff_id, layer_get.
const std = @import("std");
const sys = @import("sys.zig");
const util = @import("util.zig");
const tarfs = @import("tarfs.zig");
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

/// std.Io.Reader over a file descriptor, optionally limited to `remaining` bytes.
pub const FdIn = struct {
    fd: isize,
    remaining: ?u64,
    reader: Reader,
    blob_hash: ?*std.crypto.hash.sha2.Sha256 = null,

    pub fn init(fd: isize, buf: []u8, limit: ?u64) FdIn {
        return .{
            .fd = fd,
            .remaining = limit,
            .reader = .{ .vtable = &.{ .stream = stream }, .buffer = buf, .seek = 0, .end = 0 },
        };
    }

    fn stream(r: *Reader, w: *Writer, limit: std.Io.Limit) Reader.StreamError!usize {
        const self: *FdIn = @alignCast(@fieldParentPtr("reader", r));
        var dest = limit.slice(try w.writableSliceGreedy(1));
        if (self.remaining) |rem| {
            if (rem == 0) return error.EndOfStream;
            if (dest.len > rem) dest = dest[0..@intCast(rem)];
        }
        while (true) {
            const n = sys.read(self.fd, dest);
            if (n == -sys.E.INTR) continue;
            if (n < 0) return error.ReadFailed;
            if (n == 0) return error.EndOfStream;
            if (self.remaining) |*rem| rem.* -= @as(u64, @intCast(n));
            if (self.blob_hash) |hash| hash.update(dest[0..@intCast(n)]);
            w.advance(@intCast(n));
            return @intCast(n);
        }
    }
};

/// tar source that hashes every byte it hands out (the uncompressed stream => diff_id).
pub const HashSrc = struct {
    inner: *Reader,
    hasher: std.crypto.hash.sha2.Sha256 = std.crypto.hash.sha2.Sha256.init(.{}),
    total: u64 = 0,
    failed: bool = false,

    pub fn read(self: *HashSrc, buf: []u8) usize {
        const n = self.inner.readSliceShort(buf) catch {
            self.failed = true;
            return 0;
        };
        self.hasher.update(buf[0..n]);
        self.total += n;
        return n;
    }
};

pub const Media = enum { gzip, zstd, tar };

pub fn parseMedia(s: []const u8) ?Media {
    if (std.mem.eql(u8, s, "gzip")) return .gzip;
    if (std.mem.eql(u8, s, "zstd")) return .zstd;
    if (std.mem.eql(u8, s, "tar")) return .tar;
    return null;
}

pub const UnpackResult = struct { diff_id: [71]u8, bytes: u64 };

const store = util.base ++ "/layers/verified-v1";

pub fn validDigest(d: []const u8) bool {
    if (d.len != 71 or !std.mem.startsWith(u8, d, "sha256:")) return false;
    for (d[7..]) |c| if (!(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'))) return false;
    return true;
}

pub fn layerPath(hex: []const u8) [:0]u8 {
    return util.zf("{s}/{s}/published/root", .{ store, hex });
}

fn verified(base_dir: []const u8, hex: []const u8, expected: ?[]const u8) bool {
    const fd = sys.open(util.zf("{s}/{s}/published/diff-id", .{ base_dir, hex }).ptr, sys.O.RDONLY | sys.O.NOFOLLOW, 0);
    if (fd < 0) return false;
    defer sys.close(fd);
    var buf: [72]u8 = undefined;
    if (sys.readAll(fd, &buf) != 71 or !validDigest(buf[0..71])) return false;
    if (expected) |diff| if (!std.mem.eql(u8, buf[0..71], diff)) return false;
    const root = sys.open(util.zf("{s}/{s}/published/root", .{ base_dir, hex }).ptr, sys.O.PATH | sys.O.DIRECTORY | sys.O.NOFOLLOW, 0);
    if (root < 0) return false;
    sys.close(root);
    return true;
}

pub fn has(hex: []const u8) bool {
    return verified(store, hex, null);
}

pub fn matches(hex: []const u8, diff: []const u8) bool {
    return verified(store, hex, diff);
}

pub const UnpackError = error{ BadLayer, Sys, Unsafe, OutOfMemory };

pub fn unpack(fd: isize, size: u64, media: Media, digest: []const u8, expected_diff: []const u8) UnpackError!UnpackResult {
    return unpackAt(store, fd, size, media, digest, expected_diff);
}

fn unpackAt(base_dir: []const u8, fd: isize, size: u64, media: Media, digest: []const u8, expected_diff: []const u8) UnpackError!UnpackResult {
    if (!validDigest(digest) or !validDigest(expected_diff) or size == 0) return error.BadLayer;
    const hex = digest[7..];
    const layer = util.zf("{s}/{s}", .{ base_dir, hex });
    if (util.mkdirp(layer, 0o700) < 0) return error.Sys;
    const lock = sys.open(layer.ptr, sys.O.DIRECTORY | sys.O.RDONLY, 0);
    if (lock < 0) return error.Sys;
    defer sys.close(lock);
    if (sys.sc(.flock, @intCast(lock), 2, 0, 0, 0, 0) < 0) return error.Sys;
    const tmp = util.zf("{s}/incoming", .{layer});
    const dest = util.zf("{s}/published", .{layer});
    if (util.rmTreeChecked(lock, "incoming") < 0) return error.Sys;
    const lower = util.zf("{s}/root", .{tmp});
    if (util.mkdirp(tmp, 0o700) < 0 or sys.mkdirat(sys.AT_FDCWD, lower.ptr, 0o755) < 0) return error.Sys;
    defer _ = util.rmTreeChecked(lock, "incoming");
    const root = sys.open(lower.ptr, sys.O.RDONLY | sys.O.DIRECTORY, 0);
    if (root < 0) return error.Sys;
    defer sys.close(root);

    const in_buf = util.arena().alloc(u8, 64 * 1024) catch return error.OutOfMemory;
    var in = FdIn.init(fd, in_buf, size);
    var blob_hash = std.crypto.hash.sha2.Sha256.init(.{});
    in.blob_hash = &blob_hash;

    var src: HashSrc = undefined;
    var flate_buf: ?[]u8 = null;
    var flate: std.compress.flate.Decompress = undefined;
    var zstd: std.compress.zstd.Decompress = undefined;
    var zstd_mem: ?[]u8 = null;
    defer if (zstd_mem) |mem| sys.munmap(mem.ptr, mem.len);
    switch (media) {
        .tar => src = .{ .inner = &in.reader },
        .gzip => {
            flate_buf = util.arena().alloc(u8, std.compress.flate.max_window_len) catch return error.OutOfMemory;
            flate = std.compress.flate.Decompress.init(&in.reader, .gzip, flate_buf.?);
            src = .{ .inner = &flate.reader };
        },
        .zstd => {
            const window: u32 = 32 << 20;
            const need = window + std.compress.zstd.block_size_max;
            const mem = sys.mmapAnon(need) orelse return error.OutOfMemory;
            zstd_mem = mem[0..need];
            zstd = std.compress.zstd.Decompress.init(&in.reader, zstd_mem.?, .{ .window_len = window });
            src = .{ .inner = &zstd.reader };
        },
    }

    tarfs.extractAll(&src, root, true) catch |e| {
        return switch (e) {
            error.Sys => error.Sys,
            error.Unsafe => error.Unsafe,
            else => error.BadLayer,
        };
    };
    if (media == .gzip and flate.state != .end) return error.BadLayer;
    if (media == .zstd and zstd.state != .new_frame) return error.BadLayer;
    if (src.failed or in.remaining.? != 0 or in.reader.bufferedLen() != 0) return error.BadLayer;
    var extra: [1]u8 = undefined;
    if (sys.readAll(fd, &extra) != 0) return error.BadLayer;

    var res = UnpackResult{ .diff_id = undefined, .bytes = src.total };
    var blob_id: [71]u8 = undefined;
    _ = std.fmt.bufPrint(&blob_id, "sha256:{x}", .{&blob_hash.finalResult()}) catch unreachable;
    _ = std.fmt.bufPrint(&res.diff_id, "sha256:{x}", .{&src.hasher.finalResult()}) catch unreachable;
    if (!std.mem.eql(u8, &blob_id, digest) or !std.mem.eql(u8, &res.diff_id, expected_diff)) return error.BadLayer;
    if (verified(base_dir, hex, expected_diff)) return res;
    if (util.writeFile(util.zf("{s}/diff-id", .{tmp}).ptr, &res.diff_id, 0o600) < 0) return error.Sys;

    // Readers see a complete bundle even if a damaged verification record must be replaced.
    try publish(lock, tmp.ptr, dest.ptr, util.exists(dest.ptr), PublishOps);
    return res;
}

const PublishOps = struct {
    fn flush(fd: isize) isize { return sys.syncfs(fd); }
    fn rename(tmp: [*:0]const u8, dest: [*:0]const u8, replace: bool) isize {
        if (replace) return sys.sc(.renameat2, @bitCast(sys.AT_FDCWD), @intFromPtr(tmp), @bitCast(sys.AT_FDCWD), @intFromPtr(dest), 2, 0);
        return sys.renameat(sys.AT_FDCWD, tmp, sys.AT_FDCWD, dest);
    }
};

fn publish(lock: isize, tmp: [*:0]const u8, dest: [*:0]const u8, replace: bool, comptime Ops: type) UnpackError!void {
    if (Ops.flush(lock) < 0) return error.Sys;
    if (Ops.rename(tmp, dest, replace) < 0) return error.Sys;
    if (Ops.flush(lock) < 0) return error.Sys;
}

pub fn remove(hex: []const u8) bool {
    const dir = util.zf("{s}/{s}", .{ store, hex });
    const lock = sys.open(dir.ptr, sys.O.DIRECTORY | sys.O.RDONLY, 0);
    if (lock >= 0) {
        defer sys.close(lock);
        if (sys.sc(.flock, @intCast(lock), 2 | 4, 0, 0, 0, 0) < 0) return false;
        if (util.rmTreeChecked(lock, "published") < 0) return false;
        if (util.rmTreeChecked(lock, "incoming") < 0) return false;
    } else if (lock != -sys.E.NOENT) return false;
    return util.rmTreePathChecked(util.zf("{s}/layers/{s}", .{ util.base, hex }).ptr) >= 0;
}

test "strict layer digest syntax" {
    try std.testing.expect(validDigest("sha256:" ++ "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"));
    try std.testing.expect(!validDigest("sha256:" ++ "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdeF"));
    try std.testing.expect(!validDigest("sha256:" ++ "000000000000000000000000000000000000000000000000000000000000000"));
    try std.testing.expect(!validDigest("sha512:" ++ "0000000000000000000000000000000000000000000000000000000000000000"));
}

test "uncompressed stream hashes every byte across short reads" {
    var reader: Reader = .fixed("abc");
    var src = HashSrc{ .inner = &reader };
    var buf: [2]u8 = undefined;
    try std.testing.expectEqual(2, src.read(&buf));
    try std.testing.expectEqual(1, src.read(&buf));
    try std.testing.expectEqual(0, src.read(&buf));
    try std.testing.expectEqual(3, src.total);
    try std.testing.expect(!src.failed);
    const actual = std.fmt.bytesToHex(src.hasher.finalResult(), .lower);
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", &actual);
}

test "verified layer bundles reject mismatched streams and permit retry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    util.initArena();
    const base_dir = util.zf("/proc/self/fd/{d}/verified-v1", .{tmp.dir.handle});
    const plain: [1024]u8 = @splat(0);
    const compressed = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\xff\x63\x60\x18\x05\xa3\x60\x14\x8c\x54\x00\x00\x2e\xaf\xb5\xef\x00\x04\x00\x00";
    const zstd = "\x28\xb5\x2f\xfd\x04\x58\x4d\x00\x00\x10\x00\x00\x01\x00\xfb\x2b\x80\x05\xcd\xac\x85\xf0";
    const check = struct {
        fn id(data: []const u8) [71]u8 {
            var hash: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(data, &hash, .{});
            var result: [71]u8 = undefined;
            _ = std.fmt.bufPrint(&result, "sha256:{x}", .{&hash}) catch unreachable;
            return result;
        }
        fn run(dir: isize, base_dir_: []const u8, data: []const u8, size: u64, media: Media, blob: []const u8, diff: []const u8) !UnpackResult {
            const fd = sys.openat(dir, "input", sys.O.RDWR | sys.O.CREAT | sys.O.TRUNC, 0o600);
            if (fd < 0) return error.Sys;
            defer sys.close(fd);
            if (sys.writeAll(fd, data) < 0 or sys.lseek(fd, 0, 0) < 0) return error.Sys;
            return unpackAt(base_dir_, fd, size, media, blob, diff);
        }
    };
    const diff = check.id(&plain);
    const wrong = check.id("wrong");
    // Incorrect contents under the expected digest must never strand a deep partial tree.
    var deep_path: [300]u8 = undefined;
    for (0..150) |i| @memcpy(deep_path[i * 2 ..][0..2], "d/");
    var encoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer encoded.deinit();
    var writer = @import("tar").Writer(std.Io.Writer).init(&encoded.writer);
    try writer.begin(util.arena(), .{ .name = &deep_path, .kind = .dir, .mode = 0o755 });
    try writer.endEntry(0);
    const sentinel = util.zf("/proc/self/fd/{d}/sentinel", .{tmp.dir.handle});
    try std.testing.expect(util.writeFile(sentinel.ptr, "keep", 0o600) >= 0);
    try writer.begin(util.arena(), .{ .name = "outside", .kind = .symlink, .linkname = sentinel });
    try writer.endEntry(0);
    try writer.finish();
    const bad_tar = encoded.written();
    try std.testing.expectError(error.BadLayer, check.run(tmp.dir.handle, base_dir, bad_tar, bad_tar.len, .tar, &diff, &diff));
    try std.testing.expect(!util.exists(util.zf("{s}/{s}/incoming", .{ base_dir, diff[7..] }).ptr));
    try std.testing.expect(util.exists(sentinel.ptr));
    try std.testing.expect(!verified(base_dir, diff[7..], null));

    for ([_]Media{ .tar, .gzip, .zstd }, [_][]const u8{ &plain, compressed, zstd }) |media, bytes| {
        const blob = check.id(bytes);
        if (media != .tar) {
            const partial = bytes[0 .. bytes.len - 1];
            const truncated = check.id(partial);
            try std.testing.expectError(error.BadLayer, check.run(tmp.dir.handle, base_dir, partial, partial.len, media, &truncated, &diff));
            try std.testing.expect(!verified(base_dir, truncated[7..], null));
            const excess = try std.testing.allocator.alloc(u8, bytes.len + 5);
            defer std.testing.allocator.free(excess);
            @memcpy(excess[0..bytes.len], bytes);
            @memcpy(excess[bytes.len..], "extra");
            const trailing = check.id(excess);
            try std.testing.expectError(error.BadLayer, check.run(tmp.dir.handle, base_dir, excess, excess.len, media, &trailing, &diff));
            try std.testing.expect(!verified(base_dir, trailing[7..], null));
        }
        const dir = tmp.dir.handle;
        const legacy = util.zf("/proc/self/fd/{d}/{s}", .{ dir, blob[7..] });
        try std.testing.expect(util.mkdirp(legacy, 0o755) >= 0);
        try std.testing.expect(!verified(base_dir, blob[7..], null));
        try std.testing.expectError(error.BadLayer, check.run(dir, base_dir, bytes, bytes.len, media, &wrong, &diff));
        try std.testing.expectError(error.BadLayer, check.run(dir, base_dir, bytes, bytes.len, media, &blob, &wrong));
        try std.testing.expectError(error.BadLayer, check.run(dir, base_dir, bytes, bytes.len + 1, media, &blob, &diff));
        try std.testing.expectError(error.BadLayer, check.run(dir, base_dir, bytes, bytes.len - 1, media, &blob, &diff));
        try std.testing.expect(!verified(base_dir, blob[7..], null));
        const result = try check.run(dir, base_dir, bytes, bytes.len, media, &blob, &diff);
        try std.testing.expectEqualStrings(&diff, &result.diff_id);
        try std.testing.expectEqual(plain.len, result.bytes);
        try std.testing.expect(verified(base_dir, blob[7..], &diff));
        try std.testing.expect(!verified(base_dir, blob[7..], &wrong));
        try std.testing.expectError(error.BadLayer, check.run(dir, base_dir, bytes, bytes.len, media, &blob, &wrong));
        try std.testing.expect(verified(base_dir, blob[7..], &diff));
        const marker = util.zf("{s}/{s}/published/diff-id", .{ base_dir, blob[7..] });
        try std.testing.expect(util.writeFile(marker.ptr, "damaged", 0o600) >= 0);
        try std.testing.expect(!verified(base_dir, blob[7..], null));
        _ = try check.run(dir, base_dir, bytes, bytes.len, media, &blob, &diff);
        try std.testing.expect(verified(base_dir, blob[7..], &diff));
    }
}


test "strict layer digest publication flushes before and after rename" {
    const Fake = struct {
        var calls: [3]u8 = undefined;
        var count: usize = 0;
        var fail_at: usize = 0;
        fn reset(failure: usize) void { count = 0; fail_at = failure; }
        fn flush(_: isize) isize {
            calls[count] = 's'; count += 1;
            return if (count == fail_at) -1 else 0;
        }
        fn rename(_: [*:0]const u8, _: [*:0]const u8, _: bool) isize {
            calls[count] = 'r'; count += 1;
            return if (count == fail_at) -1 else 0;
        }
    };
    for ([_]bool{ false, true }) |replace| {
        Fake.reset(0);
        try publish(0, "incoming", "published", replace, Fake);
        try std.testing.expectEqualStrings("srs", Fake.calls[0..Fake.count]);
        for (1..4) |failure| {
            Fake.reset(failure);
            try std.testing.expectError(error.Sys, publish(0, "incoming", "published", replace, Fake));
            try std.testing.expectEqualStrings("srs"[0..failure], Fake.calls[0..Fake.count]);
        }
    }
}
