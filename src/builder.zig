const std = @import("std");
const linux = std.os.linux;
const aur = @import("aur.zig");
const git = @import("git.zig");
const process = @import("process.zig");
const review = @import("review.zig");

pub const Tree = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    revision: []u8,
    pub fn deinit(self: Tree) void {
        self.allocator.free(self.path);
        self.allocator.free(self.revision);
    }
};

pub const Artifacts = struct {
    allocator: std.mem.Allocator,
    paths: [][]u8,
    pub fn deinit(self: Artifacts) void {
        for (self.paths) |path| self.allocator.free(path);
        self.allocator.free(self.paths);
    }
};

pub const PackageNames = struct {
    allocator: std.mem.Allocator,
    identities: []Identity,
    pub fn deinit(self: PackageNames) void {
        for (self.identities) |identity| identity.deinit(self.allocator);
        self.allocator.free(self.identities);
    }
};

pub const PackageType = enum { regular, debug };
pub const Identity = struct {
    name: []u8,
    base: []u8,
    version: []u8,
    package_type: PackageType,
    pub fn deinit(self: Identity, a: std.mem.Allocator) void {
        a.free(self.name);
        a.free(self.base);
        a.free(self.version);
    }
};

/// Materialize an immutable reviewed Git commit without running checkout
/// filters or hooks. The fresh destination is never reused or overwritten.
pub fn prepare(a: std.mem.Allocator, io: std.Io, repository: []const u8, revision: []const u8, build_root: []const u8, package_base: []const u8) !Tree {
    if (!aur.validName(package_base)) return error.InvalidPackageBase;
    if (!review.validObjectId(revision)) return error.InvalidRevision;
    try requireUnprivileged();
    var path: ?[]u8 = null;
    for (0..10000) |attempt| {
        const candidate = try std.fmt.allocPrint(a, "{s}/{s}-{s}-{d}", .{ build_root, package_base, revision[0..12], attempt });
        std.Io.Dir.cwd().createDir(io, candidate, .default_dir) catch |failure| switch (failure) {
            error.PathAlreadyExists => {
                a.free(candidate);
                continue;
            },
            else => {
                a.free(candidate);
                return failure;
            },
        };
        path = candidate;
        break;
    }
    const build_path = path orelse return error.BuildDirectoryExhausted;
    errdefer a.free(build_path);
    errdefer std.Io.Dir.cwd().deleteTree(io, build_path) catch {};

    const archive = try process.captureWithLimits(a, io, &.{ "git", "-C", repository, "archive", "--format=tar", revision }, .inherit, 256 * 1024 * 1024, 1024 * 1024);
    defer archive.deinit();
    if (archive.code() != 0) return error.ArchiveFailed;
    const archive_path = try std.fs.path.join(a, &.{ build_path, ".zay-source.tar" });
    defer a.free(archive_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = archive_path, .data = archive.stdout, .flags = .{ .exclusive = true } });

    const extract = try process.capture(a, io, &.{ "bsdtar", "-xf", archive_path, "-C", build_path, "--no-same-owner", "--no-same-permissions" });
    defer extract.deinit();
    if (extract.code() != 0) return error.ArchiveFailed;
    try std.Io.Dir.cwd().deleteFile(io, archive_path);
    return .{ .allocator = a, .path = build_path, .revision = try a.dupe(u8, revision) };
}

pub fn makepkg(io: std.Io, tree: Tree, noconfirm: bool) !u8 {
    try requireUnprivileged();
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(tree.allocator);
    try argv.appendSlice(tree.allocator, &.{ "makepkg", "--nodeps" });
    if (noconfirm) try argv.append(tree.allocator, "--noconfirm");
    return process.inheritAt(io, argv.items, .{ .path = tree.path });
}

/// Run makepkg once in a previously reviewed, pinned build tree. Discover
/// outputs by listing the isolated directory; never source PKGBUILD a second
/// time just to ask makepkg for its file list.
pub fn build(a: std.mem.Allocator, io: std.Io, tree: Tree, noconfirm: bool) !Artifacts {
    const status = try makepkg(io, tree, noconfirm);
    if (status != 0) return error.MakepkgFailed;
    return discoverArtifacts(a, io, tree.path);
}

