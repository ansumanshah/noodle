//! Optional machine-only systemd handoff. No work in the container VM or minimal-init machines.
const sys = @import("sys.zig");
const util = @import("util.zig");

const agent = "/usr/local/libexec/noodle-machine-agent";
const unit =
    "[Unit]\n" ++
    "Description=Noodle machine shell sessions\n" ++
    "DefaultDependencies=no\n" ++
    // A session runs as the Mac user, and an unprivileged systemctl needs the D-Bus socket. Starting
    // before it listens makes the first shell of a boot fail with "Failed to connect to bus".
    // An After= on a unit the image does not have is ignored.
    "After=systemd-remount-fs.service dbus.socket\n" ++
    "Before=basic.target shutdown.target\n" ++
    "Conflicts=shutdown.target\n" ++
    "[Service]\n" ++
    "Type=simple\n" ++
    "ExecStart=" ++ agent ++ "\n" ++
    "Restart=on-failure\n" ++
    "TimeoutStopSec=5s\n" ++
    "[Install]\nWantedBy=basic.target\n";

pub fn boot() !void {
    if (sys.access("/sbin/init", 1) < 0 or sys.access("/usr/bin/systemctl", 1) < 0) return error.MissingSystemd;
    // Copy the running initramfs executable before handing PID 1 to the distro.
    // Stream it so this does not retain a second binary-sized arena allocation.
    if (util.mkdirp("/usr/local/libexec", 0o755) < 0) return error.InstallAgent;
    const src = sys.open("/proc/self/exe", sys.O.RDONLY | sys.O.CLOEXEC, 0);
    if (src < 0) return error.InstallAgent;
    defer sys.close(src);
    const dst = sys.open(agent ++ ".new", sys.O.WRONLY | sys.O.CREAT | sys.O.TRUNC | sys.O.CLOEXEC, 0o755);
    if (dst < 0) return error.InstallAgent;
    defer sys.close(dst);
    var buf: [16384]u8 = undefined;
    while (true) {
        const n = sys.read(src, &buf);
        if (n == -sys.E.INTR) continue;
        if (n < 0) return error.InstallAgent;
        if (n == 0) break;
        if (sys.writeAll(dst, buf[0..@intCast(n)]) < 0) return error.InstallAgent;
    }
    if (sys.chmodPath(agent ++ ".new", 0o755) < 0 or
        sys.renameat(sys.AT_FDCWD, agent ++ ".new", sys.AT_FDCWD, agent) < 0) return error.InstallAgent;
    if (util.mkdirp("/etc/systemd/system/basic.target.wants", 0o755) < 0 or
        util.writeFile("/etc/systemd/system/noodle-machine-agent.service", unit, 0o644) < 0) return error.InstallUnit;
    const link = "/etc/systemd/system/basic.target.wants/noodle-machine-agent.service";
    _ = sys.unlinkat(sys.AT_FDCWD, link, 0);
    if (sys.symlinkat("../noodle-machine-agent.service", sys.AT_FDCWD, link) < 0 or
        util.writeFile("/run/noodle-systemd", "1\n", 0o644) < 0) return error.InstallUnit;
    // console=hvc0 makes systemd generate this getty, and it waits for dev-hvc0.device. Images without
    // udev never announce that device, so boot sits 90 s on the job timeout. The console is output
    // only, so nothing logs in there. An existing file at this path wins: symlinkat fails and is ignored.
    _ = sys.symlinkat("/dev/null", sys.AT_FDCWD, "/etc/systemd/system/serial-getty@hvc0.service");

    const argv = [_:null]?[*:0]const u8{ "/sbin/init", null };
    const env = [_:null]?[*:0]const u8{ "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "LANG=C.UTF-8", null };
    _ = sys.execve("/sbin/init", &argv, &env);
    return error.ExecInit;
}

/// SIGRTMIN+4 requests the normal poweroff.target transaction, including ExecStop
/// and filesystem unmounts. Ubuntu, Debian and Fedora use glibc's SIGRTMIN=34.
/// Do not use SIGTERM (manager reexec) or the kernel reboot syscall here.
pub fn requestPoweroff() isize {
    return sys.kill(1, 38);
}
