//! Raw aarch64 Linux syscalls. No libc, no std.posix, no std.Io: just numbers and ABI structs.
//! Every wrapper returns a non-negative result or a negative errno (isize).
const std = @import("std");
const linux = std.os.linux;
const SYS = linux.SYS;

pub const E = struct {
    pub const PERM = 1;
    pub const NOENT = 2;
    pub const SRCH = 3;
    pub const INTR = 4;
    pub const IO = 5;
    pub const NXIO = 6;
    pub const CHILD = 10;
    pub const AGAIN = 11;
    pub const INPROGRESS = 115;
    pub const NOMEM = 12;
    pub const ACCES = 13;
    pub const BUSY = 16;
    pub const EXIST = 17;
    pub const NOTDIR = 20;
    pub const ISDIR = 21;
    pub const INVAL = 22;
    pub const NOSPC = 28;
    pub const NAMETOOLONG = 36;
    pub const PIPE = 32;
    pub const RANGE = 34;
    pub const NOSYS = 38;
    pub const NOTEMPTY = 39;
    pub const NODATA = 61;
    pub const OPNOTSUPP = 95;
    pub const AFNOSUPPORT = 97;
};

inline fn r(v: usize) isize {
    return @bitCast(v);
}
pub inline fn failed(v: isize) bool {
    return v < 0;
}
pub inline fn errno(v: isize) i32 {
    return @intCast(-v);
}

pub const AT_FDCWD: isize = -100;
pub const AT_SYMLINK_NOFOLLOW: usize = 0x100;
pub const AT_REMOVEDIR: usize = 0x200;
pub const AT_EMPTY_PATH: usize = 0x1000;

pub const O = struct {
    pub const RDONLY = 0;
    pub const WRONLY = 1;
    pub const RDWR = 2;
    pub const CREAT = 0o100;
    pub const EXCL = 0o200;
    pub const NOCTTY = 0o400;
    pub const TRUNC = 0o1000;
    pub const APPEND = 0o2000;
    pub const NONBLOCK = 0o4000;
    pub const DIRECTORY = 0o40000;
    pub const NOFOLLOW = 0o100000;
    pub const CLOEXEC = 0o2000000;
    pub const PATH = 0o10000000;
};

pub const S = struct {
    pub const IFMT = 0o170000;
    pub const IFSOCK = 0o140000;
    pub const IFLNK = 0o120000;
    pub const IFREG = 0o100000;
    pub const IFBLK = 0o060000;
    pub const IFDIR = 0o040000;
    pub const IFCHR = 0o020000;
    pub const IFIFO = 0o010000;
};

pub const MS = struct {
    pub const RDONLY = 1;
    pub const NOSUID = 2;
    pub const NODEV = 4;
    pub const NOEXEC = 8;
    pub const REMOUNT = 32;
    pub const NOATIME = 1024;
    pub const BIND = 4096;
    pub const MOVE = 8192;
    pub const REC = 16384;
    pub const PRIVATE = 1 << 18;
    pub const SLAVE = 1 << 19;
    pub const SHARED = 1 << 20;
};

pub const CLONE = struct {
    pub const NEWNS = 0x00020000;
    pub const NEWCGROUP = 0x02000000;
    pub const NEWUTS = 0x04000000;
    pub const NEWIPC = 0x08000000;
    pub const NEWUSER = 0x10000000;
    pub const NEWPID = 0x20000000;
    pub const NEWNET = 0x40000000;
    pub const INTO_CGROUP: u64 = 0x200000000;
};

pub const SIG = struct {
    pub const HUP = 1;
    pub const INT = 2;
    pub const KILL = 9;
    pub const TERM = 15;
    pub const CHLD = 17;
    pub const CONT = 18;
    pub const STOP = 19;
};

pub const Stat = extern struct {
    dev: u64,
    ino: u64,
    mode: u32,
    nlink: u32,
    uid: u32,
    gid: u32,
    rdev: u64,
    __pad1: u64,
    size: i64,
    blksize: i32,
    __pad2: i32,
    blocks: i64,
    atime: i64,
    atime_nsec: i64,
    mtime: i64,
    mtime_nsec: i64,
    ctime: i64,
    ctime_nsec: i64,
    __unused: [2]u32,
};

pub const Timespec = extern struct { sec: i64, nsec: i64 };

pub fn sc(n: SYS, a: usize, b: usize, c: usize, d: usize, e: usize, f: usize) isize {
    return r(linux.syscall6(n, a, b, c, d, e, f));
}
inline fn p(x: anytype) usize {
    return @intFromPtr(x);
}
inline fn u(x: isize) usize {
    return @bitCast(x);
}

