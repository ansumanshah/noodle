//! Shared helpers: arena, formatted C strings, logging to the console, small fs utilities.
const std = @import("std");
const sys = @import("sys.zig");

test {
    // Keep the attach policy covered by the normal native utility test target.
    _ = @import("attach_input.zig").Input;
}

pub const version = "26.11.7";
pub const base = "/var/lib/noodle";

/// True in the workload VM (kernel command line `noodle.role=workload`).
/// Only there may a container be privileged or unconfined.
pub var workload = false;
/// The `host` virtiofs share is mounted. In the workload VM only when the host turned on Kubernetes shared folders; its share list holds only folders the host approved.
pub var host_shares = false;

// ---------------------------------------------------------------- arena
var arena_mem: ?[*]u8 = null;
const arena_size: usize = 256 * 1024 * 1024; // virtual, committed lazily by the kernel
var fba: std.heap.FixedBufferAllocator = undefined;

pub fn initArena() void {
    arena_mem = sys.mmapAnon(arena_size);
    if (arena_mem) |m| {
        fba = std.heap.FixedBufferAllocator.init(m[0..arena_size]);
    } else {
        fba = std.heap.FixedBufferAllocator.init(&fallback);
    }
}
var fallback: [1 << 20]u8 = undefined;

pub fn arena() std.mem.Allocator {
    return fba.allocator();
}
/// Arena position to rewind to after scratch allocations in a long loop; nothing allocated after the mark may outlive the rewind.
pub fn arenaMark() usize {
    return fba.end_index;
}
pub fn arenaRewind(mark: usize) void {
    fba.end_index = mark;
}
pub fn resetArena() void {
    noteArena();
    fba.reset();
    // give pages back if a request ballooned (idle RSS matters)
    if (high_water > (4 << 20)) {
        if (arena_mem) |m| _ = sys.sc(.madvise, @intFromPtr(m), @min(high_water, arena_size), 4, 0, 0, 0); // MADV_DONTNEED
        high_water = 0;
    }
}
var high_water: usize = 0;
pub fn noteArena() void {
    if (fba.end_index > high_water) high_water = fba.end_index;
}

// ---------------------------------------------------------------- strings
/// printf into the arena, NUL terminated.
pub fn zf(comptime fmt: []const u8, args: anytype) [:0]u8 {
    const a = arena();
    const n = std.fmt.count(fmt, args);
    const buf = a.alloc(u8, n + 1) catch return @constCast("");
    _ = std.fmt.bufPrint(buf, fmt, args) catch {};
    buf[n] = 0;
    return buf[0..n :0];
}
pub fn dupeZ(a: std.mem.Allocator, s: []const u8) ![:0]u8 {
    const out = try a.alloc(u8, s.len + 1);
    @memcpy(out[0..s.len], s);
    out[s.len] = 0;
    return out[0..s.len :0];
}
pub fn zdup(s: []const u8) [:0]u8 {
    return dupeZ(arena(), s) catch @constCast("");
}
pub fn sf(comptime fmt: []const u8, args: anytype) []u8 {
    return zf(fmt, args);
}

pub fn contains(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

// ---------------------------------------------------------------- logging
pub var log_fd: isize = -1;

pub fn openLog() void {
    log_fd = sys.open("/dev/hvc0", sys.O.WRONLY | sys.O.NOCTTY, 0);
    if (log_fd < 0) {
        _ = sys.mknodat(sys.AT_FDCWD, "/dev/hvc0", sys.S.IFCHR | 0o600, (229 << 8) | 0);
        log_fd = sys.open("/dev/hvc0", sys.O.WRONLY | sys.O.NOCTTY, 0);
    }
    if (log_fd < 0) log_fd = sys.open("/dev/console", sys.O.WRONLY | sys.O.NOCTTY, 0);
}

pub fn log(comptime fmt: []const u8, args: anytype) void {
    if (log_fd < 0) return;
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "noodle-init: " ++ fmt ++ "\n", args) catch buf[0..0];
    _ = sys.write(log_fd, s);
}

