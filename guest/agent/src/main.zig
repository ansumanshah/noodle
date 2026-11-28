//! Noodle guest agent: PID 1. One epoll loop; long work happens in forked children.
const std = @import("std");
const sys = @import("sys.zig");
const util = @import("util.zig");
const frame = @import("frame");
const boot = @import("boot.zig");
const control = @import("control.zig");
const container = @import("container.zig");
const stream = @import("stream.zig");
const net = @import("net.zig");
const resolver = @import("resolver.zig");
const json = @import("json");

pub const panic = std.debug.no_panic;
pub const std_options: std.Options = .{ .enable_segfault_handler = false };

// vsock ports, one block shared with the host (NoodleWire in Sources/NoodleCore/Frames.swift).
const PORT_READY = 1031; // host listens: "both listeners are up"
const PORT_CTL = 1032; // agent listens: control frames
const PORT_STREAM = 1033; // agent listens: one stream op per connection

var ctl_buf: [4 * 1024 * 1024]u8 = undefined;
var asm_: frame.Assembler = undefined;
var ctl_fd: isize = -1;
var evt_rd: isize = -1;
var listen_ctl: isize = -1;
var listen_stream: isize = -1;

fn listenVsock(port: u32) isize {
    const s = sys.socket(sys.AF_VSOCK, sys.SOCK_STREAM, 0);
    if (s < 0) {
        util.log("vsock socket({d}): errno {d}", .{ port, -s });
        return s;
    }
    const addr = sys.SockaddrVm{ .port = port, .cid = 0xFFFFFFFF };
    var rc = sys.bind(s, &addr, @sizeOf(sys.SockaddrVm));
    if (rc < 0) {
        util.log("vsock bind({d}): errno {d}", .{ port, -rc });
        return rc;
    }
    rc = sys.listen(s, 1024);
    if (rc < 0) {
        util.log("vsock listen({d}): errno {d}", .{ port, -rc });
        return rc;
    }
    sys.setNonblock(s);
    util.log("listening on vsock {d}", .{port});
    return s;
}

/// Tell the host the listeners are up, so it does not have to poll for them. Best effort: the host still polls slowly.
fn announceReady() void {
    const s = sys.socket(sys.AF_VSOCK, sys.SOCK_STREAM, 0);
    if (s < 0) return;
    const addr = sys.SockaddrVm{ .port = PORT_READY, .cid = 2 };
    _ = sys.connect(s, &addr, @sizeOf(sys.SockaddrVm));
    sys.close(s);
}

fn sendControl(payload: []const u8) void {
    if (ctl_fd < 0) return;
    const a = util.arena();
    const out = a.alloc(u8, 4 + payload.len) catch return;
    frame.putU32(out[0..4], @intCast(payload.len));
    @memcpy(out[4..], payload);
    _ = sys.writeAll(ctl_fd, out);
}

fn emit(payload: []const u8) void {
    sendControl(payload);
}

fn closeControl() void {
    container.cancelStarts();
    if (ctl_fd >= 0) {
        _ = sys.epoll_del(util.epfd, ctl_fd);
        sys.close(ctl_fd);
        ctl_fd = -1;
        stream.ctl_fd = -1;
        asm_.len = 0;
    }
}

fn onControlReadable() void {
    while (true) {
        if (asm_.space().len == 0) {
            closeControl();
            return;
        }
        const n = sys.read(ctl_fd, asm_.space());
        if (n == -sys.E.AGAIN) break;
        if (n == -sys.E.INTR) continue;
        if (n <= 0) {
            closeControl();
            return;
        }
        asm_.commit(@intCast(n));
        while (true) {
            const f = asm_.peekFrame() catch {
                closeControl();
                return;
            } orelse break;
            const resp = control.handle(f);
            // copy the payload out of the assembler before consuming? response is in the arena already
            if (resp.len > 0) sendControl(resp);
            asm_.consume();
            util.noteArena();
            util.resetArena();
            if (control.shutdown_requested) {
                container.killAll();
                boot.shutdown();
            }
        }
        if (n < asm_.buf.len) {
            // loop again until EAGAIN so edge-ish bursts are drained
        }
    }
}

