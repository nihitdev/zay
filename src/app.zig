const std = @import("std");
const linux = std.os.linux;
const cli = @import("cli.zig");
const aur = @import("aur.zig");
const pacman = @import("pacman.zig");
const process = @import("process.zig");
const output = @import("output.zig");
const diagnostics = @import("diagnostic.zig");
const alpm = @import("alpm.zig").c;
const transaction = @import("transaction.zig");

const help =
    \\zay 0.1.0 — pacman operations with AUR-aware search and safety checks
    \\Usage:
    \\  zay -S <repo-package>...  Install repository packages via pacman
    \\  zay -Syu                  Upgrade repositories via pacman
    \\  zay -Rns <package>...     Remove packages via pacman
    \\  zay -Sp <package>...  Print a dependency plan without installing
    \\  zay -Ss <query>        Search repositories and AUR (one query)
    \\  zay -Si <package>...   Show info, preferring repository packages
    \\  zay -Q...              Query installed packages via pacman
    \\  zay --help | --version
    \\
    \\Long options: --sync, --remove, --query, --search, --info, --foreign.
    \\  --refresh --sysupgrade --recursive --nosave --cascade --unneeded
    \\  --groups --list --needed --downloadonly
    \\  --noconfirm           Do not ask for confirmation
    \\  --print               Print a dependency plan (-S only)
    \\Use -- to end options. Official package transactions use pacman.
    \\AUR packages are dependency-planned, revision-reviewed, then built as the user.
    \\AUR updates block -Syu until combined AUR upgrades are supported.
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
    err_color: bool,
    noconfirm: bool = false,
    client: aur.Client,
    environ: *const std.process.Environ.Map,

    fn diagnostic(self: *Context, comptime fmt: []const u8, args: anytype) !void {
        try output.errorPrefix(self.err, self.err_color);
        try self.err.print(fmt ++ "\n", args);
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

    fn rawPacman(self: *Context, args: []const []const u8) !u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.a);
        try argv.append(self.a, "pacman");
        try argv.appendSlice(self.a, args);
        return process.inherit(self.io, argv.items) catch |err| {
            try self.pacmanFailure(err);
            return 2;
        };
    }

    fn privilegedPacman(self: *Context, args: []const []const u8) !u8 {
        if (linux.geteuid() == 0) return self.rawPacman(args);
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.a);
        try argv.append(self.a, "sudo");
        try argv.append(self.a, "pacman");
        try argv.appendSlice(self.a, args);
        return process.inherit(self.io, argv.items) catch |failure| {
            try self.diagnostic("sudo: {s}", .{switch (failure) {
                error.FileNotFound => "not found; install/configure a privilege helper such as sudo",
                error.AccessDenied => "permission denied",
                else => diagnostics.message(failure),
            }});
            return 2;
        };
    }

    fn repoNames(self: *Context) !?std.StringHashMap(void) {
        const inventory = pacman.run(self.a, self.io, "-Slq", &.{}, false) catch |err| {
            try self.pacmanFailure(err);
            return null;
        };
        defer inventory.deinit();
        if (inventory.code() != 0) {
            try self.err.writeAll(inventory.stderr);
            if (inventory.stderr.len == 0) try self.diagnostic("could not read repository databases; check pacman configuration", .{});
            return null;
        }
        var names = std.StringHashMap(void).init(self.a);
        errdefer names.deinit();
        var lines = std.mem.tokenizeScalar(u8, inventory.stdout, '\n');
        while (lines.next()) |name| {
            if (!aur.validName(name)) return error.MalformedPacmanOutput;
            try names.put(name, {});
        }
        return names;
    }

    /// Delegate repository targets to pacman; route AUR targets through zay's
    /// dependency, review, build, and package-validation transaction.
    fn syncInstall(self: *Context, cmd: cli.Command) !u8 {
        // A custom pacman config/root/database changes which repositories and
        // installed packages are in scope. Do not classify those using defaults.
        if (cmd.custom_database) return self.privilegedPacman(cmd.raw_args.items);
        if (cmd.operands.items.len == 0) return self.rawPacman(cmd.raw_args.items);
        var names = try self.repoNames() orelse return 2;
        defer names.deinit();
        var aur_targets: std.ArrayList([]const u8) = .empty;
        defer aur_targets.deinit(self.a);
        var aur_found = false;
        for (cmd.operands.items) |target| {
            if (aur.validName(target) and !names.contains(target)) try aur_targets.append(self.a, target);
        }
        var start: usize = 0;
        while (start < aur_targets.items.len) : (start += @min(50, aur_targets.items.len - start)) {
            const batch = aur_targets.items[start..@min(start + 50, aur_targets.items.len)];
            if (try self.queryAur(.info, batch)) |response| {
                defer response.deinit();
                for (batch) |target| for (0..response.count()) |i| {
                    const package = response.get(i);
                    if (!std.mem.eql(u8, package.name, target)) continue;
                    aur_found = true;
                };
            } else return 2;
        }
        if (aur_found) {
            if (!transaction.supportsOptions(cmd.raw_args.items)) {
                try self.diagnostic("one or more pacman options are not supported for mixed AUR transactions", .{});
                return 2;
            }
            return transaction.install(self.a, self.io, self.environ, &self.client, cmd.operands.items, cmd.noconfirm, self.color, self.err_color, self.out, self.err);
        }
        return self.privilegedPacman(cmd.raw_args.items);
    }

    /// Do not start a repository upgrade that would leave an outdated AUR
    /// package behind. AUR versions use libalpm's Arch comparison semantics.
    fn checkAurUpgrades(self: *Context) !bool {
        const foreign = process.capture(self.a, self.io, &.{ "pacman", "-Qm" }) catch |err| {
            try self.pacmanFailure(err);
            return false;
        };
        defer foreign.deinit();
        if (foreign.code() != 0) {
            try self.err.writeAll(foreign.stderr);
            if (foreign.stderr.len == 0) try self.diagnostic("could not inspect installed foreign packages", .{});
            return false;
        }
        var installed = std.StringHashMap([]const u8).init(self.a);
        defer installed.deinit();
        var lines = std.mem.tokenizeScalar(u8, foreign.stdout, '\n');
        while (lines.next()) |line| {
            var fields = std.mem.tokenizeAny(u8, line, " \t\r");
            const name = fields.next() orelse continue;
            const version = fields.next() orelse return error.MalformedPacmanOutput;
            if (!aur.validName(name) or !@import("package.zig").validVersion(version) or fields.next() != null)
                return error.MalformedPacmanOutput;
            try installed.put(name, version);
        }
        if (installed.count() == 0) return true;
        var names = std.ArrayList([]const u8).empty;
        defer names.deinit(self.a);
        var iterator = installed.iterator();
        while (iterator.next()) |entry| try names.append(self.a, entry.key_ptr.*);
        var start: usize = 0;
        while (start < names.items.len) : (start += @min(50, names.items.len - start)) {
            const batch = names.items[start..@min(start + 50, names.items.len)];
            const response = try self.queryAur(.info, batch) orelse return false;
            defer response.deinit();
            for (0..response.count()) |i| {
                const remote = response.get(i);
                const current = installed.get(remote.name) orelse continue;
                const current_z = try self.a.dupeZ(u8, current);
                defer self.a.free(current_z);
                const remote_z = try self.a.dupeZ(u8, remote.version);
                defer self.a.free(remote_z);
                if (alpm.alpm_pkg_vercmp(current_z, remote_z) < 0) {
                    try self.diagnostic("AUR update available for '{s}'; refusing a partial -Syu until safe AUR builds are supported", .{remote.name});
                    return false;
                }
            }
        }
        return true;
    }

    fn syncTransaction(self: *Context, cmd: cli.Command) !u8 {
        if (cmd.sysupgrade) {
            if (cmd.custom_database) {
                try self.diagnostic("cannot verify AUR upgrades with custom pacman database options; refusing a partial -Syu", .{});
                return 2;
            }
            if (!try self.checkAurUpgrades()) return 2;
            return self.privilegedPacman(cmd.raw_args.items);
        }
        if (cmd.pacman_only) return self.rawPacman(cmd.raw_args.items);
        if (cmd.operands.items.len == 0 or cmd.refresh) return self.privilegedPacman(cmd.raw_args.items);
        return self.syncInstall(cmd);
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
        .err_color = init.environ_map.get("NO_COLOR") == null and (try std.Io.File.stderr().isTty(init.io)),
        .client = aur.Client.init(a, init.io),
        .environ = init.environ_map,
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
        .sync => if (cmd.search) try ctx.search(cmd.operands.items[0]) else if (cmd.info) try ctx.info(cmd.operands.items) else if (cmd.print) try @import("planner.zig").run(a, init.io, &ctx.client, cmd.operands.items, ctx.out, ctx.err) else try ctx.syncTransaction(cmd),
        .remove => try ctx.privilegedPacman(cmd.raw_args.items),
        .query => try ctx.rawPacman(cmd.raw_args.items),
    };
    try ctx.out.flush();
    try ctx.err.flush();
    return status;
}