pub fn logErr(what: []const u8, rc: isize) void {
    log("{s}: errno {d}", .{ what, -rc });
}

// ---------------------------------------------------------------- fs helpers
pub fn mkdirp(path: []const u8, mode: usize) isize {
    var buf: [4096]u8 = undefined;
    if (path.len >= buf.len) return -sys.E.INVAL;
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '/') {
            @memcpy(buf[0..i], path[0..i]);
            buf[i] = 0;
            const rc = sys.mkdirat(sys.AT_FDCWD, @ptrCast(&buf), mode);
            if (rc < 0 and rc != -sys.E.EXIST) return rc;
        }
    }
    return 0;
}

pub fn exists(path: [*:0]const u8) bool {
    var st: sys.Stat = undefined;
    return sys.fstatat(sys.AT_FDCWD, path, &st, sys.AT_SYMLINK_NOFOLLOW) >= 0;
}

pub fn writeFile(path: [*:0]const u8, data: []const u8, mode: usize) isize {
    const fd = sys.open(path, sys.O.WRONLY | sys.O.CREAT | sys.O.TRUNC, mode);
    if (fd < 0) return fd;
    defer sys.close(fd);
    return sys.writeAll(fd, data);
}

/// Write a short string to a procfs/sysfs/cgroup file (no create).
pub fn writeSys(path: [*:0]const u8, data: []const u8) isize {
    const fd = sys.open(path, sys.O.WRONLY, 0);
    if (fd < 0) return fd;
    defer sys.close(fd);
    const rc = sys.write(fd, data);
    return if (rc < 0) rc else 0;
}

/// Read a whole (small) file into the arena.
pub fn readFile(path: [*:0]const u8, max: usize) ?[]u8 {
    return readFileKind(path, max, false);
}

/// Image-owned account files must never block on a FIFO or read a device stream.
/// Check the opened fd, so symlinks and path replacements cannot bypass the check.
pub fn readRegularFile(path: [*:0]const u8, max: usize) ?[]u8 {
    return readFileKind(path, max, true);
}

fn readFileKind(path: [*:0]const u8, max: usize, comptime regular_only: bool) ?[]u8 {
    const fd = sys.open(path, sys.O.RDONLY | (if (regular_only) sys.O.NONBLOCK else 0), 0);
    if (fd < 0) return null;
    defer sys.close(fd);
    if (regular_only) {
        var st: sys.Stat = undefined;
        if (sys.fstat(fd, &st) < 0 or (st.mode & sys.S.IFMT) != sys.S.IFREG) return null;
    }
    const a = arena();
    var cap: usize = 4096;
    var buf = a.alloc(u8, cap) catch return null;
    var len: usize = 0;
    while (true) {
        if (len == cap) {
            if (cap >= max) break;
            const nb = a.alloc(u8, cap * 2) catch return null;
            @memcpy(nb[0..len], buf[0..len]);
            buf = nb;
            cap *= 2;
        }
        const n = sys.read(fd, buf[len..]);
        if (n < 0) {
            if (n == -sys.E.INTR) continue;
            return null;
        }
        if (n == 0) break;
        len += @intCast(n);
    }
    return buf[0..len];
}

const RemoveDir = struct {
    fd: isize,
    name: [256]u8 = undefined,
    entries: [512]u8 align(8) = undefined,
    off: usize = 0,
    len: usize = 0,
};

