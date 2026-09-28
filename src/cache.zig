const std = @import("std");
const linux = std.os.linux;

fn validateDirectory(a: std.mem.Allocator, path: []const u8) !void {
    const zpath = try a.dupeZ(u8, path);
    defer a.free(zpath);
    var stat: linux.Statx = undefined;
    const result = linux.statx(linux.AT.FDCWD, zpath, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .MODE = true, .UID = true }, &stat);
    switch (linux.errno(result)) {
        .SUCCESS => {},
        .NOENT => return error.FileNotFound,
        else => return error.UnsafeCachePath,
    }
    if (!linux.S.ISDIR(stat.mode) or
        stat.uid != linux.geteuid() or
        (stat.mode & (linux.S.IWGRP | linux.S.IWOTH)) != 0)
        return error.UnsafeCachePath;
}

pub const Paths = struct {
    allocator: std.mem.Allocator,
    root: []u8,
    repos: []u8,
    builds: []u8,
    packages: []u8,
    reviews: []u8,

    pub fn deinit(self: *Paths) void {
        self.allocator.free(self.root);
        self.allocator.free(self.repos);
        self.allocator.free(self.builds);
        self.allocator.free(self.packages);
        self.allocator.free(self.reviews);
    }

    pub fn create(
        allocator: std.mem.Allocator,
        environ: *const std.process.Environ.Map,
    ) !Paths {
        const base = if (environ.get("XDG_CACHE_HOME")) |xdg|
            xdg
        else if (environ.get("HOME")) |home|
            try std.fs.path.join(allocator, &.{ home, ".cache" })
        else
            return error.CacheHomeUnavailable;

        const owns_base = environ.get("XDG_CACHE_HOME") == null;
        defer if (owns_base) allocator.free(base);

        const root = try std.fs.path.join(allocator, &.{ base, "zay" });
        errdefer allocator.free(root);

        const repos = try std.fs.path.join(allocator, &.{ root, "repos" });
        errdefer allocator.free(repos);

        const builds = try std.fs.path.join(allocator, &.{ root, "builds" });
        errdefer allocator.free(builds);

        const packages = try std.fs.path.join(allocator, &.{ root, "packages" });
        errdefer allocator.free(packages);
        const reviews = try std.fs.path.join(allocator, &.{ root, "reviews" });
        errdefer allocator.free(reviews);

        return .{
            .allocator = allocator,
            .root = root,
            .repos = repos,
            .builds = builds,
            .packages = packages,
            .reviews = reviews,
        };
    }

    pub fn ensure(self: *const Paths, io: std.Io) !void {
        // Refuse unsafe existing leaves before createDirPath can follow them.
        for ([_][]const u8{ self.root, self.repos, self.builds, self.packages, self.reviews }) |path| {
            validateDirectory(self.allocator, path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        }
        try std.Io.Dir.cwd().createDirPath(io, self.repos);
        try std.Io.Dir.cwd().createDirPath(io, self.builds);
        try std.Io.Dir.cwd().createDirPath(io, self.packages);
        try std.Io.Dir.cwd().createDirPath(io, self.reviews);
        try validateDirectory(self.allocator, self.root);
        try validateDirectory(self.allocator, self.repos);
        try validateDirectory(self.allocator, self.builds);
        try validateDirectory(self.allocator, self.packages);
        try validateDirectory(self.allocator, self.reviews);
    }
};

test "uses XDG_CACHE_HOME when available" {
    const a = std.testing.allocator;

    var env = std.process.Environ.Map.init(a);
    defer env.deinit();

    try env.put("XDG_CACHE_HOME", "/tmp/zay-xdg-test");
    try env.put("HOME", "/home/ignored");

    var paths = try Paths.create(a, &env);
    defer paths.deinit();

    try std.testing.expectEqualStrings("/tmp/zay-xdg-test/zay", paths.root);
    try std.testing.expectEqualStrings("/tmp/zay-xdg-test/zay/repos", paths.repos);
    try std.testing.expectEqualStrings("/tmp/zay-xdg-test/zay/builds", paths.builds);
    try std.testing.expectEqualStrings("/tmp/zay-xdg-test/zay/packages", paths.packages);
    try std.testing.expectEqualStrings("/tmp/zay-xdg-test/zay/reviews", paths.reviews);
}

test "falls back to HOME cache" {
    const a = std.testing.allocator;

    var env = std.process.Environ.Map.init(a);
    defer env.deinit();

    try env.put("HOME", "/home/zei");

    var paths = try Paths.create(a, &env);
    defer paths.deinit();

    try std.testing.expectEqualStrings("/home/zei/.cache/zay", paths.root);
}

test "fails without cache home or HOME" {
    const a = std.testing.allocator;

    var env = std.process.Environ.Map.init(a);
    defer env.deinit();

    try std.testing.expectError(
        error.CacheHomeUnavailable,
        Paths.create(a, &env),
    );
}

test "ensure creates user-owned cache directories and rejects a symlinked cache root" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const base = try std.fs.path.join(a, &.{ root, "cache-base" });
    defer a.free(base);
    try std.Io.Dir.cwd().createDirPath(io, base);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("XDG_CACHE_HOME", base);
    var paths = try Paths.create(a, &env);
    defer paths.deinit();
    try paths.ensure(io);
    try validateDirectory(a, paths.root);
    try validateDirectory(a, paths.repos);

    const target = try std.fs.path.join(a, &.{ root, "target" });
    defer a.free(target);
    try std.Io.Dir.cwd().createDirPath(io, target);
    const base_two = try std.fs.path.join(a, &.{ root, "cache-base-two" });
    defer a.free(base_two);
    try std.Io.Dir.cwd().createDirPath(io, base_two);
    try env.put("XDG_CACHE_HOME", base_two);
    var linked_paths = try Paths.create(a, &env);
    defer linked_paths.deinit();
    try std.Io.Dir.cwd().symLink(io, target, linked_paths.root, .{});
    try std.testing.expectError(error.UnsafeCachePath, linked_paths.ensure(io));
    const outside_repos = try std.fs.path.join(a, &.{ target, "repos" });
    defer a.free(outside_repos);
    try std.testing.expect(!try @import("git.zig").exists(io, outside_repos));
}
