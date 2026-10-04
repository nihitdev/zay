const std = @import("std");
const linux = std.os.linux;
const aur = @import("aur.zig");
const cache = @import("cache.zig");
const catalog = @import("catalog.zig");
const resolver = @import("resolver.zig");
const aur_repo = @import("aur_repo.zig");
const srcinfo = @import("srcinfo.zig");
const review = @import("review.zig");
const builder = @import("builder.zig");
const process = @import("process.zig");
const output = @import("output.zig");
const upgrade_flow = @import("upgrade_flow.zig");
const Package = @import("package.zig").Package;

const Prepared = struct {
    base: []const u8,
    repository: aur_repo.Repository,
    srcinfo_text: []u8,
    info: srcinfo.Info,
    prior: ?[]u8,
    status: review.Status,
    fn deinit(self: *Prepared, a: std.mem.Allocator) void {
        if (self.prior) |commit| a.free(commit);
        self.info.deinit();
        a.free(self.srcinfo_text);
        self.repository.deinit();
    }
};

/// Resolve, acquire and validate every AUR base before asking once for the
/// operation. No package build or pacman transaction occurs before approval.
pub fn install(a: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, client: *aur.Client, targets: []const []const u8, noconfirm: bool, sysupgrade_args: ?[]const []const u8, color: bool, err_color: bool, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    if (sysupgrade_args) |args| if (!supportsSysupgradeOptions(args)) {
        try output.errorPrefix(err, err_color);
        try err.writeAll("unsupported pacman options for AUR-aware -Syu\n");
        try err.flush();
        return 2;
    };
    if (linux.geteuid() == 0) {
        try output.errorPrefix(err, err_color);
        try err.writeAll("refusing AUR builds as root; run zay as a normal user\n");
        try err.flush();
        return 2;
    }
    var host = catalog.Host.init(a, client);
    defer host.deinit();
    host.load(io) catch |failure| {
        try @import("planner.zig").report(err, failure, "", "", client, host.detail, err_color);
        return 2;
    };
    var graph: resolver.Graph = .{ .a = a, .catalog = host.view() };
    defer graph.deinit();
    graph.plan(targets) catch |failure| {
        try @import("planner.zig").report(err, failure, graph.problem, graph.related, client, host.detail, err_color);
        return 2;
    };
    if (graph.order.items.len == 0) {
        if (sysupgrade_args != null) {
            try output.errorPrefix(err, err_color);
            try err.writeAll("AUR update targets no longer resolve to AUR packages; rerun zay -Syu to replan\n");
            try err.flush();
            return 2;
        }
        return pacmanInstall(a, io, graph.nodes.items, noconfirm, false, err);
    }

    var paths = cache.Paths.create(a, environ) catch |failure| {
        try reportCacheError(err, err_color, failure);
        return 2;
    };
    defer paths.deinit();
    paths.ensure(io) catch |failure| {
        try reportCacheError(err, err_color, failure);
        return 2;
    };
    const store: review.Store = .{ .allocator = a, .io = io, .directory = paths.reviews };
    var prepared: std.ArrayList(Prepared) = .empty;
    defer {
        for (prepared.items) |*item| item.deinit(a);
        prepared.deinit(a);
    }
    for (graph.order.items) |build_id| {
        const plan = graph.builds.items[build_id];
        var repository = aur_repo.acquire(a, io, &paths, plan.base) catch |failure| {
            try reportAcquire(err, err_color, plan.base, failure);
            return 2;
        };
        errdefer repository.deinit();
        const text = aur_repo.readSrcinfo(a, io, repository.path, repository.acquisition.revisions.fetched) catch |failure| {
            try reportMetadata(err, err_color, plan.base, failure);
            return 2;
        };
        errdefer a.free(text);
        var info = srcinfo.parse(a, text) catch |failure| {
            try reportMetadata(err, err_color, plan.base, failure);
            return 2;
        };
        errdefer info.deinit();
        for (plan.packages.items) |node_id| {
            const record = graph.nodes.items[node_id].package;
            const pkg = packageFromRecord(record);
            aur_repo.validateMetadata(a, &info, plan.base, pkg, @tagName(@import("builtin").cpu.arch)) catch |failure| {
                try reportMetadata(err, err_color, plan.base, failure);
                return 2;
            };
        }
        const prior = store.load(plan.base) catch |failure| {
            try reportMetadata(err, err_color, plan.base, failure);
            return 2;
        };
        const status = review.classify(prior, repository.acquisition.revisions.fetched) catch |failure| {
            if (prior) |value| a.free(value);
            try reportMetadata(err, err_color, plan.base, failure);
            return 2;
        };
        try prepared.append(a, .{ .base = plan.base, .repository = repository, .srcinfo_text = text, .info = info, .prior = prior, .status = status });
        repository = undefined;
        info = undefined;
    }

    try output.infoPrefix(out, color);
    try out.writeAll(if (sysupgrade_args == null) "Packages to install:\n" else "System upgrade and AUR updates:\n");
    for (graph.nodes.items) |node| if (node.package.source == .repo) {
        try out.writeAll("  ");
        try output.safe(out, node.package.repository);
        try out.writeByte('/');
        try output.styled(out, color, .package, node.package.name);
        try out.writeByte(' ');
        try output.styled(out, color, .package, node.package.version);
        if (!node.explicit) try out.writeAll(" (dependency)");
        try out.writeByte('\n');
    };
    for (graph.order.items) |build_id| {
        const build = graph.builds.items[build_id];
        try out.writeAll("  aur/");
        try output.safe(out, build.base);
        for (build.packages.items) |node_id| {
            try out.writeByte(' ');
            try output.styled(out, color, .package, graph.nodes.items[node_id].package.name);
        }
        try out.writeByte('\n');
    }
    try out.flush();
    for (prepared.items) |*item| {
        if (item.status != .unchanged) showReview(a, io, out, item, color) catch |failure| {
            try output.errorPrefix(err, err_color);
            try err.print("could not display review files for AUR package base '{s}': {s}\n", .{ item.base, @import("diagnostic.zig").message(failure) });
            try err.flush();
            return 2;
        };
    }
    if (!noconfirm or containsUnreviewed(prepared.items)) {
        switch (try confirm(io, out, sysupgrade_args != null)) {
            .accepted => {},
            .rejected => {
                try output.errorPrefix(err, err_color);
                try err.writeAll("transaction not approved\n");
                try err.flush();
                return 1;
            },
            .unavailable => {
                try output.errorPrefix(err, err_color);
                try err.writeAll(if (containsUnreviewed(prepared.items))
                    "AUR build files need interactive review; rerun in a terminal\n"
                else
                    "transaction needs interactive confirmation; rerun in a terminal or use --noconfirm\n");
                try err.flush();
                return 2;
            },
        }
    }
    for (prepared.items) |*item| try item.repository.recordReview(store, item.base);

    if (sysupgrade_args) |args| {
        var stages = SysupgradeStages{
            .a = a,
            .io = io,
            .args = args,
            .client = client,
            .targets = targets,
            .host = &host,
            .graph = &graph,
            .prepared = prepared.items,
            .err = err,
            .err_color = err_color,
        };
        const status = try upgrade_flow.run(.{
            .context = &stages,
            .repository_upgrade = SysupgradeStages.repositoryUpgrade,
            .replan = SysupgradeStages.replan,
        });
        if (status != 0) return status;
    }

    const repo_status = try pacmanInstall(a, io, graph.nodes.items, true, false, err);
    if (repo_status != 0) return repo_status;

    for (graph.order.items) |build_id| {
        const plan = graph.builds.items[build_id];
        const item = findPrepared(prepared.items, plan.base) orelse return error.MissingPreparedPackageBase;
        var tree = builder.prepare(a, io, item.repository.path, item.repository.acquisition.revisions.fetched, paths.builds, plan.base) catch |failure| {
            try reportBuild(err, err_color, plan.base, failure);
            return 2;
        };
        defer tree.deinit();
        const review_paths = try reviewPaths(a, &item.info);
        defer a.free(review_paths);
        builder.verifyReviewedFiles(a, io, item.repository.path, item.repository.acquisition.revisions.fetched, tree, review_paths) catch |failure| {
            try reportBuild(err, err_color, plan.base, failure);
            return 2;
        };
        var artifacts = builder.build(a, io, tree, true) catch |failure| {
            try reportBuild(err, err_color, plan.base, failure);
            return 2;
        };
        defer artifacts.deinit();
        var names = builder.packageNames(a, io, artifacts, err) catch |failure| {
            try reportBuild(err, err_color, plan.base, failure);
            return 2;
        };
        defer names.deinit();
        const expected = try item.info.outputNames(a);
        defer a.free(expected);
        const expected_version = try item.info.version(a);
        defer a.free(expected_version);
        builder.validatePackageOutputs(names.identities, expected, item.base, expected_version) catch |failure| {
            try reportBuild(err, err_color, plan.base, failure);
            return 2;
        };
        var install_context = ArtifactInstallContext{ .a = a, .io = io, .err = err, .err_color = err_color };
        const install_status = try installSelectedArtifacts(a, artifacts, names, graph, plan.packages.items, .{
            .context = &install_context,
            .install = ArtifactInstallContext.run,
        });
        if (install_status != 0) return install_status;
    }
    return 0;
}

