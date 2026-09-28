const std = @import("std");
const aur = @import("aur.zig");
const catalog = @import("catalog.zig");
const resolver = @import("resolver.zig");
const output = @import("output.zig");

pub fn run(a: std.mem.Allocator, io: std.Io, client: *aur.Client, targets: []const []const u8, out: *std.Io.Writer, err: *std.Io.Writer, color: bool, err_color: bool) !u8 {
    // Validate every target before opening databases or making network requests.
    for (targets) |text| _ = @import("dependency.zig").Dependency.parse(text) catch {
        try err.writeAll("error: invalid package target; use a package name with an optional version constraint\n");
        try err.flush();
        return 2;
    };
    var host = catalog.Host.init(a, client);
    defer host.deinit();
    host.load(io) catch |failure| {
        try report(err, failure, "", "", client, host.detail, err_color);
        return 2;
    };
    var graph: resolver.Graph = .{ .a = a, .catalog = host.view() };
    defer graph.deinit();
    graph.plan(targets) catch |failure| {
        try report(err, failure, graph.problem, graph.related, client, host.detail, err_color);
        return 2;
    };
    try output.infoPrefix(out, color);
    try out.writeAll("dependency plan (no packages will be installed)\n");
    // Repository packages form one pacman transaction; runtime cycles are legal
    // there. Only source builds need a dependency-ordered sequence.
    var repo: std.ArrayList(resolver.Record) = .empty;
    defer repo.deinit(a);
    var installed: usize = 0;
    for (graph.nodes.items) |n| switch (n.package.source) {
        .repo => try repo.append(a, n.package),
        .installed => installed += 1,
        .aur => {},
    };
    std.mem.sort(resolver.Record, repo.items, {}, struct {
        fn less(_: void, l: resolver.Record, r: resolver.Record) bool {
            return std.mem.lessThan(u8, l.name, r.name);
        }
    }.less);
    if (repo.items.len != 0) {
        try output.styled(out, color, .info, "Repository packages");
        try out.print(" ({d}):\n", .{repo.items.len});
        for (repo.items) |p| {
            try out.writeAll("  ");
            try output.styled(out, color, .heading, p.repository);
            try out.writeByte('/');
            try output.styled(out, color, .package, p.name);
            try out.writeByte(' ');
            try output.styled(out, color, .version, p.version);
            try out.writeByte('\n');
        }
    }
    if (graph.order.items.len != 0) {
        try output.styled(out, color, .info, "AUR build order");
        try out.print(" ({d}):\n", .{graph.order.items.len});
        for (graph.order.items) |i| {
            const build = graph.builds.items[i];
            try output.styled(out, color, .heading, "  aur/");
            try output.styled(out, color, .package, build.base);
            try out.writeAll(":");
            for (build.packages.items) |id| {
                try out.writeByte(' ');
                try output.styled(out, color, .package, graph.nodes.items[id].package.name);
            }
            try out.writeByte('\n');
        }
        try output.infoPrefix(out, color);
        try output.styled(out, color, .warning, "AUR build files are untrusted; review is required before building");
        try out.writeByte('\n');
    }
    try output.styled(out, color, .info, "Satisfied by installed packages");
    try out.print(": {d}\n", .{installed});
    return 0;
}

pub fn report(w: *std.Io.Writer, failure: anyerror, problem: []const u8, related: []const u8, client: *aur.Client, detail: []const u8, color: bool) !void {
    try output.errorPrefix(w, color);
    if (problem.len != 0) {
        try output.safe(w, problem);
        try w.writeAll(": ");
    }
    const message: []const u8 = switch (failure) {
        error.InvalidDependency, error.InvalidProvision => "invalid dependency metadata",
        error.DependencyNotFound => "dependency not found in repositories or AUR",
        error.VersionUnavailable => "required version is unavailable; check repository versions",
        error.ConstraintConflict => "incompatible package requirements; automatic backtracking is not supported",
        error.AmbiguousProvider => "multiple providers; specify the provider package explicitly",
        error.RepositoryDependencyUnavailable => "repository dependency is unavailable; check repository databases",
        error.IgnoredPackage => "package is ignored by pacman configuration",
        error.PackageConflict => "conflicts with another selected or installed package",
        error.ReplacementRequired => "requires replacing another package; automatic removal is not supported",
        error.BreaksInstalledDependency => "would break an installed package dependency; include its compatible upgrade",
        error.DependencyCycle => "AUR dependency cycle; resolve the cycle before building",
        error.SplitBuildDependency => "build/check dependency needs an output of the same package base",
        error.SplitVersionMismatch => "split packages have inconsistent versions; retry after metadata is updated",
        error.ResolutionLimit => "dependency graph is too large",
        error.PacmanConfMissing => "pacman-conf is required but was not found",
        error.PacmanConfiguration => "could not read pacman configuration; run pacman-conf to check it",
        error.AssumeInstalledUnsupported => "planning with AssumeInstalled is not supported",
        error.PackageDatabase => "could not read package databases; check them with pacman",
        error.AurApi => detail,
        error.HttpStatus => {
            try w.print("AUR request failed: HTTP {d}\n", .{@intFromEnum(client.last_status.?)});
            try w.flush();
            return;
        },
        error.OutOfMemory, error.AccessDenied => @import("diagnostic.zig").message(failure),
        else => @import("diagnostic.zig").aurMessage(failure),
    };
    try output.safe(w, message);
    if (failure == error.PackageDatabase and detail.len != 0) {
        try w.writeAll(": ");
        try output.safe(w, detail);
    }
    if (related.len != 0) {
        try w.writeAll(switch (failure) {
            error.PackageConflict, error.ReplacementRequired, error.SplitBuildDependency => " (",
            else => " (required by ",
        });
        try output.safe(w, related);
        try w.writeByte(')');
    }
    try w.writeByte('\n');
    try w.flush();
}
