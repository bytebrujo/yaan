const std = @import("std");
const app_env = @import("env");
const remote = @import("remote");

pub const kind: remote.Kind = .query;

pub const Input = struct {
    name: []const u8,
};

pub const Output = struct {
    message: []const u8,
};

pub fn call(ctx: remote.Context, input: Input) !Output {
    return .{
        .message = try std.fmt.allocPrint(ctx.allocator, "{s}, {s}", .{ app_env.GREETING_PREFIX, input.name }),
    };
}
