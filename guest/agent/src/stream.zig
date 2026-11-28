//! Stream-port (vsock 1033) operations. Every connection is served by a forked child so the main loop never
//! blocks (unpacking, tar, logs, exec I/O, relays). The child exits when the stream ends.
const std = @import("std");
const sys = @import("sys.zig");
const util = @import("util.zig");
const json = @import("json");
const frame = @import("frame");
const tar = @import("tar");
const tarfs = @import("tarfs.zig");
const layers = @import("layers.zig");
const container = @import("container.zig");
const AttachInput = @import("attach_input.zig").Input;
const attach_input = @import("attach_input.zig");
const Value = json.Value;

pub var ctl_fd: isize = -1; // inherited control connection, used only for exec_exit events

fn sendFrame(fd: isize, payload: []const u8) bool {
    var hdr = frame.encodeHeader(@intCast(payload.len));
    var buf: [4 + 512]u8 = undefined;
    if (payload.len <= 512) {
        @memcpy(buf[0..4], &hdr);
        @memcpy(buf[4 .. 4 + payload.len], payload);
        return sys.writeAll(fd, buf[0 .. 4 + payload.len]) >= 0;
    }
    if (sys.writeAll(fd, &hdr) < 0) return false;
    return sys.writeAll(fd, payload) >= 0;
}

pub fn ackOk(fd: isize) bool {
    return sendFrame(fd, "{\"ok\":true}");
}

pub fn ackErr(fd: isize, msg: []const u8, errno: i32) void {
    var b = json.Buf.init(util.arena());
    b.raw("{\"ok\":false,\"error\":") catch return;
    b.str(msg) catch return;
    b.print(",\"errno\":{d}}}", .{errno}) catch return;
    _ = sendFrame(fd, b.bytes());
}

fn ackFail(fd: isize) void {
    ackErr(fd, container.emsg, container.eno);
}

fn readFrameAlloc(fd: isize) ?[]u8 {
    var h: [4]u8 = undefined;
    const n = sys.readAll(fd, &h);
    if (n != 4) return null;
    const len = frame.getU32(&h);
    if (len > frame.max_frame) return null;
    const buf = util.arena().alloc(u8, len) catch return null;
    if (sys.readAll(fd, buf) != len) return null;
    return buf;
}

pub fn sendMux(fd: isize, kind: u8, data: []const u8) bool {
    const h = frame.encodeMux(kind, @intCast(data.len));
    var buf: [5 + 16384]u8 = undefined;
    if (data.len <= 16384) {
        @memcpy(buf[0..5], &h);
        @memcpy(buf[5 .. 5 + data.len], data);
        return sys.writeAll(fd, buf[0 .. 5 + data.len]) >= 0;
    }
    if (sys.writeAll(fd, &h) < 0) return false;
    return sys.writeAll(fd, data) >= 0;
}

pub fn sendExit(fd: isize, code: i32) void {
    var d: [4]u8 = undefined;
    std.mem.writeInt(i32, &d, code, .big);
    _ = sendMux(fd, frame.Kind.exit, &d);
}

pub fn serve(conn: isize) noreturn {
    _ = sys.sigprocmask(2, 0);
    if (sys.sigprocmask(0, 1 << (@backingInt(std.os.linux.SIG.PIPE) - 1)) < 0) sys.exit(1);
    const code = serveInner(conn);
    sys.exit(@intCast(code & 0xff));
}

fn serveInner(conn: isize) i32 {
    util.initArena();
    const first = readFrameAlloc(conn) orelse return 1;
    const req = json.parse(util.arena(), first) catch {
        ackErr(conn, "bad request json", sys.E.INVAL);
        return 1;
    };
    const op = req.strOr("op", "");
    if (std.mem.eql(u8, op, "buildkit_native") or std.mem.eql(u8, op, "build_image")) @import("net.zig").dhcpAwaitMarker();
    if (std.mem.eql(u8, op, "buildkit_native")) return @import("buildkit.zig").native(conn, req);
    if (std.mem.eql(u8, op, "build_image")) return @import("buildkit.zig").serve(conn, req);
    if (std.mem.eql(u8, op, "unpack_layer")) return opUnpack(conn, req);
    if (std.mem.eql(u8, op, "finder_read")) return @import("finder.zig").serve(conn, req);
    if (std.mem.eql(u8, op, "archive_get")) return opArchiveGet(conn, req);
    if (std.mem.eql(u8, op, "archive_put")) return opArchivePut(conn, req);
    if (std.mem.eql(u8, op, "export")) return opTarOfRoot(conn, req, .export_);
    if (std.mem.eql(u8, op, "commit")) return opTarOfRoot(conn, req, .commit);
    if (std.mem.eql(u8, op, "layer_get")) return opLayerGet(conn, req);
    if (std.mem.eql(u8, op, "logs")) return opLogs(conn, req);
    if (std.mem.eql(u8, op, "attach")) return opAttach(conn, req);
    if (std.mem.eql(u8, op, "exec")) return opExec(conn, req);
    if (std.mem.eql(u8, op, "relay_tcp")) return opRelayTcp(conn, req);
    if (std.mem.eql(u8, op, "relay_udp")) return opRelayUdp(conn, req);
    ackErr(conn, util.sf("unknown stream op {s}", .{op}), sys.E.NOSYS);
    return 1;
}

// ------------------------------------------------------------------ layers

fn opUnpack(conn: isize, req: Value) i32 {
    const digest = req.strOr("digest", "");
    const diff = req.strOr("diff_id", "");
    const size = req.intOr("size", 0);
    if (!layers.validDigest(digest) or !layers.validDigest(diff) or size <= 0) {
        ackErr(conn, "invalid layer digest, diff_id or size", sys.E.INVAL);
        return 1;
    }
    const media = layers.parseMedia(req.strOr("media", "gzip")) orelse {
        ackErr(conn, "unknown media type", sys.E.INVAL);
        return 1;
    };
    if (!ackOk(conn)) return 1;
    const res = layers.unpack(conn, @intCast(size), media, digest, diff) catch |e| {
        ackErr(conn, util.sf("unpack failed: {s} ({s}, errno {d})", .{ @errorName(e), tarfs.last_what, tarfs.last_errno }), tarfs.last_errno);
        return 1;
    };
    var b = json.Buf.init(util.arena());
    b.print("{{\"ok\":true,\"diff_id\":\"{s}\",\"bytes\":{d}}}", .{ res.diff_id, res.bytes }) catch return 1;
    _ = sendFrame(conn, b.bytes());
    return 0;
}