fn removeOrDescend(parent: isize, name: [*:0]const u8, dirs: *std.ArrayList(RemoveDir)) isize {
    // unlink never follows the final component, including symlinks to directories.
    const rc = sys.unlinkat(parent, name, 0);
    if (rc == -sys.E.NOENT) return 0;
    if (rc != -sys.E.ISDIR) return rc;
    const fd = sys.openat2(parent, name, sys.O.RDONLY | sys.O.DIRECTORY | sys.O.NOFOLLOW, 0, 0x01); // RESOLVE_NO_XDEV
    if (fd == -sys.E.NOENT) return 0;
    if (fd < 0) return fd;
    var frame = RemoveDir{ .fd = fd };
    const len = std.mem.len(name);
    @memcpy(frame.name[0 .. len + 1], name[0 .. len + 1]);
    dirs.append(std.heap.page_allocator, frame) catch {
        sys.close(fd);
        return -sys.E.NOMEM;
    };
    return 0;
}

/// Delete one named entry beneath a pinned parent. Absence is success. A mount,
/// permission failure, concurrent replacement, or exhausted resource returns errno.
pub fn rmTreeChecked(dirfd: isize, name: [*:0]const u8) isize {
    const leaf = std.mem.span(name);
    if (!validChildName(leaf) or leaf.len > 255) return -sys.E.INVAL;
    var dirs: std.ArrayList(RemoveDir) = .empty;
    defer {
        for (dirs.items) |frame| sys.close(frame.fd);
        dirs.deinit(std.heap.page_allocator);
    }
    const start = removeOrDescend(dirfd, name, &dirs);
    if (start < 0) return start;

    while (dirs.items.len != 0) {
        const top = &dirs.items[dirs.items.len - 1];
        if (top.off == top.len) {
            const n = sys.getdents64(top.fd, &top.entries);
            if (n == -sys.E.INTR) continue;
            if (n < 0) return n;
            if (n == 0) {
                const parent = if (dirs.items.len == 1) dirfd else dirs.items[dirs.items.len - 2].fd;
                const rc = sys.unlinkat(parent, @ptrCast(&top.name), sys.AT_REMOVEDIR);
                if (rc < 0 and rc != -sys.E.NOENT) return rc;
                sys.close(top.fd);
                _ = dirs.pop();
                continue;
            }
            top.off = 0;
            top.len = @intCast(n);
        }
        const off = top.off;
        top.off += std.mem.readInt(u16, top.entries[off + 16 ..][0..2], .little);
        const entry: [*:0]const u8 = @ptrCast(&top.entries[off + 19]);
        if (!validChildName(std.mem.span(entry))) continue;
        const rc = removeOrDescend(top.fd, entry, &dirs);
        if (rc < 0) return rc;
    }
    return 0;
}

pub fn rmTree(dirfd: isize, name: [*:0]const u8, _: u32) void {
    _ = rmTreeChecked(dirfd, name);
}

pub fn rmTreePathChecked(path: [*:0]const u8) isize {
    const full = std.mem.span(path);
    if (!std.fs.path.isAbsolutePosix(full)) return -sys.E.INVAL;
    const parent = std.fs.path.dirnamePosix(full) orelse return -sys.E.INVAL;
    const leaf = std.fs.path.basenamePosix(full);
    if (!validChildName(leaf) or leaf.len > 255) return -sys.E.INVAL;
    var parent_buf: [4096]u8 = undefined;
    var name_buf: [256]u8 = undefined;
    const parent_z = std.fmt.bufPrintSentinel(&parent_buf, "{s}", .{parent}, 0) catch return -sys.E.INVAL;
    const leaf_z = std.fmt.bufPrintSentinel(&name_buf, "{s}", .{leaf}, 0) catch return -sys.E.INVAL;
    const fd = sys.open(parent_z.ptr, sys.O.PATH | sys.O.DIRECTORY, 0);
    if (fd == -sys.E.NOENT) return 0;
    if (fd < 0) return fd;
    defer sys.close(fd);
    return rmTreeChecked(fd, leaf_z.ptr);
}

pub fn rmTreePath(path: [*:0]const u8) void {
    _ = rmTreePathChecked(path);
}

