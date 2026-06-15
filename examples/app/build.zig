const std = @import("std");

// --- route discovery for the in-process server build ----------------------
// Derives the same module names the framework's runner generators emit
// (load_<routeName>, action_<routeName>, remote_<remoteName>) so the wiring
// scales to any app without a hardcoded route list.

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

/// Strips `[`, `]`, a leading `...`, and a `:type` suffix from a route segment.
fn segmentName(part: []const u8) []const u8 {
    var s = part;
    if (s.len >= 2 and s[0] == '[' and s[s.len - 1] == ']') s = s[1 .. s.len - 1];
    if (std.mem.startsWith(u8, s, "...")) s = s[3..];
    if (std.mem.indexOfScalar(u8, s, ':')) |i| s = s[0..i];
    return s;
}

/// Mirrors router.buildRouteName: snake-cased segments joined by '_', pathless
/// (group) segments skipped, the root → "home".
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

/// Walks `base` for files named `basename`, creating one module per match named
/// `prefix ++ "_" ++ routeName(dir)`, and appends them to `imports`.
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

/// Like discoverHandlers but for remotes: name = file basename without
/// ".remote.zig", module named `remote_<name>`.
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
    const dev_host = b.option([]const u8, "host", "Dev server host") orelse "127.0.0.1";
    const dev_port = b.option([]const u8, "port", "Dev server port") orelse "5173";
    const otel_endpoint = b.option([]const u8, "otel-endpoint", "Enable OTLP tracing to this endpoint");
    const otel_service = b.option([]const u8, "otel-service", "OTLP service name") orelse "yaan-dev";
    const prod_errors = b.option(bool, "prod-errors", "Render production-safe error pages in dev") orelse false;
    const trusted_proxy = b.option([]const u8, "trusted-proxy", "Comma-separated trusted proxy IPs for X-Forwarded-* headers");
    const force_https = b.option(bool, "force-https", "Redirect insecure requests to HTTPS") orelse false;
    const hsts = b.option(bool, "hsts", "Emit Strict-Transport-Security on secure requests") orelse false;
    const hsts_max_age = b.option([]const u8, "hsts-max-age", "HSTS max-age in seconds") orelse "31536000";

    const yaan_mod = b.addModule("yaan", .{
        .root_source_file = b.path("../../src/root.zig"),
        .target = target,
    });

    const yaan = b.addExecutable(.{
        .name = "yaan",
        .root_module = b.createModule(.{
            .root_source_file = b.path("../../src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "yaan", .module = yaan_mod },
            },
        }),
    });

    const check_step = b.step("check", "Run framework-aware Yaan checks");
    const check_cmd = b.addRunArtifact(yaan);
    check_cmd.addArg("check");
    check_step.dependOn(&check_cmd.step);

    const app_build_step = b.step("build-app", "Build the Yaan app into dist");
    const app_build_cmd = b.addRunArtifact(yaan);
    app_build_cmd.addArgs(&.{ "build", "--out", "dist" });
    app_build_step.dependOn(&app_build_cmd.step);
    b.getInstallStep().dependOn(&app_build_cmd.step);

    const app_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/app_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "yaan", .module = yaan_mod },
            },
        }),
    });
    const run_app_tests = b.addRunArtifact(app_tests);
    run_app_tests.step.dependOn(&app_build_cmd.step);
    const test_step = b.step("test", "Run app tests through the in-process Yaan harness");
    test_step.dependOn(&run_app_tests.step);

    const dev_step = b.step("dev", "Build and run the Yaan dev server. Use with: zig build dev --watch -fincremental");
    const dev_cmd = b.addRunArtifact(yaan);
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

    // --- in-process server: links the user's hooks into the binary so the
    //     hook runs in-process instead of via the hook_runner subprocess. ---
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
    // Shared route runtime modules (one instance each so types unify).
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
    // Per-route handler modules, discovered from the filesystem (the build-fork
    // analog of the runner's -Mload_<name>=..., -Maction_<name>=..., etc.).
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
        .name = "yaan-app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("../../src/app_server.zig"),
            .target = target,
            .optimize = optimize,
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
    app_server.step.dependOn(&app_build_cmd.step);

    const dev_inproc_step = b.step("dev-inproc", "Run the in-process server (hooks linked in, no hook_runner subprocess)");
    const dev_inproc_cmd = b.addRunArtifact(app_server);
    dev_inproc_cmd.addArgs(&.{ "--host", dev_host, "--port", dev_port });
    dev_inproc_step.dependOn(&dev_inproc_cmd.step);
}
