//! Default seccomp filter. Pure: builds classic-BPF instructions, no OS dependence.
//! A capability-gated aarch64 denylist, not a reproduction of Docker's syscall allowlist.
//! AF_VSOCK sockets are always forbidden to protect the guest control channel.
const std = @import("std");
const Sys = std.os.linux.syscalls.Arm64;

pub const Insn = extern struct { code: u16, jt: u8, jf: u8, k: u32 };

const AUDIT_ARCH_AARCH64: u32 = 0xC00000B7;
const BPF_LD_W_ABS: u16 = 0x20;
const BPF_JEQ_K: u16 = 0x15;
const BPF_RET_K: u16 = 0x06;
const BPF_JSET_K: u16 = 0x45;
pub const RET_ALLOW: u32 = 0x7fff0000;
pub const RET_KILL: u32 = 0x80000000;
fn retErrno(e: u32) u32 {
    return 0x00050000 | e;
}

pub const CAP_SYS_MODULE = 16;
pub const CAP_SYS_PACCT = 20;
pub const CAP_SYS_PTRACE = 19;
pub const CAP_SYS_ADMIN = 21;
pub const CAP_SYS_BOOT = 22;
pub const CAP_SYS_NICE = 23;
pub const CAP_SYS_TIME = 25;
pub const CAP_SYS_TTY_CONFIG = 26;
const always = 0xff;

const Rule = struct { nr: u32, cap: u8 };
fn r(comptime s: Sys, cap: u8) Rule {
    return .{ .nr = @intFromEnum(s), .cap = cap };
}

const rules = [_]Rule{
    r(.kexec_load, CAP_SYS_BOOT),
    r(.kexec_file_load, CAP_SYS_BOOT),
    r(.reboot, CAP_SYS_BOOT),
    r(.init_module, CAP_SYS_MODULE),
    r(.finit_module, CAP_SYS_MODULE),
    r(.delete_module, CAP_SYS_MODULE),
    r(.acct, CAP_SYS_PACCT),
    r(.settimeofday, CAP_SYS_TIME),
    r(.clock_settime, CAP_SYS_TIME),
    r(.clock_adjtime, CAP_SYS_TIME),
    r(.adjtimex, CAP_SYS_TIME),
    r(.vhangup, CAP_SYS_TTY_CONFIG),
    r(.process_vm_readv, CAP_SYS_PTRACE),
    r(.process_vm_writev, CAP_SYS_PTRACE),
    r(.kcmp, CAP_SYS_PTRACE),
    r(.mbind, CAP_SYS_NICE),
    r(.set_mempolicy, CAP_SYS_NICE),
    r(.migrate_pages, CAP_SYS_NICE),
    r(.move_pages, CAP_SYS_NICE),
    r(.mount, CAP_SYS_ADMIN),
    r(.umount2, CAP_SYS_ADMIN),
    r(.pivot_root, CAP_SYS_ADMIN),
    r(.setns, CAP_SYS_ADMIN),
    r(.unshare, CAP_SYS_ADMIN),
    r(.sethostname, CAP_SYS_ADMIN),
    r(.setdomainname, CAP_SYS_ADMIN),
    r(.swapon, CAP_SYS_ADMIN),
    r(.swapoff, CAP_SYS_ADMIN),
    r(.quotactl, CAP_SYS_ADMIN),
    r(.syslog, CAP_SYS_ADMIN),
    r(.bpf, CAP_SYS_ADMIN),
    r(.perf_event_open, CAP_SYS_ADMIN),
    r(.lookup_dcookie, CAP_SYS_ADMIN),
    r(.fsopen, CAP_SYS_ADMIN),
    r(.fsconfig, CAP_SYS_ADMIN),
    r(.fsmount, CAP_SYS_ADMIN),
    r(.fspick, CAP_SYS_ADMIN),
    r(.open_tree, CAP_SYS_ADMIN),
    r(.move_mount, CAP_SYS_ADMIN),
    r(.mount_setattr, CAP_SYS_ADMIN),
    r(.open_by_handle_at, CAP_SYS_ADMIN),
    r(.name_to_handle_at, CAP_SYS_ADMIN),
    r(.fanotify_init, CAP_SYS_ADMIN),
    r(.pidfd_getfd, CAP_SYS_PTRACE),
    r(.add_key, always),
    r(.keyctl, always),
    r(.request_key, always),
    r(.userfaultfd, always),
    r(.mknodat, always),
};

pub const max_insns = rules.len + 24;

fn ins(code: u16, jt: u8, jf: u8, k: u32) Insn {
    return .{ .code = code, .jt = jt, .jf = jf, .k = k };
}

