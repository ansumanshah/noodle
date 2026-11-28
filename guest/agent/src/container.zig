//! Container lifecycle: create (overlay + cgroup), start (clone3 into namespaces, pivot_root, exec),
//! exits, signals, stats, top, diff, networks per container.
const std = @import("std");
const sys = @import("sys.zig");
const util = @import("util.zig");
const json = @import("json");
const net = @import("net.zig");
const resolver = @import("resolver.zig");
const bpf = @import("bpf.zig");
const devcg = @import("devcg.zig");
const timing = @import("timing.zig");
const netns = @import("netns.zig");
const Value = json.Value;

pub const Fail = error{Fail};
var emsg_buf: [512]u8 = undefined;
pub var emsg: []const u8 = "";
pub var eno: i32 = 0;

pub fn fail(comptime fmt: []const u8, args: anytype, errno: isize) Fail {
    emsg = std.fmt.bufPrint(&emsg_buf, fmt, args) catch "error";
    eno = if (errno < 0) @intCast(-errno) else @intCast(errno);
    return error.Fail;
}

pub const max_conts = 128;
pub const max_nets_per = 4;

pub const State = enum { created, running, exited };

pub const CNet = struct {
    used: bool = false,
    attached: bool = false,
    name: [64]u8 = undefined,
    nlen: u8 = 0,
    host_if: [16]u8 = undefined,
    hlen: u8 = 0,
    ip: ?[4]u8 = null,
    prefix: u8 = 0,
    mac: ?[6]u8 = null,
    gateway: ?[4]u8 = null,
    ip6: ?[16]u8 = null,
    prefix6: u8 = 0,
    gateway6: ?[16]u8 = null,
};

pub const Cont = struct {
    used: bool = false,
    id: [64]u8 = undefined,
    idlen: u8 = 0,
    state: State = .created,
    pid: i32 = 0,
    netns: u64 = 0,
    code: i32 = 0,
    tty: bool = false,
    has_stdin: bool = false,
    master: i32 = -1, // master received from the container's devpts
    tty_requests: [2]i32 = .{ -1, -1 }, // attach workers request their own duplicate
    start_status: i32 = -1,
    start_master: i32 = -1,
    start_request: i64 = 0,
    start_error: [400]u8 = undefined,
    start_error_len: usize = 0,
    // Non-tty stdin: attach workers write stdin_b; PID 1 splices stdin_a into the stdin_w pipe, and the container reads stdin_r as fd 0.
    // fd 0 must not be a socket: busybox cat would sendfile from it while holding its stdout pipe lock, blocking PID 1's read of that pipe.
    stdin_b: i32 = -1, // attach end of the stdin socketpair (shutdown(SHUT_WR) is EOF)
    stdin_a: i32 = -1, // PID 1 end of the socketpair, relayed while open
    stdin_r: i32 = -1, // container end of the stdin pipe (held until start)
    stdin_w: i32 = -1, // PID 1 end of the stdin pipe; closing it is the container's EOF
    out: [2]i32 = .{ -1, -1 }, // stdout/stderr read ends (non-tty)
    log_fd: i32 = -1,
    log_size: u64 = 0, // bytes in the current log file
    log_max: u64 = 0, // rotate when a frame would pass this; 0 = never
    log_files: u32 = 1, // files kept, the current one included
    nets: [max_nets_per]CNet = @splat(.{}),

    pub fn idStr(self: *const Cont) []const u8 {
        return self.id[0..self.idlen];
    }
};

pub var conts: [max_conts]Cont = std.mem.zeroes([max_conts]Cont); // all-zero => .bss, `used` = false
var veth_seq: u64 = 0;

pub fn find(id: []const u8) ?*Cont {
    for (&conts) |*c| if (c.used and std.mem.eql(u8, c.idStr(), id)) return c;
    return null;
}
fn contIndex(c: *Cont) u32 {
    return @intCast((@intFromPtr(c) - @intFromPtr(&conts)) / @sizeOf(Cont));
}

pub fn cdir(id: []const u8) [:0]u8 {
    return util.zf("{s}/containers/{s}", .{ util.base, id });
}
fn cgroupPath(id: []const u8) [:0]u8 {
    return util.zf("/sys/fs/cgroup/noodle/{s}", .{id});
}
pub fn logPath(id: []const u8) [:0]u8 {
    return util.zf("{s}/containers/{s}/log", .{ util.base, id });
}
pub fn exitPath(id: []const u8) [:0]u8 {
    return util.zf("{s}/containers/{s}/exit", .{ util.base, id });
}

// ------------------------------------------------------------------ capabilities

const cap_names = [_][]const u8{
    "CHOWN",              "DAC_OVERRIDE",    "DAC_READ_SEARCH",  "FOWNER",        "FSETID",        "KILL",        "SETGID",        "SETUID",
    "SETPCAP",            "LINUX_IMMUTABLE", "NET_BIND_SERVICE", "NET_BROADCAST", "NET_ADMIN",     "NET_RAW",     "IPC_LOCK",      "IPC_OWNER",
    "SYS_MODULE",         "SYS_RAWIO",       "SYS_CHROOT",       "SYS_PTRACE",    "SYS_PACCT",     "SYS_ADMIN",   "SYS_BOOT",      "SYS_NICE",
    "SYS_RESOURCE",       "SYS_TIME",        "SYS_TTY_CONFIG",   "MKNOD",         "LEASE",         "AUDIT_WRITE", "AUDIT_CONTROL", "SETFCAP",
    "MAC_OVERRIDE",       "MAC_ADMIN",       "SYSLOG",           "WAKE_ALARM",    "BLOCK_SUSPEND", "AUDIT_READ",  "PERFMON",       "BPF",
    "CHECKPOINT_RESTORE",
};
const all_caps: u64 = (@as(u64, 1) << cap_names.len) - 1;
const default_caps = [_][]const u8{ "CHOWN", "DAC_OVERRIDE", "FSETID", "FOWNER", "MKNOD", "NET_RAW", "SETGID", "SETUID", "SETFCAP", "SETPCAP", "NET_BIND_SERVICE", "SYS_CHROOT", "KILL", "AUDIT_WRITE" };

fn capBit(name_in: []const u8) ?u6 {
    var name = name_in;
    if (std.mem.startsWith(u8, name, "CAP_")) name = name[4..];
    for (cap_names, 0..) |n, i| if (std.ascii.eqlIgnoreCase(n, name)) return @intCast(i);
    return null;
}

pub fn capMask(spec: Value) u64 {
    if (spec.boolOr("privileged", false)) return all_caps;
    var m: u64 = 0;
    for (default_caps) |n| m |= @as(u64, 1) << capBit(n).?;
    for (spec.list("cap_add")) |v| {
        if (v != .str) continue;
        if (std.ascii.eqlIgnoreCase(v.str, "ALL")) m = all_caps else if (capBit(v.str)) |b| m |= @as(u64, 1) << b;
    }
    for (spec.list("cap_drop")) |v| {
        if (v != .str) continue;
        if (std.ascii.eqlIgnoreCase(v.str, "ALL")) m = 0 else if (capBit(v.str)) |b| m &= ~(@as(u64, 1) << b);
    }
    return m;
}

// ------------------------------------------------------------------ cgroup helpers

fn cgWrite(id: []const u8, file: []const u8, val: []const u8) Fail!void {
    const p = util.zf("/sys/fs/cgroup/noodle/{s}/{s}", .{ id, file });
    const rc = util.writeSys(p.ptr, val);
    if (rc < 0) return fail("write cgroup {s}", .{file}, rc);
}

/// cpuset.cpus or cpuset.mems. The kernel checks the list against what the VM has; a refusal says so in words.
fn cgWriteCpuset(id: []const u8, file: []const u8, flag: []const u8, val: []const u8) Fail!void {
    for (val) |ch| if (!std.ascii.isDigit(ch) and ch != ',' and ch != '-') return fail("invalid {s} \"{s}\"", .{ flag, val }, sys.E.INVAL);
    const p = util.zf("/sys/fs/cgroup/noodle/{s}/{s}", .{ id, file });
    const rc = util.writeSys(p.ptr, val);
    if (rc >= 0) return;
    if (rc == -sys.E.NOENT) return fail("{s} is not supported: this VM's kernel has no cpuset controller", .{flag}, rc);
    const have = util.readFile(util.zf("/sys/fs/cgroup/noodle/{s}.effective", .{file}).ptr, 256) orelse "?";
    return fail("invalid {s} \"{s}\": this VM offers {s}", .{ flag, val, std.mem.trim(u8, have, " \n") }, rc);
}

/// Write cgroup limits from a create spec or an update request (same field names).
pub fn applyLimits(id: []const u8, v: Value) Fail!void {
    var b: [64]u8 = undefined;
    const memory = v.intOr("memory", 0);
    if (memory > 0) try cgWrite(id, "memory.max", std.fmt.bufPrint(&b, "{d}", .{memory}) catch "max") else try cgWrite(id, "memory.max", "max");
    // Docker's memory-swap is memory plus swap; -1 or unset leaves swap unlimited.
    const memswap = v.intOr("memory_swap", 0);
    if (memory > 0 and memswap >= memory) try cgWrite(id, "memory.swap.max", std.fmt.bufPrint(&b, "{d}", .{memswap - memory}) catch "max");
    const reservation = v.intOr("memory_reservation", 0);
    if (reservation > 0) try cgWrite(id, "memory.low", std.fmt.bufPrint(&b, "{d}", .{reservation}) catch "0");
    const cpus = v.floatOr("cpus", 0);
    const cpu_quota = v.intOr("cpu_quota", 0);
    if (cpu_quota > 0) {
        const period = v.intOr("cpu_period", 100000);
        try cgWrite(id, "cpu.max", std.fmt.bufPrint(&b, "{d} {d}", .{ @max(cpu_quota, 1000), if (period > 0) period else 100000 }) catch "max 100000");
    } else if (cpus > 0) {
        const quota: i64 = @intFromFloat(cpus * 100000.0);
        try cgWrite(id, "cpu.max", std.fmt.bufPrint(&b, "{d} 100000", .{@max(quota, 1000)}) catch "max 100000");
    } else try cgWrite(id, "cpu.max", "max 100000");
    const shares = v.intOr("cpu_shares", 0);
    if (shares > 0) {
        const w: i64 = 1 + @divTrunc((@max(shares, 2) - 2) * 9999, 262142);
        try cgWrite(id, "cpu.weight", std.fmt.bufPrint(&b, "{d}", .{w}) catch "100");
    }
    const set_cpus = v.strOr("cpuset_cpus", "");
    if (set_cpus.len > 0) try cgWriteCpuset(id, "cpuset.cpus", "--cpuset-cpus", set_cpus);
    const set_mems = v.strOr("cpuset_mems", "");
    if (set_mems.len > 0) try cgWriteCpuset(id, "cpuset.mems", "--cpuset-mems", set_mems);
    const pids = v.intOr("pids_limit", 0);
    if (pids > 0) try cgWrite(id, "pids.max", std.fmt.bufPrint(&b, "{d}", .{pids}) catch "max") else try cgWrite(id, "pids.max", "max");
}

// ------------------------------------------------------------------ create

// Attach workers may fork before start. They send a private reply socket here;
// the agent retains it until the child supplies the master, then passes a duplicate.
const TtyWaiter = struct { used: bool = false, idx: u32 = 0, fd: i32 = -1 };
var tty_waiters: [128]TtyWaiter = std.mem.zeroes([128]TtyWaiter);
pub var pending_starts: usize = 0;
var tty_count: usize = 0;

pub fn onTtyWaiter(idx: u32) void {
    const w = &tty_waiters[idx];
    if (!w.used) return;
    // A stale event may refer to a reused slot: check the current endpoint.
    var pfd = sys.PollFd{ .fd = w.fd, .events = sys.POLLRDHUP, .revents = 0 };
    if (sys.poll(@ptrCast(&pfd), 1, 0) > 0) {
        _ = sys.epoll_del(util.epfd, w.fd);
        sys.close(w.fd);
        w.* = .{};
    }
}

pub fn onTtyRequest(idx: u32) void {
    const c = &conts[idx];
    if (!c.used or !c.tty) return;
    while (true) {
        const fd = sys.recvFd(c.tty_requests[0]);
        if (fd < 0) return;
        if (c.master >= 0) {
            _ = sys.sendFd(fd, c.master);
            sys.close(fd);
        } else if (c.state == .exited) {
            sys.close(fd);
        } else {
            const slot = for (&tty_waiters) |*w| {
                if (!w.used) break w;
            } else {
                sys.close(fd);
                continue;
            };
            const waiter_idx: u32 = @intCast((@intFromPtr(slot) - @intFromPtr(&tty_waiters)) / @sizeOf(TtyWaiter));
            if (sys.epoll_add(util.epfd, fd, sys.POLLRDHUP, util.tag(util.Tag.tty_waiter, waiter_idx)) < 0) {
                sys.close(fd);
                continue;
            }
            slot.* = .{ .used = true, .idx = idx, .fd = @intCast(fd) };
        }
    }
}

fn finishTtyWaiters(c: *Cont) void {
    if (!c.tty) return;
    for (&tty_waiters) |*w| {
        if (!w.used or w.idx != contIndex(c)) continue;
        if (c.master >= 0) _ = sys.sendFd(w.fd, c.master);
        _ = sys.epoll_del(util.epfd, w.fd);
        sys.close(w.fd);
        w.* = .{};
    }
}

/// Forked stream workers request masters from the broker; retaining the agent's
/// unrelated master or startup endpoints would pin PTYs after their owner exits.
pub fn closeTtysInStreamChild() void {
    if (tty_count == 0) return;
    for (&conts) |*c| {
        if (!c.used or !c.tty) continue;
        sys.close(c.master);
        c.master = -1;
        sys.close(c.start_master);
        c.start_master = -1;
        if (c.start_status >= 0) c.state = .created; // fork-local: setup has not established the workload root yet
        sys.close(c.start_status);
        c.start_status = -1;
        sys.close(c.tty_requests[0]);
        c.tty_requests[0] = -1;
    }
    for (&tty_waiters) |*w| {
        if (w.used) sys.close(w.fd);
        w.* = .{};
    }
}

fn savedWinsize(c: *Cont) ?[4]u16 {
    var ws: [4]u16 = undefined;
    const fd = sys.open(util.zf("{s}/winsize", .{cdir(c.idStr())}).ptr, sys.O.RDONLY, 0);
    if (fd < 0) return null;
    defer sys.close(fd);
    if (sys.readAll(fd, std.mem.asBytes(&ws)) != @sizeOf(@TypeOf(ws))) return null;
    return ws;
}

