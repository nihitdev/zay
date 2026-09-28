const std = @import("std");
const process = @import("process.zig");

pub const Error = error{
    GitFailed,
    NotGitRepository,
    DestinationCollision,
    OriginMismatch,
    WorkingTreeModified,
    InvalidRevision,
};
pub const Action = enum { cloned, fetched };
pub const Revisions = struct {
    allocator: std.mem.Allocator,
    /// Commit currently selected by local HEAD. Fetch never changes this value.
    checkout: []u8,
    /// Remote tip fetched by the last ensure call (or checkout after a fresh clone).
    fetched: []u8,
    pub fn deinit(self: Revisions) void {
        self.allocator.free(self.checkout);
        self.allocator.free(self.fetched);
    }
};
pub const Acquisition = struct {
    action: Action,
    revisions: Revisions,
    pub fn deinit(self: Acquisition) void {
        self.revisions.deinit();
    }
};
const PathKind = enum { missing, directory, other };

fn pathKind(io: std.Io, path: []const u8) !PathKind {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        error.NotDir => {
            var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |file_err| switch (file_err) {
                error.FileNotFound => return .missing,
                else => return file_err,
            };
            file.close(io);
            return .other;
        },
        else => return err,
    };
    dir.close(io);
    return .directory;
}

pub fn exists(io: std.Io, path: []const u8) !bool {
    return (try pathKind(io, path)) != .missing;
}

fn command(a: std.mem.Allocator, io: std.Io, argv: []const []const u8) ![]u8 {
    const result = try process.capture(a, io, argv);
    defer result.deinit();
    if (result.code() != 0) return error.GitFailed;
    return a.dupe(u8, std.mem.trim(u8, result.stdout, " \r\n\t"));
}

fn revision(a: std.mem.Allocator, io: std.Io, path: []const u8, ref: []const u8) ![]u8 {
    const output = try command(a, io, &.{ "git", "-C", path, "rev-parse", "--verify", ref });
    errdefer a.free(output);
    if (!isObjectId(output)) return error.InvalidRevision;
    return output;
}
fn isObjectId(value: []const u8) bool {
    if (value.len != 40 and value.len != 64) return false;
    for (value) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

/// True only when path itself, after resolving symlinks, is the worktree root.
pub fn isRepository(a: std.mem.Allocator, io: std.Io, path: []const u8) !bool {
    if (try pathKind(io, path) != .directory) return false;
    const top = command(a, io, &.{ "git", "-C", path, "rev-parse", "--show-toplevel" }) catch |err| switch (err) {
        error.GitFailed => return false,
        else => return err,
    };
    defer a.free(top);
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    defer dir.close(io);
    const actual = try dir.realPathFileAlloc(io, ".", a);
    defer a.free(actual);
    return std.mem.eql(u8, top, actual);
}

fn origin(a: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return command(a, io, &.{ "git", "-C", path, "config", "--get", "remote.origin.url" });
}
fn verifyOrigin(a: std.mem.Allocator, io: std.Io, path: []const u8, expected: []const u8) !void {
    const actual = origin(a, io, path) catch |err| switch (err) {
        error.GitFailed => return error.OriginMismatch,
        else => return err,
    };
    defer a.free(actual);
    if (!std.mem.eql(u8, actual, expected)) return error.OriginMismatch;
}
fn ensureClean(a: std.mem.Allocator, io: std.Io, path: []const u8, allow_no_checkout: bool) !void {
    const status = try command(a, io, &.{ "git", "-C", path, "status", "--porcelain=v1", "--untracked-files=all" });
    defer a.free(status);
    if (status.len == 0) return;
    if (allow_no_checkout) {
        var lines = std.mem.splitScalar(u8, status, '\n');
        var has_entries = false;
        var deleted_count: usize = 0;
        var index_deleted_count: usize = 0;
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            has_entries = true;
            // --no-checkout leaves every tracked path absent. Any modified,
            // untracked, or partially materialized worktree is rejected.
            if (std.mem.startsWith(u8, line, " D ")) {
                deleted_count += 1;
            } else if (std.mem.startsWith(u8, line, "D  ")) {
                // Git versions/configurations may leave the empty checkout
                // index with staged deletions instead of worktree deletions.
                index_deleted_count += 1;
            } else return error.WorkingTreeModified;
        }
        if (has_entries) {
            const tracked = try command(a, io, &.{ "git", "-C", path, "ls-files", "-z" });
            defer a.free(tracked);
            const deleted = try command(a, io, &.{ "git", "-C", path, "ls-files", "--deleted", "-z" });
            defer a.free(deleted);
            const tracked_count = std.mem.count(u8, tracked, "\x00");
            const missing_count = std.mem.count(u8, deleted, "\x00");
            if (deleted_count != 0 and tracked_count == deleted_count and missing_count == deleted_count) return;
            if (index_deleted_count != 0 and tracked_count == 0 and missing_count == 0) {
                const committed = try command(a, io, &.{ "git", "-C", path, "ls-tree", "-r", "--name-only", "-z", "HEAD" });
                defer a.free(committed);
                if (std.mem.count(u8, committed, "\x00") == index_deleted_count) return;
            }
        }
    }
    return error.WorkingTreeModified;
}

