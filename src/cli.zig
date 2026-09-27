const std = @import("std");
pub const Operation = enum { sync, query, help, version };
pub const Command = struct {
    operation: Operation,
    search: bool = false,
    info: bool = false,
    foreign: bool = false,
    noconfirm: bool = false,
    print: bool = false,
    operands: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *Command, allocator: std.mem.Allocator) void {
        self.operands.deinit(allocator);
    }
};
pub const ParseError = error{ MissingOperation, ConflictingOperations, UnsupportedOption, UnsupportedCombination, MissingOperand, TooManyOperands, EmptyOperand, InstallationNotImplemented };

fn operation(current: *?Operation, value: Operation) ParseError!void {
    if (current.* != null) return error.ConflictingOperations;
    current.* = value;
}

/// Owns the operand array; strings borrow the caller's argument storage.
pub fn parse(allocator: std.mem.Allocator, args: []const []const u8) !Command {
    var cmd: Command = .{ .operation = .help };
    errdefer cmd.deinit(allocator);
    var op: ?Operation = null;
    var end_options = false;
    for (args) |arg| {
        if (arg.len == 0) return error.EmptyOperand;
        if (!end_options and std.mem.eql(u8, arg, "--")) {
            end_options = true;
        } else if (!end_options and std.mem.startsWith(u8, arg, "--")) {
            if (std.mem.eql(u8, arg, "--noconfirm")) {
                cmd.noconfirm = true;
            } else if (std.mem.eql(u8, arg, "--print")) {
                cmd.print = true;
            } else if (std.mem.eql(u8, arg, "--sync")) {
                try operation(&op, .sync);
            } else if (std.mem.eql(u8, arg, "--query")) {
                try operation(&op, .query);
            } else if (std.mem.eql(u8, arg, "--help")) {
                try operation(&op, .help);
            } else if (std.mem.eql(u8, arg, "--version")) {
                try operation(&op, .version);
            } else if (std.mem.eql(u8, arg, "--search") and !cmd.search) {
                cmd.search = true;
            } else if (std.mem.eql(u8, arg, "--info") and !cmd.info) {
                cmd.info = true;
            } else if (std.mem.eql(u8, arg, "--foreign") and !cmd.foreign) {
                cmd.foreign = true;
            } else return error.UnsupportedOption;
        } else if (!end_options and arg[0] == '-') {
            if (arg.len == 1) return error.UnsupportedOption;
            for (arg[1..]) |flag| switch (flag) {
                'S' => try operation(&op, .sync),
                'Q' => try operation(&op, .query),
                'h' => try operation(&op, .help),
                'V' => try operation(&op, .version),
                'p' => cmd.print = true,
                's' => {
                    if (cmd.search) return error.UnsupportedCombination;
                    cmd.search = true;
                },
                'i' => {
                    if (cmd.info) return error.UnsupportedCombination;
                    cmd.info = true;
                },
                'm' => {
                    if (cmd.foreign) return error.UnsupportedCombination;
                    cmd.foreign = true;
                },
                else => return error.UnsupportedOption,
            };
        } else try cmd.operands.append(allocator, arg);
    }
    cmd.operation = op orelse return error.MissingOperation;
    if (cmd.print and (cmd.operation != .sync or cmd.search or cmd.info or cmd.foreign)) return error.UnsupportedCombination;
    if (@as(u8, @intFromBool(cmd.search)) + @intFromBool(cmd.info) + @intFromBool(cmd.foreign) > 1) return error.UnsupportedCombination;
    switch (cmd.operation) {
        .help, .version => if (cmd.search or cmd.info or cmd.foreign or cmd.operands.items.len != 0) return error.UnsupportedCombination,
        .sync => {
            if (cmd.foreign) return error.UnsupportedCombination;
            if (cmd.operands.items.len == 0) return error.MissingOperand;
            if (!cmd.search and !cmd.info and !cmd.print) return error.InstallationNotImplemented;
            // Pacman uses regex; AUR uses substrings. Do not pretend multi-term semantics agree.
            if (cmd.search and cmd.operands.items.len != 1) return error.TooManyOperands;
        },
        .query => {},
    }
    return cmd;
}

