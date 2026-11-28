//! Machine agent session: one vsock connection, one process (optionally on a pty). Wire format: frames of `type u8, len u32 BE, payload`.
//!   host -> guest: 1 request, 2 stdin, 5 stdin EOF, 6 window size (rows u16, cols u16), 7 signal (u8)
//!   guest -> host: 3 stdout (the tty stream when a pty is used), 4 stderr, 8 exit status (i32 BE)
//! Request payload: NUL-terminated items, first byte is the tag: T1 tty, R rows, C cols, D cwd, U user,
//! E KEY=VAL, A argument, P power off (root only, no process is started).
const std = @import("std");
const sys = @import("sys.zig");
const util = @import("util.zig");
const systemd = @import("machine_systemd.zig");

const F_REQ = 1;
const F_IN = 2;
const F_OUT = 3;
const F_ERR = 4;
const F_EOF = 5;
const F_WINCH = 6;
const F_SIG = 7;
const F_EXIT = 8;
const max_payload = 60000;
const default_path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";

const Passwd = struct { uid: u32 = 0, gid: u32 = 0, home: []const u8 = "/root", shell: []const u8 = "/bin/sh" };

fn sendFrame(fd: isize, kind: u8, payload: []const u8) bool {
    var head: [5]u8 = undefined;
    head[0] = kind;
    std.mem.writeInt(u32, head[1..5], @intCast(payload.len), .big);
    if (sys.writeAll(fd, &head) < 0) return false;
    return payload.len == 0 or sys.writeAll(fd, payload) >= 0;
}

fn lookupUser(name: []const u8) ?Passwd {
    const text = util.readFile("/etc/passwd", 1 << 20) orelse return null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var f = std.mem.splitScalar(u8, line, ':');
        const n = f.next() orelse continue;
        if (!std.mem.eql(u8, n, name)) continue;
        _ = f.next();
        const uid = f.next() orelse continue;
        const gid = f.next() orelse continue;
        _ = f.next();
        const home = f.next() orelse continue;
        const shell = f.next() orelse "/bin/sh";
        return .{ .uid = std.fmt.parseInt(u32, uid, 10) catch continue, .gid = std.fmt.parseInt(u32, gid, 10) catch continue, .home = home, .shell = if (shell.len == 0) "/bin/sh" else shell };
    }
    return null;
}

fn findExecutable(cmd: []const u8, path: []const u8) ?[:0]const u8 {
    if (std.mem.indexOfScalar(u8, cmd, '/') != null) return util.zdup(cmd);
    var dirs = std.mem.splitScalar(u8, path, ':');
    while (dirs.next()) |d| {
        const cand = util.zf("{s}/{s}", .{ d, cmd });
        if (sys.access(cand.ptr, 1) >= 0) return cand;
    }
    return null;
}

const Request = struct {
    tty: bool = false,
    rows: u16 = 24,
    cols: u16 = 80,
    cwd: ?[]const u8 = null,
    user: []const u8 = "root",
    poweroff: bool = false,
    env: [64][]const u8 = undefined,
    nenv: usize = 0,
    args: [128][]const u8 = undefined,
    nargs: usize = 0,
};

fn parseRequest(payload: []const u8, r: *Request) void {
    var items = std.mem.splitScalar(u8, payload, 0);
    while (items.next()) |it| {
        if (it.len == 0) continue;
        const v = it[1..];
        switch (it[0]) {
            'T' => r.tty = v.len > 0 and v[0] == '1',
            'R' => r.rows = std.fmt.parseInt(u16, v, 10) catch 24,
            'C' => r.cols = std.fmt.parseInt(u16, v, 10) catch 80,
            'D' => r.cwd = v,
            'U' => r.user = v,
            'P' => r.poweroff = true,
            'E' => if (r.nenv < r.env.len) {
                r.env[r.nenv] = v;
                r.nenv += 1;
            },
            'A' => if (r.nargs < r.args.len) {
                r.args[r.nargs] = v;
                r.nargs += 1;
            },
            else => {},
        }
    }
}

