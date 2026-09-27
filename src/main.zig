const std = @import("std");
const app = @import("app.zig");
pub fn main(init: std.process.Init) void {
    const status = app.run(init) catch |err| blk: {
        std.debug.print("error: {s}\n", .{@import("diagnostic.zig").message(err)});
        break :blk 2;
    };
    if (status != 0) std.process.exit(status);
}
test {
    _ = @import("cli.zig");
    _ = @import("aur.zig");
    _ = @import("process.zig");
    _ = @import("pacman.zig");
    _ = @import("output.zig");
    _ = @import("diagnostic.zig");
    _ = @import("dependency.zig");
    _ = @import("resolver.zig");
    _ = @import("catalog.zig");
    _ = @import("resolver_test.zig");
}