fn dirChildren(fd: isize) std.ArrayList([:0]u8) {
    const a = util.arena();
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
            if (!(std.mem.eql(u8, s, ".") or std.mem.eql(u8, s, ".."))) names.append(a, util.dupeZ(a, s) catch continue) catch {};
            off += reclen;
        }
    }
    std.mem.sort([:0]u8, names.items, {}, struct {
        fn lt(_: void, x: [:0]u8, y: [:0]u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return names;
}

fn opLayerGet(conn: isize, req: Value) i32 {
    const hex = util.hexOf(req.strOr("digest", ""));
    if (!util.validHex(hex) or !layers.has(hex)) {
        ackErr(conn, "layer not found", sys.E.NOENT);
        return 1;
    }
    const fd = sys.open(layers.layerPath(hex).ptr, sys.O.RDONLY | sys.O.DIRECTORY, 0);
    if (fd < 0) {
        ackErr(conn, "open layer", @intCast(-fd));
        return 1;
    }
    return streamDirAsTar(conn, fd, .{ .oci_whiteouts = true }, false);
}

/// Sent after a complete tar when the host asked to verify it (`commit`); a stream that ends without it failed.
const tar_done = "NOODLE-TAR-DONE\n";

fn streamDirAsTar(conn: isize, fd: isize, opts: tarfs.CreateOpts, verified: bool) i32 {
    if (!ackOk(conn)) return 1;
    var sink = tarfs.FdSink{ .fd = conn };
    const cr = tarfs.newCreator(&sink, opts) orelse return 1;
    const names = dirChildren(fd);
    for (names.items) |n| {
        if (opts.skip_runtime and (std.mem.eql(u8, n, "proc") or std.mem.eql(u8, n, "sys") or std.mem.eql(u8, n, "dev") or std.mem.eql(u8, n, ".dockerenv"))) continue;
        const tname = util.sf("{s}", .{n});
        cr.addTree(fd, n.ptr, tname, 0) catch {
            util.log("tar create {s}: errno {d} ({s})", .{ n, tarfs.last_errno, tarfs.last_what });
            return 1;
        };
    }
    cr.w.finish() catch return 1;
    if (verified) sink.writeAll(tar_done) catch return 1;
    sink.flush() catch return 1;
    return 0;
}

const RootKind = enum { export_, commit };

fn opTarOfRoot(conn: isize, req: Value, kind: RootKind) i32 {
    const id = req.strOr("container", "");
    _ = container.find(id) orelse {
        ackErr(conn, "no such container", sys.E.NOENT);
        return 1;
    };
    const sub = if (kind == .export_) "merged" else "upper";
    const fd = sys.open(util.zf("{s}/containers/{s}/{s}", .{ util.base, id, sub }).ptr, sys.O.RDONLY | sys.O.DIRECTORY, 0);
    if (fd < 0) {
        ackErr(conn, "open rootfs", @intCast(-fd));
        return 1;
    }
    return streamDirAsTar(conn, fd, .{ .oci_whiteouts = kind == .commit, .skip_runtime = kind == .commit }, kind == .commit);
}

// ------------------------------------------------------------------ archive get/put

/// Directory fd for the container's root as the container sees it (running) or its merged rootfs.
fn rootFd(c: *container.Cont) isize {
    if (c.state == .running and c.pid > 0) {
        const fd = sys.open(util.zf("/proc/{d}/root", .{c.pid}).ptr, sys.O.RDONLY | sys.O.DIRECTORY, 0);
        if (fd >= 0) return fd;
    }
    return sys.open(util.zf("{s}/containers/{s}/merged", .{ util.base, c.idStr() }).ptr, sys.O.RDONLY | sys.O.DIRECTORY, 0);
}

/// A container that has not started has no mounts yet, so a path under one of its volume mounts would not exist in the merged
/// rootfs. `docker cp` must still reach the volume, as it does on a running container: resolve such a path inside the volume.
const VolumePath = struct { fd: isize, rest: []const u8, name: []const u8 };

fn volumePath(c: *container.Cont, clean: []const u8) ?VolumePath {
    if (c.state == .running) return null;
    const spec = container.loadSpec(c.idStr()) catch return null;
    var best: ?VolumePath = null;
    var best_len: usize = 0;
    for (spec.list("mounts")) |m| {
        if (!std.mem.eql(u8, m.strOr("kind", ""), "volume")) continue;
        const target = std.mem.trim(u8, m.strOr("target", ""), "/");
        if (target.len == 0 or target.len < best_len) continue;
        const exact = std.mem.eql(u8, clean, target);
        if (!exact and !(clean.len > target.len and std.mem.startsWith(u8, clean, target) and clean[target.len] == '/')) continue;
        const source = m.strOr("source", "");
        if (!util.validVolumeName(source)) continue;
        const dir = util.zf("{s}/volumes/{s}", .{ util.base, source });
        const fd = sys.openat2(sys.AT_FDCWD, dir.ptr, sys.O.PATH | sys.O.DIRECTORY, 0, 0x04); // RESOLVE_NO_SYMLINKS
        if (fd < 0) continue;
        if (best) |old| sys.close(old.fd);
        const slash = std.mem.lastIndexOfScalar(u8, target, '/');
        best = .{ .fd = fd, .rest = if (exact) "" else clean[target.len + 1 ..], .name = if (slash) |i| target[i + 1 ..] else target };
        best_len = target.len;
    }
    return best;
}

fn splitPath(path: []const u8, buf: []u8) ?struct { dir: []const u8, base: []const u8 } {
    const clean = tar.cleanPath(path, buf) orelse return null;
    const sl = std.mem.lastIndexOfScalar(u8, clean, '/');
    return .{ .dir = if (sl) |s| clean[0..s] else "", .base = if (sl) |s| clean[s + 1 ..] else clean };
}

fn opArchiveGet(conn: isize, req: Value) i32 {
    const id = req.strOr("container", "");
    const c = container.find(id) orelse {
        ackErr(conn, "no such container", sys.E.NOENT);
        return 1;
    };
    var path = req.strOr("path", "/");
    var contents_only = false;
    if (std.mem.endsWith(u8, path, "/.")) {
        contents_only = true;
        path = path[0 .. path.len - 2];
    } else if (std.mem.endsWith(u8, path, "/") and path.len > 1) {
        path = path[0 .. path.len - 1];
    }
    var root = rootFd(c);
    if (root < 0) {
        ackErr(conn, "open rootfs", @intCast(-root));
        return 1;
    }
    var pb: [1024]u8 = undefined;
    var sp = splitPath(path, &pb) orelse {
        ackErr(conn, "invalid path", sys.E.INVAL);
        return 1;
    };
    var forced_name: ?[]const u8 = null;
    var vol_fd: isize = -1;
    defer if (vol_fd >= 0) sys.close(vol_fd);
    var whole: [1024]u8 = undefined;
    if (tar.cleanPath(path, &whole)) |clean| if (volumePath(c, clean)) |v| {
        vol_fd = v.fd;
        root = v.fd;
        var rb: [1024]u8 = undefined;
        sp = splitPath(v.rest, &rb) orelse sp;
        if (v.rest.len == 0) forced_name = v.name;
    };
    const entry = forced_name orelse sp.base;
    const dirz = if (sp.dir.len == 0) util.zdup(".") else util.zdup(sp.dir);
    const pfd = sys.openat2(root, dirz.ptr, sys.O.PATH | sys.O.DIRECTORY, 0, sys.RESOLVE_IN_ROOT);
    if (pfd < 0) {
        ackErr(conn, util.sf("Could not find the file {s} in container {s}", .{ path, id }), sys.E.NOENT);
        return 1;
    }
    const basez = if (sp.base.len == 0) util.zdup(".") else util.zdup(sp.base);
    var st: sys.Stat = undefined;
    if (sys.fstatat(pfd, basez.ptr, &st, sys.AT_SYMLINK_NOFOLLOW) < 0) {
        ackErr(conn, util.sf("Could not find the file {s} in container {s}", .{ path, id }), sys.E.NOENT);
        return 1;
    }
    var b = json.Buf.init(util.arena());
    b.raw("{\"ok\":true,\"name\":") catch return 1;
    b.str(if (entry.len == 0) "/" else entry) catch return 1;
    b.print(",\"size\":{d},\"mode\":{d},\"mtime\":{d}", .{ st.size, st.mode, st.mtime }) catch return 1;
    if ((st.mode & sys.S.IFMT) == sys.S.IFLNK) {
        var lb: [1024]u8 = undefined;
        const n = sys.readlinkat(pfd, basez.ptr, &lb);
        if (n > 0) {
            b.raw(",\"link_target\":") catch return 1;
            b.str(lb[0..@intCast(n)]) catch return 1;
        }
    }
    b.byte('}') catch return 1;
    if (!sendFrame(conn, b.bytes())) return 1;

    var sink = tarfs.FdSink{ .fd = conn };
    const cr = tarfs.newCreator(&sink, .{}) orelse return 1;
    if (contents_only and (st.mode & sys.S.IFMT) == sys.S.IFDIR) {
        const dfd = sys.openat(pfd, basez.ptr, sys.O.RDONLY | sys.O.DIRECTORY | sys.O.NOFOLLOW, 0);
        if (dfd < 0) return 1;
        const names = dirChildren(dfd);
        for (names.items) |n| cr.addTree(dfd, n.ptr, util.sf("{s}", .{n}), 0) catch return 1;
    } else {
        const tname = if (entry.len == 0) "." else entry;
        cr.addTree(pfd, basez.ptr, tname, 0) catch return 1;
    }
    cr.w.finish() catch return 1;
    sink.flush() catch return 1;
    return 0;
}

fn opArchivePut(conn: isize, req: Value) i32 {
    const id = req.strOr("container", "");
    const c = container.find(id) orelse {
        ackErr(conn, "no such container", sys.E.NOENT);
        return 1;
    };
    const path = req.strOr("path", "/");
    const size: u64 = @intCast(@max(req.intOr("size", 0), 0));
    var root = rootFd(c);
    if (root < 0) {
        ackErr(conn, "open rootfs", @intCast(-root));
        return 1;
    }
    var pb: [1024]u8 = undefined;
    var clean = tar.cleanPath(path, &pb) orelse {
        ackErr(conn, "invalid path", sys.E.INVAL);
        return 1;
    };
    var vol_fd: isize = -1;
    defer if (vol_fd >= 0) sys.close(vol_fd);
    if (volumePath(c, clean)) |v| {
        vol_fd = v.fd;
        root = v.fd;
        clean = v.rest;
    }
    const dz = if (clean.len == 0) util.zdup(".") else util.zdup(clean);
    const dest = sys.openat2(root, dz.ptr, sys.O.RDONLY | sys.O.DIRECTORY, 0, sys.RESOLVE_IN_ROOT);
    if (dest < 0) {
        ackErr(conn, util.sf("destination {s} is not a directory in container", .{path}), sys.E.NOENT);
        return 1;
    }
    if (!ackOk(conn)) return 1;
    const buf = util.arena().alloc(u8, 64 * 1024) catch return 1;
    var in = layers.FdIn.init(conn, buf, size);
    var src = layers.HashSrc{ .inner = &in.reader };
    tarfs.extractAs(&src, dest, !req.boolOr("copy_uid_gid", false)) catch |e| {
        ackErr(conn, util.sf("extract failed: {s} ({s}, errno {d})", .{ @errorName(e), tarfs.last_what, tarfs.last_errno }), tarfs.last_errno);
        return 1;
    };
    _ = sendFrame(conn, "{\"ok\":true}");
    return 0;
}

// ------------------------------------------------------------------ logs and attach

const LogFrame = struct { stream: u8, ts_ns: i64, len: u32 };

const LogReader = struct {
    fd: isize,
    id: []const u8 = "",
    pos: u64 = 0,
    buf: [32 * 1024]u8 = undefined,

    /// Next frame header; null at (current) EOF or on a partial header.
    fn nextHeader(self: *LogReader) ?LogFrame {
        var h: [13]u8 = undefined;
        const n = sys.pread(self.fd, &h, self.pos);
        if (n != 13) return null;
        return .{ .stream = h[0], .ts_ns = std.mem.readInt(i64, h[1..9], .big), .len = std.mem.readInt(u32, h[9..13], .big) };
    }
    /// Read frame body at current position (after header) into buf, up to buf.len; returns bytes read.
    fn body(self: *LogReader, off: u32, max: usize) usize {
        const want = @min(max, self.buf.len);
        const n = sys.pread(self.fd, self.buf[0..want], self.pos + 13 + off);
        return if (n < 0) 0 else @intCast(n);
    }
    fn advance(self: *LogReader, f: LogFrame) void {
        self.pos += 13 + f.len;
    }
};

const LogFilter = struct {
    stdout: bool = true,
    stderr: bool = true,
    since: i64 = 0,
    until: i64 = 0,
    timestamps: bool = false,
    skip_lines: u64 = 0,
};

fn fmtTimestamp(buf: []u8, ts_ns: i64) []const u8 {
    const secs: i64 = @divFloor(ts_ns, 1_000_000_000);
    const nanos: u32 = @intCast(@mod(ts_ns, 1_000_000_000));
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(secs) };
    const ed = es.getEpochDay();
    const yd = ed.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>9}Z ", .{
        yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(), nanos,
    }) catch "";
}

