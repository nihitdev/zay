const std = @import("std");
const Package = @import("package.zig").Package;
pub const Kind = enum { search, info, providers };
const max_response = 8 * 1024 * 1024;

const RpcPackage = struct {
    Name: []const u8,
    PackageBase: []const u8,
    Version: []const u8,
    Description: ?[]const u8 = null,
    URL: ?[]const u8 = null,
    Maintainer: ?[]const u8 = null,
    NumVotes: u64 = 0,
    Popularity: f64 = 0,
    OutOfDate: ?i64 = null,
    Depends: []const []const u8 = &.{},
    MakeDepends: []const []const u8 = &.{},
    CheckDepends: []const []const u8 = &.{},
    Provides: []const []const u8 = &.{},
    Conflicts: []const []const u8 = &.{},
    Replaces: []const []const u8 = &.{},
    fn package(p: RpcPackage) Package {
        return .{ .name = p.Name, .base = p.PackageBase, .version = p.Version, .description = p.Description, .url = p.URL, .maintainer = p.Maintainer, .votes = p.NumVotes, .popularity = p.Popularity, .out_of_date = p.OutOfDate, .depends = p.Depends, .make_depends = p.MakeDepends, .check_depends = p.CheckDepends, .provides = p.Provides, .conflicts = p.Conflicts, .replaces = p.Replaces };
    }
};
const Envelope = struct {
    version: u32,
    type: []const u8,
    resultcount: ?usize = null,
    results: ?[]const RpcPackage = null,
    @"error": ?[]const u8 = null,
};
pub const Response = struct {
    parsed: std.json.Parsed(Envelope),
    pub fn deinit(self: Response) void {
        self.parsed.deinit();
    }
    pub fn count(self: Response) usize {
        return if (self.parsed.value.results) |results| results.len else 0;
    }
    pub fn get(self: Response, index: usize) Package {
        return self.parsed.value.results.?[index].package();
    }
    pub fn apiError(self: Response) ?[]const u8 {
        return self.parsed.value.@"error";
    }
};

/// Parsed strings are copied into the response's owned JSON arena.
pub fn parse(a: std.mem.Allocator, json: []const u8, kind: Kind) !Response {
    if (json.len > max_response) return error.ResponseTooLarge;
    const parsed = try std.json.parseFromSlice(Envelope, a, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always, .max_value_len = max_response });
    errdefer parsed.deinit();
    const v = parsed.value;
    if (v.version != 5) return error.UnsupportedRpcVersion;
    if (std.mem.eql(u8, v.type, "error")) {
        if (v.@"error" == null) return error.MalformedRpcResponse;
    } else {
        const expected = if (kind == .info) "multiinfo" else "search";
        const results = v.results orelse return error.MalformedRpcResponse;
        const count = v.resultcount orelse return error.MalformedRpcResponse;
        if (!std.mem.eql(u8, v.type, expected) or v.@"error" != null or count != results.len) return error.MalformedRpcResponse;
        for (results) |p| {
            if (!validName(p.Name) or !validName(p.PackageBase) or !@import("package.zig").validVersion(p.Version)) return error.MalformedRpcResponse;
        }
    }
    return .{ .parsed = parsed };
}
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name[0] == '-' or name[0] == '.') return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "@._+-", c) == null) return false;
    return true;
}

fn encode(a: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (text) |c| {
        if (std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-._~", c) != null) {
            try out.append(a, c);
        } else try out.appendSlice(a, &.{ '%', hex[c >> 4], hex[c & 15] });
    }
}
pub fn url(a: std.mem.Allocator, kind: Kind, terms: []const []const u8) ![]u8 {
    if (terms.len == 0 or (kind != .info and terms.len != 1)) return error.InvalidArguments;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "https://aur.archlinux.org/rpc/v5/");
    switch (kind) {
        .search, .providers => {
            try out.appendSlice(a, "search/");
            try encode(a, &out, terms[0]);
            try out.appendSlice(a, if (kind == .search) "?by=name-desc" else "?by=provides");
        },
        .info => {
            try out.appendSlice(a, "info?");
            for (terms, 0..) |term, i| {
                if (i != 0) try out.append(a, '&');
                try out.appendSlice(a, "arg%5B%5D=");
                try encode(a, &out, term);
            }
        },
    }
    if (out.items.len > 8000) return error.RequestTooLarge;
    return out.toOwnedSlice(a);
}

pub const Client = struct {
    http: std.http.Client,
    last_status: ?std.http.Status = null,
    pub fn init(a: std.mem.Allocator, io: std.Io) Client {
        return .{ .http = .{ .allocator = a, .io = io } };
    }
    pub fn deinit(self: *Client) void {
        self.http.deinit();
    }
    pub fn query(self: *Client, kind: Kind, terms: []const []const u8) !Response {
        self.last_status = null;
        const a = self.http.allocator;
        const address = try url(a, kind, terms);
        defer a.free(address);
        var req = try self.http.request(.GET, try std.Uri.parse(address), .{
            .redirect_behavior = .unhandled,
            .headers = .{ .user_agent = .{ .override = "zay/0.1.0" }, .accept_encoding = .{ .override = "identity" } },
        });
        defer req.deinit();
        try req.sendBodiless();
        var head_buffer: [8192]u8 = undefined;
        var response = try req.receiveHead(&head_buffer);
        self.last_status = response.head.status;
        if (response.head.status != .ok) return error.HttpStatus;
        if (response.head.content_length) |length| if (length > max_response) return error.ResponseTooLarge;
        if (response.head.content_encoding != .identity) return error.UnsupportedContentEncoding;
        var body_buffer: [8192]u8 = undefined;
        const body = try response.reader(&body_buffer).allocRemaining(a, .limited(max_response));
        defer a.free(body);
        return parse(a, body, kind);
    }
};

