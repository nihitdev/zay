const std = @import("std");
const r = @import("resolver.zig");
const Record = r.Record;
const Fixture = struct {
    installed: []const Record = &.{},
    repo: []const Record = &.{},
    aur: []const Record = &.{},
    calls: usize = 0,
    fn fetch(ctx: *anyopaque, name: []const u8, providers: bool) ![]const Record {
        const self: *Fixture = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (providers) return self.aur;
        for (self.aur, 0..) |p, i| if (std.mem.eql(u8, name, p.name)) return self.aur[i..][0..1];
        return &.{};
    }
    fn graph(self: *Fixture, a: std.mem.Allocator) r.Graph {
        return .{ .a = a, .catalog = .{ .installed = self.installed, .repositories = self.repo, .context = self, .fetch = fetch } };
    }
};
fn pkg(source: r.Source, name: []const u8) Record {
    return .{ .name = name, .base = name, .version = "1", .source = source };
}
fn expectOrder(g: *r.Graph, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, g.order.items.len);
    for (expected, g.order.items) |name, i| try std.testing.expectEqualStrings(name, g.builds.items[i].base);
}

test "repository preference and installed provider version satisfaction" {
    var root = pkg(.repo, "app");
    root.depends = &.{"virtual>=2"};
    var installed = pkg(.installed, "implementation");
    installed.provides = &.{"virtual=2"};
    var f: Fixture = .{ .repo = &.{root}, .installed = &.{installed}, .aur = &.{pkg(.aur, "app")} };
    var g = f.graph(std.testing.allocator);
    defer g.deinit();
    try g.plan(&.{"app"});
    try std.testing.expectEqual(@as(usize, 0), f.calls);
    try std.testing.expectEqual(@as(usize, 2), g.nodes.items.len);
    try std.testing.expect(g.nodes.items[1].package.source == .installed);
}
test "older installed dependency selects repository upgrade" {
    var app = pkg(.aur, "app");
    app.depends = &.{"lib>=2"};
    var lib = pkg(.repo, "lib");
    lib.version = "2";
    var f: Fixture = .{ .installed = &.{pkg(.installed, "lib")}, .repo = &.{lib}, .aur = &.{app} };
    var g = f.graph(std.testing.allocator);
    defer g.deinit();
    try g.plan(&.{"app"});
    try std.testing.expect(g.nodes.items[1].package.source == .repo);
}
test "split runtime outputs share one build with union of make/check dependencies" {
    var one = pkg(.aur, "one");
    one.base = "split";
    one.depends = &.{"two"};
    one.make_depends = &.{"compiler"};
    var two = pkg(.aur, "two");
    two.base = "split";
    two.check_depends = &.{"tests"};
    var final = pkg(.aur, "final");
    final.depends = &.{"one"};
    var f: Fixture = .{ .aur = &.{ one, two, final, pkg(.aur, "compiler"), pkg(.aur, "tests") } };
    var g = f.graph(std.testing.allocator);
    defer g.deinit();
    try g.plan(&.{"final"});
    try expectOrder(&g, &.{ "compiler", "tests", "split", "final" });
    var make = false;
    var check = false;
    for (g.edges.items) |edge| {
        make = make or edge.kind == .make;
        check = check or edge.kind == .check;
    }
    try std.testing.expect(make and check);
    try std.testing.expectEqual(@as(usize, 2), g.builds.items[g.order.items[2]].packages.items.len);
}
test "deterministic root order and duplicate targets" {
    var f: Fixture = .{ .aur = &.{ pkg(.aur, "a"), pkg(.aur, "z") } };
    var g = f.graph(std.testing.allocator);
    defer g.deinit();
    try g.plan(&.{ "z", "a", "z" });
    try expectOrder(&g, &.{ "a", "z" });
    try std.testing.expectEqual(@as(usize, 2), g.nodes.items.len);
}
test "AUR cycle fails but repository transaction cycles are valid" {
    var a = pkg(.aur, "a");
    a.depends = &.{"b"};
    var b = pkg(.aur, "b");
    b.depends = &.{"a"};
    var f: Fixture = .{ .aur = &.{ a, b } };
    var g = f.graph(std.testing.allocator);
    defer g.deinit();
    try std.testing.expectError(error.DependencyCycle, g.plan(&.{"a"}));
    a.source = .repo;
    b.source = .repo;
    var rf: Fixture = .{ .repo = &.{ a, b } };
    var rg = rf.graph(std.testing.allocator);
    defer rg.deinit();
    try rg.plan(&.{"a"});
    try std.testing.expectEqual(@as(usize, 2), rg.nodes.items.len);
}
test "same-base make dependency fails rather than guessing a bootstrap" {
    var a = pkg(.aur, "a");
    a.base = "split";
    a.make_depends = &.{"b"};
    var b = pkg(.aur, "b");
    b.base = "split";
    var f: Fixture = .{ .aur = &.{ a, b } };
    var g = f.graph(std.testing.allocator);
    defer g.deinit();
    try std.testing.expectError(error.SplitBuildDependency, g.plan(&.{"a"}));
}
test "unique AUR virtual provider and explicit provider avoid menus" {
    var app = pkg(.aur, "app");
    app.depends = &.{"virtual>=2"};
    var provider = pkg(.aur, "impl");
    provider.provides = &.{"virtual=2"};
    var f: Fixture = .{ .aur = &.{ app, provider } };
    var g = f.graph(std.testing.allocator);
    defer g.deinit();
    try g.plan(&.{"app"});
    try expectOrder(&g, &.{ "impl", "app" });
    var other = pkg(.aur, "other");
    other.provides = &.{"virtual=2"};
    var multiple: Fixture = .{ .aur = &.{ app, provider, other } };
    var ambiguous = multiple.graph(std.testing.allocator);
    defer ambiguous.deinit();
    try std.testing.expectError(error.AmbiguousProvider, ambiguous.plan(&.{"app"}));
    var chosen = multiple.graph(std.testing.allocator);
    defer chosen.deinit();
    try chosen.plan(&.{ "app", "impl" });
    try expectOrder(&chosen, &.{ "impl", "app" });
}
test "conflicts against retained installed packages and replacements fail closed" {
    var app = pkg(.aur, "app");
    app.conflicts = &.{"other>=1"};
    var f: Fixture = .{ .installed = &.{pkg(.installed, "other")}, .aur = &.{app} };
    var g = f.graph(std.testing.allocator);
    defer g.deinit();
    try std.testing.expectError(error.PackageConflict, g.plan(&.{"app"}));
    app.conflicts = &.{};
    app.replaces = &.{"other"};
    var rf: Fixture = .{ .installed = f.installed, .aur = &.{app} };
    var rg = rf.graph(std.testing.allocator);
    defer rg.deinit();
    try std.testing.expectError(error.ReplacementRequired, rg.plan(&.{"app"}));
}
test "ignore rules, unsatisfied constraints and missing dependencies" {
    var ignored = pkg(.repo, "ignored");
    ignored.ignored = true;
    var f: Fixture = .{ .repo = &.{ ignored, pkg(.repo, "old") } };
    var g = f.graph(std.testing.allocator);
    defer g.deinit();
    try std.testing.expectError(error.IgnoredPackage, g.plan(&.{"ignored"}));
    var version = f.graph(std.testing.allocator);
    defer version.deinit();
    try std.testing.expectError(error.VersionUnavailable, version.plan(&.{"old>=2"}));
    var missing = f.graph(std.testing.allocator);
    defer missing.deinit();
    try std.testing.expectError(error.DependencyNotFound, missing.plan(&.{"absent"}));
}
test "incompatible repeated dependency requirements are rejected" {
    var app = pkg(.aur, "app");
    app.depends = &.{ "lib<2", "lib>=2" };
    var f: Fixture = .{ .aur = &.{app}, .repo = &.{pkg(.repo, "lib")} };
    var g = f.graph(std.testing.allocator);
    defer g.deinit();
    try std.testing.expectError(error.ConstraintConflict, g.plan(&.{"app"}));
}
fn allocationScenario(a: std.mem.Allocator) !void {
    var app = pkg(.aur, "app");
    app.depends = &.{"lib>=1"};
    var f: Fixture = .{ .aur = &.{ app, pkg(.aur, "lib") } };
    var g = f.graph(a);
    defer g.deinit();
    try g.plan(&.{"app"});
}
test "partial graph allocation failures clean up all graph storage" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationScenario, .{});
}

