/// Borrowed metadata; storage belongs to the parsed AUR response.
pub const Package = struct {
    name: []const u8,
    base: []const u8,
    version: []const u8,
    description: ?[]const u8,
    url: ?[]const u8,
    maintainer: ?[]const u8,
    votes: u64,
    popularity: f64,
    out_of_date: ?i64,
    depends: []const []const u8,
    make_depends: []const []const u8,
    check_depends: []const []const u8,
    opt_depends: []const []const u8 = &.{},
    provides: []const []const u8,
    conflicts: []const []const u8 = &.{},
    replaces: []const []const u8 = &.{},
};

pub fn validVersion(version: []const u8) bool {
    if (version.len == 0) return false;
    for (version) |ch| if (ch <= 32 or ch >= 127 or @import("std").mem.indexOfScalar(u8, "<>=/", ch) != null) return false;
    return true;
}