pub fn head(a: std.mem.Allocator, io: std.Io, repository: []const u8) ![]u8 {
    if (!try isRepository(a, io, repository)) return error.NotGitRepository;
    return revision(a, io, repository, "HEAD^{commit}");
}

/// Clone a missing destination, or fetch an unchanged, expected-origin worktree.
/// Existing paths, modified worktrees, and unexpected remotes are never replaced.
pub fn ensure(a: std.mem.Allocator, io: std.Io, expected_origin: []const u8, destination: []const u8) !Acquisition {
    return ensureMode(a, io, expected_origin, destination, true);
}

/// AUR cache acquisition leaves remote files unmaterialized. Metadata can be
/// read from Git objects later, without checkout filters touching build files.
pub fn ensureNoCheckout(a: std.mem.Allocator, io: std.Io, expected_origin: []const u8, destination: []const u8) !Acquisition {
    return ensureMode(a, io, expected_origin, destination, false);
}

fn ensureMode(a: std.mem.Allocator, io: std.Io, expected_origin: []const u8, destination: []const u8, checkout_files: bool) !Acquisition {
    switch (try pathKind(io, destination)) {
        .missing => {
            const result = if (checkout_files)
                try process.capture(a, io, &.{ "git", "clone", "--", expected_origin, destination })
            else
                try process.capture(a, io, &.{ "git", "clone", "--no-checkout", "--", expected_origin, destination });
            defer result.deinit();
            if (result.code() != 0) return error.GitFailed;
            if (!try isRepository(a, io, destination)) return error.NotGitRepository;
            try verifyOrigin(a, io, destination, expected_origin);
            const checkout = try revision(a, io, destination, "HEAD^{commit}");
            errdefer a.free(checkout);
            return .{ .action = .cloned, .revisions = .{ .allocator = a, .checkout = checkout, .fetched = try a.dupe(u8, checkout) } };
        },
        .other => return error.DestinationCollision,
        .directory => {},
    }
    if (!try isRepository(a, io, destination)) return error.NotGitRepository;
    try verifyOrigin(a, io, destination, expected_origin);
    try ensureClean(a, io, destination, !checkout_files);
    const checkout = try revision(a, io, destination, "HEAD^{commit}");
    errdefer a.free(checkout);
    const result = try process.capture(a, io, &.{ "git", "-C", destination, "fetch", "--prune", "origin" });
    defer result.deinit();
    if (result.code() != 0) return error.GitFailed;
    const fetched = try revision(a, io, destination, "@{upstream}^{commit}");
    errdefer a.free(fetched);
    return .{ .action = .fetched, .revisions = .{ .allocator = a, .checkout = checkout, .fetched = fetched } };
}

test "missing path and non-repository directory are rejected" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const absent = try std.fs.path.join(a, &.{ root, "missing" });
    defer a.free(absent);
    try std.testing.expect(!try exists(io, absent));
    try std.testing.expect(!try isRepository(a, io, absent));
    try std.testing.expect(!try isRepository(a, io, root));
}

test "a directory nested in a worktree is not its repository root" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const nested = try std.fs.path.join(a, &.{ root, "nested" });
    defer a.free(nested);
    try std.Io.Dir.cwd().createDirPath(io, nested);
    const init = try process.capture(a, io, &.{ "git", "-C", root, "init", "--quiet" });
    defer init.deinit();
    try std.testing.expectEqual(@as(u8, 0), init.code());
    try std.testing.expect(try isRepository(a, io, root));
    try std.testing.expect(!try isRepository(a, io, nested));
}

test "symlink to repository root compares canonical paths" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const alias = try std.fs.path.join(a, &.{ root, "alias" });
    defer a.free(alias);
    const init = try process.capture(a, io, &.{ "git", "-C", root, "init", "--quiet" });
    defer init.deinit();
    try std.testing.expectEqual(@as(u8, 0), init.code());
    try std.Io.Dir.cwd().symLink(io, root, alias, .{});
    try std.testing.expect(try isRepository(a, io, alias));
}

fn gitOk(a: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const r = try process.capture(a, io, argv);
    defer r.deinit();
    try std.testing.expectEqual(@as(u8, 0), r.code());
}
fn makeRepo(a: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, path);
    try gitOk(a, io, &.{ "git", "-C", path, "init", "--quiet", "--bare" });
}
fn commitFile(a: std.mem.Allocator, io: std.Io, repo: []const u8, contents: []const u8) !void {
    const file_path = try std.fs.path.join(a, &.{ repo, "PKGBUILD" });
    defer a.free(file_path);
    var file = try std.Io.Dir.cwd().createFile(io, file_path, .{ .truncate = true });
    defer file.close(io);
    var buffer: [256]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(contents);
    try writer.interface.flush();
    try gitOk(a, io, &.{ "git", "-C", repo, "add", "PKGBUILD" });
    try gitOk(a, io, &.{ "git", "-C", repo, "-c", "user.name=zay test", "-c", "user.email=zay@example.invalid", "commit", "--quiet", "-m", "test" });
}

