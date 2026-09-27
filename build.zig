const std = @import("std");
pub fn build(b: *std.Build) void {
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    });
    module.link_libc = true;
    module.linkSystemLibrary("alpm", .{});
    const exe = b.addExecutable(.{ .name = "zay", .root_module = module });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run zay").dependOn(&run.step);
    const tests = b.addRunArtifact(b.addTest(.{ .root_module = module }));
    b.step("test", "Run safe unit tests").dependOn(&tests.step);
    const integration = b.addSystemCommand(&.{ "/bin/sh", "tests/cli.sh" });
    integration.addArtifactArg(exe);
    b.step("test-integration", "Run offline CLI tests with a fake pacman").dependOn(&integration.step);
    const planner = b.addSystemCommand(&.{ "/bin/sh", "tests/planner.sh" });
    planner.addArtifactArg(exe);
    b.step("test-planner", "Run offline planner tests with synthetic package databases").dependOn(&planner.step);
}
