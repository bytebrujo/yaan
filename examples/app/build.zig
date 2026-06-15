const std = @import("std");

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
}
