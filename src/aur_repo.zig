const std = @import("std");
const aur = @import("aur.zig");
const cache = @import("cache.zig");
const git = @import("git.zig");
const process = @import("process.zig");
const srcinfo = @import("srcinfo.zig");
const review = @import("review.zig");
const RpcPackage = @import("package.zig").Package;

pub const Repository = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    acquisition: git.Acquisition,
    pub fn deinit(self: *Repository) void {
        self.acquisition.deinit();
        self.allocator.free(self.path);
    }

    /// Compare the fetched remote tip to the user's approval for this package
    /// base. This never treats a fetched-but-unreviewed revision as approved.
    pub fn reviewStatus(self: *const Repository, store: review.Store, package_base: []const u8) !review.Status {
        const reviewed = try store.load(package_base);
        defer if (reviewed) |commit| store.allocator.free(commit);
        return review.classify(reviewed, self.acquisition.revisions.fetched);
    }

    /// Call only after the user explicitly approves this exact fetched commit.
    pub fn recordReview(self: *const Repository, store: review.Store, package_base: []const u8) !void {
        try store.save(package_base, self.acquisition.revisions.fetched);
    }
};

pub fn origin(a: std.mem.Allocator, package_base: []const u8) ![]u8 {
    if (!aur.validName(package_base)) return error.InvalidPackageBase;
    return std.fmt.allocPrint(a, "https://aur.archlinux.org/{s}.git", .{package_base});
}

/// Acquires objects into the repos cache without checking out remote files.
/// Thus PKGBUILD and .SRCINFO contents are neither executed nor passed through
/// checkout filters. An existing path is never replaced.
pub fn acquire(a: std.mem.Allocator, io: std.Io, paths: *const cache.Paths, package_base: []const u8) !Repository {
    const remote = try origin(a, package_base);
    defer a.free(remote);
    const path = try std.fs.path.join(a, &.{ paths.repos, package_base });
    errdefer a.free(path);
    const existingRoot = std.Io.Dir.cwd().statFile(io, paths.root, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existingRoot) |stat| if (stat.kind != .directory) return error.UnsafeCachePath;
    const existingRepos = std.Io.Dir.cwd().statFile(io, paths.repos, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existingRepos) |stat| if (stat.kind != .directory) return error.UnsafeCachePath;
    try paths.ensure(io);
    const root_stat = try std.Io.Dir.cwd().statFile(io, paths.root, .{ .follow_symlinks = false });
    if (root_stat.kind != .directory) return error.UnsafeCachePath;
    const repos_stat = try std.Io.Dir.cwd().statFile(io, paths.repos, .{ .follow_symlinks = false });
    if (repos_stat.kind != .directory) return error.UnsafeCachePath;
    const destination_stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (destination_stat) |stat| if (stat.kind == .sym_link) return error.UnsafeCachePath;
    return .{ .allocator = a, .path = path, .acquisition = try git.ensureNoCheckout(a, io, remote, path) };
}

/// Read metadata from an immutable Git object, never from a mutable checkout.
pub fn readSrcinfo(a: std.mem.Allocator, io: std.Io, repository: []const u8, revision: []const u8) ![]u8 {
    if (!validObjectId(revision)) return error.InvalidRevision;
    const object = try std.fmt.allocPrint(a, "{s}:.SRCINFO", .{revision});
    defer a.free(object);
    const result = try process.capture(a, io, &.{ "git", "-C", repository, "show", object });
    defer result.deinit();
    if (result.code() != 0) return error.SrcinfoMissing;
    if (result.stdout.len > 1024 * 1024) return error.SrcinfoTooLarge;
    return a.dupe(u8, result.stdout);
}

pub fn validateMetadata(a: std.mem.Allocator, info: *const srcinfo.Info, package_base: []const u8, package: RpcPackage, architecture: []const u8) !void {
    if (!std.mem.eql(u8, info.pkgbase, package_base) or !std.mem.eql(u8, package.base, package_base))
        return error.PackageBaseMismatch;
    const selected = info.package(package.name) orelse return error.PackageMissingFromSrcinfo;
    const version = try selected.version(a);
    defer a.free(version);
    if (!std.mem.eql(u8, version, package.version)) return error.MetadataVersionMismatch;
    inline for (.{
        .{ .field = srcinfo.Field.depends, .rpc = package.depends },
        .{ .field = srcinfo.Field.makedepends, .rpc = package.make_depends },
        .{ .field = srcinfo.Field.checkdepends, .rpc = package.check_depends },
        .{ .field = srcinfo.Field.optdepends, .rpc = package.opt_depends },
        .{ .field = srcinfo.Field.provides, .rpc = package.provides },
        .{ .field = srcinfo.Field.conflicts, .rpc = package.conflicts },
        .{ .field = srcinfo.Field.replaces, .rpc = package.replaces },
    }) |item| {
        const values = try selected.values(a, item.field, architecture);
        defer a.free(values);
        const matches = if (item.field == .optdepends)
            sameOptionalDependencies(values, item.rpc)
        else
            sameValues(values, item.rpc);
        if (!matches) return error.MetadataMismatch;
    }
}

