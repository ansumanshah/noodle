//! DNS wire helpers for the per-network responder. Pure, no OS dependence.
const std = @import("std");

pub const Question = struct {
    name: [255]u8 = undefined, // lowercase, dotted, no trailing dot
    name_len: usize = 0,
    qtype: u16,
    qclass: u16,
    end: usize, // offset just past the question section entry

    pub fn nameSlice(self: *const Question) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const TYPE_A: u16 = 1;
pub const TYPE_AAAA: u16 = 28;

pub fn id(pkt: []const u8) u16 {
    return std.mem.readInt(u16, pkt[0..2], .big);
}
pub fn setId(pkt: []u8, v: u16) void {
    std.mem.writeInt(u16, pkt[0..2], v, .big);
}
pub fn isQuery(pkt: []const u8) bool {
    return pkt.len >= 12 and (pkt[2] & 0xF8) == 0 and std.mem.readInt(u16, pkt[4..6], .big) >= 1;
}

/// A request with an opcode other than QUERY (status, notify, update): answered NOTIMP, never forwarded.
pub fn isNotimp(pkt: []const u8) bool {
    return pkt.len >= 12 and (pkt[2] & 0x80) == 0 and (pkt[2] & 0x78) != 0;
}

/// Header-only NOTIMP reply (12 bytes) that keeps the id, opcode and RD.
pub fn buildNotimp(out: []u8, query: []const u8) usize {
    @memset(out[0..12], 0);
    @memcpy(out[0..2], query[0..2]);
    out[2] = 0x80 | (query[2] & 0x79);
    out[3] = 0x80 | 4;
    return 12;
}

pub fn parseQuestion(pkt: []const u8) ?Question {
    if (pkt.len < 12) return null;
    var q = Question{ .qtype = 0, .qclass = 0, .end = 0 };
    var i: usize = 12;
    var n: usize = 0;
    while (true) {
        if (i >= pkt.len) return null;
        const l = pkt[i];
        if (l == 0) {
            i += 1;
            break;
        }
        if (l & 0xC0 != 0) return null; // no compression in questions
        i += 1;
        if (i + l > pkt.len) return null;
        if (n + l + 1 > q.name.len) return null;
        if (n > 0) {
            q.name[n] = '.';
            n += 1;
        }
        for (pkt[i .. i + l]) |c| {
            q.name[n] = std.ascii.toLower(c);
            n += 1;
        }
        i += l;
    }
    if (i + 4 > pkt.len) return null;
    q.name_len = n;
    q.qtype = std.mem.readInt(u16, pkt[i..][0..2], .big);
    q.qclass = std.mem.readInt(u16, pkt[i + 2 ..][0..2], .big);
    q.end = i + 4;
    return q;
}

pub fn matchesReply(pkt: []const u8, expected_id: u16, question: *const Question, sender: [4]u8, port: u16, upstream: [4]u8) bool {
    if (pkt.len < 12 or pkt[2] & 0x80 == 0 or id(pkt) != expected_id or
        port != 53 or !std.mem.eql(u8, &sender, &upstream) or
        std.mem.readInt(u16, pkt[4..6], .big) != 1) return false;
    const reply = parseQuestion(pkt) orelse return false;
    return reply.qtype == question.qtype and reply.qclass == question.qclass and
        std.mem.eql(u8, reply.nameSlice(), question.nameSlice());
}

/// Build a response to `query` into `out`. `ip` null means NOERROR with no answers (e.g. AAAA for a known name).
/// Returns the response length.
pub const max_answers = 8;

pub fn buildResponse(out: []u8, query: []const u8, q: *const Question, ip: ?[4]u8) usize {
    var one: [1][4]u8 = undefined;
    if (ip) |a| one[0] = a;
    return buildResponseMany(out, query, q, one[0..@intFromBool(ip != null)]);
}

/// One A answer per address (a name shared by several containers returns all of them).
pub fn buildResponseMany(out: []u8, query: []const u8, q: *const Question, ips: []const [4]u8) usize {
    const qlen = q.end;
    @memcpy(out[0..qlen], query[0..qlen]);
    // flags: QR=1, keep opcode, AA=1, RD copied, RA=1, rcode 0
    const rd = query[2] & 0x01;
    out[2] = 0x84 | rd;
    out[3] = 0x80;
    out[4] = 0;
    out[5] = 1; // qdcount
    out[6] = 0;
    out[7] = @intCast(ips.len);
    out[8] = 0;
    out[9] = 0;
    out[10] = 0;
    out[11] = 0;
    var n = qlen;
    for (ips) |a| {
        out[n] = 0xC0;
        out[n + 1] = 0x0C;
        std.mem.writeInt(u16, out[n + 2 ..][0..2], TYPE_A, .big);
        std.mem.writeInt(u16, out[n + 4 ..][0..2], 1, .big);
        std.mem.writeInt(u32, out[n + 6 ..][0..4], 5, .big); // ttl
        std.mem.writeInt(u16, out[n + 10 ..][0..2], 4, .big);
        @memcpy(out[n + 12 .. n + 16], &a);
        n += 16;
    }
    return n;
}

/// The same reply with an AAAA answer, or no data when the name has no IPv6 address.
pub fn buildResponse6(out: []u8, query: []const u8, q: *const Question, ip: ?[16]u8) usize {
    var one: [1][16]u8 = undefined;
    if (ip) |a| one[0] = a;
    return buildResponse6Many(out, query, q, one[0..@intFromBool(ip != null)]);
}

pub fn buildResponse6Many(out: []u8, query: []const u8, q: *const Question, ips: []const [16]u8) usize {
    var n = buildResponse(out, query, q, null);
    out[7] = @intCast(ips.len);
    for (ips) |a| {
        out[n] = 0xC0;
        out[n + 1] = 0x0C;
        std.mem.writeInt(u16, out[n + 2 ..][0..2], TYPE_AAAA, .big);
        std.mem.writeInt(u16, out[n + 4 ..][0..2], 1, .big);
        std.mem.writeInt(u32, out[n + 6 ..][0..4], 5, .big); // ttl
        std.mem.writeInt(u16, out[n + 10 ..][0..2], 16, .big);
        @memcpy(out[n + 12 .. n + 28], &a);
        n += 28;
    }
    return n;
}

/// SERVFAIL for a query we could not forward.
pub fn buildServfail(out: []u8, query: []const u8, question: *const Question) usize {
    const n = buildResponse(out, query, question, null);
    out[2] = 0x80 | (query[2] & 0x01);
    out[3] = 0x82;
    return n;
}

fn testQuery(out: []u8, transaction: u16, labels: []const []const u8, qtype: u16) []const u8 {
    @memset(out[0..12], 0);
    std.mem.writeInt(u16, out[0..2], transaction, .big);
    std.mem.writeInt(u16, out[2..4], 0x0100, .big);
    std.mem.writeInt(u16, out[4..6], 1, .big);
    var end: usize = 12;
    for (labels) |label| {
        out[end] = @intCast(label.len);
        end += 1;
        @memcpy(out[end..][0..label.len], label);
        end += label.len;
    }
    out[end] = 0;
    std.mem.writeInt(u16, out[end + 1 ..][0..2], qtype, .big);
    std.mem.writeInt(u16, out[end + 3 ..][0..2], 1, .big);
    return out[0 .. end + 5];
}

test "A response preserves its question and appends an address" {
    var request: [128]u8 = undefined;
    const pkt = testQuery(&request, 0x732b, &.{ "db", "internal" }, TYPE_A);
    const q = parseQuestion(pkt).?;
    try std.testing.expectEqualStrings("db.internal", q.nameSlice());
    try std.testing.expectEqual(TYPE_A, q.qtype);
    try std.testing.expectEqual(@as(u16, 1), q.qclass);
    try std.testing.expectEqual(pkt.len, q.end);
    try std.testing.expect(isQuery(pkt));
    try std.testing.expectEqual(@as(u16, 0x732b), id(pkt));

    var out: [128]u8 = undefined;
    const ip = [4]u8{ 10, 1, 2, 3 };
    const n = buildResponse(&out, pkt, &q, ip);
    try std.testing.expectEqual(pkt.len + 16, n);
    try std.testing.expectEqual(@as(u16, 0x732b), id(out[0..n]));
    try std.testing.expect(out[2] & 0x80 != 0);
    try std.testing.expectEqual(@as(u8, 0), out[3] & 0x0f);
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, out[6..8], .big));
    try std.testing.expectEqualSlices(u8, pkt[12..], out[12..pkt.len]);
    try std.testing.expectEqualSlices(u8, &ip, out[n - 4 .. n]);

    const none = buildResponse(&out, pkt, &q, null);
    try std.testing.expectEqual(pkt.len, none);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, out[6..8], .big));
    try std.testing.expectEqual(@as(u8, 0), out[3] & 0x0f);
}