pub fn openat(dirfd: isize, path: [*:0]const u8, flags: usize, mode: usize) isize {
    return sc(.openat, u(dirfd), p(path), flags | O.CLOEXEC, mode, 0, 0);
}
pub fn open(path: [*:0]const u8, flags: usize, mode: usize) isize {
    return openat(AT_FDCWD, path, flags, mode);
}
pub fn close(fd: isize) void {
    if (fd >= 0) _ = sc(.close, u(fd), 0, 0, 0, 0, 0);
}
pub fn read(fd: isize, buf: []u8) isize {
    return sc(.read, u(fd), p(buf.ptr), buf.len, 0, 0, 0);
}
pub fn write(fd: isize, buf: []const u8) isize {
    return sc(.write, u(fd), p(buf.ptr), buf.len, 0, 0, 0);
}
pub fn pread(fd: isize, buf: []u8, off: u64) isize {
    return sc(.pread64, u(fd), p(buf.ptr), buf.len, off, 0, 0);
}
pub fn lseek(fd: isize, off: i64, whence: usize) isize {
    return sc(.lseek, u(fd), @bitCast(off), whence, 0, 0, 0);
}
pub fn ftruncate(fd: isize, len: u64) isize {
    return sc(.ftruncate, u(fd), len, 0, 0, 0, 0);
}
pub fn fsync(fd: isize) isize {
    return sc(.fsync, u(fd), 0, 0, 0, 0, 0);
}
pub fn syncfs(fd: isize) isize {
    return sc(.syncfs, u(fd), 0, 0, 0, 0, 0);
}

/// Blocking-friendly full write; retries EINTR/EAGAIN (polls on EAGAIN).
pub fn writeAll(fd: isize, buf: []const u8) isize {
    var off: usize = 0;
    while (off < buf.len) {
        const n = write(fd, buf[off..]);
        if (n < 0) {
            if (n == -E.INTR) continue;
            if (n == -E.AGAIN) {
                var pfd = PollFd{ .fd = @intCast(fd), .events = POLLOUT, .revents = 0 };
                _ = poll(@ptrCast(&pfd), 1, 1000);
                continue;
            }
            return n;
        }
        off += @intCast(n);
    }
    return 0;
}
/// Reads exactly buf.len bytes. Returns bytes read (< len only at EOF) or negative errno.
pub fn readAll(fd: isize, buf: []u8) isize {
    var off: usize = 0;
    while (off < buf.len) {
        const n = read(fd, buf[off..]);
        if (n < 0) {
            if (n == -E.INTR) continue;
            if (n == -E.AGAIN) {
                var pfd = PollFd{ .fd = @intCast(fd), .events = POLLIN, .revents = 0 };
                _ = poll(@ptrCast(&pfd), 1, 1000);
                continue;
            }
            return n;
        }
        if (n == 0) break;
        off += @intCast(n);
    }
    return @intCast(off);
}

pub const PollFd = extern struct { fd: i32, events: i16, revents: i16 };
pub const POLLIN = 1;
pub const POLLOUT = 4;
pub const POLLERR = 8;
pub const POLLHUP = 16;
pub const POLLRDHUP = 0x2000;
pub fn poll(fds: [*]PollFd, n: usize, timeout_ms: i32) isize {
    var ts: Timespec = undefined;
    var tsp: usize = 0;
    if (timeout_ms >= 0) {
        ts = .{ .sec = @divTrunc(timeout_ms, 1000), .nsec = @as(i64, @rem(timeout_ms, 1000)) * 1_000_000 };
        tsp = p(&ts);
    }
    return sc(.ppoll, p(fds), n, tsp, 0, 0, 0);
}