const LogEmit = struct {
    conn: isize,
    f: LogFilter,
    line_no: u64 = 0,
    at_line_start: bool = true,
    ok: bool = true,

    /// Emit the frame payload slice respecting tail skipping and timestamps.
    fn emit(self: *LogEmit, fr: LogFrame, data: []const u8) void {
        var rest = data;
        while (rest.len > 0 and self.ok) {
            const nl = std.mem.indexOfScalar(u8, rest, '\n');
            const piece = if (nl) |i| rest[0 .. i + 1] else rest;
            if (self.line_no >= self.f.skip_lines) {
                if (self.f.timestamps and self.at_line_start) {
                    const mark = util.arenaMark();
                    defer util.arenaRewind(mark);
                    var tb: [48]u8 = undefined;
                    const ts = fmtTimestamp(&tb, fr.ts_ns);
                    var joined = util.arena().alloc(u8, ts.len + piece.len) catch return;
                    @memcpy(joined[0..ts.len], ts);
                    @memcpy(joined[ts.len..], piece);
                    self.ok = sendMux(self.conn, fr.stream, joined);
                } else self.ok = sendMux(self.conn, fr.stream, piece);
            }
            self.at_line_start = nl != null;
            if (nl != null) self.line_no += 1;
            rest = rest[piece.len..];
        }
    }
};

