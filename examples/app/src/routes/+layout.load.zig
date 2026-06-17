const std = @import("std");

/// Data exposed to the root layout on every route. Layout loaders are generic
/// over the request context (`ctx: anytype`) because one layout wraps many
/// routes with different param shapes; use `ctx.allocator` / `ctx.request`.
pub const Data = struct {
    framework: []const u8,
    year: u16,
};

pub fn load(ctx: anytype) !Data {
    _ = ctx;
    return .{ .framework = "Yaan", .year = 2026 };
}
