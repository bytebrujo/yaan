const std = @import("std");
const observability = @import("observability.zig");
const pipeline = @import("pipeline.zig");

var upload_counter: usize = 0;

pub const StaticServerOptions = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 5173,
    /// Prefix for the startup log line (e.g. "yaan dev" vs "yaan").
    label: []const u8 = "yaan dev",
    root: []const u8 = "dist",
    hook_runner: []const u8 = ".yaan/hook_runner",
    /// In-process hook seam. When set, the request runs this composable layer
    /// chain instead of spawning the hook_runner subprocess. The framework
    /// installs `frameworkHook` here for the dev server; tests can inject their
    /// own. Null preserves the legacy subprocess path.
    hook: ?Hook = null,
    /// In-process load/action/remote handlers. When set, the request runs them
    /// linked into the server instead of spawning the matching runner subprocess.
    load: ?LoadFn = null,
    action: ?ActionFn = null,
    remote: ?RemoteFn = null,
    load_runner: []const u8 = ".yaan/load_runner",
    action_runner: []const u8 = ".yaan/action_runner",
    remote_runner: []const u8 = ".yaan/remote_runner",
    observability: observability.Config = .{},
    debug_errors: bool = true,
    max_body_length: usize = 8 * 1024 * 1024,
    max_upload_file_length: usize = 8 * 1024 * 1024,
    max_upload_count: usize = 16,
    max_form_fields_length: usize = 1024 * 1024,
    max_multipart_header_length: usize = 16 * 1024,
    max_header_length: usize = 32 * 1024,
    read_timeout_ms: u32 = 10_000,
    trusted_proxies: []const []const u8 = &.{},
    force_https: bool = false,
    hsts: bool = false,
    hsts_max_age: u32 = 31_536_000,
    security_headers: bool = true,
    cookie_secret: []const u8 = "",
    csrf_protection: bool = false,
    // Yaan emits zero inline scripts, so script-src stays strict 'self' with no
    // unsafe-inline. Inline style attributes (style="...") in components are
    // permitted via style-src 'unsafe-inline'.
    csp: []const u8 = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; base-uri 'self'; form-action 'self'; object-src 'none'; frame-ancestors 'none'",
};

/// Appends baseline security headers shared by every response on both the
/// streaming and TestResponse paths. Values are static, so callers do not free.
fn appendSecurityHeaders(allocator: std.mem.Allocator, list: *std.ArrayList(Header), options: StaticServerOptions) !void {
    if (!options.security_headers) return;
    try list.append(allocator, .{ .name = "x-content-type-options", .value = "nosniff" });
    try list.append(allocator, .{ .name = "referrer-policy", .value = "strict-origin-when-cross-origin" });
    if (options.csp.len > 0) try list.append(allocator, .{ .name = "content-security-policy", .value = options.csp });
}

/// Responses below this size are not worth compressing (header + CPU overhead
/// outweighs the savings, and gzip can even grow tiny payloads).
const compression_threshold = 1024;

fn isCompressible(mime: []const u8) bool {
    if (std.mem.startsWith(u8, mime, "text/")) return true;
    if (std.mem.indexOf(u8, mime, "json") != null) return true;
    if (std.mem.indexOf(u8, mime, "javascript") != null) return true;
    if (std.mem.indexOf(u8, mime, "xml") != null) return true;
    if (std.mem.indexOf(u8, mime, "svg") != null) return true;
    return false;
}

fn acceptsGzip(accept_encoding: []const u8) bool {
    // Good enough for "gzip", "gzip, deflate, br", "*", etc. without q-value parsing.
    return std.mem.indexOf(u8, accept_encoding, "gzip") != null or
        std.mem.indexOf(u8, accept_encoding, "*") != null;
}

fn gzipCompress(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var sink: std.Io.Writer.Allocating = try .initCapacity(allocator, input.len + 64);
    defer sink.deinit();
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var compress = try std.compress.flate.Compress.init(&sink.writer, &window, .gzip, .default);
    try compress.writer.writeAll(input);
    try compress.finish();
    return allocator.dupe(u8, sink.written());
}

const Encoded = struct {
    body: []u8,
    encoding: ?[]const u8,
};

/// Returns the response body, gzip-encoded when the client accepts it and the
/// payload is a compressible type above the size threshold. The returned body
/// is always a fresh allocation the caller owns.
fn encodeBody(allocator: std.mem.Allocator, accept_encoding: []const u8, mime: []const u8, body: []const u8) !Encoded {
    if (body.len >= compression_threshold and isCompressible(mime) and acceptsGzip(accept_encoding)) {
        const compressed = gzipCompress(allocator, body) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return .{ .body = try allocator.dupe(u8, body), .encoding = null },
        };
        // Never serve a "compressed" body that ended up larger.
        if (compressed.len < body.len) return .{ .body = compressed, .encoding = "gzip" };
        allocator.free(compressed);
    }
    return .{ .body = try allocator.dupe(u8, body), .encoding = null };
}

pub fn serve(io: std.Io, allocator: std.mem.Allocator, options: StaticServerOptions) !void {
    var address = try std.Io.net.IpAddress.parse(options.host, options.port);
    if (options.observability.enabled) {
        std.debug.print("yaan tracing enabled: service={s} endpoint={s}\n", .{ options.observability.service_name, options.observability.endpoint });
    }
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    std.debug.print("{s} listening on http://{s}:{d}\n", .{ options.label, options.host, options.port });

    while (true) {
        var stream = try listener.accept(io);
        defer stream.close(io);
        handleConnection(io, allocator, stream, options.root, options.hook_runner, options.load_runner, options.action_runner, options.remote_runner, options.observability, options.debug_errors, options.max_body_length, options) catch |err| {
            std.debug.print("request failed: {t}\n", .{err});
            writeRenderedError(io, allocator, stream, options.root, 500, "", .{
                .message = "Internal Error",
                .code = "internal_error",
            }, &.{}, null, options.debug_errors) catch {};
        };
    }
}

pub fn describe(options: StaticServerOptions, allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "http://{s}:{d} serving {s}", .{ options.host, options.port, options.root });
}

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const TestRequest = struct {
    method: []const u8 = "GET",
    target: []const u8 = "/",
    headers: []const Header = &.{},
    body: []const u8 = "",
    peer: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 0 } },
};

pub const TestResponse = struct {
    status: u16,
    content_type: []u8,
    headers: []Header,
    body: []u8,
    location: ?[]u8 = null,

    pub fn deinit(self: *TestResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.content_type);
        for (self.headers) |item| {
            allocator.free(item.name);
            allocator.free(item.value);
        }
        allocator.free(self.headers);
        allocator.free(self.body);
        if (self.location) |location| allocator.free(location);
        self.* = undefined;
    }

    pub fn header(self: TestResponse, name: []const u8) ?[]const u8 {
        for (self.headers) |item| {
            if (std.ascii.eqlIgnoreCase(item.name, name)) return item.value;
        }
        return null;
    }

    pub fn expectStatus(self: TestResponse, expected: u16) !void {
        try std.testing.expectEqual(expected, self.status);
    }

    pub fn expectBodyContains(self: TestResponse, needle: []const u8) !void {
        try std.testing.expect(std.mem.indexOf(u8, self.body, needle) != null);
    }
};

