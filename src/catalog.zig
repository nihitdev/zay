const std = @import("std");
const c = @import("alpm.zig").c;
const aur = @import("aur.zig");
const resolver = @import("resolver.zig");
const process = @import("process.zig");
const Record = resolver.Record;

pub const RepoConfig = struct { name: []const u8, install: bool = true, usage_seen: bool = false };
pub const Config = struct {
    root: []const u8 = "",
    dbpath: []const u8 = "",
    repos: std.ArrayList(RepoConfig) = .empty,
    ignore_packages: std.ArrayList([]const u8) = .empty,
    ignore_groups: std.ArrayList([]const u8) = .empty,
    pub fn deinit(self: *Config, a: std.mem.Allocator) void {
        self.repos.deinit(a);
        self.ignore_packages.deinit(a);
        self.ignore_groups.deinit(a);
    }
    /// pacman-conf resolves Include directives and variables before this parser.
    pub fn parse(a: std.mem.Allocator, text: []const u8) !Config {
        var result: Config = .{};
        errdefer result.deinit(a);
        var options = false;
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \r\t");
            if (line.len == 0) continue;
            if (line[0] == '[') {
                if (line[line.len - 1] != ']') return error.PacmanConfiguration;
                const name = line[1 .. line.len - 1];
                options = std.mem.eql(u8, name, "options");
                if (!options) {
                    if (!aur.validName(name)) return error.PacmanConfiguration;
                    try result.repos.append(a, .{ .name = name });
                }
                continue;
            }
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..eq], " \t");
            const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
            if (options) {
                if (std.mem.eql(u8, key, "RootDir")) result.root = value else if (std.mem.eql(u8, key, "DBPath")) result.dbpath = value else if (std.mem.eql(u8, key, "IgnorePkg")) try result.ignore_packages.append(a, value) else if (std.mem.eql(u8, key, "IgnoreGroup")) try result.ignore_groups.append(a, value) else if (std.mem.eql(u8, key, "AssumeInstalled") and value.len != 0) return error.AssumeInstalledUnsupported;
            } else if (std.mem.eql(u8, key, "Usage")) {
                if (result.repos.items.len == 0) return error.PacmanConfiguration;
                const repo = &result.repos.items[result.repos.items.len - 1];
                if (!repo.usage_seen) {
                    repo.install = false;
                    repo.usage_seen = true;
                }
                if (std.mem.eql(u8, value, "All") or std.mem.eql(u8, value, "Install")) repo.install = true;
            }
        }
        if (!std.mem.startsWith(u8, result.root, "/") or !std.mem.startsWith(u8, result.dbpath, "/")) return error.PacmanConfiguration;
        return result;
    }
};