fn optionalDependencyName(value: []const u8) []const u8 {
    return value[0 .. std.mem.indexOf(u8, value, ": ") orelse value.len];
}

fn sameOptionalDependencies(srcinfo_values: []const []const u8, rpc_values: []const []const u8) bool {
    if (srcinfo_values.len != rpc_values.len) return false;
    for (srcinfo_values, 0..) |value, index| {
        var prior_duplicate = false;
        for (srcinfo_values[0..index]) |prior| if (std.mem.eql(u8, optionalDependencyName(value), optionalDependencyName(prior))) {
            prior_duplicate = true;
            break;
        };
        if (prior_duplicate) continue;
        var src_count: usize = 0;
        var rpc_count: usize = 0;
        for (srcinfo_values) |candidate| if (std.mem.eql(u8, optionalDependencyName(value), optionalDependencyName(candidate))) {
            src_count += 1;
        };
        for (rpc_values) |candidate| if (std.mem.eql(u8, optionalDependencyName(value), optionalDependencyName(candidate))) {
            rpc_count += 1;
        };
        if (src_count != rpc_count) return false;
    }
    return true;
}

fn sameValues(left: []const []const u8, right: []const []const u8) bool {
    if (left.len != right.len) return false;
    for (left, 0..) |value, index| {
        var already_counted = false;
        for (left[0..index]) |prior| if (std.mem.eql(u8, value, prior)) {
            already_counted = true;
            break;
        };
        if (already_counted) continue;
        var left_count: usize = 0;
        var right_count: usize = 0;
        for (left) |candidate| if (std.mem.eql(u8, value, candidate)) {
            left_count += 1;
        };
        for (right) |candidate| if (std.mem.eql(u8, value, candidate)) {
            right_count += 1;
        };
        if (left_count != right_count) return false;
    }
    return true;
}

fn validObjectId(value: []const u8) bool {
    if (value.len != 40 and value.len != 64) return false;
    for (value) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

test "AUR package base URL rejects path traversal and constructs canonical origin" {
    const a = std.testing.allocator;
    const url = try origin(a, "some-package");
    defer a.free(url);
    try std.testing.expectEqualStrings("https://aur.archlinux.org/some-package.git", url);
    try std.testing.expectError(error.InvalidPackageBase, origin(a, "../other"));
}

test "SRCINFO is loaded from pinned git object and checked against selected RPC package" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    try std.Io.Dir.cwd().createDirPath(io, root);
    const init = try process.capture(a, io, &.{ "git", "-C", root, "init", "--quiet" });
    defer init.deinit();
    try std.testing.expectEqual(@as(u8, 0), init.code());
    const src = try std.fs.path.join(a, &.{ root, ".SRCINFO" });
    defer a.free(src);
    var file = try std.Io.Dir.cwd().createFile(io, src, .{});
    var writer_buffer: [256]u8 = undefined;
    var writer = file.writer(io, &writer_buffer);
    try writer.interface.writeAll("pkgbase = demo\npkgver = 1.2\npkgrel = 1\npkgname = demo\noptdepends = viewer: optional support\n");
    try writer.interface.flush();
    file.close(io);
    const add = try process.capture(a, io, &.{ "git", "-C", root, "add", ".SRCINFO" });
    defer add.deinit();
    try std.testing.expectEqual(@as(u8, 0), add.code());
    const commit = try process.capture(a, io, &.{ "git", "-C", root, "-c", "user.name=zay test", "-c", "user.email=zay@example.invalid", "commit", "--quiet", "-m", "metadata" });
    defer commit.deinit();
    try std.testing.expectEqual(@as(u8, 0), commit.code());
    const head_result = try process.capture(a, io, &.{ "git", "-C", root, "rev-parse", "HEAD" });
    defer head_result.deinit();
    const revision = std.mem.trim(u8, head_result.stdout, " \r\n\t");
    const text = try readSrcinfo(a, io, root, revision);
    defer a.free(text);
    var info = try srcinfo.parse(a, text);
    defer info.deinit();
    const rpc: RpcPackage = .{
        .name = "demo",
        .base = "demo",
        .version = "1.2-1",
        .description = null,
        .url = null,
        .maintainer = null,
        .votes = 0,
        .popularity = 0,
        .out_of_date = null,
        .depends = &.{},
        .make_depends = &.{},
        .check_depends = &.{},
        .opt_depends = &.{"viewer"},
        .provides = &.{},
    };
    try validateMetadata(a, &info, "demo", rpc, "x86_64");
    try std.testing.expectError(error.PackageBaseMismatch, validateMetadata(a, &info, "other", rpc, "x86_64"));
    var inconsistent = rpc;
    inconsistent.depends = &.{"wrong>=2"};
    try std.testing.expectError(error.MetadataMismatch, validateMetadata(a, &info, "demo", inconsistent, "x86_64"));
}