fn onAcceptControl() void {
    while (true) {
        const c = sys.acceptHostVsock(listen_ctl, sys.O.NONBLOCK);
        if (c < 0) return;
        closeControl();
        ctl_fd = c;
        stream.ctl_fd = c;
        asm_.len = 0;
        _ = sys.epoll_add(util.epfd, c, sys.EPOLLIN, util.tag(util.Tag.ctl_conn, 0));
        util.log("control connection accepted", .{});
    }
}

/// Forward whole event frames that stream children wrote to the event pipe (each write is atomic).
fn onEvents() void {
    while (true) {
        var hdr: [4]u8 = undefined;
        if (sys.read(evt_rd, &hdr) != 4) return;
        const len = std.mem.readInt(u32, &hdr, .big);
        var buf: [4096]u8 = undefined;
        if (len > buf.len or sys.read(evt_rd, buf[0..len]) != len) return;
        sendControl(buf[0..len]);
        var pfd = [1]sys.PollFd{.{ .fd = @intCast(evt_rd), .events = sys.POLLIN, .revents = 0 }};
        if (sys.poll(&pfd, 1, 0) <= 0) return;
    }
}

fn onAcceptStream() void {
    while (true) {
        const c = sys.acceptHostVsock(listen_stream, 0);
        if (c < 0) return;
        const pid = sys.fork();
        if (pid == 0) {
            sys.close(listen_ctl);
            sys.close(listen_stream);
            sys.close(evt_rd);
            if (ctl_fd >= 0) sys.close(ctl_fd); // children never write it; a stale copy would hold the connection open
            stream.ctl_fd = -1;
            net.dhcpCloseInChild();
            container.closeTtysInStreamChild();
            container.closeStdinRelaysInChild();
            stream.serve(c);
        }
        sys.close(c);
    }
}

fn reap(sigfd: isize) void {
    var info: [128]u8 = undefined;
    while (sys.read(sigfd, &info) > 0) {}
    while (true) {
        var status: u32 = 0;
        const pid = sys.wait4(-1, &status, 1); // WNOHANG
        if (pid <= 0) break;
        @import("hostlo.zig").onReaped(@intCast(pid));
        @import("sshagent.zig").onReaped(@intCast(pid));
        container.teardownReaped(@intCast(pid));
        // SIGCHLD can win the epoll race against a fast tty command's status EOF.
        if (container.pending_starts > 0) for (&container.conts, 0..) |*c, idx| {
            if (c.used and c.pid == pid and c.start_status >= 0) {
                if (control.completeStart(@intCast(idx))) |resp| sendControl(resp);
            }
        };
        if (container.onChildExit(@intCast(pid), status)) |ex| {
            var b = json.Buf.init(util.arena());
            if (ex.oom) {
                b.raw("{\"event\":\"oom\",\"container\":") catch {};
                b.str(ex.id[0..ex.idlen]) catch {};
                b.byte('}') catch {};
                sendControl(b.bytes());
                b = json.Buf.init(util.arena());
            }
            b.raw("{\"event\":\"exit\",\"container\":") catch {};
            b.str(ex.id[0..ex.idlen]) catch {};
            b.print(",\"code\":{d}}}", .{ex.code}) catch {};
            sendControl(b.bytes());
        }
    }
}