/// Called only after entering the container root, before dropping credentials.
/// The master is queued in the Unix socket before exec; no master survives in the workload.
fn childPty(status_w: i32, socket: i32, ws: [4]u16, spec: Value, req: ?Value, console: bool) void {
    const master = sys.open("/dev/pts/ptmx", sys.O.RDWR | sys.O.NOCTTY, 0);
    if (master < 0) childDie(status_w, "open container ptmx: errno {d}", .{-master});
    var unlock: i32 = 0;
    var rc = sys.ioctl(master, sys.TIOCSPTLCK, @intFromPtr(&unlock));
    if (rc < 0) childDie(status_w, "unlock pty: errno {d}", .{-rc});
    var n: u32 = 0;
    rc = sys.ioctl(master, sys.TIOCGPTN, @intFromPtr(&n));
    if (rc < 0) childDie(status_w, "pty number: errno {d}", .{-rc});
    const path = util.zf("/dev/pts/{d}", .{n});
    const slave = sys.open(path.ptr, sys.O.RDWR | sys.O.NOCTTY, 0);
    if (slave < 0) childDie(status_w, "open container pty slave: errno {d}", .{-slave});
    const user = if (req) |r| r.strOr("user", spec.strOr("user", "")) else spec.strOr("user", "");
    const ident = lookupUser(if (user.len > 0) user else spec.strOr("user", "")) orelse childDie(status_w, "unable to find tty user {s}", .{user});
    rc = sys.fchownat(slave, "", ident.uid, 5, sys.AT_EMPTY_PATH);
    if (rc < 0) childDie(status_w, "chown pty slave: errno {d}", .{-rc});
    var size = ws;
    rc = sys.ioctl(slave, sys.TIOCSWINSZ, @intFromPtr(&size));
    if (rc < 0) childDie(status_w, "initial pty size: errno {d}", .{-rc});
    if (console) mnt(status_w, path.ptr, "/dev/console", null, sys.MS.BIND, null);
    if (sys.setsid() < 0) childDie(status_w, "pty setsid failed", .{});
    if (sys.ioctl(slave, sys.TIOCSCTTY, 0) < 0) childDie(status_w, "pty controlling terminal failed", .{});
    for (0..3) |fd| {
        if (sys.dup3(slave, @intCast(fd), 0) < 0) childDie(status_w, "pty stdio failed", .{});
    }
    sys.close(slave);
    rc = sys.sendFd(socket, master);
    if (rc < 0) childDie(status_w, "send pty master: errno {d}", .{-rc});
    sys.close(master);
    // Only the child waits: the agent receives through epoll, applies any resize
    // received during namespace setup, then releases exec with one byte.
    var ready: [1]u8 = undefined;
    if (sys.readAll(socket, &ready) != 1 or ready[0] != 1) childDie(status_w, "pty master handoff was not acknowledged", .{});
    sys.close(socket);
}

fn checkSecurity(spec: Value) Fail!void {
    if (spec.boolOr("privileged", false) or !std.mem.eql(u8, spec.strOr("seccomp", "default"), "default")) {
        // Only the workload VM (no host shares, device policy attached) may run these.
        if (!util.workload) return fail("privileged or unconfined containers are unsupported in this VM", .{}, sys.E.INVAL);
        if (!devcg.active) return fail("the workload VM has no device policy; refusing privileged containers", .{}, sys.E.INVAL);
    }
    const dangerous_caps: u64 = (@as(u64, 1) << 16) | (@as(u64, 1) << 17) | (@as(u64, 1) << 21) | (@as(u64, 1) << 22) | (@as(u64, 1) << 38) | (@as(u64, 1) << 39);
    if (!util.workload and capMask(spec) & dangerous_caps != 0) return fail("requested capabilities are unsupported", .{}, sys.E.INVAL);
    if (util.workload and spec.get("mounts") != null) for (spec.list("mounts")) |m| {
        const kind = m.strOr("kind", "");
        if (std.mem.eql(u8, kind, "bind") and !util.host_shares) return fail("the workload VM has no host folders; bind mounts are not available", .{}, sys.E.INVAL);
        if (std.mem.eql(u8, kind, "docker") or std.mem.eql(u8, kind, "agent")) return fail("the workload VM has no Mac relays; agent and Docker socket mounts are not available", .{}, sys.E.INVAL);
    };
    for (spec.list("ulimits")) |lim| {
        const name = lim.strOr("name", "");
        const soft = lim.int_("soft") orelse return fail("invalid ulimit", .{}, sys.E.INVAL);
        const hard = lim.int_("hard") orelse return fail("invalid ulimit", .{}, sys.E.INVAL);
        if (limitResource(name) == null or soft < -1 or hard < -1 or (hard != -1 and (soft == -1 or soft > hard)))
            return fail("invalid ulimit {s}", .{name}, sys.E.INVAL);
    }
    if (spec.get("sysctls")) |values| {
        if (values != .obj) return fail("invalid sysctls", .{}, sys.E.INVAL);
        const mode = spec.strOr("network_mode", "bridge");
        var pb: [150]u8 = undefined;
        for (values.obj) |entry| {
            if (util.netSysctlPath(&pb, entry.key) == null or entry.val != .str or entry.val.str.len == 0 or
                std.mem.eql(u8, mode, "host") or std.mem.startsWith(u8, mode, "container:"))
                return fail("unsupported sysctl {s}", .{entry.key}, sys.E.INVAL);
            for (entry.val.str) |ch| if (!util.isSysctlValueChar(ch)) return fail("invalid sysctl {s}", .{entry.key}, sys.E.INVAL);
        }
    }
}

/// Only --network none without a host-gateway name can run before the VM has its address.
pub fn specNeedsLease(spec: Value) bool {
    if (!std.mem.eql(u8, spec.strOr("network_mode", "bridge"), "none")) return true;
    for (spec.list("hosts")) |h| if (h == .str and util.hostGatewayNames(h.str) != null) return true;
    return false;
}

fn privateNet(mode: []const u8) bool {
    return !std.mem.eql(u8, mode, "host") and !std.mem.startsWith(u8, mode, "container:");
}

/// Empty `/etc/hostname`, `/etc/hosts` and `/etc/resolv.conf` under every image, made once per boot.
/// The agent binds the real files over them at start. Without this layer an image that lacks one
/// (alpine has no resolv.conf) makes every start create it in the upper, which copies up `/etc`.
/// It is the lowest layer, so whatever an image ships at those paths wins.
const mountpoints = util.base ++ "/layers/.mountpoints";
var mountpoints_ready = false;

fn ensureMountpoints() bool {
    if (mountpoints_ready) return true;
    if (util.mkdirp(mountpoints ++ "/etc", 0o755) < 0) return false;
    inline for (.{ "/etc/hostname", "/etc/hosts", "/etc/resolv.conf" }) |f| {
        const fd = sys.open(mountpoints ++ f, sys.O.WRONLY | sys.O.CREAT | sys.O.NOFOLLOW, 0o644);
        if (fd < 0) return false;
        sys.close(fd);
    }
    mountpoints_ready = true;
    return true;
}

pub fn create(id: []const u8, req_text: []const u8, spec: Value) Fail!void {
    if (!util.validId(id) or std.mem.eql(u8, id, ".") or std.mem.eql(u8, id, "..")) return fail("invalid container id", .{}, sys.E.INVAL);
    try checkSecurity(spec);
    if (find(id)) |existing| {
        if (existing.state == .running) return fail("container {s} is running", .{id}, sys.E.BUSY);
        const old = try loadSpec(id);
        const before = old.list("layers");
        const after = spec.list("layers");
        if (before.len != after.len or existing.tty != spec.boolOr("tty", false) or existing.has_stdin != spec.boolOr("stdin", false))
            return fail("container configuration changed", .{}, sys.E.INVAL);
        for (before, after) |a, b| {
            if (a != .str or b != .str or !std.mem.eql(u8, a.str, b.str)) return fail("container layers changed", .{}, sys.E.INVAL);
        }
        const rc = util.writeFile(util.zf("{s}/spec.json", .{cdir(id)}).ptr, req_text, 0o600);
        if (rc < 0) return fail("write spec", .{}, rc);
        try applyLimits(id, spec);
        setLogLimits(existing, spec);
        if (privateNet(spec.strOr("network_mode", "bridge"))) netns.prepare();
        return;
    }
    var slot: ?*Cont = null;
    for (&conts) |*c| if (!c.used) {
        slot = c;
        break;
    };
    const c = slot orelse return fail("too many containers", .{}, sys.E.NOMEM);
    // The container's network namespace is built on the other vCPU while the rest of create runs.
    if (privateNet(spec.strOr("network_mode", "bridge"))) netns.prepare();

    const dir = cdir(id);
    const fresh = !util.exists(dir.ptr);
    for ([_][]const u8{ "", "/upper", "/work", "/merged" }) |sub| {
        const rc = util.mkdirp(std.mem.span(util.zf("{s}{s}", .{ dir, sub }).ptr), 0o755);
        if (rc < 0) return fail("mkdir {s}{s}", .{ dir, sub }, rc);
    }
    errdefer if (fresh) util.rmTreePath(dir.ptr);

    // overlay
    var lower = std.ArrayList(u8).empty;
    const a = util.arena();
    const layers = spec.list("layers");
    for (layers) |l| {
        if (l != .str) return fail("bad layer entry", .{}, sys.E.INVAL);
        const hex = util.hexOf(l.str);
        if (!util.validHex(hex)) return fail("bad layer digest {s}", .{l.str}, sys.E.INVAL);
        if (!@import("layers.zig").has(hex)) return fail("layer {s} not found", .{l.str}, sys.E.NOENT);
        if (lower.items.len > 0) lower.append(a, ':') catch return fail("oom", .{}, sys.E.NOMEM);
        lower.appendSlice(a, std.mem.span(@import("layers.zig").layerPath(hex).ptr)) catch return fail("oom", .{}, sys.E.NOMEM);
    }
    if (layers.len == 0) {
        const empty = util.zf("{s}/layers/.empty", .{util.base});
        _ = util.mkdirp(std.mem.span(empty.ptr), 0o755);
        lower.appendSlice(a, std.mem.span(empty.ptr)) catch {};
    }
    if (lower.items.len > 3500) return fail("too many image layers", .{}, sys.E.INVAL);
    if (ensureMountpoints()) lower.appendSlice(a, ":" ++ mountpoints) catch return fail("oom", .{}, sys.E.NOMEM);
    const opts = util.zf("lowerdir={s},upperdir={s}/upper,workdir={s}/work", .{ lower.items, dir, dir });
    const merged = util.zf("{s}/merged", .{dir});
    var rc = sys.mount("overlay", merged.ptr, "overlay", sys.MS.NODEV, opts.ptr);
    if (rc < 0) return fail("overlay mount failed", .{}, rc);
    errdefer _ = sys.umount2(merged.ptr, 2);

    // cgroup
    const cg = cgroupPath(id);
    rc = sys.mkdirat(sys.AT_FDCWD, cg.ptr, 0o755);
    if (rc < 0 and rc != -sys.E.EXIST) return fail("cgroup mkdir", .{}, rc);
    errdefer _ = sys.unlinkat(sys.AT_FDCWD, cg.ptr, sys.AT_REMOVEDIR);
    try applyLimits(id, spec);

    // persist the request for start
    rc = util.writeFile(util.zf("{s}/spec.json", .{dir}).ptr, req_text, 0o600);
    if (rc < 0) return fail("write spec", .{}, rc);

    c.* = .{};
    c.used = true;
    @memcpy(c.id[0..id.len], id);
    c.idlen = @intCast(id.len);
    c.tty = spec.boolOr("tty", false);
    c.has_stdin = spec.boolOr("stdin", false);

    const lp = logPath(id);
    const lfd = sys.open(lp.ptr, sys.O.WRONLY | sys.O.CREAT | sys.O.APPEND, 0o600);
    if (lfd < 0) {
        c.used = false;
        return fail("open log", .{}, lfd);
    }
    c.log_fd = @intCast(lfd);
    var lst: sys.Stat = undefined;
    c.log_size = if (sys.fstat(lfd, &lst) >= 0) @intCast(lst.size) else 0;
    setLogLimits(c, spec);

    if (c.tty) {
        rc = sys.socketpair(sys.AF_UNIX, sys.SOCK_STREAM | sys.SOCK_NONBLOCK, &c.tty_requests);
        if (rc >= 0) rc = sys.epoll_add(util.epfd, c.tty_requests[0], sys.EPOLLIN, util.tag(util.Tag.tty_request, contIndex(c)));
        if (rc < 0) {
            for (c.tty_requests) |fd| sys.close(fd);
            sys.close(c.log_fd);
            c.used = false;
            return fail("tty attach socket", .{}, rc);
        }
        tty_count += 1;
    } else if (c.has_stdin) {
        rc = openStdin(c);
        if (rc < 0) {
            sys.close(c.log_fd);
            c.used = false;
            return fail("stdin relay", .{}, rc);
        }
    }
}

fn closeStdin(c: *Cont) void {
    for ([_]*i32{ &c.stdin_a, &c.stdin_w }) |fd| {
        if (fd.* >= 0) _ = sys.epoll_del(util.epfd, fd.*);
    }
    for ([_]*i32{ &c.stdin_b, &c.stdin_a, &c.stdin_r, &c.stdin_w }) |fd| {
        sys.close(fd.*);
        fd.* = -1;
    }
}

fn openStdin(c: *Cont) isize {
    closeStdin(c);
    var sp: [2]i32 = undefined;
    var rc = sys.socketpair(sys.AF_UNIX, sys.SOCK_STREAM, &sp);
    if (rc < 0) return rc;
    var pp: [2]i32 = undefined;
    rc = sys.pipe2(&pp, 0);
    if (rc < 0) {
        for (sp) |fd| sys.close(fd);
        return rc;
    }
    c.stdin_b = sp[0];
    c.stdin_a = sp[1];
    c.stdin_r = pp[0];
    c.stdin_w = pp[1];
    sys.setNonblock(c.stdin_a);
    sys.setNonblock(c.stdin_w);
    rc = sys.epoll_add(util.epfd, c.stdin_a, sys.EPOLLIN, util.tag(util.Tag.cont_stdin, contIndex(c) * 2));
    if (rc < 0) closeStdin(c);
    return rc;
}

/// Stops relaying: the container sees EOF and attach writes fail with EPIPE.
fn endStdin(c: *Cont) void {
    for ([_]*i32{ &c.stdin_a, &c.stdin_w }) |fd| {
        if (fd.* >= 0) _ = sys.epoll_del(util.epfd, fd.*);
        sys.close(fd.*);
        fd.* = -1;
    }
}