pub fn supportsOptions(raw_args: []const []const u8) bool {
    for (raw_args) |arg| {
        if (std.mem.eql(u8, arg, "-S") or std.mem.eql(u8, arg, "--sync") or std.mem.eql(u8, arg, "--noconfirm") or std.mem.eql(u8, arg, "--")) continue;
        if (std.mem.startsWith(u8, arg, "-")) return false;
    }
    return true;
}

test "AUR transaction does not silently ignore pacman options" {
    try std.testing.expect(supportsOptions(&.{ "-S", "--noconfirm", "foo" }));
    try std.testing.expect(supportsOptions(&.{ "--sync", "--", "foo" }));
    try std.testing.expect(!supportsOptions(&.{ "-S", "--needed", "foo" }));
    try std.testing.expect(!supportsOptions(&.{ "-S", "--root=/tmp/root", "foo" }));
}

pub fn supportsSysupgradeOptions(raw_args: []const []const u8) bool {
    var sync = false;
    var refresh = false;
    var sysupgrade = false;
    var sysupgrade_count: usize = 0;
    for (raw_args) |arg| {
        if (std.mem.eql(u8, arg, "--sync")) {
            sync = true;
        } else if (std.mem.eql(u8, arg, "--refresh")) {
            refresh = true;
        } else if (std.mem.eql(u8, arg, "--sysupgrade")) {
            sysupgrade = true;
        } else if (std.mem.eql(u8, arg, "--noconfirm") or std.mem.eql(u8, arg, "--")) {
            // -- is harmless here because mixed AUR sysupgrades reject operands.
        } else if (arg.len > 1 and arg[0] == '-' and arg[1] != '-') {
            for (arg[1..]) |flag| switch (flag) {
                'S' => sync = true,
                'y' => refresh = true,
                'u' => {
                    sysupgrade = true;
                    sysupgrade_count += 1;
                },
                else => return false,
            };
        } else return false;
    }
    return sync and refresh and sysupgrade and sysupgrade_count <= 1;
}

