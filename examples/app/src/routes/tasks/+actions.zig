const routes = @import("routes");

pub const Form = struct {
    title: []const u8,
};

pub const Result = struct {
    ok: bool,
    title: []const u8,
};

pub fn action(ctx: routes.ActionContext(.tasks), form: Form) !Result {
    _ = ctx;
    return .{ .ok = form.title.len > 0, .title = form.title };
}
