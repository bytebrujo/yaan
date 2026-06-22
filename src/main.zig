const std = @import("std");
const yaan = @import("yaan");
const build_options = @import("build_options");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 2) return usage();

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "init")) {
        const name: ?[]const u8 = if (args.len >= 3 and !std.mem.startsWith(u8, args[2], "-")) args[2] else null;
        const cwd_abs = init.environ_map.get("PWD") orelse "";
        yaan.project.writeExampleApp(init.io, allocator, name, build_options.framework_root, cwd_abs) catch |err| switch (err) {
            // Message already printed by writeExampleApp; exit without a trace.
            error.PathAlreadyExists => std.process.exit(1),
            else => return err,
        };
        const deploy_hint = "\n\nto build the deployable single binary:\n  zig build -Doptimize=ReleaseFast   (-> zig-out/bin/yaan-app; see `yaan add docker`)\n";
        if (name) |n| {
            std.debug.print("created Yaan app '{s}'\n\nnext steps:\n  cd {s}\n  yaan dev{s}", .{ n, n, deploy_hint });
        } else {
            std.debug.print("created Yaan app in the current directory\n\nnext steps:\n  yaan dev{s}", .{deploy_hint});
        }
    } else if (std.mem.eql(u8, cmd, "add")) {
        const target = if (args.len >= 3 and !std.mem.startsWith(u8, args[2], "-")) args[2] else "";
        yaan.project.addDeployFile(init.io, allocator, target, build_options.framework_url, build_options.framework_version) catch |err| switch (err) {
            error.UnknownAddTarget => {
                std.debug.print("usage: yaan add <docker|systemd|cloudrun>\n", .{});
                std.process.exit(1);
            },
            else => return err,
        };
    } else if (std.mem.eql(u8, cmd, "deploy")) {
        const sub = if (args.len >= 3 and !std.mem.startsWith(u8, args[2], "-")) args[2] else "";
        if (!std.mem.eql(u8, sub, "gcp") and !std.mem.eql(u8, sub, "cloudrun")) {
            std.debug.print("usage: yaan deploy gcp [--project ID] [--region R] [--service NAME] [--set-env-vars K=V,...] [--no-allow-unauthenticated] [--skip-dep-check] [--dry-run]\n", .{});
            std.process.exit(1);
        }
        yaan.project.deployCloudRun(init.io, allocator, .{
            .service = optionValue(args, "--service") orelse "yaan-app",
            .project = optionValue(args, "--project"),
            .region = optionValue(args, "--region"),
            .allow_unauthenticated = !optionFlag(args, "--no-allow-unauthenticated"),
            .set_env_vars = optionValue(args, "--set-env-vars"),
            .dry_run = optionFlag(args, "--dry-run"),
            .framework_url = build_options.framework_url,
            .framework_version = build_options.framework_version,
            .skip_dep_check = optionFlag(args, "--skip-dep-check"),
        }) catch |err| switch (err) {
            // Message already printed; exit without a trace.
            error.GcloudNotFound, error.DeployFailed, error.LocalPathDependency => std.process.exit(1),
            else => return err,
        };
    } else if (std.mem.eql(u8, cmd, "check")) {
        try runCheck(init.io, allocator);
    } else if (std.mem.eql(u8, cmd, "build")) {
        const out = optionValue(args, "--out") orelse "dist";
        try yaan.project.buildProject(init.io, allocator, out);
        if (optionFlag(args, "--runners")) {
            // Compile the subprocess runner binaries as part of the build so
            // `yaan start` never needs the Zig toolchain at boot. The in-process
            // deploy artifact links its handlers in and never uses these, so
            // they stay opt-in (plain `yaan build` stays fast for tests + the
            // in-process build).
            try yaan.project.buildDevLoadRunner(init.io, allocator);
            try yaan.project.buildDevActionRunner(init.io, allocator);
            try yaan.project.buildDevRemoteRunner(init.io, allocator);
            try yaan.project.buildDevHookRunner(init.io, allocator);
        }
        std.debug.print("built {s}\n", .{out});
    } else if (std.mem.eql(u8, cmd, "dev")) {
        try runServer(init.io, allocator, args, init.environ_map.get("YAAN_COOKIE_SECRET"), .dev);
    } else if (std.mem.eql(u8, cmd, "start")) {
        runServer(init.io, allocator, args, init.environ_map.get("YAAN_COOKIE_SECRET"), .start) catch |err| switch (err) {
            // Message already printed by runServer; exit without a trace.
            error.MissingBuild => std.process.exit(1),
            else => return err,
        };
    } else {
        return usage();
    }
}

const ServeMode = enum { dev, start };