pub fn mkdirat(dirfd: isize, path: [*:0]const u8, mode: usize) isize {
    return sc(.mkdirat, u(dirfd), p(path), mode, 0, 0, 0);
}
pub fn unlinkat(dirfd: isize, path: [*:0]const u8, flags: usize) isize {
    return sc(.unlinkat, u(dirfd), p(path), flags, 0, 0, 0);
}
pub fn symlinkat(target: [*:0]const u8, dirfd: isize, path: [*:0]const u8) isize {
    return sc(.symlinkat, p(target), u(dirfd), p(path), 0, 0, 0);
}
pub fn linkat(od: isize, op: [*:0]const u8, nd: isize, np: [*:0]const u8, flags: usize) isize {
    return sc(.linkat, u(od), p(op), u(nd), p(np), flags, 0);
}
pub fn renameat(od: isize, op: [*:0]const u8, nd: isize, np: [*:0]const u8) isize {
    return sc(.renameat2, u(od), p(op), u(nd), p(np), 0, 0);
}
pub fn mknodat(dirfd: isize, path: [*:0]const u8, mode: usize, dev: u64) isize {
    return sc(.mknodat, u(dirfd), p(path), mode, dev, 0, 0);
}
pub fn fchownat(dirfd: isize, path: [*:0]const u8, uid: u32, gid: u32, flags: usize) isize {
    return sc(.fchownat, u(dirfd), p(path), uid, gid, flags, 0);
}
pub fn chmodPath(path: [*:0]const u8, mode: usize) isize {
    return sc(.fchmodat2, u(AT_FDCWD), p(path), mode, 0, 0, 0);
}
pub fn chmodFd(fd: isize, mode: usize) isize {
    return sc(.fchmodat2, u(fd), p(""), mode, AT_EMPTY_PATH | AT_SYMLINK_NOFOLLOW, 0, 0);
}
pub fn utimensat(dirfd: isize, path: [*:0]const u8, times: *const [2]Timespec, flags: usize) isize {
    return sc(.utimensat, u(dirfd), p(path), p(times), flags, 0, 0);
}
pub fn fstatat(dirfd: isize, path: [*:0]const u8, st: *Stat, flags: usize) isize {
    return sc(.newfstatat, u(dirfd), p(path), p(st), flags, 0, 0);
}
pub fn fstat(fd: isize, st: *Stat) isize {
    return sc(.fstat, u(fd), p(st), 0, 0, 0, 0);
}
pub fn readlinkat(dirfd: isize, path: [*:0]const u8, buf: []u8) isize {
    return sc(.readlinkat, u(dirfd), p(path), p(buf.ptr), buf.len, 0, 0);
}
pub fn getdents64(fd: isize, buf: []u8) isize {
    return sc(.getdents64, u(fd), p(buf.ptr), buf.len, 0, 0, 0);
}
pub fn setxattr(path: [*:0]const u8, name: [*:0]const u8, val: []const u8) isize {
    return sc(.setxattr, p(path), p(name), p(val.ptr), val.len, 0, 0);
}
pub fn lsetxattr(path: [*:0]const u8, name: [*:0]const u8, val: []const u8) isize {
    return sc(.lsetxattr, p(path), p(name), p(val.ptr), val.len, 0, 0);
}
pub fn lgetxattr(path: [*:0]const u8, name: [*:0]const u8, buf: []u8) isize {
    return sc(.lgetxattr, p(path), p(name), p(buf.ptr), buf.len, 0, 0);
}
pub fn llistxattr(path: [*:0]const u8, buf: []u8) isize {
    return sc(.llistxattr, p(path), p(buf.ptr), buf.len, 0, 0, 0);
}
pub fn chdir(path: [*:0]const u8) isize {
    return sc(.chdir, p(path), 0, 0, 0, 0, 0);
}
pub fn fchdir(fd: isize) isize {
    return sc(.fchdir, u(fd), 0, 0, 0, 0, 0);
}
pub fn chroot(path: [*:0]const u8) isize {
    return sc(.chroot, p(path), 0, 0, 0, 0, 0);
}
pub fn access(path: [*:0]const u8, mode: usize) isize {
    return sc(.faccessat, u(AT_FDCWD), p(path), mode, 0, 0, 0);
}

pub const OpenHow = extern struct { flags: u64, mode: u64, resolve: u64 };
pub const RESOLVE_NO_MAGICLINKS = 0x02;
pub const RESOLVE_IN_ROOT = 0x10;
pub fn openat2(dirfd: isize, path: [*:0]const u8, flags: u64, mode: u64, resolve: u64) isize {
    var how = OpenHow{ .flags = flags | O.CLOEXEC, .mode = mode, .resolve = resolve };
    return sc(.openat2, u(dirfd), p(path), p(&how), @sizeOf(OpenHow), 0, 0);
}

pub fn mount(src: ?[*:0]const u8, target: [*:0]const u8, fstype: ?[*:0]const u8, flags: usize, data: ?[*:0]const u8) isize {
    return sc(.mount, if (src) |s| p(s) else 0, p(target), if (fstype) |s| p(s) else 0, flags, if (data) |s| p(s) else 0, 0);
}
pub fn umount2(target: [*:0]const u8, flags: usize) isize {
    return sc(.umount2, p(target), flags, 0, 0, 0, 0);
}
pub fn pivot_root(new: [*:0]const u8, old: [*:0]const u8) isize {
    return sc(.pivot_root, p(new), p(old), 0, 0, 0, 0);
}
pub fn sethostname(name: []const u8) isize {
    return sc(.sethostname, p(name.ptr), name.len, 0, 0, 0, 0);
}
pub fn setdomainname(name: []const u8) isize {
    return sc(.setdomainname, p(name.ptr), name.len, 0, 0, 0, 0);
}

