//! Control-port (vsock 1032) operations: parse a request frame, run it, build the response frame.
const std = @import("std");
const sys = @import("sys.zig");
const util = @import("util.zig");
const json = @import("json");
const frame = @import("frame");
const container = @import("container.zig");
const layers = @import("layers.zig");
const net = @import("net.zig");
const resolver = @import("resolver.zig");
const fspoke = @import("fspoke.zig");
const meminfo = @import("meminfo.zig");
const Value = json.Value;

pub var shutdown_requested = false;
pub var boot_ns: u64 = 0;

const Resp = struct {
    b: json.Buf,
    id: i64,

    fn start(a: std.mem.Allocator, id: i64) Resp {
        var r = Resp{ .b = json.Buf.init(a), .id = id };
        r.b.print("{{\"id\":{d},\"ok\":true", .{id}) catch {};
        return r;
    }
    fn finish(self: *Resp) []const u8 {
        self.b.byte('}') catch {};
        return self.b.bytes();
    }
};

/// `in_start` marks an error from the start part of `start` or of `create` with `start`.
fn errorResponse(a: std.mem.Allocator, id: i64, msg: []const u8, errno: i32, in_start: bool) []const u8 {
    var b = json.Buf.init(a);
    b.print("{{\"id\":{d},\"ok\":false,\"error\":", .{id}) catch {};
    b.str(msg) catch {};
    b.print(",\"errno\":{d}{s}}}", .{ errno, if (in_start) ",\"stage\":\"start\"" else "" }) catch {};
    return b.bytes();
}
var starting = false;

fn signalNumber(v: ?Value) i64 {
    const val = v orelse return 15;
    switch (val) {
        .int => |i| return i,
        .str => |s| {
            var name = s;
            if (std.mem.startsWith(u8, name, "SIG")) name = name[3..];
            if (std.fmt.parseInt(i64, name, 10)) |n| return n else |_| {}
            const table = [_]struct { n: []const u8, v: i64 }{
                .{ .n = "HUP", .v = 1 },   .{ .n = "INT", .v = 2 },   .{ .n = "QUIT", .v = 3 },   .{ .n = "ILL", .v = 4 },
                .{ .n = "TRAP", .v = 5 },  .{ .n = "ABRT", .v = 6 },  .{ .n = "BUS", .v = 7 },    .{ .n = "FPE", .v = 8 },
                .{ .n = "KILL", .v = 9 },  .{ .n = "USR1", .v = 10 }, .{ .n = "SEGV", .v = 11 },  .{ .n = "USR2", .v = 12 },
                .{ .n = "PIPE", .v = 13 }, .{ .n = "ALRM", .v = 14 }, .{ .n = "TERM", .v = 15 },  .{ .n = "CHLD", .v = 17 },
                .{ .n = "CONT", .v = 18 }, .{ .n = "STOP", .v = 19 }, .{ .n = "TSTP", .v = 20 },  .{ .n = "TTIN", .v = 21 },
                .{ .n = "TTOU", .v = 22 }, .{ .n = "URG", .v = 23 },  .{ .n = "WINCH", .v = 28 },
            };
            for (table) |t| if (std.mem.eql(u8, t.n, name)) return t.v;
            return 15;
        },
        else => return 15,
    }
}

fn dirSize(fd: isize, depth: u32) u64 {
    if (depth > 64) return 0;
    var total: u64 = 0;
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
            off += reclen;
            if (std.mem.eql(u8, s, ".") or std.mem.eql(u8, s, "..")) continue;
            var st: sys.Stat = undefined;
            if (sys.fstatat(fd, nm, &st, sys.AT_SYMLINK_NOFOLLOW) >= 0) total += @as(u64, @intCast(st.blocks)) * 512;
            if (dtype == 4) {
                const sub = sys.openat(fd, nm, sys.O.RDONLY | sys.O.DIRECTORY | sys.O.NOFOLLOW, 0);
                if (sub >= 0) {
                    total += dirSize(sub, depth + 1);
                    sys.close(sub);
                }
            }
        }
    }
    return total;
}

fn validName(s: []const u8) bool {
    return util.validVolumeName(s);
}

// Long filesystem walks (volume_size, diff) run in a forked child so PID 1's loop keeps serving DNS, output pipes and control.
// The child runs the normal handler and writes the response JSON to a pipe; the loop sends it, tagged job, once the pipe hits EOF.
const Job = struct { fd: isize = -1, id: i64 = 0, bad: bool = false, buf: std.ArrayList(u8) = .empty };
var jobs: [16]Job = @splat(.{});
var in_job = false;
const job_cap = 256 * 1024 * 1024;

