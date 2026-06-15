const routes = @import("routes");

pub const Form = struct {
    email: []const u8,
    password: []const u8,
    avatar: ?routes.Upload,
};

pub const Result = struct {
    ok: bool,
    message: []const u8,
};

pub fn action(ctx: routes.ActionContext(.login), form: Form) !Result {
    _ = ctx;
    return .{
        .ok = form.password.len >= 6,
        .message = if (form.avatar) |upload|
            upload.filename
        else if (form.password.len >= 6)
            form.email
        else
            "Password is too short",
    };
}
