const std = @import("std");

/// Options for `addInProcessServer`. `yaan_dep` is the app's `b.dependency("yaan", ...)`,
/// `app_build_step` is the step that runs `yaan build` (generating `.yaan/*` + dist).
pub const InProcessOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    yaan_dep: *std.Build.Dependency,
    app_build_step: *std.Build.Step,
    name: []const u8 = "yaan-app",
};

/// Builds a per-app server executable that links the app's hooks, load, action,
/// and remote handlers IN-PROCESS (no runner subprocesses). Route/remote handler
/// modules are discovered from the app's `src/` so no route list is hardcoded.
/// The app's build.zig wires the whole in-process server with a single call.
pub fn addInProcessServer(b: *std.Build, opts: InProcessOptions) *std.Build.Step.Compile {
    const target = opts.target;
    const dep = opts.yaan_dep;
    const yaan_mod = dep.module("yaan");

    const database_mod = b.createModule(.{ .root_source_file = b.path(".yaan/database.zig"), .target = target });
    const env_mod = b.createModule(.{ .root_source_file = b.path(".yaan/env.zig"), .target = target });
    const assets_mod = b.createModule(.{ .root_source_file = b.path(".yaan/assets.zig"), .target = target });
    const hooks_mod = b.createModule(.{
        .root_source_file = b.path(".yaan/hooks.zig"),
        .target = target,
        .imports = &.{.{ .name = "database", .module = database_mod }},
    });
    const app_hooks_mod = b.createModule(.{
        .root_source_file = b.path("src/hooks.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "hooks", .module = hooks_mod },
            .{ .name = "env", .module = env_mod },
            .{ .name = "database", .module = database_mod },
            .{ .name = "assets", .module = assets_mod },
        },
    });
    const routes_mod = b.createModule(.{
        .root_source_file = b.path(".yaan/routes.zig"),
        .target = target,
        .imports = &.{ .{ .name = "database", .module = database_mod }, .{ .name = "assets", .module = assets_mod } },
    });
    const remote_support_mod = b.createModule(.{
        .root_source_file = b.path(".yaan/remote.zig"),
        .target = target,
        .imports = &.{.{ .name = "database", .module = database_mod }},
    });

    const route_imports = [_]std.Build.Module.Import{
        .{ .name = "routes", .module = routes_mod },
        .{ .name = "env", .module = env_mod },
        .{ .name = "database", .module = database_mod },
        .{ .name = "assets", .module = assets_mod },
    };
    const remote_handler_imports = [_]std.Build.Module.Import{
        .{ .name = "remote", .module = remote_support_mod },
        .{ .name = "env", .module = env_mod },
        .{ .name = "database", .module = database_mod },
        .{ .name = "assets", .module = assets_mod },
    };

    var load_imports: std.ArrayList(std.Build.Module.Import) = .empty;
    load_imports.append(b.allocator, .{ .name = "routes", .module = routes_mod }) catch @panic("oom");
    discoverHandlers(b, target, &load_imports, "src/routes", "+load.zig", "load", &route_imports);

    var action_imports: std.ArrayList(std.Build.Module.Import) = .empty;
    action_imports.append(b.allocator, .{ .name = "routes", .module = routes_mod }) catch @panic("oom");
    discoverHandlers(b, target, &action_imports, "src/routes", "+actions.zig", "action", &route_imports);

    var remote_imports: std.ArrayList(std.Build.Module.Import) = .empty;
    remote_imports.append(b.allocator, .{ .name = "remote", .module = remote_support_mod }) catch @panic("oom");
    discoverRemotes(b, target, &remote_imports, &remote_handler_imports);

    const load_runner_mod = b.createModule(.{ .root_source_file = b.path(".yaan/load_runner.zig"), .target = target, .imports = load_imports.items });
    const action_runner_mod = b.createModule(.{ .root_source_file = b.path(".yaan/action_runner.zig"), .target = target, .imports = action_imports.items });
    const remote_runner_mod = b.createModule(.{ .root_source_file = b.path(".yaan/remote_runner.zig"), .target = target, .imports = remote_imports.items });

    const app_server = b.addExecutable(.{
        .name = opts.name,
        .root_module = b.createModule(.{
            .root_source_file = dep.path("src/app_server.zig"),
            .target = target,
            .optimize = opts.optimize,
            .imports = &.{
                .{ .name = "yaan", .module = yaan_mod },
                .{ .name = "hooks", .module = hooks_mod },
                .{ .name = "app_hooks", .module = app_hooks_mod },
                .{ .name = "load_runner", .module = load_runner_mod },
                .{ .name = "action_runner", .module = action_runner_mod },
                .{ .name = "remote_runner", .module = remote_runner_mod },
            },
        }),
    });
    // The generated .yaan/* modules must exist before this compiles.
    app_server.step.dependOn(opts.app_build_step);
    return app_server;
}