fn systemUpgradeArgv(a: std.mem.Allocator, raw_args: []const []const u8, root: bool) ![][]const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    errdefer args.deinit(a);
    if (root) {
        try args.append(a, "pacman");
    } else {
        try args.appendSlice(a, &.{ "sudo", "pacman" });
    }
    var has_noconfirm = false;
    for (raw_args) |arg| {
        if (std.mem.eql(u8, arg, "--noconfirm")) has_noconfirm = true;
        if (std.mem.eql(u8, arg, "--")) {
            if (!has_noconfirm) try args.append(a, "--noconfirm");
            has_noconfirm = true;
        }
        try args.append(a, arg);
    }
    if (!has_noconfirm) try args.append(a, "--noconfirm");
    return args.toOwnedSlice(a);
}

const SysupgradeStages = struct {
    a: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    client: *aur.Client,
    targets: []const []const u8,
    host: *catalog.Host,
    graph: *resolver.Graph,
    prepared: []Prepared,
    err: *std.Io.Writer,
    err_color: bool,

    fn repositoryUpgrade(context: *anyopaque) anyerror!u8 {
        const self: *SysupgradeStages = @ptrCast(@alignCast(context));
        return runSystemUpgrade(self.a, self.io, self.args, self.err, self.err_color);
    }

    fn replan(context: *anyopaque) anyerror!u8 {
        const self: *SysupgradeStages = @ptrCast(@alignCast(context));
        // pacman has refreshed sync databases and installed repository
        // upgrades. Re-resolve against that state, constrained to reviewed
        // package bases, before the caller enters the AUR build phase.
        self.graph.deinit();
        self.host.deinit();
        self.host.* = catalog.Host.init(self.a, self.client);
        self.host.load(self.io) catch |failure| {
            try output.errorPrefix(self.err, self.err_color);
            try self.err.print("repository upgrade completed, but the AUR dependency plan could not be refreshed: {s}\n", .{@import("diagnostic.zig").message(failure)});
            try self.err.flush();
            return 2;
        };
        self.graph.* = .{ .a = self.a, .catalog = self.host.view() };
        self.graph.plan(self.targets) catch |failure| {
            try @import("planner.zig").report(self.err, failure, self.graph.problem, self.graph.related, self.client, self.host.detail, self.err_color);
            return 2;
        };
        for (self.graph.order.items) |build_id| {
            const plan = self.graph.builds.items[build_id];
            const item = findPrepared(self.prepared, plan.base) orelse {
                try output.errorPrefix(self.err, self.err_color);
                try self.err.print("repository upgrade changed the AUR dependency plan; new package base '{s}' needs review, rerun zay -Syu\n", .{plan.base});
                try self.err.flush();
                return 2;
            };
            for (plan.packages.items) |node_id| {
                const pkg = packageFromRecord(self.graph.nodes.items[node_id].package);
                aur_repo.validateMetadata(self.a, &item.info, plan.base, pkg, @tagName(@import("builtin").cpu.arch)) catch |failure| {
                    try reportMetadata(self.err, self.err_color, plan.base, failure);
                    return 2;
                };
            }
        }
        return 0;
    }
};