pub fn testRequest(io: std.Io, allocator: std.mem.Allocator, options: StaticServerOptions, request: TestRequest) !TestResponse {
    const method = request.method;
    const target = request.target;
    const accept = requestHeader(request.headers, "accept") orelse "";
    const accept_encoding = requestHeader(request.headers, "accept-encoding") orelse "";
    const content_type = requestHeader(request.headers, "content-type") orelse "";
    const host = requestHeader(request.headers, "host") orelse "";
    const forwarded_proto = nearestForwardedValue(requestHeader(request.headers, "x-forwarded-proto") orelse "");
    const forwarded_host = nearestForwardedValue(requestHeader(request.headers, "x-forwarded-host") orelse "");
    const forwarded_port = nearestForwardedValue(requestHeader(request.headers, "x-forwarded-port") orelse "");

    const security = try requestSecurity(allocator, request.peer, options.trusted_proxies, host, forwarded_proto, forwarded_host, forwarded_port);
    defer if (security.host.ptr != host.ptr) allocator.free(security.host);
    if (options.force_https and !security.secure) {
        const location = try httpsRedirectLocation(allocator, security.host, target);
        defer allocator.free(location);
        return try testResponse(allocator, 308, "text/plain; charset=utf-8", "", &.{}, location);
    }

    var response_headers: std.ArrayList(Header) = .empty;
    defer response_headers.deinit(allocator);
    try appendSecurityHeaders(allocator, &response_headers, options);
    const hsts_value = if (options.hsts and security.secure)
        try std.fmt.allocPrint(allocator, "max-age={d}", .{options.hsts_max_age})
    else
        null;
    defer if (hsts_value) |value| allocator.free(value);
    if (hsts_value) |value| try response_headers.append(allocator, .{ .name = "strict-transport-security", .value = value });

    if (request.body.len > options.max_body_length) {
        return try testRenderedError(io, allocator, options.root, 413, accept, .{
            .message = "Request body is too large",
            .code = "payload_too_large",
        }, response_headers.items, null, options.debug_errors);
    }

    const headers_json = try headersJson(allocator, request.headers);
    defer allocator.free(headers_json);
    const meta_json = try metaJson(allocator, .{
        .secure = security.secure,
        .csrf_protection = options.csrf_protection and options.cookie_secret.len > 0,
        .cookie_secret = options.cookie_secret,
    });
    defer allocator.free(meta_json);

    var path = sanitizePath(target);
    // Decision data must outlive the routing/static phases below (response
    // headers reference it), so these live at function scope.
    var hook_decision: ?HookDecision = null;
    defer if (hook_decision) |d| d.deinit(allocator);
    var hook_json: ?[]u8 = null;
    defer if (hook_json) |json| allocator.free(json);
    var hook_result: ?std.json.Parsed(HookRunnerResult) = null;
    defer if (hook_result) |*result| result.deinit();

    if (options.hook) |hook| {
        hook_decision = try hook(io, allocator, options.hook_runner, .{ .method = method, .target = target, .path = path, .body = request.body });
        switch (hook_decision.?) {
            .halt => |h| return try testMaybeRenderedResponse(io, allocator, options.root, accept, .{
                .__yaan_response = true,
                .status = h.status,
                .content_type = h.content_type,
                .location = h.location,
                .headers = h.headers,
                .body = h.body,
            }, response_headers.items, options.debug_errors),
            .continue_ => |c| {
                if (c.path) |rewritten| path = sanitizePath(rewritten);
                try response_headers.appendSlice(allocator, c.headers);
            },
        }
    } else {
        hook_json = runHookRunner(io, allocator, options.hook_runner, method, target, path, request.body) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        hook_result = if (hook_json) |json| try std.json.parseFromSlice(HookRunnerResult, allocator, json, .{}) else null;
        if (hook_result) |result| {
            if (std.mem.eql(u8, result.value.action, "halt")) {
                return try testMaybeRenderedResponse(io, allocator, options.root, accept, .{
                    .__yaan_response = true,
                    .status = result.value.status,
                    .content_type = result.value.content_type,
                    .location = result.value.location,
                    .headers = result.value.headers,
                    .body = result.value.body,
                }, response_headers.items, options.debug_errors);
            }
            if (!std.mem.eql(u8, result.value.action, "continue")) return error.InvalidHookResult;
            if (result.value.path) |rewritten| path = sanitizePath(rewritten);
            try response_headers.appendSlice(allocator, result.value.headers);
        }
    }

    if (std.mem.eql(u8, method, "POST")) {
        if (std.mem.eql(u8, path, "/_yaan/remote")) {
            const data = if (options.remote) |f|
                try f(io, allocator, method, path, request.body)
            else
                runRemoteRunner(io, allocator, options.remote_runner, method, path, request.body) catch |err| switch (err) {
                    error.FileNotFound => try allocator.dupe(u8, "{\"error\":\"no_remote_runner\"}"),
                    else => return err,
                };
            defer allocator.free(data);
            return try testRunnerOutput(io, allocator, options.root, accept, data, response_headers.items, options.debug_errors);
        }

        var multipart_data: ?MultipartData = null;
        defer if (multipart_data) |*data| data.deinit(io, allocator);
        const action_body = if (multipartBoundary(content_type)) |boundary| body: {
            multipart_data = parseMultipart(io, allocator, request.body, boundary, options) catch |err| switch (err) {
                error.PayloadTooLarge => return try testRenderedError(io, allocator, options.root, 413, accept, .{
                    .message = "Upload is too large",
                    .code = "payload_too_large",
                }, response_headers.items, null, options.debug_errors),
                error.MalformedMultipart => return try testRenderedError(io, allocator, options.root, 400, accept, .{
                    .message = "Malformed multipart body",
                    .code = "bad_multipart",
                }, response_headers.items, null, options.debug_errors),
                else => return err,
            };
            break :body multipart_data.?.fields_body;
        } else request.body;
        const uploads_json = if (multipart_data) |data|
            try uploadsJson(allocator, data.uploads)
        else
            try allocator.dupe(u8, "[]");
        defer allocator.free(uploads_json);

        if (options.csrf_protection and options.cookie_secret.len > 0 and !validCsrfForRequest(allocator, request.headers, action_body, options.cookie_secret)) {
            return try testRenderedError(io, allocator, options.root, 403, accept, .{
                .message = "Invalid CSRF token",
                .code = "csrf_invalid",
            }, response_headers.items, null, options.debug_errors);
        }

        const data = if (options.action) |f|
            try f(io, allocator, method, path, action_body, uploads_json, headers_json, meta_json)
        else
            runActionRunner(io, allocator, options.action_runner, method, path, action_body, uploads_json, headers_json, meta_json) catch |err| switch (err) {
                error.FileNotFound => try allocator.dupe(u8, "{\"error\":\"no_action\"}"),
                else => return err,
            };
        defer allocator.free(data);
        return try testRunnerOutput(io, allocator, options.root, accept, data, response_headers.items, options.debug_errors);
    }

    if (!std.mem.eql(u8, method, "GET") and !std.mem.eql(u8, method, "HEAD")) {
        return try testRenderedError(io, allocator, options.root, 405, accept, .{
            .message = "Method Not Allowed",
            .code = "method_not_allowed",
        }, response_headers.items, null, options.debug_errors);
    }

    if (std.mem.startsWith(u8, path, "/_yaan/load")) {
        const load_path = (try queryValue(allocator, target, "path")) orelse try allocator.dupe(u8, "/");
        defer allocator.free(load_path);
        const data = if (options.load) |f|
            try f(io, allocator, method, load_path, headers_json, meta_json)
        else
            runLoadRunner(io, allocator, options.load_runner, method, load_path, headers_json, meta_json) catch |err| switch (err) {
                error.FileNotFound => try allocator.dupe(u8, "null"),
                else => return err,
            };
        defer allocator.free(data);
        return try testRunnerOutput(io, allocator, options.root, accept, data, response_headers.items, options.debug_errors);
    }

    const doc_override = if (isNavigableHtml(method, accept, path))
        try matchPrerenderFile(io, allocator, options.root, path)
    else
        null;
    defer if (doc_override) |d| allocator.free(d);
    const read_path = doc_override orelse path;
    const body = readAsset(io, allocator, options.root, read_path) catch |err| switch (err) {
        error.FileNotFound => fallback: {
            if (std.mem.startsWith(u8, path, "/assets/")) {
                return try testRenderedError(io, allocator, options.root, 404, accept, .{
                    .message = "Asset not found",
                    .code = "not_found",
                }, response_headers.items, null, options.debug_errors);
            }
            break :fallback try readAsset(io, allocator, options.root, "/index.html");
        },
        else => return err,
    };
    defer allocator.free(body);
    const mime = mimeType(read_path);
    const encoded = try encodeBody(allocator, accept_encoding, mime, body);
    defer allocator.free(encoded.body);
    var asset_headers: std.ArrayList(Header) = .empty;
    defer asset_headers.deinit(allocator);
    try asset_headers.appendSlice(allocator, response_headers.items);
    if (std.mem.startsWith(u8, path, "/assets/")) {
        try asset_headers.append(allocator, .{ .name = "cache-control", .value = "public, max-age=31536000, immutable" });
    }
    if (encoded.encoding) |encoding| {
        try asset_headers.append(allocator, .{ .name = "content-encoding", .value = encoding });
        try asset_headers.append(allocator, .{ .name = "vary", .value = "accept-encoding" });
    }
    const response_body = if (std.mem.eql(u8, method, "HEAD")) "" else encoded.body;
    return try testResponse(allocator, 200, mime, response_body, asset_headers.items, null);
}

const HookRunnerResult = struct {
    action: []const u8,
    path: ?[]const u8 = null,
    status: u16 = 200,
    content_type: []const u8 = "text/plain; charset=utf-8",
    location: ?[]const u8 = null,
    headers: []const Header = &.{},
    body: []const u8 = "",
};

// --- in-process hook seam (wires src/pipeline.zig into the live request path) ---

/// The slice of the request handed to an in-process hook.
pub const HookRequest = struct {
    method: []const u8,
    target: []const u8,
    path: []const u8,
    body: []const u8,
};

/// The decision an in-process hook returns — the Zig-native equivalent of the
/// JSON the hook_runner subprocess used to emit. All strings are owned by the
/// allocator passed to the hook; the server frees them via `deinit`.
pub const HookDecision = union(enum) {
    continue_: Continue,
    halt: Halt,

    pub const Continue = struct {
        path: ?[]const u8 = null,
        headers: []const Header = &.{},
    };
    pub const Halt = struct {
        status: u16 = 200,
        content_type: []const u8 = "text/plain; charset=utf-8",
        location: ?[]const u8 = null,
        headers: []const Header = &.{},
        body: []const u8 = "",
    };

    pub fn deinit(self: HookDecision, allocator: std.mem.Allocator) void {
        switch (self) {
            .continue_ => |c| {
                if (c.path) |p| allocator.free(p);
                freeHeaders(allocator, c.headers);
            },
            .halt => |h| {
                allocator.free(h.content_type);
                if (h.location) |l| allocator.free(l);
                allocator.free(h.body);
                freeHeaders(allocator, h.headers);
            },
        }
    }
};

pub const Hook = *const fn (io: std.Io, allocator: std.mem.Allocator, hook_runner: []const u8, request: HookRequest) anyerror!HookDecision;

// In-process handler seams. Each returns the same JSON the corresponding runner
// subprocess would have written to stdout, so the downstream rendering is
// unchanged. Null falls back to the subprocess runner.
pub const LoadFn = *const fn (io: std.Io, allocator: std.mem.Allocator, method: []const u8, path: []const u8, headers_json: []const u8, meta_json: []const u8) anyerror![]u8;
pub const ActionFn = *const fn (io: std.Io, allocator: std.mem.Allocator, method: []const u8, path: []const u8, body: []const u8, uploads_json: []const u8, headers_json: []const u8, meta_json: []const u8) anyerror![]u8;
pub const RemoteFn = *const fn (io: std.Io, allocator: std.mem.Allocator, method: []const u8, path: []const u8, body: []const u8) anyerror![]u8;

fn freeHeaders(allocator: std.mem.Allocator, headers: []const Header) void {
    for (headers) |h| {
        allocator.free(h.name);
        allocator.free(h.value);
    }
    allocator.free(headers);
}

fn dupeHeaders(allocator: std.mem.Allocator, headers: []const pipeline.Header) ![]Header {
    const out = try allocator.alloc(Header, headers.len);
    errdefer allocator.free(out);
    for (headers, 0..) |h, i| {
        out[i] = .{ .name = try allocator.dupe(u8, h.name), .value = try allocator.dupe(u8, h.value) };
    }
    return out;
}

// State threaded through the in-process hook chain. `io` and `runner` let the
// terminal layer bridge to the existing subprocess user-hook; `rewrite` carries
// a path rewrite back out.
const HookLocals = struct {
    io: std.Io,
    runner: []const u8,
    target: []const u8,
    body: []const u8,
    rewrite: ?[]const u8 = null,
};

const HookCtx = pipeline.Context(HookLocals);

// A framework layer: stamps every response so it is observable that the
// in-process pipeline ran, and demonstrates post-processing after `next`.
const StampLayer = struct {
    pub fn handle(ctx: *HookCtx, next: anytype) anyerror!pipeline.Outcome {
        const outcome = try next.run(ctx);
        try ctx.response.setHeader("x-yaan-pipeline", "in-process");
        return outcome;
    }
};

// Terminal: bridges to the existing hook_runner subprocess so user hooks keep
// working. This is the seam that a future build that links user code would
// replace with the user's own in-process layers.
const SubprocessHook = struct {
    pub fn handle(ctx: *HookCtx) anyerror!pipeline.Outcome {
        const json = runHookRunner(ctx.locals.io, ctx.allocator, ctx.locals.runner, ctx.request.method, ctx.locals.target, ctx.request.path, ctx.locals.body) catch |err| switch (err) {
            error.FileNotFound => return .done, // no user hook -> proceed
            else => return err,
        };
        const parsed = std.json.parseFromSlice(HookRunnerResult, ctx.allocator, json, .{}) catch return error.InvalidHookResult;
        const result = parsed.value;
        for (result.headers) |h| try ctx.response.setHeader(h.name, h.value);
        if (std.mem.eql(u8, result.action, "halt")) {
            ctx.response.status = result.status;
            ctx.response.content_type = result.content_type;
            ctx.response.location = result.location;
            ctx.response.body = result.body;
            return .halt;
        }
        if (result.path) |p| ctx.locals.rewrite = p;
        return .done;
    }
};

