//! One transient, digest-pinned BuildKit worker. Its PID namespace dies with the build client.
const std = @import("std");
const sys = @import("sys.zig");
const util = @import("util.zig");
const cache = @import("build_cache.zig");
const layers = @import("layers.zig");
const tarfs = @import("tarfs.zig");
const bpf = @import("bpf.zig");
const net = @import("net.zig");
const devcg = @import("devcg.zig");
const wire = @import("stream.zig");
const Value = @import("json").Value;
const test_hooks = @import("build_options").test_hooks;

const base = util.base ++ "/buildkit";
const work = base ++ "/work";
const root = work ++ "/root";
const context = work ++ "/context";
// Base images the Mac resolved, as an OCI layout. Never inside the context, so COPY . cannot see it.
const bases = work ++ "/bases";
const output = work ++ "/out/image.tar";
// Every process of a worker lives in this cgroup. The flock drops when the namespace init
// closes its files, which Linux does before it kills and waits for the rest of the PID
// namespace, so the lock alone does not prove the old tree has stopped writing.
const worker_cgroup = "/sys/fs/cgroup/noodle/buildkit-worker";
const Error = error{ CacheRecovery, InvalidRequest, Workspace, BadContext, Namespace, Mount, Pipe, Fork, Poll, Disconnected, Worker, Archive, Isolation, Exec };

pub fn serve(conn: isize, req: Value) i32 {
    // A disconnected log reader must yield EPIPE so the supervisor can kill and reap the worker.
    if (sys.sigprocmask(0, 1 << (@backingInt(std.os.linux.SIG.PIPE) - 1)) < 0) return 1;
    const size = req.intOr("size", 0);
    if (size < 512 or size > (1 << 30) or req.list("options").len > 128 or req.list("layers").len == 0) {
        wire.ackErr(conn, "invalid build request", sys.E.INVAL);
        return 1;
    }
    const base_size = req.intOr("base_size", 0);
    if (base_size < 0 or base_size > (4 << 30)) {
        wire.ackErr(conn, "invalid build request", sys.E.INVAL);
        return 1;
    }
    if (!wire.ackOk(conn)) return 1;
    const result = build(conn, req, @intCast(size), @intCast(base_size));
    if (result) |_| {
        wire.sendExit(conn, 0);
        return 0;
    } else |err| {
        _ = wire.sendMux(conn, 2, util.sf("build failed: {s}\n", .{@errorName(err)}));
        wire.sendExit(conn, 1);
        return 1;
    }
}

fn waitWorker(pid: isize, status: *u32) isize {
    while (true) {
        const result = sys.wait4(pid, status, 0);
        if (result != -sys.E.INTR) return result;
    }
}

pub fn native(conn: isize, req: Value) i32 {
    if (sys.sigprocmask(0, 1 << (@backingInt(std.os.linux.SIG.PIPE) - 1)) < 0) return 1;
    build(conn, req, null, 0) catch |err| {
        wire.ackErr(conn, @errorName(err), sys.E.INVAL);
        return 1;
    };
    return 0;
}