test "repository upgrade cannot break a retained installed consumer" {
    var consumer = pkg(.installed, "consumer");
    consumer.depends = &.{"lib<2"};
    var newer = pkg(.repo, "lib");
    newer.version = "2";
    var f: Fixture = .{ .installed = &.{ pkg(.installed, "lib"), consumer }, .repo = &.{newer} };
    var g = f.graph(std.testing.allocator);
    defer g.deinit();
    try std.testing.expectError(error.BreaksInstalledDependency, g.plan(&.{"lib"}));
}
test "explicit repository name wins over a selected AUR provision" {
    var provider = pkg(.aur, "a-provider");
    provider.provides = &.{"real"};
    var f: Fixture = .{ .repo = &.{pkg(.repo, "real")}, .aur = &.{provider} };
    var g = f.graph(std.testing.allocator);
    defer g.deinit();
    try g.plan(&.{ "a-provider", "real" });
    try std.testing.expectEqual(@as(usize, 2), g.nodes.items.len);
    try std.testing.expect(g.nodes.items[1].package.source == .repo);
}

test "explicit provider is honored even when virtual root sorts first" {
    var one = pkg(.repo, "provider-one");
    one.provides = &.{"aaa-virtual"};
    var two = pkg(.repo, "provider-two");
    two.provides = &.{"aaa-virtual"};
    var f: Fixture = .{ .repo = &.{ one, two } };
    var g = f.graph(std.testing.allocator);
    defer g.deinit();
    try g.plan(&.{ "aaa-virtual", "provider-two" });
    try std.testing.expectEqual(@as(usize, 1), g.nodes.items.len);
    try std.testing.expectEqualStrings("provider-two", g.nodes.items[0].package.name);
}
