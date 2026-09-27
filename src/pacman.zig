const std = @import("std");
const process = @import("process.zig");
pub fn run(a: std.mem.Allocator, io: std.Io, flag: []const u8, targets: []const []const u8, noconfirm: bool) !process.Result {
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(a);
    try args.appendSlice(a, &.{ "pacman", flag, "--color", "never" });
    if (noconfirm) try args.append(a, "--noconfirm");
    try args.append(a, "--");
    try args.appendSlice(a, targets);
    return process.capture(a, io, args.items);
}
/// Pacman search headers start at column zero: repository/name version.
/// Returned keys borrow the captured output and must not outlive it.
pub fn searchNames(a: std.mem.Allocator, text: []const u8) !std.StringHashMap(void) {
    var names = std.StringHashMap(void).init(a);
    errdefer names.deinit();
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or std.ascii.isWhitespace(line[0])) continue;
        const slash = std.mem.indexOfScalar(u8, line, '/') orelse return error.MalformedPacmanOutput;
        const end = std.mem.indexOfScalarPos(u8, line, slash + 1, ' ') orelse return error.MalformedPacmanOutput;
        if (slash == 0 or end == slash + 1) return error.MalformedPacmanOutput;
        try names.put(line[slash + 1 .. end], {});
    }
    return names;
}
test "repository name extraction ignores descriptions and merges duplicates" {
    var n = try searchNames(std.testing.allocator, "extra/foo 1-1\n    a/b description\ncustom/foo 1-1\n    desc\ncore/bar 2\n");
    defer n.deinit();
    try std.testing.expectEqual(@as(u32, 2), n.count());
    try std.testing.expect(n.contains("foo") and n.contains("bar"));
    try std.testing.expectError(error.MalformedPacmanOutput, searchNames(std.testing.allocator, "bad output\n"));
}
