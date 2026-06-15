const std = @import("std");
const database = @import("database.zig");
const server = @import("server.zig");

pub const TestApp = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    options: server.StaticServerOptions,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, options: server.StaticServerOptions) TestApp {
        return .{
            .io = io,
            .allocator = allocator,
            .options = options,
        };
    }

    pub fn request(self: TestApp, request_value: server.TestRequest) !server.TestResponse {
        return server.testRequest(self.io, self.allocator, self.options, request_value);
    }

    pub fn get(self: TestApp, target: []const u8) !server.TestResponse {
        return self.request(.{ .method = "GET", .target = target });
    }

    pub fn post(self: TestApp, target: []const u8, body: []const u8, content_type: []const u8) !server.TestResponse {
        const headers = [_]server.Header{.{ .name = "content-type", .value = content_type }};
        return self.request(.{
            .method = "POST",
            .target = target,
            .headers = &headers,
            .body = body,
        });
    }
};

pub fn connCase(io: std.Io, allocator: std.mem.Allocator, options: server.StaticServerOptions) TestApp {
    return TestApp.init(io, allocator, options);
}

pub fn memoryDatabase(allocator: std.mem.Allocator) database.Memory {
    return database.Memory.init(allocator);
}

test "test app exposes in-process request helper" {
    const app = connCase(std.testing.io, std.testing.allocator, .{ .root = "does-not-exist" });
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