pub fn message(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingOperation => "an operation is required; see --help",
        error.ConflictingOperations => "choose exactly one operation",
        error.UnsupportedOption => "unknown or unsupported option; see --help",
        error.UnsupportedCombination => "unsupported option combination; see --help",
        error.MissingOperand => "this operation requires a query or package name",
        error.TooManyOperands => "AUR search currently accepts exactly one query; quote queries containing spaces",
        error.EmptyOperand => "empty operands are not allowed",
        error.InstallationNotImplemented => "installation is not implemented yet; use -Sp to print a dependency plan",
        else => @import("diagnostic.zig").message(err),
    };
}

test "combined and separate options, long options, operands and delimiter" {
    const a = std.testing.allocator;
    for ([_][]const []const u8{ &.{ "-Ss", "firefox" }, &.{ "-S", "--search", "firefox" }, &.{ "--sync", "-s", "--", "-firefox" } }) |args| {
        var c = try parse(a, args);
        defer c.deinit(a);
        try std.testing.expect(c.operation == .sync and c.search);
        try std.testing.expectEqual(@as(usize, 1), c.operands.items.len);
    }
    for ([_][]const []const u8{ &.{"-Q"}, &.{ "-Qs", "foo" }, &.{ "-Qi", "foo" }, &.{"-Qm"}, &.{ "-Si", "foo", "bar" }, &.{"--help"}, &.{"--version"} }) |args| {
        var c = try parse(a, args);
        defer c.deinit(a);
    }
}
test "invalid invocations" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.MissingOperation, parse(a, &.{}));
    try std.testing.expectError(error.MissingOperand, parse(a, &.{"-Ss"}));
    try std.testing.expectError(error.ConflictingOperations, parse(a, &.{"-SQ"}));
    try std.testing.expectError(error.UnsupportedCombination, parse(a, &.{ "-Ssi", "x" }));
    try std.testing.expectError(error.InstallationNotImplemented, parse(a, &.{ "-S", "x" }));
    try std.testing.expectError(error.UnsupportedOption, parse(a, &.{"-Syu"}));
    try std.testing.expectError(error.MissingOperation, parse(a, &.{"--noconfirm"}));
    try std.testing.expectError(error.TooManyOperands, parse(a, &.{ "-Ss", "x", "y" }));
    try std.testing.expectError(error.EmptyOperand, parse(a, &.{ "-Ss", "" }));
}

fn allocationScenario(a: std.mem.Allocator) !void {
    var c = try parse(a, &.{ "-Si", "foo", "bar" });
    defer c.deinit(a);
}
test "parser allocation failures release operand array" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationScenario, .{});
}

test "noconfirm is a global option and never bypasses operation validation" {
    const a = std.testing.allocator;
    for ([_][]const []const u8{
        &.{ "--noconfirm", "-Ss", "firefox" },
        &.{ "-Si", "firefox", "--noconfirm" },
        &.{ "-Q", "--noconfirm", "--noconfirm" },
    }) |args| {
        var c = try parse(a, args);
        defer c.deinit(a);
        try std.testing.expect(c.noconfirm);
    }
    var literal = try parse(a, &.{ "-Ss", "--", "--noconfirm" });
    defer literal.deinit(a);
    try std.testing.expect(!literal.noconfirm);
    try std.testing.expectEqualStrings("--noconfirm", literal.operands.items[0]);
    try std.testing.expectError(error.InstallationNotImplemented, parse(a, &.{ "-S", "--noconfirm", "foo" }));
    try std.testing.expectError(error.UnsupportedOption, parse(a, &.{ "-Q", "--noconfirm=yes" }));
}

test "read-only sync plan syntax" {
    const a = std.testing.allocator;
    for ([_][]const []const u8{ &.{ "-Sp", "foo>=1" }, &.{ "-S", "--print", "--noconfirm", "foo" } }) |args| {
        var cmd = try parse(a, args);
        defer cmd.deinit(a);
        try std.testing.expect(cmd.operation == .sync and cmd.print);
    }
    try std.testing.expectError(error.UnsupportedCombination, parse(a, &.{ "-Ssp", "foo" }));
    try std.testing.expectError(error.UnsupportedCombination, parse(a, &.{ "-Qp", "foo" }));
    try std.testing.expectError(error.MissingOperand, parse(a, &.{"-Sp"}));
}
