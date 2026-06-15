const std = @import("std");
const yaan = @import("yaan");

test "home page renders through in-process app request" {
    const app = yaan.testing.connCase(std.testing.io, std.testing.allocator, .{ .root = "dist" });
    var response = try app.get("/");
    defer response.deinit(std.testing.allocator);

    try response.expectStatus(200);
    try std.testing.expectEqualStrings("text/html; charset=utf-8", response.content_type);
    try response.expectBodyContains("<!doctype html>");
}

test "missing asset returns negotiated JSON error without a socket" {
    const app = yaan.testing.connCase(std.testing.io, std.testing.allocator, .{ .root = "dist" });
    var response = try app.request(.{
        .method = "GET",
        .target = "/assets/missing.svg",
        .headers = &.{.{ .name = "accept", .value = "application/json" }},
    });
    defer response.deinit(std.testing.allocator);

    try response.expectStatus(404);
    try std.testing.expectEqualStrings("application/json; charset=utf-8", response.content_type);
    try response.expectBodyContains("Asset not found");
}