/// Moves stdin from the socket into the container's pipe without blocking or buffering. When the
/// pipe is full the socket is unwatched until the pipe is writable, so writers feel backpressure.
pub fn onStdin(idx: u32, writable: bool) void {
    if (idx >= max_conts) return;
    const c = &conts[idx];
    if (!c.used or c.stdin_a < 0 or c.stdin_w < 0) return;
    const sock_tag = util.tag(util.Tag.cont_stdin, idx * 2);
    if (writable) {
        _ = sys.epoll_del(util.epfd, c.stdin_w);
        _ = sys.epoll_add(util.epfd, c.stdin_a, sys.EPOLLIN, sock_tag);
    }
    var rounds: usize = 0;
    while (rounds < 16) : (rounds += 1) {
        const n = sys.splice(c.stdin_a, c.stdin_w, 65536, sys.SPLICE_F_NONBLOCK);
        if (n > 0 or n == -sys.E.INTR) continue;
        if (n == -sys.E.AGAIN) {
            var pfd = [1]sys.PollFd{.{ .fd = c.stdin_w, .events = sys.POLLOUT, .revents = 0 }};
            if (sys.poll(&pfd, 1, 0) > 0 and pfd[0].revents != 0) return; // the socket is empty
            _ = sys.epoll_del(util.epfd, c.stdin_a);
            _ = sys.epoll_add(util.epfd, c.stdin_w, sys.EPOLLOUT, sock_tag + 1);
            return;
        }
        // 0: the attach side shut down its write half. Negative: the container closed its stdin.
        endStdin(c);
        return;
    }
}

/// A forked worker must not keep a container's stdin pipe open, or closing PID 1's end gives no EOF.
pub fn closeStdinRelaysInChild() void {
    for (&conts) |*c| {
        if (!c.used) continue;
        for ([_]*i32{ &c.stdin_a, &c.stdin_r, &c.stdin_w }) |fd| {
            sys.close(fd.*);
            fd.* = -1;
        }
    }
}

// ------------------------------------------------------------------ start

const ClonArgs = extern struct {
    flags: u64 = 0,
    pidfd: u64 = 0,
    child_tid: u64 = 0,
    parent_tid: u64 = 0,
    exit_signal: u64 = 0,
    stack: u64 = 0,
    stack_size: u64 = 0,
    tls: u64 = 0,
    set_tid: u64 = 0,
    set_tid_size: u64 = 0,
    cgroup: u64 = 0,
};

pub fn loadSpec(id: []const u8) Fail!Value {
    const p = util.zf("{s}/containers/{s}/spec.json", .{ util.base, id });
    const text = util.readFile(p.ptr, 4 << 20) orelse return fail("spec.json missing", .{}, sys.E.NOENT);
    const root = json.parse(util.arena(), text) catch return fail("spec.json corrupt", .{}, sys.E.INVAL);
    return root.get("spec") orelse return fail("spec missing", .{}, sys.E.INVAL);
}

fn waitForEmptyCgroup(id: []const u8) Fail!void {
    const fd = sys.open(util.zf("{s}/cgroup.events", .{cgroupPath(id)}).ptr, sys.O.RDONLY, 0);
    if (fd < 0) return fail("open cgroup events", .{}, fd);
    defer sys.close(fd);
    const deadline = sys.boottime_ns() + 1_000_000_000;
    while (true) {
        var buf: [256]u8 = undefined;
        if (sys.lseek(fd, 0, 0) < 0) return fail("seek cgroup events", .{}, sys.E.IO);
        const n = sys.read(fd, &buf);
        if (n <= 0) return fail("read cgroup events", .{}, if (n < 0) n else -sys.E.IO);
        const populated = util.flatKey(buf[0..@intCast(n)], "populated") orelse return fail("invalid cgroup events", .{}, sys.E.IO);
        if (populated == 0) return;
        const now = sys.boottime_ns();
        if (now >= deadline) return fail("previous container processes are still exiting", .{}, sys.E.BUSY);
        var pfd = sys.PollFd{ .fd = @intCast(fd), .events = 2, .revents = 0 }; // POLLPRI: cgroup.events changed
        const rc = sys.poll(@ptrCast(&pfd), 1, @intCast((deadline - now + 999_999) / 1_000_000));
        if (rc < 0 and rc != -sys.E.INTR) return fail("wait cgroup events", .{}, rc);
    }
}

fn pruneEntry(parent: []const u8, name: []const u8, dtype: u8) void {
    if (dtype != 4) return; // DT_DIR
    pruneCgroup(util.zf("{s}/{s}", .{ parent, name }));
}

/// Remove an empty cgroup subtree depth-first (cgroupfs only allows rmdir on directories).
fn pruneCgroup(path: [:0]const u8) void {
    const fd = sys.open(path.ptr, sys.O.RDONLY | sys.O.DIRECTORY, 0);
    if (fd >= 0) {
        util.forEachDirent(fd, @as([]const u8, path), pruneEntry);
        sys.close(fd);
    }
    _ = sys.unlinkat(sys.AT_FDCWD, path.ptr, sys.AT_REMOVEDIR);
}

/// A nested runtime (kubelet, runc) leaves child cgroups and delegated controllers behind. With
/// subtree_control set the group is not a leaf, so writing cgroup.procs fails with EBUSY on restart.
fn resetNestedCgroups(id: []const u8) void {
    const base = cgroupPath(id);
    const fd = sys.open(util.zf("{s}", .{base}).ptr, sys.O.RDONLY | sys.O.DIRECTORY, 0);
    if (fd < 0) return;
    util.forEachDirent(fd, @as([]const u8, base), pruneEntry);
    sys.close(fd);
    const sc_path = util.zf("{s}/cgroup.subtree_control", .{base});
    if (util.readFile(sc_path.ptr, 256)) |t| {
        var it = std.mem.tokenizeAny(u8, t, " \n");
        while (it.next()) |ctl| _ = util.writeSys(sc_path.ptr, util.sf("-{s}", .{ctl}));
    }
}

pub fn start(id: []const u8) Fail!i32 {
    const c = find(id) orelse return fail("no such container", .{}, sys.E.NOENT);
    if (c.state == .running) return fail("container already running", .{}, sys.E.BUSY);
    timing.open();
    defer timing.report();
    timing.mark(.enter);
    const spec = try loadSpec(id);
    if (specNeedsLease(spec)) net.dhcpFinish();
    try checkSecurity(spec);
    const dir = cdir(id);
    timing.mark(.spec);

    // cgroup.kill can outlive the previous init; never clone into its group until it is empty.
    try waitForEmptyCgroup(id);
    resetNestedCgroups(id);
    _ = sys.unlinkat(sys.AT_FDCWD, exitPath(id).ptr, 0);
    _ = util.writeSys(util.zf("/sys/fs/cgroup/noodle/{s}/cgroup.freeze", .{id}).ptr, "0");
    if (c.has_stdin and !c.tty and c.stdin_r < 0) {
        // restart where reaping could not reopen stdin (see onChildExit)
        _ = openStdin(c);
    }

    timing.mark(.cgroup_ready);
    // stdio plumbing
    var out_r: [2]i32 = .{ -1, -1 };
    var out_w: [2]i32 = .{ -1, -1 };
    var handoff: [2]i32 = .{ -1, -1 };
    defer for (handoff) |fd| sys.close(fd);
    errdefer for (out_r) |fd| sys.close(fd);
    defer for (out_w) |fd| sys.close(fd);
    if (c.tty) {
        const rc = sys.socketpair(sys.AF_UNIX, sys.SOCK_STREAM | sys.SOCK_NONBLOCK, &handoff);
        if (rc < 0) return fail("pty handoff socket", .{}, rc);
        sys.close(c.master);
        c.master = -1;
    } else {
        var p1: [2]i32 = undefined;
        var p2: [2]i32 = undefined;
        var rc = sys.pipe2(&p1, 0);
        if (rc < 0) return fail("pipe", .{}, rc);
        rc = sys.pipe2(&p2, 0);
        if (rc < 0) {
            sys.close(p1[0]);
            sys.close(p1[1]);
            return fail("pipe", .{}, rc);
        }
        out_r = .{ p1[0], p2[0] };
        out_w = .{ p1[1], p2[1] };
    }
    var go: [2]i32 = undefined;
    var st: [2]i32 = undefined;
    var rc = sys.pipe2(&go, 0);
    if (rc < 0) return fail("pipe", .{}, rc);
    defer for (go) |fd| sys.close(fd);
    rc = sys.pipe2(&st, 0);
    if (rc < 0) return fail("pipe", .{}, rc);
    defer for (st) |fd| sys.close(fd);

    // namespaces
    const mode = spec.strOr("network_mode", "bridge");
    var flags: u64 = sys.CLONE.NEWNS | sys.CLONE.NEWPID | sys.CLONE.NEWUTS | sys.CLONE.NEWIPC;
    var join_net: ?i32 = null;
    var share_resolver_idx: ?u32 = null;
    c.netns = 0;
    var join_ipc_pid: ?i32 = null;
    if (std.mem.startsWith(u8, mode, "container:")) {
        const other = find(mode["container:".len..]) orelse return fail("network container {s} not found", .{mode["container:".len..]}, sys.E.NOENT);
        if (other.state != .running) return fail("network container is not running", .{}, sys.E.INVAL);
        join_net = other.pid;
        c.netns = other.netns;
        share_resolver_idx = contIndex(other);
    }
    _ = &join_ipc_pid;
    // A private namespace comes ready from create when there is one; otherwise clone3 makes it.
    const private_net = privateNet(mode);
    var prepared_net: i32 = if (private_net) (netns.take() orelse -1) else -1;
    if (prepared_net >= 0 and netns.enter(prepared_net) < 0) {
        sys.close(prepared_net);
        prepared_net = -1;
    }
    if (private_net and prepared_net < 0) flags |= sys.CLONE.NEWNET;

    timing.mark(.pipes);
    var args = ClonArgs{
        .flags = flags,
        .exit_signal = sys.SIG.CHLD,
    };
    // block signalfd-managed SIGCHLD stays blocked in the parent; child resets its mask
    const pid = sys.sc(.clone3, @intFromPtr(&args), @sizeOf(ClonArgs), 0, 0, 0, 0);
    if (pid == 0) {
        // ---- container init (child)
        sys.close(go[1]);
        sys.close(st[0]);
        sys.close(handoff[0]);
        childMain(c, spec, dir, go[0], st[1], handoff[1], out_w, join_net, private_net, prepared_net >= 0);
    }
    if (prepared_net >= 0) {
        // The child keeps the namespace alive from here; the agent goes home before anything else.
        netns.leave();
        sys.close(prepared_net);
    }
    if (pid < 0) {
        return fail("clone3 failed", .{}, pid);
    }

    // ---- parent
    timing.mark(.cloned);
    sys.close(go[0]);
    sys.close(st[1]);
    go[0] = -1;
    st[1] = -1;
    sys.close(handoff[1]);
    handoff[1] = -1;
    sys.close(out_w[0]);
    sys.close(out_w[1]);
    out_w = .{ -1, -1 };

    // Linux 6.18's CLONE_INTO_CGROUP kill_seq bug kills restarts; move the blocked child before releasing it.
    const cg_rc = util.writeSys(util.zf("{s}/cgroup.procs", .{cgroupPath(id)}).ptr, util.sf("{d}", .{pid}));
    var failure: ?Fail = if (cg_rc < 0) fail("assign container cgroup", .{}, cg_rc) else null;
    timing.mark(.cgroup_moved);
    if (private_net) {
        var st_net: sys.Stat = undefined;
        if (sys.fstatat(sys.AT_FDCWD, util.zf("/proc/{d}/ns/net", .{pid}).ptr, &st_net, 0) >= 0) c.netns = st_net.ino;
        for (&c.nets) |*cn| cn.attached = false;
    }
    // network
    if (failure == null) if (share_resolver_idx) |owner| resolver.shareRedirect(owner, cgroupPath(c.idStr()).ptr);
    // --network none: the container's init brings lo up itself, already in the namespace.
    if (failure == null and private_net and !std.mem.eql(u8, mode, "none")) {
        failure = setupNets(c, spec, @intCast(pid));
        if (failure == null) if (spec.get("resolver")) |r| resolver.open(contIndex(c), r, @intCast(pid));
    }

    var go_byte: [1]u8 = .{if (failure == null) 1 else 0};
    if (failure != null) _ = sys.kill(pid, sys.SIG.KILL);
    _ = sys.write(go[1], &go_byte);
    sys.close(go[1]);
    go[1] = -1;
    timing.mark(.released);

    if (c.tty and failure == null) {
        sys.setNonblock(st[0]);
        rc = sys.epoll_add(util.epfd, st[0], sys.EPOLLIN, util.tag(util.Tag.tty_start, contIndex(c)));
        if (rc >= 0) {
            rc = sys.epoll_add(util.epfd, handoff[0], sys.EPOLLIN, util.tag(util.Tag.tty_master, contIndex(c)));
            if (rc < 0) _ = sys.epoll_del(util.epfd, st[0]);
        }
        if (rc >= 0) {
            c.pid = @intCast(pid);
            c.state = .running;
            c.code = 0;
            c.start_error_len = 0;
            c.start_status = st[0];
            pending_starts += 1;
            st[0] = -1;
            c.start_master = handoff[0];
            handoff[0] = -1;
            return @intCast(pid);
        }
        failure = fail("watch tty startup", .{}, rc);
        _ = sys.kill(pid, sys.SIG.KILL);
    }

    // wait for exec (EOF on the CLOEXEC status pipe) or an error message
    var msg: [400]u8 = undefined;
    const n = sys.readAll(st[0], &msg);
    sys.close(st[0]);
    st[0] = -1;
    timing.mark(.exec_seen);
    if (n != 0 or failure != null) {
        _ = sys.kill(pid, sys.SIG.KILL);
        var status: u32 = 0;
        _ = sys.wait4(pid, &status, 0);
        if (failure) |f| return f;
        return fail("{s}", .{if (n > 0) msg[0..@intCast(n)] else "read startup status failed"}, sys.E.INVAL);
    }

    c.pid = @intCast(pid);
    c.state = .running;
    c.code = 0;
    c.out = out_r;
    for (0..2) |i| {
        sys.setNonblock(out_r[i]);
        _ = sys.epoll_add(util.epfd, out_r[i], sys.EPOLLIN, util.tag(util.Tag.cont_out, contIndex(c) * 4 + @as(u32, @intCast(i))));
    }
    if (c.stdin_r >= 0) {
        sys.close(c.stdin_r);
        c.stdin_r = -1;
    }
    return @intCast(pid);
}

