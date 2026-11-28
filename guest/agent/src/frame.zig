//! Wire framing shared by the control and stream ports. Pure, no OS dependence.
const std = @import("std");

pub const max_frame: u32 = 16 * 1024 * 1024;

pub const Kind = struct {
    pub const stdin: u8 = 0;
    pub const stdout: u8 = 1;
    pub const stderr: u8 = 2;
    pub const exit: u8 = 3;
    pub const stdin_eof: u8 = 4;
    pub const resize: u8 = 5;
};

pub fn putU32(buf: []u8, v: u32) void {
    std.mem.writeInt(u32, buf[0..4], v, .big);
}
pub fn getU32(buf: []const u8) u32 {
    return std.mem.readInt(u32, buf[0..4], .big);
}

/// Control-style frame header: u32 length (big endian).
pub fn encodeHeader(len: u32) [4]u8 {
    var h: [4]u8 = undefined;
    putU32(&h, len);
    return h;
}

/// Multiplexed body frame header: u8 kind, u32 length.
pub fn encodeMux(kind: u8, len: u32) [5]u8 {
    var h: [5]u8 = undefined;
    h[0] = kind;
    putU32(h[1..], len);
    return h;
}

pub const MuxHeader = struct { kind: u8, len: u32 };
pub fn decodeMux(h: *const [5]u8) MuxHeader {
    return .{ .kind = h[0], .len = getU32(h[1..]) };
}

/// Incremental decoder for length-prefixed frames out of a byte stream (used by the
/// non-blocking control connection). Feed bytes, pull complete frames.
pub const Assembler = struct {
    buf: []u8,
    len: usize = 0,

    pub fn init(buf: []u8) Assembler {
        return .{ .buf = buf };
    }
    /// Free space to read into.
    pub fn space(self: *Assembler) []u8 {
        return self.buf[self.len..];
    }
    pub fn commit(self: *Assembler, n: usize) void {
        self.len += n;
    }
    pub const Err = error{FrameTooLarge};
    /// Returns the next complete frame payload (valid until `consume`), or null.
    pub fn peekFrame(self: *Assembler) Err!?[]const u8 {
        if (self.len < 4) return null;
        const n = getU32(self.buf[0..4]);
        if (n > max_frame or n + 4 > self.buf.len) return error.FrameTooLarge;
        if (self.len < 4 + n) return null;
        return self.buf[4 .. 4 + n];
    }
    /// Drop the frame returned by peekFrame.
    pub fn consume(self: *Assembler) void {
        const n = getU32(self.buf[0..4]);
        const total = 4 + n;
        std.mem.copyForwards(u8, self.buf[0 .. self.len - total], self.buf[total..self.len]);
        self.len -= total;
    }
};

test "header roundtrip" {
    const h = encodeHeader(0x01020304);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, &h);
    try std.testing.expectEqual(@as(u32, 0x01020304), getU32(&h));
}

test "mux roundtrip" {
    const h = encodeMux(Kind.stderr, 513);
    const d = decodeMux(&h);
    try std.testing.expectEqual(@as(u8, 2), d.kind);
    try std.testing.expectEqual(@as(u32, 513), d.len);
}

test "assembler splits and reassembles" {
    var storage: [64]u8 = undefined;
    var a = Assembler.init(&storage);
    const msg = "{\"id\":1,\"op\":\"ping\"}";
    var wire: [4 + msg.len + 4 + 2]u8 = undefined;
    putU32(wire[0..4], msg.len);
    @memcpy(wire[4 .. 4 + msg.len], msg);
    putU32(wire[4 + msg.len ..][0..4], 2);
    @memcpy(wire[4 + msg.len + 4 ..], "{}");
    // feed in awkward chunks
    var fed: usize = 0;
    var frames: usize = 0;
    while (fed < wire.len) {
        const n = @min(5, wire.len - fed);
        @memcpy(a.space()[0..n], wire[fed .. fed + n]);
        a.commit(n);
        fed += n;
        while (try a.peekFrame()) |f| {
            frames += 1;
            if (frames == 1) try std.testing.expectEqualStrings(msg, f) else try std.testing.expectEqualStrings("{}", f);
            a.consume();
        }
    }
    try std.testing.expectEqual(@as(usize, 2), frames);
}

test "assembler rejects oversize" {
    var storage: [16]u8 = undefined;
    var a = Assembler.init(&storage);
    putU32(a.space()[0..4], 100);
    a.commit(4);
    try std.testing.expectError(error.FrameTooLarge, a.peekFrame());
}