const HookApp = pipeline.Pipeline(HookCtx, .{StampLayer}, SubprocessHook);

/// The framework's in-process hook: runs a comptime-composed layer chain
/// (`StampLayer` → subprocess bridge) and maps the result to a `HookDecision`.
/// Installed on the dev server so real requests flow through the pipeline.
pub fn frameworkHook(io: std.Io, allocator: std.mem.Allocator, hook_runner: []const u8, request: HookRequest) anyerror!HookDecision {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var response = pipeline.Response{ .allocator = a };
    var ctx = HookCtx{
        .allocator = a,
        .request = .{ .method = request.method, .path = request.path, .body = request.body },
        .response = &response,
        .locals = .{ .io = io, .runner = hook_runner, .target = request.target, .body = request.body },
    };
    const outcome = try HookApp.run(&ctx);
    // Copy the result out of the per-request arena into caller-owned memory.
    const headers = try dupeHeaders(allocator, response.headers.items);
    errdefer freeHeaders(allocator, headers);
    if (outcome == .halt) {
        return .{ .halt = .{
            .status = response.status,
            .content_type = try allocator.dupe(u8, response.content_type),
            .location = if (response.location) |l| try allocator.dupe(u8, l) else null,
            .body = try allocator.dupe(u8, response.body),
            .headers = headers,
        } };
    }
    return .{ .continue_ = .{
        .path = if (ctx.locals.rewrite) |p| try allocator.dupe(u8, p) else null,
        .headers = headers,
    } };
}

const RunnerResponse = struct {
    __yaan_response: bool = false,
    status: u16 = 200,
    content_type: []const u8 = "application/json; charset=utf-8",
    location: ?[]const u8 = null,
    headers: []const Header = &.{},
    body: []const u8 = "",
};

const ErrorBody = struct {
    message: []const u8,
    code: []const u8,
    id: []const u8 = "",
};

const RequestSecurity = struct {
    secure: bool,
    host: []const u8,
};

pub const RequestMeta = struct {
    secure: bool = false,
    csrf_protection: bool = false,
    cookie_secret: []const u8 = "",
};

const UploadHandle = struct {
    name: []const u8,
    filename: []const u8,
    content_type: []const u8,
    path: []const u8,
    size: usize,
};

const MultipartData = struct {
    fields_body: []u8,
    uploads: []UploadHandle,

    fn deinit(self: *MultipartData, io: std.Io, allocator: std.mem.Allocator) void {
        deinitUploadHandles(io, allocator, self.uploads);
        allocator.free(self.uploads);
        allocator.free(self.fields_body);
    }
};

fn handleConnection(io: std.Io, allocator: std.mem.Allocator, stream: std.Io.net.Stream, root: []const u8, hook_runner: []const u8, load_runner: []const u8, action_runner: []const u8, remote_runner: []const u8, observability_config: observability.Config, debug_errors: bool, max_body_length: usize, options: StaticServerOptions) !void {
    var read_buffer: [8192]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    const line = reader.interface.takeDelimiterInclusive('\n') catch return;
    var parts = std.mem.tokenizeScalar(u8, std.mem.trim(u8, line, "\r\n"), ' ');
    const method = parts.next() orelse return;
    const target = parts.next() orelse "/";
    var tracer = observability.Tracer.init(allocator, observability_config);
    defer tracer.deinit();
    var trace = try tracer.startRoot("http.request");
    defer {
        tracer.finishRoot(&trace);
        tracer.exportSpans(io) catch {};
    }
    errdefer tracer.setAttribute(trace.root, "yaan.error", .{ .bool = true }) catch {};
    try tracer.setAttribute(trace.root, "http.request.method", .{ .string = method });
    try tracer.setAttribute(trace.root, "url.path", .{ .string = sanitizePath(target) });
    var content_length: usize = 0;
    var accept: []const u8 = "";
    var accept_encoding: []const u8 = "";
    var content_type: []const u8 = "";
    var host: []const u8 = "";
    var forwarded_proto: []const u8 = "";
    var forwarded_host: []const u8 = "";
    var forwarded_port: []const u8 = "";
    var request_headers: std.ArrayList(Header) = .empty;
    defer deinitHeaderList(allocator, &request_headers);
    var header_bytes: usize = line.len;
    while (true) {
        const header_line = reader.interface.takeDelimiterInclusive('\n') catch return;
        header_bytes += header_line.len;
        if (header_bytes > options.max_header_length) {
            try writeResponse(io, stream, "431 Request Header Fields Too Large", "text/plain; charset=utf-8", "Request headers are too large");
            return;
        }
        const header = std.mem.trim(u8, header_line, "\r\n");
        if (header.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, header, ':') orelse continue;
        const header_name = std.mem.trim(u8, header[0..colon], " \t");
        const header_value = std.mem.trim(u8, header[colon + 1 ..], " \t");
        try request_headers.append(allocator, .{
            .name = try allocator.dupe(u8, header_name),
            .value = try allocator.dupe(u8, header_value),
        });
        const stored = request_headers.items[request_headers.items.len - 1].value;
        if (std.ascii.eqlIgnoreCase(header_name, "content-length")) {
            content_length = try std.fmt.parseInt(usize, stored, 10);
        } else if (std.ascii.eqlIgnoreCase(header_name, "accept-encoding")) {
            accept_encoding = stored;
        } else if (std.ascii.eqlIgnoreCase(header_name, "accept")) {
            accept = stored;
        } else if (std.ascii.eqlIgnoreCase(header_name, "content-type")) {
            content_type = stored;
        } else if (std.ascii.eqlIgnoreCase(header_name, "host")) {
            host = stored;
        } else if (std.ascii.eqlIgnoreCase(header_name, "x-forwarded-proto")) {
            forwarded_proto = nearestForwardedValue(stored);
        } else if (std.ascii.eqlIgnoreCase(header_name, "x-forwarded-host")) {
            forwarded_host = nearestForwardedValue(stored);
        } else if (std.ascii.eqlIgnoreCase(header_name, "x-forwarded-port")) {
            forwarded_port = nearestForwardedValue(stored);
        }
    }
    const security = try requestSecurity(allocator, stream.socket.address, options.trusted_proxies, host, forwarded_proto, forwarded_host, forwarded_port);
    defer if (security.host.ptr != host.ptr) allocator.free(security.host);
    if (options.force_https and !security.secure) {
        const location = try httpsRedirectLocation(allocator, security.host, target);
        defer allocator.free(location);
        try writeResponseWithHeaders(io, stream, "308 Permanent Redirect", "text/plain; charset=utf-8", "", &.{}, location);
        return;
    }
    var response_headers_list: std.ArrayList(Header) = .empty;
    defer response_headers_list.deinit(allocator);
    try appendSecurityHeaders(allocator, &response_headers_list, options);
    const hsts_value = if (options.hsts and security.secure)
        try std.fmt.allocPrint(allocator, "max-age={d}", .{options.hsts_max_age})
    else
        null;
    defer if (hsts_value) |value| allocator.free(value);
    if (hsts_value) |value| try response_headers_list.append(allocator, .{ .name = "strict-transport-security", .value = value });
    if (content_length > max_body_length) {
        try writeRenderedError(io, allocator, stream, root, 413, accept, .{
            .message = "Request body is too large",
            .code = "payload_too_large",
        }, response_headers_list.items, null, debug_errors);
        return;
    }
    const request_body = if (content_length > 0) body: {
        const body = try allocator.alloc(u8, content_length);
        errdefer allocator.free(body);
        try reader.interface.readSliceAll(body);
        break :body body;
    } else if (reader.interface.bufferedLen() > 0)
        try allocator.dupe(u8, reader.interface.buffered())
    else
        try allocator.dupe(u8, "");
    defer allocator.free(request_body);

    const headers_json = try headersJson(allocator, request_headers.items);
    defer allocator.free(headers_json);
    const meta_json = try metaJson(allocator, .{
        .secure = security.secure,
        .csrf_protection = options.csrf_protection and options.cookie_secret.len > 0,
        .cookie_secret = options.cookie_secret,
    });
    defer allocator.free(meta_json);

    var path = sanitizePath(target);
    // Decision data must outlive the routing/static phases below.
    var hook_decision: ?HookDecision = null;
    defer if (hook_decision) |d| d.deinit(allocator);
    var hook_json: ?[]u8 = null;
    defer if (hook_json) |json| allocator.free(json);
    var hook_result: ?std.json.Parsed(HookRunnerResult) = null;
    defer if (hook_result) |*result| result.deinit();

    {
        const span = try tracer.startChild(&trace, "yaan.hooks.handle");
        defer tracer.endSpan(&trace, span);
        if (options.hook) |hook| {
            hook_decision = try hook(io, allocator, hook_runner, .{ .method = method, .target = target, .path = path, .body = request_body });
        } else {
            hook_json = runHookRunner(io, allocator, hook_runner, method, target, path, request_body) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return err,
            };
            hook_result = if (hook_json) |json| try std.json.parseFromSlice(HookRunnerResult, allocator, json, .{}) else null;
        }
    }

    if (hook_decision) |decision| {
        switch (decision) {
            .halt => |h| {
                try tracer.setAttribute(trace.root, "http.response.status_code", .{ .int = h.status });
                try writeMaybeRenderedResponse(io, allocator, stream, root, accept, .{
                    .__yaan_response = true,
                    .status = h.status,
                    .content_type = h.content_type,
                    .location = h.location,
                    .headers = h.headers,
                    .body = h.body,
                }, response_headers_list.items, debug_errors);
                return;
            },
            .continue_ => |c| {
                if (c.path) |rewritten| path = sanitizePath(rewritten);
                try response_headers_list.appendSlice(allocator, c.headers);
            },
        }
    } else if (hook_result) |result| {
        if (std.mem.eql(u8, result.value.action, "halt")) {
            try tracer.setAttribute(trace.root, "http.response.status_code", .{ .int = result.value.status });
            try writeMaybeRenderedResponse(io, allocator, stream, root, accept, .{
                .__yaan_response = true,
                .status = result.value.status,
                .content_type = result.value.content_type,
                .location = result.value.location,
                .headers = result.value.headers,
                .body = result.value.body,
            }, response_headers_list.items, debug_errors);
            return;
        }
        if (!std.mem.eql(u8, result.value.action, "continue")) return error.InvalidHookResult;
        if (result.value.path) |rewritten| path = sanitizePath(rewritten);
        try response_headers_list.appendSlice(allocator, result.value.headers);
    }

    if (std.mem.eql(u8, method, "POST")) {
        if (std.mem.eql(u8, path, "/_yaan/remote")) {
            const data = remote: {
                const span = try tracer.startChild(&trace, "yaan.remote");
                defer tracer.endSpan(&trace, span);
                if (options.remote) |f| break :remote try f(io, allocator, method, path, request_body);
                break :remote runRemoteRunner(io, allocator, remote_runner, method, path, request_body) catch |err| switch (err) {
                    error.FileNotFound => try allocator.dupe(u8, "{\"error\":\"no_remote_runner\"}"),
                    else => return err,
                };
            };
            defer allocator.free(data);
            const status = try writeRunnerOutput(io, allocator, stream, root, accept, data, response_headers_list.items, debug_errors);
            try tracer.setAttribute(trace.root, "http.response.status_code", .{ .int = status });
            return;
        }
        var multipart_data: ?MultipartData = null;
        defer if (multipart_data) |*data| data.deinit(io, allocator);
        const action_body = if (multipartBoundary(content_type)) |boundary| body: {
            multipart_data = parseMultipart(io, allocator, request_body, boundary, options) catch |err| switch (err) {
                error.PayloadTooLarge => {
                    try tracer.setAttribute(trace.root, "http.response.status_code", .{ .int = 413 });
                    try writeRenderedError(io, allocator, stream, root, 413, accept, .{
                        .message = "Upload is too large",
                        .code = "payload_too_large",
                    }, response_headers_list.items, null, debug_errors);
                    return;
                },
                error.MalformedMultipart => {
                    try tracer.setAttribute(trace.root, "http.response.status_code", .{ .int = 400 });
                    try writeRenderedError(io, allocator, stream, root, 400, accept, .{
                        .message = "Malformed multipart body",
                        .code = "bad_multipart",
                    }, response_headers_list.items, null, debug_errors);
                    return;
                },
                else => return err,
            };
            break :body multipart_data.?.fields_body;
        } else request_body;
        const uploads_json = if (multipart_data) |data|
            try uploadsJson(allocator, data.uploads)
        else
            try allocator.dupe(u8, "[]");
        defer allocator.free(uploads_json);

        if (options.csrf_protection and options.cookie_secret.len > 0 and !validCsrfForRequest(allocator, request_headers.items, action_body, options.cookie_secret)) {
            try tracer.setAttribute(trace.root, "http.response.status_code", .{ .int = 403 });
            try writeRenderedError(io, allocator, stream, root, 403, accept, .{
                .message = "Invalid CSRF token",
                .code = "csrf_invalid",
            }, response_headers_list.items, null, debug_errors);
            return;
        }

        const data = action: {
            const span = try tracer.startChild(&trace, "yaan.action");
            defer tracer.endSpan(&trace, span);
            if (options.action) |f| break :action try f(io, allocator, method, path, action_body, uploads_json, headers_json, meta_json);
            break :action runActionRunner(io, allocator, action_runner, method, path, action_body, uploads_json, headers_json, meta_json) catch |err| switch (err) {
                error.FileNotFound => try allocator.dupe(u8, "{\"error\":\"no_action\"}"),
                else => return err,
            };
        };
        defer allocator.free(data);
        const status = try writeRunnerOutput(io, allocator, stream, root, accept, data, response_headers_list.items, debug_errors);
        try tracer.setAttribute(trace.root, "http.response.status_code", .{ .int = status });
        return;
    }
    if (!std.mem.eql(u8, method, "GET") and !std.mem.eql(u8, method, "HEAD")) {
        try tracer.setAttribute(trace.root, "http.response.status_code", .{ .int = 405 });
        try writeRenderedError(io, allocator, stream, root, 405, accept, .{
            .message = "Method Not Allowed",
            .code = "method_not_allowed",
        }, response_headers_list.items, null, debug_errors);
        return;
    }

    if (std.mem.startsWith(u8, path, "/_yaan/load")) {
        const load_path = (try queryValue(allocator, target, "path")) orelse try allocator.dupe(u8, "/");
        defer allocator.free(load_path);
        const data = load: {
            const span = try tracer.startChild(&trace, "yaan.load");
            defer tracer.endSpan(&trace, span);
            try tracer.setAttribute(span, "yaan.route.path", .{ .string = load_path });
            if (options.load) |f| break :load try f(io, allocator, method, load_path, headers_json, meta_json);
            break :load runLoadRunner(io, allocator, load_runner, method, load_path, headers_json, meta_json) catch |err| switch (err) {
                error.FileNotFound => try allocator.dupe(u8, "null"),
                else => return err,
            };
        };
        defer allocator.free(data);
        const status = try writeRunnerOutput(io, allocator, stream, root, accept, data, response_headers_list.items, debug_errors);
        try tracer.setAttribute(trace.root, "http.response.status_code", .{ .int = status });
        return;
    }
    const doc_override = if (isNavigableHtml(method, accept, path))
        try matchPrerenderFile(io, allocator, root, path)
    else
        null;
    defer if (doc_override) |d| allocator.free(d);
    const read_path = doc_override orelse path;
    const body = asset: {
        const span = try tracer.startChild(&trace, "yaan.static");
        defer tracer.endSpan(&trace, span);
        break :asset readAsset(io, allocator, root, read_path) catch |err| switch (err) {
            error.FileNotFound => {
                if (std.mem.startsWith(u8, path, "/assets/")) {
                    try tracer.setAttribute(trace.root, "http.response.status_code", .{ .int = 404 });
                    try writeRenderedError(io, allocator, stream, root, 404, accept, .{
                        .message = "Asset not found",
                        .code = "not_found",
                    }, response_headers_list.items, null, debug_errors);
                    return;
                }
                break :asset try readAsset(io, allocator, root, "/index.html");
            },
            else => return err,
        };
    };
    defer allocator.free(body);
    try tracer.setAttribute(trace.root, "http.response.status_code", .{ .int = 200 });
    const mime = mimeType(read_path);
    const encoded = try encodeBody(allocator, accept_encoding, mime, body);
    defer allocator.free(encoded.body);
    var asset_headers: std.ArrayList(Header) = .empty;
    defer asset_headers.deinit(allocator);
    try asset_headers.appendSlice(allocator, response_headers_list.items);
    if (std.mem.startsWith(u8, path, "/assets/")) {
        try asset_headers.append(allocator, .{ .name = "cache-control", .value = "public, max-age=31536000, immutable" });
    }
    if (encoded.encoding) |encoding| {
        try asset_headers.append(allocator, .{ .name = "content-encoding", .value = encoding });
        try asset_headers.append(allocator, .{ .name = "vary", .value = "accept-encoding" });
    }
    if (std.mem.eql(u8, method, "HEAD")) {
        try writeHeadWithHeaders(io, stream, "200 OK", mime, encoded.body.len, asset_headers.items);
    } else {
        try writeResponseWithHeaders(io, stream, "200 OK", mime, encoded.body, asset_headers.items, null);
    }
}

