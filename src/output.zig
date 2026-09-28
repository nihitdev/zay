const std = @import("std");
const Package = @import("package.zig").Package;
pub const Style = enum { info, warning, err, package, version, heading };

pub fn styled(w: *std.Io.Writer, enabled: bool, style: Style, value: []const u8) !void {
    if (enabled) try w.writeAll(switch (style) {
        .info => "\x1b[1;36m",
        .warning => "\x1b[1;33m",
        .err => "\x1b[1;31m",
        .package => "\x1b[1m",
        .version => "\x1b[1;32m",
        .heading => "\x1b[1;35m",
    });
    try w.writeAll(value);
    if (enabled) try w.writeAll("\x1b[0m");
}

pub fn infoPrefix(w: *std.Io.Writer, enabled: bool) !void {
    try styled(w, enabled, .info, "::");
    try w.writeByte(' ');
}

pub fn warningPrefix(w: *std.Io.Writer, enabled: bool) !void {
    try styled(w, enabled, .warning, "warning:");
    try w.writeByte(' ');
}

pub fn errorPrefix(w: *std.Io.Writer, enabled: bool) !void {
    try styled(w, enabled, .err, "error:");
    try w.writeByte(' ');
}

/// AUR metadata is untrusted terminal content. Escape controls, including ESC.
pub fn safe(w: *std.Io.Writer, value: []const u8) !void {
    return safeImpl(w, value, false);
}

/// Preserve line structure for source files shown during the required AUR
/// review while still escaping terminal controls supplied by the repository.
pub fn safeMultiline(w: *std.Io.Writer, value: []const u8) !void {
    return safeImpl(w, value, true);
}

fn safeImpl(w: *std.Io.Writer, value: []const u8, multiline: bool) !void {
    var i: usize = 0;
    while (i < value.len) {
        const len = std.unicode.utf8ByteSequenceLength(value[i]) catch {
            try w.writeByte('?');
            i += 1;
            continue;
        };
        if (len > value.len - i) {
            try w.writeByte('?');
            break;
        }
        const bytes = value[i..][0..len];
        const c = std.unicode.utf8Decode(bytes) catch {
            try w.writeByte('?');
            i += 1;
            continue;
        };
        if (multiline and (c == '\n' or c == '\t')) {
            try w.writeAll(bytes);
        } else if (c < 32 or (c >= 127 and c <= 159)) {
            try w.writeByte('?');
        } else try w.writeAll(bytes);
        i += len;
    }
}
pub fn search(w: *std.Io.Writer, p: Package, color: bool) !void {
    try styled(w, color, .heading, "aur/");
    try styled(w, color, .package, p.name);
    try w.writeByte(' ');
    try styled(w, color, .version, p.version);
    if (p.maintainer == null) {
        try w.writeByte(' ');
        try styled(w, color, .warning, "[orphaned]");
    }
    if (p.out_of_date != null) {
        try w.writeByte(' ');
        try styled(w, color, .warning, "[out-of-date]");
    }
    try w.writeAll("\n    ");
    try safe(w, p.description orelse "(no description)");
    try w.writeByte('\n');
}
fn field(w: *std.Io.Writer, color: bool, label: []const u8, value: []const u8, value_style: Style) !void {
    try styled(w, color, .info, label);
    for (label.len..16) |_| try w.writeByte(' ');
    try w.writeAll(": ");
    try styled(w, color, value_style, value);
    try w.writeByte('\n');
}
fn list(w: *std.Io.Writer, color: bool, label: []const u8, values: []const []const u8) !void {
    try styled(w, color, .info, label);
    for (label.len..16) |_| try w.writeByte(' ');
    try w.writeAll(": ");
    if (values.len == 0) try w.writeAll("None");
    for (values, 0..) |value, i| {
        if (i != 0) try w.writeAll("  ");
        try safe(w, value);
    }
    try w.writeByte('\n');
}
pub fn info(w: *std.Io.Writer, p: Package, color: bool) !void {
    try field(w, color, "Repository", "aur", .heading);
    try field(w, color, "Name", p.name, .package);
    try field(w, color, "Package Base", p.base, .package);
    try field(w, color, "Version", p.version, .version);
    try field(w, color, "Description", p.description orelse "None", .info);
    try field(w, color, "URL", p.url orelse "None", .info);
    try field(w, color, "Maintainer", p.maintainer orelse "None (orphaned)", .info);
    try list(w, color, "Depends On", p.depends);
    try list(w, color, "Make Depends", p.make_depends);
    try list(w, color, "Check Depends", p.check_depends);
    try list(w, color, "Provides", p.provides);
    try w.print("Votes           : {d}\nPopularity      : {d:.2}\n", .{ p.votes, p.popularity });
    try field(w, color, "Out Of Date", if (p.out_of_date != null) "Yes" else "No", if (p.out_of_date != null) .warning else .info);
    try w.writeByte('\n');
}
test "terminal control sanitization" {
    var buffer: [100]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try safe(&w, "hello\x1b[31m\nworld 日本語 é\u{009b}\xff");
    try std.testing.expectEqualStrings("hello?[31m?world 日本語 é??", w.buffered());
}

test "multiline review text keeps layout but escapes terminal controls" {
    var buffer: [100]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try safeMultiline(&w, "pkgname=demo\n\tvalue\x1b[31m\rend");
    try std.testing.expectEqualStrings("pkgname=demo\n\tvalue?[31m?end", w.buffered());
}

test "style helpers emit no escapes when color is disabled" {
    var buffer: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try infoPrefix(&w, false);
    try styled(&w, false, .package, "hello 2.12.1-2");
    try w.writeByte(' ');
    try errorPrefix(&w, false);
    try w.writeAll("failed\n");
    try std.testing.expectEqualStrings(":: hello 2.12.1-2 error: failed\n", w.buffered());
}

test "style helpers distinguish versions and headings when color is enabled" {
    var buffer: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try styled(&w, true, .heading, "aur/");
    try styled(&w, true, .package, "sample");
    try w.writeByte(' ');
    try styled(&w, true, .version, "1.2-1");
    try std.testing.expectEqualStrings("\x1b[1;35maur/\x1b[0m\x1b[1msample\x1b[0m \x1b[1;32m1.2-1\x1b[0m", w.buffered());
}

test "search output is compact and adds no escapes without color" {
    var buffer: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    const p: Package = .{
        .name = "example",
        .base = "example",
        .version = "1-1",
        .description = "A package",
        .url = null,
        .maintainer = null,
        .votes = 123,
        .popularity = 4.5,
        .out_of_date = 1,
        .depends = &.{},
        .make_depends = &.{},
        .check_depends = &.{},
        .provides = &.{},
    };
    try search(&w, p, false);
    try std.testing.expectEqualStrings("aur/example 1-1 [orphaned] [out-of-date]\n    A package\n", w.buffered());
}