pub fn main() void {
    util.initArena();
    control.boot_ns = sys.boottime_ns();
    if (!boot.run()) fatal("data disk unavailable; inspect the VM log and repair or restore the disk");
    asm_ = frame.Assembler.init(&ctl_buf);

    const ep = sys.epoll_create();
    if (ep < 0) fatal("epoll_create");
    util.epfd = ep;
    net.dhcpWatch();

    // SIGCHLD through a signalfd so children are reaped from the loop
    const chld_mask: u64 = @as(u64, 1) << (sys.SIG.CHLD - 1);
    _ = sys.sigprocmask(0, chld_mask); // SIG_BLOCK
    const sigfd = sys.signalfd(chld_mask);
    if (sigfd < 0) fatal("signalfd");
    _ = sys.epoll_add(ep, sigfd, sys.EPOLLIN, util.tag(util.Tag.sigfd, 0));

    var evp: [2]i32 = undefined;
    if (sys.pipe2(&evp, 0) < 0) fatal("event pipe");
    evt_rd = evp[0];
    stream.evt_fd = evp[1];
    _ = sys.epoll_add(ep, evt_rd, sys.EPOLLIN, util.tag(util.Tag.evt_pipe, 0));

    listen_ctl = listenVsock(PORT_CTL);
    listen_stream = listenVsock(PORT_STREAM);
    if (listen_ctl < 0 or listen_stream < 0) fatal("vsock listen");
    _ = sys.epoll_add(ep, listen_ctl, sys.EPOLLIN, util.tag(util.Tag.listen_ctl, 0));
    _ = sys.epoll_add(ep, listen_stream, sys.EPOLLIN, util.tag(util.Tag.listen_stream, 0));

    container.sweepStale();
    util.resetArena();
    util.log("ready", .{});
    announceReady();

    var evs: [32]sys.EpollEvent = undefined;
    while (true) {
        const n = sys.epoll_wait(ep, &evs, earliest(resolver.nextTimeoutMs(), net.dhcpTimeoutMs()));
        resolver.onTimer();
        net.dhcpPump();
        if (n < 0) continue;
        var i: usize = 0;
        while (i < @as(usize, @intCast(n))) : (i += 1) {
            const kind: u32 = @intCast(evs[i].data >> 32);
            const idx: u32 = @truncate(evs[i].data);
            switch (kind) {
                util.Tag.listen_ctl => onAcceptControl(),
                util.Tag.listen_stream => onAcceptStream(),
                util.Tag.ctl_conn => onControlReadable(),
                util.Tag.sigfd => reap(sigfd),
                util.Tag.evt_pipe => onEvents(),
                util.Tag.job => if (control.onJob(idx)) |resp| sendControl(resp),
                util.Tag.cont_out => container.onOutput(idx / 4, idx % 4),
                util.Tag.cont_stdin => container.onStdin(idx / 2, idx % 2 == 1),
                util.Tag.tty_request => container.onTtyRequest(idx),
                util.Tag.tty_waiter => container.onTtyWaiter(idx),
                util.Tag.tty_master => {
                    if (control.receiveStartMaster(idx)) |resp| sendControl(resp);
                },
                util.Tag.tty_start => {
                    if (control.completeStart(idx)) |resp| sendControl(resp);
                },
                util.Tag.dns => net.handleDns(idx),
                util.Tag.dns_up => resolver.onUpstream(),
                util.Tag.resolver => resolver.onQuery(idx),
                util.Tag.resolver_tcp => resolver.onAccept(idx),
                util.Tag.dns_conn => resolver.onConn(idx),
                util.Tag.dns_up_tcp => resolver.onUpTcp(idx),
                util.Tag.ssh_listen => @import("sshagent.zig").onAccept(idx),
                util.Tag.hostlo_listen => @import("hostlo.zig").onAccept(),
                else => {},
            }
        }
        util.resetArena();
    }
}

/// Soonest of two epoll timeouts, where -1 means none.
fn earliest(a: i32, b: i32) i32 {
    if (a < 0) return b;
    if (b < 0) return a;
    return @min(a, b);
}

fn fatal(what: []const u8) noreturn {
    util.log("FATAL: {s}", .{what});
    while (true) sys.sleep_ms(1000);
}