fn readAsset(io: std.Io, allocator: std.mem.Allocator, root: []const u8, request_path: []const u8) ![]u8 {
    const rel = if (std.mem.eql(u8, request_path, "/")) "/index.html" else request_path;
    const trimmed = trimLeadingSlash(rel);
    if (std.mem.indexOf(u8, trimmed, "..") != null) return error.FileNotFound;
    const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, trimmed });
    defer allocator.free(full);
    return std.Io.Dir.cwd().readFileAlloc(io, full, allocator, .limited(8 * 1024 * 1024));
}

fn sanitizePath(target: []const u8) []const u8 {
    const no_query = if (std.mem.indexOfScalar(u8, target, '?')) |i| target[0..i] else target;
    if (no_query.len == 0 or no_query[0] != '/') return "/";
    return no_query;
}

fn requestSecurity(allocator: std.mem.Allocator, peer: std.Io.net.IpAddress, trusted_proxies: []const []const u8, host: []const u8, forwarded_proto: []const u8, forwarded_host: []const u8, forwarded_port: []const u8) !RequestSecurity {
    const trust_forwarded = isTrustedProxy(peer, trusted_proxies);
    if (!trust_forwarded) return .{ .secure = false, .host = host };
    const secure = std.ascii.eqlIgnoreCase(forwarded_proto, "https");
    const effective_host = if (forwarded_host.len > 0)
        try forwardedHostWithPort(allocator, forwarded_host, forwarded_port)
    else
        host;
    return .{ .secure = secure, .host = effective_host };
}

fn isTrustedProxy(peer: std.Io.net.IpAddress, trusted_proxies: []const []const u8) bool {
    for (trusted_proxies) |entry| {
        const trimmed = std.mem.trim(u8, entry, " \t");
        if (trimmed.len == 0) continue;
        const trusted = std.Io.net.IpAddress.parse(trimmed, 0) catch continue;
        if (sameIpIgnoringPort(peer, trusted)) return true;
    }
    return false;
}

fn sameIpIgnoringPort(a: std.Io.net.IpAddress, b: std.Io.net.IpAddress) bool {
    return switch (a) {
        .ip4 => |a4| switch (b) {
            .ip4 => |b4| std.mem.eql(u8, &a4.bytes, &b4.bytes),
            .ip6 => |b6| if (std.Io.net.Ip4Address.fromIp6(b6)) |mapped| std.mem.eql(u8, &a4.bytes, &mapped.bytes) else false,
        },
        .ip6 => |a6| switch (b) {
            .ip4 => |b4| if (std.Io.net.Ip4Address.fromIp6(a6)) |mapped| std.mem.eql(u8, &mapped.bytes, &b4.bytes) else false,
            .ip6 => |b6| std.mem.eql(u8, &a6.bytes, &b6.bytes),
        },
    };
}

fn nearestForwardedValue(value: []const u8) []const u8 {
    const last = if (std.mem.lastIndexOfScalar(u8, value, ',')) |i| value[i + 1 ..] else value;
    return std.mem.trim(u8, last, " \t");
}

fn forwardedHostWithPort(allocator: std.mem.Allocator, forwarded_host: []const u8, forwarded_port: []const u8) ![]const u8 {
    if (!validHostValue(forwarded_host)) return allocator.dupe(u8, "");
    if (forwarded_port.len == 0 or std.mem.eql(u8, forwarded_port, "443") or hostHasPort(forwarded_host) or !validPortValue(forwarded_port)) {
        return allocator.dupe(u8, forwarded_host);
    }
    return std.fmt.allocPrint(allocator, "{s}:{s}", .{ forwarded_host, forwarded_port });
}

fn hostHasPort(host: []const u8) bool {
    if (host.len == 0) return false;
    if (host[0] == '[') return std.mem.indexOf(u8, host, "]:") != null;
    return std.mem.indexOfScalar(u8, host, ':') != null;
}

fn httpsRedirectLocation(allocator: std.mem.Allocator, host: []const u8, target: []const u8) ![]u8 {
    const safe_host = if (host.len > 0 and validHostValue(host)) host else "localhost";
    const safe_target = if (target.len > 0 and target[0] == '/') target else "/";
    return std.fmt.allocPrint(allocator, "https://{s}{s}", .{ safe_host, safe_target });
}