test "AAAA response length and record fields with and without an address" {
    var request: [128]u8 = undefined;
    const pkt = testQuery(&request, 0x284f, &.{"api"}, TYPE_AAAA);
    const q = parseQuestion(pkt).?;
    try std.testing.expectEqual(TYPE_AAAA, q.qtype);
    var out: [128]u8 = undefined;
    const ip = [16]u8{ 0xfd, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2 };
    const none = buildResponse6(&out, pkt, &q, null);
    try std.testing.expectEqual(pkt.len, none);
    try std.testing.expectEqual(@as(u8, 0), out[7]);
    const n = buildResponse6(&out, pkt, &q, ip);
    try std.testing.expectEqual(pkt.len + 28, n);
    try std.testing.expectEqual(@as(u8, 1), out[7]);
    try std.testing.expectEqual(@as(u16, TYPE_AAAA), std.mem.readInt(u16, out[pkt.len + 2 ..][0..2], .big));
    try std.testing.expectEqual(@as(u16, 16), std.mem.readInt(u16, out[pkt.len + 10 ..][0..2], .big));
    try std.testing.expectEqualSlices(u8, &ip, out[n - 16 .. n]);
}

test "reply validation rejects each mismatched peer or question field" {
    var request: [128]u8 = undefined;
    const transaction: u16 = 0x691d;
    const pkt = testQuery(&request, transaction, &.{"api"}, TYPE_A);
    const q = parseQuestion(pkt).?;
    var out: [128]u8 = undefined;
    const n = buildResponse(&out, pkt, &q, .{ 1, 2, 3, 4 });
    const reply = out[0..n];
    const upstream = [4]u8{ 8, 8, 8, 8 };
    try std.testing.expect(matchesReply(reply, transaction, &q, upstream, 53, upstream));
    try std.testing.expect(!matchesReply(reply, transaction + 1, &q, upstream, 53, upstream));
    try std.testing.expect(!matchesReply(reply, transaction, &q, upstream, 54, upstream));
    try std.testing.expect(!matchesReply(reply, transaction, &q, .{ 1, 1, 1, 1 }, 53, upstream));
    out[13] = 'x';
    try std.testing.expect(!matchesReply(reply, transaction, &q, upstream, 53, upstream));
}

