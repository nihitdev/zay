const std = @import("std");
const dependency = @import("dependency.zig");
const Dependency = dependency.Dependency;
pub const Source = enum { installed, repo, aur };
/// All strings borrow the catalog's lifetime. Graph storage owns only nodes/edges.
pub const Record = struct {
    name: []const u8,
    version: []const u8,
    base: []const u8 = "",
    repository: []const u8 = "",
    source: Source,
    depends: []const []const u8 = &.{},
    make_depends: []const []const u8 = &.{},
    check_depends: []const []const u8 = &.{},
    provides: []const []const u8 = &.{},
    conflicts: []const []const u8 = &.{},
    replaces: []const []const u8 = &.{},
    ignored: bool = false,
    pub fn satisfies(self: Record, a: std.mem.Allocator, dep: Dependency) !bool {
        return dep.satisfiedBy(a, self.name, self.version, self.provides);
    }
};
pub const Catalog = struct {
    installed: []const Record,
    repositories: []const Record,
    build_environment: []const []const u8 = &.{},
    context: *anyopaque,
    // Returned records stay valid until the catalog is destroyed. Exact info and
    // provider queries are cached by the catalog, not recursively by the resolver.
    fetch: *const fn (*anyopaque, []const u8, bool) anyerror![]const Record,
};
pub const Node = struct { package: Record, explicit: bool = false };
pub const Edge = struct { from: usize, to: usize, kind: dependency.Kind, requirement: []const u8 };
pub const Build = struct { base: []const u8, packages: std.ArrayList(usize) = .empty };
pub const Graph = struct {
    a: std.mem.Allocator,
    catalog: Catalog,
    nodes: std.ArrayList(Node) = .empty,
    edges: std.ArrayList(Edge) = .empty,
    builds: std.ArrayList(Build) = .empty,
    order: std.ArrayList(usize) = .empty,
    // Useful, bounded diagnostics without turning implementation details into UI.
    problem: []const u8 = "",
    related: []const u8 = "",
    requested: []const []const u8 = &.{},

    pub fn deinit(self: *Graph) void {
        for (self.builds.items) |*b| b.packages.deinit(self.a);
        self.builds.deinit(self.a);
        self.nodes.deinit(self.a);
        self.edges.deinit(self.a);
        self.order.deinit(self.a);
    }
    fn findName(self: *Graph, name: []const u8) ?usize {
        for (self.nodes.items, 0..) |n, i| if (std.mem.eql(u8, n.package.name, name)) return i;
        return null;
    }
    fn choose(self: *Graph, records: []const Record, dep: Dependency) !?Record {
        // Repository order is supplied by pacman-conf; never prefer a lower
        // priority repository's newer version of the same package name.
        for (records) |p| {
            if (std.mem.eql(u8, p.name, dep.name)) {
                if (try p.satisfies(self.a, dep)) return p;
                if (p.source != .installed) return error.VersionUnavailable;
            }
        }
        var candidate: ?Record = null;
        var ambiguous = false;
        var preferred: ?Record = null;
        var preferred_ambiguous = false;
        for (records) |p| {
            if (!try p.satisfies(self.a, dep)) continue;
            for (self.requested) |target| {
                if (std.mem.eql(u8, (try Dependency.parse(target)).name, p.name)) {
                    if (preferred) |prior| {
                        if (!std.mem.eql(u8, prior.name, p.name)) preferred_ambiguous = true;
                    } else preferred = p;
                }
            }
            if (candidate) |prior| {
                if (std.mem.eql(u8, prior.name, p.name)) continue;
                if (p.source != .installed) ambiguous = true;
                if (std.mem.lessThan(u8, p.name, prior.name)) candidate = p;
            } else candidate = p;
        }
        if (preferred_ambiguous) return error.AmbiguousProvider;
        if (preferred) |p| return p;
        if (ambiguous) return error.AmbiguousProvider;
        return candidate;
    }
    fn add(self: *Graph, p: Record, explicit: bool) !usize {
        if (p.ignored and p.source != .installed) return error.IgnoredPackage;
        if (self.findName(p.name)) |id| {
            if (!std.mem.eql(u8, self.nodes.items[id].package.version, p.version) or self.nodes.items[id].package.source != p.source)
                return error.ConstraintConflict;
            self.nodes.items[id].explicit = self.nodes.items[id].explicit or explicit;
            return id;
        }
        if (self.nodes.items.len >= 4096) return error.ResolutionLimit;
        try self.nodes.append(self.a, .{ .package = p, .explicit = explicit });
        return self.nodes.items.len - 1;
    }
    fn resolve(self: *Graph, text: []const u8, explicit: bool, allow_aur: bool) !usize {
        self.problem = text;
        const dep = try Dependency.parse(text);
        if (explicit) {
            for (self.catalog.repositories) |p| {
                if (std.mem.eql(u8, p.name, dep.name)) {
                    if (!try p.satisfies(self.a, dep)) return error.VersionUnavailable;
                    return self.add(p, true);
                }
            }
        }
        // Explicit targets are selected before traversal, so their providers are
        // available without prompting while resolving dependencies.
        for (self.nodes.items, 0..) |n, i| {
            if (try n.package.satisfies(self.a, dep)) {
                if (explicit) self.nodes.items[i].explicit = true;
                return i;
            }
        }
        if (self.findName(dep.name) != null) return error.ConstraintConflict;
        if (!explicit) {
            // An older installed version is not an error: try repository/AUR next.
            const installed = self.choose(self.catalog.installed, dep) catch |err| switch (err) {
                error.VersionUnavailable => null,
                else => return err,
            };
            if (installed) |p| {
                if (self.findName(p.name) == null) return self.add(p, false);
            }
        }
        if (try self.choose(self.catalog.repositories, dep)) |p| return self.add(p, explicit);
        if (!allow_aur) return error.RepositoryDependencyUnavailable;
        const exact = try self.catalog.fetch(self.catalog.context, dep.name, false);
        if (try self.choose(exact, dep)) |p| return self.add(p, explicit);
        const providers = try self.catalog.fetch(self.catalog.context, dep.name, true);
        if (try self.choose(providers, dep)) |p| return self.add(p, explicit);
        return error.DependencyNotFound;
    }
    pub fn plan(self: *Graph, targets: []const []const u8) !void {
        self.requested = targets;
        defer self.requested = &.{};
        const sorted = try self.a.dupe([]const u8, targets);
        defer self.a.free(sorted);
        std.mem.sort([]const u8, sorted, {}, lessText);
        for (sorted) |target| _ = try self.resolve(target, true, true);
        var i: usize = 0;
        while (i < self.nodes.items.len) : (i += 1) {
            const p = self.nodes.items[i].package;
            if (p.source == .installed) continue;
            try self.expand(i, p.depends, .runtime);
            if (p.source == .aur) {
                try self.expand(i, self.catalog.build_environment, .make);
                try self.expand(i, p.make_depends, .make);
                try self.expand(i, p.check_depends, .check);
            }
        }
        try self.checkConflicts();
        try self.checkReverseDependencies();
        try self.buildOrder();
        self.problem = "";
        self.related = "";
    }
    fn expand(self: *Graph, from: usize, requirements: []const []const u8, kind: dependency.Kind) !void {
        const sorted = try self.a.dupe([]const u8, requirements);
        defer self.a.free(sorted);
        std.mem.sort([]const u8, sorted, {}, lessText);
        for (sorted) |text| {
            self.related = self.nodes.items[from].package.name;
            const to = try self.resolve(text, false, self.nodes.items[from].package.source == .aur);
            if (self.nodes.items[from].package.source == .repo and self.nodes.items[to].package.source == .aur)
                return error.RepositoryDependencyUnavailable;
            try self.edges.append(self.a, .{ .from = from, .to = to, .kind = kind, .requirement = text });
        }
    }
    fn conflicts(self: *Graph, p: Record, other: Record) !void {
        if (std.mem.eql(u8, p.name, other.name)) return;
        for (p.conflicts) |text| {
            if (try other.satisfies(self.a, try Dependency.parse(text))) {
                self.problem = p.name;
                self.related = other.name;
                return error.PackageConflict;
            }
        }
        // Replacements require a transaction decision, never silent removals.
        for (p.replaces) |text| {
            if (try other.satisfies(self.a, try Dependency.parse(text))) {
                self.problem = p.name;
                self.related = other.name;
                return error.ReplacementRequired;
            }
        }
    }
    fn checkConflicts(self: *Graph) !void {
        for (self.nodes.items) |n| {
            const p = n.package;
            if (p.source == .installed) continue;
            for (self.nodes.items) |other| try self.conflicts(p, other.package);
            for (self.catalog.installed) |installed| {
                if (self.findName(installed.name)) |id| if (self.nodes.items[id].package.source != .installed) continue;
                try self.conflicts(p, installed);
                try self.conflicts(installed, p);
            }
        }
    }
    fn buildIndex(self: *Graph, name: []const u8) usize {
        for (self.builds.items, 0..) |b, i| if (std.mem.eql(u8, b.base, name)) return i;
        unreachable;
    }
    fn effectiveSatisfies(self: *Graph, dep: Dependency) !bool {
        for (self.nodes.items) |n| if (try n.package.satisfies(self.a, dep)) return true;
        for (self.catalog.installed) |p| {
            if (self.findName(p.name)) |id| if (self.nodes.items[id].package.source != .installed) continue;
            if (try p.satisfies(self.a, dep)) return true;
        }
        return false;
    }
    fn checkReverseDependencies(self: *Graph) !void {
        for (self.nodes.items) |n| {
            if (n.package.source == .installed) continue;
            for (self.catalog.installed) |old| {
                if (!std.mem.eql(u8, old.name, n.package.name)) continue;
                for (self.catalog.installed) |consumer| {
                    if (self.findName(consumer.name)) |id| if (self.nodes.items[id].package.source != .installed) continue;
                    for (consumer.depends) |text| {
                        const dep = try Dependency.parse(text);
                        if (try old.satisfies(self.a, dep) and !try self.effectiveSatisfies(dep)) {
                            self.problem = text;
                            self.related = consumer.name;
                            return error.BreaksInstalledDependency;
                        }
                    }
                }
            }
        }
    }
    fn buildOrder(self: *Graph) !void {
        for (self.nodes.items, 0..) |n, i| {
            const p = n.package;
            if (p.source != .aur) continue;
            var found = false;
            for (self.builds.items) |*b| {
                if (std.mem.eql(u8, b.base, p.base)) {
                    // Inconsistent split metadata cannot describe one build.
                    if (!std.mem.eql(u8, self.nodes.items[b.packages.items[0]].package.version, p.version)) return error.SplitVersionMismatch;
                    try b.packages.append(self.a, i);
                    found = true;
                    break;
                }
            }
            if (!found) {
                try self.builds.append(self.a, .{ .base = p.base });
                try self.builds.items[self.builds.items.len - 1].packages.append(self.a, i);
            }
        }
        const done = try self.a.alloc(bool, self.builds.items.len);
        defer self.a.free(done);
        @memset(done, false);
        while (self.order.items.len < done.len) {
            var best: ?usize = null;
            for (self.builds.items, 0..) |b, i| {
                if (done[i]) continue;
                var ready = true;
                for (self.edges.items) |edge| {
                    const from = self.nodes.items[edge.from].package;
                    const to = self.nodes.items[edge.to].package;
                    if (from.source != .aur or to.source != .aur or !std.mem.eql(u8, from.base, b.base)) continue;
                    if (std.mem.eql(u8, from.base, to.base)) {
                        // Runtime dependencies between split outputs do not need a
                        // pre-existing artifact. Build/check dependencies do.
                        if (edge.kind != .runtime) {
                            self.problem = from.base;
                            self.related = edge.requirement;
                            return error.SplitBuildDependency;
                        }
                        continue;
                    }
                    if (!done[self.buildIndex(to.base)]) {
                        ready = false;
                        break;
                    }
                }
                if (ready and (best == null or std.mem.lessThan(u8, b.base, self.builds.items[best.?].base))) best = i;
            }
            const next = best orelse {
                for (done, 0..) |finished, i| if (!finished) {
                    self.problem = self.builds.items[i].base;
                    break;
                };
                self.related = "";
                return error.DependencyCycle;
            };
            done[next] = true;
            try self.order.append(self.a, next);
        }
    }
};
fn lessText(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
