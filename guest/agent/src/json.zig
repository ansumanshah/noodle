//! Minimal JSON: arena-parsed tree, and a growing byte buffer with JSON emit helpers.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Member = struct { key: []const u8, val: Value };

pub const Value = union(enum) {
    null,
    bool: bool,
    int: i64,
    float: f64,
    str: []const u8,
    arr: []const Value,
    obj: []const Member,

    pub fn get(self: Value, key: []const u8) ?Value {
        if (self != .obj) return null;
        for (self.obj) |m| if (std.mem.eql(u8, m.key, key)) return m.val;
        return null;
    }
    pub fn str_(self: Value, key: []const u8) ?[]const u8 {
        const v = self.get(key) orelse return null;
        return if (v == .str) v.str else null;
    }
    pub fn strOr(self: Value, key: []const u8, def: []const u8) []const u8 {
        return self.str_(key) orelse def;
    }
    pub fn int_(self: Value, key: []const u8) ?i64 {
        const v = self.get(key) orelse return null;
        return switch (v) {
            .int => |i| i,
            .float => |f| if (std.math.isFinite(f) and f >= -9.2e18 and f <= 9.2e18) @as(i64, @intFromFloat(f)) else null,
            else => null,
        };
    }
    pub fn intOr(self: Value, key: []const u8, def: i64) i64 {
        return self.int_(key) orelse def;
    }
    pub fn boolOr(self: Value, key: []const u8, def: bool) bool {
        const v = self.get(key) orelse return def;
        return switch (v) {
            .bool => |b| b,
            .int => |i| i != 0,
            else => def,
        };
    }
    pub fn floatOr(self: Value, key: []const u8, def: f64) f64 {
        const v = self.get(key) orelse return def;
        return switch (v) {
            .float => |f| f,
            .int => |i| @floatFromInt(i),
            else => def,
        };
    }
    pub fn list(self: Value, key: []const u8) []const Value {
        const v = self.get(key) orelse return &.{};
        return if (v == .arr) v.arr else &.{};
    }
};

pub const ParseError = error{ Syntax, OutOfMemory, TooDeep };

pub fn parse(a: Allocator, text: []const u8) ParseError!Value {
    var p = Parser{ .a = a, .s = text, .i = 0 };
    p.ws();
    const v = try p.value(0);
    p.ws();
    if (p.i != p.s.len) return error.Syntax;
    return v;
}

const Parser = struct {
    a: Allocator,
    s: []const u8,
    i: usize,

    fn ws(p: *Parser) void {
        while (p.i < p.s.len and (p.s[p.i] == ' ' or p.s[p.i] == '\n' or p.s[p.i] == '\t' or p.s[p.i] == '\r')) p.i += 1;
    }
    fn value(p: *Parser, depth: u32) ParseError!Value {
        if (depth > 64) return error.TooDeep;
        if (p.i >= p.s.len) return error.Syntax;
        switch (p.s[p.i]) {
            '{' => {
                p.i += 1;
                var items: std.ArrayList(Member) = .empty;
                p.ws();
                if (p.peek() == '}') {
                    p.i += 1;
                    return .{ .obj = &.{} };
                }
                while (true) {
                    p.ws();
                    if (p.peek() != '"') return error.Syntax;
                    const k = try p.string();
                    p.ws();
                    if (p.peek() != ':') return error.Syntax;
                    p.i += 1;
                    p.ws();
                    const v = try p.value(depth + 1);
                    try items.append(p.a, .{ .key = k, .val = v });
                    p.ws();
                    const c = p.peek();
                    p.i += 1;
                    if (c == ',') continue;
                    if (c == '}') break;
                    return error.Syntax;
                }
                return .{ .obj = items.items };
            },
            '[' => {
                p.i += 1;
                var items: std.ArrayList(Value) = .empty;
                p.ws();
                if (p.peek() == ']') {
                    p.i += 1;
                    return .{ .arr = &.{} };
                }
                while (true) {
                    p.ws();
                    const v = try p.value(depth + 1);
                    try items.append(p.a, v);
                    p.ws();
                    const c = p.peek();
                    p.i += 1;
                    if (c == ',') continue;
                    if (c == ']') break;
                    return error.Syntax;
                }
                return .{ .arr = items.items };
            },
            '"' => return .{ .str = try p.string() },
            't' => return p.lit("true", .{ .bool = true }),
            'f' => return p.lit("false", .{ .bool = false }),
            'n' => return p.lit("null", .null),
            else => return p.number(),
        }
    }
    fn peek(p: *Parser) u8 {
        return if (p.i < p.s.len) p.s[p.i] else 0;
    }
    fn lit(p: *Parser, word: []const u8, v: Value) ParseError!Value {
        if (!std.mem.startsWith(u8, p.s[p.i..], word)) return error.Syntax;
        p.i += word.len;
        return v;
    }
    fn number(p: *Parser) ParseError!Value {
        const start = p.i;
        var is_float = false;
        while (p.i < p.s.len) : (p.i += 1) {
            switch (p.s[p.i]) {
                '0'...'9', '-', '+' => {},
                '.', 'e', 'E' => is_float = true,
                else => break,
            }
        }
        if (p.i == start) return error.Syntax;
        const t = p.s[start..p.i];
        if (!is_float) {
            if (std.fmt.parseInt(i64, t, 10)) |n| return .{ .int = n } else |_| {}
        }
        const f = std.fmt.parseFloat(f64, t) catch return error.Syntax;
        return .{ .float = f };
    }
    fn string(p: *Parser) ParseError![]const u8 {
        p.i += 1; // opening quote
        const start = p.i;
        // fast path: no escapes
        while (p.i < p.s.len and p.s[p.i] != '"' and p.s[p.i] != '\\') p.i += 1;
        if (p.i >= p.s.len) return error.Syntax;
        if (p.s[p.i] == '"') {
            const out = p.s[start..p.i];
            p.i += 1;
            return out;
        }
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(p.a, p.s[start..p.i]);
        while (p.i < p.s.len) {
            const c = p.s[p.i];
            if (c == '"') {
                p.i += 1;
                return out.items;
            }
            if (c != '\\') {
                try out.append(p.a, c);
                p.i += 1;
                continue;
            }
            p.i += 1;
            if (p.i >= p.s.len) return error.Syntax;
            const e = p.s[p.i];
            p.i += 1;
            switch (e) {
                '"', '\\', '/' => try out.append(p.a, e),
                'b' => try out.append(p.a, 8),
                'f' => try out.append(p.a, 12),
                'n' => try out.append(p.a, '\n'),
                'r' => try out.append(p.a, '\r'),
                't' => try out.append(p.a, '\t'),
                'u' => {
                    var cp = try p.hex4();
                    if (cp >= 0xD800 and cp < 0xDC00 and p.i + 1 < p.s.len and p.s[p.i] == '\\' and p.s[p.i + 1] == 'u') {
                        p.i += 2;
                        const lo = try p.hex4();
                        if (lo >= 0xDC00 and lo < 0xE000) cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00) else return error.Syntax;
                    }
                    var tmp: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(@intCast(cp), &tmp) catch return error.Syntax;
                    try out.appendSlice(p.a, tmp[0..n]);
                },
                else => return error.Syntax,
            }
        }
        return error.Syntax;
    }
    fn hex4(p: *Parser) ParseError!u32 {
        if (p.i + 4 > p.s.len) return error.Syntax;
        const v = std.fmt.parseInt(u32, p.s[p.i .. p.i + 4], 16) catch return error.Syntax;
        p.i += 4;
        return v;
    }
};