fn build(conn: isize, req: Value, size: ?u64, base_size: u64) Error!void {
    if (util.mkdirp(base, 0o700) < 0) return error.Workspace;
    const parent = sys.open(base, sys.O.DIRECTORY | sys.O.NOFOLLOW | sys.O.RDONLY, 0);
    if (parent < 0) return error.Workspace;
    defer sys.close(parent);
    // The worker inherits only a regular lock file, never an outside-chroot directory.
    const lock = sys.openat(parent, "worker.lock", sys.O.RDWR | sys.O.NOFOLLOW | sys.O.CREAT, 0o600);
    if (lock < 0) return error.Workspace;
    defer sys.close(lock);
    // A cancelled HTTP client can retry before its previous PID namespace has finished tearing down.
    if (sys.sc(.flock, @intCast(lock), 2, 0, 0, 0, 0) < 0) return error.Workspace;

    try drainWorkerCgroup();
    util.rmTreePath(work);
    if (sys.mkdirat(sys.AT_FDCWD, work, 0o700) < 0) return error.Workspace;
    defer util.rmTreePath(work);
    for ([_][*:0]const u8{ context, bases, root, work ++ "/upper", work ++ "/overlay-work", work ++ "/out" }) |path| {
        if (util.mkdirp(std.mem.span(path), 0o700) < 0) return error.Workspace;
    }

    if (size) |count| {
        const dir = sys.open(context, sys.O.DIRECTORY | sys.O.RDONLY, 0);
        if (dir < 0) return error.Workspace;
        defer sys.close(dir);
        var buffer: [64 * 1024]u8 = undefined;
        var input = layers.FdIn.init(conn, &buffer, count);
        var source = layers.HashSrc{ .inner = &input.reader };
        tarfs.extractAll(&source, dir, false) catch return error.BadContext;
        if (source.failed or source.total != count) return error.BadContext;
        if (base_size > 0) {
            const layout = sys.open(bases, sys.O.DIRECTORY | sys.O.RDONLY, 0);
            if (layout < 0) return error.Workspace;
            defer sys.close(layout);
            var layout_input = layers.FdIn.init(conn, &buffer, base_size);
            var layout_source = layers.HashSrc{ .inner = &layout_input.reader };
            tarfs.extractAll(&layout_source, layout, false) catch return error.BadContext;
            if (layout_source.failed or layout_source.total != base_size) return error.BadContext;
        }
    }

    const notify = try notifySocket();
    defer sys.close(notify);
    try cache.begin(parent);

    // getppid() is zero across a PID namespace boundary. A pipe proves that
    // the supervisor still existed when the child armed its death signal.
    var life: [2]i32 = undefined;
    if (sys.pipe2(&life, sys.O.CLOEXEC) < 0) return error.Pipe;
    defer sys.close(life[0]);
    defer sys.close(life[1]);
    var log: [2]i32 = undefined;
    if (sys.pipe2(&log, sys.O.CLOEXEC) < 0) return error.Pipe;
    defer sys.close(log[0]);
    const pid = sys.sc(.clone, sys.CLONE.NEWPID | sys.CLONE.NEWNS | sys.CLONE.NEWIPC | sys.CLONE.NEWUTS | sys.SIG.CHLD, 0, 0, 0, 0, 0);
    if (pid == 0) {
        sys.close(life[1]);
        if (sys.prctl(sys.PR_SET_PDEATHSIG, sys.SIG.KILL, 0, 0, 0) < 0) sys.exit(125);
        // "0" moves the writer itself; every later descendant inherits the group.
        if (util.writeSys(worker_cgroup ++ "/cgroup.procs", "0") < 0) sys.exit(125);
        var alive = [_]sys.PollFd{.{ .fd = life[0], .events = sys.POLLIN, .revents = 0 }};
        if (sys.poll(&alive, 1, 0) != 0) sys.exit(125);
        if (sys.sigprocmask(2, 0) < 0) sys.exit(125);
        if (sys.dup3(log[1], 2, 0) < 0 or sys.dup3(log[1], 1, 0) < 0) sys.exit(125);
        // Keep the flock's open file description through worker exit even when
        // the supervisor is killed. Do not pass any agent sockets to the worker.
        if (lock != 3 and sys.dup3(lock, 3, 0) < 0) sys.exit(125);
        if (sys.sc(.close_range, 4, 0xffffffff, 0, 0, 0, 0) < 0) sys.exit(125);
        launch(req, size == null) catch |err| {
            _ = sys.writeAll(2, util.sf("BuildKit setup: {s}\n", .{@errorName(err)}));
        };
        sys.exit(125);
    }
    sys.close(log[1]);
    if (pid < 0) return error.Fork;
    var status: u32 = 0;
    var reaped = false;
    defer if (!reaped) {
        _ = sys.kill(pid, sys.SIG.KILL);
        _ = waitWorker(pid, &status);
    };
    if (size == null) {
        // The Unix socket lives in the private output bind, visible to this supervisor.
        const path = work ++ "/out/control.sock";
        const Address = extern struct { family: u16 = sys.AF_UNIX, path: [108]u8 = @splat(0) };
        var address = Address{};
        @memcpy(address.path[0..path.len], path);
        for (0..1500) |_| {
            const fd = sys.socket(sys.AF_UNIX, sys.SOCK_STREAM, 0);
            if (fd < 0) return error.Pipe;
            if (sys.connect(fd, &address, 2 + path.len + 1) >= 0) {
                defer sys.close(fd);
                if (!wire.ackOk(conn)) return;
                var activate: [1]u8 = undefined;
                if (sys.read(conn, &activate) == 1 and activate[0] == 1 and wire.relaySockets(conn, fd, true) == 0) {
                    _ = sys.shutdown(fd, 2);
                    if (stopNative(pid, notify, &reaped)) try cache.commit(parent);
                }
                return;
            }
            sys.close(fd);
            if (sys.wait4(pid, &status, 1) == pid) {
                reaped = true;
                return error.Worker;
            }
            sys.sleep_ms(10);
        }
        return error.Worker;
    }
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        var fds = [_]sys.PollFd{
            .{ .fd = log[0], .events = sys.POLLIN, .revents = 0 },
            .{ .fd = @intCast(conn), .events = sys.POLLIN, .revents = 0 },
        };
        const n = sys.poll(&fds, 2, -1);
        if (n == -sys.E.INTR) continue;
        if (n < 0) return error.Poll;
        if (fds[1].revents != 0) return error.Disconnected;
        if (fds[0].revents != 0) {
            const len = sys.read(log[0], &buffer);
            if (len < 0) return error.Pipe;
            if (len == 0) break;
            // Test builds only: die like an OOM-killed supervisor while the worker is mid-RUN.
            if (test_hooks and std.mem.indexOf(u8, buffer[0..@intCast(len)], "NOODLE_TEST_KILL_SUPERVISOR") != null) {
                straggler(lock);
                _ = sys.kill(sys.getpid(), sys.SIG.KILL);
            }
            if (!wire.sendMux(conn, 2, buffer[0..@intCast(len)])) return error.Disconnected;
        }
    }
    if (waitWorker(pid, &status) != pid) return error.Worker;
    reaped = true;
    if (status != 0 or !didNotifyStopping(notify)) return error.Worker;
    try cache.commit(parent);

    const archive = sys.open(output, sys.O.RDONLY | sys.O.NOFOLLOW, 0);
    if (archive < 0) return error.Archive;
    defer sys.close(archive);
    while (true) {
        const n = sys.read(archive, &buffer);
        if (n < 0) return error.Archive;
        if (n == 0) break;
        if (!wire.sendMux(conn, 1, buffer[0..@intCast(n)])) return error.Disconnected;
    }
}