fn forkJob(id: i64, payload: []const u8) bool {
    var slot: u32 = 0;
    while (slot < jobs.len and jobs[slot].fd >= 0) slot += 1;
    if (slot == jobs.len) return false; // table full: the caller answers busy
    net.dhcpFinish(); // the child must not settle the lease for the parent
    var p: [2]i32 = undefined;
    if (sys.pipe2(&p, sys.O.NONBLOCK) < 0) return false;
    const pid = sys.fork();
    if (pid < 0) {
        sys.close(p[0]);
        sys.close(p[1]);
        return false;
    }
    if (pid == 0) {
        sys.close(p[0]);
        sys.close(@import("stream.zig").ctl_fd); // a stale copy would keep a dropped control connection open
        container.closeStdinRelaysInChild();
        resolver.closeConnsInChild();
        in_job = true;
        const resp = handle(payload);
        var hdr: [4]u8 = undefined;
        std.mem.writeInt(u32, &hdr, @intCast(resp.len), .little);
        _ = sys.writeAll(p[1], &hdr);
        _ = sys.writeAll(p[1], resp);
        sys.exit(0);
    }
    sys.close(p[1]);
    jobs[slot] = .{ .fd = p[0], .id = id };
    if (sys.epoll_add(util.epfd, p[0], sys.EPOLLIN, util.tag(util.Tag.job, slot)) < 0) {
        sys.close(p[0]);
        jobs[slot] = .{};
        return false; // run inline; the child gets EPIPE
    }
    return true;
}

/// Pipe event for a job. Returns the response once the child has finished.
pub fn onJob(slot: u32) ?[]const u8 {
    if (slot >= jobs.len) return null;
    const j = &jobs[slot];
    if (j.fd < 0) return null;
    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        const n = sys.read(j.fd, &chunk);
        if (n == -sys.E.AGAIN) return null;
        if (n == -sys.E.INTR) continue;
        if (n > 0 and j.buf.items.len < job_cap) {
            j.buf.appendSlice(std.heap.page_allocator, chunk[0..@intCast(n)]) catch {
                j.bad = true;
            };
            continue;
        }
        if (n > 0) {
            j.bad = true; // over the cap: the tail is dropped
            continue;
        }
        break;
    }
    _ = sys.epoll_del(util.epfd, j.fd);
    sys.close(j.fd);
    const a = util.arena();
    const resp: []const u8 = if (j.bad or util.lengthPrefixed(j.buf.items) == null) errorResponse(a, j.id, "operation failed", sys.E.IO, false) else a.dupe(u8, util.lengthPrefixed(j.buf.items).?) catch errorResponse(a, j.id, "out of memory", sys.E.NOMEM, false);
    j.buf.deinit(std.heap.page_allocator);
    j.* = .{};
    return resp;
}

/// Handle one request payload. Returns the response JSON (arena memory).
pub fn handle(payload: []const u8) []const u8 {
    const a = util.arena();
    const req = json.parse(a, payload) catch return errorResponse(a, 0, "malformed request", sys.E.INVAL, false);
    const id = req.intOr("id", 0);
    const op = req.strOr("op", "");
    if (!in_job and (eq(op, "volume_size") or eq(op, "diff")) and forkJob(id, payload)) return "";
    // never walk in PID 1's loop; the host treats a failed diff as an error and a failed volume size as unknown
    if (!in_job and (eq(op, "volume_size") or eq(op, "diff"))) return errorResponse(a, id, "guest busy, try again", sys.E.AGAIN, false);
    var r = Resp.start(a, id);

    starting = false;
    const res = dispatch(&r, req, op, payload);
    if (res) |_| {
        if (eq(op, "start") or (eq(op, "create") and req.boolOr("start", false))) {
            if (container.find(req.strOr("container", ""))) |c| {
                if (c.start_status >= 0) {
                    c.start_request = id;
                    return ""; // response follows the CLOEXEC status pipe, via epoll
                }
            }
        }
        return r.finish();
    } else |_| {
        return errorResponse(a, id, container.emsg, container.eno, starting);
    }
}