/// Growing byte buffer with JSON writing helpers.
pub const Buf = struct {
    a: Allocator,
    list: std.ArrayList(u8) = .empty,

    pub fn init(a: Allocator) Buf {
        return .{ .a = a };
    }
    pub fn bytes(self: *const Buf) []const u8 {
        return self.list.items;
    }
    pub fn raw(self: *Buf, s: []const u8) !void {
        try self.list.appendSlice(self.a, s);
    }
    pub fn byte(self: *Buf, c: u8) !void {
        try self.list.append(self.a, c);
    }
    pub fn print(self: *Buf, comptime fmt: []const u8, args: anytype) !void {
        var tmp: [128]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, fmt, args) catch return error.OutOfMemory;
        try self.raw(s);
    }
    pub fn int(self: *Buf, v: anytype) !void {
        try self.print("{d}", .{v});
    }
    pub fn str(self: *Buf, s: []const u8) !void {
        try self.byte('"');
        for (s) |c| switch (c) {
            '"' => try self.raw("\\\""),
            '\\' => try self.raw("\\\\"),
            '\n' => try self.raw("\\n"),
            '\r' => try self.raw("\\r"),
            '\t' => try self.raw("\\t"),
            0...8, 11, 12, 14...31 => try self.print("\\u{x:0>4}", .{c}),
            else => try self.byte(c),
        };
        try self.byte('"');
    }
    pub fn key(self: *Buf, k: []const u8) !void {
        try self.str(k);
        try self.byte(':');
    }
};

test "parse object with nesting and escapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(),
        \\{"id":7,"op":"create","spec":{"argv":["a","b\n\u00e9"],"tty":true,"cpus":1.5,"neg":-3},"n":null}
    );
    try std.testing.expectEqual(@as(i64, 7), v.intOr("id", 0));
    try std.testing.expectEqualStrings("create", v.strOr("op", ""));
    const spec = v.get("spec").?;
    try std.testing.expect(spec.boolOr("tty", false));
    try std.testing.expectEqual(@as(f64, 1.5), spec.floatOr("cpus", 0));
    try std.testing.expectEqual(@as(i64, -3), spec.intOr("neg", 0));
    const argv = spec.list("argv");
    try std.testing.expectEqual(@as(usize, 2), argv.len);
    try std.testing.expectEqualStrings("b\n\xc3\xa9", argv[1].str);
    try std.testing.expect(v.get("n").? == .null);
}

test "huge or non-finite floats do not trap int_" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(), "{\"a\":1e300,\"b\":-1e300,\"c\":3.0}");
    try std.testing.expectEqual(@as(?i64, null), v.int_("a"));
    try std.testing.expectEqual(@as(?i64, null), v.int_("b"));
    try std.testing.expectEqual(@as(?i64, 3), v.int_("c"));
}

test "parse errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.Syntax, parse(arena.allocator(), "{\"a\":}"));
    try std.testing.expectError(error.Syntax, parse(arena.allocator(), "[1,2"));
    try std.testing.expectError(error.Syntax, parse(arena.allocator(), "{} x"));
}

test "buf emits escaped json" {
    var b = Buf.init(std.testing.allocator);
    defer b.list.deinit(std.testing.allocator);
    try b.byte('{');
    try b.key("error");
    try b.str("a\"b\\c\n\x01");
    try b.byte('}');
    try std.testing.expectEqualStrings("{\"error\":\"a\\\"b\\\\c\\n\\u0001\"}", b.bytes());
}
