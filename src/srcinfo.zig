const std = @import("std");
const aur = @import("aur.zig");
const resolver = @import("resolver.zig");

/// Parsed as data only; no PKGBUILD or shell code is evaluated.
pub const Field = enum {
    arch,
    license,
    source,
    validpgpkeys,
    groups,
    backup,
    options,
    install,
    noextract,
    md5sums,
    sha256sums,
    sha512sums,
    b2sums,
    changelog,
    depends,
    makedepends,
    checkdepends,
    optdepends,
    provides,
    conflicts,
    replaces,
};
pub const IssueKind = enum {
    malformed_line,
    invalid_key,
    missing_pkgbase,
    duplicate_pkgbase,
    missing_pkgver,
    missing_pkgrel,
    missing_pkgname,
    duplicate_pkgname,
    invalid_value,
    duplicate_scalar,
};
pub const ParseIssue = struct { kind: IssueKind, line: usize, key: []const u8 };
const Entry = struct { field: Field, value: []const u8, arch: ?[]const u8 = null };
const Scalar = struct { key: []const u8, value: []const u8 };
const Package = struct { name: []const u8, entries: []const Entry, scalars: []const Scalar };
const Builder = struct {
    name: []const u8,
    entries: std.ArrayList(Entry) = .empty,
    scalars: std.ArrayList(Scalar) = .empty,
};

/// Arena lifetime matches the parsed metadata snapshot. Text values borrow from
/// the input; package and metadata arrays are owned by this Info.
pub const Info = struct {
    arena: std.heap.ArenaAllocator,
    pkgbase: []const u8,
    pkgver: []const u8,
    pkgrel: []const u8,
    epoch: ?u64,
    base_entries: []const Entry,
    base_scalars: []const Scalar,
    packages: []const Package,
    pub fn deinit(self: *Info) void {
        self.arena.deinit();
    }
    pub fn package(self: *const Info, name: []const u8) ?PackageView {
        for (self.packages) |pkg| if (std.mem.eql(u8, name, pkg.name)) return .{ .info = self, .pkg = pkg };
        return null;
    }
    pub fn outputNames(self: *const Info, a: std.mem.Allocator) ![][]const u8 {
        const names = try a.alloc([]const u8, self.packages.len);
        for (self.packages, 0..) |pkg, i| names[i] = pkg.name;
        return names;
    }
    pub fn version(self: *const Info, a: std.mem.Allocator) ![]u8 {
        if (self.epoch) |epoch| if (epoch != 0) return std.fmt.allocPrint(a, "{d}:{s}-{s}", .{ epoch, self.pkgver, self.pkgrel });
        return std.fmt.allocPrint(a, "{s}-{s}", .{ self.pkgver, self.pkgrel });
    }
};

pub const PackageView = struct {
    info: *const Info,
    pkg: Package,
    pub fn scalar(self: PackageView, key: []const u8) ?[]const u8 {
        for (self.pkg.scalars) |item| if (std.mem.eql(u8, item.key, key)) return item.value;
        for (self.info.base_scalars) |item| if (std.mem.eql(u8, item.key, key)) return item.value;
        return null;
    }
    /// Package-scope arrays add to base-scope arrays. Architecture-specific
    /// entries are retained and selected at the point of use.
    pub fn values(self: PackageView, a: std.mem.Allocator, field: Field, architecture: []const u8) ![][]const u8 {
        var result: std.ArrayList([]const u8) = .empty;
        errdefer result.deinit(a);
        try appendValues(a, &result, self.info.base_entries, field, architecture);
        try appendValues(a, &result, self.pkg.entries, field, architecture);
        return result.toOwnedSlice(a);
    }
    pub fn version(self: PackageView, a: std.mem.Allocator) ![]u8 {
        return self.info.version(a);
    }
    pub fn planned(self: PackageView, a: std.mem.Allocator, architecture: []const u8) !Planned {
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const aa = arena.allocator();
        const record = resolver.Record{
            .name = self.pkg.name,
            .base = self.info.pkgbase,
            .version = try self.version(aa),
            .source = .aur,
            .depends = try self.values(aa, .depends, architecture),
            .make_depends = try self.values(aa, .makedepends, architecture),
            .check_depends = try self.values(aa, .checkdepends, architecture),
            .opt_depends = try self.values(aa, .optdepends, architecture),
            .provides = try self.values(aa, .provides, architecture),
            .conflicts = try self.values(aa, .conflicts, architecture),
            .replaces = try self.values(aa, .replaces, architecture),
        };
        return .{ .arena = arena, .record = record };
    }
};

pub const Planned = struct {
    arena: std.heap.ArenaAllocator,
    record: resolver.Record,
    pub fn deinit(self: *Planned) void {
        self.arena.deinit();
    }
};