fn runSystemUpgrade(a: std.mem.Allocator, io: std.Io, raw_args: []const []const u8, err: *std.Io.Writer, err_color: bool) !u8 {
    const argv = try systemUpgradeArgv(a, raw_args, linux.geteuid() == 0);
    defer a.free(argv);
    return process.inherit(io, argv) catch |failure| {
        try output.errorPrefix(err, err_color);
        try err.print("{s}\n", .{privilegeMessage(failure, "pacman")});
        try err.flush();
        return 2;
    };
}

test "combined sysupgrade accepts only explicitly supported pacman flags" {
    try std.testing.expect(supportsSysupgradeOptions(&.{"-Syu"}));
    try std.testing.expect(supportsSysupgradeOptions(&.{ "--sync", "--refresh", "--sysupgrade", "--noconfirm" }));
    try std.testing.expect(supportsSysupgradeOptions(&.{"-Syyu"}));
    try std.testing.expect(!supportsSysupgradeOptions(&.{"-Syyuu"}));
    try std.testing.expect(!supportsSysupgradeOptions(&.{ "-Syu", "--ignore", "foo" }));
    try std.testing.expect(!supportsSysupgradeOptions(&.{ "-Syu", "--color=always" }));
    try std.testing.expect(!supportsSysupgradeOptions(&.{"-S"}));
}

