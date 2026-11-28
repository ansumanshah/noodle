//! PID 1 of a Linux machine VM. Boots from an initramfs, mounts the
//! machine's own disk (/dev/vda) as the root filesystem, extracts the seed rootfs once (/dev/vdb, a raw tar
//! the host attaches only before the first boot), sets up the user, network and optional share, then serves
//! shell sessions over vsock, or hands PID 1 to systemd and serves as a guest unit.
const std = @import("std");
const sys = @import("sys.zig");
const util = @import("util.zig");
const net = @import("net.zig");
const tarfs = @import("tarfs.zig");
const session = @import("machine_session.zig");
const systemd = @import("machine_systemd.zig");

const agent_port: u32 = 1030;
const marker = "/mnt/root/.noodle-machine";

const Cfg = struct { user: []const u8 = "user", uid: u32 = 1000, host: []const u8 = "machine", share: bool = false, systemd: bool = false };

fn mountDir(src: [*:0]const u8, target: [*:0]const u8, fs: [*:0]const u8, flags: usize, data: ?[*:0]const u8) isize {
    _ = sys.mkdirat(sys.AT_FDCWD, target, 0o755);
    return sys.mount(src, target, fs, flags, data);
}

fn parseCmdline() Cfg {
    var c = Cfg{};
    const text = util.readFile("/proc/cmdline", 4096) orelse return c;
    var it = std.mem.tokenizeAny(u8, text, " \n");
    while (it.next()) |tok| {
        if (std.mem.startsWith(u8, tok, "noodle.user=")) c.user = tok[12..];
        if (std.mem.startsWith(u8, tok, "noodle.uid=")) c.uid = std.fmt.parseInt(u32, tok[11..], 10) catch c.uid;
        if (std.mem.startsWith(u8, tok, "noodle.host=")) c.host = tok[12..];
        if (std.mem.eql(u8, tok, "noodle.share=1")) c.share = true;
        if (std.mem.eql(u8, tok, "noodle.systemd=1")) c.systemd = true;
    }
    return c;
}

const FdSrc = struct {
    fd: isize,
    pub fn read(self: *FdSrc, buf: []u8) usize {
        const n = sys.read(self.fd, buf);
        return if (n < 0) 0 else @intCast(n);
    }
};

fn waitFor(path: [*:0]const u8) bool {
    var tries: usize = 0;
    while (!util.exists(path) and tries < 200) : (tries += 1) sys.sleep_ms(20);
    return util.exists(path);
}

/// Rewrite an /etc file without lines whose first field (or third, for numeric ids) matches, then append `line`.
fn replaceEntry(path: [*:0]const u8, name: []const u8, id: ?u32, line: []const u8, mode: usize) void {
    const old = util.readFile(path, 1 << 20) orelse "";
    const out = util.arena().alloc(u8, old.len + line.len + 2) catch return;
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, old, '\n');
    while (lines.next()) |l| {
        if (l.len == 0) continue;
        var f = std.mem.splitScalar(u8, l, ':');
        const first = f.next() orelse "";
        _ = f.next();
        const third = f.next() orelse "";
        var drop = std.mem.eql(u8, first, name);
        if (id) |v| if (std.fmt.parseInt(u32, third, 10) catch null) |t| {
            if (t == v) drop = true;
        };
        if (drop) continue;
        @memcpy(out[n .. n + l.len], l);
        n += l.len;
        out[n] = '\n';
        n += 1;
    }
    @memcpy(out[n .. n + line.len], line);
    n += line.len;
    out[n] = '\n';
    n += 1;
    _ = util.writeFile(path, out[0..n], mode);
}

fn copySkel(home: [*:0]const u8, uid: u32) void {
    const dir = sys.open("/etc/skel", sys.O.RDONLY | sys.O.DIRECTORY, 0);
    if (dir < 0) return;
    defer sys.close(dir);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = sys.getdents64(dir, &buf);
        if (n <= 0) break;
        var off: usize = 0;
        while (off < @as(usize, @intCast(n))) {
            const reclen = std.mem.readInt(u16, buf[off + 16 ..][0..2], .little);
            const dtype = buf[off + 18];
            const name = std.mem.sliceTo(buf[off + 19 ..], 0);
            off += reclen;
            if (dtype != 8 or name.len == 0) continue; // regular files only
            const src = util.zf("/etc/skel/{s}", .{name});
            const dst = util.zf("{s}/{s}", .{ std.mem.span(home), name });
            const data = util.readFile(src.ptr, 1 << 20) orelse continue;
            _ = util.writeFile(dst.ptr, data, 0o644);
            _ = sys.fchownat(sys.AT_FDCWD, dst.ptr, uid, uid, 0);
        }
    }
}