pub fn discoverArtifacts(a: std.mem.Allocator, io: std.Io, build_dir: []const u8) !Artifacts {
    var dir = try std.Io.Dir.cwd().openDir(io, build_dir, .{ .iterate = true });
    defer dir.close(io);
    const root = try dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var paths: std.ArrayList([]u8) = .empty;
    errdefer {
        for (paths.items) |path| a.free(path);
        paths.deinit(a);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!isPackageArchive(entry.name)) continue;
        if (entry.kind != .file) return error.InvalidArtifact;
        const path = try std.fs.path.join(a, &.{ root, entry.name });
        paths.append(a, path) catch |failure| {
            a.free(path);
            return failure;
        };
    }
    if (paths.items.len == 0) return error.NoArtifacts;
    std.mem.sort([]u8, paths.items, {}, struct {
        fn less(_: void, left: []u8, right: []u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.less);
    return .{ .allocator = a, .paths = try paths.toOwnedSlice(a) };
}

/// Git archive attributes can omit or substitute file contents. Confirm the
/// files the user reviewed are byte-identical in the prepared build tree.
pub fn verifyReviewedFiles(a: std.mem.Allocator, io: std.Io, repository: []const u8, revision: []const u8, tree: Tree, paths: []const []const u8) !void {
    if (!review.validObjectId(revision) or !std.mem.eql(u8, revision, tree.revision)) return error.BuildRevisionMismatch;
    for (paths) |path| {
        if (!safeRelativePath(path)) return error.InvalidReviewPath;
        const object = try std.fmt.allocPrint(a, "{s}:{s}", .{ revision, path });
        defer a.free(object);
        const source = try process.capture(a, io, &.{ "git", "-C", repository, "show", object });
        defer source.deinit();
        if (source.code() != 0) return error.ReviewFileMissing;
        const materialized_path = try std.fs.path.join(a, &.{ tree.path, path });
        defer a.free(materialized_path);
        const stat = std.Io.Dir.cwd().statFile(io, materialized_path, .{ .follow_symlinks = false }) catch return error.ReviewFileMismatch;
        if (stat.kind != .file) return error.ReviewFileMismatch;
        const materialized = std.Io.Dir.cwd().readFileAlloc(io, materialized_path, a, .limited(16 * 1024 * 1024)) catch return error.ReviewFileMismatch;
        defer a.free(materialized);
        if (!std.mem.eql(u8, source.stdout, materialized)) return error.ReviewFileMismatch;
    }
}

/// Validate every makepkg path as a regular file strictly inside the fresh
/// build directory. Artifact names are never inferred from package arguments.
pub fn parsePackagelist(a: std.mem.Allocator, io: std.Io, build_dir: []const u8, text: []const u8) !Artifacts {
    var dir = try std.Io.Dir.cwd().openDir(io, build_dir, .{});
    defer dir.close(io);
    const root = try dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var paths: std.ArrayList([]u8) = .empty;
    errdefer {
        for (paths.items) |path| a.free(path);
        paths.deinit(a);
    }
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const raw = std.mem.trim(u8, line, "\r\t ");
        if (raw.len == 0) continue;
        const path = if (std.fs.path.isAbsolute(raw)) try a.dupe(u8, raw) else try std.fs.path.join(a, &.{ root, raw });
        const prefix = try std.fmt.allocPrint(a, "{s}/", .{root});
        defer a.free(prefix);
        const canonical = validateArtifact(a, io, path, prefix, paths.items) catch |err| {
            a.free(path);
            return err;
        };
        a.free(path);
        paths.append(a, canonical) catch |err| {
            a.free(canonical);
            return err;
        };
    }
    if (paths.items.len == 0) return error.NoArtifacts;
    return .{ .allocator = a, .paths = try paths.toOwnedSlice(a) };
}