fn wanted(f: LogFilter, fr: LogFrame) bool {
    if (fr.stream == 1 and !f.stdout) return false;
    if (fr.stream == 2 and !f.stderr) return false;
    const secs = @divFloor(fr.ts_ns, 1_000_000_000);
    if (f.since > 0 and secs < f.since) return false;
    if (f.until > 0 and secs > f.until) return false;
    return true;
}

/// Newlines in the wanted frames of lr's file; `partial` carries "last byte was not a newline" across files.
fn countLines(lr: *LogReader, f: LogFilter, partial: *bool) u64 {
    lr.pos = 0;
    var lines: u64 = 0;
    while (lr.nextHeader()) |fr| {
        if (wanted(f, fr)) {
            var off: u32 = 0;
            while (off < fr.len) {
                const n = lr.body(off, fr.len - off);
                if (n == 0) break;
                for (lr.buf[0..n]) |ch| {
                    if (ch == '\n') {
                        lines += 1;
                        partial.* = false;
                    } else partial.* = true;
                }
                off += @intCast(n);
            }
        }
        lr.advance(fr);
    }
    return lines;
}

fn logFileZ(id: []const u8, k: u32) [:0]u8 {
    return if (k == 0) container.logPath(id) else util.zf("{s}/containers/{s}/log.{d}", .{ util.base, id, k });
}

/// Highest k such that log.1 .. log.k all exist (0 when the log never rotated).
fn oldestLog(id: []const u8) u32 {
    var k: u32 = 0;
    var st: sys.Stat = undefined;
    while (k < 10000 and sys.fstatat(sys.AT_FDCWD, logFileZ(id, k + 1).ptr, &st, 0) >= 0) k += 1;
    return k;
}

/// Line count over every log file, oldest first, with lr.fd/pos restored afterwards.
fn countAll(lr: *LogReader, f: LogFilter, oldest: u32) u64 {
    const save_fd = lr.fd;
    const save_pos = lr.pos;
    defer {
        lr.fd = save_fd;
        lr.pos = save_pos;
    }
    var total: u64 = 0;
    var partial = false;
    var k = oldest + 1;
    while (k > 0) {
        k -= 1;
        const fd = sys.open(logFileZ(lr.id, k).ptr, sys.O.RDONLY, 0);
        if (fd < 0) continue;
        lr.fd = fd;
        total += countLines(lr, f, &partial);
        sys.close(fd);
    }
    return total + @intFromBool(partial);
}

/// Index of the file lr.fd refers to (0 = current), or null once it has been rotated away.
fn locateLog(lr: *LogReader) ?u32 {
    var mine: sys.Stat = undefined;
    if (sys.fstat(lr.fd, &mine) < 0) return null;
    var k: u32 = 0;
    var st: sys.Stat = undefined;
    while (k < 10000) : (k += 1) {
        if (sys.fstatat(sys.AT_FDCWD, logFileZ(lr.id, k).ptr, &st, 0) < 0) {
            if (k == 0) continue; // current file briefly absent mid-rotation
            return null;
        }
        if (st.ino == mine.ino and st.dev == mine.dev) return k;
    }
    return null;
}

/// Send everything currently in the log from lr.pos; updates lr.pos. Returns false if the peer went away.
fn pumpFile(lr: *LogReader, em: *LogEmit) bool {
    while (lr.nextHeader()) |fr| {
        // a frame may still be mid-write: require the whole payload to be present
        var st: sys.Stat = undefined;
        if (sys.fstat(lr.fd, &st) < 0) return false;
        if (@as(u64, @intCast(st.size)) < lr.pos + 13 + fr.len) return true;
        if (wanted(em.f, fr)) {
            var off: u32 = 0;
            while (off < fr.len) {
                const n = lr.body(off, fr.len - off);
                if (n == 0) break;
                em.emit(fr, lr.buf[0..n]);
                if (!em.ok) return false;
                off += @intCast(n);
            }
        }
        lr.advance(fr);
    }
    return em.ok;
}

/// Send everything from lr's position, following the log across rotations. Returns false if the peer went away.
fn pumpLog(lr: *LogReader, em: *LogEmit) bool {
    while (true) {
        if (!pumpFile(lr, em)) return false;
        const k = locateLog(lr);
        if (k != null and k.? == 0) return em.ok;
        if (!pumpFile(lr, em)) return false; // a write may have landed just before the rename
        // next newer file: one index down, or the oldest survivor if ours was deleted
        var next: u32 = if (k) |kk| kk - 1 else oldestLog(lr.id);
        var nfd = sys.open(logFileZ(lr.id, next).ptr, sys.O.RDONLY, 0);
        if (nfd < 0 and k == null) {
            next = 0;
            nfd = sys.open(logFileZ(lr.id, 0).ptr, sys.O.RDONLY, 0);
        }
        if (nfd < 0) return em.ok; // mid-rotation; the next write event retries
        sys.close(lr.fd);
        lr.fd = nfd;
        lr.pos = 0;
    }
}

fn readExitCode(id: []const u8) ?i32 {
    const t = util.readFile(container.exitPath(id).ptr, 32) orelse return null;
    return std.fmt.parseInt(i32, std.mem.trim(u8, t, " \n"), 10) catch 0;
}

/// Identifies one write of the exit marker: start() unlinks it and the next exit creates a new file.
fn exitStamp(id: []const u8) ?[3]i64 {
    var st: sys.Stat = undefined;
    if (sys.fstatat(sys.AT_FDCWD, container.exitPath(id).ptr, &st, 0) < 0) return null;
    return .{ @bitCast(st.ino), st.ctime, st.ctime_nsec };
}

/// `--rm` deletes the container folder, exit marker included, while a slow reader may still be draining output.
fn containerRemoved(id: []const u8) bool {
    return !util.exists(container.cdir(id).ptr);
}

