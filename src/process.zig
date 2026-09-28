const std = @import("std");
pub const Result = struct {
    allocator: std.mem.Allocator,
    stdout: []u8,
    stderr: []u8,
    term: std.process.Child.Term,
    pub fn deinit(self: Result) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }
    pub fn code(self: Result) u8 {
        return exitCode(self.term);
    }
};
pub fn exitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        .signal => |signal| @intCast(@min(255, 128 + @intFromEnum(signal))),
        else => 1,
    };
}
pub fn capture(a: std.mem.Allocator, io: std.Io, argv: []const []const u8) !Result {
    return captureAt(a, io, argv, .inherit);
}
pub fn captureAt(a: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: std.process.Child.Cwd) !Result {
    return captureWithLimits(a, io, argv, cwd, 16 * 1024 * 1024, 1024 * 1024);
}
pub fn captureWithLimits(a: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: std.process.Child.Cwd, stdout_limit: usize, stderr_limit: usize) !Result {
    const r = try std.process.run(a, io, .{
        .argv = argv,
        .cwd = cwd,
        .expand_arg0 = .expand,
        .stdout_limit = .limited(stdout_limit),
        .stderr_limit = .limited(stderr_limit),
    });
    return .{ .allocator = a, .stdout = r.stdout, .stderr = r.stderr, .term = r.term };
}
pub fn inherit(io: std.Io, argv: []const []const u8) !u8 {
    return inheritAt(io, argv, .inherit);
}
pub fn inheritAt(io: std.Io, argv: []const []const u8, cwd: std.process.Child.Cwd) !u8 {
    var child = try std.process.spawn(io, .{ .argv = argv, .cwd = cwd, .expand_arg0 = .expand });
    defer child.kill(io);
    return exitCode(try child.wait(io));
}
test "exit status including signals" {
    try std.testing.expectEqual(@as(u8, 7), exitCode(.{ .exited = 7 }));
    try std.testing.expectEqual(@as(u8, 143), exitCode(.{ .signal = .TERM }));
}

test "capture literal arguments without a shell" {
    const result = try capture(std.testing.allocator, std.testing.io, &.{ "/usr/bin/printf", "%s", "$(false); * -- a b" });
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 0), result.code());
    try std.testing.expectEqualStrings("$(false); * -- a b", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}
test "capture can use a controlled working directory" {
    const result = try captureAt(std.testing.allocator, std.testing.io, &.{"/usr/bin/pwd"}, .{ .path = "/usr" });
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 0), result.code());
    try std.testing.expectEqualStrings("/usr\n", result.stdout);
}
test "missing executable and nonzero exit" {
    try std.testing.expectError(error.FileNotFound, capture(std.testing.allocator, std.testing.io, &.{"/zay-test-executable-does-not-exist"}));
    const result = try capture(std.testing.allocator, std.testing.io, &.{"/usr/bin/false"});
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 1), result.code());
}