fn appendValues(a: std.mem.Allocator, result: *std.ArrayList([]const u8), entries: []const Entry, field: Field, architecture: []const u8) !void {
    for (entries) |entry| {
        if (entry.field != field) continue;
        if (entry.arch) |arch| if (!std.mem.eql(u8, arch, architecture)) continue;
        try result.append(a, entry.value);
    }
}
fn knownField(key: []const u8) ?struct { field: Field, arch: ?[]const u8 } {
    inline for (@typeInfo(Field).@"enum".fields) |item| {
        if (std.mem.eql(u8, key, item.name)) return .{ .field = @field(Field, item.name), .arch = null };
    }
    inline for (@typeInfo(Field).@"enum".fields) |item| {
        const prefix = item.name ++ "_";
        if (std.mem.startsWith(u8, key, prefix) and key.len > prefix.len)
            return .{ .field = @field(Field, item.name), .arch = key[prefix.len..] };
    }
    return null;
}
pub const Detailed = union(enum) { parsed: Info, issue: ParseIssue };

pub fn parseDetailed(a: std.mem.Allocator, text: []const u8) !Detailed {
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const aa = arena.allocator();
    var base_entries: std.ArrayList(Entry) = .empty;
    var base_scalars: std.ArrayList(Scalar) = .empty;
    var packages: std.ArrayList(Package) = .empty;
    var current: ?Builder = null;
    var pkgbase: ?[]const u8 = null;
    var pkgver: ?[]const u8 = null;
    var pkgrel: ?[]const u8 = null;
    var epoch: ?u64 = null;
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        line_no += 1;
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return makeIssue(a, &arena, .malformed_line, line_no, "");
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (key.len == 0 or value.len == 0) return makeIssue(a, &arena, .invalid_value, line_no, key);
        if (std.mem.eql(u8, key, "pkgbase")) {
            if (pkgbase != null) return makeIssue(a, &arena, .duplicate_pkgbase, line_no, key);
            if (!aur.validName(value)) return makeIssue(a, &arena, .invalid_value, line_no, key);
            pkgbase = value;
            continue;
        }
        if (std.mem.eql(u8, key, "pkgname")) {
            if (!aur.validName(value)) return makeIssue(a, &arena, .invalid_value, line_no, key);
            if (current) |*builder| try packages.append(aa, .{ .name = builder.name, .entries = try builder.entries.toOwnedSlice(aa), .scalars = try builder.scalars.toOwnedSlice(aa) });
            for (packages.items) |pkg| if (std.mem.eql(u8, pkg.name, value)) return makeIssue(a, &arena, .duplicate_pkgname, line_no, key);
            current = .{ .name = value };
            continue;
        }
        if (std.mem.eql(u8, key, "pkgver") or std.mem.eql(u8, key, "pkgrel") or std.mem.eql(u8, key, "epoch")) {
            if (current != null) return makeIssue(a, &arena, .invalid_value, line_no, key);
            if (std.mem.eql(u8, key, "pkgver")) {
                if (pkgver != null or !@import("package.zig").validVersion(value)) return makeIssue(a, &arena, .invalid_value, line_no, key);
                pkgver = value;
            } else if (std.mem.eql(u8, key, "pkgrel")) {
                if (pkgrel != null or !@import("package.zig").validVersion(value)) return makeIssue(a, &arena, .invalid_value, line_no, key);
                pkgrel = value;
            } else {
                if (epoch != null) return makeIssue(a, &arena, .invalid_value, line_no, key);
                epoch = std.fmt.parseInt(u64, value, 10) catch return makeIssue(a, &arena, .invalid_value, line_no, key);
            }
            continue;
        }
        if (std.mem.eql(u8, key, "pkgdesc") or std.mem.eql(u8, key, "url")) {
            const scalars = if (current) |*builder| &builder.scalars else &base_scalars;
            for (scalars.items) |item| if (std.mem.eql(u8, item.key, key)) return makeIssue(a, &arena, .duplicate_scalar, line_no, key);
            try scalars.append(aa, .{ .key = key, .value = value });
            continue;
        }
        const field = knownField(key) orelse return makeIssue(a, &arena, .invalid_key, line_no, key);
        const entry = Entry{ .field = field.field, .value = value, .arch = field.arch };
        if (current) |*builder| try builder.entries.append(aa, entry) else try base_entries.append(aa, entry);
    }
    if (current) |*builder| try packages.append(aa, .{ .name = builder.name, .entries = try builder.entries.toOwnedSlice(aa), .scalars = try builder.scalars.toOwnedSlice(aa) });
    if (pkgbase == null) return makeIssue(a, &arena, .missing_pkgbase, 0, "pkgbase");
    if (pkgver == null) return makeIssue(a, &arena, .missing_pkgver, 0, "pkgver");
    if (pkgrel == null) return makeIssue(a, &arena, .missing_pkgrel, 0, "pkgrel");
    if (packages.items.len == 0) return makeIssue(a, &arena, .missing_pkgname, 0, "pkgname");
    return .{ .parsed = .{ .arena = arena, .pkgbase = pkgbase.?, .pkgver = pkgver.?, .pkgrel = pkgrel.?, .epoch = epoch, .base_entries = try base_entries.toOwnedSlice(aa), .base_scalars = try base_scalars.toOwnedSlice(aa), .packages = try packages.toOwnedSlice(aa) } };
}