pub fn pipe2(fds: *[2]i32, flags: usize) isize {
    return sc(.pipe2, p(fds), flags | O.CLOEXEC, 0, 0, 0, 0);
}
pub const SPLICE_F_NONBLOCK = 2;
pub fn splice(in: isize, out: isize, len: usize, flags: usize) isize {
    return sc(.splice, u(in), 0, u(out), 0, len, flags);
}
pub fn dup3(old: isize, new: isize, flags: usize) isize {
    return sc(.dup3, u(old), u(new), flags, 0, 0, 0);
}
pub fn fcntl(fd: isize, cmd: usize, arg: usize) isize {
    return sc(.fcntl, u(fd), cmd, arg, 0, 0, 0);
}
pub fn ioctl(fd: isize, req: usize, arg: usize) isize {
    return sc(.ioctl, u(fd), req, arg, 0, 0, 0);
}
pub const TIOCSWINSZ = 0x5414;
pub const TIOCSCTTY = 0x540E;
pub const TIOCGPTN = 0x80045430;
pub const TIOCSPTLCK = 0x40045431;
pub const F_GETFL = 3;
pub const F_SETFL = 4;
pub fn setNonblock(fd: isize) void {
    const fl = fcntl(fd, F_GETFL, 0);
    if (fl >= 0) _ = fcntl(fd, F_SETFL, @as(usize, @intCast(fl)) | O.NONBLOCK);
}
pub fn clearNonblock(fd: isize) void {
    const fl = fcntl(fd, F_GETFL, 0);
    if (fl >= 0) _ = fcntl(fd, F_SETFL, @as(usize, @intCast(fl)) & ~@as(usize, O.NONBLOCK));
}
pub fn setCloexec(fd: isize, on: bool) void {
    _ = fcntl(fd, 2, if (on) 1 else 0); // F_SETFD
}

// sockets
pub const AF_UNIX = 1;
pub const AF_INET = 2;
pub const AF_INET6 = 10;
pub const AF_NETLINK = 16;
pub const AF_VSOCK = 40;
pub const SOCK_STREAM = 1;
pub const SOCK_DGRAM = 2;
pub const SOCK_RAW = 3;
pub const SOCK_NONBLOCK = 0o4000;
pub const SOCK_CLOEXEC = 0o2000000;
pub const SOL_SOCKET = 1;
pub const SO_REUSEADDR = 2;
pub const SO_BROADCAST = 6;
pub const SO_BINDTODEVICE = 25;
pub const SO_RCVTIMEO = 20;
pub fn socket(dom: usize, ty: usize, proto: usize) isize {
    return sc(.socket, dom, ty | SOCK_CLOEXEC, proto, 0, 0, 0);
}
pub fn socketpair(dom: usize, ty: usize, fds: *[2]i32) isize {
    return sc(.socketpair, dom, ty | SOCK_CLOEXEC, 0, p(fds), 0, 0);
}
// Linux LP64 ABI, independent of the host's socket headers.
const FdIov = extern struct { base: usize, len: usize };
const FdMsg = extern struct {
    name: usize = 0,
    namelen: u32 = 0,
    iov: usize,
    iovlen: usize = 1,
    control: usize,
    controllen: usize,
    flags: u32 = 0,
};
const FdCmsg = extern struct { len: usize, level: i32, kind: i32 };
const fd_header_len = @sizeOf(FdCmsg);
const fd_control_len = fd_header_len + 256 * @sizeOf(i32);
const FdControl = struct {
    fds: [256]i32 = undefined,
    count: usize = 0,
    valid: bool,
};

// Keep every complete SCM_RIGHTS descriptor, even on invalid input, so the
// caller can close them all. Linux closes descriptors omitted by MSG_CTRUNC.
fn parseFdControl(control: []const u8, flags: u32, payload_len: isize) FdControl {
    var result = FdControl{ .valid = payload_len == 1 and flags & (8 | 0x20) == 0 };
    var offset: usize = 0;
    var rights: usize = 0;
    while (offset < control.len) {
        const remaining = control.len - offset;
        if (remaining < fd_header_len) {
            result.valid = false;
            break;
        }
        const header = std.mem.bytesToValue(FdCmsg, control[offset..][0..fd_header_len]);
        if (header.len < fd_header_len) {
            result.valid = false;
            break;
        }
        const available = @min(header.len, remaining);
        if (header.level == SOL_SOCKET and header.kind == 1) {
            rights += 1;
            const data = control[offset + fd_header_len .. offset + available];
            if (data.len == 0 or data.len % @sizeOf(i32) != 0) result.valid = false;
            var i: usize = 0;
            while (i + @sizeOf(i32) <= data.len) : (i += @sizeOf(i32)) {
                const fd = std.mem.bytesToValue(i32, data[i..][0..@sizeOf(i32)]);
                if (fd < 0 or result.count == result.fds.len) {
                    result.valid = false;
                } else {
                    result.fds[result.count] = fd;
                    result.count += 1;
                }
            }
        } else {
            result.valid = false;
        }
        if (header.len > remaining) {
            result.valid = false;
            break;
        }
        // Missing final alignment padding is permitted by CMSG_NXTHDR.
        const padding = (0 -% header.len) & (@sizeOf(usize) - 1);
        if (padding > remaining - header.len) break;
        offset += header.len + padding;
    }
    result.valid = result.valid and rights == 1 and result.count == 1;
    return result;
}