test "URL encoding prevents query and path injection" {
    const a = std.testing.allocator;
    const s = try url(a, .search, &.{"a b/&?#é"});
    defer a.free(s);
    try std.testing.expectEqualStrings("https://aur.archlinux.org/rpc/v5/search/a%20b%2F%26%3F%23%C3%A9?by=name-desc", s);
    const i = try url(a, .info, &.{ "foo", "bar&x" });
    defer a.free(i);
    try std.testing.expectEqualStrings("https://aur.archlinux.org/rpc/v5/info?arg%5B%5D=foo&arg%5B%5D=bar%26x", i);
}
test "nullable and absent fields, owned response strings, dependencies" {
    const r = try parse(std.testing.allocator,
        \\{"version":5,"type":"multiinfo","resultcount":1,"results":[{"Name":"foo","PackageBase":"foo-base","Version":"1:2-3","Description":null,"Maintainer":null,"OutOfDate":null,"Depends":["bar>=2"],"Unknown":42}]}
    , .info);
    defer r.deinit();
    const p = r.get(0);
    try std.testing.expectEqualStrings("foo", p.name);
    try std.testing.expect(p.description == null and p.maintainer == null and p.out_of_date == null);
    try std.testing.expectEqualStrings("bar>=2", p.depends[0]);
    try std.testing.expectEqual(@as(usize, 0), p.make_depends.len);
}
test "API errors and invalid envelopes" {
    const a = std.testing.allocator;
    const r = try parse(a, "{\"version\":5,\"type\":\"error\",\"error\":\"Too many package results.\"}", .search);
    defer r.deinit();
    try std.testing.expectEqualStrings("Too many package results.", r.apiError().?);
    try std.testing.expectError(error.SyntaxError, parse(a, "not json", .search));
    try std.testing.expectError(error.MalformedRpcResponse, parse(a, "{\"version\":5,\"type\":\"search\",\"resultcount\":1,\"results\":[]}", .search));
    try std.testing.expectError(error.UnsupportedRpcVersion, parse(a, "{\"version\":6,\"type\":\"search\"}", .search));
    try std.testing.expectError(error.MalformedRpcResponse, parse(a, "{\"version\":5,\"type\":\"multiinfo\"}", .search));
}

test "required envelope and package fields, wrong types and empty results" {
    const a = std.testing.allocator;
    for ([_][]const u8{
        \\{"version":5,"type":"search"}
        ,
        \\{"version":5,"type":"search","resultcount":0}
        ,
        \\{"version":5,"type":"search","results":[]}
        ,
        \\{"version":5,"type":"error"}
        ,
        \\{"version":5,"type":"search","resultcount":1,"results":[{"Name":"bad/name","PackageBase":"foo","Version":"1"}]}
        ,
    }) |json| try std.testing.expectError(error.MalformedRpcResponse, parse(a, json, .search));
    try std.testing.expectError(error.MissingField, parse(a,
        \\{"version":5,"type":"search","resultcount":1,"results":[{"Name":"foo","Version":"1"}]}
    , .search));
    try std.testing.expectError(error.UnexpectedToken, parse(a,
        \\{"version":5,"type":"search","resultcount":false,"results":[]}
    , .search));
    const empty = try parse(a,
        \\{"version":5,"type":"search","resultcount":0,"results":[]}
    , .search);
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.count());
}

fn allocationScenario(a: std.mem.Allocator) !void {
    const address = try url(a, .info, &.{ "foo", "bar" });
    defer a.free(address);
    const response = try parse(a,
        \\{"version":5,"type":"multiinfo","resultcount":1,"results":[{"Name":"foo","PackageBase":"foo","Version":"1","Depends":["bar>=2"]}]}
    , .info);
    defer response.deinit();
}
test "AUR allocation failures release owned memory" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationScenario, .{});
}
test "request and response limits" {
    const a = std.testing.allocator;
    const large = try a.alloc(u8, max_response + 1);
    defer a.free(large);
    @memset(large, 'a');
    try std.testing.expectError(error.ResponseTooLarge, parse(a, large, .search));
    try std.testing.expectError(error.RequestTooLarge, url(a, .search, &.{large[0..8001]}));
    try std.testing.expectError(error.InvalidArguments, url(a, .search, &.{}));
}

test "provider queries and info conflict/replacement metadata" {
    const a = std.testing.allocator;
    const address = try url(a, .providers, &.{"virtual"});
    defer a.free(address);
    try std.testing.expectEqualStrings("https://aur.archlinux.org/rpc/v5/search/virtual?by=provides", address);
    const r = try parse(a,
        \\{"version":5,"type":"multiinfo","resultcount":1,"results":[{"Name":"impl","PackageBase":"impl","Version":"1","Provides":["virtual=2"],"Conflicts":["other<2"],"Replaces":["old"]}]}
    , .info);
    defer r.deinit();
    try std.testing.expectEqualStrings("other<2", r.get(0).conflicts[0]);
    try std.testing.expectEqualStrings("old", r.get(0).replaces[0]);
    try std.testing.expectError(error.MalformedRpcResponse, parse(a,
        \\{"version":5,"type":"multiinfo","resultcount":1,"results":[{"Name":"impl","PackageBase":"impl","Version":"1\u0000garbage"}]}
    , .info));
}
