const std = @import("std");
const alpm = @import("alpm.zig").c;
const package = @import("package.zig");
const Package = package.Package;
const aur = @import("aur.zig");

pub const Installed = struct {
    name: []const u8,
    version: []const u8,
};

/// Parsed entries borrow the pacman output; the caller must retain it while
/// using the returned records.
pub fn parseForeign(a: std.mem.Allocator, text: []const u8) ![]Installed {
    var packages: std.ArrayList(Installed) = .empty;
    errdefer packages.deinit(a);
    var seen = std.StringHashMap(void).init(a);
    defer seen.deinit();
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t\r");
        const name = fields.next() orelse return error.MalformedPacmanOutput;
        const version = fields.next() orelse return error.MalformedPacmanOutput;
        if (!aur.validName(name) or !package.validVersion(version) or fields.next() != null)
            return error.MalformedPacmanOutput;
        const entry = try seen.getOrPut(name);
        if (entry.found_existing) return error.MalformedPacmanOutput;
        try packages.append(a, .{ .name = name, .version = version });
    }
    return packages.toOwnedSlice(a);
}

pub fn isOutdated(a: std.mem.Allocator, installed: Installed, remote: Package) !bool {
    if (!std.mem.eql(u8, installed.name, remote.name)) return false;
    const local_z = try a.dupeZ(u8, installed.version);
    defer a.free(local_z);
    const remote_z = try a.dupeZ(u8, remote.version);
    defer a.free(remote_z);
    return alpm.alpm_pkg_vercmp(local_z, remote_z) < 0;
}

/// Return a sorted, owned list of installed package names with newer RPC
/// versions. Names not present in the AUR response are intentionally omitted.
pub fn outdatedNames(a: std.mem.Allocator, installed: []const Installed, remote: []const Package) ![][]const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (result.items) |name| a.free(name);
        result.deinit(a);
    }
    var seen = std.StringHashMap(void).init(a);
    defer seen.deinit();
    for (remote) |candidate| {
        for (installed) |local| {
            if (!try isOutdated(a, local, candidate)) continue;
            const entry = try seen.getOrPut(candidate.name);
            if (!entry.found_existing) try result.append(a, try a.dupe(u8, candidate.name));
            break;
        }
    }
    std.mem.sort([]const u8, result.items, {}, lessName);
    return result.toOwnedSlice(a);
}

pub fn lessName(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

test "parse foreign package inventory strictly and reject duplicate names" {
    const packages = try parseForeign(std.testing.allocator, "foo 1:2.0-1\nbar 3-2\n");
    defer std.testing.allocator.free(packages);
    try std.testing.expectEqual(@as(usize, 2), packages.len);
    try std.testing.expectEqualStrings("foo", packages[0].name);
    try std.testing.expectEqualStrings("1:2.0-1", packages[0].version);
    try std.testing.expectError(error.MalformedPacmanOutput, parseForeign(std.testing.allocator, "foo bad version extra\n"));
    try std.testing.expectError(error.MalformedPacmanOutput, parseForeign(std.testing.allocator, "foo 1-1\nfoo 2-1\n"));
}

test "AUR update detection uses Arch version comparison" {
    const a = std.testing.allocator;
    const local: Installed = .{ .name = "demo", .version = "1:2.9-1" };
    const newer: Package = .{ .name = "demo", .base = "demo", .version = "1:2.10-1" };
    const same: Package = .{ .name = "demo", .base = "demo", .version = "1:2.9-1" };
    const older: Package = .{ .name = "demo", .base = "demo", .version = "1:2.8-1" };
    try std.testing.expect(try isOutdated(a, local, newer));
    try std.testing.expect(!try isOutdated(a, local, same));
    try std.testing.expect(!try isOutdated(a, local, older));
    try std.testing.expect(!try isOutdated(a, local, .{ .name = "other", .base = "other", .version = "9-1" }));
}

test "outdated AUR targets are matched exactly and returned deterministically" {
    const a = std.testing.allocator;
    const installed = [_]Installed{
        .{ .name = "zulu", .version = "1-1" },
        .{ .name = "alpha", .version = "2-1" },
        .{ .name = "local-only", .version = "4-1" },
    };
    const remote = [_]Package{
        .{ .name = "zulu", .base = "zulu", .version = "2-1" },
        .{ .name = "alpha", .base = "alpha", .version = "2-1" },
        .{ .name = "other", .base = "other", .version = "99-1" },
        .{ .name = "zulu", .base = "zulu", .version = "2-1" },
    };
    const names = try outdatedNames(a, &installed, &remote);
    defer {
        for (names) |name| a.free(name);
        a.free(names);
    }
    try std.testing.expectEqual(@as(usize, 1), names.len);
    try std.testing.expectEqualStrings("zulu", names[0]);
}