fn setupUser(c: Cfg) void {
    const shell: []const u8 = if (util.exists("/bin/bash")) "/bin/bash" else "/bin/sh";
    const home = util.zf("/home/{s}", .{c.user});
    replaceEntry("/etc/passwd", c.user, c.uid, util.sf("{s}:x:{d}:{d}:{s}:{s}:{s}", .{ c.user, c.uid, c.uid, c.user, home, shell }), 0o644);
    replaceEntry("/etc/group", c.user, c.uid, util.sf("{s}:x:{d}:", .{ c.user, c.uid }), 0o644);
    replaceEntry("/etc/shadow", c.user, null, util.sf("{s}:*:19000:0:99999:7:::", .{c.user}), 0o640);
    _ = util.mkdirp("/etc/sudoers.d", 0o750);
    _ = util.writeFile("/etc/sudoers.d/noodle", util.sf("{s} ALL=(ALL) NOPASSWD:ALL\n", .{c.user}), 0o440);
    _ = sys.chmodPath("/etc/sudoers.d/noodle", 0o440);
    if (!util.exists(home.ptr)) {
        _ = util.mkdirp(home, 0o755);
        _ = sys.fchownat(sys.AT_FDCWD, home.ptr, c.uid, c.uid, 0);
        _ = sys.chmodPath(home.ptr, 0o755);
        copySkel(home.ptr, c.uid);
    }
    _ = util.writeFile("/etc/hostname", util.sf("{s}\n", .{c.host}), 0o644);
    _ = util.writeFile("/etc/hosts", util.sf("127.0.0.1 localhost {s}\n::1 localhost ip6-localhost\n", .{c.host}), 0o644);
}

/// switch_root: the ext4 mount becomes "/" (the initramfs root cannot be unmounted, so it is moved over).
fn switchRoot() bool {
    for ([_][*:0]const u8{ "proc", "sys", "dev" }) |d| {
        const target = util.zf("/mnt/root/{s}", .{std.mem.span(d)});
        _ = sys.mkdirat(sys.AT_FDCWD, target.ptr, 0o755);
        if (sys.mount(util.zf("/{s}", .{std.mem.span(d)}).ptr, target.ptr, null, sys.MS.MOVE, null) < 0) return false;
    }
    if (sys.chdir("/mnt/root") < 0) return false;
    if (sys.mount(".", "/", null, sys.MS.MOVE, null) < 0) return false;
    if (sys.chroot(".") < 0) return false;
    _ = sys.chdir("/");
    return true;
}

fn fail(what: []const u8) noreturn {
    util.log("machine boot failed: {s}", .{what});
    sys.sleep_ms(500);
    sys.poweroff();
    while (true) sys.sleep_ms(1000);
}

pub const std_options: std.Options = .{ .enable_segfault_handler = false };