test "system upgrade argv is explicit and avoids duplicate confirmation" {
    const a = std.testing.allocator;
    const argv = try systemUpgradeArgv(a, &.{"-Syu"}, false);
    defer a.free(argv);
    try std.testing.expectEqualSlices([]const u8, &.{ "sudo", "pacman", "-Syu", "--noconfirm" }, argv);

    const with_delimiter = try systemUpgradeArgv(a, &.{ "-Syu", "--" }, true);
    defer a.free(with_delimiter);
    try std.testing.expectEqualSlices([]const u8, &.{ "pacman", "-Syu", "--noconfirm", "--" }, with_delimiter);

    const already = try systemUpgradeArgv(a, &.{ "-Syu", "--noconfirm" }, true);
    defer a.free(already);
    try std.testing.expectEqualSlices([]const u8, &.{ "pacman", "-Syu", "--noconfirm" }, already);
}

fn packageFromRecord(record: resolver.Record) Package {
    return .{ .name = record.name, .base = record.base, .version = record.version, .description = null, .url = null, .maintainer = null, .votes = 0, .popularity = 0, .out_of_date = null, .depends = record.depends, .make_depends = record.make_depends, .check_depends = record.check_depends, .provides = record.provides, .opt_depends = record.opt_depends, .conflicts = record.conflicts, .replaces = record.replaces };
}

fn containsUnreviewed(items: []const Prepared) bool {
    for (items) |item| if (item.status != .unchanged) return true;
    return false;
}

fn findPrepared(items: []Prepared, base: []const u8) ?*Prepared {
    for (items) |*item| if (std.mem.eql(u8, item.base, base)) return item;
    return null;
}

const Confirmation = enum { accepted, rejected, unavailable };

fn confirm(io: std.Io, out: *std.Io.Writer, system_upgrade: bool) !Confirmation {
    if (!try std.Io.File.stdin().isTty(io)) return .unavailable;
    try out.writeAll(if (system_upgrade) "Proceed with system upgrade? [y/N] " else "Proceed with installation? [y/N] ");
    try out.flush();
    var storage: [128]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &storage);
    const answer = reader.interface.takeDelimiterExclusive('\n') catch |failure| switch (failure) {
        error.EndOfStream => return .rejected,
        error.StreamTooLong => return .rejected,
        else => return failure,
    };
    return if (std.mem.eql(u8, std.mem.trim(u8, answer, "\r\t "), "y") or std.mem.eql(u8, std.mem.trim(u8, answer, "\r\t "), "Y")) .accepted else .rejected;
}

fn showReview(a: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, item: *const Prepared, color: bool) !void {
    try output.infoPrefix(out, color);
    try output.styled(out, color, .warning, "Untrusted AUR build files:");
    try out.writeByte(' ');
    try output.styled(out, color, .package, item.base);
    try out.print(" at {s} ({s})\n", .{ item.repository.acquisition.revisions.fetched, if (item.status == .first_seen) "first review" else "changed since review" });
    const paths = try reviewPaths(a, &item.info);
    defer a.free(paths);
    if (item.status == .changed) {
        const old = item.prior orelse return error.InvalidReviewState;
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(a);
        try args.appendSlice(a, &.{ "git", "-C", item.repository.path, "--no-pager", "diff", "--no-ext-diff", old, item.repository.acquisition.revisions.fetched, "--" });
        try args.appendSlice(a, paths);
        const diff = try process.capture(a, io, args.items);
        defer diff.deinit();
        if (diff.code() != 0) return error.ReviewDiffFailed;
        if (diff.stdout.len == 0) try out.writeAll("  (no changes in PKGBUILD, .SRCINFO, or selected .install files)\n") else try output.safeMultiline(out, diff.stdout);
    } else {
        for (paths) |path| {
            const object = try std.fmt.allocPrint(a, "{s}:{s}", .{ item.repository.acquisition.revisions.fetched, path });
            defer a.free(object);
            const result = try process.capture(a, io, &.{ "git", "-C", item.repository.path, "show", object });
            defer result.deinit();
            if (result.code() != 0) return error.ReviewFileMissing;
            try output.styled(out, color, .heading, "--- ");
            try output.safe(out, path);
            try output.styled(out, color, .heading, " ---\n");
            try output.safeMultiline(out, result.stdout);
            if (result.stdout.len == 0 or result.stdout[result.stdout.len - 1] != '\n') try out.writeByte('\n');
        }
    }
    try out.flush();
}