fn opLogs(conn: isize, req: Value) i32 {
    const id = req.strOr("container", "");
    _ = container.find(id) orelse {
        ackErr(conn, "no such container", sys.E.NOENT);
        return 1;
    };
    const oldest = oldestLog(id);
    const lfd = sys.open(logFileZ(id, oldest).ptr, sys.O.RDONLY, 0);
    if (lfd < 0) {
        ackErr(conn, "no log", @intCast(-lfd));
        return 1;
    }
    const tail = req.intOr("tail", -1);
    var filt = LogFilter{
        .since = req.intOr("since", 0),
        .until = req.intOr("until", 0),
        .timestamps = req.boolOr("timestamps", false),
    };
    const lr = util.arena().create(LogReader) catch return 1;
    lr.* = .{ .fd = lfd, .id = id };
    if (tail >= 0) {
        const total = countAll(lr, filt, oldest);
        filt.skip_lines = if (total > @as(u64, @intCast(tail))) total - @as(u64, @intCast(tail)) else 0;
    }
    const follow = req.boolOr("follow", false);
    const ino = if (follow) sys.inotify_init() else -1;
    const watching = ino >= 0 and sys.inotify_add(ino, container.cdir(id).ptr, 2 | 8) >= 0; // IN_MODIFY | IN_CLOSE_WRITE
    if (!ackOk(conn)) return 1;
    var em = LogEmit{ .conn = conn, .f = filt };
    if (!pumpLog(lr, &em)) return 1;
    if (follow) {
        while (true) {
            // The exit marker is written after all output, so drain once more after seeing it. Paths and reads are scratch: rewind each wakeup.
            const mark = util.arenaMark();
            const exited = readExitCode(id) != null or containerRemoved(id);
            if (!pumpLog(lr, &em)) return 0;
            util.arenaRewind(mark);
            if (exited) break;
            var pfds = [2]sys.PollFd{
                .{ .fd = @intCast(ino), .events = sys.POLLIN, .revents = 0 },
                .{ .fd = @intCast(conn), .events = sys.POLLRDHUP, .revents = 0 },
            };
            _ = sys.poll(&pfds, 2, if (watching) -1 else 500);
            if (pfds[1].revents & (sys.POLLRDHUP | sys.POLLHUP | sys.POLLERR) != 0) return 0;
            if (ino >= 0 and pfds[0].revents != 0) {
                var drain: [512]u8 = undefined;
                _ = sys.read(ino, &drain);
            }
        }
    }
    sendExit(conn, 0);
    return 0;
}

fn opAttach(conn: isize, req: Value) i32 {
    const id = req.strOr("container", "");
    const c = container.find(id) orelse {
        ackErr(conn, "no such container", sys.E.NOENT);
        return 1;
    };
    const want_stdin = req.boolOr("stdin", false);
    var tty_reply: [2]i32 = .{ -1, -1 };
    var tty_master: isize = -1;
    defer {
        for (tty_reply) |fd| sys.close(fd);
        sys.close(tty_master);
    }
    if (c.tty and want_stdin) {
        const rc = sys.socketpair(sys.AF_UNIX, sys.SOCK_STREAM | sys.SOCK_NONBLOCK, &tty_reply);
        if (rc < 0 or sys.sendFd(c.tty_requests[1], tty_reply[1]) < 0) {
            ackErr(conn, "request attach pty", sys.E.IO);
            return 1;
        }
        sys.close(tty_reply[1]);
        tty_reply[1] = -1;
    }

    var filt = LogFilter{ .stdout = req.boolOr("stdout", true), .stderr = req.boolOr("stderr", true) };
    _ = &filt;
    const lfd = sys.open(container.logPath(id).ptr, sys.O.RDONLY, 0);
    if (lfd < 0) {
        ackErr(conn, "no log", @intCast(-lfd));
        return 1;
    }
    const lr = util.arena().create(LogReader) catch return 1;
    lr.* = .{ .fd = lfd, .id = id };
    if (!req.boolOr("logs", false)) {
        var st: sys.Stat = undefined;
        if (sys.fstat(lfd, &st) >= 0) lr.pos = @intCast(st.size);
    }
    // Attached to a stopped container (`docker start -a`): its exit marker belongs to the last run, so wait for the next one.
    var stale: ?[3]i64 = if (c.state == .exited) exitStamp(id) else null;
    const ino = sys.inotify_init();
    const watching = ino >= 0 and sys.inotify_add(ino, container.cdir(id).ptr, 2 | 8) >= 0; // IN_MODIFY | IN_CLOSE_WRITE
    if (!ackOk(conn)) return 1;

    var em = LogEmit{ .conn = conn, .f = filt };

    var stdin_open = want_stdin; // whether the client may still send mux frames
    var input = AttachInput.init(want_stdin, c.tty);
    var pending_input: std.ArrayList(u8) = .empty;
    var pending_size: ?[4]u16 = null;
    var ibuf: [65536]u8 = undefined;
    while (true) {
        // Path building and file reads are scratch: rewind each wakeup so a long attach cannot fill the arena.
        const mark = util.arenaMark();
        if (stale) |old| {
            const now = exitStamp(id);
            if (now == null or !std.mem.eql(i64, &now.?, &old)) stale = null;
        }
        const code = if (stale == null) readExitCode(id) else null;
        const removed = code == null and containerRemoved(id);
        if (!pumpLog(lr, &em)) return 0;
        util.arenaRewind(mark);
        if (code) |exit_code| {
            sendExit(conn, exit_code);
            return 0;
        }
        // The real status reaches `docker run` through the wait API, which the engine answers from its own record.
        if (removed) {
            sendExit(conn, 0);
            return 0;
        }
        var pfds = [3]sys.PollFd{
            .{ .fd = @intCast(ino), .events = sys.POLLIN, .revents = 0 },
            .{ .fd = @intCast(conn), .events = if (stdin_open) sys.POLLIN else sys.POLLRDHUP, .revents = 0 },
            .{ .fd = tty_reply[0], .events = sys.POLLIN, .revents = 0 },
        };
        _ = sys.poll(&pfds, if (c.tty) 3 else 2, if (watching) -1 else 500);
        if (tty_reply[0] >= 0 and pfds[2].revents != 0) {
            const received = sys.recvFd(tty_reply[0]);
            input.masterResult(received);
            if (received != -sys.E.AGAIN) {
                tty_master = received;
                sys.close(tty_reply[0]);
                tty_reply[0] = -1;
                if (input.forwarding()) {
                    if (pending_size) |saved| {
                        var ws = saved;
                        _ = sys.ioctl(tty_master, sys.TIOCSWINSZ, @intFromPtr(&ws));
                    }
                    if (pending_input.items.len > 0) input.writeResult(sys.writeAll(tty_master, pending_input.items));
                }
                // EOF means no master is available. Continue tailing the log and
                // wait for the exit marker, including when attach raced with exit.
                pending_input.deinit(util.arena());
                pending_input = .empty;
            }
        }
        if (ino >= 0 and pfds[0].revents != 0) {
            var drain: [512]u8 = undefined;
            _ = sys.read(ino, &drain);
        }
        if (pfds[1].revents & (sys.POLLIN | sys.POLLHUP | sys.POLLERR | sys.POLLRDHUP) != 0) {
            if (stdin_open) {
                var h: [5]u8 = undefined;
                const n = sys.readAll(conn, &h);
                if (n != 5) {
                    // client gone: stop attaching but leave the container running
                    return 0;
                }
                const mh = frame.decodeMux(&h);
                if (mh.len > ibuf.len) return 1;
                if (mh.len > 0 and sys.readAll(conn, ibuf[0..mh.len]) != mh.len) return 0;
                switch (mh.kind) {
                    frame.Kind.stdin => {
                        const fd: isize = if (c.tty) tty_master else c.stdin_b;
                        if (fd >= 0 and input.forwarding()) {
                            input.writeResult(sys.writeAll(fd, ibuf[0..mh.len]));
                        } else if (input.waiting()) {
                            if (pending_input.items.len + mh.len > 65536) return 1;
                            pending_input.appendSlice(util.arena(), ibuf[0..mh.len]) catch return 1;
                        }
                    },
                    frame.Kind.stdin_eof => {
                        if (!c.tty and c.stdin_b >= 0) _ = sys.shutdown(c.stdin_b, 1);
                        stdin_open = false;
                        if (!c.tty) input.stop();
                    },
                    frame.Kind.resize => {
                        if (c.tty and mh.len >= 4) {
                            container.resize(id, std.mem.readInt(u16, ibuf[0..2], .big), std.mem.readInt(u16, ibuf[2..4], .big)) catch {};
                            pending_size = .{ std.mem.readInt(u16, ibuf[0..2], .big), std.mem.readInt(u16, ibuf[2..4], .big), 0, 0 };
                            if (tty_master >= 0) {
                                var ws = [4]u16{ std.mem.readInt(u16, ibuf[0..2], .big), std.mem.readInt(u16, ibuf[2..4], .big), 0, 0 };
                                _ = sys.ioctl(tty_master, sys.TIOCSWINSZ, @intFromPtr(&ws));
                            }
                        }
                    },
                    else => {},
                }
            } else if (pfds[1].revents & (sys.POLLHUP | sys.POLLRDHUP | sys.POLLERR) != 0) return 0;
        }
    }
}