/// Builds the request runners and serves the app. `dev` rebuilds `dist/` on
/// every run and shows debug error pages by default; `start` serves an existing
/// `yaan build` output and is production-safe by default (`--debug-errors` opts
/// back in). Both share the same server pipeline and flags.
fn runServer(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    env_cookie_secret: ?[]const u8,
    mode: ServeMode,
) !void {
    const host = optionValue(args, "--host") orelse "127.0.0.1";
    const port_text = optionValue(args, "--port") orelse "5173";
    const port = try std.fmt.parseInt(u16, port_text, 10);
    const otel_endpoint = optionValue(args, "--otel-endpoint");
    const service_name = optionValue(args, "--otel-service") orelse "yaan-dev";
    const trusted_proxies = try optionList(allocator, args, "--trusted-proxy");
    const trust_forwarded = optionFlag(args, "--trust-forwarded");
    const force_https = optionFlag(args, "--force-https");
    const hsts = optionFlag(args, "--hsts");
    const hsts_max_age = try parseU32Option(args, "--hsts-max-age", 31536000);
    const max_body_length = try parseUsizeOption(args, "--max-body", 8 * 1024 * 1024);
    const max_upload_file_length = try parseUsizeOption(args, "--max-upload-file", 8 * 1024 * 1024);
    const max_upload_count = try parseUsizeOption(args, "--max-upload-count", 16);
    const max_form_fields_length = try parseUsizeOption(args, "--max-form-fields", 1024 * 1024);
    const max_multipart_header_length = try parseUsizeOption(args, "--max-multipart-header", 16 * 1024);
    const max_header_length = try parseUsizeOption(args, "--max-headers", 32 * 1024);
    const read_timeout_ms = try parseU32Option(args, "--read-timeout-ms", 10_000);
    const csrf_protection = optionFlag(args, "--csrf");
    const cookie_secret = optionValue(args, "--cookie-secret") orelse env_cookie_secret orelse "";
    if (csrf_protection and cookie_secret.len == 0) return error.MissingCookieSecret;

    const debug_errors = switch (mode) {
        // dev shows safe details by default; --prod-errors forces prod output.
        .dev => !optionFlag(args, "--prod-errors"),
        // start is production-safe by default; --debug-errors opts into details.
        .start => optionFlag(args, "--debug-errors"),
    };

    switch (mode) {
        // dev is a toolchain context: rebuild dist/ and (re)compile the runners
        // on every run so edits are picked up.
        .dev => {
            try yaan.project.buildProject(io, allocator, "dist");
            try yaan.project.buildDevLoadRunner(io, allocator);
            try yaan.project.buildDevActionRunner(io, allocator);
            try yaan.project.buildDevRemoteRunner(io, allocator);
            try yaan.project.buildDevHookRunner(io, allocator);
        },
        // start serves a prior `yaan build --runners`. It must NOT invoke the
        // Zig toolchain at boot, so it only verifies the build output exists.
        .start => {
            const cwd = std.Io.Dir.cwd();
            cwd.access(io, "dist", .{}) catch {
                std.debug.print("no dist/ found; run `yaan build --runners` first\n", .{});
                return error.MissingBuild;
            };
        },
    }
    // The server bases each connection's request arena on this allocator; use a
    // thread-safe, reclaiming allocator so concurrent requests free their memory
    // (init.arena never reclaims). Setup above keeps using the process arena.
    try yaan.server.serve(io, std.heap.smp_allocator, .{
        .host = host,
        .port = port,
        .label = switch (mode) {
            .dev => "yaan dev",
            .start => "yaan",
        },
        .root = "dist",
        // Run the request through the in-process layer pipeline (which
        // bridges to the hook_runner subprocess) instead of calling it
        // directly. See src/pipeline.zig.
        .hook = &yaan.server.frameworkHook,
        .observability = .{
            .enabled = otel_endpoint != null,
            .endpoint = otel_endpoint orelse "http://127.0.0.1:4318/v1/traces",
            .service_name = service_name,
        },
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

fn runCheck(io: std.Io, allocator: std.mem.Allocator) !void {
    const failures = yaan.project.checkProject(io, allocator) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("no src/routes directory found\n", .{});
            return;
        },
        else => return err,
    };
    if (failures > 0) return error.CheckFailed;
    std.debug.print("yaan check passed\n", .{});
}

fn optionValue(args: []const []const u8, name: []const u8) ?[]const u8 {
    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, name) and i + 1 < args.len) return args[i + 1];
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

fn usage() void {
    std.debug.print(
        \\usage: yaan <command>
        \\
        \\commands:
        \\  init [name]
        \\  add <docker|systemd|cloudrun>    (emit deployment files for the single-binary artifact)
        \\  deploy gcp [--project ID] [--region R] [--service NAME] [--set-env-vars K=V,...] [--dry-run]
        \\  check
        \\  build [--out dist] [--runners]   (--runners also compiles subprocess runner binaries for `yaan start`)
        \\  dev [--host 127.0.0.1] [--port 5173] [--otel-endpoint http://127.0.0.1:4318/v1/traces] [--otel-service yaan-dev] [--prod-errors] [--trusted-proxy 127.0.0.1,::1] [--force-https] [--hsts] [--hsts-max-age 31536000] [--csrf] [--cookie-secret secret] [--max-body bytes]
        \\  start [--host 127.0.0.1] [--port 5173] [--debug-errors] [--trusted-proxy 127.0.0.1,::1] [--force-https] [--hsts] [--csrf] [--cookie-secret secret]  (serve a prior `yaan build --runners`)
        \\
    , .{});
}

test "option parser" {
    const args = [_][]const u8{ "yaan", "dev", "--port", "9000" };
    try std.testing.expectEqualStrings("9000", optionValue(&args, "--port").?);
}

test "option list parser" {
    const args = [_][]const u8{ "yaan", "dev", "--trusted-proxy", "127.0.0.1, ::1" };
    const values = try optionList(std.testing.allocator, &args, "--trusted-proxy");
    defer std.testing.allocator.free(values);
    try std.testing.expectEqual(@as(usize, 2), values.len);
    try std.testing.expectEqualStrings("127.0.0.1", values[0]);
    try std.testing.expectEqualStrings("::1", values[1]);
}