fn validHostValue(host: []const u8) bool {
    if (host.len == 0 or !validHeaderValue(host)) return false;
    for (host) |c| {
        if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9')) continue;
        if (c == '.' or c == '-' or c == '_' or c == ':' or c == '[' or c == ']') continue;
        return false;
    }
    return true;
}

fn validPortValue(port: []const u8) bool {
    if (port.len == 0 or port.len > 5) return false;
    for (port) |c| if (c < '0' or c > '9') return false;
    const parsed = std.fmt.parseInt(u16, port, 10) catch return false;
    return parsed > 0;
}

fn queryValue(allocator: std.mem.Allocator, target: []const u8, key: []const u8) !?[]u8 {
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var pairs = std.mem.splitScalar(u8, target[query_start + 1 ..], '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) return try percentDecode(allocator, pair[eq + 1 ..]);
    }
    return null;
}

fn percentDecode(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < value.len) {
        if (value[i] == '%' and i + 2 < value.len) {
            const hi = try std.fmt.charToDigit(value[i + 1], 16);
            const lo = try std.fmt.charToDigit(value[i + 2], 16);
            try out.append(allocator, (hi << 4) | lo);
            i += 3;
        } else {
            try out.append(allocator, if (value[i] == '+') ' ' else value[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn multipartBoundary(content_type: []const u8) ?[]const u8 {
    if (!std.ascii.startsWithIgnoreCase(content_type, "multipart/form-data")) return null;
    var params = std.mem.splitScalar(u8, content_type, ';');
    _ = params.next();
    while (params.next()) |param| {
        const trimmed = std.mem.trim(u8, param, " \t");
        if (!std.mem.startsWith(u8, trimmed, "boundary=")) continue;
        var value = trimmed["boundary=".len..];
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value = value[1 .. value.len - 1];
        return if (value.len > 0) value else null;
    }
    return null;
}

fn parseMultipart(io: std.Io, allocator: std.mem.Allocator, body: []const u8, boundary: []const u8, options: StaticServerOptions) !MultipartData {
    const delimiter = try std.fmt.allocPrint(allocator, "--{s}", .{boundary});
    defer allocator.free(delimiter);
    var fields: std.ArrayList(u8) = .empty;
    errdefer fields.deinit(allocator);
    var uploads: std.ArrayList(UploadHandle) = .empty;
    errdefer {
        deinitUploadHandles(io, allocator, uploads.items);
        uploads.deinit(allocator);
    }

    var parts = std.mem.splitSequence(u8, body, delimiter);
    _ = parts.next();
    var upload_index: usize = 0;
    while (parts.next()) |raw_part| {
        if (std.mem.startsWith(u8, raw_part, "--")) break;
        var part = raw_part;
        if (std.mem.startsWith(u8, part, "\r\n")) part = part[2..];
        if (part.len == 0) continue;
        const header_end = std.mem.indexOf(u8, part, "\r\n\r\n") orelse return error.MalformedMultipart;
        if (header_end > options.max_multipart_header_length) return error.PayloadTooLarge;
        const header_block = part[0..header_end];
        var content = part[header_end + 4 ..];
        if (std.mem.endsWith(u8, content, "\r\n")) content = content[0 .. content.len - 2];

        const disposition = multipartHeader(header_block, "content-disposition") orelse return error.MalformedMultipart;
        const name = dispositionParam(disposition, "name") orelse return error.MalformedMultipart;
        const filename = dispositionParam(disposition, "filename");
        if (filename) |original_filename| {
            if (upload_index >= options.max_upload_count) return error.PayloadTooLarge;
            if (content.len > options.max_upload_file_length) return error.PayloadTooLarge;
            const content_type = multipartHeader(header_block, "content-type") orelse "application/octet-stream";
            const path = try uniqueUploadPath(io, allocator, upload_index);
            errdefer allocator.free(path);
            upload_index += 1;
            try std.Io.Dir.cwd().createDirPath(io, ".yaan/tmp");
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = content });
            try uploads.append(allocator, .{
                .name = try allocator.dupe(u8, name),
                .filename = try allocator.dupe(u8, original_filename),
                .content_type = try allocator.dupe(u8, content_type),
                .path = path,
                .size = content.len,
            });
        } else {
            if (fields.items.len + name.len + content.len + 2 > options.max_form_fields_length) return error.PayloadTooLarge;
            if (fields.items.len > 0) try fields.append(allocator, '&');
            try appendFormEscaped(allocator, &fields, name);
            try fields.append(allocator, '=');
            try appendFormEscaped(allocator, &fields, content);
            if (fields.items.len > options.max_form_fields_length) return error.PayloadTooLarge;
        }
    }

    return .{
        .fields_body = try fields.toOwnedSlice(allocator),
        .uploads = try uploads.toOwnedSlice(allocator),
    };
}

fn deinitUploadHandles(io: std.Io, allocator: std.mem.Allocator, uploads: []UploadHandle) void {
    const cwd = std.Io.Dir.cwd();
    for (uploads) |upload| {
        cwd.deleteFile(io, upload.path) catch {};
        allocator.free(upload.name);
        allocator.free(upload.filename);
        allocator.free(upload.content_type);
        allocator.free(upload.path);
    }
}

fn multipartHeader(headers: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const header_name = std.mem.trim(u8, line[0..colon], " \t");
        if (std.ascii.eqlIgnoreCase(header_name, name)) return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

fn dispositionParam(disposition: []const u8, name: []const u8) ?[]const u8 {
    var parts = std.mem.splitScalar(u8, disposition, ';');
    _ = parts.next();
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, trimmed[0..eq], " \t"), name)) continue;
        var value = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value = value[1 .. value.len - 1];
        return value;
    }
    return null;
}

fn uniqueUploadPath(io: std.Io, allocator: std.mem.Allocator, index: usize) ![]u8 {
    const counter = @atomicRmw(usize, &upload_counter, .Add, 1, .monotonic);
    var random_bytes: [16]u8 = undefined;
    io.randomSecure(&random_bytes) catch io.random(&random_bytes);
    var random_hex: [32]u8 = undefined;
    writeHexBytes(random_hex[0..], &random_bytes);
    return std.fmt.allocPrint(allocator, ".yaan/tmp/upload-{d}-{d}-{s}", .{ counter, index, random_hex });
}

fn appendFormEscaped(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |c| {
        if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.' or c == '*') {
            try out.append(allocator, c);
        } else if (c == ' ') {
            try out.append(allocator, '+');
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, hex[c >> 4]);
            try out.append(allocator, hex[c & 15]);
        }
    }
}

fn uploadsJson(allocator: std.mem.Allocator, uploads: []const UploadHandle) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try std.json.Stringify.value(uploads, .{}, &writer.writer);
    return allocator.dupe(u8, writer.written());
}

fn headersJson(allocator: std.mem.Allocator, headers: []const Header) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try std.json.Stringify.value(headers, .{}, &writer.writer);
    return allocator.dupe(u8, writer.written());
}

fn metaJson(allocator: std.mem.Allocator, meta: RequestMeta) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try std.json.Stringify.value(meta, .{}, &writer.writer);
    return allocator.dupe(u8, writer.written());
}

fn deinitHeaderList(allocator: std.mem.Allocator, headers: *std.ArrayList(Header)) void {
    for (headers.items) |h| {
        allocator.free(h.name);
        allocator.free(h.value);
    }
    headers.deinit(allocator);
}

pub fn signedCookieValue(allocator: std.mem.Allocator, name: []const u8, value: []const u8, secret: []const u8) ![]u8 {
    if (secret.len == 0) return error.MissingCookieSecret;
    const encoded_value = try base64Encode(allocator, value);
    defer allocator.free(encoded_value);
    const signed_part = try cookieMacInput(allocator, name, encoded_value);
    defer allocator.free(signed_part);
    var mac: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, signed_part, secret);
    const encoded_mac = try base64Encode(allocator, &mac);
    defer allocator.free(encoded_mac);
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ encoded_value, encoded_mac });
}

pub fn verifySignedCookie(allocator: std.mem.Allocator, name: []const u8, signed_value: []const u8, secret: []const u8) !?[]u8 {
    if (secret.len == 0) return error.MissingCookieSecret;
    const dot = std.mem.lastIndexOfScalar(u8, signed_value, '.') orelse return null;
    const encoded_value = signed_value[0..dot];
    const encoded_mac = signed_value[dot + 1 ..];
    const signed_part = try cookieMacInput(allocator, name, encoded_value);
    defer allocator.free(signed_part);
    var expected: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&expected, signed_part, secret);
    const actual = base64Decode(allocator, encoded_mac) catch return null;
    defer allocator.free(actual);
    if (actual.len != expected.len) return null;
    var actual_array: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    @memcpy(actual_array[0..], actual);
    if (!std.crypto.timing_safe.eql([std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8, actual_array, expected)) return null;
    return base64Decode(allocator, encoded_value) catch return null;
}

fn cookieMacInput(allocator: std.mem.Allocator, name: []const u8, encoded_value: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}\n{s}", .{ name, encoded_value });
}

fn base64Encode(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const out = try allocator.alloc(u8, encoder.calcSize(value.len));
    _ = encoder.encode(out, value);
    return out;
}

fn base64Decode(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const size = try decoder.calcSizeForSlice(value);
    const out = try allocator.alloc(u8, size);
    errdefer allocator.free(out);
    try decoder.decode(out, value);
    return out;
}

fn validCsrfForRequest(allocator: std.mem.Allocator, headers: []const Header, body: []const u8, secret: []const u8) bool {
    const cookie_token = cookieValue(headers, "yaan_csrf") orelse return false;
    const submitted = requestHeader(headers, "x-csrf-token") orelse formFieldRaw(body, "_csrf") orelse return false;
    if (!std.mem.eql(u8, cookie_token, submitted)) return false;
    const decoded = verifySignedCookie(allocator, "yaan_csrf", cookie_token, secret) catch return false;
    if (decoded) |value| {
        allocator.free(value);
        return true;
    }
    return false;
}

fn cookieValue(headers: []const Header, name: []const u8) ?[]const u8 {
    const cookie_header = requestHeader(headers, "cookie") orelse return null;
    var parts = std.mem.splitScalar(u8, cookie_header, ';');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        if (std.mem.eql(u8, trimmed[0..eq], name)) return trimmed[eq + 1 ..];
    }
    return null;
}

fn formFieldRaw(body: []const u8, name: []const u8) ?[]const u8 {
    var pairs = std.mem.splitScalar(u8, body, '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

fn writeHexBytes(out: []u8, bytes: []const u8) void {
    const alphabet = "0123456789abcdef";
    for (bytes, 0..) |byte, i| {
        out[i * 2] = alphabet[byte >> 4];
        out[i * 2 + 1] = alphabet[byte & 0x0f];
    }
}

fn runLoadRunner(io: std.Io, allocator: std.mem.Allocator, runner: []const u8, method: []const u8, path: []const u8, headers_json: []const u8, meta_json: []const u8) ![]u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ runner, method, path, headers_json, meta_json },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer allocator.free(result.stderr);
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        std.debug.print("{s}", .{result.stderr});
        allocator.free(result.stdout);
        return error.LoaderFailed;
    }
    return result.stdout;
}