/// Iterate directory entries. Calls f(ctx, name, d_type) for each except . and ..
pub fn forEachDirent(fd: isize, ctx: anytype, comptime f: fn (@TypeOf(ctx), []const u8, u8) void) void {
    var buf: [4096]u8 align(8) = undefined;
    while (true) {
        const n = sys.getdents64(fd, &buf);
        if (n <= 0) break;
        var off: usize = 0;
        while (off < @as(usize, @intCast(n))) {
            const reclen = std.mem.readInt(u16, buf[off + 16 ..][0..2], .little);
            const dtype = buf[off + 18];
            const nm: [*:0]const u8 = @ptrCast(&buf[off + 19]);
            const s = std.mem.span(nm);
            if (!(std.mem.eql(u8, s, ".") or std.mem.eql(u8, s, ".."))) f(ctx, s, dtype);
            off += reclen;
        }
    }
}

/// An IPv6 literal with optional `::`. No zone, no embedded IPv4: the host only sends plain literals.
pub fn parseIp6(s: []const u8) ?[16]u8 {
    if (s.len < 2 or s.len > 39) return null;
    var head: [8]u16 = undefined;
    var tail: [8]u16 = undefined;
    var nh: usize = 0;
    var nt: usize = 0;
    const gap = std.mem.indexOf(u8, s, "::");
    const parts = struct {
        fn run(text: []const u8, out: *[8]u16, n: *usize) bool {
            if (text.len == 0) return true;
            var it = std.mem.splitScalar(u8, text, ':');
            while (it.next()) |g| {
                if (g.len == 0 or g.len > 4 or n.* == 8) return false;
                out[n.*] = std.fmt.parseInt(u16, g, 16) catch return false;
                if (g[0] == '+' or g[0] == '-') return false;
                n.* += 1;
            }
            return true;
        }
    };
    if (gap) |g| {
        if (std.mem.indexOfPos(u8, s, g + 1, "::") != null) return null;
        if (!parts.run(s[0..g], &head, &nh) or !parts.run(s[g + 2 ..], &tail, &nt)) return null;
        if (nh + nt > 7) return null;
    } else {
        if (!parts.run(s, &head, &nh) or nh != 8) return null;
    }
    var out: [16]u8 = @splat(0);
    for (head[0..nh], 0..) |v, i| std.mem.writeInt(u16, out[i * 2 ..][0..2], v, .big);
    for (tail[0..nt], 0..) |v, i| std.mem.writeInt(u16, out[(8 - nt + i) * 2 ..][0..2], v, .big);
    return out;
}

/// `ip` with everything past `prefix` bits cleared.
pub fn maskIp6(ip: [16]u8, prefix: u8) [16]u8 {
    var out: [16]u8 = @splat(0);
    for (0..16) |i| {
        const bits: i32 = @as(i32, prefix) - @as(i32, @intCast(i * 8));
        const m: u8 = if (bits >= 8) 0xff else if (bits <= 0) 0 else @as(u8, 0xff) << @intCast(8 - bits);
        out[i] = ip[i] & m;
    }
    return out;
}

pub fn parseIp4(s: []const u8) ?[4]u8 {
    var out: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, s, '.');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i >= 4) return null;
        out[i] = std.fmt.parseInt(u8, part, 10) catch return null;
    }
    return if (i == 4) out else null;
}

pub fn parseMac(s: []const u8) ?[6]u8 {
    var out: [6]u8 = undefined;
    var it = std.mem.splitScalar(u8, s, ':');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i >= 6) return null;
        out[i] = std.fmt.parseInt(u8, part, 16) catch return null;
    }
    return if (i == 6) out else null;
}

pub fn hexOf(digest: []const u8) []const u8 {
    if (std.mem.startsWith(u8, digest, "sha256:")) return digest[7..];
    return digest;
}