/// Kills whatever a previous worker left in its cgroup and waits until the group is empty, so
/// cleanup never races a descendant that is still unwinding after its supervisor died.
pub fn drainWorkerCgroup() Error!void {
    const made = sys.mkdirat(sys.AT_FDCWD, worker_cgroup, 0o755);
    if (made < 0 and made != -sys.E.EXIST) return error.Workspace;
    // The worker binds the whole VM /dev, so the device policy (the data disk stays unreachable) rides on its cgroup in
    // every VM. Once per new cgroup: the programs stack, and the cgroup outlives builds.
    if (made >= 0) {
        const was_active = devcg.active; // `active` gates privileged containers, which a worker-only policy must not enable
        defer devcg.active = was_active;
        if (!devcg.attach(worker_cgroup)) {
            _ = sys.unlinkat(sys.AT_FDCWD, worker_cgroup, sys.AT_REMOVEDIR); // else the next build sees EXIST and runs with no policy
            return error.Workspace;
        }
    }
    const kill_rc = util.writeSys(worker_cgroup ++ "/cgroup.kill", "1");
    if (kill_rc < 0) return error.Workspace;
    const fd = sys.open(worker_cgroup ++ "/cgroup.events", sys.O.RDONLY, 0);
    if (fd < 0) return error.Workspace;
    defer sys.close(fd);
    const deadline = sys.boottime_ns() + 10_000_000_000;
    while (true) {
        var buf: [256]u8 = undefined;
        if (sys.lseek(fd, 0, 0) < 0) return error.Workspace;
        const n = sys.read(fd, &buf);
        if (n <= 0) return error.Workspace;
        const populated = util.flatKey(buf[0..@intCast(n)], "populated") orelse return error.Workspace;
        if (populated == 0) return;
        const now = sys.boottime_ns();
        if (now >= deadline) return error.Workspace;
        var pfd = sys.PollFd{ .fd = @intCast(fd), .events = 2, .revents = 0 }; // POLLPRI: cgroup.events changed
        const rc = sys.poll(@ptrCast(&pfd), 1, @intCast((deadline - now + 999_999) / 1_000_000));
        if (rc < 0 and rc != -sys.E.INTR) return error.Workspace;
    }
}