/// Epoll receives the master before exec. The child waits for this acknowledgement,
/// so the latest cached window size is installed before its first instruction.
pub fn receiveStartMaster(c: *Cont) Fail!void {
    if (c.master >= 0) return;
    const fd = sys.recvFd(c.start_master);
    if (fd < 0) return fail("receive container pty master", .{}, fd);
    c.master = @intCast(fd);
    if (savedWinsize(c)) |saved| {
        var ws = saved;
        const rc = sys.ioctl(fd, sys.TIOCSWINSZ, @intFromPtr(&ws));
        if (rc < 0) return fail("apply pending tty resize", .{}, rc);
    }
    sys.setNonblock(fd);
    const rc = sys.epoll_add(util.epfd, fd, sys.EPOLLIN, util.tag(util.Tag.cont_out, contIndex(c) * 4 + 2));
    if (rc < 0) return fail("watch container pty", .{}, rc);
    const ack = sys.sendNonblock(c.start_master, &.{1});
    if (ack != 1) return fail("acknowledge container pty", .{}, if (ack < 0) ack else -sys.E.IO);
    _ = sys.epoll_del(util.epfd, c.start_master);
    sys.close(c.start_master);
    c.start_master = -1;
    finishTtyWaiters(c);
}

pub fn abortStart(c: *Cont) void {
    _ = sys.kill(c.pid, sys.SIG.KILL);
    if (c.start_status >= 0) {
        _ = sys.epoll_del(util.epfd, c.start_status);
        sys.close(c.start_status);
        c.start_status = -1;
        pending_starts -= 1;
    }
    if (c.start_master >= 0) _ = sys.epoll_del(util.epfd, c.start_master);
    sys.close(c.start_master);
    c.start_master = -1;
    if (c.master >= 0) _ = sys.epoll_del(util.epfd, c.master);
    sys.close(c.master);
    c.master = -1;
    c.state = .created;
    c.pid = 0;
    resolver.close(contIndex(c));
    finishTtyWaiters(c);
}

/// Nonblocking completion of tty startup. EOF is the existing exec-success signal.
pub fn finishStart(c: *Cont) Fail!bool {
    var read_error: isize = 0;
    while (c.start_error_len < c.start_error.len) {
        const n = sys.read(c.start_status, c.start_error[c.start_error_len..]);
        if (n == -sys.E.INTR) continue;
        if (n == -sys.E.AGAIN) return false;
        if (n <= 0) {
            read_error = n;
            break;
        }
        c.start_error_len += @intCast(n);
    }
    errdefer abortStart(c);
    if (read_error < 0) return fail("read tty startup status", .{}, read_error);
    if (c.start_error_len > 0) return fail("{s}", .{c.start_error[0..c.start_error_len]}, sys.E.INVAL);
    // SIGCHLD may arrive before the queued master event if setup was killed.
    try receiveStartMaster(c);
    _ = sys.epoll_del(util.epfd, c.start_status);
    sys.close(c.start_status);
    c.start_status = -1;
    pending_starts -= 1;
    return true;
}

pub fn cancelStarts() void {
    for (&conts) |*c| {
        if (c.used and c.start_status >= 0) abortStart(c);
    }
}

fn setupNets(c: *Cont, spec: Value, pid: i32) ?Fail {
    // primary network from the spec
    const nv = spec.get("network");
    if (nv) |n| {
        const nname = n.strOr("name", "");
        const ipv = util.parseIp4(n.strOr("ip", ""));
        const ip6v = util.parseIp6(n.strOr("ip6", ""));
        if (nname.len > 0 and (ipv != null or ip6v != null)) {
            var slot: ?*CNet = null;
            for (&c.nets) |*cn| if (cn.used and std.mem.eql(u8, cn.name[0..cn.nlen], nname)) {
                slot = cn;
                break;
            };
            if (slot == null) for (&c.nets) |*cn| if (!cn.used) {
                slot = cn;
                break;
            };
            const cn = slot orelse return fail("too many networks", .{}, sys.E.NOMEM);
            if (nname.len > cn.name.len) return fail("network name too long", .{}, sys.E.INVAL);
            cn.used = true;
            cn.attached = false;
            @memcpy(cn.name[0..nname.len], nname);
            cn.nlen = @intCast(nname.len);
            cn.ip = ipv;
            cn.prefix = @intCast(n.intOr("prefix", 16));
            cn.gateway = util.parseIp4(n.strOr("gateway", ""));
            cn.ip6 = ip6v;
            cn.prefix6 = @intCast(n.intOr("prefix6", 64));
            cn.gateway6 = util.parseIp6(n.strOr("gateway6", ""));
            const mac = n.strOr("mac", "");
            cn.mac = if (mac.len > 0) util.parseMac(mac) else null;
        }
    }
    for (&c.nets, 0..) |*cn, i| {
        if (!cn.used or cn.attached) continue;
        if (attachOne(c, cn, i, pid)) |f| return f;
    }
    return null;
}

fn attachOne(c: *Cont, cn: *CNet, idx: usize, pid: i32) ?Fail {
    const network = net.findNet(cn.name[0..cn.nlen]) orelse return fail("network {s} not found", .{cn.name[0..cn.nlen]}, sys.E.NOENT);
    // Each family's default route goes through the first network that has that family.
    var first4 = true;
    var first6 = true;
    for (c.nets[0..idx]) |*prev| {
        if (!prev.used) continue;
        if (prev.ip != null) first4 = false;
        if (prev.ip6 != null) first6 = false;
    }
    var hb: [16]u8 = undefined;
    veth_seq += 1;
    const host_if = std.fmt.bufPrint(&hb, "v{x}-{d}", .{ veth_seq, idx }) catch return fail("ifname", .{}, sys.E.INVAL);
    var eb: [8]u8 = undefined;
    const ifname = std.fmt.bufPrint(&eb, "eth{d}", .{idx}) catch unreachable;
    // Each attachment gets a new name while the kernel retires the old namespace asynchronously.
    const rc = net.attachBridge(pid, .{
        .net = network,
        .ip = cn.ip,
        .prefix = cn.prefix,
        .gateway = if (first4) cn.gateway else null,
        .ip6 = cn.ip6,
        .prefix6 = cn.prefix6,
        .gateway6 = if (first6) cn.gateway6 else null,
        .mac = cn.mac,
        .ifname = ifname,
        .host_if = host_if,
    });
    if (rc < 0) return fail("network attach failed: errno {d}", .{-rc}, rc);
    @memcpy(cn.host_if[0..host_if.len], host_if);
    cn.hlen = @intCast(host_if.len);
    cn.attached = true;
    return null;
}

pub fn netConnect(cid: []const u8, network_name: []const u8, ip_s: []const u8, ip6_s: []const u8, mac_s: []const u8, aliases: []const Value, resolver_spec: ?Value) Fail!void {
    const c = find(cid) orelse return fail("no such container", .{}, sys.E.NOENT);
    const network = net.findNet(network_name) orelse return fail("network {s} not found", .{network_name}, sys.E.NOENT);
    const ip = util.parseIp4(ip_s);
    const ip6 = util.parseIp6(ip6_s);
    if (ip == null and ip6 == null) return fail("bad ip", .{}, sys.E.INVAL);
    var slot: ?usize = null;
    for (&c.nets, 0..) |*cn, i| if (cn.used and std.mem.eql(u8, cn.name[0..cn.nlen], network_name)) {
        slot = i;
        break;
    };
    if (slot == null) for (&c.nets, 0..) |*cn, i| if (!cn.used) {
        slot = i;
        break;
    };
    const i = slot orelse return fail("too many networks", .{}, sys.E.NOMEM);
    const cn = &c.nets[i];
    if (network_name.len > cn.name.len) return fail("network name too long", .{}, sys.E.INVAL);
    // Before a (re)start the slot still holds the address of the previous run: take the new one.
    if (!cn.used or c.state != .running) {
        cn.* = .{};
        cn.used = true;
        @memcpy(cn.name[0..network_name.len], network_name);
        cn.nlen = @intCast(network_name.len);
        cn.ip = ip;
        cn.prefix = network.prefix;
        cn.gateway = if (ip != null) network.gw else null;
        cn.ip6 = ip6;
        cn.prefix6 = network.prefix6;
        cn.gateway6 = if (ip6 != null) network.gw6 else null;
        cn.mac = if (mac_s.len > 0) util.parseMac(mac_s) else null;
    }
    const fresh = c.state == .running and !cn.attached;
    if (fresh) {
        if (attachOne(c, cn, i, c.pid)) |f| return f;
        if (resolver_spec) |r| {
            const idx = contIndex(c);
            if (!resolver.isOpen(idx)) {
                resolver.open(idx, r, c.pid);
                resolver.pointResolvConf(cdir(c.idStr()));
            }
        }
    }
    for (aliases) |al| {
        if (al == .str and !net.addRecord(network, al.str, ip, ip6)) {
            // the host releases the address on failure, so leave nothing attached to it
            if (fresh) {
                net.removeRecordsFor(network, cn.ip, cn.ip6);
                if (cn.attached) net.deleteLinkByName(cn.host_if[0..cn.hlen]);
                cn.used = false;
                cn.attached = false;
            }
            return fail("dns record table full", .{}, sys.E.NOMEM);
        }
    }
}

pub fn netDisconnect(cid: []const u8, network_name: []const u8) Fail!void {
    const c = find(cid) orelse return fail("no such container", .{}, sys.E.NOENT);
    for (&c.nets) |*cn| {
        if (!(cn.used and std.mem.eql(u8, cn.name[0..cn.nlen], network_name))) continue;
        if (net.findNet(network_name)) |n| net.removeRecordsFor(n, cn.ip, cn.ip6);
        if (cn.attached) net.deleteLinkByName(cn.host_if[0..cn.hlen]);
        cn.used = false;
        cn.attached = false;
    }
}

// ------------------------------------------------------------------ container init (runs in the new namespaces)

fn childDie(status_w: i32, comptime fmt: []const u8, args: anytype) noreturn {
    var b: [380]u8 = undefined;
    const s = std.fmt.bufPrint(&b, fmt, args) catch "init failed";
    _ = sys.write(status_w, s);
    sys.exit(127);
}

fn mnt(status_w: i32, src: ?[*:0]const u8, target: [*:0]const u8, fs: ?[*:0]const u8, flags: usize, data: ?[*:0]const u8) void {
    const rc = sys.mount(src, target, fs, flags, data);
    if (rc < 0) childDie(status_w, "mount {s}: errno {d}", .{ std.mem.span(target), -rc });
}

fn mntOpt(src: ?[*:0]const u8, target: [*:0]const u8, fs: ?[*:0]const u8, flags: usize, data: ?[*:0]const u8) bool {
    return sys.mount(src, target, fs, flags, data) >= 0;
}

// Resolve every destination inside the overlay, including image-provided symlinks.
// The returned descriptor pins the mountpoint until exec closes it.
fn mountTarget(status_w: i32, root: isize, path: []const u8, directory: bool) [:0]u8 {
    if (!@import("mount_path.zig").valid(path)) childDie(status_w, "invalid mount target: {s}", .{path});
    var it = std.mem.tokenizeScalar(u8, path, '/');
    var prefix: std.ArrayList(u8) = .empty;
    while (it.next()) |part| {
        const parent = sys.openat2(root, util.zdup(if (prefix.items.len == 0) "/" else prefix.items).ptr, sys.O.PATH | sys.O.DIRECTORY, 0, sys.RESOLVE_IN_ROOT | sys.RESOLVE_NO_MAGICLINKS);
        if (parent < 0) childDie(status_w, "open mount parent {s}: errno {d}", .{ path, -parent });
        const component = util.zdup(part);
        const last = it.peek() == null;
        var fd = sys.openat2(root, util.zf("/{s}{s}{s}", .{ prefix.items, if (prefix.items.len == 0) "" else "/", part }).ptr, sys.O.PATH, 0, sys.RESOLVE_IN_ROOT | sys.RESOLVE_NO_MAGICLINKS);
        if (fd == -sys.E.NOENT) {
            const rc = if (!last or directory) sys.mkdirat(parent, component.ptr, 0o755) else sys.openat(parent, component.ptr, sys.O.WRONLY | sys.O.CREAT | sys.O.NOFOLLOW, 0o644);
            if (rc < 0 and rc != -sys.E.EXIST) childDie(status_w, "create mount target {s}: errno {d}", .{ path, -rc });
            if (last and !directory and rc >= 0) sys.close(rc);
            fd = sys.openat2(root, util.zf("/{s}{s}{s}", .{ prefix.items, if (prefix.items.len == 0) "" else "/", part }).ptr, sys.O.PATH, 0, sys.RESOLVE_IN_ROOT | sys.RESOLVE_NO_MAGICLINKS);
        }
        sys.close(parent);
        if (fd < 0) childDie(status_w, "open mount target {s}: errno {d}", .{ path, -fd });
        if (!last) sys.close(fd) else return util.zf("/proc/self/fd/{d}", .{fd});
        if (prefix.items.len > 0) prefix.append(util.arena(), '/') catch childDie(status_w, "oom", .{});
        prefix.appendSlice(util.arena(), part) catch childDie(status_w, "oom", .{});
    }
    const fd = sys.openat2(root, "/", sys.O.PATH, 0, sys.RESOLVE_IN_ROOT | sys.RESOLVE_NO_MAGICLINKS);
    if (fd < 0) childDie(status_w, "open rootfs: errno {d}", .{-fd});
    return util.zf("/proc/self/fd/{d}", .{fd});
}

pub fn volumeInUse(current: ?*const Cont, name: []const u8) bool {
    for (&conts) |*other| {
        if (!other.used or other == current or other.state == .created) continue;
        if (other.state == .exited) {
            // A recreated spec may differ while processes from the previous start are exiting.
            const events = util.readFile(util.zf("{s}/cgroup.events", .{cgroupPath(other.idStr())}).ptr, 4096) orelse return true;
            if ((util.flatKey(events, "populated") orelse 1) != 0) return true;
            continue;
        }
        const spec = loadSpec(other.idStr()) catch return true;
        for (spec.list("mounts")) |m| {
            if (std.mem.eql(u8, m.strOr("kind", ""), "volume") and std.mem.eql(u8, m.strOr("source", ""), name)) return true;
        }
    }
    return false;
}

const masked_files = [_][:0]const u8{ "/proc/kcore", "/proc/keys", "/proc/latency_stats", "/proc/timer_list", "/proc/timer_stats", "/proc/sched_debug", "/proc/acpi", "/proc/scsi", "/proc/asound", "/proc/interrupts", "/sys/firmware", "/sys/devices/virtual/powercap" };
const ro_paths = [_][:0]const u8{ "/proc/bus", "/proc/fs", "/proc/irq", "/proc/sys", "/proc/sysrq-trigger" };

