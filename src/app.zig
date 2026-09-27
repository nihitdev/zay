const std = @import("std");
const cli = @import("cli.zig");
const aur = @import("aur.zig");
const pacman = @import("pacman.zig");
const process = @import("process.zig");
const output = @import("output.zig");
const diagnostics = @import("diagnostic.zig");

const help =
    \\zay 0.1.0 — repository and AUR search, info and dependency planning
    \\Usage:
    \\  zay -Sp <package>...  Print a dependency plan without installing
    \\  zay -Ss <query>        Search repositories and AUR (one query)
    \\  zay -Si <package>...   Show info, preferring repository packages
    \\  zay -Q[s|i|m] [args]   Read-only installed-package queries via pacman
    \\  zay --help | --version
    \\
    \\Long options: --sync, --query, --search, --info, --foreign.
    \\  --noconfirm           Do not ask for confirmation
    \\  --print               Print a dependency plan (-S only)
    \\Use -- to end options. Pacman search uses regex; AUR uses substrings.
    \\Install, remove, refresh and upgrade operations are not implemented.
    \\Exit: 0 success; 1 no match/not found; 2 usage or incomplete/failed lookup.
    \\Local queries preserve pacman's exit status (signals: 128 + signal).
    \\
;

const Context = struct {
    a: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    color: bool,
    noconfirm: bool = false,
    client: aur.Client,

    fn diagnostic(self: *Context, comptime fmt: []const u8, args: anytype) !void {
        try self.err.print("error: " ++ fmt ++ "\n", args);
        try self.err.flush();
    }
    fn pacmanFailure(self: *Context, err: anyerror) !void {
        try self.diagnostic("pacman: {s}", .{switch (err) {
            error.FileNotFound => "executable not found; pacman is required on Arch Linux",
            error.AccessDenied => "permission denied executing pacman",
            else => diagnostics.message(err),
        }});
    }
    fn queryAur(self: *Context, kind: aur.Kind, terms: []const []const u8) !?aur.Response {
        const response = self.client.query(kind, terms) catch |err| {
            if (err == error.HttpStatus) {
                try self.diagnostic("AUR request failed: HTTP {d}", .{@intFromEnum(self.client.last_status.?)});
            } else try self.diagnostic("AUR: {s}", .{diagnostics.aurMessage(err)});
            return null;
        };
        if (response.apiError()) |msg| {
            defer response.deinit();
            try self.err.writeAll("error: AUR: ");
            try output.safe(self.err, msg);
            try self.err.writeByte('\n');
            try self.err.flush();
            return null;
        }
        return response;
    }
    fn search(self: *Context, query: []const u8) !u8 {
        var failed = false;
        var found = false;
        var names = std.StringHashMap(void).init(self.a);
        defer names.deinit();
        const repo: ?process.Result = pacman.run(self.a, self.io, "-Ss", &.{query}, self.noconfirm) catch |err| blk: {
            try self.pacmanFailure(err);
            failed = true;
            break :blk null;
        };
        defer if (repo) |r| r.deinit();
        if (repo) |r| {
            try self.err.writeAll(r.stderr);
            try self.err.flush();
            // pacman uses 1 for no matches, but diagnostics mean a real failure.
            if (r.code() != 0 and (r.code() != 1 or r.stderr.len != 0)) {
                if (r.stderr.len == 0) try self.diagnostic("repository search failed (status {d})", .{r.code()});
                failed = true;
            } else {
                const parsed_names = try pacman.searchNames(self.a, r.stdout);
                names.deinit();
                names = parsed_names;
                found = names.count() != 0;
                try self.out.writeAll(r.stdout);
                try self.out.flush();
            }
        }
        if (try self.queryAur(.search, &.{query})) |response| {
            defer response.deinit();
            const packages = try self.a.alloc(@import("package.zig").Package, response.count());
            defer self.a.free(packages);
            for (packages, 0..) |*p, i| p.* = response.get(i);
            std.mem.sort(@import("package.zig").Package, packages, {}, struct {
                fn less(_: void, l: @import("package.zig").Package, r: @import("package.zig").Package) bool {
                    return std.mem.lessThan(u8, l.name, r.name);
                }
            }.less);
            var previous: ?[]const u8 = null;
            for (packages) |p| {
                if (names.contains(p.name)) continue;
                if (previous) |name| if (std.mem.eql(u8, name, p.name)) continue;
                previous = p.name;
                found = true;
                try output.search(self.out, p, self.color);
            }
        } else failed = true;
        return if (failed) 2 else if (found) 0 else 1;
    }

    fn info(self: *Context, targets: []const []const u8) !u8 {
        // Inventory names first: a failed -Si must never be mistaken for absence.
        const inventory = pacman.run(self.a, self.io, "-Slq", &.{}, self.noconfirm) catch |err| {
            try self.pacmanFailure(err);
            return 2;
        };
        defer inventory.deinit();
        try self.err.writeAll(inventory.stderr);
        try self.err.flush();
        if (inventory.code() != 0) {
            if (inventory.stderr.len == 0) try self.diagnostic("could not read repository databases; check pacman configuration", .{});
            return 2;
        }
        var repo_names = std.StringHashMap(void).init(self.a);
        defer repo_names.deinit();
        var lines = std.mem.tokenizeScalar(u8, inventory.stdout, '\n');
        while (lines.next()) |name| {
            if (!aur.validName(name)) return error.MalformedPacmanOutput;
            try repo_names.put(name, {});
        }
        var missing: std.ArrayList([]const u8) = .empty;
        defer missing.deinit(self.a);
        var seen = std.StringHashMap(void).init(self.a);
        defer seen.deinit();
        var failed = false;
        for (targets) |target| {
            if (!aur.validName(target)) {
                try self.diagnostic("info requires an unqualified package name (repository/name is not supported)", .{});
                return 2;
            }
            const entry = try seen.getOrPut(target);
            if (entry.found_existing) continue;
            if (repo_names.contains(target)) {
                const result = pacman.run(self.a, self.io, "-Si", &.{target}, self.noconfirm) catch |err| {
                    try self.pacmanFailure(err);
                    failed = true;
                    continue;
                };
                defer result.deinit();
                try self.out.writeAll(result.stdout);
                try self.err.writeAll(result.stderr);
                if (result.code() != 0) {
                    if (result.stderr.len == 0) try self.diagnostic("repository info failed (status {d})", .{result.code()});
                    failed = true;
                }
            } else try missing.append(self.a, target);
        }
        try self.out.flush();
        var not_found = false;
        // Bound each info URL; small batches also avoid huge RPC responses.
        var start: usize = 0;
        while (start < missing.items.len) : (start += @min(50, missing.items.len - start)) {
            const batch = missing.items[start..@min(start + 50, missing.items.len)];
            if (try self.queryAur(.info, batch)) |response| {
                defer response.deinit();
                for (batch) |target| {
                    var matched = false;
                    for (0..response.count()) |i| {
                        const p = response.get(i);
                        if (std.mem.eql(u8, target, p.name)) {
                            try output.info(self.out, p);
                            matched = true;
                            break;
                        }
                    }
                    if (!matched) {
                        try self.diagnostic("package '{s}' was not found in repositories or AUR", .{target});
                        not_found = true;
                    }
                }
            } else failed = true;
        }
        return if (failed) 2 else if (not_found) 1 else 0;
    }
};