pub const Host = struct {
    a: std.mem.Allocator,
    // The metadata snapshot is one planning lifetime. This arena owns copied
    // dependency strings and record arrays, not sockets or libalpm resources.
    arena: std.heap.ArenaAllocator,
    handle: ?*c.alpm_handle_t = null,
    installed: []const Record = &.{},
    repositories: []const Record = &.{},
    ignored: []const [:0]const u8 = &.{},
    responses: std.ArrayList(aur.Response) = .empty,
    cache: std.StringHashMap([]const Record),
    client: *aur.Client,
    detail: []const u8 = "",

    pub fn init(a: std.mem.Allocator, client: *aur.Client) Host {
        return .{ .a = a, .arena = std.heap.ArenaAllocator.init(a), .cache = std.StringHashMap([]const Record).init(a), .client = client };
    }
    pub fn deinit(self: *Host) void {
        for (self.responses.items) |r| r.deinit();
        self.responses.deinit(self.a);
        self.cache.deinit();
        if (self.handle) |h| _ = c.alpm_release(h);
        self.arena.deinit();
    }
    pub fn view(self: *Host) resolver.Catalog {
        return .{ .installed = self.installed, .repositories = self.repositories, .build_environment = &.{"base-devel"}, .context = self, .fetch = fetch };
    }
    pub fn load(self: *Host, io: std.Io) !void {
        const result = process.capture(self.a, io, &.{"pacman-conf"}) catch |err| switch (err) {
            error.FileNotFound => return error.PacmanConfMissing,
            else => return err,
        };
        defer result.deinit();
        if (result.code() != 0) return error.PacmanConfiguration;
        var config = try Config.parse(self.a, result.stdout);
        defer config.deinit(self.a);
        const a = self.arena.allocator();
        const ignored = try a.alloc([:0]const u8, config.ignore_packages.items.len);
        for (config.ignore_packages.items, 0..) |pattern, i| ignored[i] = try a.dupeZ(u8, pattern);
        self.ignored = ignored;
        const root = try a.dupeZ(u8, config.root);
        const dbpath = try a.dupeZ(u8, config.dbpath);
        var err: c.alpm_errno_t = 0;
        const handle = c.alpm_initialize(root, dbpath, &err) orelse {
            self.detail = span(c.alpm_strerror(err));
            return error.PackageDatabase;
        };
        self.handle = handle;
        for (config.ignore_packages.items) |pattern| if (c.alpm_option_add_ignorepkg(handle, try a.dupeZ(u8, pattern)) != 0) return error.PackageDatabase;
        for (config.ignore_groups.items) |pattern| if (c.alpm_option_add_ignoregroup(handle, try a.dupeZ(u8, pattern)) != 0) return error.PackageDatabase;
        const local = c.alpm_get_localdb(handle) orelse return error.PackageDatabase;
        if (c.alpm_db_get_valid(local) != 0) return self.databaseFailure();
        var installed: std.ArrayList(Record) = .empty;
        var repositories: std.ArrayList(Record) = .empty;
        var names = std.StringHashMap(void).init(self.a);
        defer names.deinit();
        try self.loadDb(local, .installed, &installed, null);
        self.installed = try installed.toOwnedSlice(a);
        for (config.repos.items) |repo| {
            if (!repo.install) continue;
            const db = c.alpm_register_syncdb(handle, try a.dupeZ(u8, repo.name), 0) orelse return error.PackageDatabase;
            if (c.alpm_db_get_valid(db) != 0) return self.databaseFailure();
            try self.loadDb(db, .repo, &repositories, &names);
        }
        self.repositories = try repositories.toOwnedSlice(a);
    }
    fn loadDb(self: *Host, db: *c.alpm_db_t, source: resolver.Source, out: *std.ArrayList(Record), names: ?*std.StringHashMap(void)) !void {
        const a = self.arena.allocator();
        var list = c.alpm_db_get_pkgcache(db);
        if (list == null and c.alpm_errno(self.handle) != c.ALPM_ERR_OK) return self.databaseFailure();
        while (list != null) : (list = list.*.next) {
            const pkg: *c.alpm_pkg_t = @ptrCast(@alignCast(list.*.data orelse return error.PackageDatabase));
            const name = span(c.alpm_pkg_get_name(pkg));
            if (names) |set| {
                const entry = try set.getOrPut(name);
                if (entry.found_existing) continue;
            }
            const base = span(c.alpm_pkg_get_base(pkg));
            try out.append(a, .{
                .name = name,
                .base = if (base.len == 0) name else base,
                .version = span(c.alpm_pkg_get_version(pkg)),
                .repository = span(c.alpm_db_get_name(db)),
                .source = source,
                .depends = try self.deps(c.alpm_pkg_get_depends(pkg)),
                .provides = try self.deps(c.alpm_pkg_get_provides(pkg)),
                .conflicts = try self.deps(c.alpm_pkg_get_conflicts(pkg)),
                .replaces = try self.deps(c.alpm_pkg_get_replaces(pkg)),
                .ignored = c.alpm_pkg_should_ignore(self.handle, pkg) != 0,
            });
        }
    }
    fn deps(self: *Host, head: [*c]c.alpm_list_t) ![]const []const u8 {
        const a = self.arena.allocator();
        var result: std.ArrayList([]const u8) = .empty;
        var list = head;
        while (list != null) : (list = list.*.next) {
            const dep: *c.alpm_depend_t = @ptrCast(@alignCast(list.*.data orelse return error.PackageDatabase));
            const text = c.alpm_dep_compute_string(dep);
            if (text == null) return error.OutOfMemory;
            defer c.free(text);
            try result.append(a, try a.dupe(u8, std.mem.span(text)));
        }
        return result.toOwnedSlice(a);
    }
    fn databaseFailure(self: *Host) error{PackageDatabase} {
        self.detail = span(c.alpm_strerror(c.alpm_errno(self.handle)));
        return error.PackageDatabase;
    }
    fn query(self: *Host, kind: aur.Kind, terms: []const []const u8) !aur.Response {
        const response = try self.client.query(kind, terms);
        errdefer response.deinit();
        if (response.apiError()) |msg| {
            self.detail = try self.arena.allocator().dupe(u8, msg);
            return error.AurApi;
        }
        try self.responses.append(self.a, response);
        return response;
    }
    fn fetch(ctx: *anyopaque, name: []const u8, providers: bool) ![]const Record {
        const self: *Host = @ptrCast(@alignCast(ctx));
        const a = self.arena.allocator();
        const key = try std.fmt.allocPrint(a, "{s}:{s}", .{ if (providers) "provides" else "info", name });
        if (self.cache.get(key)) |records| return records;
        var records: std.ArrayList(Record) = .empty;
        if (providers) {
            const matches = try self.query(.providers, &.{name});
            if (matches.count() > 50) return error.AmbiguousProvider;
            if (matches.count() != 0) {
                var names: std.ArrayList([]const u8) = .empty;
                for (0..matches.count()) |i| try names.append(a, matches.get(i).name);
                const info = try self.query(.info, names.items);
                for (0..info.count()) |i| try records.append(a, fromAur(info.get(i)));
            }
        } else {
            const info = try self.query(.info, &.{name});
            for (0..info.count()) |i| try records.append(a, fromAur(info.get(i)));
        }
        for (records.items) |*record| {
            const pkg_name = try a.dupeZ(u8, record.name);
            for (self.ignored) |pattern| {
                if (c.fnmatch(pattern, pkg_name, 0) == 0) record.ignored = true;
            }
        }
        const owned = try records.toOwnedSlice(a);
        try self.cache.put(key, owned);
        return owned;
    }
};
fn span(ptr: [*c]const u8) []const u8 {
    return if (ptr == null) "" else std.mem.span(ptr);
}
fn fromAur(p: @import("package.zig").Package) Record {
    return .{ .name = p.name, .version = p.version, .base = p.base, .source = .aur, .repository = "aur", .depends = p.depends, .make_depends = p.make_depends, .check_depends = p.check_depends, .provides = p.provides, .conflicts = p.conflicts, .replaces = p.replaces };
}

test "resolved pacman configuration preserves priority and install usage" {
    const a = std.testing.allocator;
    var cfg = try Config.parse(a, "[options]\nRootDir = /\nDBPath = /var/lib/pacman/\nIgnorePkg = foo*\n[custom]\nUsage = Sync\nUsage = Install\n[core]\nUsage = All\n[search-only]\nUsage = Search\n");
    defer cfg.deinit(a);
    try std.testing.expectEqualStrings("custom", cfg.repos.items[0].name);
    try std.testing.expect(cfg.repos.items[0].install and cfg.repos.items[1].install and !cfg.repos.items[2].install);
    try std.testing.expectEqualStrings("foo*", cfg.ignore_packages.items[0]);
    try std.testing.expectError(error.AssumeInstalledUnsupported, Config.parse(a, "[options]\nAssumeInstalled = foo\n"));
    try std.testing.expectError(error.PacmanConfiguration, Config.parse(a, "[options]\nRootDir = relative\n"));
}