pub fn validHex(s: []const u8) bool {
    if (s.len == 0 or s.len > 128) return false;
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

pub fn validChildName(name: []const u8) bool {
    return name.len > 0 and !std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..") and
        std.mem.indexOfAny(u8, name, "/\x00") == null;
}

pub fn validId(s: []const u8) bool {
    return s.len <= 64 and validVolumeName(s);
}

/// Docker's volume name rule without the 64 cap that container IDs keep; 255 is the filesystem's name limit.
pub fn validVolumeName(s: []const u8) bool {
    if (s.len > 255 or !validChildName(s)) return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.')) return false;
    return true;
}

test "volume names may be longer than IDs" {
    const tail: [64]u8 = @splat('a');
    const long = "act-smoke-hosted-" ++ tail;
    try std.testing.expect(validVolumeName(long) and !validId(long));
    const v255: [255]u8 = @splat('v');
    const v256: [256]u8 = @splat('v');
    try std.testing.expect(validVolumeName(&v255) and !validVolumeName(&v256));
    try std.testing.expect(!validVolumeName("a/b") and !validVolumeName(".."));
}

pub fn makedev(major: u32, minor: u32) u64 {
    const ma: u64 = major;
    const mi: u64 = minor;
    return ((ma & 0xfffff000) << 32) | ((ma & 0xfff) << 8) | ((mi & 0xffffff00) << 12) | (mi & 0xff);
}

pub fn parseU64(s: []const u8) ?u64 {
    return std.fmt.parseInt(u64, std.mem.trim(u8, s, " \n"), 10) catch null;
}

/// Read a number out of a small sysfs/cgroup file.
pub fn readNum(path: [*:0]const u8) ?u64 {
    var buf: [64]u8 = undefined;
    const fd = sys.open(path, sys.O.RDONLY, 0);
    if (fd < 0) return null;
    defer sys.close(fd);
    const n = sys.read(fd, &buf);
    if (n <= 0) return null;
    return parseU64(buf[0..@intCast(n)]);
}

/// Find "key value" in a flat-keyed file such as cpu.stat or memory.events.
pub fn flatKey(text: []const u8, key: []const u8) ?u64 {
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, key) and line.len > key.len and line[key.len] == ' ') {
            return parseU64(line[key.len + 1 ..]);
        }
    }
    return null;
}

/// Append one whole frame at `size` or nothing: a short write or error is cut back so later frames stay aligned.
pub fn appendWhole(f: anytype, size: *u64, buf: []const u8) void {
    const w = f.write(buf);
    if (w == @as(isize, @intCast(buf.len))) {
        size.* += buf.len;
    } else {
        f.truncate(size.*);
    }
}

/// A job reply is a u32 little-endian length then the body. Null unless the body is complete.
pub fn lengthPrefixed(b: []const u8) ?[]const u8 {
    if (b.len < 4) return null;
    const n = std.mem.readInt(u32, b[0..4], .little);
    return if (b.len - 4 == n) b[4..] else null;
}

test "lengthPrefixed rejects truncated bodies" {
    try std.testing.expectEqualStrings("{}", lengthPrefixed("\x02\x00\x00\x00{}").?);
    try std.testing.expect(lengthPrefixed("\x0a\x00\x00\x00{\"a\":[{}") == null); // EOF after a nested brace
    try std.testing.expect(lengthPrefixed("\x02\x00\x00\x00{}x") == null);
    try std.testing.expect(lengthPrefixed("\x02\x00") == null);
}

test "appendWhole failure keeps earlier output" {
    const F = struct {
        pub fn write(_: @This(), _: []const u8) isize { return -5; }
        pub fn truncate(_: @This(), _: u64) void { truncated = true; }
        var truncated = false;
    };
    var size: u64 = 7;
    appendWhole(F{}, &size, "abc");
    try std.testing.expect(F.truncated and size == 7);
}

