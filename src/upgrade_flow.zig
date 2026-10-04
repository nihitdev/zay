/// The repository phase and catalog refresh must complete in order before an
/// AUR update plan is allowed to continue. This small seam is shared by the
/// transaction code and offline tests (whose callbacks never touch the host).
pub const Hooks = struct {
    context: *anyopaque,
    repository_upgrade: *const fn (*anyopaque) anyerror!u8,
    replan: *const fn (*anyopaque) anyerror!u8,
};

pub fn run(hooks: Hooks) !u8 {
    const repository_status = try hooks.repository_upgrade(hooks.context);
    if (repository_status != 0) return repository_status;
    return hooks.replan(hooks.context);
}

const std = @import("std");

const Fake = struct {
    steps: [2]u8 = .{ 0, 0 },
    count: usize = 0,
    repository_status: u8 = 0,
    replan_status: u8 = 0,

    fn repository(context: *anyopaque) anyerror!u8 {
        const self: *Fake = @ptrCast(@alignCast(context));
        self.steps[self.count] = 1;
        self.count += 1;
        return self.repository_status;
    }

    fn replan(context: *anyopaque) anyerror!u8 {
        const self: *Fake = @ptrCast(@alignCast(context));
        self.steps[self.count] = 2;
        self.count += 1;
        return self.replan_status;
    }

    fn hooks(self: *Fake) Hooks {
        return .{ .context = self, .repository_upgrade = repository, .replan = replan };
    }
};

test "reviewed AUR update waits for repository upgrade and replans before continuing" {
    var fake: Fake = .{};
    const status = try run(fake.hooks());
    try std.testing.expectEqual(@as(u8, 0), status);
    try std.testing.expectEqual(@as(usize, 2), fake.count);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, fake.steps[0..fake.count]);
}

test "failed repository upgrade prevents stale AUR replan" {
    var fake: Fake = .{ .repository_status = 7 };
    const status = try run(fake.hooks());
    try std.testing.expectEqual(@as(u8, 7), status);
    try std.testing.expectEqual(@as(usize, 1), fake.count);
}

test "failed AUR replan stops before build continuation" {
    var fake: Fake = .{ .replan_status = 2 };
    const status = try run(fake.hooks());
    try std.testing.expectEqual(@as(u8, 2), status);
    try std.testing.expectEqual(@as(usize, 2), fake.count);
}
