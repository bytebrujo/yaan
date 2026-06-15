const routes = @import("routes");

pub const Data = struct {
    id: i64,
};

pub fn load(ctx: routes.LoadContext(.users_id)) !Data {
    return .{ .id = ctx.params.id };
}