// ---------------------------------------------------------------- epoll tags
pub var epfd: isize = -1;
pub const Tag = struct {
    pub const listen_ctl: u32 = 1;
    pub const listen_stream: u32 = 2;
    pub const ctl_conn: u32 = 3;
    pub const sigfd: u32 = 4;
    pub const cont_out: u32 = 5;
    pub const tty_request: u32 = 10;
    pub const tty_start: u32 = 11;
    pub const tty_waiter: u32 = 12;
    pub const tty_master: u32 = 13;
    pub const cont_stdin: u32 = 14;
    pub const hostlo_listen: u32 = 15;
    pub const evt_pipe: u32 = 16;
    pub const job: u32 = 17;
    pub const dns: u32 = 6;
    pub const dns_up: u32 = 7;
    pub const ssh_listen: u32 = 8;
    pub const dhcp: u32 = 9;
    pub const resolver: u32 = 40;
    pub const resolver_tcp: u32 = 41;
    pub const dns_conn: u32 = 42;
    pub const dns_up_tcp: u32 = 43;
};
pub fn tag(kind: u32, idx: u32) u64 {
    return (@as(u64, kind) << 32) | idx;
}

test "whiteouts and object IDs cannot target a directory or its parent" {
    for ([_][]const u8{ ".wh.", ".wh..", ".wh...", ".wh..\x00ignored", ".wh...\x00ignored", ".wh.a/b" }) |entry| {
        try std.testing.expect(!validChildName(entry[".wh.".len..]));
    }
    try std.testing.expect(validChildName(".hidden"));
    try std.testing.expect(!validId("."));
    try std.testing.expect(!validId(".."));
}

/// resolv.conf for a container that moved to the embedded resolver: search and
/// options stay, the servers go.
pub fn resolvConfForEmbedded(out: []u8, old: []const u8) []const u8 {
    const head = "nameserver 127.0.0.11\n";
    @memcpy(out[0..head.len], head);
    var n = head.len;
    var lines = std.mem.splitScalar(u8, old, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or std.mem.startsWith(u8, line, "nameserver")) continue;
        if (n + line.len + 1 > out.len) break;
        @memcpy(out[n .. n + line.len], line);
        n += line.len;
        out[n] = '\n';
        n += 1;
    }
    return out[0..n];
}

test "resolv.conf keeps search and options when it moves to the embedded resolver" {
    var out: [256]u8 = undefined;
    const got = resolvConfForEmbedded(&out, "search a.test\nnameserver 172.18.0.1\nnameserver 9.9.9.9\noptions ndots:2\n");
    try std.testing.expectEqualStrings("nameserver 127.0.0.11\nsearch a.test\noptions ndots:2\n", got);
}

/// The /proc path of a `net.*` sysctl, which the kernel scopes to the container's network
/// namespace. Null for anything else. The key cannot climb out of /proc/sys/net.
pub fn netSysctlPath(out: *[150]u8, key: []const u8) ?[:0]u8 {
    if (!std.mem.startsWith(u8, key, "net.") or key.len > 128) return null;
    for (key) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '_' or ch == '-')) return null;
    if (std.mem.indexOf(u8, key, "..") != null or key[key.len - 1] == '.') return null;
    const prefix = "/proc/sys/";
    @memcpy(out[0..prefix.len], prefix);
    @memcpy(out[prefix.len..][0..key.len], key);
    out[prefix.len + key.len] = 0;
    const path = out[0 .. prefix.len + key.len :0];
    for (path) |*ch| if (ch.* == '.') {
        ch.* = '/';
    };
    return path;
}

pub fn isSysctlValueChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == ' ' or ch == '\t' or ch == '_' or ch == '-' or ch == '.';
}

test "only net sysctls map to a path" {
    var b: [150]u8 = undefined;
    try std.testing.expectEqualStrings("/proc/sys/net/ipv4/ping_group_range", netSysctlPath(&b, "net.ipv4.ping_group_range").?);
    try std.testing.expect(netSysctlPath(&b, "kernel.hostname") == null);
    try std.testing.expect(netSysctlPath(&b, "net..ipv4") == null);
    try std.testing.expect(netSysctlPath(&b, "net.ipv4/../../x") == null);
}