pub fn run(init: std.process.Init) !u8 {
    const a = init.gpa;
    // argv belongs to the process lifetime; other allocations have explicit owners.
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var out_buffer: [8192]u8 = undefined;
    var err_buffer: [2048]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &out_buffer);
    var stderr = std.Io.File.stderr().writer(init.io, &err_buffer);
    var ctx: Context = .{
        .a = a,
        .io = init.io,
        .out = &stdout.interface,
        .err = &stderr.interface,
        .color = init.environ_map.get("NO_COLOR") == null and (try std.Io.File.stdout().isTty(init.io)),
        .client = aur.Client.init(a, init.io),
    };
    defer ctx.client.deinit();
    var cmd = cli.parse(a, args[1..]) catch |err| {
        try ctx.diagnostic("{s}", .{cli.message(err)});
        return 2;
    };
    defer cmd.deinit(a);
    ctx.noconfirm = cmd.noconfirm;
    // Proxy configuration is command-scoped and must outlive the HTTP client.
    if (cmd.operation == .sync) try ctx.client.http.initDefaultProxies(init.arena.allocator(), init.environ_map);
    const status: u8 = switch (cmd.operation) {
        .help => blk: {
            try ctx.out.writeAll(help);
            break :blk 0;
        },
        .version => blk: {
            try ctx.out.writeAll("zay 0.1.0\n");
            break :blk 0;
        },
        .sync => if (cmd.search) try ctx.search(cmd.operands.items[0]) else if (cmd.info) try ctx.info(cmd.operands.items) else try @import("planner.zig").run(a, init.io, &ctx.client, cmd.operands.items, ctx.out, ctx.err),
        .query => blk: {
            var argv: std.ArrayList([]const u8) = .empty;
            defer argv.deinit(a);
            try argv.appendSlice(a, &.{ "pacman", if (cmd.search) "-Qs" else if (cmd.info) "-Qi" else if (cmd.foreign) "-Qm" else "-Q", "--color", if (ctx.color) "auto" else "never" });
            if (cmd.noconfirm) try argv.append(a, "--noconfirm");
            try argv.append(a, "--");
            try argv.appendSlice(a, cmd.operands.items);
            break :blk process.inherit(init.io, argv.items) catch |err| {
                try ctx.pacmanFailure(err);
                return 2;
            };
        },
    };
    try ctx.out.flush();
    try ctx.err.flush();
    return status;
}
