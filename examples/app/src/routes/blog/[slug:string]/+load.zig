const routes = @import("routes");

pub const Data = struct {
    title: []const u8,
};

pub fn load(ctx: routes.LoadContext(.blog_slug)) !Data {
    return .{ .title = ctx.params.slug };
}