fn childMain(c: *Cont, spec: Value, dir: [:0]u8, go_r: i32, status_w: i32, tty_socket: i32, out_w: [2]i32, join_net: ?i32, private_net: bool, net_ready: bool) noreturn {
    timing.mark(.c_first);
    _ = sys.sigprocmask(2, 0); // SIG_SETMASK empty
    _ = sys.prctl(sys.PR_SET_PDEATHSIG, sys.SIG.KILL, 0, 0, 0);
    // wait for the parent to finish networking
    var gb: [1]u8 = undefined;
    const gn = sys.read(go_r, &gb);
    if (gn != 1 or gb[0] != 1) sys.exit(127);
    sys.close(go_r);
    timing.mark(.c_go);
    // Read the shared resize file before pivot_root hides the agent's data path.
    const initial_ws = if (c.tty) (savedWinsize(c) orelse [4]u16{ 0, 0, 0, 0 }) else [4]u16{ 0, 0, 0, 0 };

    if (join_net) |opid| {
        const fd = sys.open(util.zf("/proc/{d}/ns/net", .{opid}).ptr, sys.O.RDONLY, 0);
        if (fd < 0 or sys.setns(fd, sys.CLONE.NEWNET) < 0) childDie(status_w, "join network namespace failed", .{});
        sys.close(fd);
    }
    // A namespace prepared by netns.zig already has loopback up and both sysctls set.
    if (private_net and !net_ready) {
        if (std.mem.eql(u8, spec.strOr("network_mode", "bridge"), "none")) {
            const lrc = net.linkUpByName("lo");
            if (lrc < 0) childDie(status_w, "loopback setup failed: errno {d}", .{-lrc});
        }
        const rc = util.writeSys("/proc/sys/net/ipv4/ip_unprivileged_port_start", "0");
        if (rc < 0) childDie(status_w, "configure unprivileged ports: errno {d}", .{rc});
        // Unprivileged ICMP sockets, so ping works for any user without NET_RAW.
        const prc = util.writeSys("/proc/sys/net/ipv4/ping_group_range", "0 2147483647");
        if (prc < 0) childDie(status_w, "configure ping: errno {d}", .{prc});
    }
    if (spec.get("sysctls")) |values| for (values.obj) |entry| {
        var pb: [150]u8 = undefined;
        const rc = util.writeSys((util.netSysctlPath(&pb, entry.key) orelse childDie(status_w, "sysctl {s}", .{entry.key})).ptr, entry.val.str);
        if (rc < 0) childDie(status_w, "sysctl {s}: errno {d}", .{ entry.key, -rc });
    };
    timing.mark(.c_net);
    if (sys.unshare(sys.CLONE.NEWCGROUP) < 0) childDie(status_w, "unshare cgroup ns failed", .{});
    timing.mark(.c_cgroupns);

    const id = c.idStr();
    const privileged = spec.boolOr("privileged", false);
    const merged = util.zf("{s}/merged", .{dir});
    const ro_flag: usize = if (privileged) 0 else sys.MS.RDONLY;
    const root = sys.open(merged.ptr, sys.O.PATH | sys.O.DIRECTORY, 0);
    if (root < 0) childDie(status_w, "open rootfs: errno {d}", .{-root});

    mnt(status_w, null, "/", null, sys.MS.REC | sys.MS.PRIVATE, null);

    // Copy from the image before runtime files, virtiofs shares or other volumes can obscure it.
    for (spec.list("mounts")) |m| {
        if (!std.mem.eql(u8, m.strOr("kind", ""), "volume")) continue;
        const volumes = sys.open(util.base ++ "/volumes", sys.O.PATH | sys.O.DIRECTORY | sys.O.NOFOLLOW, 0);
        if (volumes < 0) childDie(status_w, "open volumes: errno {d}", .{-volumes});
        defer sys.close(volumes);
        const work = sys.open(dir.ptr, sys.O.PATH | sys.O.DIRECTORY | sys.O.NOFOLLOW, 0);
        if (work < 0) childDie(status_w, "open container directory: errno {d}", .{-work});
        defer sys.close(work);
        const volume = @import("volume.zig");
        const name = util.zdup(m.strOr("source", ""));
        const target = util.zdup(m.strOr("target", ""));
        volume.prepare(root, volumes, work, name, target, m.boolOr("no_copy", false) or volumeInUse(c, name)) catch |err|
            childDie(status_w, "prepare volume {s}: {s} errno {d}", .{ name, @errorName(err), volume.last_errno });
    }

    timing.mark(.c_private);
    // --- /proc /sys
    {
        const p = mountTarget(status_w, root, "/proc", true);
        mnt(status_w, "proc", p.ptr, "proc", sys.MS.NOSUID | sys.MS.NODEV | sys.MS.NOEXEC, null);
        const s = mountTarget(status_w, root, "/sys", true);
        mnt(status_w, "sysfs", s.ptr, "sysfs", sys.MS.NOSUID | sys.MS.NODEV | sys.MS.NOEXEC | ro_flag, null);
        const cg = mountTarget(status_w, root, "/sys/fs/cgroup", true);
        mnt(status_w, "cgroup2", cg.ptr, "cgroup2", sys.MS.NOSUID | sys.MS.NODEV | sys.MS.NOEXEC | ro_flag, null);
    }

    timing.mark(.c_proc_sys);
    // --- /dev
    {
        const d = mountTarget(status_w, root, "/dev", true);
        mnt(status_w, "tmpfs", d.ptr, "tmpfs", sys.MS.NOSUID | @as(usize, if (privileged) 0 else sys.MS.NODEV), "mode=755,size=65536k");
        const nodes = [_][:0]const u8{ "null", "zero", "full", "random", "urandom", "tty" };
        for (nodes) |n| {
            const t = mountTarget(status_w, root, util.sf("/dev/{s}", .{n}), false);
            _ = mntOpt(util.zf("/dev/{s}", .{n}).ptr, t.ptr, null, sys.MS.BIND, null);
        }
        // Privileged containers get a few more nodes, never the disk, console or vsock device.
        // The cgroup device policy (devcg.zig) enforces the same list if a container makes its own nodes.
        if (privileged) for ([_][:0]const u8{ "kmsg", "fuse", "net/tun", "loop-control", "loop0", "loop1", "loop2", "loop3", "loop4", "loop5", "loop6", "loop7" }) |n| {
            if (!util.exists(util.zf("/dev/{s}", .{n}).ptr)) continue;
            const t = mountTarget(status_w, root, util.sf("/dev/{s}", .{n}), false);
            _ = mntOpt(util.zf("/dev/{s}", .{n}).ptr, t.ptr, null, sys.MS.BIND, null);
        };
        const pts = mountTarget(status_w, root, "/dev/pts", true);
        mnt(status_w, "devpts", pts.ptr, "devpts", sys.MS.NOSUID | sys.MS.NOEXEC, "newinstance,ptmxmode=0666,mode=0620,gid=5");
        const devfd = sys.openat2(root, "/dev", sys.O.PATH | sys.O.DIRECTORY, 0, sys.RESOLVE_IN_ROOT | sys.RESOLVE_NO_MAGICLINKS);
        if (devfd < 0) childDie(status_w, "open /dev failed", .{});
        _ = sys.symlinkat("pts/ptmx", devfd, "ptmx");
        const shm = mountTarget(status_w, root, "/dev/shm", true);
        _ = mntOpt("shm", shm.ptr, "tmpfs", sys.MS.NOSUID | sys.MS.NODEV | sys.MS.NOEXEC, util.zf("mode=1777,size={d}", .{spec.intOr("shm_size", 67108864)}).ptr);
        _ = sys.symlinkat("/proc/self/fd", devfd, "fd");
        _ = sys.symlinkat("/proc/self/fd/0", devfd, "stdin");
        _ = sys.symlinkat("/proc/self/fd/1", devfd, "stdout");
        _ = sys.symlinkat("/proc/self/fd/2", devfd, "stderr");
        sys.close(devfd);
        if (c.tty) _ = mountTarget(status_w, root, "/dev/console", false);
    }

    timing.mark(.c_dev);
    // --- /etc files
    {
        const hostname = spec.strOr("hostname", "");
        const hn = if (hostname.len > 0) hostname else id[0..@min(id.len, 12)];
        const files = [_]struct { name: []const u8, content: []const u8 }{
            .{ .name = "hostname", .content = util.sf("{s}\n", .{hn}) },
            .{ .name = "hosts", .content = buildHosts(spec, c, hn) },
            .{ .name = "resolv.conf", .content = buildResolv(spec) },
        };
        for (files) |f| {
            const src = util.zf("{s}/{s}", .{ dir, f.name });
            _ = util.writeFile(src.ptr, f.content, 0o644);
            const dest = mountTarget(status_w, root, util.sf("/etc/{s}", .{f.name}), false);
            mnt(status_w, src.ptr, dest.ptr, null, sys.MS.BIND, null);
        }
    }

    timing.mark(.c_etc);
    // --- user mounts
    for (spec.list("mounts")) |m| {
        const kind = m.strOr("kind", "bind");
        const tgt_rel = m.strOr("target", "");
        if (tgt_rel.len == 0 or tgt_rel[0] != '/') childDie(status_w, "mount target must be absolute: {s}", .{tgt_rel});
        const ro = m.boolOr("read_only", false);
        if (std.mem.eql(u8, kind, "tmpfs")) {
            const dest = mountTarget(status_w, root, tgt_rel, true);
            const sz = m.intOr("tmpfs_size", 0);
            const data = if (sz > 0) util.zf("size={d},mode=1777", .{sz}) else util.zf("mode=1777", .{});
            mnt(status_w, "tmpfs", dest.ptr, "tmpfs", sys.MS.NOSUID | sys.MS.NODEV | @as(usize, if (ro) sys.MS.RDONLY else 0), data.ptr);
            continue;
        }
        const is_docker = std.mem.eql(u8, kind, "docker");
        const is_agent = is_docker or std.mem.eql(u8, kind, "agent");
        const src_s = if (is_docker) @import("sshagent.zig").docker_socket_path else if (is_agent) @import("sshagent.zig").socket_path else m.strOr("source", "");
        const is_volume = std.mem.eql(u8, kind, "volume");
        if (!is_volume and !is_agent and (!std.mem.eql(u8, kind, "bind") or !@import("mount_path.zig").validShare(src_s)))
            childDie(status_w, "invalid bind source", .{});
        if (is_volume and !util.validVolumeName(src_s)) childDie(status_w, "invalid volume name", .{});
        const src = if (is_volume) util.zf("{s}/volumes/{s}", .{ util.base, src_s }) else util.zdup(src_s);
        var st: sys.Stat = undefined;
        const source_fd = sys.openat2(sys.AT_FDCWD, src.ptr, sys.O.PATH, 0, 0x04); // RESOLVE_NO_SYMLINKS
        if (source_fd < 0) childDie(status_w, "open {s} source {s}: errno {d}", .{ kind, src_s, -source_fd });
        if (sys.fstat(source_fd, &st) < 0) childDie(status_w, "stat mount source failed", .{});
        const directory = (st.mode & sys.S.IFMT) == sys.S.IFDIR;
        if (!directory and (is_volume or ((st.mode & sys.S.IFMT) != sys.S.IFREG and !(is_agent and (st.mode & sys.S.IFMT) == sys.S.IFSOCK)))) childDie(status_w, "mount source must be a regular file or directory", .{});
        const source = util.zf("/proc/self/fd/{d}", .{source_fd});
        const dest = mountTarget(status_w, root, tgt_rel, directory);
        mnt(status_w, source.ptr, dest.ptr, null, sys.MS.BIND, null);
        sys.close(source_fd);
        const mounted = mountTarget(status_w, root, tgt_rel, directory);
        mnt(status_w, null, mounted.ptr, null, sys.MS.BIND | sys.MS.REMOUNT | sys.MS.NODEV | @as(usize, if (ro) sys.MS.RDONLY else 0), null);
    }

    if (spec.boolOr("init", false)) {
        const dest = mountTarget(status_w, root, "/dev/docker-init", false);
        mnt(status_w, "/sbin/docker-init", dest.ptr, null, sys.MS.BIND, null);
        const mounted = mountTarget(status_w, root, "/dev/docker-init", false);
        mnt(status_w, null, mounted.ptr, null, sys.MS.BIND | sys.MS.REMOUNT | sys.MS.RDONLY | sys.MS.NODEV | sys.MS.NOSUID, null);
    }

    timing.mark(.c_user_mounts);
    // --- masked and read-only paths
    if (!privileged) {
        for (masked_files) |p| {
            const fd = sys.openat2(root, p.ptr, sys.O.PATH, 0, sys.RESOLVE_IN_ROOT | sys.RESOLVE_NO_MAGICLINKS);
            if (fd == -sys.E.NOENT) continue;
            if (fd < 0) childDie(status_w, "open masked path failed: errno {d}", .{-fd});
            const t = util.zf("/proc/self/fd/{d}", .{fd});
            var st: sys.Stat = undefined;
            if (sys.fstat(fd, &st) < 0) childDie(status_w, "stat masked path failed", .{});
            if ((st.mode & sys.S.IFMT) == sys.S.IFDIR) {
                mnt(status_w, "tmpfs", t.ptr, "tmpfs", sys.MS.RDONLY | sys.MS.NODEV | sys.MS.NOSUID | sys.MS.NOEXEC, "size=0");
            } else mnt(status_w, "/dev/null", t.ptr, null, sys.MS.BIND, null);
        }
        for (ro_paths) |p| {
            const fd = sys.openat2(root, p.ptr, sys.O.PATH, 0, sys.RESOLVE_IN_ROOT | sys.RESOLVE_NO_MAGICLINKS);
            if (fd == -sys.E.NOENT) continue;
            if (fd < 0) childDie(status_w, "open read-only path failed: errno {d}", .{-fd});
            const t = util.zf("/proc/self/fd/{d}", .{fd});
            mnt(status_w, t.ptr, t.ptr, null, sys.MS.BIND, null);
            const mounted = mountTarget(status_w, root, p, true);
            mnt(status_w, null, mounted.ptr, null, sys.MS.BIND | sys.MS.REMOUNT | sys.MS.RDONLY | sys.MS.NODEV | sys.MS.NOSUID | sys.MS.NOEXEC, null);
        }
    }

    timing.mark(.c_masked);
    sys.close(root);
    // --- pivot_root
    if (sys.chdir(merged.ptr) < 0) childDie(status_w, "chdir rootfs failed", .{});
    if (sys.pivot_root(".", ".") >= 0) {
        _ = sys.umount2(".", 2); // MNT_DETACH
    } else {
        // root is still an initramfs rootfs: fall back to move + chroot
        if (sys.mount(".", "/", null, sys.MS.MOVE, null) < 0 or sys.chroot(".") < 0) childDie(status_w, "pivot_root failed", .{});
    }
    _ = sys.chdir("/");
    if (c.tty) childPty(status_w, tty_socket, initial_ws, spec, null, true);
    if (spec.boolOr("read_only", false)) mnt(status_w, null, "/", null, sys.MS.REMOUNT | sys.MS.BIND | sys.MS.RDONLY | sys.MS.NODEV, null);

    timing.mark(.c_pivot);
    // --- identity
    const hostname = spec.strOr("hostname", "");
    const hn = if (hostname.len > 0) hostname else id[0..@min(id.len, 12)];
    _ = sys.sethostname(hn);
    _ = sys.setdomainname(spec.strOr("domainname", ""));

    // --- stdio
    if (!c.tty) {
        _ = sys.setsid();
        if (c.stdin_r >= 0) {
            _ = sys.dup3(c.stdin_r, 0, 0);
        } else {
            const nul = sys.open("/dev/null", sys.O.RDONLY, 0);
            if (nul >= 0) _ = sys.dup3(nul, 0, 0);
        }
        _ = sys.dup3(out_w[0], 1, 0);
        _ = sys.dup3(out_w[1], 2, 0);
    }

    timing.mark(.c_stdio);
    runUser(status_w, spec, hn, c.tty, true, null);
}