test "clone and fetch report checkout and fetched commit separately" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const remote = try std.fs.path.join(a, &.{ root, "remote.git" });
    defer a.free(remote);
    const source = try std.fs.path.join(a, &.{ root, "source" });
    defer a.free(source);
    const clone = try std.fs.path.join(a, &.{ root, "clone" });
    defer a.free(clone);
    try makeRepo(a, io, remote);
    try gitOk(a, io, &.{ "git", "clone", "--quiet", remote, source });
    try gitOk(a, io, &.{ "git", "-C", source, "config", "user.name", "zay test" });
    try gitOk(a, io, &.{ "git", "-C", source, "config", "user.email", "zay@example.invalid" });
    try commitFile(a, io, source, "first revision\n");
    try gitOk(a, io, &.{ "git", "-C", source, "push", "--quiet", "origin", "HEAD" });
    var cloned = try ensure(a, io, remote, clone);
    defer cloned.deinit();
    try std.testing.expect(cloned.action == .cloned);
    try std.testing.expectEqualStrings(cloned.revisions.checkout, cloned.revisions.fetched);
    const original = try a.dupe(u8, cloned.revisions.checkout);
    defer a.free(original);
    try commitFile(a, io, source, "second revision\n");
    try gitOk(a, io, &.{ "git", "-C", source, "push", "--quiet", "origin", "HEAD" });
    var fetched = try ensure(a, io, remote, clone);
    defer fetched.deinit();
    try std.testing.expect(fetched.action == .fetched);
    try std.testing.expectEqualStrings(original, fetched.revisions.checkout);
    try std.testing.expect(!std.mem.eql(u8, fetched.revisions.checkout, fetched.revisions.fetched));
    const checked_out = try head(a, io, clone);
    defer a.free(checked_out);
    try std.testing.expectEqualStrings(original, checked_out);
}

test "no-checkout acquisition leaves repository files unmaterialized" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const remote = try std.fs.path.join(a, &.{ root, "remote.git" });
    defer a.free(remote);
    const source = try std.fs.path.join(a, &.{ root, "source" });
    defer a.free(source);
    const destination = try std.fs.path.join(a, &.{ root, "cache" });
    defer a.free(destination);
    try makeRepo(a, io, remote);
    try gitOk(a, io, &.{ "git", "clone", "--quiet", remote, source });
    try gitOk(a, io, &.{ "git", "-C", source, "config", "user.name", "zay test" });
    try gitOk(a, io, &.{ "git", "-C", source, "config", "user.email", "zay@example.invalid" });
    try commitFile(a, io, source, "untrusted build data\n");
    try gitOk(a, io, &.{ "git", "-C", source, "push", "--quiet", "origin", "HEAD" });
    var acquired = try ensureNoCheckout(a, io, remote, destination);
    defer acquired.deinit();
    const build_file = try std.fs.path.join(a, &.{ destination, "PKGBUILD" });
    defer a.free(build_file);
    try std.testing.expect(!(try exists(io, build_file)));
    try std.testing.expectEqualStrings(acquired.revisions.checkout, acquired.revisions.fetched);
    var fetched = try ensureNoCheckout(a, io, remote, destination);
    defer fetched.deinit();
    try std.testing.expect(fetched.action == .fetched);
    try std.testing.expectEqualStrings(acquired.revisions.checkout, fetched.revisions.checkout);
    try std.testing.expectEqualStrings(acquired.revisions.fetched, fetched.revisions.fetched);
}

test "destination collisions modified repositories and origin mismatch fail closed" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const remote = try std.fs.path.join(a, &.{ root, "remote.git" });
    defer a.free(remote);
    const other = try std.fs.path.join(a, &.{ root, "other.git" });
    defer a.free(other);
    const destination = try std.fs.path.join(a, &.{ root, "destination" });
    defer a.free(destination);
    const file_path = try std.fs.path.join(a, &.{ root, "collision" });
    defer a.free(file_path);
    try makeRepo(a, io, remote);
    try makeRepo(a, io, other);
    var file = try std.Io.Dir.cwd().createFile(io, file_path, .{});
    file.close(io);
    try std.testing.expectError(error.DestinationCollision, ensure(a, io, remote, file_path));
    try std.Io.Dir.cwd().createDirPath(io, destination);
    try std.testing.expectError(error.NotGitRepository, ensure(a, io, remote, destination));
    const clone = try process.capture(a, io, &.{ "git", "clone", "--quiet", remote, destination });
    defer clone.deinit();
    try std.testing.expectEqual(@as(u8, 0), clone.code());
    try std.testing.expectError(error.OriginMismatch, ensure(a, io, other, destination));
    const dirty = try std.fs.path.join(a, &.{ destination, "untracked" });
    defer a.free(dirty);
    var dirty_file = try std.Io.Dir.cwd().createFile(io, dirty, .{});
    dirty_file.close(io);
    try std.testing.expectError(error.WorkingTreeModified, ensure(a, io, remote, destination));
}