// Test builds only. Stands in for a worker descendant that is slow to die: a worker-cgroup
// member that keeps writing into the build tree for three seconds after the supervisor and
// the lock holder are gone. Cleanup that only waits for the lock races it.
fn straggler(lock: isize) void {
    if (!test_hooks) return;
    const pid = sys.fork();
    if (pid != 0) {
        if (pid > 0) _ = util.writeSys(worker_cgroup ++ "/cgroup.procs", util.sf("{d}", .{pid}));
        return;
    }
    _ = lock;
    // Hold the cache directory open the way a worker descendant would, then keep creating
    // entries through that handle even after cleanup renames the tree away.
    _ = sys.sc(.close_range, 3, 0xffffffff, 0, 0, 0, 0);
    const dir = sys.open(base ++ "/cache", sys.O.DIRECTORY | sys.O.RDONLY, 0);
    if (dir < 0) sys.exit(1);
    for (0..3000) |n| {
        const fd = sys.openat(dir, util.zf("straggler.{d}", .{n}).ptr, sys.O.WRONLY | sys.O.CREAT, 0o600);
        if (fd >= 0) sys.close(fd);
        sys.sleep_ms(1);
    }
    sys.exit(0);
}

fn notifySocket() Error!isize {
    const fd = sys.socket(sys.AF_UNIX, sys.SOCK_DGRAM | sys.SOCK_NONBLOCK | sys.SOCK_CLOEXEC, 0);
    if (fd < 0) return error.Pipe;
    errdefer sys.close(fd);
    const Address = extern struct { family: u16 = sys.AF_UNIX, path: [108]u8 = @splat(0) };
    var addr = Address{};
    const path = work ++ "/out/notify.sock";
    @memcpy(addr.path[0..path.len], path);
    if (sys.bind(fd, &addr, 2 + path.len + 1) < 0) return error.Pipe;
    return fd;
}

// Upstream BuildKit sends STOPPING=1 before GracefulStop/Close and exits 1
// for SIGTERM's canceled context. A signal death, timeout or exit without the
// lifecycle notification leaves the cache dirty.
fn stopNative(pid: isize, notify: isize, reaped: *bool) bool {
    if (sys.kill(pid, sys.SIG.TERM) < 0) return false;
    var status: u32 = 0;
    for (0..250) |_| {
        const done = sys.wait4(pid, &status, 1);
        if (done == pid) {
            reaped.* = true;
            if (status != 0 and status != 256) return false;
            return didNotifyStopping(notify);
        }
        if (done < 0 and done != -sys.E.INTR) return false;
        sys.sleep_ms(20);
    }
    return false;
}

fn didNotifyStopping(notify: isize) bool {
    var buf: [128]u8 = undefined;
    while (true) {
        const n = sys.read(notify, &buf);
        if (n == -sys.E.INTR) continue;
        if (n <= 0) return false;
        if (std.mem.eql(u8, buf[0..@intCast(n)], "STOPPING=1")) return true;
    }
}

// The upstream daemonless script masks buildkitd's wait status. Keep the CLI
// and the actual worker status separate. A SIGKILL/OOM must never bless a cache.
const classicScript =
    \\addr=unix:///noodle/output/control.sock
    \\buildkitd --config=/noodle/output/buildkitd.toml --addr="$addr" --containerd-worker=false --oci-worker=true --oci-worker-snapshotter=overlayfs --oci-worker-net=bridge >/dev/null 2>&1 &
    \\pid=$!
    \\n=0
    \\until buildctl --addr "$addr" debug workers >/dev/null 2>&1; do
    \\  kill -0 "$pid" && [ "$n" -lt 150 ] || exit 125
    \\  n=$((n+1)); sleep 0.1
    \\done
    \\buildctl --addr "$addr" "$@"; result=$?
    \\kill -TERM "$pid" || exit 125
    \\wait "$pid"; stopped=$?
    \\[ "$stopped" -le 1 ] || exit 125
    \\exit "$result"
;