// Encode only after validating the descriptor; callers retain their buffer on error.
fn encodeFdControl(control: *[24]u8, fd: isize) isize {
    if (fd < 0 or fd > std.math.maxInt(i32)) return -E.INVAL;
    control.* = @splat(0);
    const header = FdCmsg{ .len = fd_header_len + @sizeOf(i32), .level = SOL_SOCKET, .kind = 1 };
    const descriptor: i32 = @intCast(fd);
    @memcpy(control[0..fd_header_len], std.mem.asBytes(&header));
    @memcpy(control[fd_header_len..][0..4], std.mem.asBytes(&descriptor));
    return 0;
}

/// Send exactly one descriptor with a one-byte Unix socket message.
/// Returns zero on success, or negative errno; never waits for socket readiness.
pub fn sendFd(socket_fd: isize, fd: isize) isize {
    var control: [24]u8 align(@alignOf(FdCmsg)) = undefined;
    const encoded = encodeFdControl(&control, fd);
    if (encoded < 0) return encoded;
    var byte: u8 = 0;
    var iov = FdIov{ .base = p(&byte), .len = 1 };
    var msg = FdMsg{ .iov = p(&iov), .control = p(&control), .controllen = control.len };
    while (true) {
        const n = sc(.sendmsg, u(socket_fd), p(&msg), 0x40 | 0x4000, 0, 0, 0); // DONTWAIT | NOSIGNAL
        if (n == -E.INTR) continue;
        return if (n < 0) n else if (n == 1) 0 else -E.IO;
    }
}

/// Receive exactly one close-on-exec descriptor, or negative errno.
pub fn recvFd(socket_fd: isize) isize {
    var byte: u8 = 0;
    var iov = FdIov{ .base = p(&byte), .len = 1 };
    var control: [fd_control_len]u8 align(@alignOf(FdCmsg)) = undefined;
    while (true) {
        var msg = FdMsg{ .iov = p(&iov), .control = p(&control), .controllen = control.len };
        const n = sc(.recvmsg, u(socket_fd), p(&msg), 0x40 | 0x40000000, 0, 0, 0); // DONTWAIT | CMSG_CLOEXEC
        if (n == -E.INTR) continue;
        if (n < 0) return n;
        const parsed = parseFdControl(control[0..@min(msg.controllen, control.len)], msg.flags, n);
        if (parsed.valid and msg.controllen <= control.len) return parsed.fds[0];
        for (parsed.fds[0..parsed.count]) |fd| close(fd);
        return -E.IO;
    }
}

/// Nonblocking Unix socket write without SIGPIPE; retries interrupted syscalls.
pub fn sendNonblock(fd: isize, buf: []const u8) isize {
    while (true) {
        const n = sc(.sendto, u(fd), p(buf.ptr), buf.len, 0x40 | 0x4000, 0, 0);
        if (n == -E.INTR) continue;
        return n;
    }
}

pub fn bind(fd: isize, addr: *const anyopaque, len: usize) isize {
    return sc(.bind, u(fd), p(addr), len, 0, 0, 0);
}
pub fn listen(fd: isize, backlog: usize) isize {
    return sc(.listen, u(fd), backlog, 0, 0, 0, 0);
}
pub fn acceptHostVsock(listener: isize, flags: usize) isize {
    while (true) {
        const fd = sc(.accept4, u(listener), 0, 0, flags | SOCK_CLOEXEC, 0, 0);
        if (fd < 0) return fd;
        var peer: SockaddrVm = undefined;
        var len: u32 = @sizeOf(SockaddrVm);
        if (sc(.getpeername, u(fd), p(&peer), p(&len), 0, 0, 0) == 0 and peer.isHost(len)) return fd;
        close(fd);
    }
}
pub fn connect(fd: isize, addr: *const anyopaque, len: usize) isize {
    return sc(.connect, u(fd), p(addr), len, 0, 0, 0);
}
pub fn setsockopt(fd: isize, level: usize, name: usize, val: []const u8) isize {
    return sc(.setsockopt, u(fd), level, name, p(val.ptr), val.len, 0);
}
pub fn sendto(fd: isize, buf: []const u8, addr: ?*const anyopaque, alen: usize) isize {
    return sc(.sendto, u(fd), p(buf.ptr), buf.len, 0, if (addr) |a| p(a) else 0, alen);
}
pub fn recvfrom(fd: isize, buf: []u8, addr: ?*anyopaque, alen: ?*u32) isize {
    return sc(.recvfrom, u(fd), p(buf.ptr), buf.len, 0, if (addr) |a| p(a) else 0, if (alen) |a| p(a) else 0);
}
pub fn shutdown(fd: isize, how: usize) isize {
    return sc(.shutdown, u(fd), how, 0, 0, 0, 0);
}