fn runActionRunner(io: std.Io, allocator: std.mem.Allocator, runner: []const u8, method: []const u8, path: []const u8, body: []const u8, uploads: []const u8, headers_json: []const u8, meta_json: []const u8) ![]u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ runner, method, path, body, uploads, headers_json, meta_json },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer allocator.free(result.stderr);
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        std.debug.print("{s}", .{result.stderr});
        allocator.free(result.stdout);
        return error.ActionFailed;
    }
    return result.stdout;
}

fn runRemoteRunner(io: std.Io, allocator: std.mem.Allocator, runner: []const u8, method: []const u8, path: []const u8, body: []const u8) ![]u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ runner, method, path, body },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer allocator.free(result.stderr);
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        std.debug.print("{s}", .{result.stderr});
        allocator.free(result.stdout);
        return error.RemoteFailed;
    }
    return result.stdout;
}

fn runHookRunner(io: std.Io, allocator: std.mem.Allocator, runner: []const u8, method: []const u8, target: []const u8, path: []const u8, body: []const u8) ![]u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ runner, method, target, path, body },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer allocator.free(result.stderr);
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        std.debug.print("{s}", .{result.stderr});
        allocator.free(result.stdout);
        return error.HookFailed;
    }
    return result.stdout;
}

fn trimLeadingSlash(value: []const u8) []const u8 {
    var i: usize = 0;
    while (i < value.len and value[i] == '/') i += 1;
    return value[i..];
}

/// A navigable request is a GET/HEAD for an HTML document at an extensionless
/// path (i.e. a route, not a static file or internal endpoint).
fn isNavigableHtml(method: []const u8, accept: []const u8, path: []const u8) bool {
    if (!std.mem.eql(u8, method, "GET") and !std.mem.eql(u8, method, "HEAD")) return false;
    if (!wantsHtml(accept)) return false;
    if (std.mem.startsWith(u8, path, "/_yaan")) return false;
    if (std.mem.startsWith(u8, path, "/assets/")) return false;
    const last = path[(std.mem.lastIndexOfScalar(u8, path, '/') orelse 0)..];
    return std.mem.indexOfScalar(u8, last, '.') == null;
}

const PrerenderEntry = struct { path: []const u8, file: []const u8 };

/// Resolves a navigable path to its prerendered document via dist/prerender.json.
/// Returns a request-style path ("/pages/pageN.html") to read, or null to fall
/// back to the default shell. Apps built without prerendering simply return null.
fn matchPrerenderFile(io: std.Io, allocator: std.mem.Allocator, root: []const u8, path: []const u8) !?[]u8 {
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/prerender.json", .{root});
    defer allocator.free(manifest_path);
    const data = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .limited(256 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(data);
    const parsed = std.json.parseFromSlice([]PrerenderEntry, allocator, data, .{}) catch return null;
    defer parsed.deinit();
    for (parsed.value) |entry| {
        if (pathMatchesPattern(entry.path, path)) {
            return try std.fmt.allocPrint(allocator, "/{s}", .{entry.file});
        }
    }
    return null;
}

/// Matches a request path against a route pattern such as "/", "/users/:id",
/// or "/docs/:path*". Mirrors the client router's matching semantics.
fn pathMatchesPattern(pattern: []const u8, path: []const u8) bool {
    if (std.mem.eql(u8, pattern, "/")) return std.mem.eql(u8, path, "/") or path.len == 0;
    var pat_it = std.mem.tokenizeScalar(u8, pattern, '/');
    var path_it = std.mem.tokenizeScalar(u8, path, '/');
    while (pat_it.next()) |seg| {
        if (seg.len > 0 and seg[0] == ':' and seg[seg.len - 1] == '*') {
            return true; // rest parameter matches the remainder (including empty)
        }
        const actual = path_it.next() orelse return false;
        if (seg.len > 0 and seg[0] == ':') continue; // named param matches any one segment
        if (!std.mem.eql(u8, seg, actual)) return false;
    }
    return path_it.next() == null; // no leftover path segments
}

fn mimeType(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".js")) return "text/javascript; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".css")) return "text/css; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".html") or std.mem.eql(u8, path, "/")) return "text/html; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".json")) return "application/json; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".svg")) return "image/svg+xml";
    if (std.mem.endsWith(u8, path, ".png")) return "image/png";
    if (std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg")) return "image/jpeg";
    if (std.mem.endsWith(u8, path, ".gif")) return "image/gif";
    if (std.mem.endsWith(u8, path, ".webp")) return "image/webp";
    if (std.mem.endsWith(u8, path, ".avif")) return "image/avif";
    if (std.mem.endsWith(u8, path, ".ico")) return "image/x-icon";
    return "application/octet-stream";
}

fn writeHead(io: std.Io, stream: std.Io.net.Stream, status: []const u8, mime: []const u8, len: usize) !void {
    try writeHeadWithHeaders(io, stream, status, mime, len, &.{});
}

fn writeHeadWithHeaders(io: std.Io, stream: std.Io.net.Stream, status: []const u8, mime: []const u8, len: usize, headers: []const Header) !void {
    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.print("HTTP/1.1 {s}\r\ncontent-type: {s}\r\ncontent-length: {d}\r\n", .{ status, mime, len });
    for (headers) |header| {
        if (validHeaderName(header.name) and validHeaderValue(header.value)) {
            try writer.interface.print("{s}: {s}\r\n", .{ header.name, header.value });
        }
    }
    try writer.interface.writeAll("connection: close\r\n\r\n");
    try writer.interface.flush();
}

fn writeResponse(io: std.Io, stream: std.Io.net.Stream, status: []const u8, mime: []const u8, body: []const u8) !void {
    try writeResponseWithHeaders(io, stream, status, mime, body, &.{}, null);
}

