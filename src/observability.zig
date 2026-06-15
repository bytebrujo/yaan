const std = @import("std");

pub const Config = struct {
    enabled: bool = false,
    service_name: []const u8 = "yaan-dev",
    endpoint: []const u8 = "http://127.0.0.1:4318/v1/traces",
};

pub const Attribute = struct {
    key: []const u8,
    value: Value,

    pub const Value = union(enum) {
        string: []const u8,
        int: i64,
        bool: bool,
    };
};

const Span = struct {
    name: []const u8,
    trace_id: [16]u8,
    span_id: [8]u8,
    parent_span_id: ?[8]u8,
    start_ns: u64,
    end_ns: u64 = 0,
    attributes: std.ArrayList(Attribute) = .empty,
};

pub const SpanRef = struct {
    index: usize,
};

pub const Context = struct {
    root: ?SpanRef = null,
    current: ?SpanRef = null,
};

pub const Tracer = struct {
    allocator: std.mem.Allocator,
    config: Config,
    spans: std.ArrayList(Span) = .empty,
    random: std.Random.DefaultPrng,

    pub fn init(allocator: std.mem.Allocator, config: Config) Tracer {
        return .{
            .allocator = allocator,
            .config = config,
            .random = std.Random.DefaultPrng.init(if (config.enabled) nowNs() else 0),
        };
    }

    pub fn deinit(self: *Tracer) void {
        for (self.spans.items) |*span| span.attributes.deinit(self.allocator);
        self.spans.deinit(self.allocator);
    }

    pub fn startRoot(self: *Tracer, name: []const u8) !Context {
        if (!self.config.enabled) return .{};
        var trace_id: [16]u8 = undefined;
        self.random.random().bytes(&trace_id);
        var span_id: [8]u8 = undefined;
        self.random.random().bytes(&span_id);
        const index = self.spans.items.len;
        try self.spans.append(self.allocator, .{
            .name = name,
            .trace_id = trace_id,
            .span_id = span_id,
            .parent_span_id = null,
            .start_ns = nowNs(),
        });
        const span_ref: SpanRef = .{ .index = index };
        return .{ .root = span_ref, .current = span_ref };
    }

    pub fn startChild(self: *Tracer, context: *Context, name: []const u8) !SpanRef {
        if (!self.config.enabled) return .{ .index = 0 };
        const parent = context.current orelse context.root orelse return .{ .index = 0 };
        const parent_span = self.spans.items[parent.index];
        var span_id: [8]u8 = undefined;
        self.random.random().bytes(&span_id);
        const index = self.spans.items.len;
        try self.spans.append(self.allocator, .{
            .name = name,
            .trace_id = parent_span.trace_id,
            .span_id = span_id,
            .parent_span_id = parent_span.span_id,
            .start_ns = nowNs(),
        });
        context.current = .{ .index = index };
        return .{ .index = index };
    }

    pub fn endSpan(self: *Tracer, context: *Context, span_ref: SpanRef) void {
        if (!self.config.enabled) return;
        if (span_ref.index >= self.spans.items.len) return;
        self.spans.items[span_ref.index].end_ns = nowNs();
        if (self.spans.items[span_ref.index].parent_span_id != null) {
            context.current = context.root;
        }
    }

    pub fn setAttribute(self: *Tracer, span_ref: ?SpanRef, key: []const u8, value: Attribute.Value) !void {
        if (!self.config.enabled) return;
        const ref = span_ref orelse return;
        if (ref.index >= self.spans.items.len) return;
        try self.spans.items[ref.index].attributes.append(self.allocator, .{ .key = key, .value = value });
    }

    pub fn finishRoot(self: *Tracer, context: *Context) void {
        if (!self.config.enabled) return;
        if (context.root) |root| {
            if (root.index < self.spans.items.len and self.spans.items[root.index].end_ns == 0) {
                self.spans.items[root.index].end_ns = nowNs();
            }
        }
    }

    pub fn exportSpans(self: *Tracer, io: std.Io) !void {
        if (!self.config.enabled or self.spans.items.len == 0) return;
        const body = try self.otlpJson();
        defer self.allocator.free(body);

        var client = std.http.Client{ .allocator = self.allocator, .io = io };
        defer client.deinit();
        const result = client.fetch(.{
            .location = .{ .url = self.config.endpoint },
            .method = .POST,
            .payload = body,
            .headers = .{ .content_type = .{ .override = "application/json" } },
        }) catch |err| {
            std.debug.print("otel export failed: {t}\n", .{err});
            return;
        };
        if (@intFromEnum(result.status) >= 300) {
            std.debug.print("otel export returned status {d}\n", .{@intFromEnum(result.status)});
        }
    }

    fn otlpJson(self: *Tracer) ![]u8 {
        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer writer.deinit();
        try writer.writer.writeAll("{\"resourceSpans\":[{\"resource\":{\"attributes\":[");
        try writeJsonAttribute(&writer.writer, "service.name", .{ .string = self.config.service_name });
        try writer.writer.writeAll("]},\"scopeSpans\":[{\"scope\":{\"name\":\"yaan\"},\"spans\":[");
        for (self.spans.items, 0..) |span, i| {
            if (i > 0) try writer.writer.writeAll(",");
            try writer.writer.writeAll("{\"traceId\":\"");
            try writeHex(&writer.writer, &span.trace_id);
            try writer.writer.writeAll("\",\"spanId\":\"");
            try writeHex(&writer.writer, &span.span_id);
            try writer.writer.writeAll("\",");
            if (span.parent_span_id) |parent| {
                try writer.writer.writeAll("\"parentSpanId\":\"");
                try writeHex(&writer.writer, &parent);
                try writer.writer.writeAll("\",");
            }
            try writer.writer.writeAll("\"name\":");
            try std.json.Stringify.value(span.name, .{}, &writer.writer);
            try writer.writer.print(",\"kind\":2,\"startTimeUnixNano\":\"{d}\",\"endTimeUnixNano\":\"{d}\",\"attributes\":[", .{
                span.start_ns,
                if (span.end_ns == 0) nowNs() else span.end_ns,
            });
            for (span.attributes.items, 0..) |attribute, attr_i| {
                if (attr_i > 0) try writer.writer.writeAll(",");
                try writeJsonAttribute(&writer.writer, attribute.key, attribute.value);
            }
            try writer.writer.writeAll("]}");
        }
        try writer.writer.writeAll("]}]}]}]}");
        return self.allocator.dupe(u8, writer.written());
    }
};