/// Read identity through pacman's supported -Qp output, then read package base
/// and makepkg package type from .PKGINFO. Neither filename nor package base is
/// inferred from artifact names.
pub fn packageNames(a: std.mem.Allocator, io: std.Io, artifacts: Artifacts, err: *std.Io.Writer) !PackageNames {
    var identities: std.ArrayList(Identity) = .empty;
    errdefer {
        for (identities.items) |identity| identity.deinit(a);
        identities.deinit(a);
    }
    for (artifacts.paths) |path| {
        // pacman query mode rejects --print-format; -Qp prints name and version.
        const result = try process.capture(a, io, &.{ "pacman", "-Qp", "--", path });
        defer result.deinit();
        if (result.code() != 0) {
            if (result.stderr.len != 0) try err.writeAll(result.stderr);
            try err.flush();
            return error.InvalidPackageArtifact;
        }
        var fields = std.mem.tokenizeAny(u8, result.stdout, "\r\n \t");
        const name = fields.next() orelse return error.InvalidPackageArtifact;
        const version = fields.next() orelse return error.InvalidPackageArtifact;
        if (!aur.validName(name) or !@import("package.zig").validVersion(version) or fields.next() != null)
            return error.InvalidPackageArtifact;

        const metadata = try process.captureWithLimits(a, io, &.{ "bsdtar", "-xOf", path, ".PKGINFO" }, .inherit, 1024 * 1024, 1024 * 1024);
        defer metadata.deinit();
        if (metadata.code() != 0) {
            if (metadata.stderr.len != 0) try err.writeAll(metadata.stderr);
            try err.flush();
            return error.InvalidPackageArtifact;
        }
        const identity = try parsePackageInfo(a, metadata.stdout);
        errdefer identity.deinit(a);
        if (!std.mem.eql(u8, name, identity.name) or !std.mem.eql(u8, version, identity.version))
            return error.InvalidPackageArtifact;
        try identities.append(a, identity);
    }
    return .{ .allocator = a, .identities = try identities.toOwnedSlice(a) };
}

pub fn parsePackageInfo(a: std.mem.Allocator, text: []const u8) !Identity {
    var name: ?[]const u8 = null;
    var base: ?[]const u8 = null;
    var version: ?[]const u8 = null;
    var package_type: PackageType = .regular;
    var saw_type = false;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidPackageInfo;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (value.len == 0) return error.InvalidPackageInfo;
        if (std.mem.eql(u8, key, "pkgname")) {
            if (name != null) return error.InvalidPackageInfo;
            name = value;
        } else if (std.mem.eql(u8, key, "pkgbase")) {
            if (base != null) return error.InvalidPackageInfo;
            base = value;
        } else if (std.mem.eql(u8, key, "pkgver")) {
            if (version != null) return error.InvalidPackageInfo;
            version = value;
        } else if (std.mem.eql(u8, key, "xdata") and std.mem.startsWith(u8, value, "pkgtype=")) {
            if (saw_type) return error.InvalidPackageInfo;
            saw_type = true;
            const kind = value["pkgtype=".len..];
            if (std.mem.eql(u8, kind, "debug")) {
                package_type = .debug;
            } else if (!std.mem.eql(u8, kind, "pkg")) {
                return error.UnsupportedPackageType;
            }
        }
    }
    const parsed_name = name orelse return error.InvalidPackageInfo;
    const parsed_base = base orelse return error.InvalidPackageInfo;
    const parsed_version = version orelse return error.InvalidPackageInfo;
    if (!aur.validName(parsed_name) or !aur.validName(parsed_base) or !@import("package.zig").validVersion(parsed_version))
        return error.InvalidPackageInfo;
    const owned_name = try a.dupe(u8, parsed_name);
    errdefer a.free(owned_name);
    const owned_base = try a.dupe(u8, parsed_base);
    errdefer a.free(owned_base);
    const owned_version = try a.dupe(u8, parsed_version);
    return .{ .name = owned_name, .base = owned_base, .version = owned_version, .package_type = package_type };
}

/// Require every .SRCINFO output exactly once. makepkg may additionally emit
/// generated -debug packages; accept only pkgtype=debug artifacts whose base,
/// version, and matching declared parent package all agree.
pub fn validatePackageOutputs(actual: []const Identity, expected: []const []const u8, expected_base: []const u8, expected_version: []const u8) !void {
    var regular_count: usize = 0;
    for (actual, 0..) |identity, index| {
        if (!std.mem.eql(u8, identity.base, expected_base)) return error.PackageOutputMismatch;
        if (!std.mem.eql(u8, identity.version, expected_version)) return error.PackageVersionMismatch;
        for (actual[0..index]) |prior| if (std.mem.eql(u8, identity.name, prior.name)) return error.DuplicatePackageOutput;
        var expected_index: ?usize = null;
        for (expected, 0..) |name, i| if (std.mem.eql(u8, identity.name, name)) {
            expected_index = i;
            break;
        };
        if (expected_index) |_| {
            if (identity.package_type != .regular) return error.PackageOutputMismatch;
            regular_count += 1;
            continue;
        }
        if (identity.package_type != .debug or !std.mem.endsWith(u8, identity.name, "-debug")) return error.PackageOutputMismatch;
        const parent = identity.name[0 .. identity.name.len - "-debug".len];
        var parent_found = false;
        for (expected) |name| if (std.mem.eql(u8, parent, name)) {
            parent_found = true;
            break;
        };
        if (!parent_found) return error.PackageOutputMismatch;
    }
    if (regular_count != expected.len) return error.PackageOutputMismatch;
}