pub fn main() void {
    util.initArena();
    // The same binary is installed as a systemd unit; only PID 1 prepares the rootfs.
    if (sys.getpid() != 1) {
        util.openLog();
        serveSessions();
    }
    _ = mountDir("proc", "/proc", "proc", 0, null);
    _ = mountDir("sysfs", "/sys", "sysfs", 0, null);
    _ = mountDir("devtmpfs", "/dev", "devtmpfs", 0, "mode=755");
    util.openLog();
    const cfg = parseCmdline();
    util.log("machine init starting for {s} (uid {d})", .{ cfg.user, cfg.uid });
    if (!waitFor("/dev/vda")) fail("no /dev/vda");
    _ = util.mkdirp("/mnt/root", 0o755);
    if (sys.mount("/dev/vda", "/mnt/root", "ext4", sys.MS.NOATIME, null) < 0) fail("cannot mount /dev/vda");
    if (util.exists("/dev/vdb") and !util.exists(marker)) {
        const fd = sys.open("/dev/vdb", sys.O.RDONLY, 0);
        const root = sys.open("/mnt/root", sys.O.RDONLY | sys.O.DIRECTORY, 0);
        if (fd < 0 or root < 0) fail("cannot open the seed disk");
        var src = FdSrc{ .fd = fd };
        tarfs.extractAll(&src, root, false) catch fail("rootfs extraction failed");
        sys.close(fd);
        sys.close(root);
        _ = util.writeFile(marker, "1\n", 0o644);
        sys.sync();
        util.log("rootfs extracted", .{});
    }
    if (!util.exists(marker)) fail("disk has no rootfs");
    if (!switchRoot()) fail("switch_root");
    _ = mountDir("devpts", "/dev/pts", "devpts", 0, "gid=5,mode=620,ptmxmode=666");
    _ = mountDir("tmpfs", "/dev/shm", "tmpfs", sys.MS.NOSUID | sys.MS.NODEV, "mode=1777");
    _ = mountDir("tmpfs", "/run", "tmpfs", sys.MS.NOSUID | sys.MS.NODEV, "mode=755");
    _ = mountDir("tmpfs", "/tmp", "tmpfs", sys.MS.NOSUID | sys.MS.NODEV, "mode=1777");
    const cg = mountDir("cgroup2", "/sys/fs/cgroup", "cgroup2", sys.MS.NOSUID | sys.MS.NODEV | sys.MS.NOEXEC, null);
    if (cfg.systemd and cg < 0) fail("systemd requires kernel cgroup v2 support (CONFIG_CGROUPS)");
    _ = sys.sethostname(cfg.host);
    setupUser(cfg);
    if (cfg.share) {
        const rc = mountDir("share", "/mnt/share", "virtiofs", 0, null);
        if (rc < 0) util.log("share mount failed: errno {d}", .{-rc});
    }
    if (!net.dhcpEth0()) util.log("no network lease", .{});
    _ = util.writeFile("/run/noodle-ip", util.sf("{d}.{d}.{d}.{d}\n", .{ net.guest_ip[0], net.guest_ip[1], net.guest_ip[2], net.guest_ip[3] }), 0o644);

    if (cfg.systemd) {
        systemd.boot() catch fail("systemd handoff failed: image needs systemd, executable /sbin/init and systemctl; see console.log");
    }
    serveSessions();
}

fn serveSessions() noreturn {
    // agent: host-initiated vsock, one forked process per session
    const l = sys.socket(sys.AF_VSOCK, sys.SOCK_STREAM, 0);
    const addr = sys.SockaddrVm{ .port = agent_port, .cid = 0xffffffff };
    if (l < 0 or sys.bind(l, &addr, @sizeOf(sys.SockaddrVm)) < 0 or sys.listen(l, 16) < 0) fail("vsock listen");
    util.log("machine ready", .{});
    const chld_bit: u64 = @as(u64, 1) << (sys.SIG.CHLD - 1);
    _ = sys.sigprocmask(0, chld_bit);
    const sfd = sys.signalfd(chld_bit);
    while (true) {
        var pfd = [2]sys.PollFd{
            .{ .fd = @intCast(l), .events = sys.POLLIN, .revents = 0 },
            .{ .fd = @intCast(sfd), .events = sys.POLLIN, .revents = 0 },
        };
        if (sys.poll(&pfd, 2, -1) < 0) continue;
        if (pfd[1].revents != 0) {
            var info: [128]u8 = undefined;
            _ = sys.read(sfd, &info);
            var st: u32 = 0;
            while (sys.wait4(-1, &st, 1) > 0) {}
        }
        if (pfd[0].revents != 0) {
            const c = sys.acceptHostVsock(l, 0);
            if (c < 0) continue;
            const pid = sys.fork();
            if (pid == 0) {
                sys.close(l);
                session.serve(c);
            }
            sys.close(c);
        }
    }
}

pub const panic = std.debug.FullPanic(struct {
    fn f(msg: []const u8, _: ?usize) noreturn {
        util.log("panic: {s}", .{msg});
        sys.poweroff();
        while (true) sys.sleep_ms(1000);
    }
}.f);