/// Build the filter. `caps` is a bitmask of the capabilities the container holds.
/// Returns the number of instructions written to `out` (len >= max_insns).
pub fn build(out: []Insn, caps: u64, unconfined: bool) usize {
    var n: usize = 0;
    // arch check: wrong arch -> kill
    out[n] = ins(BPF_LD_W_ABS, 0, 0, 4);
    n += 1;
    out[n] = ins(BPF_JEQ_K, 1, 0, AUDIT_ARCH_AARCH64);
    n += 1;
    out[n] = ins(BPF_RET_K, 0, 0, RET_KILL);
    n += 1;
    out[n] = ins(BPF_LD_W_ABS, 0, 0, 0); // syscall nr
    n += 1;

    // Even the builder must not create sockets through IORING_OP_SOCKET.
    out[n] = ins(BPF_JEQ_K, 0, 1, @intFromEnum(Sys.io_uring_setup));
    n += 1;
    out[n] = ins(BPF_RET_K, 0, 0, retErrno(1));
    n += 1;

    const gate_ns = !unconfined and (caps >> CAP_SYS_ADMIN) & 1 == 0; // namespace-creating clone variants
    var active: usize = 0;
    if (!unconfined) {
        for (rules) |rl| {
            if (rl.cap == always or (caps >> @intCast(rl.cap)) & 1 == 0) active += 1;
        }
    }
    // tail layout (offsets from the first tail instruction):
    //   [clone3 ENOSYS: 1][clone NEWUSER check: 4]  (only when gate_ns)
    //   socket check: 3, then ALLOW, EPERM, EAFNOSUPPORT, ENOSYS
    const ns_len: usize = if (gate_ns) 5 else 0;
    const tail = n + active;
    const allow_idx = tail + ns_len + 3;
    const eperm_idx = allow_idx + 1;
    const eafnosupport_idx = allow_idx + 2;
    const enosys_idx = allow_idx + 3;

    if (!unconfined) {
        for (rules) |rl| {
            if (!(rl.cap == always or (caps >> @intCast(rl.cap)) & 1 == 0)) continue;
            out[n] = ins(BPF_JEQ_K, @intCast(eperm_idx - n - 1), 0, rl.nr);
            n += 1;
        }
    }
    if (gate_ns) {
        // clone3 hides its flags in a struct seccomp cannot inspect: report ENOSYS so libc falls back to clone
        out[n] = ins(BPF_JEQ_K, @intCast(enosys_idx - n - 1), 0, @intFromEnum(Sys.clone3));
        n += 1;
        out[n] = ins(BPF_JEQ_K, 0, 3, @intFromEnum(Sys.clone)); // not clone: skip to the socket check
        n += 1;
        out[n] = ins(BPF_LD_W_ABS, 0, 0, 16); // clone flags
        n += 1;
        out[n] = ins(BPF_JSET_K, @intCast(eperm_idx - n - 1), 0, 0x10000000); // CLONE_NEWUSER
        n += 1;
        out[n] = ins(BPF_LD_W_ABS, 0, 0, 0); // reload nr
        n += 1;
    }
    return finishTail(out, n, allow_idx, eafnosupport_idx);
}

fn finishTail(out: []Insn, n_in: usize, allow_idx: usize, eafnosupport_idx: usize) usize {
    var n = n_in;
    // socket(AF_VSOCK, ...) -> EAFNOSUPPORT
    out[n] = ins(BPF_JEQ_K, 0, 2, @intFromEnum(Sys.socket)); // not socket: skip ld+jeq to ALLOW
    n += 1;
    out[n] = ins(BPF_LD_W_ABS, 0, 0, 16); // arg0 low word
    n += 1;
    out[n] = ins(BPF_JEQ_K, @intCast(eafnosupport_idx - n - 1), 0, 40); // AF_VSOCK
    n += 1;
    std.debug.assert(n == allow_idx);
    out[n] = ins(BPF_RET_K, 0, 0, RET_ALLOW);
    n += 1;
    out[n] = ins(BPF_RET_K, 0, 0, retErrno(1)); // EPERM
    n += 1;
    out[n] = ins(BPF_RET_K, 0, 0, retErrno(97)); // EAFNOSUPPORT
    n += 1;
    out[n] = ins(BPF_RET_K, 0, 0, retErrno(38)); // ENOSYS
    n += 1;
    return n;
}

/// Tiny interpreter used only by tests to check the generated program.
fn run(prog: []const Insn, arch: u32, nr: u32, arg0: u32) u32 {
    var a: u32 = 0;
    var pc: usize = 0;
    while (pc < prog.len) {
        const x = prog[pc];
        switch (x.code) {
            BPF_LD_W_ABS => {
                a = switch (x.k) {
                    0 => nr,
                    4 => arch,
                    16 => arg0,
                    else => unreachable,
                };
                pc += 1;
            },
            BPF_JEQ_K => pc += 1 + @as(usize, if (a == x.k) x.jt else x.jf),
            BPF_JSET_K => pc += 1 + @as(usize, if (a & x.k != 0) x.jt else x.jf),
            BPF_RET_K => return x.k,
            else => unreachable,
        }
    }
    unreachable;
}

