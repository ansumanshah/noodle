//! Boot sequence (docs/architecture/protocol.md "Guest boot"). Every step logs to /dev/hvc0.
const std = @import("std");
const sys = @import("sys.zig");
const util = @import("util.zig");
const net = @import("net.zig");
const devcg = @import("devcg.zig");

fn step(comptime what: []const u8, rc: isize) bool {
    if (rc < 0 and rc != -sys.E.BUSY) {
        util.log(what ++ ": FAILED errno {d}", .{-rc});
        return false;
    }
    util.log(what ++ ": ok", .{});
    return true;
}

fn mountDir(src: [*:0]const u8, target: [*:0]const u8, fs: [*:0]const u8, flags: usize, data: ?[*:0]const u8) isize {
    _ = sys.mkdirat(sys.AT_FDCWD, target, 0o755);
    return sys.mount(src, target, fs, flags, data);
}

/// Prepare a tmpfs root for subsequent container pivot_root calls.
/// Move the mount into place, carrying docker-init across from the initramfs.
fn switchRoot() void {
    _ = sys.mkdirat(sys.AT_FDCWD, "/newroot", 0o755);
    if (sys.mount("tmpfs", "/newroot", "tmpfs", 0, "mode=755") < 0) return;
    const helper = sys.open("/sbin/docker-init", sys.O.RDONLY, 0);
    if (sys.chdir("/newroot") < 0) {
        if (helper >= 0) sys.close(helper);
        return;
    }
    _ = sys.mkdirat(sys.AT_FDCWD, "sbin", 0o755);
    if (helper >= 0) {
        const dest = sys.open("sbin/docker-init", sys.O.WRONLY | sys.O.CREAT | sys.O.TRUNC, 0o755);
        if (dest >= 0) {
            var buf: [16384]u8 = undefined;
            var ok = true;
            while (true) {
                const n = sys.read(helper, &buf);
                if (n == 0) break;
                if (n < 0 or sys.writeAll(dest, buf[0..@intCast(n)]) < 0) { ok = false; break; }
            }
            sys.close(dest);
            if (!ok) _ = sys.unlinkat(sys.AT_FDCWD, "sbin/docker-init", 0);
        }
        sys.close(helper);
    }
    for ([_][*:0]const u8{ "proc", "sys", "dev", "run", "tmp", "mnt", "etc", "var" }) |d| _ = sys.mkdirat(sys.AT_FDCWD, d, 0o755);
    if (sys.mount(".", "/", null, sys.MS.MOVE, null) < 0) return;
    _ = sys.chroot(".");
    _ = sys.chdir("/");
}

fn enableControllers(path: [*:0]const u8) void {
    for ([_][]const u8{ "+cpu", "+cpuset", "+memory", "+pids", "+io" }) |c| _ = util.writeSys(path, c);
}