pub const SockaddrVm = extern struct {
    family: u16 = AF_VSOCK,
    reserved: u16 = 0,
    port: u32,
    cid: u32,
    flags: u8 = 0,
    zero: [3]u8 = .{ 0, 0, 0 },

    fn isHost(self: *const SockaddrVm, len: u32) bool {
        const VMADDR_CID_HOST = 2;
        return len == @sizeOf(SockaddrVm) and self.family == AF_VSOCK and self.cid == VMADDR_CID_HOST;
    }
};

test "privileged listeners accept only complete host vsock addresses" {
    const len = @sizeOf(SockaddrVm);
    var peer = SockaddrVm{ .port = 4096, .cid = 2 };
    try std.testing.expect(peer.isHost(len));
    try std.testing.expect(!peer.isHost(len - 1));
    try std.testing.expect(!peer.isHost(len + 1));
    peer.family = AF_INET;
    try std.testing.expect(!peer.isHost(len));
    peer.family = AF_VSOCK;
    for ([_]u32{ 0, 1, 3, 0xffffffff }) |cid| {
        peer.cid = cid;
        try std.testing.expect(!peer.isHost(len));
    }
}
pub const SockaddrIn6 = extern struct {
    family: u16 = AF_INET6,
    port: u16, // network order
    flowinfo: u32 = 0,
    addr: [16]u8,
    scope: u32 = 0,
};
pub const SockaddrIn = extern struct {
    family: u16 = AF_INET,
    port: u16, // network order
    addr: [4]u8,
    zero: [8]u8 = @splat(0),
};
pub const SockaddrNl = extern struct {
    family: u16 = AF_NETLINK,
    pad: u16 = 0,
    pid: u32 = 0,
    groups: u32 = 0,
};

// epoll
pub const EpollEvent = extern struct { events: u32, data: u64 }; // aarch64: 16 bytes (only x86-64 packs it)
pub const EPOLLIN = 1;
pub const EPOLLOUT = 4;
pub const EPOLLERR = 8;
pub const EPOLLHUP = 16;
pub fn epoll_create() isize {
    return sc(.epoll_create1, O.CLOEXEC, 0, 0, 0, 0, 0);
}
pub fn epoll_add(ep: isize, fd: isize, events: u32, data: u64) isize {
    var ev = EpollEvent{ .events = events, .data = data };
    return sc(.epoll_ctl, u(ep), 1, u(fd), p(&ev), 0, 0);
}
pub fn epoll_mod(ep: isize, fd: isize, events: u32, data: u64) isize {
    var ev = EpollEvent{ .events = events, .data = data };
    return sc(.epoll_ctl, u(ep), 3, u(fd), p(&ev), 0, 0);
}
pub fn epoll_del(ep: isize, fd: isize) isize {
    var ev = EpollEvent{ .events = 0, .data = 0 };
    return sc(.epoll_ctl, u(ep), 2, u(fd), p(&ev), 0, 0);
}
pub fn epoll_wait(ep: isize, evs: []EpollEvent, timeout: i32) isize {
    return sc(.epoll_pwait, u(ep), p(evs.ptr), evs.len, @bitCast(@as(isize, timeout)), 0, 8);
}

// signals
pub fn sigprocmask(how: usize, set: u64) isize {
    var s = set;
    return sc(.rt_sigprocmask, how, p(&s), 0, 8, 0, 0);
}
pub fn signalfd(mask: u64) isize {
    var m = mask;
    return sc(.signalfd4, @bitCast(@as(isize, -1)), p(&m), 8, O.NONBLOCK | O.CLOEXEC, 0, 0);
}
pub fn kill(pid: isize, sig: usize) isize {
    return sc(.kill, u(pid), sig, 0, 0, 0, 0);
}

