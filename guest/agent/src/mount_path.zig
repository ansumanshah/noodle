const std = @import("std");

pub fn valid(path: []const u8) bool {
    if (path.len == 0 or path[0] != '/' or std.mem.indexOfScalar(u8, path, 0) != null) return false;
    var parts = std.mem.tokenizeScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

/// `/mnt/host/k<24 hex><r|w>` (a folder the host shared), optionally followed by one file name.
pub fn validShare(src: []const u8) bool {
    const prefix = "/mnt/host/";
    if (!std.mem.startsWith(u8, src, prefix)) return false;
    const rest = src[prefix.len..];
    if (!validKey(rest[0..@min(rest.len, key_len)])) return false;
    if (rest.len == key_len) return true;
    if (rest[key_len] != '/' or rest.len <= key_len + 1) return false;
    const name = rest[key_len + 1 ..];
    return !std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..") and
        std.mem.indexOfScalar(u8, name, '/') == null and std.mem.indexOfScalar(u8, name, 0) == null;
}

pub const key_len = 26;

pub fn validKey(k: []const u8) bool {
    if (k.len != key_len or k[0] != 'k' or (k[key_len - 1] != 'r' and k[key_len - 1] != 'w')) return false;
    for (k[1 .. key_len - 1]) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    return true;
}

test "mount targets reject traversal and embedded NUL" {
    try std.testing.expect(valid("/etc/hosts"));
    try std.testing.expect(valid("/"));
    try std.testing.expect(!valid("relative"));
    try std.testing.expect(!valid("/etc/../host"));
    try std.testing.expect(!valid("/etc/./host"));
    try std.testing.expect(!valid("/etc/hosts\x00/escape"));
}

test "bind sources must be a registered share key, optionally with one file name" {
    const k = "/mnt/host/k0123456789abcdef01234567w";
    try std.testing.expect(validShare(k));
    try std.testing.expect(validShare(k ++ "/file name"));
    try std.testing.expect(validShare("/mnt/host/k0123456789abcdef01234567r/f"));
    try std.testing.expect(!validShare(k ++ "/"));
    try std.testing.expect(!validShare(k ++ "/.."));
    try std.testing.expect(!validShare(k ++ "/a/b"));
    try std.testing.expect(!validShare(k ++ "/file\x00name"));
    try std.testing.expect(!validShare(k ++ "/../secret"));
    try std.testing.expect(!validShare("/mnt/host"));
    try std.testing.expect(!validShare("/mnt/host/"));
    try std.testing.expect(!validShare("/mnt/host/k0123456789abcdef01234567x"));
    try std.testing.expect(!validShare("/mnt/host/k0123456789ABCDEF01234567w"));
    try std.testing.expect(!validShare("/mnt/host/k0123456789abcdef0123456w"));
    try std.testing.expect(!validShare("/mnt/host/sabcd_2"));
    try std.testing.expect(!validShare("/mnt/hostk0123456789abcdef01234567w"));
}