fn requestHeader(headers: []const Header, name: []const u8) ?[]const u8 {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

fn testResponse(allocator: std.mem.Allocator, status: u16, content_type: []const u8, body: []const u8, headers: []const Header, location: ?[]const u8) !TestResponse {
    return .{
        .status = status,
        .content_type = try allocator.dupe(u8, content_type),
        .headers = try ownedHeaders(allocator, headers),
        .body = try allocator.dupe(u8, body),
        .location = if (location) |value| try allocator.dupe(u8, value) else null,
    };
}

fn ownedHeaders(allocator: std.mem.Allocator, headers: []const Header) ![]Header {
    const out = try allocator.alloc(Header, headers.len);
    errdefer allocator.free(out);
    for (headers, 0..) |header, i| {
        out[i] = .{
            .name = try allocator.dupe(u8, header.name),
            .value = try allocator.dupe(u8, header.value),
        };
    }
    return out;
}

fn testRunnerOutput(io: std.Io, allocator: std.mem.Allocator, root: []const u8, accept: []const u8, data: []const u8, extra_headers: []const Header, debug_errors: bool) !TestResponse {
    var parsed = std.json.parseFromSlice(RunnerResponse, allocator, data, .{}) catch {
        return try testResponse(allocator, 200, "application/json; charset=utf-8", data, extra_headers, null);
    };
    defer parsed.deinit();
    if (!parsed.value.__yaan_response) {
        return try testResponse(allocator, 200, "application/json; charset=utf-8", data, extra_headers, null);
    }
    return try testMaybeRenderedResponse(io, allocator, root, accept, parsed.value, extra_headers, debug_errors);
}

fn testMaybeRenderedResponse(io: std.Io, allocator: std.mem.Allocator, root: []const u8, accept: []const u8, response: RunnerResponse, extra_headers: []const Header, debug_errors: bool) !TestResponse {
    var headers: std.ArrayList(Header) = .empty;
    defer headers.deinit(allocator);
    try headers.appendSlice(allocator, extra_headers);
    try headers.appendSlice(allocator, response.headers);
    if (response.status < 400 or !wantsHtml(accept)) {
        return try testResponse(allocator, response.status, response.content_type, response.body, headers.items, response.location);
    }
    const parsed_body = parseErrorBody(allocator, response.status, response.body);
    defer if (parsed_body.value) |*value| value.deinit();
    return try testRenderedError(io, allocator, root, response.status, accept, parsed_body.body, headers.items, response.location, debug_errors);
}

fn testRenderedError(io: std.Io, allocator: std.mem.Allocator, root: []const u8, status: u16, accept: []const u8, body: ErrorBody, headers: []const Header, location: ?[]const u8, debug_errors: bool) !TestResponse {
    if (!wantsHtml(accept)) {
        const json = try errorJson(allocator, status, body, debug_errors);
        defer allocator.free(json);
        return try testResponse(allocator, status, "application/json; charset=utf-8", json, headers, location);
    }
    if (try readErrorOverride(io, allocator, root, status)) |override| {
        defer allocator.free(override);
        return try testResponse(allocator, status, "text/html; charset=utf-8", override, headers, location);
    }
    const html = try defaultErrorHtml(allocator, status, body, debug_errors);
    defer allocator.free(html);
    return try testResponse(allocator, status, "text/html; charset=utf-8", html, headers, location);
}

fn writeRunnerOutput(io: std.Io, allocator: std.mem.Allocator, stream: std.Io.net.Stream, root: []const u8, accept: []const u8, data: []const u8, extra_headers: []const Header, debug_errors: bool) !u16 {
    var parsed = std.json.parseFromSlice(RunnerResponse, allocator, data, .{}) catch {
        try writeResponseWithHeaders(io, stream, "200 OK", "application/json; charset=utf-8", data, extra_headers, null);
        return 200;
    };
    defer parsed.deinit();
    if (!parsed.value.__yaan_response) {
        try writeResponseWithHeaders(io, stream, "200 OK", "application/json; charset=utf-8", data, extra_headers, null);
        return 200;
    }
    try writeMaybeRenderedResponse(io, allocator, stream, root, accept, parsed.value, extra_headers, debug_errors);
    return parsed.value.status;
}

fn writeMaybeRenderedResponse(io: std.Io, allocator: std.mem.Allocator, stream: std.Io.net.Stream, root: []const u8, accept: []const u8, response: RunnerResponse, extra_headers: []const Header, debug_errors: bool) !void {
    var headers: std.ArrayList(Header) = .empty;
    defer headers.deinit(allocator);
    try headers.appendSlice(allocator, extra_headers);
    try headers.appendSlice(allocator, response.headers);
    if (response.status < 400 or !wantsHtml(accept)) {
        try writeResponseWithHeaders(io, stream, statusText(response.status), response.content_type, response.body, headers.items, response.location);
        return;
    }
    const parsed_body = parseErrorBody(allocator, response.status, response.body);
    defer if (parsed_body.value) |*value| value.deinit();
    try writeRenderedError(io, allocator, stream, root, response.status, accept, parsed_body.body, headers.items, response.location, debug_errors);
}

const ParsedErrorBody = struct {
    body: ErrorBody,
    parsed: bool = false,
    value: ?std.json.Parsed(ErrorBody) = null,
};

fn parseErrorBody(allocator: std.mem.Allocator, status: u16, body: []const u8) ParsedErrorBody {
    const parsed = std.json.parseFromSlice(ErrorBody, allocator, body, .{}) catch {
        return .{ .body = .{
            .message = if (body.len > 0) body else statusTitle(status),
            .code = statusCode(status),
        } };
    };
    return .{ .body = parsed.value, .parsed = true, .value = parsed };
}

fn writeRenderedError(io: std.Io, allocator: std.mem.Allocator, stream: std.Io.net.Stream, root: []const u8, status: u16, accept: []const u8, body: ErrorBody, headers: []const Header, location: ?[]const u8, debug_errors: bool) !void {
    if (!wantsHtml(accept)) {
        const json = try errorJson(allocator, status, body, debug_errors);
        defer allocator.free(json);
        try writeResponseWithHeaders(io, stream, statusText(status), "application/json; charset=utf-8", json, headers, location);
        return;
    }
    if (try readErrorOverride(io, allocator, root, status)) |override| {
        defer allocator.free(override);
        try writeResponseWithHeaders(io, stream, statusText(status), "text/html; charset=utf-8", override, headers, location);
        return;
    }
    const html = try defaultErrorHtml(allocator, status, body, debug_errors);
    defer allocator.free(html);
    try writeResponseWithHeaders(io, stream, statusText(status), "text/html; charset=utf-8", html, headers, location);
}

fn readErrorOverride(io: std.Io, allocator: std.mem.Allocator, root: []const u8, status: u16) !?[]u8 {
    const error_path = try std.fmt.allocPrint(allocator, "/error/{d}.html", .{status});
    defer allocator.free(error_path);
    if (readAsset(io, allocator, root, error_path)) |body| return body else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    if (status == 404) {
        if (readAsset(io, allocator, root, "/404.html")) |body| return body else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
    }
    return null;
}

fn defaultErrorHtml(allocator: std.mem.Allocator, status: u16, body: ErrorBody, debug_errors: bool) ![]u8 {
    const title = statusTitle(status);
    const message = safeErrorMessage(status, body.message, debug_errors);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>");
    try appendEscapedHtml(allocator, &out, title);
    try out.appendSlice(allocator, "</title><style>body{font-family:system-ui,sans-serif;margin:4rem;line-height:1.5;color:#111827}main{max-width:42rem}code{background:#f3f4f6;padding:.1rem .25rem;border-radius:.25rem}</style></head><body><main><h1>");
    try appendEscapedHtml(allocator, &out, title);
    try out.appendSlice(allocator, "</h1><p>");
    try appendEscapedHtml(allocator, &out, message);
    try out.appendSlice(allocator, "</p>");
    if (debug_errors and (body.code.len > 0 or body.id.len > 0)) {
        try out.appendSlice(allocator, "<p>");
        if (body.code.len > 0) {
            try out.appendSlice(allocator, "Code <code>");
            try appendEscapedHtml(allocator, &out, body.code);
            try out.appendSlice(allocator, "</code>");
        }
        if (body.id.len > 0) {
            try out.appendSlice(allocator, " ID <code>");
            try appendEscapedHtml(allocator, &out, body.id);
            try out.appendSlice(allocator, "</code>");
        }
        try out.appendSlice(allocator, "</p>");
    }
    try out.appendSlice(allocator, "</main></body></html>");
    return out.toOwnedSlice(allocator);
}

fn errorJson(allocator: std.mem.Allocator, status: u16, body: ErrorBody, debug_errors: bool) ![]u8 {
    const safe_body = ErrorBody{
        .message = safeErrorMessage(status, body.message, debug_errors),
        .code = if (status >= 500 and !debug_errors) "internal_error" else body.code,
        .id = body.id,
    };
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try std.json.Stringify.value(safe_body, .{}, &writer.writer);
    return allocator.dupe(u8, writer.written());
}

fn wantsHtml(accept: []const u8) bool {
    if (std.mem.indexOf(u8, accept, "text/html") != null) return true;
    return false;
}

fn safeErrorMessage(status: u16, message: []const u8, debug_errors: bool) []const u8 {
    if (status >= 500 and !debug_errors) return "Internal Error";
    if (message.len > 0) return message;
    return statusTitle(status);
}

fn statusTitle(status: u16) []const u8 {
    return switch (status) {
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        413 => "Payload Too Large",
        422 => "Unprocessable Entity",
        500 => "Internal Error",
        else => "Error",
    };
}

fn statusCode(status: u16) []const u8 {
    return switch (status) {
        400 => "bad_request",
        401 => "unauthorized",
        403 => "forbidden",
        404 => "not_found",
        405 => "method_not_allowed",
        409 => "conflict",
        413 => "payload_too_large",
        422 => "unprocessable_entity",
        500 => "internal_error",
        else => "error",
    };
}

fn appendEscapedHtml(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    for (value) |c| switch (c) {
        '&' => try out.appendSlice(allocator, "&amp;"),
        '<' => try out.appendSlice(allocator, "&lt;"),
        '>' => try out.appendSlice(allocator, "&gt;"),
        '"' => try out.appendSlice(allocator, "&quot;"),
        '\'' => try out.appendSlice(allocator, "&#39;"),
        else => try out.append(allocator, c),
    };
}

fn writeResponseWithHeaders(io: std.Io, stream: std.Io.net.Stream, status: []const u8, mime: []const u8, body: []const u8, headers: []const Header, location: ?[]const u8) !void {
    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.print("HTTP/1.1 {s}\r\ncontent-type: {s}\r\ncontent-length: {d}\r\n", .{ status, mime, body.len });
    if (location) |value| {
        if (validHeaderValue(value)) try writer.interface.print("location: {s}\r\n", .{value});
    }
    for (headers) |header| {
        if (validHeaderName(header.name) and validHeaderValue(header.value)) {
            try writer.interface.print("{s}: {s}\r\n", .{ header.name, header.value });
        }
    }
    try writer.interface.writeAll("connection: close\r\n\r\n");
    try writer.interface.writeAll(body);
    try writer.interface.flush();
}

fn validHeaderName(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |c| {
        if (c <= 32 or c >= 127 or c == ':') return false;
    }
    return true;
}

fn validHeaderValue(value: []const u8) bool {
    return std.mem.indexOfAny(u8, value, "\r\n") == null;
}

fn statusText(status: u16) []const u8 {
    return switch (status) {
        200 => "200 OK",
        201 => "201 Created",
        204 => "204 No Content",
        301 => "301 Moved Permanently",
        302 => "302 Found",
        303 => "303 See Other",
        307 => "307 Temporary Redirect",
        308 => "308 Permanent Redirect",
        400 => "400 Bad Request",
        401 => "401 Unauthorized",
        403 => "403 Forbidden",
        404 => "404 Not Found",
        405 => "405 Method Not Allowed",
        409 => "409 Conflict",
        413 => "413 Payload Too Large",
        422 => "422 Unprocessable Entity",
        500 => "500 Internal Server Error",
        else => "500 Internal Server Error",
    };
}

test "gzip round-trips and only encodes above threshold" {
    const allocator = std.testing.allocator;

    // Small payload: left uncompressed.
    const small = try encodeBody(allocator, "gzip", "text/css", "body{}");
    defer allocator.free(small.body);
    try std.testing.expect(small.encoding == null);
    try std.testing.expectEqualStrings("body{}", small.body);

    // Compressible payload over threshold with a client that accepts gzip.
    const original = "abcdefgh" ** 256; // 2048 bytes, highly compressible
    const encoded = try encodeBody(allocator, "gzip, deflate, br", "text/javascript", original);
    defer allocator.free(encoded.body);
    try std.testing.expectEqualStrings("gzip", encoded.encoding.?);
    try std.testing.expect(encoded.body.len < original.len);

    // Decompress and confirm we recover the exact original bytes.
    var in: std.Io.Reader = .fixed(encoded.body);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress = std.compress.flate.Decompress.init(&in, .gzip, &window);
    const restored = try decompress.reader.allocRemaining(allocator, .unlimited);
    defer allocator.free(restored);
    try std.testing.expectEqualStrings(original, restored);

    // Client without gzip support gets the raw body.
    const raw = try encodeBody(allocator, "identity", "text/javascript", original);
    defer allocator.free(raw.body);
    try std.testing.expect(raw.encoding == null);
}

fn testHaltHook(io: std.Io, allocator: std.mem.Allocator, runner: []const u8, request: HookRequest) anyerror!HookDecision {
    _ = io;
    _ = runner;
    _ = request;
    return .{ .halt = .{
        .status = 403,
        .content_type = try allocator.dupe(u8, "text/plain; charset=utf-8"),
        .body = try allocator.dupe(u8, "blocked by layer"),
        .headers = try allocator.alloc(Header, 0),
    } };
}

fn testHeaderHook(io: std.Io, allocator: std.mem.Allocator, runner: []const u8, request: HookRequest) anyerror!HookDecision {
    _ = io;
    _ = runner;
    _ = request;
    const headers = try allocator.alloc(Header, 1);
    headers[0] = .{ .name = try allocator.dupe(u8, "x-test-layer"), .value = try allocator.dupe(u8, "1") };
    return .{ .continue_ = .{ .headers = headers } };
}

test "in-process hook halts the request through the real pipeline" {
    var res = try testRequest(std.testing.io, std.testing.allocator, .{
        .root = ".",
        .hook = &testHaltHook,
    }, .{ .method = "GET", .target = "/anything" });
    defer res.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 403), res.status);
    try res.expectBodyContains("blocked by layer");
}

test "in-process hook continue headers reach the response" {
    var res = try testRequest(std.testing.io, std.testing.allocator, .{
        .root = ".",
        .hook = &testHeaderHook,
    }, .{ .method = "GET", .target = "/assets/missing.js" });
    defer res.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 404), res.status); // continued to routing/static
    try std.testing.expectEqualStrings("1", res.header("x-test-layer").?);
}

test "frameworkHook composes an in-process layer over the subprocess bridge" {
    // No hook_runner exists, so the bridge terminal returns continue; the
    // StampLayer must still have stamped the response on the way out.
    const decision = try frameworkHook(std.testing.io, std.testing.allocator, ".yaan/does-not-exist", .{
        .method = "GET",
        .target = "/",
        .path = "/",
        .body = "",
    });
    defer decision.deinit(std.testing.allocator);
    switch (decision) {
        .continue_ => |c| {
            var stamped = false;
            for (c.headers) |h| {
                if (std.mem.eql(u8, h.name, "x-yaan-pipeline")) stamped = true;
            }
            try std.testing.expect(stamped);
        },
        .halt => return error.UnexpectedHalt,
    }
}

