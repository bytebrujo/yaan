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
const env = @import("env");
const dist_embed = @import("dist_embed");
const load_runner = @import("load_runner");
const action_runner = @import("action_runner");
const remote_runner = @import("remote_runner");

// In-process load/action/remote: call the generated runners' `run()` directly.
fn loadFn(io: std.Io, allocator: std.mem.Allocator, method: []const u8, path: []const u8, headers_json: []const u8, meta_json: []const u8) anyerror![]u8 {
    return load_runner.run(io, allocator, method, path, headers_json, meta_json);
}
fn actionFn(io: std.Io, allocator: std.mem.Allocator, method: []const u8, path: []const u8, body: []const u8, uploads_json: []const u8, headers_json: []const u8, meta_json: []const u8) anyerror![]u8 {
    return action_runner.run(io, allocator, method, path, body, uploads_json, headers_json, meta_json);
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
        const id = try hooks.errorId(a, err, ctx.request.path);
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
    // Respect $PORT when --port is absent (Cloud Run and most PaaS set it).
    const port_text = optionValue(args, "--port") orelse init.environ_map.get("PORT") orelse "5173";
    const port = try std.fmt.parseInt(u16, port_text, 10);
    const debug_errors = optionFlag(args, "--debug-errors");
    const trusted_proxies = try optionList(allocator, args, "--trusted-proxy");
    const trust_forwarded = optionFlag(args, "--trust-forwarded");
    const force_https = optionFlag(args, "--force-https");
    const hsts = optionFlag(args, "--hsts");
    const hsts_max_age = try parseU32Option(args, "--hsts-max-age", 31_536_000);
    const max_body_length = try parseUsizeOption(args, "--max-body", 8 * 1024 * 1024);
    const max_upload_file_length = try parseUsizeOption(args, "--max-upload-file", 8 * 1024 * 1024);
    const max_upload_count = try parseUsizeOption(args, "--max-upload-count", 16);
    const max_form_fields_length = try parseUsizeOption(args, "--max-form-fields", 1024 * 1024);
    const max_multipart_header_length = try parseUsizeOption(args, "--max-multipart-header", 16 * 1024);
    const max_header_length = try parseUsizeOption(args, "--max-headers", 32 * 1024);
    const read_timeout_ms = try parseU32Option(args, "--read-timeout-ms", 10_000);
    const cookie_secret = optionValue(args, "--cookie-secret") orelse init.environ_map.get("YAAN_COOKIE_SECRET") orelse "";
    const csrf_protection = optionFlag(args, "--csrf");
    if (csrf_protection and cookie_secret.len == 0) return error.MissingCookieSecret;

    // Escape hatch: serve the built assets from this directory on disk instead of
    // the embedded copy (e.g. a volume-mounted dist/ kept in sync with a CDN, or
    // to swap assets without rebuilding). Defaults to the embedded dist/.
    const assets_dir = optionValue(args, "--assets-dir");

    // The deploy artifact does NOT build at boot. When serving the embedded dist/
    // it needs nothing on disk; with --assets-dir it serves that directory. Fail
    // fast if neither has content rather than serving an empty site.
    if (assets_dir == null and dist_embed.entries.len == 0) {
        std.debug.print("no embedded assets; run `zig build` (which runs `yaan build`) before starting\n", .{});
        std.process.exit(1);
    }
    if (assets_dir) |dir| {
        std.Io.Dir.cwd().access(io, dir, .{}) catch {
            std.debug.print("--assets-dir '{s}' not found\n", .{dir});
            std.process.exit(1);
        };
    }

    // Resolve runtime (private, non-static) env vars from this process's
    // environment before serving. One init() populates the shared `env` module
    // for every linked-in handler (load/action/remote/hook), so the same binary
    // serves different environments by varying the process env — no rebuild.
    env.init(init.environ_map) catch |err| {
        std.debug.print("env init failed: {t}\n", .{err});
        std.process.exit(1);
    };

    std.debug.print("yaan in-process server (hooks+load+action+remote linked) on http://{s}:{d}\n", .{ host, port });
    // Per-connection request arenas are based on a thread-safe, reclaiming
    // allocator so concurrent requests free their memory (init.arena, used for
    // startup above, never reclaims).
    try yaan.server.serve(io, std.heap.smp_allocator, .{
        .host = host,
        .port = port,
        // With --assets-dir, serve that directory from disk; otherwise serve the
        // embedded dist/ from inside the binary (no filesystem).
        .root = assets_dir orelse "dist",
        .assets = if (assets_dir == null) &dist_embed.lookup else null,
        .hook = &userHook,
        .load = &loadFn,
        .action = &actionFn,
        .remote = &remoteFn,
        // The in-process server is the production deploy artifact, so it is
        // production-safe by default: internals never leak. `--debug-errors`
        // opts into verbose error pages for local development (the dev-inproc
        // build step passes it).
        .debug_errors = debug_errors,
        .trusted_proxies = trusted_proxies,
        .trust_forwarded = trust_forwarded,
        .force_https = force_https,
        .hsts = hsts,
        .hsts_max_age = hsts_max_age,
        .max_body_length = max_body_length,
        .max_upload_file_length = max_upload_file_length,
        .max_upload_count = max_upload_count,
        .max_form_fields_length = max_form_fields_length,
        .max_multipart_header_length = max_multipart_header_length,
        .max_header_length = max_header_length,
        .read_timeout_ms = read_timeout_ms,
        .cookie_secret = cookie_secret,
        .csrf_protection = csrf_protection,
    });
}

fn optionValue(args: []const []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], name) and i + 1 < args.len) return args[i + 1];
    }
    return null;
}

fn optionFlag(args: []const []const u8, name: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, name)) return true;
    }
    return false;
}

fn optionList(allocator: std.mem.Allocator, args: []const []const u8, name: []const u8) ![]const []const u8 {
    const raw = optionValue(args, name) orelse return &.{};
    var items: std.ArrayList([]const u8) = .empty;
    var parts = std.mem.splitScalar(u8, raw, ',');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len > 0) try items.append(allocator, trimmed);
    }
    return items.toOwnedSlice(allocator);
}

fn parseUsizeOption(args: []const []const u8, name: []const u8, default: usize) !usize {
    return try std.fmt.parseInt(usize, optionValue(args, name) orelse return default, 10);
}

fn parseU32Option(args: []const []const u8, name: []const u8, default: u32) !u32 {
    return try std.fmt.parseInt(u32, optionValue(args, name) orelse return default, 10);
}
