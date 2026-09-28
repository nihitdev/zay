const std = @import("std");
pub const Operation = enum { sync, remove, query, help, version };
pub const Command = struct {
    operation: Operation,
    search: bool = false,
    info: bool = false,
    foreign: bool = false,
    noconfirm: bool = false,
    print: bool = false,
    refresh: bool = false,
    sysupgrade: bool = false,
    recursive: bool = false,
    nosave: bool = false,
    cascade: bool = false,
    unneeded: bool = false,
    pacman_only: bool = false,
    custom_database: bool = false,
    operands: std.ArrayList([]const u8) = .empty,
    raw_args: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *Command, allocator: std.mem.Allocator) void {
        self.operands.deinit(allocator);
        self.raw_args.deinit(allocator);
    }
};
pub const ParseError = error{ MissingOperation, ConflictingOperations, UnsupportedOption, UnsupportedCombination, MissingOperand, TooManyOperands, EmptyOperand };

fn optionName(arg: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, arg, '=')) |at| arg[0..at] else arg;
}

fn needsLongValue(arg: []const u8) bool {
    const name = optionName(arg);
    inline for (.{
        "--assume-installed", "--cachedir", "--color",       "--config",  "--dbpath",
        "--hookdir",          "--ignore",   "--ignoregroup", "--logfile", "--overwrite",
        "--print-format",     "--root",     "--sysroot",     "--arch",
    }) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}

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
    var expecting_value = false;
    for (args) |arg| {
        if (arg.len == 0) return error.EmptyOperand;
        try cmd.raw_args.append(allocator, arg);
        if (expecting_value) {
            expecting_value = false;
            continue;
        }
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
            } else if (std.mem.eql(u8, arg, "--remove")) {
                try operation(&op, .remove);
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
            } else if (std.mem.eql(u8, arg, "--refresh")) {
                cmd.refresh = true;
            } else if (std.mem.eql(u8, arg, "--sysupgrade")) {
                cmd.sysupgrade = true;
            } else if (std.mem.eql(u8, arg, "--recursive")) {
                cmd.recursive = true;
            } else if (std.mem.eql(u8, arg, "--nosave")) {
                cmd.nosave = true;
            } else if (std.mem.eql(u8, arg, "--cascade")) {
                cmd.cascade = true;
            } else if (std.mem.eql(u8, arg, "--unneeded")) {
                cmd.unneeded = true;
            } else if (std.mem.eql(u8, arg, "--groups") or std.mem.eql(u8, arg, "--list")) {
                cmd.pacman_only = true;
            } else if (std.mem.eql(u8, arg, "--needed") or std.mem.eql(u8, arg, "--downloadonly") or
                std.mem.eql(u8, arg, "--nodeps") or std.mem.eql(u8, arg, "--noprogressbar") or
                std.mem.eql(u8, arg, "--noscriptlet") or std.mem.eql(u8, arg, "--dbonly") or
                std.mem.eql(u8, arg, "--asdeps") or std.mem.eql(u8, arg, "--asexplicit") or
                std.mem.eql(u8, arg, "--changelog") or std.mem.eql(u8, arg, "--check") or
                std.mem.eql(u8, arg, "--deps") or std.mem.eql(u8, arg, "--explicit") or
                std.mem.eql(u8, arg, "--files") or std.mem.eql(u8, arg, "--owns") or
                std.mem.eql(u8, arg, "--unrequired") or std.mem.eql(u8, arg, "--upgrades") or
                std.mem.eql(u8, arg, "--nosignature") or std.mem.eql(u8, arg, "--disable-download-timeout"))
            {
                // The complete argv is forwarded to pacman for transaction/query operations.
            } else if (needsLongValue(arg)) {
                if (std.mem.eql(u8, optionName(arg), "--root") or std.mem.eql(u8, optionName(arg), "--dbpath") or
                    std.mem.eql(u8, optionName(arg), "--config") or std.mem.eql(u8, optionName(arg), "--sysroot") or
                    std.mem.eql(u8, optionName(arg), "--arch")) cmd.custom_database = true;
                if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
                    if (eq + 1 == arg.len) return error.EmptyOperand;
                } else expecting_value = true;
            } else return error.UnsupportedOption;
        } else if (!end_options and (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "-b"))) {
            cmd.custom_database = true;
            expecting_value = true;
        } else if (!end_options and arg[0] == '-') {
            if (arg.len == 1) return error.UnsupportedOption;
            for (arg[1..]) |flag| switch (flag) {
                'S' => try operation(&op, .sync),
                'R' => try operation(&op, .remove),
                'Q' => try operation(&op, .query),
                'h' => try operation(&op, .help),
                'V' => try operation(&op, .version),
                'p' => cmd.print = true,
                's' => if (op == .remove) {
                    cmd.recursive = true;
                } else {
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
                'y' => cmd.refresh = true,
                'u' => cmd.unneeded = true,
                'n' => cmd.nosave = true,
                'c' => cmd.cascade = true,
                'r' => cmd.recursive = true,
                'g', 'l' => cmd.pacman_only = true,
                'd', 'q', 't', 'w', 'v', 'k', 'o', 'e', 'x', 'b' => {},
                else => return error.UnsupportedOption,
            };
        } else try cmd.operands.append(allocator, arg);
    }
    if (expecting_value) return error.MissingOperand;
    cmd.operation = op orelse return error.MissingOperation;
    if (cmd.operation == .sync and cmd.unneeded) {
        cmd.sysupgrade = true;
        cmd.unneeded = false;
    }
    if (cmd.print and (cmd.operation != .sync or cmd.search or cmd.info or cmd.foreign or cmd.sysupgrade or cmd.refresh)) return error.UnsupportedCombination;
    if (@as(u8, @intFromBool(cmd.search)) + @intFromBool(cmd.info) + @intFromBool(cmd.foreign) > 1) return error.UnsupportedCombination;
    switch (cmd.operation) {
        .help, .version => if (cmd.search or cmd.info or cmd.foreign or cmd.operands.items.len != 0) return error.UnsupportedCombination,
        .sync => {
            if (cmd.foreign) return error.UnsupportedCombination;
            if ((cmd.search or cmd.info or cmd.print) and (cmd.sysupgrade or cmd.refresh)) return error.UnsupportedCombination;
            if (cmd.operands.items.len == 0 and !cmd.sysupgrade and !cmd.refresh and !cmd.cascade and !cmd.pacman_only) return error.MissingOperand;
            // Pacman uses regex; AUR uses substrings. Do not pretend multi-term semantics agree.
            if (cmd.search and cmd.operands.items.len != 1) return error.TooManyOperands;
        },
        .remove => {
            if (cmd.search or cmd.info or cmd.foreign or cmd.print or cmd.operands.items.len == 0) return error.UnsupportedCombination;
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
    var sync = try parse(a, &.{ "-Syu", "--noconfirm" });
    defer sync.deinit(a);
    try std.testing.expect(sync.sysupgrade and sync.refresh and sync.noconfirm);
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
    var install = try parse(a, &.{ "-S", "--noconfirm", "foo" });
    defer install.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), install.raw_args.items.len);
    var remove = try parse(a, &.{ "-Rns", "foo", "--noconfirm" });
    defer remove.deinit(a);
    try std.testing.expect(remove.operation == .remove and remove.recursive and remove.nosave);
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

test "transactions preserve pacman options and keep option values out of target list" {
    const a = std.testing.allocator;
    var install = try parse(a, &.{ "-S", "--needed", "--config", "/tmp/pacman.conf", "foo" });
    defer install.deinit(a);
    try std.testing.expect(install.custom_database);
    try std.testing.expectEqual(@as(usize, 1), install.operands.items.len);
    try std.testing.expectEqualStrings("foo", install.operands.items[0]);
    try std.testing.expectEqual(@as(usize, 5), install.raw_args.items.len);
    var remove = try parse(a, &.{ "-Rns", "foo", "--noconfirm" });
    defer remove.deinit(a);
    try std.testing.expect(remove.recursive and remove.nosave);
    try std.testing.expectError(error.MissingOperand, parse(a, &.{ "-S", "--config" }));
}