test "malformed questions rejected" {
    try std.testing.expect(parseQuestion(&[_]u8{ 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 5, 'a' }) == null);
    try std.testing.expect(parseQuestion(&[_]u8{ 0, 0 }) == null);
}

test "opcodes other than QUERY get NOTIMP, shared names answer with every address" {
    var buf: [512]u8 = undefined;
    const q = testQuery(&buf, 7, &.{ "web", "x" }, TYPE_A);
    try std.testing.expect(isQuery(q) and !isNotimp(q));
    var upd: [512]u8 = undefined;
    @memcpy(upd[0..q.len], q);
    upd[2] |= 0x28; // opcode 5 (UPDATE)
    try std.testing.expect(!isQuery(upd[0..q.len]) and isNotimp(upd[0..q.len]));
    var out: [64]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 12), buildNotimp(&out, upd[0..q.len]));
    try std.testing.expectEqual(@as(u8, 0x84), out[3]);
    try std.testing.expectEqual(@as(u8, 0x28), out[2] & 0x78);
    const question = parseQuestion(q).?;
    var big: [512]u8 = undefined;
    const n = buildResponseMany(&big, q, &question, &.{ .{ 10, 0, 0, 1 }, .{ 10, 0, 0, 2 } });
    try std.testing.expectEqual(question.end + 32, n);
    try std.testing.expectEqual(@as(u8, 2), big[7]);
}