pub fn run() bool {
    switchRoot();
    // 1. pseudo filesystems
    _ = mountDir("proc", "/proc", "proc", 0, null);
    _ = mountDir("sysfs", "/sys", "sysfs", 0, null);
    _ = mountDir("devtmpfs", "/dev", "devtmpfs", 0, "mode=755");
    util.openLog();
    if (util.readFile("/proc/cmdline", 4096)) |t| util.workload = std.mem.indexOf(u8, t, "noodle.role=workload") != null;
    util.log("noodle-init {s} starting (pid {d})", .{ util.version, sys.getpid() });
    _ = step("mount /proc", if (util.exists("/proc/self")) 0 else -1);
    _ = step("mount /sys", if (util.exists("/sys/kernel")) 0 else -1);
    _ = step("mount /dev", if (util.exists("/dev/null")) 0 else -1);
    _ = step("mount /dev/pts", mountDir("devpts", "/dev/pts", "devpts", 0, "gid=5,mode=620,ptmxmode=666"));
    _ = mountDir("tmpfs", "/run", "tmpfs", sys.MS.NOSUID | sys.MS.NODEV, "mode=755");
    _ = mountDir("tmpfs", "/tmp", "tmpfs", sys.MS.NOSUID | sys.MS.NODEV, "mode=1777");
    // favordynmods keeps the cgroup threadgroup lock from waiting on an RCU grace period at every
    // container start; without it a cgroup.procs write can take tens of milliseconds.
    var cgroup_rc = mountDir("cgroup2", "/sys/fs/cgroup", "cgroup2", 0, "favordynmods");
    if (cgroup_rc < 0) cgroup_rc = mountDir("cgroup2", "/sys/fs/cgroup", "cgroup2", 0, null);
    _ = step("mount cgroup2", cgroup_rc);
    enableControllers("/sys/fs/cgroup/cgroup.subtree_control");
    _ = sys.mkdirat(sys.AT_FDCWD, "/sys/fs/cgroup/noodle", 0o755);
    enableControllers("/sys/fs/cgroup/noodle/cgroup.subtree_control");
    if (util.workload and !devcg.attach("/sys/fs/cgroup/noodle")) util.log("workload VM without device policy: privileged containers are refused", .{});
    if (util.readFile("/sys/fs/cgroup/noodle/cgroup.controllers", 256)) |t| util.log("cgroup controllers: {s}", .{std.mem.trim(u8, t, " \n")});

    // 2. data disk
    if (!mountData()) return false;
    _ = util.mkdirp(util.base ++ "/layers", 0o755);
    _ = util.mkdirp(util.base ++ "/containers", 0o755);
    _ = util.mkdirp(util.base ++ "/volumes", 0o755);
    util.log("data dir ready at {s}", .{util.base});

    // 3. virtiofs shares
    // The workload VM has a `host` device only when Kubernetes shared folders are on; without one the mount fails.
    _ = util.mkdirp("/mnt/host", 0o755);
    if (!util.workload) {
        util.host_shares = step("mount virtiofs host", sys.mount("host", "/mnt/host", "virtiofs", sys.MS.NOATIME, null));
        _ = util.mkdirp("/mnt/rosetta", 0o755);
        if (sys.mount("rosetta", "/mnt/rosetta", "virtiofs", 0, null) >= 0) {
            util.log("mount virtiofs rosetta: ok", .{});
            registerRosetta();
        } else util.log("rosetta share not present, x86-64 emulation off", .{});
    } else if (sys.mount("host", "/mnt/host", "virtiofs", sys.MS.NOATIME, null) >= 0) {
        util.host_shares = true;
        util.log("workload VM: approved Mac folders shared", .{});
    } else util.log("workload VM: no host shares", .{});

    // 4. network
    _ = sys.sethostname("noodle");
    if (!step("ip_forward", net.setIpForward())) return false;
    net.dhcpBegin();
    util.log("boot sequence done", .{});
    return true;
}

fn mountData() bool {
    // the block device can show up a moment after init starts
    var tries: usize = 0;
    while (!util.exists("/dev/vda") and tries < 100) : (tries += 1) sys.sleep_ms(20);
    _ = util.mkdirp(util.base, 0o755);
    if (util.exists("/dev/vda")) {
        const rc = sys.mount("/dev/vda", util.base, "ext4", sys.MS.NOATIME, null);
        if (rc >= 0) {
            util.log("mount /dev/vda -> {s}: ok", .{util.base});
            return true;
        }
        util.log("mount /dev/vda: FAILED errno {d}; data disk must be repaired before starting", .{-rc});
    } else util.log("no /dev/vda; data disk is required", .{});
    return false;
}

fn registerRosetta() void {
    _ = mountDir("binfmt_misc", "/proc/sys/fs/binfmt_misc", "binfmt_misc", 0, null);
    const reg = ":rosetta:M::\\x7fELF\\x02\\x01\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x02\\x00\\x3e\\x00:\\xff\\xff\\xff\\xff\\xff\\xfe\\xfe\\x00\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xfe\\xff\\xff\\xff:/mnt/rosetta/rosetta:CF";
    const rc = util.writeSys("/proc/sys/fs/binfmt_misc/register", reg);
    if (rc < 0 and rc != -sys.E.EXIST) util.log("binfmt rosetta register: FAILED errno {d}", .{-rc}) else util.log("binfmt rosetta: ok", .{});
}

pub fn shutdown() noreturn {
    util.log("shutting down", .{});
    sys.sync();
    _ = sys.umount2(util.base, 2);
    sys.sync();
    sys.poweroff();
    while (true) sys.sleep_ms(1000);
}