pub fn Tracing(comptime enabled: bool) type {
    return if (enabled) struct {
        root: ?SpanRef = null,
        current: ?SpanRef = null,

        pub fn setAttribute(self: *@This(), key: []const u8, value: Attribute.Value) void {
            _ = self;
            _ = key;
            _ = value;
        }
    } else struct {
        pub fn setAttribute(self: *@This(), key: []const u8, value: Attribute.Value) void {
            _ = self;
            _ = key;
            _ = value;
        }
    };
}

fn nowNs() u64 {
    var tv: std.c.timeval = undefined;
    if (std.c.gettimeofday(&tv, null) == 0) {
        const seconds: u64 = @intCast(tv.sec);
        const micros: u64 = @intCast(tv.usec);
        return seconds * std.time.ns_per_s + micros * std.time.ns_per_us;
    }
    return 1;
}

fn writeJsonAttribute(writer: *std.Io.Writer, key: []const u8, value: Attribute.Value) !void {
    try writer.writeAll("{\"key\":");
    try std.json.Stringify.value(key, .{}, writer);
    try writer.writeAll(",\"value\":{");
    switch (value) {
        .string => |string| {
            try writer.writeAll("\"stringValue\":");
            try std.json.Stringify.value(string, .{}, writer);
        },
        .int => |int| try writer.print("\"intValue\":\"{d}\"", .{int}),
        .bool => |boolean| try writer.print("\"boolValue\":{}", .{boolean}),
    }
    try writer.writeAll("}}");
}

fn writeHex(writer: *std.Io.Writer, bytes: []const u8) !void {
    const alphabet = "0123456789abcdef";
    for (bytes) |byte| {
        try writer.writeByte(alphabet[byte >> 4]);
        try writer.writeByte(alphabet[byte & 0x0f]);
    }
}

test "tracer emits OTLP JSON shape" {
    var tracer = Tracer.init(std.testing.allocator, .{ .enabled = true, .service_name = "test" });
    defer tracer.deinit();
    var ctx = try tracer.startRoot("GET /");
    try tracer.setAttribute(ctx.current, "http.request.method", .{ .string = "GET" });
    tracer.finishRoot(&ctx);
    const json = try tracer.otlpJson();
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"resourceSpans\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"service.name\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"http.request.method\"") != null);
}