fn reviewPaths(a: std.mem.Allocator, info: *const srcinfo.Info) ![][]const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    errdefer paths.deinit(a);
    try paths.appendSlice(a, &.{ "PKGBUILD", ".SRCINFO" });
    for (info.packages) |pkg| {
        const view = info.package(pkg.name).?;
        const installs = try view.values(a, .install, "any");
        defer a.free(installs);
        for (installs) |install_path| {
            if (!safeRelativePath(install_path)) return error.InvalidInstallScriptPath;
            var seen = false;
            for (paths.items) |prior| if (std.mem.eql(u8, prior, install_path)) {
                seen = true;
                break;
            };
            if (!seen) try paths.append(a, install_path);
        }
    }
    return paths.toOwnedSlice(a);
}

fn safeRelativePath(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) return false;
    var parts = std.mem.tokenizeScalar(u8, path, '/');
    while (parts.next()) |part| if (std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".")) return false;
    return true;
}

fn pacmanInstall(a: std.mem.Allocator, io: std.Io, nodes: []const resolver.Node, noconfirm: bool, dependencies_only: bool, err: *std.Io.Writer) !u8 {
    var deps: std.ArrayList([]const u8) = .empty;
    var explicit: std.ArrayList([]const u8) = .empty;
    defer deps.deinit(a);
    defer explicit.deinit(a);
    for (nodes) |node| if (node.package.source == .repo) {
        if (node.explicit) try explicit.append(a, node.package.name) else try deps.append(a, node.package.name);
    };
    if (!dependencies_only) {
        const status = try runPacman(a, io, &explicit, false, noconfirm, err);
        if (status != 0) return status;
    }
    return runPacman(a, io, &deps, true, noconfirm, err);
}

fn runPacman(a: std.mem.Allocator, io: std.Io, packages: *const std.ArrayList([]const u8), asdeps: bool, noconfirm: bool, err: *std.Io.Writer) !u8 {
    if (packages.items.len == 0) return 0;
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(a);
    if (linux.geteuid() == 0) {
        try args.append(a, "pacman");
    } else {
        try args.appendSlice(a, &.{ "sudo", "pacman" });
    }
    try args.append(a, "-S");
    if (noconfirm) try args.append(a, "--noconfirm");
    if (asdeps) try args.append(a, "--asdeps");
    try args.appendSlice(a, &.{"--"});
    try args.appendSlice(a, packages.items);
    return process.inherit(io, args.items) catch |failure| {
        try err.print("error: {s}\n", .{privilegeMessage(failure, "pacman")});
        try err.flush();
        return 2;
    };
}

const ArtifactInstaller = struct {
    context: *anyopaque,
    install: *const fn (*anyopaque, []const []const u8, bool) anyerror!u8,
};

const ArtifactInstallContext = struct {
    a: std.mem.Allocator,
    io: std.Io,
    err: *std.Io.Writer,
    err_color: bool,

    fn run(context: *anyopaque, artifacts: []const []const u8, asdeps: bool) anyerror!u8 {
        const self: *ArtifactInstallContext = @ptrCast(@alignCast(context));
        return installArtifacts(self.a, self.io, artifacts, asdeps, self.err, self.err_color);
    }
};