// ------------------------------------------------------------------ exec

fn opExec(conn: isize, req: Value) i32 {
    const id = req.strOr("container", "");
    const exec_id = req.strOr("exec", "");
    const c = container.find(id) orelse {
        ackErr(conn, "no such container", sys.E.NOENT);
        return 1;
    };
    if (c.state != .running) {
        ackErr(conn, "container is not running", sys.E.INVAL);
        return 1;
    }
    const tty = req.boolOr("tty", false);
    const want_stdin = req.boolOr("stdin", false);

    var out_r: [2]i32 = .{ -1, -1 };
    var out_w: [2]i32 = .{ -1, -1 };
    var master: isize = -1;
    var handoff: [2]i32 = .{ -1, -1 };
    var in_a: isize = -1;
    var in_b: isize = -1;
    defer {
        for (handoff) |fd| sys.close(fd);
        for (out_r) |fd| sys.close(fd);
        for (out_w) |fd| sys.close(fd);
        sys.close(master);
        sys.close(in_a);
        sys.close(in_b);
    }
    if (tty) {
        const rc = sys.socketpair(sys.AF_UNIX, sys.SOCK_STREAM | sys.SOCK_NONBLOCK, &handoff);
        if (rc < 0) {
            ackErr(conn, "exec pty handoff socket", @intCast(-rc));
            return 1;
        }
    } else {
        var pipe: [2]i32 = undefined;
        var rc = sys.pipe2(&pipe, 0);
        if (rc < 0) {
            ackErr(conn, "exec stdout pipe", @intCast(-rc));
            return 1;
        }
        out_r[0] = pipe[0];
        out_w[0] = pipe[1];
        rc = sys.pipe2(&pipe, 0);
        if (rc < 0) {
            ackErr(conn, "exec stderr pipe", @intCast(-rc));
            return 1;
        }
        out_r[1] = pipe[0];
        out_w[1] = pipe[1];
        if (want_stdin) {
            // A pipe, as runc uses. With a socket, busybox `cat` sendfile()s stdin to its stdout pipe and
            // sleeps for input while holding that pipe's lock, so our read of its output blocks: deadlock.
            rc = sys.pipe2(&pipe, 0);
            if (rc < 0) {
                ackErr(conn, "exec stdin pipe", @intCast(-rc));
                return 1;
            }
            in_a = pipe[0];
            in_b = pipe[1];
        }
    }
    var st_p: [2]i32 = undefined;
    const status_rc = sys.pipe2(&st_p, 0);
    if (status_rc < 0) {
        ackErr(conn, "exec status pipe", @intCast(-status_rc));
        return 1;
    }
    defer for (st_p) |fd| sys.close(fd);

    const pid = container.execInContainer(c, req, .{
        .stdin_r = in_a,
        .stdout_w = out_w[0],
        .stderr_w = out_w[1],
        .tty_socket = handoff[1],
        .tty_parent_socket = handoff[0],
        .status_w = st_p[1],
    });
    if (pid < 0) {
        ackErr(conn, util.sf("exec setup failed: errno {d}", .{-pid}), @intCast(-pid));
        return 1;
    }
    var reaped = false;
    defer if (!reaped) {
        _ = sys.kill(pid, sys.SIG.KILL);
        var status: u32 = 0;
        while (sys.wait4(pid, &status, 0) == -sys.E.INTR) {}
    };
    sys.close(st_p[1]);
    st_p[1] = -1;
    sys.close(out_w[0]);
    sys.close(out_w[1]);
    sys.close(in_a);
    in_a = -1;
    out_w = .{ -1, -1 };
    sys.close(handoff[1]);
    handoff[1] = -1;
    if (tty) {
        while (true) {
            var ready = [3]sys.PollFd{
                .{ .fd = handoff[0], .events = sys.POLLIN, .revents = 0 },
                .{ .fd = st_p[0], .events = sys.POLLIN, .revents = 0 },
                .{ .fd = @intCast(conn), .events = sys.POLLRDHUP, .revents = 0 },
            };
            const rc = sys.poll(&ready, 3, -1);
            if (rc == -sys.E.INTR) continue;
            if (rc < 0) {
                ackErr(conn, "wait exec pty handoff", @intCast(-rc));
                return 126;
            }
            if (ready[2].revents & (sys.POLLRDHUP | sys.POLLHUP | sys.POLLERR) != 0) return 1;
            if (ready[0].revents != 0) {
                master = sys.recvFd(handoff[0]);
                if (master < 0) {
                    sys.close(handoff[0]);
                    handoff[0] = -1;
                    break; // report the child's detailed setup failure below
                }
                if (sys.sendNonblock(handoff[0], &.{1}) != 1) {
                    ackErr(conn, "acknowledge exec pty master", sys.E.IO);
                    return 126;
                }
                sys.setNonblock(master);
                break;
            }
            if (ready[1].revents != 0) break; // childDie or early child death
        }
    }
    var emsg: [400]u8 = undefined;
    const en = sys.readAll(st_p[0], &emsg);
    sys.close(st_p[0]);
    st_p[0] = -1;
    if (en != 0) {
        ackErr(conn, if (en > 0) emsg[0..@intCast(en)] else "read exec status failed", sys.E.NOENT);
        return 126;
    }
    if (tty and master < 0) {
        ackErr(conn, "exec exited before pty handoff", sys.E.IO);
        return 126;
    }
    if (!ackOk(conn)) return 1;

    const out0: isize = if (tty) master else out_r[0];
    const out1: isize = if (tty) -1 else out_r[1];
    var open0 = true;
    var open1 = out1 >= 0;
    var stdin_open = want_stdin;
    var exited = false;
    var code: i32 = 0;
    var data: [16384]u8 = undefined;
    var ibuf: [65536]u8 = undefined;
    // Stdin is relayed non-blocking: unwritten bytes wait here so output keeps draining.
    const stdin_fd: isize = if (tty) master else in_b;
    if (!tty and in_b >= 0) sys.setNonblock(in_b);
    var stdin_pending: std.ArrayList(u8) = .empty;
    var stdin_eof_seen = false;
    var stdin_shut = false;
    while (true) {
        // Backpressure: stop reading stdin frames from conn while the queue is full.
        const conn_ev: i16 = if (stdin_pending.items.len > 65536) 0 else sys.POLLIN;
        var pfds = [4]sys.PollFd{
            .{ .fd = if (conn_ev != 0) @intCast(conn) else -1, .events = conn_ev, .revents = 0 },
            .{ .fd = if (open0) @intCast(out0) else -1, .events = sys.POLLIN, .revents = 0 },
            .{ .fd = if (open1) @intCast(out1) else -1, .events = sys.POLLIN, .revents = 0 },
            .{ .fd = if (stdin_pending.items.len > 0 and stdin_fd >= 0) @intCast(stdin_fd) else -1, .events = sys.POLLOUT, .revents = 0 },
        };
        _ = sys.poll(&pfds, 4, if (exited) 50 else 200);
        if (pfds[3].revents != 0 and stdin_pending.items.len > 0) _ = attach_input.writeQueued(stdin_fd, &stdin_pending, util.arena(), "");
        var got_output = false;
        const outs = [2]struct { fd: isize, open: *bool, kind: u8, idx: usize }{
            .{ .fd = out0, .open = &open0, .kind = frame.Kind.stdout, .idx = 1 },
            .{ .fd = out1, .open = &open1, .kind = frame.Kind.stderr, .idx = 2 },
        };
        for (outs) |o| {
            if (!o.open.* or pfds[o.idx].revents == 0) continue;
            const n = sys.read(o.fd, &data);
            if (n > 0) {
                got_output = true;
                if (!sendMux(conn, o.kind, data[0..@intCast(n)])) return 1;
            } else if (n != -sys.E.AGAIN and n != -sys.E.INTR) o.open.* = false;
        }
        if (pfds[0].revents & (sys.POLLIN | sys.POLLHUP | sys.POLLERR) != 0) {
            var h: [5]u8 = undefined;
            const n = sys.readAll(conn, &h);
            if (n != 5) {
                return 1;
            }
            const mh = frame.decodeMux(&h);
            if (mh.len > ibuf.len) return 1;
            if (mh.len > 0 and sys.readAll(conn, ibuf[0..mh.len]) != mh.len) return 1;
            switch (mh.kind) {
                frame.Kind.stdin => {
                    if (stdin_fd >= 0 and !stdin_shut) _ = attach_input.writeQueued(stdin_fd, &stdin_pending, util.arena(), ibuf[0..mh.len]);
                },
                frame.Kind.stdin_eof => {
                    stdin_eof_seen = true;
                    stdin_open = false;
                },
                frame.Kind.resize => {
                    if (tty and mh.len >= 4) {
                        var ws = [4]u16{ std.mem.readInt(u16, ibuf[0..2], .big), std.mem.readInt(u16, ibuf[2..4], .big), 0, 0 };
                        _ = sys.ioctl(master, sys.TIOCSWINSZ, @intFromPtr(&ws));
                    }
                },
                else => {},
            }
        }
        if (stdin_eof_seen and !stdin_shut and stdin_pending.items.len == 0) {
            stdin_shut = true;
            if (!tty and in_b >= 0) {
                sys.close(in_b); // EOF for the reader
                in_b = -1;
            }
        }
        if (!exited) {
            var status: u32 = 0;
            const w = sys.wait4(pid, &status, 1); // WNOHANG
            if (w == pid) {
                reaped = true;
                exited = true;
                code = if (status & 0x7f == 0) @intCast((status >> 8) & 0xff) else 128 + @as(i32, @intCast(status & 0x7f));
            }
        }
        if (exited and !got_output) {
            // drain whatever is left in the pipes, then finish
            var empty = true;
            for (outs) |o| {
                if (!o.open.*) continue;
                const n = sys.read(o.fd, &data);
                if (n > 0) {
                    empty = false;
                    if (!sendMux(conn, o.kind, data[0..@intCast(n)])) return 1;
                }
            }
            if (empty) break;
        }
    }
    sendExit(conn, code);
    emitExecExit(exec_id, code);
    return code;
}