// A tmpfs /dev with only the nodes runc and RUN steps need, never the VM's disks, console or vsock.
fn minimalDev() Error!void {
    const dev = root ++ "/dev";
    if (sys.mount("tmpfs", dev, "tmpfs", sys.MS.NOSUID, "mode=755,size=65536k") < 0) return error.Mount;
    for ([_][:0]const u8{ "null", "zero", "full", "random", "urandom", "tty", "fuse", "net/tun" }) |n| {
        const src = util.zf("/dev/{s}", .{n});
        if (!util.exists(src.ptr)) continue;
        const dst = util.zf(dev ++ "/{s}", .{n});
        if (std.mem.indexOfScalar(u8, n, '/') != null and util.mkdirp(util.sf(dev ++ "/{s}", .{std.fs.path.dirname(n).?}), 0o755) < 0) return error.Mount;
        if (util.writeFile(dst.ptr, "", 0o644) < 0 or sys.mount(src.ptr, dst.ptr, null, sys.MS.BIND, null) < 0) return error.Mount;
    }
    if (util.mkdirp(dev ++ "/pts", 0o755) < 0 or util.mkdirp(dev ++ "/shm", 0o1777) < 0) return error.Mount;
    if (sys.mount("devpts", dev ++ "/pts", "devpts", sys.MS.NOSUID | sys.MS.NOEXEC, "newinstance,ptmxmode=0666,mode=0620,gid=5") < 0) return error.Mount;
    if (sys.mount("shm", dev ++ "/shm", "tmpfs", sys.MS.NOSUID | sys.MS.NODEV | sys.MS.NOEXEC, "mode=1777,size=67108864") < 0) return error.Mount;
    for ([_][2][*:0]const u8{ .{ "pts/ptmx", "ptmx" }, .{ "/proc/self/fd", "fd" }, .{ "/proc/self/fd/0", "stdin" }, .{ "/proc/self/fd/1", "stdout" }, .{ "/proc/self/fd/2", "stderr" } }) |l| {
        if (sys.symlinkat(l[0], sys.AT_FDCWD, util.zf(dev ++ "/{s}", .{std.mem.span(l[1])}).ptr) < 0) return error.Mount;
    }
}