fn installSelectedArtifacts(a: std.mem.Allocator, artifacts: builder.Artifacts, names: builder.PackageNames, graph: resolver.Graph, selected_nodes: []const usize, installer: ArtifactInstaller) !u8 {
    var explicit: std.ArrayList([]const u8) = .empty;
    var dependencies: std.ArrayList([]const u8) = .empty;
    defer explicit.deinit(a);
    defer dependencies.deinit(a);
    for (selected_nodes) |node_id| {
        const node = graph.nodes.items[node_id];
        var found = false;
        for (names.identities, 0..) |actual, i| if (std.mem.eql(u8, actual.name, node.package.name)) {
            if (node.explicit) {
                try explicit.append(a, artifacts.paths[i]);
            } else {
                try dependencies.append(a, artifacts.paths[i]);
            }
            found = true;
            break;
        };
        if (!found) return error.PackageOutputMismatch;
    }
    if (explicit.items.len != 0) {
        const explicit_status = try installer.install(installer.context, explicit.items, false);
        if (explicit_status != 0) return explicit_status;
    }
    if (dependencies.items.len == 0) return 0;
    return installer.install(installer.context, dependencies.items, true);
}

const MockArtifactInstaller = struct {
    calls: usize = 0,
    expected_filename: []const u8,

    fn run(context: *anyopaque, paths: []const []const u8, asdeps: bool) anyerror!u8 {
        const self: *MockArtifactInstaller = @ptrCast(@alignCast(context));
        try std.testing.expectEqual(@as(usize, 1), paths.len);
        try std.testing.expectEqualStrings(self.expected_filename, std.fs.path.basename(paths[0]));
        try std.testing.expect(!asdeps);
        self.calls += 1;
        return 0;
    }
};

test "successful explicit install does not fail on empty dependency phase with debug output" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const build_dir = try std.fs.path.join(a, &.{ root, "sample build" });
    defer a.free(build_dir);
    try std.Io.Dir.cwd().createDirPath(io, build_dir);
    const regular_path = try std.fs.path.join(a, &.{ build_dir, "sample-app-1.2.3-1-x86_64.pkg.tar.zst" });
    defer a.free(regular_path);
    const debug_path = try std.fs.path.join(a, &.{ build_dir, "sample-app-debug-1.2.3-1-x86_64.pkg.tar.zst" });
    defer a.free(debug_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = regular_path, .data = "regular fixture" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = debug_path, .data = "debug fixture" });

    var artifacts = try builder.discoverArtifacts(a, io, build_dir);
    defer artifacts.deinit();
    try std.testing.expectEqual(@as(usize, 2), artifacts.paths.len);
    try std.testing.expectEqualStrings("sample-app-1.2.3-1-x86_64.pkg.tar.zst", std.fs.path.basename(artifacts.paths[0]));
    try std.testing.expectEqualStrings("sample-app-debug-1.2.3-1-x86_64.pkg.tar.zst", std.fs.path.basename(artifacts.paths[1]));

    var regular = try builder.parsePackageInfo(a, "pkgname = sample-app\npkgbase = sample-app\npkgver = 1.2.3-1\nxdata = pkgtype=pkg\n");
    defer regular.deinit(a);
    var debug = try builder.parsePackageInfo(a, "pkgname = sample-app-debug\npkgbase = sample-app\npkgver = 1.2.3-1\nxdata = pkgtype=debug\n");
    defer debug.deinit(a);
    const identity_storage = try a.alloc(builder.Identity, 2);
    var initialized_identities: usize = 0;
    var identities_transferred = false;
    errdefer if (!identities_transferred) {
        for (identity_storage[0..initialized_identities]) |identity| identity.deinit(a);
        a.free(identity_storage);
    };
    identity_storage[0] = try duplicateIdentity(a, regular);
    initialized_identities += 1;
    identity_storage[1] = try duplicateIdentity(a, debug);
    initialized_identities += 1;
    var names = builder.PackageNames{ .allocator = a, .identities = identity_storage };
    identities_transferred = true;
    defer names.deinit();

    var graph: resolver.Graph = .{ .a = a, .catalog = undefined };
    defer graph.deinit();
    try graph.nodes.append(a, .{ .package = .{ .name = "sample-app", .base = "sample-app", .version = "1.2.3-1", .source = .aur }, .explicit = true });
    var mock = MockArtifactInstaller{ .expected_filename = "sample-app-1.2.3-1-x86_64.pkg.tar.zst" };
    const status = try installSelectedArtifacts(a, artifacts, names, graph, &.{0}, .{ .context = &mock, .install = MockArtifactInstaller.run });
    try std.testing.expectEqual(@as(u8, 0), status);
    try std.testing.expectEqual(@as(usize, 1), mock.calls);
}

