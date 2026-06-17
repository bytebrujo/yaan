const std = @import("std");
const yaan = @import("yaan");

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
    const csrf = b.option(bool, "csrf", "Enable CSRF validation for action POSTs") orelse false;
    const cookie_secret = b.option([]const u8, "cookie-secret", "Cookie signing secret override");
    const max_body = b.option([]const u8, "max-body", "Maximum request body bytes");
    const max_upload_file = b.option([]const u8, "max-upload-file", "Maximum upload file bytes");
    const max_upload_count = b.option([]const u8, "max-upload-count", "Maximum uploaded file count");
    const max_form_fields = b.option([]const u8, "max-form-fields", "Maximum accumulated form field bytes");
    const max_multipart_header = b.option([]const u8, "max-multipart-header", "Maximum multipart part header bytes");
    const max_headers = b.option([]const u8, "max-headers", "Maximum HTTP header bytes");
    const read_timeout_ms = b.option([]const u8, "read-timeout-ms", "Request read timeout in milliseconds");

    // The framework is a dependency: its `yaan` module, the `yaan` CLI, and the
    // in-process server builder all come from it.
    const yaan_dep = b.dependency("yaan", .{ .target = target, .optimize = optimize });
    const yaan_mod = yaan_dep.module("yaan");
    const yaan_exe = yaan_dep.artifact("yaan");

    const check_step = b.step("check", "Run framework-aware Yaan checks");
    const check_cmd = b.addRunArtifact(yaan_exe);
    check_cmd.addArg("check");
    check_step.dependOn(&check_cmd.step);

    const app_build_step = b.step("build-app", "Build the Yaan app into dist");
    const app_build_cmd = b.addRunArtifact(yaan_exe);
    app_build_cmd.addArgs(&.{ "build", "--out", "dist" });
    app_build_step.dependOn(&app_build_cmd.step);
    b.getInstallStep().dependOn(&app_build_cmd.step);

    const app_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/app_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "yaan", .module = yaan_mod }},
        }),
    });
    const run_app_tests = b.addRunArtifact(app_tests);
    run_app_tests.step.dependOn(&app_build_cmd.step);
    const test_step = b.step("test", "Run app tests through the in-process Yaan harness");
    test_step.dependOn(&run_app_tests.step);

    const dev_step = b.step("dev", "Build and run the Yaan dev server (subprocess runners)");
    const dev_cmd = b.addRunArtifact(yaan_exe);
    dev_cmd.addArgs(&.{ "dev", "--host", dev_host, "--port", dev_port });
    if (otel_endpoint) |endpoint| {
        dev_cmd.addArgs(&.{ "--otel-endpoint", endpoint, "--otel-service", otel_service });
    }
    if (prod_errors) dev_cmd.addArg("--prod-errors");
    if (trusted_proxy) |value| dev_cmd.addArgs(&.{ "--trusted-proxy", value });
    if (force_https) dev_cmd.addArg("--force-https");
    if (hsts) dev_cmd.addArg("--hsts");
    dev_cmd.addArgs(&.{ "--hsts-max-age", hsts_max_age });
    if (csrf) dev_cmd.addArg("--csrf");
    if (cookie_secret) |value| dev_cmd.addArgs(&.{ "--cookie-secret", value });
    if (max_body) |value| dev_cmd.addArgs(&.{ "--max-body", value });
    if (max_upload_file) |value| dev_cmd.addArgs(&.{ "--max-upload-file", value });
    if (max_upload_count) |value| dev_cmd.addArgs(&.{ "--max-upload-count", value });
    if (max_form_fields) |value| dev_cmd.addArgs(&.{ "--max-form-fields", value });
    if (max_multipart_header) |value| dev_cmd.addArgs(&.{ "--max-multipart-header", value });
    if (max_headers) |value| dev_cmd.addArgs(&.{ "--max-headers", value });
    if (read_timeout_ms) |value| dev_cmd.addArgs(&.{ "--read-timeout-ms", value });
    dev_step.dependOn(&dev_cmd.step);

    // In-process server: handlers linked into the binary, no runner subprocesses.
    // The whole module graph is discovered and wired by the framework.
    const app_server = yaan.addInProcessServer(b, .{
        .target = target,
        .optimize = optimize,
        .yaan_dep = yaan_dep,
        .app_build_step = &app_build_cmd.step,
    });
    const dev_inproc_step = b.step("dev-inproc", "Run the in-process server (handlers linked in, no runner subprocesses)");
    const dev_inproc_cmd = b.addRunArtifact(app_server);
    dev_inproc_cmd.addArgs(&.{ "--host", dev_host, "--port", dev_port });
    if (trusted_proxy) |value| dev_inproc_cmd.addArgs(&.{ "--trusted-proxy", value });
    if (force_https) dev_inproc_cmd.addArg("--force-https");
    if (hsts) dev_inproc_cmd.addArg("--hsts");
    dev_inproc_cmd.addArgs(&.{ "--hsts-max-age", hsts_max_age });
    if (csrf) dev_inproc_cmd.addArg("--csrf");
    if (cookie_secret) |value| dev_inproc_cmd.addArgs(&.{ "--cookie-secret", value });
    if (max_body) |value| dev_inproc_cmd.addArgs(&.{ "--max-body", value });
    if (max_upload_file) |value| dev_inproc_cmd.addArgs(&.{ "--max-upload-file", value });
    if (max_upload_count) |value| dev_inproc_cmd.addArgs(&.{ "--max-upload-count", value });
    if (max_form_fields) |value| dev_inproc_cmd.addArgs(&.{ "--max-form-fields", value });
    if (max_multipart_header) |value| dev_inproc_cmd.addArgs(&.{ "--max-multipart-header", value });
    if (max_headers) |value| dev_inproc_cmd.addArgs(&.{ "--max-headers", value });
    if (read_timeout_ms) |value| dev_inproc_cmd.addArgs(&.{ "--read-timeout-ms", value });
    // The in-process binary is production-safe by default; opt into verbose
    // error pages for local dev unless -Dprod-errors was requested.
    if (!prod_errors) dev_inproc_cmd.addArg("--debug-errors");
    dev_inproc_step.dependOn(&dev_inproc_cmd.step);
}