/// Workload-VM filter for unconfined containers: allow everything except open_by_handle_at, which
/// CAP_DAC_READ_SEARCH would turn into access to any file on the data disk. name_to_handle_at stays (systemd).
pub fn buildHandleDeny(out: []Insn) usize {
    out[0] = ins(BPF_LD_W_ABS, 0, 0, 4);
    out[1] = ins(BPF_JEQ_K, 1, 0, AUDIT_ARCH_AARCH64);
    out[2] = ins(BPF_RET_K, 0, 0, RET_KILL);
    out[3] = ins(BPF_LD_W_ABS, 0, 0, 0);
    out[4] = ins(BPF_JEQ_K, 0, 1, @intFromEnum(Sys.open_by_handle_at));
    out[5] = ins(BPF_RET_K, 0, 0, retErrno(1));
    out[6] = ins(BPF_RET_K, 0, 0, RET_ALLOW);
    return 7;
}

test "handle-deny filter blocks only open_by_handle_at" {
    var buf: [max_insns]Insn = undefined;
    const prog = buf[0..buildHandleDeny(&buf)];
    try std.testing.expectEqual(retErrno(1), run(prog, AUDIT_ARCH_AARCH64, @intFromEnum(Sys.open_by_handle_at), 0));
    try std.testing.expectEqual(RET_ALLOW, run(prog, AUDIT_ARCH_AARCH64, @intFromEnum(Sys.name_to_handle_at), 0));
    try std.testing.expectEqual(RET_ALLOW, run(prog, AUDIT_ARCH_AARCH64, @intFromEnum(Sys.io_uring_setup), 0));
}

test "denies gated syscalls, allows when cap held, always blocks vsock" {
    var buf: [max_insns]Insn = undefined;
    const n = build(&buf, 0, false);
    const prog = buf[0..n];
    const mount_nr: u32 = @intFromEnum(Sys.mount);
    const read_nr: u32 = @intFromEnum(Sys.read);
    const sock_nr: u32 = @intFromEnum(Sys.socket);
    try std.testing.expectEqual(retErrno(1), run(prog, AUDIT_ARCH_AARCH64, mount_nr, 0));
    try std.testing.expectEqual(RET_ALLOW, run(prog, AUDIT_ARCH_AARCH64, read_nr, 0));
    try std.testing.expectEqual(RET_KILL, run(prog, 0x1234, read_nr, 0));
    try std.testing.expectEqual(RET_ALLOW, run(prog, AUDIT_ARCH_AARCH64, sock_nr, 2));
    try std.testing.expectEqual(retErrno(97), run(prog, AUDIT_ARCH_AARCH64, sock_nr, 40));
    try std.testing.expectEqual(retErrno(1), run(prog, AUDIT_ARCH_AARCH64, @intFromEnum(Sys.keyctl), 0));
    try std.testing.expectEqual(retErrno(1), run(prog, AUDIT_ARCH_AARCH64, @intFromEnum(Sys.io_uring_setup), 0));
    try std.testing.expectEqual(retErrno(1), run(prog, AUDIT_ARCH_AARCH64, @intFromEnum(Sys.mknodat), 0));

    // namespace-creating clone variants are refused without SYS_ADMIN
    try std.testing.expectEqual(retErrno(38), run(prog, AUDIT_ARCH_AARCH64, @intFromEnum(Sys.clone3), 0));
    try std.testing.expectEqual(retErrno(1), run(prog, AUDIT_ARCH_AARCH64, @intFromEnum(Sys.clone), 0x10000000));
    try std.testing.expectEqual(RET_ALLOW, run(prog, AUDIT_ARCH_AARCH64, @intFromEnum(Sys.clone), 0x11));
    try std.testing.expectEqual(retErrno(97), run(prog, AUDIT_ARCH_AARCH64, sock_nr, 40));

    const n2 = build(&buf, @as(u64, 1) << CAP_SYS_ADMIN, false);
    try std.testing.expectEqual(RET_ALLOW, run(buf[0..n2], AUDIT_ARCH_AARCH64, mount_nr, 0));
    try std.testing.expectEqual(retErrno(1), run(buf[0..n2], AUDIT_ARCH_AARCH64, @intFromEnum(Sys.keyctl), 0));

    const n3 = build(&buf, 0, true);
    try std.testing.expectEqual(retErrno(1), run(buf[0..n3], AUDIT_ARCH_AARCH64, @intFromEnum(Sys.io_uring_setup), 0));
    try std.testing.expectEqual(RET_ALLOW, run(buf[0..n3], AUDIT_ARCH_AARCH64, @intFromEnum(Sys.mknodat), 0));
    try std.testing.expectEqual(RET_ALLOW, run(buf[0..n3], AUDIT_ARCH_AARCH64, mount_nr, 0));
    try std.testing.expectEqual(retErrno(97), run(buf[0..n3], AUDIT_ARCH_AARCH64, sock_nr, 40));
}