// processes
pub fn fork() isize {
    return sc(.clone, SIG.CHLD, 0, 0, 0, 0, 0);
}
pub fn wait4(pid: isize, status: *u32, options: usize) isize {
    return sc(.wait4, u(pid), p(status), options, 0, 0, 0);
}
pub fn exit(code: usize) noreturn {
    _ = sc(.exit_group, code, 0, 0, 0, 0, 0);
    unreachable;
}
pub fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) isize {
    return sc(.execve, p(path), p(argv), p(envp), 0, 0, 0);
}
pub fn getpid() isize {
    return sc(.getpid, 0, 0, 0, 0, 0, 0);
}
pub fn setsid() isize {
    return sc(.setsid, 0, 0, 0, 0, 0, 0);
}
pub fn setns(fd: isize, nstype: usize) isize {
    return sc(.setns, u(fd), nstype, 0, 0, 0, 0);
}
pub fn unshare(flags: usize) isize {
    return sc(.unshare, flags, 0, 0, 0, 0, 0);
}
pub fn setuid(id: u32) isize {
    return sc(.setuid, id, 0, 0, 0, 0, 0);
}
pub fn setgid(id: u32) isize {
    return sc(.setgid, id, 0, 0, 0, 0, 0);
}
pub fn setgroups(g: []const u32) isize {
    return sc(.setgroups, g.len, p(g.ptr), 0, 0, 0, 0);
}
pub fn prctl(opt: usize, a: usize, b: usize, c: usize, d: usize) isize {
    return sc(.prctl, opt, a, b, c, d, 0);
}
pub const PR_SET_NO_NEW_PRIVS = 38;
pub const PR_CAPBSET_DROP = 24;
pub const PR_CAPBSET_READ = 23;
pub const PR_SET_SECCOMP = 22;
pub const PR_SET_KEEPCAPS = 8;
pub const PR_SET_PDEATHSIG = 1;
pub fn capset(hdr: *const [2]u32, data: *const [6]u32) isize {
    return sc(.capset, p(hdr), p(data), 0, 0, 0, 0);
}
pub fn seccomp_filter(prog: *const SockFprog) isize {
    return sc(.seccomp, 1, 0, p(prog), 0, 0, 0);
}
pub const SockFilter = extern struct { code: u16, jt: u8, jf: u8, k: u32 };
pub const SockFprog = extern struct { len: u16, filter: [*]const SockFilter };

pub fn clock_ns(clk: usize) u64 {
    var ts: Timespec = undefined;
    _ = sc(.clock_gettime, clk, p(&ts), 0, 0, 0, 0);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}
pub fn realtime_ns() u64 {
    return clock_ns(0);
}
pub fn clock_set_realtime(sec: i64, nsec: i64) isize {
    const ts = Timespec{ .sec = sec, .nsec = nsec };
    return sc(.clock_settime, 0, p(&ts), 0, 0, 0, 0);
}
pub fn boottime_ns() u64 {
    return clock_ns(7);
}
pub fn sleep_ms(ms: u64) void {
    const ts = Timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
    _ = sc(.nanosleep, p(&ts), 0, 0, 0, 0, 0);
}
pub fn sync() void {
    _ = sc(.sync, 0, 0, 0, 0, 0, 0);
}
pub fn poweroff() void {
    _ = sc(.reboot, 0xfee1dead, 672274793, 0x4321fedc, 0, 0, 0);
}

pub fn mmapAnon(len: usize) ?[*]u8 {
    // PROT_READ|WRITE, MAP_PRIVATE|ANONYMOUS|NORESERVE
    const res = sc(.mmap, 0, len, 3, 0x22 | 0x4000, @bitCast(@as(isize, -1)), 0);
    if (res < 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(res)));
}
pub fn munmap(ptr: [*]u8, len: usize) void {
    _ = sc(.munmap, p(ptr), len, 0, 0, 0, 0);
}

pub fn inotify_init() isize {
    return sc(.inotify_init1, O.NONBLOCK | O.CLOEXEC, 0, 0, 0, 0, 0);
}
pub fn inotify_add(fd: isize, path: [*:0]const u8, mask: u32) isize {
    return sc(.inotify_add_watch, u(fd), p(path), mask, 0, 0, 0);
}