fn buildHosts(spec: Value, c: *Cont, hn: []const u8) []const u8 {
    var b = json.Buf.init(util.arena());
    for (spec.list("hosts")) |h| if (h == .str) {
        if (util.hostGatewayNames(h.str)) |names| {
            // Without a lease there is no address to give the name, and a literal "host-gateway" would be garbage.
            if (net.vm_gateway) |gw| b.print("{d}.{d}.{d}.{d}\t{s}\n", .{ gw[0], gw[1], gw[2], gw[3], names }) catch {};
            continue;
        }
        b.raw(h.str) catch {};
        b.byte('\n') catch {};
    };
    for (c.nets) |cn| if (cn.used) {
        if (cn.ip) |ip| b.print("{d}.{d}.{d}.{d}\t{s}\n", .{ ip[0], ip[1], ip[2], ip[3], hn }) catch {};
        break;
    };
    b.raw("::1\tlocalhost ip6-localhost ip6-loopback\n") catch {};
    return b.bytes();
}

fn buildResolv(spec: Value) []const u8 {
    var b = json.Buf.init(util.arena());
    const search = spec.list("dns_search");
    if (search.len > 0) {
        b.raw("search") catch {};
        for (search) |s| if (s == .str) {
            b.byte(' ') catch {};
            b.raw(s.str) catch {};
        };
        b.byte('\n') catch {};
    }
    const servers = spec.list("dns");
    for (servers) |s| if (s == .str) {
        b.raw("nameserver ") catch {};
        b.raw(s.str) catch {};
        b.byte('\n') catch {};
    };
    if (servers.len == 0 and !std.mem.eql(u8, &net.upstream_dns, &[4]u8{ 0, 0, 0, 0 })) {
        b.print("nameserver {d}.{d}.{d}.{d}\n", .{ net.upstream_dns[0], net.upstream_dns[1], net.upstream_dns[2], net.upstream_dns[3] }) catch {};
    }
    const opts = spec.list("dns_options");
    if (opts.len > 0) {
        b.raw("options") catch {};
        for (opts) |s| if (s == .str) {
            b.byte(' ') catch {};
            b.raw(s.str) catch {};
        };
        b.byte('\n') catch {};
    }
    return b.bytes();
}

// ------------------------------------------------------------------ user lookup, caps, seccomp, exec

const Ident = struct { uid: u32 = 0, gid: u32 = 0, groups: [32]u32 = undefined, ngroups: usize = 0, home: []const u8 = "/", name: []const u8 = "" };

fn fieldIter(line: []const u8) std.mem.SplitIterator(u8, .scalar) {
    return std.mem.splitScalar(u8, line, ':');
}

fn lookupUser(userspec: []const u8) ?Ident {
    var id = Ident{};
    var user = userspec;
    var group: []const u8 = "";
    if (std.mem.indexOfScalar(u8, userspec, ':')) |i| {
        user = userspec[0..i];
        group = userspec[i + 1 ..];
    }
    if (user.len == 0) user = "0";
    const passwd = util.readRegularFile("/etc/passwd", 1 << 20) orelse "";
    const group_txt = util.readRegularFile("/etc/group", 1 << 20) orelse "";
    const want_uid = std.fmt.parseInt(u32, user, 10) catch null;
    var found = false;
    var lines = std.mem.tokenizeScalar(u8, passwd, '\n');
    while (lines.next()) |line| {
        var it = fieldIter(line);
        const name = it.next() orelse continue;
        _ = it.next();
        const uid_s = it.next() orelse continue;
        const gid_s = it.next() orelse continue;
        _ = it.next();
        const home = it.next() orelse "/";
        const uid = std.fmt.parseInt(u32, uid_s, 10) catch continue;
        const match = if (want_uid) |w| uid == w else std.mem.eql(u8, name, user);
        if (match) {
            id.uid = uid;
            id.gid = std.fmt.parseInt(u32, gid_s, 10) catch 0;
            id.home = if (home.len > 0) home else "/";
            id.name = name;
            found = true;
            break;
        }
    }
    if (!found) {
        if (want_uid) |w| {
            id.uid = w;
            id.gid = 0;
        } else return null;
    }
    if (group.len > 0) {
        if (std.fmt.parseInt(u32, group, 10)) |g| {
            id.gid = g;
        } else |_| {
            var gl = std.mem.tokenizeScalar(u8, group_txt, '\n');
            var gfound = false;
            while (gl.next()) |line| {
                var it = fieldIter(line);
                const gname = it.next() orelse continue;
                _ = it.next();
                const gid_s = it.next() orelse continue;
                if (std.mem.eql(u8, gname, group)) {
                    id.gid = std.fmt.parseInt(u32, gid_s, 10) catch 0;
                    gfound = true;
                    break;
                }
            }
            if (!gfound) return null;
        }
    } else if (found) {
        // supplementary groups by membership
        var gl = std.mem.tokenizeScalar(u8, group_txt, '\n');
        while (gl.next()) |line| {
            var it = fieldIter(line);
            _ = it.next();
            _ = it.next();
            const gid_s = it.next() orelse continue;
            const members = it.next() orelse continue;
            var mi = std.mem.tokenizeScalar(u8, members, ',');
            while (mi.next()) |m| if (std.mem.eql(u8, m, id.name) and id.ngroups < id.groups.len) {
                id.groups[id.ngroups] = std.fmt.parseInt(u32, gid_s, 10) catch continue;
                id.ngroups += 1;
            };
        }
    }
    return id;
}

fn lastCap() u6 {
    var i: u6 = 40;
    while (i > 0) : (i -= 1) {
        if (sys.prctl(sys.PR_CAPBSET_READ, i, 0, 0, 0) >= 0) return i;
    }
    return 0;
}

fn dropBounding(status_w: i32, mask: u64) void {
    const last = lastCap();
    var i: u8 = 0;
    while (i <= last) : (i += 1) {
        if ((mask >> @intCast(i)) & 1 == 0 and sys.prctl(sys.PR_CAPBSET_DROP, i, 0, 0, 0) < 0) childDie(status_w, "drop capability {d} failed", .{i});
    }
}

fn setCaps(status_w: i32, mask: u64) void {
    const hdr = [2]u32{ 0x20080522, 0 }; // _LINUX_CAPABILITY_VERSION_3, pid 0
    var data: [6]u32 = undefined;
    const lo: u32 = @truncate(mask);
    const hi: u32 = @truncate(mask >> 32);
    data = .{ lo, lo, lo, hi, hi, hi }; // eff, perm, inh per word: effective, permitted, inheritable
    // layout is {effective, permitted, inheritable} for each of the two 32-bit words
    data = .{ lo, lo, 0, hi, hi, 0 };
    if (sys.capset(&hdr, &data) < 0) childDie(status_w, "capset failed", .{});
}

fn installSeccomp(status_w: i32, spec: Value, caps: u64) void {
    var prog: [bpf.max_insns]bpf.Insn = undefined;
    const sc_mode = spec.strOr("seccomp", "default");
    const unconfined = spec.boolOr("privileged", false) or std.mem.eql(u8, sc_mode, "unconfined");
    // Literal unconfined, only in the workload VM: its filter protects a control channel that VM does not share
    // with ordinary containers.
    // The one exception is open_by_handle_at: with CAP_DAC_READ_SEARCH it opens any file on the data disk.
    const n = if (unconfined and util.workload) bpf.buildHandleDeny(&prog) else bpf.build(&prog, caps, unconfined);
    const fprog = sys.SockFprog{ .len = @intCast(n), .filter = @ptrCast(&prog) };
    if (sys.seccomp_filter(&fprog) < 0) childDie(status_w, "seccomp install failed", .{});
}

fn envHas(env: []const Value, key: []const u8) bool {
    for (env) |e| if (e == .str and std.mem.startsWith(u8, e.str, key) and e.str.len > key.len and e.str[key.len] == '=') return true;
    return false;
}

/// Finish in the container: user, cwd, env, caps, seccomp, execve. Never returns.
/// `exec_extra_env` are KEY=VALUE overrides (for exec).
fn limitResource(name: []const u8) ?usize {
    const names = [_][]const u8{ "cpu", "fsize", "data", "stack", "core", "rss", "nproc", "nofile", "memlock", "as", "locks", "sigpending", "msgqueue", "nice", "rtprio", "rttime" };
    for (names, 0..) |n, i| if (std.mem.eql(u8, n, name)) return i;
    return null;
}

fn runUser(status_w: i32, spec: Value, hostname: []const u8, tty: bool, is_init: bool, exec_req: ?Value) noreturn {
    const a = util.arena();
    const userspec = if (exec_req) |e| (if (e.strOr("user", "").len > 0) e.strOr("user", "") else spec.strOr("user", "")) else spec.strOr("user", "");
    const ident = lookupUser(userspec) orelse childDie(status_w, "unable to find user {s}: no matching entries in passwd file", .{userspec});
    const privileged = spec.boolOr("privileged", false) or (if (exec_req) |e| e.boolOr("privileged", false) else false);

    // argv and env
    const argv_v = if (exec_req) |e| e.list("argv") else spec.list("argv");
    if (argv_v.len == 0) childDie(status_w, "no command specified", .{});
    var env: std.ArrayList(Value) = .empty;
    for (spec.list("env")) |e| env.append(a, e) catch {};
    if (exec_req) |er| {
        for (er.list("env")) |e| {
            if (e != .str) continue;
            const eq = std.mem.indexOfScalar(u8, e.str, '=') orelse continue;
            // override existing key
            var replaced = false;
            for (env.items) |*x| if (x.* == .str and std.mem.startsWith(u8, x.str, e.str[0 .. eq + 1])) {
                x.* = e;
                replaced = true;
            };
            if (!replaced) env.append(a, e) catch {};
        }
    }
    const default_path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
    if (!envHas(env.items, "PATH")) env.append(a, .{ .str = "PATH=" ++ default_path }) catch {};
    if (!envHas(env.items, "HOSTNAME")) env.append(a, .{ .str = util.sf("HOSTNAME={s}", .{hostname}) }) catch {};
    if (!envHas(env.items, "HOME")) env.append(a, .{ .str = util.sf("HOME={s}", .{ident.home}) }) catch {};
    if (tty and !envHas(env.items, "TERM")) env.append(a, .{ .str = "TERM=xterm" }) catch {};

    const envp = a.allocSentinel(?[*:0]const u8, env.items.len, null) catch childDie(status_w, "oom", .{});
    var path_val: []const u8 = default_path;
    for (env.items, 0..) |e, i| {
        envp[i] = (util.dupeZ(a, e.str) catch childDie(status_w, "oom", .{})).ptr;
        if (std.mem.startsWith(u8, e.str, "PATH=")) path_val = e.str[5..];
    }
    const argv = a.allocSentinel(?[*:0]const u8, argv_v.len, null) catch childDie(status_w, "oom", .{});
    for (argv_v, 0..) |v, i| argv[i] = (util.dupeZ(a, if (v == .str) v.str else "") catch childDie(status_w, "oom", .{})).ptr;

    // cwd (created if missing, as Docker does)
    var cwd = spec.strOr("cwd", "/");
    if (exec_req) |e| if (e.strOr("cwd", "").len > 0) {
        cwd = e.strOr("cwd", "/");
    };
    if (cwd.len == 0) cwd = "/";
    const cwdz = util.zdup(cwd);
    if (sys.chdir(cwdz.ptr) < 0) {
        _ = util.mkdirp(cwd, 0o755);
        if (is_init) _ = sys.fchownat(sys.AT_FDCWD, cwdz.ptr, ident.uid, ident.gid, 0);
        if (sys.chdir(cwdz.ptr) < 0) childDie(status_w, "chdir to cwd (\"{s}\") failed", .{cwd});
    }

    if (is_init) timing.mark(.c_user);
    var default_lim = [2]u64{ 1048576, 1048576 };
    _ = sys.sc(.prlimit64, 0, 7, @intFromPtr(&default_lim), 0, 0, 0);
    for (spec.list("ulimits")) |limit| {
        const resource = limitResource(limit.strOr("name", "")) orelse childDie(status_w, "invalid ulimit", .{});
        const soft = limit.intOr("soft", -2);
        const hard = limit.intOr("hard", -2);
        if (soft < -1 or hard < -1 or (hard != -1 and (soft == -1 or soft > hard))) childDie(status_w, "invalid ulimit", .{});
        var lim = [2]u64{ if (soft == -1) std.math.maxInt(u64) else @intCast(soft), if (hard == -1) std.math.maxInt(u64) else @intCast(hard) };
        const rc = sys.sc(.prlimit64, 0, resource, @intFromPtr(&lim), 0, 0, 0);
        if (rc < 0) childDie(status_w, "ulimit {s}: errno {d}", .{ limit.strOr("name", ""), -rc });
    }

    if (is_init) timing.mark(.c_limits);
    const caps: u64 = if (privileged) all_caps else capMask(spec);
    // seccomp first: installing a filter needs CAP_SYS_ADMIN (still held), so Docker's no-NNP behaviour holds
    installSeccomp(status_w, spec, caps);
    if (is_init) timing.mark(.c_seccomp);
    if (caps != all_caps) dropBounding(status_w, caps);
    if (spec.boolOr("no_new_privs", false) and sys.prctl(sys.PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) < 0) childDie(status_w, "no_new_privs failed", .{});

    if (ident.uid != 0 or ident.gid != 0 or ident.ngroups > 0) {
        _ = sys.prctl(sys.PR_SET_KEEPCAPS, 0, 0, 0, 0);
        if (sys.setgroups(ident.groups[0..ident.ngroups]) < 0) childDie(status_w, "setgroups failed", .{});
        if (sys.setgid(ident.gid) < 0) childDie(status_w, "setgid failed", .{});
        if (sys.setuid(ident.uid) < 0) childDie(status_w, "setuid failed", .{});
    }
    if (ident.uid == 0) setCaps(status_w, caps);
    if (is_init) {
        timing.mark(.c_caps);
        timing.childFlush();
    }

    if (is_init and spec.boolOr("init", false)) {
        const init_argv = a.allocSentinel(?[*:0]const u8, argv_v.len + 2, null) catch childDie(status_w, "oom", .{});
        init_argv[0] = "/dev/docker-init";
        init_argv[1] = "--";
        for (argv_v, 0..) |_, i| init_argv[i + 2] = argv[i];
        const rc = sys.execve("/dev/docker-init", @ptrCast(init_argv.ptr), @ptrCast(envp.ptr));
        childDie(status_w, "exec init: {s}", .{errName(rc)});
    }

    // execvpe
    const prog = argv_v[0].str;
    if (std.mem.indexOfScalar(u8, prog, '/') != null) {
        const rc = sys.execve(argv[0].?, @ptrCast(argv.ptr), @ptrCast(envp.ptr));
        childDie(status_w, "exec: \"{s}\": {s}", .{ prog, errName(rc) });
    }
    var it = std.mem.splitScalar(u8, path_val, ':');
    var last_rc: isize = -sys.E.NOENT;
    while (it.next()) |dirp| {
        const full = util.zf("{s}/{s}", .{ if (dirp.len == 0) "." else dirp, prog });
        const rc = sys.execve(full.ptr, @ptrCast(argv.ptr), @ptrCast(envp.ptr));
        if (rc != -sys.E.NOENT and rc != -sys.E.NOTDIR) last_rc = rc else if (last_rc == -sys.E.NOENT) last_rc = rc;
    }
    if (last_rc == -sys.E.NOENT or last_rc == -sys.E.NOTDIR) childDie(status_w, "exec: \"{s}\": executable file not found in $PATH", .{prog});
    childDie(status_w, "exec: \"{s}\": {s}", .{ prog, errName(last_rc) });
}