fn makeIssue(a: std.mem.Allocator, arena: *std.heap.ArenaAllocator, kind: IssueKind, line: usize, key: []const u8) !Detailed {
    const owned_key = try a.dupe(u8, key);
    arena.deinit();
    return .{ .issue = .{ .kind = kind, .line = line, .key = owned_key } };
}
pub fn parse(a: std.mem.Allocator, text: []const u8) !Info {
    const detailed = try parseDetailed(a, text);
    return switch (detailed) {
        .parsed => |info| info,
        .issue => |problem| {
            a.free(problem.key);
            return switch (problem.kind) {
                .malformed_line => error.MalformedSrcinfo,
                .invalid_key => error.InvalidSrcinfoKey,
                .missing_pkgbase => error.MissingPackageBase,
                .duplicate_pkgbase => error.DuplicatePackageBase,
                .missing_pkgver => error.MissingPackageVersion,
                .missing_pkgrel => error.MissingPackageRelease,
                .missing_pkgname => error.MissingPackageName,
                .duplicate_pkgname => error.DuplicatePackageName,
                .invalid_value => error.InvalidSrcinfoValue,
                .duplicate_scalar => error.DuplicateSrcinfoScalar,
            };
        },
    };
}

test "split package scopes and version composition" {
    const a = std.testing.allocator;
    var info = try parse(a,
        \\# generated metadata
        \\pkgbase = splitbase
        \\pkgver = 2.4
        \\pkgrel = 3
        \\epoch = 1
        \\pkgdesc = common
        \\depends = common>=1
        \\makedepends = compiler
        \\pkgname = split-one
        \\pkgdesc = first
        \\depends = own>=2
        \\provides = virtual=2.4
        \\conflicts = old
        \\pkgname = split-two
        \\checkdepends = tester
    );
    defer info.deinit();
    const ver = try info.version(a);
    defer a.free(ver);
    try std.testing.expectEqualStrings("1:2.4-3", ver);
    const first = info.package("split-one").?;
    try std.testing.expectEqualStrings("first", first.scalar("pkgdesc").?);
    const deps = try first.values(a, .depends, "x86_64");
    defer a.free(deps);
    try std.testing.expectEqual(@as(usize, 2), deps.len);
    try std.testing.expectEqualStrings("common>=1", deps[0]);
    try std.testing.expectEqualStrings("own>=2", deps[1]);
    const second = info.package("split-two").?;
    const checks = try second.values(a, .checkdepends, "x86_64");
    defer a.free(checks);
    try std.testing.expectEqualStrings("tester", checks[0]);
    var planned = try first.planned(a, "x86_64");
    defer planned.deinit();
    try std.testing.expectEqual(resolver.Source.aur, planned.record.source);
    try std.testing.expectEqualStrings("splitbase", planned.record.base);
    try std.testing.expectEqualStrings("1:2.4-3", planned.record.version);
    try std.testing.expectEqual(@as(usize, 1), planned.record.make_depends.len);
}

test "architecture-qualified values remain scoped and repeated values are preserved" {
    const a = std.testing.allocator;
    var info = try parse(a,
        \\pkgbase = archpkg
        \\pkgver = 1
        \\pkgrel = 1
        \\depends = base
        \\depends_x86_64 = native>=2
        \\source = common.tar.gz
        \\source_aarch64 = arm.tar.gz
        \\pkgname = archpkg
        \\provides = virtual
        \\provides = another
    );
    defer info.deinit();
    const pkg = info.package("archpkg").?;
    const deps = try pkg.values(a, .depends, "x86_64");
    defer a.free(deps);
    try std.testing.expectEqual(@as(usize, 2), deps.len);
    const sources = try pkg.values(a, .source, "aarch64");
    defer a.free(sources);
    try std.testing.expectEqualStrings("arm.tar.gz", sources[1]);
    const native = try pkg.values(a, .source, "x86_64");
    defer a.free(native);
    try std.testing.expectEqual(@as(usize, 1), native.len);
}

test "malformed metadata has structured location and no evaluation" {
    const a = std.testing.allocator;
    const text = "pkgbase = safe\npkgver = 1\npkgrel = 1\npkgname = safe\nnot metadata\n";
    var result = try parseDetailed(a, text);
    defer switch (result) {
        .parsed => |*info| info.deinit(),
        .issue => |problem| a.free(problem.key),
    };
    try std.testing.expect(result == .issue);
    try std.testing.expectEqual(@as(usize, 5), result.issue.line);
    try std.testing.expectError(error.MalformedSrcinfo, parse(a, text));
}