fn powerOff() noreturn {
    sys.sync();
    _ = sys.kill(-1, sys.SIG.TERM);
    sys.sleep_ms(600);
    _ = sys.kill(-1, sys.SIG.KILL);
    sys.sync();
    _ = sys.mount(null, "/", null, sys.MS.REMOUNT | sys.MS.RDONLY, null);
    sys.poweroff();
    while (true) sys.sleep_ms(1000);
}

fn envHas(r: *const Request, key: []const u8) bool {
    for (r.env[0..r.nenv]) |e| if (std.mem.startsWith(u8, e, key) and e.len > key.len and e[key.len] == '=') return true;
    return false;
}

/// Runs in the forked child: become the user and exec. Never returns.
fn execChild(r: *const Request, pw: Passwd) noreturn {
    _ = sys.sigprocmask(2, 0); // SIG_SETMASK: the connection process blocks SIGCHLD
    const envp = util.arena().alloc(?[*:0]const u8, r.nenv + 8) catch sys.exit(127);
    var n: usize = 0;
    for (r.env[0..r.nenv]) |e| {
        envp[n] = util.zdup(e).ptr;
        n += 1;
    }
    const defaults = [_][]const u8{ util.sf("HOME={s}", .{pw.home}), util.sf("USER={s}", .{r.user}), util.sf("LOGNAME={s}", .{r.user}), util.sf("SHELL={s}", .{pw.shell}) };
    for (defaults) |d| {
        envp[n] = util.zdup(d).ptr;
        n += 1;
    }
    if (!envHas(r, "PATH")) {
        envp[n] = "PATH=" ++ default_path;
        n += 1;
    }
    if (!envHas(r, "TERM")) {
        envp[n] = "TERM=xterm-256color";
        n += 1;
    }
    envp[n] = null;
    var path: []const u8 = default_path;
    for (r.env[0..r.nenv]) |e| if (std.mem.startsWith(u8, e, "PATH=")) {
        path = e[5..];
    };

    const argv = util.arena().alloc(?[*:0]const u8, r.nargs + 2) catch sys.exit(127);
    var exe: [:0]const u8 = undefined;
    if (r.nargs == 0) {
        exe = util.zdup(pw.shell);
        const base = std.fs.path.basename(pw.shell);
        argv[0] = util.zf("-{s}", .{base}).ptr;
        argv[1] = null;
    } else {
        exe = findExecutable(r.args[0], path) orelse {
            const msg = util.sf("noodle: {s}: command not found\n", .{r.args[0]});
            _ = sys.write(2, msg);
            sys.exit(127);
        };
        for (r.args[0..r.nargs], 0..) |a, i| argv[i] = util.zdup(a).ptr;
        argv[r.nargs] = null;
    }
    if (pw.uid != 0 or pw.gid != 0) {
        _ = sys.setgroups(&[_]u32{pw.gid});
        if (sys.setgid(pw.gid) < 0 or sys.setuid(pw.uid) < 0) sys.exit(126);
    }
    const dirs = [_][:0]const u8{ if (r.cwd) |c| util.zdup(c) else util.zdup(pw.home), util.zdup(pw.home), "/" };
    for (dirs) |d| if (sys.chdir(d.ptr) >= 0) break;
    _ = sys.execve(exe.ptr, @ptrCast(argv.ptr), @ptrCast(envp.ptr));
    const msg = util.sf("noodle: cannot execute {s}\n", .{exe});
    _ = sys.write(2, msg);
    sys.exit(126);
}