fn errName(rc: isize) []const u8 {
    return switch (-rc) {
        sys.E.NOENT => "no such file or directory",
        sys.E.ACCES => "permission denied",
        sys.E.NOTDIR => "not a directory",
        sys.E.ISDIR => "is a directory",
        8 => "exec format error",
        else => "exec failed",
    };
}

// ------------------------------------------------------------------ exec (runs inside a stream child)

pub const ExecPlumb = struct {
    stdin_r: isize = -1, // what the exec'd process reads
    stdout_w: isize = -1,
    stderr_w: isize = -1,
    tty_socket: i32 = -1, // child sends its devpts master here
    tty_parent_socket: i32 = -1,
    status_w: i32,
};

/// In a forked stream child: join the container and fork the process. Returns pid of the process (in the
/// container's pid namespace as seen from here) or negative errno. The process never returns.
pub fn execInContainer(c: *Cont, req: Value, p: ExecPlumb) isize {
    const spec = loadSpec(c.idStr()) catch return -sys.E.NOENT;
    checkSecurity(spec) catch return -sys.E.INVAL;
    if (req.boolOr("privileged", false) and !util.workload) return -sys.E.INVAL;
    const pid_c = c.pid;
    const tty = req.boolOr("tty", false);
    // Only the exec'd process joins the cgroup, never this helper: from the container's pid namespace the helper is
    // invisible, so a nested init (k3s) could not evacuate it and enabling its subtree_control would fail with EBUSY.
    const cg_procs = sys.open(util.zf("/sys/fs/cgroup/noodle/{s}/cgroup.procs", .{c.idStr()}).ptr, sys.O.WRONLY, 0);
    defer sys.close(cg_procs);
    const names = [_]struct { n: []const u8, f: usize }{
        .{ .n = "user", .f = 0 },
        .{ .n = "mnt", .f = sys.CLONE.NEWNS },
        .{ .n = "uts", .f = sys.CLONE.NEWUTS },
        .{ .n = "ipc", .f = sys.CLONE.NEWIPC },
        .{ .n = "net", .f = sys.CLONE.NEWNET },
        .{ .n = "cgroup", .f = sys.CLONE.NEWCGROUP },
        .{ .n = "pid", .f = sys.CLONE.NEWPID },
    };
    var fds: [8]isize = undefined;
    var nfd: usize = 0;
    defer for (fds[0..nfd]) |fd| sys.close(fd);
    for (names) |nm| {
        if (nm.f == 0) continue;
        const fd = sys.open(util.zf("/proc/{d}/ns/{s}", .{ pid_c, nm.n }).ptr, sys.O.RDONLY, 0);
        if (fd < 0) return fd;
        fds[nfd] = fd;
        nfd += 1;
    }
    // mount ns last, pid ns joins children only
    // fds order: mnt(0) uts(1) ipc(2) net(3) cgroup(4) pid(5)
    // cgroup(4) is joined by the child after it moved into the container's cgroup (see below).
    const seq = [_]struct { idx: usize, f: usize }{
        .{ .idx = 5, .f = sys.CLONE.NEWPID },
        .{ .idx = 3, .f = sys.CLONE.NEWNET },
        .{ .idx = 2, .f = sys.CLONE.NEWIPC },
        .{ .idx = 1, .f = sys.CLONE.NEWUTS },
        .{ .idx = 0, .f = sys.CLONE.NEWNS },
    };
    for (seq) |s| {
        const rc = sys.setns(fds[s.idx], s.f);
        if (rc < 0) return rc;
    }

    const child = sys.fork();
    if (child < 0) return child;
    if (child == 0) {
        // Still in the agent's cgroup namespace, so the move is allowed; EBUSY (a nested runtime made the group a
        // non-leaf) leaves the process where it was, as before.
        const moved = if (cg_procs >= 0) sys.write(cg_procs, "0") else cg_procs;
        if (moved < 0 and moved != -sys.E.BUSY) childDie(p.status_w, "exec: join container cgroup: errno {d}", .{-moved});
        const joined = sys.setns(fds[4], sys.CLONE.NEWCGROUP);
        if (joined < 0) childDie(p.status_w, "exec: join cgroup namespace: errno {d}", .{-joined});
        for (fds[0..nfd]) |fd| sys.close(fd);
        sys.close(p.tty_parent_socket);
        _ = sys.sigprocmask(2, 0);
        _ = sys.prctl(sys.PR_SET_PDEATHSIG, sys.SIG.KILL, 0, 0, 0);
        // setns(NEWNS) supplies the namespace root, even if init later chrooted.
        const hostname = spec.strOr("hostname", "");
        const hn = if (hostname.len > 0) hostname else c.idStr()[0..@min(c.idStr().len, 12)];
        if (tty) {
            childPty(p.status_w, p.tty_socket, .{ 0, 0, 0, 0 }, spec, req, false);
        } else {
            if (p.stdin_r >= 0) {
                _ = sys.dup3(p.stdin_r, 0, 0);
            } else {
                const nul = sys.open("/dev/null", sys.O.RDONLY, 0);
                if (nul >= 0) _ = sys.dup3(nul, 0, 0);
            }
            _ = sys.dup3(p.stdout_w, 1, 0);
            _ = sys.dup3(p.stderr_w, 2, 0);
        }
        runUser(p.status_w, spec, hn, tty, false, req);
    }
    return child;
}

// ------------------------------------------------------------------ signals, pause, update, remove

pub fn kill(id: []const u8, sig: i64) Fail!void {
    const c = find(id) orelse return fail("no such container", .{}, sys.E.NOENT);
    if (c.state != .running) return fail("container is not running", .{}, sys.E.INVAL);
    const rc = sys.kill(c.pid, @intCast(sig));
    if (rc < 0) return fail("kill failed", .{}, rc);
    // a frozen container needs a thaw for the signal to be delivered
    if (sig == sys.SIG.KILL or sig == sys.SIG.TERM) _ = util.writeSys(util.zf("/sys/fs/cgroup/noodle/{s}/cgroup.freeze", .{id}).ptr, "0");
}

pub fn pause(id: []const u8, on: bool) Fail!void {
    const c = find(id) orelse return fail("no such container", .{}, sys.E.NOENT);
    if (c.state != .running) return fail("container is not running", .{}, sys.E.INVAL);
    const rc = util.writeSys(util.zf("/sys/fs/cgroup/noodle/{s}/cgroup.freeze", .{id}).ptr, if (on) "1" else "0");
    if (rc < 0) return fail("freeze failed", .{}, rc);
}

pub fn remove(id: []const u8) Fail!void {
    if (!util.validId(id)) return fail("invalid container id", .{}, sys.E.INVAL);
    const dir = cdir(id);
    const c = find(id) orelse {
        // not adopted by this agent run (e.g. left over from an earlier boot): just clean the disk
        _ = sys.umount2(util.zf("{s}/merged", .{dir}).ptr, 2);
        util.rmTreePath(dir.ptr);
        _ = sys.unlinkat(sys.AT_FDCWD, cgroupPath(id).ptr, sys.AT_REMOVEDIR);
        return;
    };
    if (c.state == .running) return fail("container is running", .{}, sys.E.BUSY);
    const cg = cgroupPath(id);
    var shared_netns = c.netns == 0;
    for (&conts) |*other| {
        if (other.used and other.state == .running and other.netns == c.netns) shared_netns = true;
    }
    for (&c.nets) |*cn| if (cn.used) {
        if (net.findNet(cn.name[0..cn.nlen])) |n| net.removeRecordsFor(n, cn.ip, cn.ip6);
        // Private namespace teardown deletes its veths; explicit deletion waits on kernel RCU.
        if (cn.attached and shared_netns) net.deleteLinkByName(cn.host_if[0..cn.hlen]);
    };
    resolver.close(contIndex(c));
    sys.close(c.log_fd);
    sys.close(c.master);
    c.master = -1;
    finishTtyWaiters(c);
    if (c.tty_requests[0] >= 0) _ = sys.epoll_del(util.epfd, c.tty_requests[0]);
    for (c.tty_requests) |fd| sys.close(fd);
    if (c.tty) tty_count -= 1;
    closeStdin(c);
    c.* = .{};
    teardown(dir, cg);
}

// Unmounting the overlay and deleting the upper directory are the slowest part of a remove and nothing waits on them
// but later operations that look at the disk. A child does the work and the answer goes back at once. The container ID
// never comes back, so `create` and `start` of other containers do not wait; everything else calls `teardownFinish`.
var teardowns: [32]i32 = @splat(0);

fn teardownWork(dir: [:0]const u8, cg: [:0]const u8) void {
    _ = sys.umount2(util.zf("{s}/merged", .{dir}).ptr, 2);
    util.rmTreePath(dir.ptr);
    _ = sys.unlinkat(sys.AT_FDCWD, cg.ptr, sys.AT_REMOVEDIR);
}

fn teardown(dir: [:0]const u8, cg: [:0]const u8) void {
    const slot = for (&teardowns) |*t| {
        if (t.* == 0) break t;
    } else null;
    const pid: isize = if (slot != null) sys.fork() else -1;
    if (pid == 0) {
        closeStdinRelaysInChild();
        teardownWork(dir, cg);
        sys.exit(0);
    }
    if (pid < 0) {
        teardownWork(dir, cg);
        return;
    }
    slot.?.* = @intCast(pid);
}

/// A reaped child that was a teardown. The event loop calls this for every child.
pub fn teardownReaped(pid: i32) void {
    for (&teardowns) |*t| {
        if (t.* == pid) t.* = 0;
    }
}

/// Wait for removes still in progress, so disk state is what the host believes it is.
pub fn teardownFinish() void {
    for (&teardowns) |*t| {
        if (t.* == 0) continue;
        var status: u32 = 0;
        _ = sys.wait4(t.*, &status, 0);
        t.* = 0;
    }
}

// ------------------------------------------------------------------ output + exit

const log_hdr = 13;

fn setLogLimits(c: *Cont, spec: Value) void {
    const mx = spec.intOr("log_max_size", 0);
    const files = spec.intOr("log_max_file", 1);
    c.log_max = if (mx > 0) @intCast(mx) else 0;
    c.log_files = if (files > 1) @intCast(@min(files, 10000)) else 1;
}

/// Docker's scheme: `log` is current, `log.1` the newest rotated file, `log.<files-1>` the oldest.
/// A reader that opened an older file keeps its descriptor, so rotation never disturbs it.
fn rotateLog(c: *Cont) void {
    const id = c.idStr();
    const cur = logPath(id);
    if (c.log_files <= 1) {
        _ = sys.unlinkat(sys.AT_FDCWD, cur.ptr, 0);
    } else {
        var i: u32 = c.log_files - 1;
        while (i >= 1) : (i -= 1) {
            const from = if (i == 1) cur else util.zf("{s}/containers/{s}/log.{d}", .{ util.base, id, i - 1 });
            const to = util.zf("{s}/containers/{s}/log.{d}", .{ util.base, id, i });
            _ = sys.renameat(sys.AT_FDCWD, from.ptr, sys.AT_FDCWD, to.ptr);
        }
    }
    const nfd = sys.open(cur.ptr, sys.O.WRONLY | sys.O.CREAT | sys.O.APPEND, 0o600);
    if (nfd < 0) return; // keep writing to the old file rather than lose output
    sys.close(c.log_fd);
    c.log_fd = @intCast(nfd);
    // a failed rename leaves the old file in place, so keep its real size
    var st: sys.Stat = undefined;
    c.log_size = if (sys.fstat(nfd, &st) >= 0) @intCast(st.size) else 0;
}

fn appendLog(c: *Cont, stream: u8, data: []const u8) void {
    var rest = data;
    while (rest.len > 0) {
        // one read can exceed max-size, so split it to keep every file within the limit
        var n = rest.len;
        if (c.log_max > log_hdr and n > c.log_max - log_hdr) {
            n = @intCast(c.log_max - log_hdr);
            // end the frame on a line when one fits, so a rotated file starts with a whole line
            if (std.mem.lastIndexOfScalar(u8, rest[0..n], '\n')) |nl| n = nl + 1;
        }
        appendFrame(c, stream, rest[0..n]);
        rest = rest[n..];
    }
}

const LogFile = struct {
    fd: isize,
    pub fn write(self: LogFile, b: []const u8) isize {
        return sys.write(self.fd, b);
    }
    pub fn truncate(self: LogFile, len: u64) void {
        _ = sys.ftruncate(self.fd, len);
    }
};

fn appendFrame(c: *Cont, stream: u8, data: []const u8) void {
    var hdr: [log_hdr]u8 = undefined;
    hdr[0] = stream;
    std.mem.writeInt(i64, hdr[1..9], @intCast(sys.realtime_ns()), .big);
    std.mem.writeInt(u32, hdr[9..13], @intCast(data.len), .big);
    // header and data are written separately only if data does not already sit behind a header slot
    var buf: [log_hdr + 32 * 1024]u8 = undefined;
    @memcpy(buf[0..log_hdr], &hdr);
    @memcpy(buf[log_hdr .. log_hdr + data.len], data);
    const total: u64 = log_hdr + data.len;
    if (c.log_max > 0 and c.log_size > 0 and c.log_size + total > c.log_max) rotateLog(c);
    util.appendWhole(LogFile{ .fd = c.log_fd }, &c.log_size, buf[0 .. log_hdr + data.len]);
}

