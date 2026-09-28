const std = @import("std");
const Package = @import("package.zig").Package;
pub const Style = enum { info, warning, err, package, heading };

pub fn styled(w: *std.Io.Writer, enabled: bool, style: Style, value: []const u8) !void {
    if (enabled) try w.writeAll(switch (style) {
        .info => "\x1b[1;36m",
        .warning => "\x1b[1;33m",
        .err => "\x1b[1;31m",
        .package => "\x1b[1m",
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
    if (color) try w.writeAll("\x1b[1;35m");
    try w.writeAll("aur/");
    try safe(w, p.name);
    if (color) try w.writeAll("\x1b[0m");
    try w.writeByte(' ');
    try safe(w, p.version);
    if (p.maintainer == null) try w.writeAll(" [orphaned]");
    if (p.out_of_date != null) try w.writeAll(" [out-of-date]");
    try w.writeAll("\n    ");
    try safe(w, p.description orelse "(no description)");
    try w.writeByte('\n');
}
fn field(w: *std.Io.Writer, label: []const u8, value: []const u8) !void {
    try w.print("{s: <16}: ", .{label});
    try safe(w, value);
    try w.writeByte('\n');
}
fn list(w: *std.Io.Writer, label: []const u8, values: []const []const u8) !void {
    try w.print("{s: <16}: ", .{label});
    if (values.len == 0) try w.writeAll("None");
    for (values, 0..) |value, i| {
        if (i != 0) try w.writeAll("  ");
        try safe(w, value);
    }
    try w.writeByte('\n');
}
pub fn info(w: *std.Io.Writer, p: Package) !void {
    try field(w, "Repository", "aur");
    try field(w, "Name", p.name);
    try field(w, "Package Base", p.base);
    try field(w, "Version", p.version);
    try field(w, "Description", p.description orelse "None");
    try field(w, "URL", p.url orelse "None");
    try field(w, "Maintainer", p.maintainer orelse "None (orphaned)");
    try list(w, "Depends On", p.depends);
    try list(w, "Make Depends", p.make_depends);
    try list(w, "Check Depends", p.check_depends);
    try list(w, "Provides", p.provides);
    try w.print("Votes           : {d}\nPopularity      : {d:.2}\n", .{ p.votes, p.popularity });
    try field(w, "Out Of Date", if (p.out_of_date != null) "Yes" else "No");
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
