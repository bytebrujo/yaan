const std = @import("std");
const hooks = @import("hooks");

pub const Locals = struct {
    request_id: []const u8 = "dev",
};

pub fn handle(ctx: *hooks.Context(Locals)) !hooks.Decision {
    if (std.mem.eql(u8, ctx.request.path, "/healthz")) {
        return hooks.text(200, "ok");
    }
    if (std.mem.eql(u8, ctx.request.path, "/old-docs")) {
        return hooks.redirect("/docs/intro/setup");
    }
    if (std.mem.eql(u8, ctx.request.path, "/start")) {
        return hooks.rewrite("/");
    }
    return hooks.pass();
}
