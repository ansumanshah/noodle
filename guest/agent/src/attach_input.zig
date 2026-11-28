//! Stdin forwarding is independent of the attach connection's output lifetime.
const std = @import("std");
const sys = @import("sys.zig");

pub const Input = struct {
    const State = enum { disabled, waiting, ready };
    state: State,

    pub fn init(want_stdin: bool, tty: bool) Input {
        return .{ .state = if (!want_stdin) .disabled else if (tty) .waiting else .ready };
    }

    pub fn waiting(self: Input) bool {
        return self.state == .waiting;
    }

    pub fn forwarding(self: Input) bool {
        return self.state == .ready;
    }

    /// A failed or absent master closes only stdin, never the attach session.
    pub fn masterResult(self: *Input, fd: isize) void {
        if (self.state != .waiting or fd == -sys.E.AGAIN) return;
        self.state = if (fd >= 0) .ready else .disabled;
    }

    pub fn writeResult(self: *Input, result: isize) void {
        if (result < 0) self.stop();
    }

    pub fn stop(self: *Input) void {
        self.state = .disabled;
    }
};

/// Non-blocking write of `data` to `fd` (after anything already queued). Unwritten bytes stay in
/// `pending` so the caller can wait for POLLOUT. Returns false when the peer is gone (pending cleared).
pub fn writeQueued(fd: isize, pending: *std.ArrayList(u8), alloc: std.mem.Allocator, data: []const u8) bool {
    if (data.len > 0) pending.appendSlice(alloc, data) catch return false;
    var off: usize = 0;
    var ok = true;
    while (off < pending.items.len) {
        const n = sys.write(fd, pending.items[off..]);
        if (n == -sys.E.INTR) continue;
        if (n == -sys.E.AGAIN) break;
        if (n <= 0) {
            ok = false;
            break;
        }
        off += @intCast(n);
    }
    if (!ok) {
        pending.clearRetainingCapacity();
        return false;
    }
    const rem = pending.items.len - off;
    if (off > 0) std.mem.copyForwards(u8, pending.items[0..rem], pending.items[off..]);
    pending.shrinkRetainingCapacity(rem);
    return true;
}

test "closed stdin stops forwarding for pipes and PTYs without requiring session teardown" {
    var pipe = Input.init(true, false);
    try std.testing.expect(pipe.forwarding());
    pipe.writeResult(-sys.E.PIPE);
    try std.testing.expect(!pipe.forwarding());
    try std.testing.expect(!pipe.waiting());

    var tty = Input.init(true, true);
    tty.masterResult(42);
    try std.testing.expect(tty.forwarding());
    tty.writeResult(-sys.E.IO);
    try std.testing.expect(!tty.forwarding());
    try std.testing.expect(!tty.waiting());
}

test "master unavailable discards buffered input while retry preserves it" {
    var input = Input.init(true, true);
    input.masterResult(-sys.E.AGAIN);
    try std.testing.expect(input.waiting());
    input.masterResult(-sys.E.IO);
    try std.testing.expect(!input.waiting());
    try std.testing.expect(!input.forwarding());
    input.masterResult(42);
    try std.testing.expect(!input.forwarding());
}

test "disabled input and output-only attach cannot be reopened by a late master" {
    var input = Input.init(true, true);
    input.stop();
    input.masterResult(42);
    try std.testing.expect(!input.waiting());
    try std.testing.expect(!input.forwarding());
    var output_only = Input.init(false, true);
    output_only.masterResult(42);
    try std.testing.expect(!output_only.forwarding());
}