const Session = struct {
    conn: isize,
    master: isize = -1, // pty master, or -1
    stdin_fd: isize = -1,
    out_fd: isize = -1,
    err_fd: isize = -1,
    pid: isize = 0,
    pend: [262144]u8 = undefined,
    plen: usize = 0,
    want_eof: bool = false,
    rx: [70000]u8 = undefined,
    rlen: usize = 0,

    fn closeStdin(s: *Session) void {
        if (s.stdin_fd >= 0 and s.stdin_fd != s.master) sys.close(s.stdin_fd);
        if (s.stdin_fd != s.master) s.stdin_fd = -1;
    }

    fn flushInput(s: *Session) void {
        while (s.plen > 0 and s.stdin_fd >= 0) {
            const n = sys.write(s.stdin_fd, s.pend[0..s.plen]);
            if (n <= 0) {
                if (n == -sys.E.AGAIN) return;
                s.plen = 0;
                break;
            }
            const k: usize = @intCast(n);
            std.mem.copyForwards(u8, s.pend[0 .. s.plen - k], s.pend[k..s.plen]);
            s.plen -= k;
        }
        if (s.plen == 0 and s.want_eof) {
            s.want_eof = false;
            s.closeStdin();
        }
    }

    fn handle(s: *Session, kind: u8, p: []const u8) void {
        switch (kind) {
            F_IN => if (s.plen + p.len <= s.pend.len) {
                @memcpy(s.pend[s.plen .. s.plen + p.len], p);
                s.plen += p.len;
                s.flushInput();
            },
            F_EOF => {
                s.want_eof = true;
                s.flushInput();
            },
            F_WINCH => if (s.master >= 0 and p.len == 4) {
                const ws = [4]u16{ std.mem.readInt(u16, p[0..2], .big), std.mem.readInt(u16, p[2..4], .big), 0, 0 };
                _ = sys.ioctl(s.master, sys.TIOCSWINSZ, @intFromPtr(&ws));
                _ = sys.kill(-s.pid, 28); // SIGWINCH
            },
            F_SIG => if (p.len == 1 and s.pid > 0 and p[0] > 0 and p[0] < 32) {
                _ = sys.kill(-s.pid, p[0]);
            },
            else => {},
        }
    }

    fn frames(s: *Session) void {
        while (s.rlen >= 5) {
            const plen = std.mem.readInt(u32, s.rx[1..5], .big);
            if (plen > max_payload) sys.exit(1);
            if (s.rlen < 5 + plen) break;
            s.handle(s.rx[0], s.rx[5 .. 5 + plen]);
            const total = 5 + plen;
            std.mem.copyForwards(u8, s.rx[0 .. s.rlen - total], s.rx[total..s.rlen]);
            s.rlen -= total;
        }
    }

    fn pump(s: *Session, fd: *isize, kind: u8) bool {
        var buf: [16384]u8 = undefined;
        const n = sys.read(fd.*, &buf);
        if (n == -sys.E.AGAIN) return true;
        if (n <= 0) {
            sys.close(fd.*);
            fd.* = -1;
            return true;
        }
        return sendFrame(s.conn, kind, buf[0..@intCast(n)]);
    }

    fn drain(s: *Session) void {
        var guard: usize = 0;
        while (guard < 4096 and (s.master >= 0 or s.out_fd >= 0 or s.err_fd >= 0)) : (guard += 1) {
            const before = [3]isize{ s.master, s.out_fd, s.err_fd };
            if (s.master >= 0) _ = s.pump(&s.master, F_OUT);
            if (s.out_fd >= 0) _ = s.pump(&s.out_fd, F_OUT);
            if (s.err_fd >= 0) _ = s.pump(&s.err_fd, F_ERR);
            if (before[0] == s.master and before[1] == s.out_fd and before[2] == s.err_fd) break; // EAGAIN everywhere
        }
    }
};

fn exitCode(status: u32) i32 {
    if (status & 0x7f == 0) return @intCast((status >> 8) & 0xff);
    return 128 + @as(i32, @intCast(status & 0x7f));
}