/// Readable event on a container output fd. slot: 0 stdout, 1 stderr, 2 tty master.
pub fn onOutput(idx: u32, slot: u32) void {
    if (idx >= max_conts) return;
    const c = &conts[idx];
    if (!c.used) return;
    const fd: i32 = if (slot == 2) c.master else c.out[slot & 1];
    if (fd < 0) return;
    var data: [32 * 1024]u8 = undefined;
    var rounds: usize = 0;
    while (rounds < 16) : (rounds += 1) {
        const n = sys.read(fd, &data);
        if (n == -sys.E.AGAIN) return;
        if (n == -sys.E.INTR) continue;
        if (n <= 0) {
            // EOF or EIO (pty slave closed): stop watching
            _ = sys.epoll_del(util.epfd, fd);
            return;
        }
        appendLog(c, if (slot == 1) 2 else 1, data[0..@intCast(n)]);
    }
}

fn drain(c: *Cont) void {
    if (c.tty) {
        if (c.master >= 0) onOutput(contIndex(c), 2);
    } else {
        onOutput(contIndex(c), 0);
        onOutput(contIndex(c), 1);
    }
}

pub const Exit = struct { id: [64]u8, idlen: u8, code: i32, oom: bool };

/// Called for every reaped pid. Returns an Exit if it was a container init.
pub fn onChildExit(pid: i32, status: u32) ?Exit {
    for (&conts) |*c| {
        if (!(c.used and c.state == .running and c.pid == pid)) continue;
        const code: i32 = if (status & 0x7f == 0) @intCast((status >> 8) & 0xff) else 128 + @as(i32, @intCast(status & 0x7f));
        drain(c);
        for (&c.out) |*f| {
            if (f.* >= 0) {
                _ = sys.epoll_del(util.epfd, f.*);
                sys.close(f.*);
                f.* = -1;
            }
        }
        if (c.master >= 0) {
            _ = sys.epoll_del(util.epfd, c.master);
            sys.close(c.master);
            c.master = -1;
        }
        // kill stragglers in the cgroup
        _ = util.writeSys(util.zf("/sys/fs/cgroup/noodle/{s}/cgroup.kill", .{c.idStr()}).ptr, "1");
        var oom = false;
        if (util.readFile(util.zf("/sys/fs/cgroup/noodle/{s}/memory.events", .{c.idStr()}).ptr, 4096)) |t| {
            if (util.flatKey(t, "oom_kill")) |k| oom = k > 0;
        }
        resolver.close(contIndex(c));
        c.state = .exited;
        c.code = code;
        c.pid = 0;
        // `docker start -a` attaches before it starts, so the next run's stdin must exist now. On failure start() retries.
        if (c.has_stdin and !c.tty) _ = openStdin(c);
        var cb: [16]u8 = undefined;
        _ = util.writeFile(exitPath(c.idStr()).ptr, std.fmt.bufPrint(&cb, "{d}", .{code}) catch "0", 0o600);
        var ex = Exit{ .id = c.id, .idlen = c.idlen, .code = code, .oom = oom };
        _ = &ex;
        return ex;
    }
    return null;
}

pub fn resize(id: []const u8, rows: i64, cols: i64) Fail!void {
    const c = find(id) orelse return fail("no such container", .{}, sys.E.NOENT);
    if (!c.tty) return fail("container has no tty", .{}, sys.E.INVAL);
    if (rows < 0 or rows > 65535 or cols < 0 or cols > 65535) return fail("invalid tty size", .{}, sys.E.INVAL);
    var ws = [4]u16{ @intCast(rows), @intCast(cols), 0, 0 };
    if (c.master >= 0) {
        const rc = sys.ioctl(c.master, sys.TIOCSWINSZ, @intFromPtr(&ws));
        if (rc < 0) return fail("resize failed", .{}, rc);
        saveWinsize(id, &ws) catch {}; // a full/removed data directory cannot break a live terminal
    } else try saveWinsize(id, &ws);
}

fn saveWinsize(id: []const u8, ws: *const [4]u16) Fail!void {
    const dir = cdir(id);
    const temp = util.zf("{s}/winsize.{d}", .{ dir, sys.getpid() });
    defer _ = sys.unlinkat(sys.AT_FDCWD, temp.ptr, 0);
    const saved = util.writeFile(temp.ptr, std.mem.asBytes(ws), 0o600);
    if (saved < 0) return fail("save tty size", .{}, saved);
    const renamed = sys.renameat(sys.AT_FDCWD, temp.ptr, sys.AT_FDCWD, util.zf("{s}/winsize", .{dir}).ptr);
    if (renamed < 0) return fail("publish tty size", .{}, renamed);
}

// ------------------------------------------------------------------ stats / top / diff

pub fn stats(id: []const u8, b: *json.Buf) Fail!void {
    const c = find(id) orelse return fail("no such container", .{}, sys.E.NOENT);
    const cg = util.zf("/sys/fs/cgroup/noodle/{s}", .{id});
    var cpu_ns: u64 = 0;
    if (util.readFile(util.zf("{s}/cpu.stat", .{cg}).ptr, 4096)) |t| cpu_ns = (util.flatKey(t, "usage_usec") orelse 0) * 1000;
    const mem = util.readNum(util.zf("{s}/memory.current", .{cg}).ptr) orelse 0;
    var limit: u64 = 0;
    if (util.readFile(util.zf("{s}/memory.max", .{cg}).ptr, 64)) |t| {
        limit = util.parseU64(t) orelse 0;
    }
    if (limit == 0) limit = totalMemory();
    const pids = util.readNum(util.zf("{s}/pids.current", .{cg}).ptr) orelse 0;
    var rd: u64 = 0;
    var wr: u64 = 0;
    if (util.readFile(util.zf("{s}/io.stat", .{cg}).ptr, 8192)) |t| {
        var lines = std.mem.tokenizeScalar(u8, t, '\n');
        while (lines.next()) |line| {
            var toks = std.mem.tokenizeScalar(u8, line, ' ');
            _ = toks.next();
            while (toks.next()) |kv| {
                if (std.mem.startsWith(u8, kv, "rbytes=")) rd += util.parseU64(kv[7..]) orelse 0;
                if (std.mem.startsWith(u8, kv, "wbytes=")) wr += util.parseU64(kv[7..]) orelse 0;
            }
        }
    }
    var rx: u64 = 0;
    var tx: u64 = 0;
    if (c.state == .running) {
        if (util.readFile(util.zf("/proc/{d}/net/dev", .{c.pid}).ptr, 16384)) |t| {
            var lines = std.mem.tokenizeScalar(u8, t, '\n');
            _ = lines.next();
            _ = lines.next();
            while (lines.next()) |line| {
                const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                if (std.mem.eql(u8, std.mem.trim(u8, line[0..colon], " "), "lo")) continue;
                var f = std.mem.tokenizeScalar(u8, line[colon + 1 ..], ' ');
                rx += util.parseU64(f.next() orelse "0") orelse 0;
                var k: usize = 0;
                while (k < 7) : (k += 1) _ = f.next();
                tx += util.parseU64(f.next() orelse "0") orelse 0;
            }
        }
    }
    b.print(",\"cpu_ns\":{d},\"memory\":{d},\"memory_limit\":{d},\"pids\":{d},\"net_rx\":{d},\"net_tx\":{d},\"blk_read\":{d},\"blk_write\":{d}", .{ cpu_ns, mem, limit, pids, rx, tx, rd, wr }) catch {};
}

fn totalMemory() u64 {
    if (util.readFile("/proc/meminfo", 4096)) |t| {
        var lines = std.mem.tokenizeScalar(u8, t, '\n');
        while (lines.next()) |line| if (std.mem.startsWith(u8, line, "MemTotal:")) {
            var it = std.mem.tokenizeScalar(u8, line[9..], ' ');
            return (util.parseU64(it.next() orelse "0") orelse 0) * 1024;
        };
    }
    return 0;
}

pub fn top(id: []const u8, b: *json.Buf) Fail!void {
    _ = find(id) orelse return fail("no such container", .{}, sys.E.NOENT);
    const procs = util.readFile(util.zf("/sys/fs/cgroup/noodle/{s}/cgroup.procs", .{id}).ptr, 1 << 16) orelse "";
    b.raw(",\"processes\":[") catch {};
    var first = true;
    var it = std.mem.tokenizeScalar(u8, procs, '\n');
    while (it.next()) |ps| {
        const pid = std.fmt.parseInt(u32, ps, 10) catch continue;
        const stat = util.readFile(util.zf("/proc/{d}/stat", .{pid}).ptr, 4096) orelse continue;
        const rp = std.mem.lastIndexOfScalar(u8, stat, ')') orelse continue;
        var f = std.mem.tokenizeScalar(u8, stat[rp + 1 ..], ' ');
        _ = f.next();
        const ppid = util.parseU64(f.next() orelse "0") orelse 0;
        var st: sys.Stat = undefined;
        var uid: u32 = 0;
        if (sys.fstatat(sys.AT_FDCWD, util.zf("/proc/{d}", .{pid}).ptr, &st, 0) >= 0) uid = st.uid;
        var cmd: []const u8 = "";
        if (util.readFile(util.zf("/proc/{d}/cmdline", .{pid}).ptr, 4096)) |cl| {
            const mcl = util.arena().dupe(u8, cl) catch cl;
            for (mcl) |*ch| if (ch.* == 0) {
                ch.* = ' ';
            };
            cmd = std.mem.trimEnd(u8, mcl, " ");
        }
        if (cmd.len == 0) {
            const lp = std.mem.indexOfScalar(u8, stat, '(') orelse 0;
            cmd = stat[lp + 1 .. rp];
        }
        if (!first) b.byte(',') catch {};
        first = false;
        b.print("{{\"pid\":{d},\"ppid\":{d},\"uid\":{d},\"cmd\":", .{ pid, ppid, uid }) catch {};
        b.str(cmd) catch {};
        b.byte('}') catch {};
    }
    b.byte(']') catch {};
}

const DiffCtx = struct {
    b: *json.Buf,
    lower: []const []const u8, // layer dirs, top first
    first: bool = true,
};

fn existsInLower(lower: []const []const u8, rel: []const u8) bool {
    for (lower) |l| {
        const p = util.zf("{s}/{s}", .{ l, rel });
        var st: sys.Stat = undefined;
        if (sys.fstatat(sys.AT_FDCWD, p.ptr, &st, sys.AT_SYMLINK_NOFOLLOW) >= 0) {
            if ((st.mode & sys.S.IFMT) == sys.S.IFCHR and st.rdev == 0) return false;
            return true;
        }
    }
    return false;
}

fn diffWalk(ctx: *DiffCtx, dirfd: isize, rel: []const u8, depth: u32) void {
    if (depth > 100) return;
    const a = util.arena();
    var names: std.ArrayList([:0]u8) = .empty;
    var dbuf: [4096]u8 align(8) = undefined;
    while (true) {
        const n = sys.getdents64(dirfd, &dbuf);
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
    for (names.items) |name| {
        const path = if (rel.len == 0) util.sf("{s}", .{name}) else util.sf("{s}/{s}", .{ rel, name });
        if (rel.len == 0) {
            const skip = [_][]const u8{ "proc", "sys", "dev", ".dockerenv" };
            if (util.contains(&skip, name)) continue;
        }
        if (std.mem.eql(u8, path, "etc/hosts") or std.mem.eql(u8, path, "etc/hostname") or std.mem.eql(u8, path, "etc/resolv.conf")) continue;
        var st: sys.Stat = undefined;
        if (sys.fstatat(dirfd, name.ptr, &st, sys.AT_SYMLINK_NOFOLLOW) < 0) continue;
        const is_wh = (st.mode & sys.S.IFMT) == sys.S.IFCHR and st.rdev == 0;
        const kind: u8 = if (is_wh) 2 else if (existsInLower(ctx.lower, path)) 0 else 1;
        if (!ctx.first) ctx.b.byte(',') catch {};
        ctx.first = false;
        ctx.b.raw("{\"path\":") catch {};
        ctx.b.str(util.sf("/{s}", .{path})) catch {};
        ctx.b.print(",\"kind\":{d}}}", .{kind}) catch {};
        if ((st.mode & sys.S.IFMT) == sys.S.IFDIR) {
            const fd = sys.openat(dirfd, name.ptr, sys.O.RDONLY | sys.O.DIRECTORY | sys.O.NOFOLLOW, 0);
            if (fd >= 0) {
                diffWalk(ctx, fd, path, depth + 1);
                sys.close(fd);
            }
        }
    }
}

pub fn diff(id: []const u8, b: *json.Buf) Fail!void {
    _ = find(id) orelse return fail("no such container", .{}, sys.E.NOENT);
    const spec = try loadSpec(id);
    const a = util.arena();
    var lower: std.ArrayList([]const u8) = .empty;
    for (spec.list("layers")) |l| if (l == .str) lower.append(a, @import("layers.zig").layerPath(util.hexOf(l.str))) catch {};
    const upper = util.zf("{s}/containers/{s}/upper", .{ util.base, id });
    const fd = sys.open(upper.ptr, sys.O.RDONLY | sys.O.DIRECTORY, 0);
    if (fd < 0) return fail("open upper", .{}, fd);
    defer sys.close(fd);
    b.raw(",\"changes\":[") catch {};
    var ctx = DiffCtx{ .b = b, .lower = lower.items };
    diffWalk(&ctx, fd, "", 0);
    b.byte(']') catch {};
}

pub fn specLayers(id: []const u8) ?[]const Value {
    const spec = loadSpec(id) catch return null;
    return spec.list("layers");
}

pub fn updateLimits(id: []const u8, req: Value) Fail!void {
    _ = find(id) orelse return fail("no such container", .{}, sys.E.NOENT);
    try applyLimits(id, req);
}

pub fn killAll() void {
    for (&conts) |*c| if (c.used and c.state == .running) {
        _ = sys.kill(c.pid, sys.SIG.KILL);
    };
}

/// Re-adopt containers left on disk by a previous agent run: none are running (new VM boot), so only
/// stale directories are cleaned.
pub fn sweepStale() void {
    const dir = util.zf("{s}/containers", .{util.base});
    const fd = sys.open(dir.ptr, sys.O.RDONLY | sys.O.DIRECTORY, 0);
    if (fd < 0) return;
    defer sys.close(fd);
    const Ctx = struct {
        fn each(_: void, name: []const u8, _: u8) void {
            // leave data in place; the host decides what to remove. Just clear stale exit markers.
            _ = sys.unlinkat(sys.AT_FDCWD, util.zf("{s}/containers/{s}/exit", .{ util.base, name }).ptr, 0);
        }
    };
    util.forEachDirent(fd, {}, Ctx.each);
}
