//! Per-app server entrypoint that links the user's hooks IN-PROCESS.
//!
//! This is the "build fork": instead of the generic `yaan` binary spawning a
//! `hook_runner` subprocess per request, an app compiles THIS file with its own
//! `hooks` (the generated framework runtime) and `app_hooks` (the user's
//! src/hooks.zig) linked in. The hook then runs inside the server process and
//! the hook_runner subprocess is never spawned.
//!
//! The app's build.zig provides the `yaan`, `hooks`, and `app_hooks` modules.
//! load/action/remote handlers still use their runners for now; only the hook
//! has been moved in-process.

const std = @import("std");
const yaan = @import("yaan");
const hooks = @import("hooks");
const app_hooks = @import("app_hooks");
const load_runner = @import("load_runner");
const action_runner = @import("action_runner");
const remote_runner = @import("remote_runner");

// In-process load/action/remote: call the generated runners' `run()` directly.
fn loadFn(io: std.Io, allocator: std.mem.Allocator, method: []const u8, path: []const u8) anyerror![]u8 {
    return load_runner.run(io, allocator, method, path);
}
fn actionFn(io: std.Io, allocator: std.mem.Allocator, method: []const u8, path: []const u8, body: []const u8, uploads_json: []const u8) anyerror![]u8 {
    return action_runner.run(io, allocator, method, path, body, uploads_json);
}
fn remoteFn(io: std.Io, allocator: std.mem.Allocator, method: []const u8, path: []const u8, body: []const u8) anyerror![]u8 {
    return remote_runner.run(io, allocator, method, path, body);
}

const Locals = if (@hasDecl(app_hooks, "Locals")) app_hooks.Locals else hooks.EmptyLocals;

fn queryPart(target: []const u8) []const u8 {
    const i = std.mem.indexOfScalar(u8, target, '?') orelse return "";
    return target[i + 1 ..];
}

fn dupeHeaders(allocator: std.mem.Allocator, headers: []const hooks.Header) ![]yaan.server.Header {
    const out = try allocator.alloc(yaan.server.Header, headers.len);
    errdefer allocator.free(out);
    for (headers, 0..) |h, i| {
        out[i] = .{ .name = try allocator.dupe(u8, h.name), .value = try allocator.dupe(u8, h.value) };
    }
    return out;
}

fn halt(allocator: std.mem.Allocator, response: hooks.Response) !yaan.server.HookDecision {
    return .{ .halt = .{
        .status = response.status,
        .content_type = try allocator.dupe(u8, response.content_type),
        .location = if (response.location) |l| try allocator.dupe(u8, l) else null,
        .headers = try dupeHeaders(allocator, response.headers),
        .body = try allocator.dupe(u8, response.body),
    } };
}

/// The in-process hook: builds the framework Context, runs the user's `handle`
/// directly, and maps the user-facing `hooks.Decision` to the server's
/// `HookDecision`. No subprocess, no JSON.
fn userHook(io: std.Io, allocator: std.mem.Allocator, hook_runner: []const u8, request: yaan.server.HookRequest) anyerror!yaan.server.HookDecision {
    _ = io;
    _ = hook_runner;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = hooks.Context(Locals){
        .allocator = a,
        .request = .{
            .method = request.method,
            .target = request.target,
            .path = request.path,
            .query = queryPart(request.target),
            .body = request.body,
        },
        .locals = .{},
    };
    const decision = app_hooks.handle(&ctx) catch |err| {
        const id = try std.fmt.allocPrint(a, "err-{s}", .{@errorName(err)});
        var error_ctx = hooks.ErrorContext{ .allocator = a, .request = ctx.request, .err = err, .id = id };
        const response = if (@hasDecl(app_hooks, "onError")) app_hooks.onError(&error_ctx) else hooks.defaultOnError(&error_ctx);
        return halt(allocator, response);
    };
    return switch (decision) {
        .continue_ => |c| .{ .continue_ = .{
            .path = if (c.path) |p| try allocator.dupe(u8, p) else null,
            .headers = try dupeHeaders(allocator, c.headers),
        } },
        .halt => |r| try halt(allocator, r),
    };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    const host = optionValue(args, "--host") orelse "127.0.0.1";
    const port_text = optionValue(args, "--port") orelse "5173";
    const port = try std.fmt.parseInt(u16, port_text, 10);

    // Generate the app's dist + .yaan artifacts. No runner SUBPROCESSES are
    // built — hook, load, action, and remote all run in-process now.
    try yaan.project.buildProject(io, allocator, "dist");

    std.debug.print("yaan in-process server (hooks+load+action+remote linked) on http://{s}:{d}\n", .{ host, port });
    try yaan.server.serve(io, allocator, .{
        .host = host,
        .port = port,
        .root = "dist",
        .hook = &userHook,
        .load = &loadFn,
        .action = &actionFn,
        .remote = &remoteFn,
    });
}

fn optionValue(args: []const []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], name) and i + 1 < args.len) return args[i + 1];
    }
    return null;
}