// ------------------------------------------------------------------ relays

/// A relay target. The host sends one literal of either family.
const RelayAddr = union(enum) {
    v4: sys.SockaddrIn,
    v6: sys.SockaddrIn6,

    fn parse(text: []const u8, port: u16) ?RelayAddr {
        const be = std.mem.nativeToBig(u16, port);
        if (util.parseIp4(text)) |ip| return .{ .v4 = .{ .port = be, .addr = ip } };
        if (util.parseIp6(text)) |ip| return .{ .v6 = .{ .port = be, .addr = ip } };
        return null;
    }
    fn family(self: *const RelayAddr) usize {
        return if (self.* == .v4) sys.AF_INET else sys.AF_INET6;
    }
    fn connect(self: *const RelayAddr, s: isize) isize {
        return switch (self.*) {
            .v4 => |*a| sys.connect(s, a, @sizeOf(sys.SockaddrIn)),
            .v6 => |*a| sys.connect(s, a, @sizeOf(sys.SockaddrIn6)),
        };
    }
};

fn connectTcp(addr: RelayAddr) isize {
    const s = sys.socket(addr.family(), sys.SOCK_STREAM, 0);
    if (s < 0) return s;
    sys.setNonblock(s);
    const rc = addr.connect(s);
    if (rc < 0 and rc != -115) { // EINPROGRESS
        sys.close(s);
        return rc;
    }
    if (rc < 0) {
        var pfd = sys.PollFd{ .fd = @intCast(s), .events = sys.POLLOUT, .revents = 0 };
        if (sys.poll(@ptrCast(&pfd), 1, 5000) <= 0) {
            sys.close(s);
            return -110; // ETIMEDOUT
        }
        var err: i32 = 0;
        var len: u32 = 4;
        _ = sys.sc(.getsockopt, @intCast(s), sys.SOL_SOCKET, 4, @intFromPtr(&err), @intFromPtr(&len), 0);
        if (err != 0) {
            sys.close(s);
            return -err;
        }
    }
    sys.clearNonblock(s);
    return s;
}