pub fn serve(conn: isize) noreturn {
    const s = util.arena().create(Session) catch sys.exit(1);
    s.* = .{ .conn = conn };
    var req = Request{};
    // first frame: the request
    while (true) {
        const n = sys.read(conn, s.rx[s.rlen..]);
        if (n <= 0) sys.exit(1);
        s.rlen += @intCast(n);
        if (s.rlen >= 5 and s.rlen >= 5 + std.mem.readInt(u32, s.rx[1..5], .big)) break;
        if (s.rlen == s.rx.len) sys.exit(1);
    }
    const plen = std.mem.readInt(u32, s.rx[1..5], .big);
    if (s.rx[0] != F_REQ or plen > max_payload) sys.exit(1);
    parseRequest(s.rx[5 .. 5 + plen], &req);
    std.mem.copyForwards(u8, s.rx[0 .. s.rlen - 5 - plen], s.rx[5 + plen .. s.rlen]);
    s.rlen -= 5 + plen;

    if (req.poweroff) {
        if (util.exists("/run/noodle-systemd")) {
            // Let systemd stop services and unmount filesystems. Never run the minimal
            // init's kill-all/reboot path while systemd owns PID 1.
            const rc = systemd.requestPoweroff();
            _ = sendFrame(conn, F_EXIT, if (rc == 0) &[4]u8{ 0, 0, 0, 0 } else &[4]u8{ 0, 0, 0, 1 });
            sys.exit(0);
        }
        _ = sendFrame(conn, F_EXIT, &[4]u8{ 0, 0, 0, 0 });
        powerOff();
    }
    const pw = lookupUser(req.user) orelse {
        _ = sendFrame(conn, F_ERR, util.sf("noodle: no such user {s}\n", .{req.user}));
        _ = sendFrame(conn, F_EXIT, &[4]u8{ 0, 0, 0, 126 });
        sys.exit(0);
    };

    // pty or pipes
    var in_r: i32 = -1;
    var out_w: i32 = -1;
    var err_w: i32 = -1;
    var slave_path: [:0]const u8 = "";
    if (req.tty) {
        const m = sys.open("/dev/ptmx", sys.O.RDWR | sys.O.NOCTTY | sys.O.CLOEXEC | sys.O.NONBLOCK, 0);
        if (m < 0) sys.exit(1);
        var unlock: i32 = 0;
        var num: u32 = 0;
        _ = sys.ioctl(m, sys.TIOCSPTLCK, @intFromPtr(&unlock));
        _ = sys.ioctl(m, sys.TIOCGPTN, @intFromPtr(&num));
        const ws = [4]u16{ req.rows, req.cols, 0, 0 };
        _ = sys.ioctl(m, sys.TIOCSWINSZ, @intFromPtr(&ws));
        slave_path = util.zf("/dev/pts/{d}", .{num});
        s.master = m;
        s.stdin_fd = m;
    } else {
        var a: [2]i32 = undefined;
        var b: [2]i32 = undefined;
        var c: [2]i32 = undefined;
        if (sys.pipe2(&a, sys.O.CLOEXEC) < 0 or sys.pipe2(&b, sys.O.CLOEXEC) < 0 or sys.pipe2(&c, sys.O.CLOEXEC) < 0) sys.exit(1);
        in_r = a[0];
        s.stdin_fd = a[1];
        out_w = b[1];
        s.out_fd = b[0];
        err_w = c[1];
        s.err_fd = c[0];
        sys.setNonblock(s.stdin_fd);
        sys.setNonblock(s.out_fd);
        sys.setNonblock(s.err_fd);
    }
    // SIGCHLD through a signalfd, so the exit wakes the poll loop
    const chld_bit: u64 = @as(u64, 1) << (sys.SIG.CHLD - 1);
    _ = sys.sigprocmask(0, chld_bit);
    const sfd = sys.signalfd(chld_bit);

    const pid = sys.fork();
    if (pid == 0) {
        _ = sys.setsid();
        if (req.tty) {
            const sl = sys.open(slave_path.ptr, sys.O.RDWR, 0);
            if (sl < 0) sys.exit(1);
            _ = sys.fchownat(sl, "", pw.uid, pw.gid, sys.AT_EMPTY_PATH);
            _ = sys.ioctl(sl, sys.TIOCSCTTY, 0);
            _ = sys.dup3(sl, 0, 0);
            _ = sys.dup3(sl, 1, 0);
            _ = sys.dup3(sl, 2, 0);
            if (sl > 2) sys.close(sl);
        } else {
            _ = sys.dup3(in_r, 0, 0);
            _ = sys.dup3(out_w, 1, 0);
            _ = sys.dup3(err_w, 2, 0);
        }
        sys.setCloexec(conn, true);
        execChild(&req, pw);
    }
    if (pid < 0) sys.exit(1);
    s.pid = pid;
    if (in_r >= 0) sys.close(in_r);
    if (out_w >= 0) sys.close(out_w);
    if (err_w >= 0) sys.close(err_w);
    s.frames(); // input that arrived together with the request

    var status: u32 = 0;
    var exited = false;
    while (!exited) {
        var pfd: [5]sys.PollFd = undefined;
        var n: usize = 0;
        var which: [5]u8 = undefined;
        const room = s.plen < 65536;
        const add = struct {
            fn f(p: *[5]sys.PollFd, w: *[5]u8, k: *usize, fd: isize, ev: i16, tag: u8) void {
                if (fd < 0) return;
                p[k.*] = .{ .fd = @intCast(fd), .events = ev, .revents = 0 };
                w[k.*] = tag;
                k.* += 1;
            }
        }.f;
        add(&pfd, &which, &n, conn, if (room) sys.POLLIN else 0, 'c');
        add(&pfd, &which, &n, sfd, sys.POLLIN, 's');
        add(&pfd, &which, &n, s.master, sys.POLLIN | (if (s.plen > 0) @as(i16, sys.POLLOUT) else 0), 'm');
        add(&pfd, &which, &n, s.out_fd, sys.POLLIN, 'o');
        add(&pfd, &which, &n, s.err_fd, sys.POLLIN, 'e');
        if (s.plen > 0 and s.master < 0) add(&pfd, &which, &n, s.stdin_fd, sys.POLLOUT, 'i');
        if (sys.poll(@ptrCast(&pfd), n, -1) < 0) continue;
        for (pfd[0..n], which[0..n]) |p, w| {
            if (p.revents == 0) continue;
            switch (w) {
                'c' => {
                    const r = sys.read(conn, s.rx[s.rlen..]);
                    if (r <= 0) {
                        _ = sys.kill(-s.pid, sys.SIG.HUP);
                        sys.exit(1);
                    }
                    s.rlen += @intCast(r);
                    s.frames();
                },
                's' => {
                    var info: [128]u8 = undefined;
                    _ = sys.read(sfd, &info);
                    const r = sys.wait4(s.pid, &status, 1);
                    if (r == s.pid) exited = true;
                },
                'm' => {
                    if (p.revents & sys.POLLOUT != 0) s.flushInput();
                    if (p.revents & (sys.POLLIN | sys.POLLHUP | sys.POLLERR) != 0 and s.master >= 0) {
                        const keep = s.master;
                        if (!s.pump(&s.master, F_OUT)) sys.exit(1);
                        if (s.master < 0) s.stdin_fd = -1;
                        _ = keep;
                    }
                },
                'o' => if (!s.pump(&s.out_fd, F_OUT)) sys.exit(1),
                'e' => if (!s.pump(&s.err_fd, F_ERR)) sys.exit(1),
                'i' => s.flushInput(),
                else => {},
            }
        }
    }
    s.drain();
    const code = exitCode(status);
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(i32, &bytes, code, .big);
    _ = sendFrame(conn, F_EXIT, &bytes);
    sys.exit(0);
}
