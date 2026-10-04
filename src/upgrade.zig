const std = @import("std");
const alpm = @import("alpm.zig").c;
const package = @import("package.zig");
const Package = package.Package;
const aur = @import("aur.zig");

pub const Installed = struct {
    name: []const u8,
    version: []const u8,
};

pub const Query = struct {
    context: *anyopaque,
    info: *const fn (*anyopaque, []const []const u8) anyerror!aur.Response,
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

/// Parse pacman's foreign-package inventory, query AUR info in bounded batches,
/// and return owned, sorted update targets. The query callback keeps this path
/// deterministic in tests without changing the production RPC endpoint.
pub fn discover(a: std.mem.Allocator, foreign_output: []const u8, query: Query) ![][]const u8 {
    const installed = try parseForeign(a, foreign_output);
    defer a.free(installed);
    if (installed.len == 0) return a.alloc([]const u8, 0);

    var sorted: std.ArrayList([]const u8) = .empty;
    defer sorted.deinit(a);
    for (installed) |pkg| try sorted.append(a, pkg.name);
    std.mem.sort([]const u8, sorted.items, {}, lessName);

    var updates: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (updates.items) |name| a.free(name);
        updates.deinit(a);
    }
    var start: usize = 0;
    while (start < sorted.items.len) : (start += @min(50, sorted.items.len - start)) {
        const batch = sorted.items[start..@min(start + 50, sorted.items.len)];
        const response = try query.info(query.context, batch);
        defer response.deinit();
        const remote = try a.alloc(Package, response.count());
        defer a.free(remote);
        for (remote, 0..) |*pkg, i| pkg.* = response.get(i);
        const local = try a.alloc(Installed, batch.len);
        defer a.free(local);
        for (batch, 0..) |name, i| {
            local[i] = for (installed) |pkg| {
                if (std.mem.eql(u8, pkg.name, name)) break pkg;
            } else return error.MalformedPacmanOutput;
        }
        const batch_updates = try outdatedNames(a, local, remote);
        defer {
            for (batch_updates) |name| a.free(name);
            a.free(batch_updates);
        }
        for (batch_updates) |name| try updates.append(a, try a.dupe(u8, name));
    }
    std.mem.sort([]const u8, updates.items, {}, lessName);
    return updates.toOwnedSlice(a);
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
    const newer = testPackage("demo", "1:2.10-1");
    const same = testPackage("demo", "1:2.9-1");
    const older = testPackage("demo", "1:2.8-1");
    try std.testing.expect(try isOutdated(a, local, newer));
    try std.testing.expect(!try isOutdated(a, local, same));
    try std.testing.expect(!try isOutdated(a, local, older));
    try std.testing.expect(!try isOutdated(a, local, testPackage("other", "9-1")));
}

test "outdated AUR targets are matched exactly and returned deterministically" {
    const a = std.testing.allocator;
    const installed = [_]Installed{
        .{ .name = "zulu", .version = "1-1" },
        .{ .name = "alpha", .version = "2-1" },
        .{ .name = "local-only", .version = "4-1" },
    };
    const remote = [_]Package{
        testPackage("zulu", "2-1"),
        testPackage("alpha", "2-1"),
        testPackage("other", "99-1"),
        testPackage("zulu", "2-1"),
    };
    const names = try outdatedNames(a, &installed, &remote);
    defer {
        for (names) |name| a.free(name);
        a.free(names);
    }
    try std.testing.expectEqual(@as(usize, 1), names.len);
    try std.testing.expectEqualStrings("zulu", names[0]);
}

fn testPackage(name: []const u8, version: []const u8) Package {
    return .{
        .name = name,
        .base = name,
        .version = version,
        .description = null,
        .url = null,
        .maintainer = null,
        .votes = 0,
        .popularity = 0,
        .out_of_date = null,
        .depends = &.{},
        .make_depends = &.{},
        .check_depends = &.{},
        .provides = &.{},
    };
}

const MockRpc = struct {
    a: std.mem.Allocator,
    calls: usize = 0,
    asked: [50][]const u8 = undefined,
    asked_count: usize = 0,
    fail: bool = false,

    fn info(context: *anyopaque, terms: []const []const u8) anyerror!aur.Response {
        const self: *MockRpc = @ptrCast(@alignCast(context));
        self.calls += 1;
        if (terms.len > self.asked.len) return error.TooManyMockTerms;
        @memcpy(self.asked[0..terms.len], terms);
        self.asked_count = terms.len;
        if (self.fail) return error.MockRpcFailure;
        return aur.parse(self.a,
            \\{"version":5,"type":"multiinfo","resultcount":2,"results":[
            \\{"Name":"demo","PackageBase":"demo-base","Version":"2-1"},
            \\{"Name":"same","PackageBase":"same","Version":"4-1"}]}
        , .info);
    }
};

test "offline AUR update discovery batches foreign packages and matches exact names" {
    const a = std.testing.allocator;
    var rpc: MockRpc = .{ .a = a };
    const targets = try discover(a, "same 4-1\ndemo 1-1\nlocal-only 3-1\n", .{ .context = &rpc, .info = MockRpc.info });
    defer {
        for (targets) |name| a.free(name);
        a.free(targets);
    }
    try std.testing.expectEqual(@as(usize, 1), targets.len);
    try std.testing.expectEqualStrings("demo", targets[0]);
    try std.testing.expectEqual(@as(usize, 1), rpc.calls);
    try std.testing.expectEqual(@as(usize, 3), rpc.asked_count);
    try std.testing.expectEqualStrings("demo", rpc.asked[0]);
    try std.testing.expectEqualStrings("local-only", rpc.asked[1]);
    try std.testing.expectEqualStrings("same", rpc.asked[2]);
}

test "offline AUR update discovery propagates RPC failures without partial targets" {
    const a = std.testing.allocator;
    var rpc: MockRpc = .{ .a = a, .fail = true };
    try std.testing.expectError(error.MockRpcFailure, discover(a, "demo 1-1\n", .{ .context = &rpc, .info = MockRpc.info }));
    try std.testing.expectEqual(@as(usize, 1), rpc.calls);
}