pub fn receiveStartMaster(idx: u32) ?[]const u8 {
    const c = &container.conts[idx];
    if (!c.used or c.start_status < 0 or c.start_master < 0) return null;
    container.receiveStartMaster(c) catch {
        if (c.master < 0) {
            if (container.eno == sys.E.AGAIN) return null;
            // Setup errors close the handoff socket too. Preserve the detailed
            // childDie message arriving on the status pipe instead of masking it.
            _ = sys.epoll_del(util.epfd, c.start_master);
            sys.close(c.start_master);
            c.start_master = -1;
            return null;
        }
        container.abortStart(c);
        return errorResponse(util.arena(), c.start_request, container.emsg, container.eno, true);
    };
    return null;
}

pub fn completeStart(idx: u32) ?[]const u8 {
    const c = &container.conts[idx];
    if (!c.used or c.start_status < 0) return null;
    const done = container.finishStart(c) catch return errorResponse(util.arena(), c.start_request, container.emsg, container.eno, true);
    if (!done) return null;
    var r = Resp.start(util.arena(), c.start_request);
    r.b.print(",\"pid\":{d}", .{c.pid}) catch {};
    return r.finish();
}

fn dispatch(r: *Resp, req: Value, op: []const u8, payload: []const u8) container.Fail!void {
    const b = &r.b;
    const cid = req.strOr("container", "");
    // The container hot path runs without waiting. `create` and `start` decide about the lease themselves:
    // a --network none container needs none.
    // `host_loopback` installs its redirects when the lease arrives, so a boot never waits on it.
    const hot = eq(op, "ping") or eq(op, "vm_usage") or eq(op, "set_time") or eq(op, "layer_has") or eq(op, "create") or eq(op, "start") or eq(op, "remove") or eq(op, "host_loopback");
    if (!hot and !eq(op, "shutdown")) net.dhcpFinish();
    if (!hot) container.teardownFinish();
    if (eq(op, "ping")) {
        b.print(",\"version\":\"{s}\",\"uptime_ms\":{d}", .{ util.version, (sys.boottime_ns() - boot_ns) / 1_000_000 }) catch {};
    } else if (eq(op, "layer_has")) {
        b.raw(",\"present\":[") catch {};
        var first = true;
        const digests = req.list("digests");
        const diffs = req.list("diff_ids");
        if (digests.len != diffs.len) return container.fail("missing layer diff IDs", .{}, sys.E.INVAL);
        var pairs: std.StringHashMapUnmanaged([]const u8) = .empty;
        for (digests, diffs) |d, diff| {
            if (d != .str or diff != .str or !layers.validDigest(d.str) or !layers.validDigest(diff.str))
                return container.fail("invalid layer digest or diff ID", .{}, sys.E.INVAL);
            const pair = pairs.getOrPut(util.arena(), d.str) catch return container.fail("layer list too large", .{}, sys.E.NOMEM);
            if (pair.found_existing) {
                if (!eq(pair.value_ptr.*, diff.str)) return container.fail("conflicting layer diff IDs", .{}, sys.E.INVAL);
                continue;
            }
            pair.value_ptr.* = diff.str;
            if (layers.matches(d.str[7..], diff.str)) {
                if (!first) b.byte(',') catch {};
                first = false;
                b.str(d.str) catch {};
            }
        }
        b.byte(']') catch {};
    } else if (eq(op, "layer_remove")) {
        for (req.list("digests")) |d| if (d == .str) {
            const hex = util.hexOf(d.str);
            if (util.validHex(hex) and !layers.remove(hex)) return container.fail("layer in use", .{}, sys.E.BUSY);
        };
    } else if (eq(op, "create")) {
        const spec = req.get("spec") orelse return container.fail("spec missing", .{}, sys.E.INVAL);
        if (container.specNeedsLease(spec)) net.dhcpFinish();
        try container.create(cid, payload, spec);
        if (req.boolOr("start", false)) {
            starting = true;
            const pid = try container.start(cid);
            b.print(",\"pid\":{d}", .{pid}) catch {};
        }
    } else if (eq(op, "start")) {
        starting = true;
        const pid = try container.start(cid);
        b.print(",\"pid\":{d}", .{pid}) catch {};
    } else if (eq(op, "kill")) {
        try container.kill(cid, signalNumber(req.get("signal")));
    } else if (eq(op, "pause")) {
        try container.pause(cid, true);
    } else if (eq(op, "unpause")) {
        try container.pause(cid, false);
    } else if (eq(op, "remove")) {
        try container.remove(cid);
    } else if (eq(op, "update")) {
        try container.updateLimits(cid, req);
    } else if (eq(op, "stats")) {
        try container.stats(cid, b);
    } else if (eq(op, "vm_usage")) {
        if (util.readFile("/proc/meminfo", 16 << 10)) |text| {
            if (meminfo.memoryUsed(text)) |used| b.print(",\"memory_used\":{d}", .{used}) catch {};
        }
        if (util.readFile("/proc/stat", 16 << 10)) |text| {
            if (meminfo.cpuUsage(text)) |cpu| b.print(",\"cpu_busy\":{d},\"cpu_total\":{d}", .{ cpu.busy, cpu.total }) catch {};
        }
    } else if (eq(op, "top")) {
        try container.top(cid, b);
    } else if (eq(op, "list_ports")) {
        try listPorts(cid, b);
    } else if (eq(op, "diff")) {
        try container.diff(cid, b);
    } else if (eq(op, "resize")) {
        try container.resize(cid, req.intOr("rows", 24), req.intOr("cols", 80));
    } else if (eq(op, "net_create")) {
        const rc = net.createNetwork(req.strOr("network", ""), req.strOr("bridge", ""), req.strOr("subnet", ""), req.strOr("gateway", ""), req.strOr("subnet6", ""), req.strOr("gateway6", ""), req.boolOr("internal", false));
        if (rc < 0) return container.fail("network create failed", .{}, rc);
    } else if (eq(op, "net_remove")) {
        const rc = net.removeNetwork(req.strOr("network", ""));
        if (rc < 0) return container.fail("network remove failed", .{}, rc);
    } else if (eq(op, "net_connect")) {
        try container.netConnect(cid, req.strOr("network", ""), req.strOr("ip", ""), req.strOr("ip6", ""), req.strOr("mac", ""), req.list("aliases"), req.get("resolver"));
    } else if (eq(op, "dns_answer")) {
        resolver.onHostAnswer(req.intOr("query", -1), req.strOr("answer", ""));
    } else if (eq(op, "net_disconnect")) {
        try container.netDisconnect(cid, req.strOr("network", ""));
    } else if (eq(op, "dns_set")) {
        const n = net.findNet(req.strOr("network", "")) orelse return container.fail("network not found", .{}, sys.E.NOENT);
        var recs: std.ArrayList(net.Rec) = .empty;
        for (req.list("records")) |rv| {
            const nm = rv.strOr("name", "");
            const ip = util.parseIp4(rv.strOr("ip", ""));
            const ip6 = util.parseIp6(rv.strOr("ip6", ""));
            if (ip == null and ip6 == null) continue;
            recs.append(util.arena(), .{ .name = nm, .ip = ip, .ip6 = ip6 }) catch {};
        }
        net.setRecords(n, recs.items);
    } else if (eq(op, "volume_create")) {
        const name = req.strOr("name", "");
        if (!validName(name)) return container.fail("invalid volume name", .{}, sys.E.INVAL);
        const rc = util.mkdirp(std.mem.span(util.zf("{s}/volumes/{s}", .{ util.base, name }).ptr), 0o755);
        if (rc < 0) return container.fail("volume create failed", .{}, rc);
    } else if (eq(op, "volume_remove")) {
        const name = req.strOr("name", "");
        if (!validName(name)) return container.fail("invalid volume name", .{}, sys.E.INVAL);
        if (container.volumeInUse(null, name)) return container.fail("volume is in use", .{}, sys.E.BUSY);
        const volume = @import("volume.zig");
        volume.remove(util.zdup(name)) catch |err| return container.fail("volume remove: {s}", .{@errorName(err)}, volume.last_errno);
    } else if (eq(op, "volume_size")) {
        const name = req.strOr("name", "");
        if (!validName(name)) return container.fail("invalid volume name", .{}, sys.E.INVAL);
        const fd = sys.open(util.zf("{s}/volumes/{s}", .{ util.base, name }).ptr, sys.O.RDONLY | sys.O.DIRECTORY, 0);
        if (fd < 0) return container.fail("no such volume", .{}, fd);
        defer sys.close(fd);
        b.print(",\"bytes\":{d}", .{dirSize(fd, 0)}) catch {};
    } else if (eq(op, "ssh_agent")) {
        if (util.workload) return container.fail("SSH agent forwarding is not available in the workload VM", .{}, sys.E.INVAL);
        const rc = @import("sshagent.zig").ensure(0);
        if (rc < 0) return container.fail("ssh agent socket: errno {d}", .{-rc}, rc);
    } else if (eq(op, "docker_api")) {
        if (util.workload) return container.fail("Docker API forwarding is not available in the workload VM", .{}, sys.E.INVAL);
        const rc = @import("sshagent.zig").ensure(1);
        if (rc < 0) return container.fail("docker api socket: errno {d}", .{-rc}, rc);
    } else if (eq(op, "host_loopback")) {
        if (util.workload) return container.fail("Mac loopback access is not available in the workload VM", .{}, sys.E.INVAL);
        const rc = @import("hostlo.zig").enable();
        if (rc < 0) return container.fail("Mac loopback relay: errno {d}", .{-rc}, rc);
    } else if (eq(op, "fs_poke")) {
        var rels: [fspoke.max_paths][]const u8 = undefined;
        var n: usize = 0;
        for (req.list("paths")) |pv| {
            if (pv != .str or n == rels.len) continue;
            rels[n] = pv.str;
            n += 1;
        }
        const outcome = fspoke.pokeAll(rels[0..n]);
        b.print(",\"poked\":{d},\"stale\":{d}", .{ outcome.poked, outcome.stale }) catch {};
    } else if (eq(op, "balloon_hint")) {
        const cache = meminfo.fileCache(util.readFile("/proc/meminfo", 16 << 10) orelse "");
        b.print(",\"cache\":{d}", .{cache}) catch {};
        sys.sync();
        _ = util.writeSys("/proc/sys/vm/drop_caches", "3");
        _ = util.writeSys("/proc/sys/vm/compact_memory", "1");
        const pages = meminfo.vmstat(util.readFile("/proc/vmstat", 16 << 10) orelse "", "nr_balloon_pages") orelse 0;
        const balloon = pages *| @as(u64, std.heap.pageSize());
        if (meminfo.guestUsed(util.readFile("/proc/meminfo", 16 << 10) orelse "", balloon)) |used| b.print(",\"used\":{d}", .{used}) catch {};
    } else if (eq(op, "set_time")) {
        const sec = req.intOr("sec", 0);
        const ns = req.intOr("nsec", 0);
        if (sec <= 0 or ns < 0 or ns >= 1_000_000_000) return container.fail("invalid time", .{}, sys.E.INVAL);
        const rc = sys.clock_set_realtime(sec, ns);
        if (rc < 0) return container.fail("clock_settime: errno {d}", .{-rc}, rc);
    } else if (eq(op, "shutdown")) {
        shutdown_requested = true;
    } else {
        return container.fail("unknown op {s}", .{op}, sys.E.NOSYS);
    }
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// On-demand procfs snapshot. /proc/<pid>/net is scoped to that process's network
// namespace, so PID 1 never needs to join a container namespace or spawn a helper.
fn listPorts(cid: []const u8, b: *json.Buf) container.Fail!void {
    const c = container.find(cid) orelse return container.fail("no such container", .{}, sys.E.NOENT);
    if (c.state != .running or c.pid <= 0) return container.fail("container is not running", .{}, sys.E.INVAL);
    const a = util.arena();
    var owners: std.AutoHashMapUnmanaged(u64, []const u8) = .empty;
    const procs = util.readFile(util.zf("/sys/fs/cgroup/noodle/{s}/cgroup.procs", .{cid}).ptr, 1 << 16) orelse
        return container.fail("cannot read container processes", .{}, sys.E.IO);
    if (procs.len >= 1 << 16) return container.fail("too many container processes to inspect", .{}, sys.E.INVAL);
    var pids = std.mem.tokenizeScalar(u8, procs, '\n');
    var scanned: usize = 0;
    while (pids.next()) |ps| {
        const pid = std.fmt.parseInt(u32, ps, 10) catch continue;
        const comm = util.readFile(util.zf("/proc/{d}/comm", .{pid}).ptr, 4096) orelse continue;
        const name = std.mem.trimEnd(u8, comm, "\n");
        const fd = sys.open(util.zf("/proc/{d}/fd", .{pid}).ptr, sys.O.RDONLY | sys.O.DIRECTORY, 0);
        if (fd < 0) continue; // A process may exit during the snapshot.
        defer sys.close(fd);
        var entries: [4096]u8 align(8) = undefined;
        while (true) {
            const n = sys.getdents64(fd, &entries);
            if (n <= 0) break;
            var off: usize = 0;
            while (off < @as(usize, @intCast(n))) {
                const reclen = std.mem.readInt(u16, entries[off + 16 ..][0..2], .little);
                const entry: [*:0]const u8 = @ptrCast(&entries[off + 19]);
                off += reclen;
                scanned += 1;
                if (scanned > 65536) return container.fail("too many process descriptors to inspect", .{}, sys.E.INVAL);
                var target: [128]u8 = undefined;
                const len = sys.readlinkat(fd, entry, &target);
                if (len <= 0 or len >= target.len) continue;
                const link = target[0..@intCast(len)];
                if (!std.mem.startsWith(u8, link, "socket:[") or !std.mem.endsWith(u8, link, "]")) continue;
                const inode = std.fmt.parseInt(u64, link[8 .. link.len - 1], 10) catch continue;
                owners.put(a, inode, name) catch return container.fail("not enough memory to inspect ports", .{}, sys.E.NOMEM);
            }
        }
    }
    b.raw(",\"ports\":[") catch {};
    var first = true;
    for ([_][]const u8{ "tcp", "tcp6", "udp", "udp6" }) |table| {
        const data = util.readFile(util.zf("/proc/{d}/net/{s}", .{ c.pid, table }).ptr, 1 << 20) orelse {
            // IPv6 tables are absent on kernels without IPv6.
            if (table[table.len - 1] == '6') continue;
            return container.fail("cannot read container socket table", .{}, sys.E.IO);
        };
        if (data.len >= 1 << 20) return container.fail("container socket table is too large", .{}, sys.E.INVAL);
        var lines = std.mem.tokenizeScalar(u8, data, '\n');
        _ = lines.next(); // header
        while (lines.next()) |line| {
            var fields = std.mem.tokenizeAny(u8, line, " \t");
            _ = fields.next();
            const local = fields.next() orelse continue;
            _ = fields.next();
            const state = fields.next() orelse continue;
            if (table[0] == 't' and !eq(state, "0A")) continue;
            var skip: usize = 0;
            while (skip < 5) : (skip += 1) _ = fields.next();
            const inode = std.fmt.parseInt(u64, fields.next() orelse "", 10) catch continue;
            const colon = std.mem.lastIndexOfScalar(u8, local, ':') orelse continue;
            const port = std.fmt.parseInt(u16, local[colon + 1 ..], 16) catch continue;
            if (port == 0) continue;
            const address = socketAddress(local[0..colon]) orelse continue;
            if (!first) b.byte(',') catch {};
            first = false;
            b.print("{{\"port\":{d},\"protocol\":\"{s}\",\"address\":", .{ port, table[0..3] }) catch {};
            b.str(address) catch {};
            if (owners.get(inode)) |name| {
                b.raw(",\"process\":") catch {};
                b.str(name) catch {};
            }
            b.byte('}') catch {};
        }
    }
    // The main process can exit while procfs is read; avoid returning a successful
    // snapshot for a PID that was already gone before the final check.
    var st: sys.Stat = undefined;
    if (sys.fstatat(sys.AT_FDCWD, util.zf("/proc/{d}", .{c.pid}).ptr, &st, 0) < 0)
        return container.fail("container is not running", .{}, sys.E.NOENT);
    b.byte(']') catch {};
}

fn socketAddress(hex: []const u8) ?[]const u8 {
    if (hex.len != 8 and hex.len != 32) return null;
    var bytes: [16]u8 = undefined;
    var word: usize = 0;
    while (word < hex.len / 8) : (word += 1) {
        const n = std.fmt.parseInt(u32, hex[word * 8 ..][0..8], 16) catch return null;
        std.mem.writeInt(u32, bytes[word * 4 ..][0..4], n, .little);
    }
    if (hex.len == 8) return util.sf("{d}.{d}.{d}.{d}", .{ bytes[0], bytes[1], bytes[2], bytes[3] });
    return util.sf("{x}:{x}:{x}:{x}:{x}:{x}:{x}:{x}", .{
        std.mem.readInt(u16, bytes[0..2], .big),   std.mem.readInt(u16, bytes[2..4], .big),
        std.mem.readInt(u16, bytes[4..6], .big),   std.mem.readInt(u16, bytes[6..8], .big),
        std.mem.readInt(u16, bytes[8..10], .big),  std.mem.readInt(u16, bytes[10..12], .big),
        std.mem.readInt(u16, bytes[12..14], .big), std.mem.readInt(u16, bytes[14..16], .big),
    });
}
