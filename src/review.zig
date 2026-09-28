const std = @import("std");
const linux = std.os.linux;
const aur = @import("aur.zig");

/// Trust is attached to the immutable Git object ID, never a branch name or
/// timestamp. A fetched revision is trusted only when it exactly matches this.
pub const Status = enum { first_seen, unchanged, changed };

pub fn classify(reviewed: ?[]const u8, candidate: []const u8) !Status {
    if (!validObjectId(candidate)) return error.InvalidRevision;
    const old = reviewed orelse return .first_seen;
    if (!validObjectId(old)) return error.InvalidRevision;
    return if (std.mem.eql(u8, old, candidate)) .unchanged else .changed;
}

pub fn validObjectId(value: []const u8) bool {
    if (value.len != 40 and value.len != 64) return false;
    for (value) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

/// A tiny per-package-base trust store. The caller supplies zay's cache-owned
/// directory; entries contain only the reviewed commit ID and are atomically
/// replaced so an interrupted write cannot create a partial approval.
pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: []const u8,

    pub fn load(self: Store, base: []const u8) !?[]u8 {
        const filename = try self.statePath(base);
        defer self.allocator.free(filename);
        var stat: linux.Statx = undefined;
        const zpath = try self.allocator.dupeZ(u8, filename);
        defer self.allocator.free(zpath);
        const result = linux.statx(linux.AT.FDCWD, zpath, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .MODE = true, .UID = true }, &stat);
        switch (linux.errno(result)) {
            .NOENT => return null,
            .SUCCESS => {},
            else => return error.UnsafeReviewState,
        }
        if (!linux.S.ISREG(stat.mode) or stat.uid != linux.geteuid() or (stat.mode & (linux.S.IWGRP | linux.S.IWOTH)) != 0)
            return error.UnsafeReviewState;
        var file = try std.Io.Dir.cwd().openFile(self.io, filename, .{ .follow_symlinks = false });
        defer file.close(self.io);
        var reader = file.reader(self.io, &.{});
        const bytes = try reader.interface.allocRemaining(self.allocator, .limited(66));
        defer self.allocator.free(bytes);
        const text = std.mem.trim(u8, bytes, "\r\n");
        if (!validObjectId(text)) return error.InvalidReviewState;
        return try self.allocator.dupe(u8, text);
    }

    pub fn save(self: Store, base: []const u8, commit: []const u8) !void {
        if (!aur.validName(base)) return error.InvalidPackageBase;
        if (!validObjectId(commit)) return error.InvalidRevision;
        const filename = try self.statePath(base);
        defer self.allocator.free(filename);
        var dir = try std.Io.Dir.cwd().openDir(self.io, self.directory, .{ .iterate = true, .follow_symlinks = false });
        defer dir.close(self.io);
        const exists = std.Io.Dir.cwd().statFile(self.io, filename, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (exists) |stat| {
            if (stat.kind != .file) return error.UnsafeReviewState;
            try validateOwnership(self.allocator, filename);
        }
        var atomic = try dir.createFileAtomic(self.io, base, .{ .replace = exists != null, .make_path = false });
        defer atomic.deinit(self.io);
        try atomic.file.writeStreamingAll(self.io, commit);
        try atomic.file.writeStreamingAll(self.io, "\n");
        if (exists != null) try atomic.replace(self.io) else try atomic.link(self.io);
    }

    fn statePath(self: Store, base: []const u8) ![]u8 {
        if (!aur.validName(base)) return error.InvalidPackageBase;
        return std.fs.path.join(self.allocator, &.{ self.directory, base });
    }
};

fn validateOwnership(a: std.mem.Allocator, path: []const u8) !void {
    const zpath = try a.dupeZ(u8, path);
    defer a.free(zpath);
    var stat: linux.Statx = undefined;
    const result = linux.statx(linux.AT.FDCWD, zpath, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .MODE = true, .UID = true }, &stat);
    if (linux.errno(result) != .SUCCESS or !linux.S.ISREG(stat.mode) or stat.uid != linux.geteuid() or (stat.mode & (linux.S.IWGRP | linux.S.IWOTH)) != 0)
        return error.UnsafeReviewState;
}

test "review approval belongs to an exact immutable revision" {
    const first = "0123456789abcdef0123456789abcdef01234567";
    const same = "0123456789abcdef0123456789abcdef01234567";
    const changed = "1123456789abcdef0123456789abcdef01234567";
    try std.testing.expectEqual(Status.first_seen, try classify(null, first));
    try std.testing.expectEqual(Status.unchanged, try classify(first, same));
    try std.testing.expectEqual(Status.changed, try classify(first, changed));
}

test "invalid revision identities cannot become approvals" {
    try std.testing.expectError(error.InvalidRevision, classify(null, "branch-name"));
    try std.testing.expectError(error.InvalidRevision, classify("bad", "0123456789abcdef0123456789abcdef01234567"));
}

test "review store persists exact commits and rejects unsafe package bases" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const review_dir = try std.fs.path.join(a, &.{ root, "reviewed" });
    defer a.free(review_dir);
    try std.Io.Dir.cwd().createDirPath(io, review_dir);
    const store: Store = .{ .allocator = a, .io = io, .directory = review_dir };
    const commit = "0123456789abcdef0123456789abcdef01234567";
    try store.save("demo", commit);
    const saved = (try store.load("demo")).?;
    defer a.free(saved);
    try std.testing.expectEqualStrings(commit, saved);
    try std.testing.expectError(error.InvalidPackageBase, store.load("../outside"));
}