fn launch(req: Value, is_native: bool) Error!void {
    if (sys.mount(null, "/", null, sys.MS.REC | sys.MS.PRIVATE, null) < 0) return error.Namespace;
    var dirs: std.Io.Writer.Allocating = .init(util.arena());
    for (req.list("layers"), 0..) |layer, index| {
        if (layer != .str or !layers.validDigest(layer.str) or !layers.has(layer.str[7..])) return error.InvalidRequest;
        if (index > 0) dirs.writer.writeByte(':') catch return error.Workspace;
        dirs.writer.writeAll(layers.layerPath(util.hexOf(layer.str))) catch return error.Workspace;
    }
    const overlay = util.zf("lowerdir={s},upperdir=" ++ work ++ "/upper,workdir=" ++ work ++ "/overlay-work", .{dirs.written()});
    if (sys.mount("overlay", root, "overlay", 0, overlay.ptr) < 0) return error.Mount;
    for ([_][]const u8{ "/proc", "/sys", "/dev", "/run", "/tmp", "/var/lib/buildkit", "/noodle/context", "/noodle/bases", "/noodle/output" }) |dir| {
        if (util.mkdirp(util.sf(root ++ "{s}", .{dir}), 0o755) < 0) return error.Mount;
    }
    if (util.mkdirp(work ++ "/out", 0o700) < 0) return error.Workspace;
    for ([_][2][*:0]const u8{
        .{ "/sys", root ++ "/sys" },                        .{ base ++ "/cache", root ++ "/var/lib/buildkit" },
        .{ context, root ++ "/noodle/context" },            .{ bases, root ++ "/noodle/bases" },
        .{ work ++ "/out", root ++ "/noodle/output" },
    }) |pair| {
        if (sys.mount(pair[0], pair[1], null, sys.MS.REC | sys.MS.BIND, null) < 0) return error.Mount;
    }
    if (sys.mount("proc", root ++ "/proc", "proc", 0, null) < 0) return error.Mount;
    try minimalDev();
    // The VM's DHCP resolver bypasses the agent's Mac resolver fallback. BuildKit
    // gives RUN its own bridge, but its queries must still go through our resolver.
    const network = net.findNet("bridge") orelse return error.InvalidRequest;
    if (!network.has4 or network.dns_fd < 0) return error.InvalidRequest;
    const dns = util.sf("nameserver {d}.{d}.{d}.{d}\n", .{ network.gw[0], network.gw[1], network.gw[2], network.gw[3] });
    if (util.writeFile(root ++ "/etc/resolv.conf", dns, 0o644) < 0) return error.Mount;
    // The agent only accepts default-bridge DNS from its containers or this worker bridge.
    if (util.writeFile(root ++ "/noodle/output/buildkitd.toml", "[worker.oci]\nbridgeName = \"" ++ net.builder_bridge ++ "\"\n", 0o600) < 0) return error.Mount;
    if (sys.chdir(root) < 0 or sys.chroot(".") < 0 or sys.chdir("/") < 0) return error.Mount;
    const devnull = sys.open("/dev/null", sys.O.RDONLY, 0);
    if (devnull < 0 or (devnull != 0 and sys.dup3(devnull, 0, 0) < 0)) return error.Isolation;
    if (devnull != 0) sys.close(devnull);

    // runc and every Dockerfile RUN inherit the guest control-channel socket filter.
    var filter: [bpf.max_insns]bpf.Insn = undefined;
    const len = bpf.build(&filter, 0, true);
    if (sys.seccomp_filter(&.{ .len = @intCast(len), .filter = @ptrCast(&filter) }) < 0) return error.Isolation;

    if (is_native) {
        const path = "/usr/bin/buildkitd";
        const argv = [_:null]?[*:0]const u8{ path, "--config=/noodle/output/buildkitd.toml", "--addr=unix:///noodle/output/control.sock", "--containerd-worker=false", "--oci-worker=true", "--oci-worker-snapshotter=overlayfs", "--oci-worker-net=bridge", gatewayLabel() };
        const env = [_:null]?[*:0]const u8{ "NOTIFY_SOCKET=/noodle/output/notify.sock", "HOME=/root", "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" };
        const nullfd = sys.open("/dev/null", sys.O.WRONLY, 0);
        if (nullfd < 0 or sys.dup3(nullfd, 1, 0) < 0 or sys.dup3(nullfd, 2, 0) < 0) return error.Isolation;
        sys.close(nullfd);
        _ = sys.execve(path, &argv, &env);
        return error.Exec;
    }
    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    const a = util.arena();
    argv.appendSlice(a, &.{ "/bin/sh", "-c", classicScript, "noodle-build", "build", "--progress=plain", "--frontend=dockerfile.v0", "--local", "context=/noodle/context", "--local", "dockerfile=/noodle/context", "--oci-layout", "noodle=/noodle/bases", "--output", "type=docker,dest=/noodle/output/image.tar", "--opt", util.zf("filename={s}", .{req.strOr("dockerfile", "Dockerfile")}).ptr }) catch return error.Workspace;
    for (req.list("options")) |opt| {
        if (opt != .str or std.mem.indexOfScalar(u8, opt.str, 0) != null) return error.InvalidRequest;
        argv.appendSlice(a, &.{ "--opt", util.zdup(opt.str).ptr }) catch return error.Workspace;
    }
    argv.append(a, null) catch return error.Workspace;
    const env = [_:null]?[*:0]const u8{ "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "HOME=/root", "NOTIFY_SOCKET=/noodle/output/notify.sock" };
    _ = sys.execve("/bin/sh", @ptrCast(argv.items.ptr), &env);
    return error.Exec;
}

fn gatewayLabel() ?[*:0]const u8 {
    const routes = util.readFile("/proc/net/route", 64 * 1024) orelse return null;
    var lines = std.mem.tokenizeScalar(u8, routes, '\n');
    while (lines.next()) |line| {
        var cols = std.mem.tokenizeAny(u8, line, " \t");
        _ = cols.next() orelse continue;
        if (!std.mem.eql(u8, cols.next() orelse continue, "00000000")) continue;
        const gw = std.fmt.parseInt(u32, cols.next() orelse continue, 16) catch continue;
        if (gw != 0) return util.zf("--oci-worker-labels=org.mobyproject.buildkit.worker.moby.host-gateway-ip={d}.{d}.{d}.{d}", .{ gw & 255, (gw >> 8) & 255, (gw >> 16) & 255, gw >> 24 }).ptr;
    }
    return null;
}