fn validateArtifact(a: std.mem.Allocator, io: std.Io, path: []const u8, prefix: []const u8, previous: []const []u8) ![]u8 {
    if (!std.mem.startsWith(u8, path, prefix)) return error.ArtifactOutsideBuildDirectory;
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return error.InvalidArtifact;
    if (stat.kind != .file) return error.InvalidArtifact;
    const canonical_z = try std.Io.Dir.realPathFileAbsoluteAlloc(io, path, a);
    defer a.free(canonical_z);
    const canonical = try a.dupe(u8, canonical_z);
    errdefer a.free(canonical);
    if (!std.mem.startsWith(u8, canonical, prefix) or !isPackageArchive(canonical)) return error.ArtifactOutsideBuildDirectory;
    for (previous) |prior| if (std.mem.eql(u8, prior, canonical)) return error.DuplicateArtifact;
    return canonical;
}

fn isPackageArchive(path: []const u8) bool {
    const name = std.fs.path.basename(path);
    if (std.mem.endsWith(u8, name, ".sig")) return false;
    const marker = std.mem.indexOf(u8, name, ".pkg.tar") orelse return false;
    const suffix = name[marker + ".pkg.tar".len ..];
    return suffix.len == 0 or suffix[0] == '.' and suffix.len > 1;
}

fn safeRelativePath(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) return false;
    var parts = std.mem.tokenizeScalar(u8, path, '/');
    while (parts.next()) |part| if (std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".")) return false;
    return true;
}

fn requireUnprivileged() !void {
    if (linux.geteuid() == 0) return error.RefusingRootBuild;
}

test "reviewed commit materialization uses a local repository and never overwrites" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const repo = try std.fs.path.join(a, &.{ root, "repo" });
    defer a.free(repo);
    const build_root = try std.fs.path.join(a, &.{ root, "builds" });
    defer a.free(build_root);
    try std.Io.Dir.cwd().createDirPath(io, repo);
    try std.Io.Dir.cwd().createDirPath(io, build_root);
    const init = try process.capture(a, io, &.{ "git", "-C", repo, "init", "--quiet" });
    defer init.deinit();
    try std.testing.expectEqual(@as(u8, 0), init.code());
    const source = try std.fs.path.join(a, &.{ repo, "PKGBUILD" });
    defer a.free(source);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = source, .data = "# test data only\n" });
    const add = try process.capture(a, io, &.{ "git", "-C", repo, "add", "PKGBUILD" });
    defer add.deinit();
    try std.testing.expectEqual(@as(u8, 0), add.code());
    const commit = try process.capture(a, io, &.{ "git", "-C", repo, "-c", "user.name=zay test", "-c", "user.email=zay@example.invalid", "commit", "--quiet", "-m", "fixture" });
    defer commit.deinit();
    try std.testing.expectEqual(@as(u8, 0), commit.code());
    const head = try git.head(a, io, repo);
    defer a.free(head);
    if (linux.geteuid() != 0) {
        var tree = try prepare(a, io, repo, head, build_root, "demo");
        defer tree.deinit();
        try std.testing.expectEqualStrings(head, tree.revision);
        const copied = try std.fs.path.join(a, &.{ tree.path, "PKGBUILD" });
        defer a.free(copied);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, copied, a, .limited(256));
        defer a.free(bytes);
        try std.testing.expectEqualStrings("# test data only\n", bytes);
        var second = try prepare(a, io, repo, head, build_root, "demo");
        defer second.deinit();
        try std.testing.expect(!std.mem.eql(u8, tree.path, second.path));
    }
}

test "invalid base and revision never reach git archive" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidPackageBase, prepare(a, std.testing.io, "/not-used", "0123456789abcdef0123456789abcdef01234567", "/not-used", "../escape"));
    try std.testing.expectError(error.InvalidRevision, prepare(a, std.testing.io, "/not-used", "branch", "/not-used", "demo"));
}