test "IPv6 literals" {
    const std_t = std.testing;
    var want: [16]u8 = @splat(0);
    want[15] = 1;
    try std_t.expectEqualSlices(u8, &want, &parseIp6("::1").?);
    want[15] = 0;
    try std_t.expectEqualSlices(u8, &want, &parseIp6("::").?);
    want[0] = 0xfe;
    want[1] = 0x80;
    try std_t.expectEqualSlices(u8, &want, &parseIp6("fe80::").?);
    try std_t.expectEqualSlices(u8, &[16]u8{ 0xfd, 0x6e, 0x6f, 0x6f, 0x64, 0x6c, 0, 1, 0, 0, 0, 0, 0, 0, 0, 2 }, &parseIp6("fd6e:6f6f:646c:1::2").?);
    try std_t.expectEqualSlices(u8, &[16]u8{ 0, 1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0, 7, 0, 8 }, &parseIp6("1:2:3:4:5:6:7:8").?);
    for ([_][]const u8{ "", ":", "1.2.3.4", "1:2", ":::", "1::2::3", "12345::", "1:2:3:4:5:6:7:8:9", "1:2:3:4:5:6:7::8", "g::", "1:", "fd00::1/64", "+1::" }) |bad| {
        try std_t.expect(parseIp6(bad) == null);
    }
}

test "IPv6 network masks" {
    const ip = parseIp6("fd6e:6f6f:646c:1:aaaa::2").?;
    try std.testing.expectEqualSlices(u8, &parseIp6("fd6e:6f6f:646c:1::").?, &maskIp6(ip, 64));
    try std.testing.expectEqualSlices(u8, &parseIp6("fd6e:6f6f:6000::").?, &maskIp6(ip, 36));
    try std.testing.expectEqualSlices(u8, &ip, &maskIp6(ip, 128));
}

/// The names of a spec `hosts` line whose address is the literal `host-gateway`; null for any other line.
pub fn hostGatewayNames(line: []const u8) ?[]const u8 {
    const prefix = "host-gateway";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const rest = line[prefix.len..];
    if (rest.len == 0 or (rest[0] != ' ' and rest[0] != '\t')) return null;
    const names = std.mem.trim(u8, rest, " \t");
    return if (names.len == 0) null else names;
}

test "hostGatewayNames finds only the literal address" {
    try std.testing.expectEqualStrings("host.docker.internal", hostGatewayNames("host-gateway host.docker.internal").?);
    try std.testing.expectEqualStrings("a b", hostGatewayNames("host-gateway\ta b").?);
    try std.testing.expect(hostGatewayNames("10.0.0.1 host-gateway") == null);
    try std.testing.expect(hostGatewayNames("host-gateway2 x") == null);
    try std.testing.expect(hostGatewayNames("host-gateway") == null);
    try std.testing.expect(hostGatewayNames("host-gateway  ") == null);
}

test "a short log write is cut back so the next frame stays aligned" {
    const Mock = struct {
        data: *std.ArrayList(u8),
        limit: usize,
        pub fn write(self: @This(), b: []const u8) isize {
            const n = @min(b.len, self.limit);
            self.data.appendSlice(std.testing.allocator, b[0..n]) catch unreachable;
            return @intCast(n);
        }
        pub fn truncate(self: @This(), len: u64) void {
            self.data.shrinkRetainingCapacity(len);
        }
    };
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    var size: u64 = 0;
    appendWhole(Mock{ .data = &data, .limit = 100 }, &size, "0123456789");
    try std.testing.expectEqual(@as(u64, 10), size);
    appendWhole(Mock{ .data = &data, .limit = 4 }, &size, "abcdefghij");
    try std.testing.expectEqual(@as(u64, 10), size);
    try std.testing.expectEqualStrings("0123456789", data.items);
    appendWhole(Mock{ .data = &data, .limit = 100 }, &size, "XY");
    try std.testing.expectEqualStrings("0123456789XY", data.items);
}
