const std = @import("std");
const c = @import("alpm.zig").c;
pub const Kind = enum { runtime, make, check };
pub const Operator = enum { any, eq, ge, le, gt, lt };
pub const Dependency = struct {
    name: []const u8,
    op: Operator = .any,
    version: []const u8 = "",

    pub fn parse(text: []const u8) !Dependency {
        const end = std.mem.indexOfAny(u8, text, "<>=") orelse text.len;
        if (!@import("aur.zig").validName(text[0..end])) return error.InvalidDependency;
        if (end == text.len) return .{ .name = text };
        var start = end + 1;
        const equal = start < text.len and text[start] == '=';
        if (equal) start += 1;
        if (text[end] == '=' and equal) return error.InvalidDependency;
        const version = text[start..];
        if (!@import("package.zig").validVersion(version)) return error.InvalidDependency;
        return .{ .name = text[0..end], .version = version, .op = switch (text[end]) {
            '=' => .eq,
            '>' => if (equal) .ge else .gt,
            '<' => if (equal) .le else .lt,
            else => unreachable,
        } };
    }

    pub fn accepts(self: Dependency, a: std.mem.Allocator, version: []const u8) !bool {
        if (self.op == .any) return true;
        const lhs = try a.dupeZ(u8, version);
        defer a.free(lhs);
        const rhs = try a.dupeZ(u8, self.version);
        defer a.free(rhs);
        const order = c.alpm_pkg_vercmp(lhs, rhs);
        return switch (self.op) {
            .any => true,
            .eq => order == 0,
            .ge => order >= 0,
            .le => order <= 0,
            .gt => order > 0,
            .lt => order < 0,
        };
    }

    pub fn satisfiedBy(self: Dependency, a: std.mem.Allocator, name: []const u8, version: []const u8, provides: []const []const u8) !bool {
        if (std.mem.eql(u8, self.name, name) and try self.accepts(a, version)) return true;
        for (provides) |text| {
            const provide = try Dependency.parse(text);
            if (provide.op != .any and provide.op != .eq) return error.InvalidProvision;
            if (!std.mem.eql(u8, self.name, provide.name)) continue;
            if (self.op == .any) return true;
            // A versionless virtual provision cannot satisfy a version constraint.
            if (provide.op == .eq and try self.accepts(a, provide.version)) return true;
        }
        return false;
    }
};

test "dependency syntax and invalid constraints" {
    for ([_][]const u8{ "foo", "foo>=2", "foo<=2", "foo=2", "foo>2", "foo<2", "foo=1:2.0-3" }) |text| {
        const d = try Dependency.parse(text);
        try std.testing.expectEqualStrings("foo", d.name);
    }
    for ([_][]const u8{ "", "foo>=", "foo==2", "foo=>2", "foo 2", "foo!=2", "foo>=2<3", "repo/foo", "foo=2\n" }) |text|
        try std.testing.expectError(error.InvalidDependency, Dependency.parse(text));
}
test "Arch versions and versioned provides" {
    const a = std.testing.allocator;
    try std.testing.expect(try (try Dependency.parse("foo>=2")).accepts(a, "10"));
    try std.testing.expect(try (try Dependency.parse("foo>9:99")).accepts(a, "10:1"));
    try std.testing.expect(try (try Dependency.parse("foo=1.0")).accepts(a, "1.0-5"));
    const d = try Dependency.parse("virtual>=2");
    try std.testing.expect(!try d.satisfiedBy(a, "impl", "10", &.{"virtual"}));
    try std.testing.expect(try d.satisfiedBy(a, "impl", "1", &.{"virtual=2"}));
    try std.testing.expect(!try d.satisfiedBy(a, "impl", "100", &.{"virtual=1"}));
}