test "archive attribute substitutions cannot alter reviewed build files" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const repo = try std.fs.path.join(a, &.{ root, "repo" });
    defer a.free(repo);
    const build_root = try std.fs.path.join(a, &.{ root, "builds" });
    defer a.free(build_root);
    try std.Io.Dir.cwd().createDirPath(io, repo);
    try std.Io.Dir.cwd().createDirPath(io, build_root);
    const init = try process.capture(a, io, &.{ "git", "-C", repo, "init", "--quiet" });
    defer init.deinit();
    try std.testing.expectEqual(@as(u8, 0), init.code());
    const attrs = try std.fs.path.join(a, &.{ repo, ".gitattributes" });
    defer a.free(attrs);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = attrs, .data = "PKGBUILD export-subst\n" });
    const pkgbuild = try std.fs.path.join(a, &.{ repo, "PKGBUILD" });
    defer a.free(pkgbuild);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = pkgbuild, .data = "# $Format:%H$\n" });
    const add = try process.capture(a, io, &.{ "git", "-C", repo, "add", ".gitattributes", "PKGBUILD" });
    defer add.deinit();
    try std.testing.expectEqual(@as(u8, 0), add.code());
    const commit = try process.capture(a, io, &.{ "git", "-C", repo, "-c", "user.name=zay test", "-c", "user.email=zay@example.invalid", "commit", "--quiet", "-m", "fixture" });
    defer commit.deinit();
    try std.testing.expectEqual(@as(u8, 0), commit.code());
    const revision = try git.head(a, io, repo);
    defer a.free(revision);
    if (linux.geteuid() != 0) {
        var tree = try prepare(a, io, repo, revision, build_root, "demo");
        defer tree.deinit();
        try std.testing.expectError(error.ReviewFileMismatch, verifyReviewedFiles(a, io, repo, revision, tree, &.{"PKGBUILD"}));
    }
}

test "artifact list accepts only regular package files in build tree" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const build_dir = try std.fs.path.join(a, &.{ root, "builds with spaces" });
    defer a.free(build_dir);
    try std.Io.Dir.cwd().createDirPath(io, build_dir);
    const artifact = try std.fs.path.join(a, &.{ build_dir, "demo-1-1-x86_64.pkg.tar.zst" });
    defer a.free(artifact);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = artifact, .data = "inert test bytes" });
    const debug_artifact = try std.fs.path.join(a, &.{ build_dir, "demo-debug-1-1-x86_64.pkg.tar.zst" });
    defer a.free(debug_artifact);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = debug_artifact, .data = "inert debug bytes" });
    const spaced_artifact = try std.fs.path.join(a, &.{ build_dir, "demo tools-1-1-any.pkg.tar.xz" });
    defer a.free(spaced_artifact);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = spaced_artifact, .data = "inert split bytes" });
    const gzip_artifact = try std.fs.path.join(a, &.{ build_dir, "demo-1-1-any.pkg.tar.gz" });
    defer a.free(gzip_artifact);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = gzip_artifact, .data = "inert gzip bytes" });
    const plain_artifact = try std.fs.path.join(a, &.{ build_dir, "demo-1-1-any.pkg.tar" });
    defer a.free(plain_artifact);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = plain_artifact, .data = "inert plain bytes" });
    const signature = try std.fmt.allocPrint(a, "{s}.sig", .{artifact});
    defer a.free(signature);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = signature, .data = "detached signature" });
    const outside = try std.fs.path.join(a, &.{ root, "outside.pkg.tar.zst" });
    defer a.free(outside);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = outside, .data = "inert test bytes" });
    var found = try parsePackagelist(a, io, build_dir, artifact);
    defer found.deinit();
    try std.testing.expectEqual(@as(usize, 1), found.paths.len);
    var discovered = try discoverArtifacts(a, io, build_dir);
    defer discovered.deinit();
    try std.testing.expectEqual(@as(usize, 5), discovered.paths.len);
    const listed_text = try std.fmt.allocPrint(a, "{s}\n{s}\n{s}\n", .{ artifact, debug_artifact, spaced_artifact });
    defer a.free(listed_text);
    var listed = try parsePackagelist(a, io, build_dir, listed_text);
    defer listed.deinit();
    try std.testing.expectEqual(@as(usize, 3), listed.paths.len);
    const traversal = try std.fmt.allocPrint(a, "{s}/../outside.pkg.tar.zst", .{build_dir});
    defer a.free(traversal);
    try std.testing.expectError(error.ArtifactOutsideBuildDirectory, parsePackagelist(a, io, build_dir, traversal));
    try std.testing.expectError(error.NoArtifacts, parsePackagelist(a, io, build_dir, "\n"));
    try std.testing.expectError(error.InvalidArtifact, parsePackagelist(a, io, build_dir, "PKGBUILD"));
}