test "SCM_RIGHTS Linux layout and single descriptor parsing" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(FdCmsg));
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(FdMsg));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(FdMsg, "flags"));
    var control: [24]u8 = @splat(0);
    const header = FdCmsg{ .len = 20, .level = 1, .kind = 1 };
    @memcpy(control[0..16], std.mem.asBytes(&header));
    const fd: i32 = 42;
    @memcpy(control[16..20], std.mem.asBytes(&fd));
    const parsed = parseFdControl(&control, 0, 1);
    try std.testing.expect(parsed.valid);
    try std.testing.expectEqual(@as(i32, 42), parsed.fds[0]);
    try std.testing.expectEqual(@as(usize, 1), parsed.count);
    try std.testing.expect(parseFdControl(control[0..20], 0, 1).valid);
    const zero: i32 = 0;
    @memcpy(control[16..20], std.mem.asBytes(&zero));
    try std.testing.expect(parseFdControl(&control, 0, 1).valid);
    const negative: i32 = -1;
    @memcpy(control[16..20], std.mem.asBytes(&negative));
    try std.testing.expect(!parseFdControl(&control, 0, 1).valid);
}

test "SCM_RIGHTS rejects missing malformed truncated and multiple descriptors retaining cleanup list" {
    try std.testing.expect(!parseFdControl(&.{}, 0, 1).valid);
    var control: [48]u8 = @splat(0);
    var header = FdCmsg{ .len = 24, .level = 1, .kind = 1 };
    @memcpy(control[0..16], std.mem.asBytes(&header));
    const fds = [_]i32{ 40, 41 };
    @memcpy(control[16..24], std.mem.asBytes(&fds));
    var parsed = parseFdControl(control[0..24], 0, 1);
    try std.testing.expect(!parsed.valid);
    try std.testing.expectEqualSlices(i32, &fds, parsed.fds[0..parsed.count]);
    header.len = 20;
    @memcpy(control[0..16], std.mem.asBytes(&header));
    @memcpy(control[24..40], std.mem.asBytes(&header));
    @memcpy(control[40..44], std.mem.asBytes(&fds[1]));
    parsed = parseFdControl(&control, 0, 1);
    try std.testing.expect(!parsed.valid);
    try std.testing.expectEqualSlices(i32, &fds, parsed.fds[0..parsed.count]);
    for ([_]u32{ 8, 0x20 }) |flags| {
        parsed = parseFdControl(control[0..24], flags, 1);
        try std.testing.expect(!parsed.valid);
        try std.testing.expectEqual(@as(usize, 1), parsed.count);
    }
    try std.testing.expect(!parseFdControl(control[0..24], 0, 0).valid);
    header.len = 21; // Partial descriptor, but the complete descriptor still needs closing.
    @memcpy(control[0..16], std.mem.asBytes(&header));
    parsed = parseFdControl(control[0..24], 0, 1);
    try std.testing.expect(!parsed.valid);
    try std.testing.expectEqual(@as(usize, 1), parsed.count);
    header.len = 1000;
    @memcpy(control[0..16], std.mem.asBytes(&header));
    parsed = parseFdControl(control[0..24], 0, 1);
    try std.testing.expect(!parsed.valid);
    try std.testing.expectEqual(@as(usize, 2), parsed.count);
    header.len = 15;
    @memcpy(control[0..16], std.mem.asBytes(&header));
    try std.testing.expect(!parseFdControl(control[0..24], 0, 1).valid);
    header = .{ .len = 20, .level = 1, .kind = 2 };
    @memcpy(control[0..16], std.mem.asBytes(&header));
    try std.testing.expect(!parseFdControl(control[0..24], 0, 1).valid);
}

test "SCM_RIGHTS encoder produces Linux LP64 ancillary bytes including padding" {
    var control: [24]u8 = @splat(0xff);
    try std.testing.expectEqual(@as(isize, 0), encodeFdControl(&control, 0x12345678));
    const expected = [_]u8{
        0x14, 0, 0, 0, 0, 0, 0, 0, // cmsg_len = 20
        1, 0, 0, 0, // SOL_SOCKET
        1, 0, 0, 0, // SCM_RIGHTS
        0x78, 0x56, 0x34, 0x12, // descriptor
        0, 0, 0, 0, // CMSG_SPACE padding
    };
    try std.testing.expectEqualSlices(u8, &expected, &control);
}

test "SCM_RIGHTS encoder accepts fd boundaries and rejects invalid descriptors" {
    var control: [24]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 0), encodeFdControl(&control, 0));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, control[16..20]);
    try std.testing.expectEqual(@as(isize, 0), encodeFdControl(&control, 2147483647));
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xff, 0xff, 0x7f }, control[16..20]);
    for ([_]isize{ -1, std.math.minInt(isize), 2147483648, std.math.maxInt(isize) }) |fd| {
        control = @splat(0xa5);
        try std.testing.expectEqual(@as(isize, -E.INVAL), encodeFdControl(&control, fd));
        const untouched: [24]u8 = @splat(0xa5);
        try std.testing.expectEqualSlices(u8, &untouched, &control);
    }
}