test "security headers append when enabled" {
    const allocator = std.testing.allocator;
    var list: std.ArrayList(Header) = .empty;
    defer list.deinit(allocator);
    try appendSecurityHeaders(allocator, &list, .{});
    try std.testing.expect(requestHeader(list.items, "x-content-type-options") != null);
    try std.testing.expect(requestHeader(list.items, "content-security-policy") != null);

    var off: std.ArrayList(Header) = .empty;
    defer off.deinit(allocator);
    try appendSecurityHeaders(allocator, &off, .{ .security_headers = false });
    try std.testing.expectEqual(@as(usize, 0), off.items.len);
}

test "path pattern matching mirrors the client router" {
    try std.testing.expect(pathMatchesPattern("/", "/"));
    try std.testing.expect(!pathMatchesPattern("/", "/about"));
    try std.testing.expect(pathMatchesPattern("/users/:id", "/users/42"));
    try std.testing.expect(!pathMatchesPattern("/users/:id", "/users/42/edit"));
    try std.testing.expect(!pathMatchesPattern("/users/:id", "/users"));
    try std.testing.expect(pathMatchesPattern("/blog/:slug", "/blog/hello"));
    try std.testing.expect(pathMatchesPattern("/docs/:path*", "/docs"));
    try std.testing.expect(pathMatchesPattern("/docs/:path*", "/docs/intro/setup"));
    try std.testing.expect(!pathMatchesPattern("/shop/cart", "/shop/wish"));
}

test "error rendering hides internals in prod and exposes them in debug" {
    const a = std.testing.allocator;
    const leaky = ErrorBody{ .message = "db connection string is postgres://secret", .code = "db_down", .id = "err-abc" };

    // 5xx in prod: message is replaced, code forced to internal_error, no leak.
    {
        const json = try errorJson(a, 500, leaky, false);
        defer a.free(json);
        try std.testing.expect(std.mem.indexOf(u8, json, "Internal Error") != null);
        try std.testing.expect(std.mem.indexOf(u8, json, "internal_error") != null);
        try std.testing.expect(std.mem.indexOf(u8, json, "postgres://secret") == null);
        try std.testing.expect(std.mem.indexOf(u8, json, "db_down") == null);
    }
    // 5xx in debug: the real message and code come through.
    {
        const json = try errorJson(a, 500, leaky, true);
        defer a.free(json);
        try std.testing.expect(std.mem.indexOf(u8, json, "postgres://secret") != null);
        try std.testing.expect(std.mem.indexOf(u8, json, "db_down") != null);
    }
    // The HTML renderer only emits the code/id debug block when debug_errors.
    {
        const html = try defaultErrorHtml(a, 500, leaky, false);
        defer a.free(html);
        try std.testing.expect(std.mem.indexOf(u8, html, "postgres://secret") == null);
        try std.testing.expect(std.mem.indexOf(u8, html, "err-abc") == null);
        try std.testing.expect(std.mem.indexOf(u8, html, "Internal Error") != null);
    }
    {
        const html = try defaultErrorHtml(a, 500, leaky, true);
        defer a.free(html);
        try std.testing.expect(std.mem.indexOf(u8, html, "err-abc") != null);
    }
    // 4xx messages are caller-facing and pass through even in prod.
    {
        const body = ErrorBody{ .message = "id must be an integer", .code = "bad_request" };
        const json = try errorJson(a, 400, body, false);
        defer a.free(json);
        try std.testing.expect(std.mem.indexOf(u8, json, "id must be an integer") != null);
    }
}

test "navigable html detection" {
    try std.testing.expect(isNavigableHtml("GET", "text/html", "/users/42"));
    try std.testing.expect(isNavigableHtml("GET", "text/html,*/*", "/"));
    try std.testing.expect(!isNavigableHtml("GET", "text/html", "/app.js"));
    try std.testing.expect(!isNavigableHtml("GET", "text/html", "/assets/logo.svg"));
    try std.testing.expect(!isNavigableHtml("GET", "text/html", "/_yaan/load"));
    try std.testing.expect(!isNavigableHtml("POST", "text/html", "/users/42"));
    try std.testing.expect(!isNavigableHtml("GET", "application/json", "/users/42"));
}

test "server description" {
    const s = try describe(.{}, std.testing.allocator);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("http://127.0.0.1:5173 serving dist", s);
}

test "multipart parser writes upload handles and urlencoded fields" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    try std.Io.Dir.cwd().createDirPath(io, ".yaan/tmp");
    const body =
        "--yaan\r\n" ++
        "Content-Disposition: form-data; name=\"title\"\r\n" ++
        "\r\n" ++
        "hello world\r\n" ++
        "--yaan\r\n" ++
        "Content-Disposition: form-data; name=\"photo\"; filename=\"avatar.png\"\r\n" ++
        "Content-Type: image/png\r\n" ++
        "\r\n" ++
        "PNGDATA\r\n" ++
        "--yaan--\r\n";
    var parsed = try parseMultipart(io, allocator, body, "yaan", .{});
    defer parsed.deinit(io, allocator);

    try std.testing.expectEqualStrings("title=hello+world", parsed.fields_body);
    try std.testing.expectEqual(@as(usize, 1), parsed.uploads.len);
    try std.testing.expectEqualStrings("photo", parsed.uploads[0].name);
    try std.testing.expectEqualStrings("avatar.png", parsed.uploads[0].filename);
    try std.testing.expectEqualStrings("image/png", parsed.uploads[0].content_type);
    try std.testing.expectEqual(@as(usize, 7), parsed.uploads[0].size);

    const contents = try std.Io.Dir.cwd().readFileAlloc(io, parsed.uploads[0].path, allocator, .limited(128));
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("PNGDATA", contents);
}

test "forwarded headers are ignored without trusted proxy" {
    const peer = try std.Io.net.IpAddress.parse("203.0.113.10", 49152);
    const security = try requestSecurity(
        std.testing.allocator,
        peer,
        &.{"127.0.0.1"},
        "app.example.com",
        "https",
        "public.example.com",
        "443",
    );
    try std.testing.expect(!security.secure);
    try std.testing.expectEqualStrings("app.example.com", security.host);
}

test "trusted forwarded headers determine secure host" {
    const peer = try std.Io.net.IpAddress.parse("127.0.0.1", 49152);
    const security = try requestSecurity(
        std.testing.allocator,
        peer,
        &.{"127.0.0.1"},
        "127.0.0.1:5173",
        "https",
        "app.example.com",
        "8443",
    );
    defer std.testing.allocator.free(security.host);
    try std.testing.expect(security.secure);
    try std.testing.expectEqualStrings("app.example.com:8443", security.host);
}

test "trusted forwarded headers use nearest proxy value" {
    const peer = try std.Io.net.IpAddress.parse("127.0.0.1", 49152);
    const security = try requestSecurity(
        std.testing.allocator,
        peer,
        &.{"127.0.0.1"},
        "127.0.0.1:5173",
        nearestForwardedValue("http, https"),
        nearestForwardedValue("attacker.example, app.example.com"),
        nearestForwardedValue("80, 443"),
    );
    defer std.testing.allocator.free(security.host);
    try std.testing.expect(security.secure);
    try std.testing.expectEqualStrings("app.example.com", security.host);
}

test "https redirect location preserves target" {
    const location = try httpsRedirectLocation(std.testing.allocator, "example.com", "/users/42?tab=profile");
    defer std.testing.allocator.free(location);
    try std.testing.expectEqualStrings("https://example.com/users/42?tab=profile", location);
}

test "https redirect rejects invalid host characters" {
    const location = try httpsRedirectLocation(std.testing.allocator, "evil.com/path", "/users");
    defer std.testing.allocator.free(location);
    try std.testing.expectEqualStrings("https://localhost/users", location);
}

test "hsts only emits for secure effective requests" {
    const headers = [_]Header{
        .{ .name = "accept", .value = "application/json" },
        .{ .name = "host", .value = "internal:5173" },
        .{ .name = "x-forwarded-proto", .value = "https" },
    };
    var secure_res = try testRequest(std.testing.io, std.testing.allocator, .{
        .root = ".",
        .trusted_proxies = &.{"127.0.0.1"},
        .hsts = true,
    }, .{ .method = "GET", .target = "/assets/missing.js", .headers = &headers });
    defer secure_res.deinit(std.testing.allocator);
    try std.testing.expect(secure_res.header("strict-transport-security") != null);

    var plain_res = try testRequest(std.testing.io, std.testing.allocator, .{
        .root = ".",
        .hsts = true,
    }, .{ .method = "GET", .target = "/assets/missing.js", .headers = &headers });
    defer plain_res.deinit(std.testing.allocator);
    try std.testing.expect(plain_res.header("strict-transport-security") == null);
}

test "multipart parser enforces upload limits" {
    const body =
        "--yaan\r\n" ++
        "Content-Disposition: form-data; name=\"photo\"; filename=\"avatar.png\"\r\n" ++
        "Content-Type: image/png\r\n" ++
        "\r\n" ++
        "PNGDATA\r\n" ++
        "--yaan--\r\n";
    try std.testing.expectError(error.PayloadTooLarge, parseMultipart(std.testing.io, std.testing.allocator, body, "yaan", .{ .max_upload_count = 0 }));
    try std.testing.expectError(error.PayloadTooLarge, parseMultipart(std.testing.io, std.testing.allocator, body, "yaan", .{ .max_upload_file_length = 4 }));
}

test "signed cookies and csrf validation reject tampering" {
    const allocator = std.testing.allocator;
    const secret = "test-secret";
    const signed = try signedCookieValue(allocator, "session", "abc123", secret);
    defer allocator.free(signed);
    const verified = (try verifySignedCookie(allocator, "session", signed, secret)).?;
    defer allocator.free(verified);
    try std.testing.expectEqualStrings("abc123", verified);
    try std.testing.expect((try verifySignedCookie(allocator, "session", "bad.value", secret)) == null);

    const csrf = try signedCookieValue(allocator, "yaan_csrf", "nonce", secret);
    defer allocator.free(csrf);
    const cookie = try std.fmt.allocPrint(allocator, "yaan_csrf={s}", .{csrf});
    defer allocator.free(cookie);
    const headers = [_]Header{
        .{ .name = "cookie", .value = cookie },
        .{ .name = "x-csrf-token", .value = csrf },
    };
    try std.testing.expect(validCsrfForRequest(allocator, &headers, "", secret));
    const bad_headers = [_]Header{
        .{ .name = "cookie", .value = cookie },
        .{ .name = "x-csrf-token", .value = "bad" },
    };
    try std.testing.expect(!validCsrfForRequest(allocator, &bad_headers, "", secret));
}