fn duplicateIdentity(a: std.mem.Allocator, identity: builder.Identity) !builder.Identity {
    const name = try a.dupe(u8, identity.name);
    errdefer a.free(name);
    const base = try a.dupe(u8, identity.base);
    errdefer a.free(base);
    const version = try a.dupe(u8, identity.version);
    return .{ .name = name, .base = base, .version = version, .package_type = identity.package_type };
}

fn installArtifacts(a: std.mem.Allocator, io: std.Io, artifacts: []const []const u8, asdeps: bool, err: *std.Io.Writer, err_color: bool) !u8 {
    if (artifacts.len == 0) return error.NoArtifacts;
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(a);
    try args.appendSlice(a, &.{ "sudo", "pacman", "-U", "--noconfirm" });
    if (asdeps) try args.append(a, "--asdeps");
    try args.append(a, "--");
    try args.appendSlice(a, artifacts);
    return process.inherit(io, args.items) catch |failure| {
        try output.errorPrefix(err, err_color);
        try err.print("{s}\n", .{privilegeMessage(failure, "package installation")});
        try err.flush();
        return 2;
    };
}

fn privilegeMessage(failure: anyerror, comptime operation: []const u8) []const u8 {
    return switch (failure) {
        error.FileNotFound => "sudo is required for pacman operations; install/configure a privilege helper such as sudo",
        error.AccessDenied => "permission denied while executing the pacman privilege helper",
        else => if (std.mem.eql(u8, operation, "pacman"))
            @import("diagnostic.zig").message(failure)
        else
            "package installation failed; review pacman output above",
    };
}

fn reportCacheError(err: *std.Io.Writer, color: bool, failure: anyerror) !void {
    try output.errorPrefix(err, color);
    try err.print("cache: {s}\n", .{@import("diagnostic.zig").message(failure)});
    try err.flush();
}
fn reportAcquire(err: *std.Io.Writer, color: bool, base: []const u8, failure: anyerror) !void {
    try output.errorPrefix(err, color);
    try err.writeAll("could not acquire AUR package base '");
    try output.safe(err, base);
    try err.print("': {s}\n", .{@import("diagnostic.zig").message(failure)});
    try err.flush();
}
fn reportMetadata(err: *std.Io.Writer, color: bool, base: []const u8, failure: anyerror) !void {
    try output.errorPrefix(err, color);
    try err.writeAll("invalid AUR metadata for '");
    try output.safe(err, base);
    try err.print("': {s}\n", .{@import("diagnostic.zig").message(failure)});
    try err.flush();
}
fn reportBuild(err: *std.Io.Writer, color: bool, base: []const u8, failure: anyerror) !void {
    try output.errorPrefix(err, color);
    try err.writeAll("AUR build failed for '");
    try output.safe(err, base);
    try err.print("': {s}\n", .{@import("diagnostic.zig").message(failure)});
    try err.flush();
}