test "artifact discovery rejects package symlinks" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const build_dir = try std.fs.path.join(a, &.{ root, "build" });
    defer a.free(build_dir);
    try std.Io.Dir.cwd().createDirPath(io, build_dir);
    const target = try std.fs.path.join(a, &.{ root, "payload" });
    defer a.free(target);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = target, .data = "not a package" });
    const linked = try std.fs.path.join(a, &.{ build_dir, "fake-1-1-x86_64.pkg.tar.zst" });
    defer a.free(linked);
    try std.Io.Dir.cwd().symLink(io, target, linked, .{});
    try std.testing.expectError(error.InvalidArtifact, discoverArtifacts(a, io, build_dir));
}

test "parse PKGINFO identifies regular and generated debug package outputs" {
    const a = std.testing.allocator;
    var regular = try parsePackageInfo(a,
        \\# Generated by makepkg
        \\pkgname = hello
        \\pkgbase = hello
        \\xdata = pkgtype=pkg
        \\pkgver = 2.12.1-2
        \\arch = x86_64
    );
    defer regular.deinit(a);
    try std.testing.expectEqualStrings("hello", regular.name);
    try std.testing.expectEqualStrings("hello", regular.base);
    try std.testing.expectEqual(PackageType.regular, regular.package_type);

    var debug = try parsePackageInfo(a,
        \\pkgname = hello-debug
        \\pkgbase = hello
        \\xdata = pkgtype=debug
        \\pkgver = 2.12.1-2
    );
    defer debug.deinit(a);
    try std.testing.expectEqual(PackageType.debug, debug.package_type);
    try validatePackageOutputs(&.{ regular, debug }, &.{"hello"}, "hello", "2.12.1-2");
    try std.testing.expectError(error.InvalidPackageInfo, parsePackageInfo(a, "pkgname = hello\npkgver = 1-1\n"));
    try std.testing.expectError(error.UnsupportedPackageType, parsePackageInfo(a,
        \\pkgname = hello
        \\pkgbase = hello
        \\pkgver = 1-1
        \\xdata = pkgtype=source
    ));
}

test "split outputs include only matching generated debug archives" {
    const a = std.testing.allocator;
    var main = try parsePackageInfo(a, "pkgname = hello\npkgbase = hello\npkgver = 2.12.1-2\n");
    defer main.deinit(a);
    var docs = try parsePackageInfo(a, "pkgname = hello-docs\npkgbase = hello\npkgver = 2.12.1-2\nxdata = pkgtype=pkg\n");
    defer docs.deinit(a);
    var main_debug = try parsePackageInfo(a, "pkgname = hello-debug\npkgbase = hello\npkgver = 2.12.1-2\nxdata = pkgtype=debug\n");
    defer main_debug.deinit(a);
    var docs_debug = try parsePackageInfo(a, "pkgname = hello-docs-debug\npkgbase = hello\npkgver = 2.12.1-2\nxdata = pkgtype=debug\n");
    defer docs_debug.deinit(a);
    const expected = [_][]const u8{ "hello", "hello-docs" };
    try validatePackageOutputs(&.{ main, docs, main_debug, docs_debug }, &expected, "hello", "2.12.1-2");
    try std.testing.expectError(error.PackageOutputMismatch, validatePackageOutputs(&.{ main, main_debug }, &expected, "hello", "2.12.1-2"));
    try std.testing.expectError(error.DuplicatePackageOutput, validatePackageOutputs(&.{ main, docs, main_debug, docs_debug, docs_debug }, &expected, "hello", "2.12.1-2"));
    try std.testing.expectError(error.PackageVersionMismatch, validatePackageOutputs(&.{ main, docs, main_debug, docs_debug }, &expected, "hello", "2.12.1-3"));
    try std.testing.expectError(error.PackageOutputMismatch, validatePackageOutputs(&.{ main, docs, main_debug, docs_debug }, &expected, "other-base", "2.12.1-2"));
}