fn appendSnake(al: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) void {
    var last_sep = false;
    for (value) |c| {
        if ((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9')) {
            out.append(al, c) catch @panic("oom");
            last_sep = false;
        } else if (c >= 'A' and c <= 'Z') {
            out.append(al, c + 32) catch @panic("oom");
            last_sep = false;
        } else if (!last_sep) {
            out.append(al, '_') catch @panic("oom");
            last_sep = true;
        }
    }
}

fn segmentName(part: []const u8) []const u8 {
    var s = part;
    if (s.len >= 2 and s[0] == '[' and s[s.len - 1] == ']') s = s[1 .. s.len - 1];
    if (std.mem.startsWith(u8, s, "...")) s = s[3..];
    if (std.mem.indexOfScalar(u8, s, ':')) |i| s = s[0..i];
    return s;
}

fn routeName(al: std.mem.Allocator, rel_dir: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var parts = std.mem.tokenizeScalar(u8, rel_dir, '/');
    var first = true;
    while (parts.next()) |part| {
        if (part.len >= 2 and part[0] == '(' and part[part.len - 1] == ')') continue;
        if (!first) out.append(al, '_') catch @panic("oom");
        first = false;
        appendSnake(al, &out, segmentName(part));
    }
    if (out.items.len == 0) return "home";
    return out.toOwnedSlice(al) catch @panic("oom");
}

fn discoverHandlers(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    imports: *std.ArrayList(std.Build.Module.Import),
    base: []const u8,
    basename: []const u8,
    prefix: []const u8,
    handler_imports: []const std.Build.Module.Import,
) void {
    const io = b.graph.io;
    var dir = b.build_root.handle.openDir(io, base, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var walker = dir.walk(b.allocator) catch @panic("oom");
    defer walker.deinit();
    while (walker.next(io) catch @panic("walk")) |entry| {
        if (entry.kind != .file or !std.mem.eql(u8, entry.basename, basename)) continue;
        const rel_dir = std.fs.path.dirname(entry.path) orelse "";
        const name = std.fmt.allocPrint(b.allocator, "{s}_{s}", .{ prefix, routeName(b.allocator, rel_dir) }) catch @panic("oom");
        const file = std.fs.path.join(b.allocator, &.{ base, entry.path }) catch @panic("oom");
        const mod = b.createModule(.{ .root_source_file = b.path(file), .target = target, .imports = handler_imports });
        imports.append(b.allocator, .{ .name = name, .module = mod }) catch @panic("oom");
    }
}

fn discoverRemotes(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    imports: *std.ArrayList(std.Build.Module.Import),
    handler_imports: []const std.Build.Module.Import,
) void {
    const io = b.graph.io;
    var dir = b.build_root.handle.openDir(io, "src/remotes", .{ .iterate = true }) catch return;
    defer dir.close(io);
    var walker = dir.walk(b.allocator) catch @panic("oom");
    defer walker.deinit();
    const suffix = ".remote.zig";
    while (walker.next(io) catch @panic("walk")) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, suffix)) continue;
        const stem = entry.basename[0 .. entry.basename.len - suffix.len];
        const name = std.fmt.allocPrint(b.allocator, "remote_{s}", .{stem}) catch @panic("oom");
        const file = std.fs.path.join(b.allocator, &.{ "src/remotes", entry.path }) catch @panic("oom");
        const mod = b.createModule(.{ .root_source_file = b.path(file), .target = target, .imports = handler_imports });
        imports.append(b.allocator, .{ .name = name, .module = mod }) catch @panic("oom");
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const app_root = b.option([]const u8, "app-root", "Yaan app root used by check/app-build/dev steps") orelse ".";
    const dev_host = b.option([]const u8, "host", "Dev server host") orelse "127.0.0.1";
    const dev_port = b.option([]const u8, "port", "Dev server port") orelse "5173";
    const otel_endpoint = b.option([]const u8, "otel-endpoint", "Enable OTLP tracing to this endpoint");
    const otel_service = b.option([]const u8, "otel-service", "OTLP service name") orelse "yaan-dev";
    const prod_errors = b.option(bool, "prod-errors", "Render production-safe error pages in dev") orelse false;
    const trusted_proxy = b.option([]const u8, "trusted-proxy", "Comma-separated trusted proxy IPs for X-Forwarded-* headers");
    const force_https = b.option(bool, "force-https", "Redirect insecure requests to HTTPS") orelse false;
    const hsts = b.option(bool, "hsts", "Emit Strict-Transport-Security on secure requests") orelse false;
    const hsts_max_age = b.option([]const u8, "hsts-max-age", "HSTS max-age in seconds") orelse "31536000";

    const mod = b.addModule("yaan", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "yaan",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "yaan", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run yaan");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    const check_step = b.step("check", "Run framework-aware Yaan checks for an app");
    const check_cmd = b.addRunArtifact(exe);
    check_cmd.step.dependOn(b.getInstallStep());
    check_cmd.setCwd(b.path(app_root));
    check_cmd.addArg("check");
    check_step.dependOn(&check_cmd.step);

    const app_build_step = b.step("app-build", "Build a Yaan app into dist");
    const app_build_cmd = b.addRunArtifact(exe);
    app_build_cmd.step.dependOn(b.getInstallStep());
    app_build_cmd.setCwd(b.path(app_root));
    app_build_cmd.addArgs(&.{ "build", "--out", "dist" });
    app_build_step.dependOn(&app_build_cmd.step);

    const dev_step = b.step("dev", "Build and run the Yaan dev server. Use with: zig build dev --watch -fincremental");
    const dev_cmd = b.addRunArtifact(exe);
    dev_cmd.step.dependOn(b.getInstallStep());
    dev_cmd.setCwd(b.path(app_root));
    dev_cmd.addArgs(&.{ "dev", "--host", dev_host, "--port", dev_port });
    if (otel_endpoint) |endpoint| {
        dev_cmd.addArgs(&.{ "--otel-endpoint", endpoint, "--otel-service", otel_service });
    }
    if (prod_errors) dev_cmd.addArg("--prod-errors");
    if (trusted_proxy) |value| dev_cmd.addArgs(&.{ "--trusted-proxy", value });
    if (force_https) dev_cmd.addArg("--force-https");
    if (hsts) dev_cmd.addArg("--hsts");
    dev_cmd.addArgs(&.{ "--hsts-max-age", hsts_max_age });
    dev_step.dependOn(&dev_cmd.step);

    const lib_tests = b.addTest(.{ .root_module = mod });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