fn opRelayTcp(conn: isize, req: Value) i32 {
    const port: u16 = @intCast(req.intOr("port", 0));
    const addr = RelayAddr.parse(req.strOr("ip", ""), port) orelse {
        ackErr(conn, "bad ip", sys.E.INVAL);
        return 1;
    };
    const s = connectTcp(addr);
    if (s < 0) {
        ackErr(conn, "connect failed", @intCast(-s));
        return 1;
    }
    if (!ackOk(conn)) return 1;
    return relaySockets(conn, s, false);
}

pub fn relaySockets(conn: isize, s: isize, stop_on_disconnect: bool) i32 {
    var buf: [65536]u8 = undefined;
    var host_open = true;
    var peer_open = true;
    while (host_open or peer_open) {
        var pfds = [2]sys.PollFd{
            .{ .fd = if (host_open) @intCast(conn) else -1, .events = sys.POLLIN, .revents = 0 },
            .{ .fd = if (peer_open) @intCast(s) else -1, .events = sys.POLLIN, .revents = 0 },
        };
        if (sys.poll(&pfds, 2, -1) < 0) continue;
        if (pfds[0].revents != 0) {
            const n = sys.read(conn, &buf);
            if (n > 0) {
                if (sys.writeAll(s, buf[0..@intCast(n)]) < 0) return 1;
            } else if (n != -sys.E.INTR) {
                if (stop_on_disconnect) return 0;
                host_open = false;
                _ = sys.shutdown(s, 1);
            }
        }
        if (pfds[1].revents != 0) {
            const n = sys.read(s, &buf);
            if (n > 0) {
                if (sys.writeAll(conn, buf[0..@intCast(n)]) < 0) return 1;
            } else if (n != -sys.E.INTR) {
                if (stop_on_disconnect) return 1;
                peer_open = false;
                _ = sys.shutdown(conn, 1);
            }
        }
    }
    return 0;
}

const udp_idle_ms = 90_000;

fn opRelayUdp(conn: isize, req: Value) i32 {
    const port: u16 = @intCast(req.intOr("port", 0));
    const target = RelayAddr.parse(req.strOr("ip", ""), port) orelse {
        ackErr(conn, "bad ip", sys.E.INVAL);
        return 1;
    };
    const s = sys.socket(target.family(), sys.SOCK_DGRAM, 0);
    if (s < 0) {
        ackErr(conn, "socket", @intCast(-s));
        return 1;
    }
    const rc = target.connect(s);
    if (rc < 0) {
        ackErr(conn, "connect", @intCast(-rc));
        return 1;
    }
    if (!ackOk(conn)) return 1;
    var buf: [65536 + 4]u8 = undefined;
    while (true) {
        var pfds = [2]sys.PollFd{
            .{ .fd = @intCast(conn), .events = sys.POLLIN, .revents = 0 },
            .{ .fd = @intCast(s), .events = sys.POLLIN, .revents = 0 },
        };
        const ready = sys.poll(&pfds, 2, udp_idle_ms);
        if (ready == 0) return 0; // idle past the host's 60 s expiry: the host side is gone or stuck
        if (ready < 0) continue;
        if (pfds[0].revents != 0) {
            var h: [4]u8 = undefined;
            if (sys.readAll(conn, &h) != 4) return 0;
            const len = frame.getU32(&h);
            if (len > 65535) return 1;
            if (sys.readAll(conn, buf[0..len]) != len) return 0;
            _ = sys.sendto(s, buf[0..len], null, 0);
        }
        if (pfds[1].revents != 0) {
            const n = sys.recvfrom(s, buf[4..], null, null);
            if (n >= 0) {
                frame.putU32(buf[0..4], @intCast(n));
                if (sys.writeAll(conn, buf[0 .. 4 + @as(usize, @intCast(n))]) < 0) return 0;
            }
        }
    }
}

// ------------------------------------------------------------------ exec_exit events

/// Asks the host to answer a DNS query. False when there is no host to ask.
pub fn emitDnsQuery(id: u16, query: []const u8) bool {
    if (ctl_fd < 0 or query.len > 512) return false;
    var enc: [700]u8 = undefined;
    const q64 = std.base64.standard.Encoder.encode(&enc, query);
    var b = json.Buf.init(util.arena());
    b.print("{{\"event\":\"dns_query\",\"id\":{d},\"query\":\"{s}\"}}", .{ id, q64 }) catch return false;
    var out = util.arena().alloc(u8, 4 + b.bytes().len) catch return false;
    frame.putU32(out[0..4], @intCast(b.bytes().len));
    @memcpy(out[4..], b.bytes());
    return sys.writeAll(ctl_fd, out) >= 0;
}

/// Write end of the event pipe PID 1 forwards to the control stream. One write per frame, under PIPE_BUF, so frames never interleave.
pub var evt_fd: isize = -1;
const pipe_buf = 4096;

pub fn emitExecExit(exec_id: []const u8, code: i32) void {
    if (evt_fd < 0) return;
    var b = json.Buf.init(util.arena());
    b.raw("{\"event\":\"exec_exit\",\"exec\":") catch return;
    b.str(exec_id) catch return;
    b.print(",\"code\":{d}}}", .{code}) catch return;
    var out = util.arena().alloc(u8, 4 + b.bytes().len) catch return;
    frame.putU32(out[0..4], @intCast(b.bytes().len));
    @memcpy(out[4..], b.bytes());
    if (out.len > pipe_buf) return;
    _ = sys.write(evt_fd, out);
}
