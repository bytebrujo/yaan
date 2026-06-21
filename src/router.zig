const std = @import("std");

pub const ParamType = enum {
    string,
    int,
    uint,

    pub fn zigType(self: ParamType) []const u8 {
        return switch (self) {
            .string => "[]const u8",
            .int => "i64",
            .uint => "u64",
        };
    }
};

pub const SegmentKind = enum { static, dynamic, rest };

pub const Segment = struct {
    kind: SegmentKind,
    name: []u8,
    param_type: ?ParamType = null,
};

pub const Prerender = enum { auto, always, never };
pub const TrailingSlash = enum { ignore, always, never };

pub const RouteOptions = struct {
    prerender: Prerender = .auto,
    csr: bool = true,
    trailing_slash: TrailingSlash = .ignore,
};

/// One layout level in a route's chain. `file` is the `+layout.yn` source;
/// `load_file` is its optional `+layout.load.zig` data loader. `name` is a
/// stable, unique identifier (derived from the layout's directory + a dedup
/// index) used to name generated modules.
pub const LayoutRef = struct {
    file: []u8,
    load_file: ?[]u8 = null,
    name: []u8,

    pub fn deinit(self: *LayoutRef, allocator: std.mem.Allocator) void {
        allocator.free(self.file);
        if (self.load_file) |load_file| allocator.free(load_file);
        allocator.free(self.name);
    }
};

pub const RoutePattern = struct {
    file: []u8,
    load_file: ?[]u8 = null,
    actions_file: ?[]u8 = null,
    options_file: ?[]u8 = null,
    options: RouteOptions = .{},
    path: []u8,
    shape: []u8,
    name: []u8,
    groups: [][]u8,
    segments: []Segment,
    score: usize,
    /// Layout chain wrapping this page, outermost (root) to innermost. Resolved
    /// by discovery from the filesystem; empty for a route with no layouts.
    layouts: []LayoutRef = &.{},

    pub fn deinit(self: *RoutePattern, allocator: std.mem.Allocator) void {
        allocator.free(self.file);
        if (self.load_file) |load_file| allocator.free(load_file);
        if (self.actions_file) |actions_file| allocator.free(actions_file);
        if (self.options_file) |options_file| allocator.free(options_file);
        allocator.free(self.path);
        allocator.free(self.shape);
        allocator.free(self.name);
        for (self.groups) |group| allocator.free(group);
        allocator.free(self.groups);
        for (self.segments) |segment| allocator.free(segment.name);
        allocator.free(self.segments);
        for (self.layouts) |*layout| layout.deinit(allocator);
        allocator.free(self.layouts);
    }
};

pub fn parseRouteFile(allocator: std.mem.Allocator, file: []const u8) !RoutePattern {
    const marker = "src/routes/";
    var rel = if (std.mem.indexOf(u8, file, marker)) |idx| file[idx + marker.len ..] else file;
    if (std.mem.endsWith(u8, rel, "+page.yn")) rel = rel[0 .. rel.len - "+page.yn".len];
    rel = std.mem.trim(u8, rel, "/");

    var groups: std.ArrayList([]u8) = .empty;
    var segments: std.ArrayList(Segment) = .empty;
    errdefer {
        for (groups.items) |group| allocator.free(group);
        groups.deinit(allocator);
        for (segments.items) |segment| allocator.free(segment.name);
        segments.deinit(allocator);
    }

    if (rel.len > 0) {
        var parts = std.mem.splitScalar(u8, rel, '/');
        while (parts.next()) |part| {
            if (part.len == 0) continue;
            if (isRouteGroup(part)) {
                try groups.append(allocator, try allocator.dupe(u8, part[1 .. part.len - 1]));
                continue;
            }
            if (part[0] == '(' or part[part.len - 1] == ')') return error.InvalidRouteGroup;
            try segments.append(allocator, try parseSegment(allocator, part));
        }
    }
    if (segments.items.len > 0) {
        for (segments.items[0 .. segments.items.len - 1]) |segment| {
            if (segment.kind == .rest) return error.InvalidRouteRest;
        }
    }

    const owned_groups = try groups.toOwnedSlice(allocator);
    const owned_segments = try segments.toOwnedSlice(allocator);
    errdefer {
        for (owned_groups) |group| allocator.free(group);
        allocator.free(owned_groups);
        for (owned_segments) |segment| allocator.free(segment.name);
        allocator.free(owned_segments);
    }

    return .{
        .file = try allocator.dupe(u8, file),
        .load_file = null,
        .actions_file = null,
        .options_file = null,
        .options = .{},
        .path = try buildPublicPath(allocator, owned_segments),
        .shape = try buildShape(allocator, owned_segments),
        .name = try buildRouteName(allocator, owned_segments),
        .groups = owned_groups,
        .segments = owned_segments,
        .score = routeScore(owned_segments),
    };
}

pub fn sortRoutes(routes: []RoutePattern) void {
    std.mem.sort(RoutePattern, routes, {}, struct {
        fn lessThan(_: void, a: RoutePattern, b: RoutePattern) bool {
            if (a.score == b.score) return a.path.len > b.path.len;
            return a.score > b.score;
        }
    }.lessThan);
}

pub fn hasDuplicateShapes(routes: []const RoutePattern) bool {
    for (routes, 0..) |a, i| {
        for (routes[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.shape, b.shape)) return true;
        }
    }
    return false;
}

pub fn hasDuplicateNames(routes: []const RoutePattern) bool {
    for (routes, 0..) |a, i| {
        for (routes[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.name, b.name)) return true;
        }
    }
    return false;
}

pub fn matchesStaticPath(route: RoutePattern, path: []const u8) bool {
    const clean = stripQueryHash(path);
    if (std.mem.eql(u8, clean, "/")) {
        return route.segments.len == 0 or (route.segments.len == 1 and route.segments[0].kind == .rest);
    }
    var count: usize = 0;
    var parts = std.mem.splitScalar(u8, std.mem.trim(u8, clean, "/"), '/');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        if (count >= route.segments.len) return false;
        const segment = route.segments[count];
        if (segment.kind == .static and !std.mem.eql(u8, segment.name, part)) return false;
        if (segment.kind == .rest) return true;
        if (segment.kind == .dynamic) {
            switch (segment.param_type.?) {
                .string => {},
                .int => _ = std.fmt.parseInt(i64, part, 10) catch return false,
                .uint => _ = std.fmt.parseInt(u64, part, 10) catch return false,
            }
        }
        count += 1;
    }
    if (count == route.segments.len) return true;
    return count + 1 == route.segments.len and route.segments[count].kind == .rest;
}

pub fn anyRouteMatchesStaticPath(routes: []const RoutePattern, path: []const u8) bool {
    for (routes) |route| {
        if (matchesStaticPath(route, path)) return true;
    }
    return false;
}

pub fn generateZigRoutes(allocator: std.mem.Allocator, routes: []const RoutePattern) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator,
        \\const std = @import("std");
        \\const database = @import("database");
        \\
        \\pub const RouteName = enum {
        \\
    );
    for (routes) |route| try out.print(allocator, "    {s},\n", .{route.name});
    try out.appendSlice(allocator,
        \\};
        \\
        \\pub const Route = union(enum) {
        \\
    );
    for (routes) |route| try writeUnionField(allocator, &out, route);
    try out.appendSlice(allocator,
        \\};
        \\
        \\pub const Match = union(enum) {
        \\
    );
    for (routes) |route| try writeUnionField(allocator, &out, route);
    try out.appendSlice(allocator,
        \\};
        \\
        \\pub const Prerender = enum { auto, always, never };
        \\pub const TrailingSlash = enum { ignore, always, never };
        \\
        \\pub const PageOptions = struct {
        \\    prerender: Prerender = .auto,
        \\    csr: bool = true,
        \\    trailing_slash: TrailingSlash = .ignore,
        \\};
        \\
        \\pub const RouteMeta = struct {
        \\    name: RouteName,
        \\    path: []const u8,
        \\    groups: []const []const u8 = &.{},
        \\    options: PageOptions,
        \\};
        \\
        \\pub const route_meta = [_]RouteMeta{
        \\
    );
    for (routes) |route| {
        try out.print(allocator, "    .{{ .name = .{s}, .path = \"{s}\", .groups = ", .{ route.name, route.path });
        try writeGroupsLiteral(allocator, &out, route.groups);
        try out.appendSlice(allocator, ", .options = ");
        try writeOptionsLiteral(allocator, &out, route.options);
        try out.appendSlice(allocator, " },\n");
    }
    try out.appendSlice(allocator,
        \\};
        \\
        \\pub fn pageOptions(route: RouteName) PageOptions {
        \\    return switch (route) {
        \\
    );
    for (routes) |route| {
        try out.print(allocator, "        .{s} => ", .{route.name});
        try writeOptionsLiteral(allocator, &out, route.options);
        try out.appendSlice(allocator, ",\n");
    }
    try out.appendSlice(allocator,
        \\    };
        \\}
        \\
        \\pub const Header = struct {
        \\    name: []const u8,
        \\    value: []const u8,
        \\};
        \\
        \\pub const Status = enum(u16) {
        \\    ok = 200,
        \\    created = 201,
        \\    no_content = 204,
        \\    bad_request = 400,
        \\    unauthorized = 401,
        \\    forbidden = 403,
        \\    not_found = 404,
        \\    method_not_allowed = 405,
        \\    conflict = 409,
        \\    payload_too_large = 413,
        \\    unprocessable_entity = 422,
        \\    internal_server_error = 500,
        \\};
        \\
        \\pub const ErrorBody = struct {
        \\    message: []const u8,
        \\    code: []const u8,
        \\    id: []const u8 = "",
        \\};
        \\
        \\pub const Response = struct {
        \\    status: Status,
        \\    body: ErrorBody,
        \\    content_type: []const u8 = "application/json; charset=utf-8",
        \\    headers: []const Header = &.{},
        \\};
        \\
        \\pub fn Result(comptime T: type) type {
        \\    return union(enum) {
        \\        pub const __yaan_result = true;
        \\        value: T,
        \\        fail: Response,
        \\    };
        \\}
        \\
        \\pub fn fail(status: Status, code: []const u8, message: []const u8) Response {
        \\    return .{ .status = status, .body = .{ .message = message, .code = code } };
        \\}
        \\
        \\pub fn notFound(message: []const u8) Response {
        \\    return fail(.not_found, "not_found", message);
        \\}
        \\
        \\pub fn badRequest(message: []const u8) Response {
        \\    return fail(.bad_request, "bad_request", message);
        \\}
        \\
        \\pub const Upload = struct {
        \\    name: []const u8,
        \\    filename: []const u8,
        \\    content_type: []const u8,
        \\    path: []const u8,
        \\    size: usize,
        \\};
        \\
        \\pub const RequestMeta = struct {
        \\    secure: bool = false,
        \\    csrf_protection: bool = false,
        \\    cookie_secret: []const u8 = "",
        \\};
        \\
        \\pub const Request = struct {
        \\    method: []const u8,
        \\    path: []const u8,
        \\    query: []const u8 = "",
        \\    headers: []const Header = &.{},
        \\    body: []const u8 = "",
        \\    uploads: []const Upload = &.{},
        \\    meta: RequestMeta = .{},
        \\
        \\    pub fn upload(self: Request, name: []const u8) ?Upload {
        \\        for (self.uploads) |item| {
        \\            if (std.mem.eql(u8, item.name, name)) return item;
        \\        }
        \\        return null;
        \\    }
        \\
        \\    pub fn header(self: Request, name: []const u8) ?[]const u8 {
        \\        for (self.headers) |item| {
        \\            if (std.ascii.eqlIgnoreCase(item.name, name)) return item.value;
        \\        }
        \\        return null;
        \\    }
        \\
        \\    pub fn cookie(self: Request, name: []const u8) ?[]const u8 {
        \\        const raw = self.header("cookie") orelse return null;
        \\        var parts = std.mem.splitScalar(u8, raw, ';');
        \\        while (parts.next()) |part| {
        \\            const trimmed = std.mem.trim(u8, part, " \t");
        \\            const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        \\            if (std.mem.eql(u8, trimmed[0..eq], name)) return trimmed[eq + 1 ..];
        \\        }
        \\        return null;
        \\    }
        \\
        \\    pub fn signedCookie(self: Request, allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
        \\        const raw = self.cookie(name) orelse return null;
        \\        return try verifySignedCookie(allocator, name, raw, self.meta.cookie_secret);
        \\    }
        \\};
        \\
        \\pub const CookieOptions = struct {
        \\    path: []const u8 = "/",
        \\    http_only: bool = true,
        \\    same_site: []const u8 = "Lax",
        \\    secure: bool = false,
        \\    max_age: ?u32 = null,
        \\};
        \\
        \\pub fn setCookie(allocator: std.mem.Allocator, name: []const u8, value: []const u8, options: CookieOptions) !Header {
        \\    var out: std.ArrayList(u8) = .empty;
        \\    try out.print(allocator, "{s}={s}; Path={s}; SameSite={s}", .{ name, value, options.path, options.same_site });
        \\    if (options.http_only) try out.appendSlice(allocator, "; HttpOnly");
        \\    if (options.secure) try out.appendSlice(allocator, "; Secure");
        \\    if (options.max_age) |age| try out.print(allocator, "; Max-Age={d}", .{age});
        \\    return .{ .name = "set-cookie", .value = try out.toOwnedSlice(allocator) };
        \\}
        \\
        \\pub fn clearCookie(allocator: std.mem.Allocator, name: []const u8, secure: bool) !Header {
        \\    return setCookie(allocator, name, "", .{ .secure = secure, .max_age = 0 });
        \\}
        \\
        \\pub fn signedCookieHeader(allocator: std.mem.Allocator, request: Request, name: []const u8, value: []const u8) !Header {
        \\    const signed = try signedCookieValue(allocator, name, value, request.meta.cookie_secret);
        \\    return setCookie(allocator, name, signed, .{ .secure = request.meta.secure });
        \\}
        \\
        \\pub const CsrfPair = struct {
        \\    header: Header,
        \\    token: []const u8,
        \\};
        \\
        \\pub fn csrfPair(allocator: std.mem.Allocator, request: Request) !CsrfPair {
        \\    var random_bytes: [24]u8 = undefined;
        \\    std.crypto.random.bytes(&random_bytes);
        \\    const nonce = try base64Encode(allocator, &random_bytes);
        \\    defer allocator.free(nonce);
        \\    const signed = try signedCookieValue(allocator, "yaan_csrf", nonce, request.meta.cookie_secret);
        \\    const header = try setCookie(allocator, "yaan_csrf", signed, .{ .secure = request.meta.secure });
        \\    return .{ .header = header, .token = signed };
        \\}
        \\
        \\pub fn signedCookieValue(allocator: std.mem.Allocator, name: []const u8, value: []const u8, secret: []const u8) ![]u8 {
        \\    if (secret.len == 0) return error.MissingCookieSecret;
        \\    const encoded_value = try base64Encode(allocator, value);
        \\    defer allocator.free(encoded_value);
        \\    const signed_part = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ name, encoded_value });
        \\    defer allocator.free(signed_part);
        \\    var mac: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
        \\    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, signed_part, secret);
        \\    const encoded_mac = try base64Encode(allocator, &mac);
        \\    defer allocator.free(encoded_mac);
        \\    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ encoded_value, encoded_mac });
        \\}
        \\
        \\pub fn verifySignedCookie(allocator: std.mem.Allocator, name: []const u8, signed_value: []const u8, secret: []const u8) !?[]u8 {
        \\    if (secret.len == 0) return error.MissingCookieSecret;
        \\    const dot = std.mem.lastIndexOfScalar(u8, signed_value, '.') orelse return null;
        \\    const encoded_value = signed_value[0..dot];
        \\    const encoded_mac = signed_value[dot + 1 ..];
        \\    const signed_part = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ name, encoded_value });
        \\    defer allocator.free(signed_part);
        \\    var expected: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
        \\    std.crypto.auth.hmac.sha2.HmacSha256.create(&expected, signed_part, secret);
        \\    const actual = base64Decode(allocator, encoded_mac) catch return null;
        \\    defer allocator.free(actual);
        \\    if (actual.len != expected.len) return null;
        \\    var actual_array: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
        \\    @memcpy(actual_array[0..], actual);
        \\    if (!std.crypto.timing_safe.eql([std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8, actual_array, expected)) return null;
        \\    return base64Decode(allocator, encoded_value) catch return null;
        \\}
        \\
        \\fn base64Encode(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
        \\    const encoder = std.base64.url_safe_no_pad.Encoder;
        \\    const out = try allocator.alloc(u8, encoder.calcSize(value.len));
        \\    _ = encoder.encode(out, value);
        \\    return out;
        \\}
        \\
        \\fn base64Decode(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
        \\    const decoder = std.base64.url_safe_no_pad.Decoder;
        \\    const size = try decoder.calcSizeForSlice(value);
        \\    const out = try allocator.alloc(u8, size);
        \\    errdefer allocator.free(out);
        \\    try decoder.decode(out, value);
        \\    return out;
        \\}
        \\
        \\pub const TraceValue = union(enum) {
        \\    string: []const u8,
        \\    int: i64,
        \\    bool: bool,
        \\};
        \\
        \\pub const TraceSpan = struct {
        \\    trace_id: []const u8 = "",
        \\    span_id: []const u8 = "",
        \\
        \\    pub fn setAttribute(self: *TraceSpan, key: []const u8, value: TraceValue) void {
        \\        _ = self;
        \\        _ = key;
        \\        _ = value;
        \\    }
        \\};
        \\
        \\pub const Tracing = struct {
        \\    root: TraceSpan = .{},
        \\    current: TraceSpan = .{},
        \\
        \\    pub fn setAttribute(self: *Tracing, key: []const u8, value: TraceValue) void {
        \\        self.current.setAttribute(key, value);
        \\    }
        \\};
        \\
        \\pub fn Params(comptime route: RouteName) type {
        \\    return switch (route) {
        \\
    );
    for (routes) |route| try writeParamsCase(allocator, &out, route);
    try out.appendSlice(allocator,
        \\    };
        \\}
        \\
        \\pub fn LoadContext(comptime route: RouteName) type {
        \\    return struct {
        \\        allocator: std.mem.Allocator,
        \\        params: Params(route),
        \\        request: Request,
        \\        db: ?database.Database = null,
        \\        tracing: Tracing = .{},
        \\    };
        \\}
        \\
        \\pub fn ActionContext(comptime route: RouteName) type {
        \\    return struct {
        \\        allocator: std.mem.Allocator,
        \\        params: Params(route),
        \\        request: Request,
        \\        db: ?database.Database = null,
        \\        tracing: Tracing = .{},
        \\    };
        \\}
        \\
        \\pub fn href(allocator: std.mem.Allocator, route: Route) ![]u8 {
        \\    var out: std.ArrayList(u8) = .empty;
        \\    switch (route) {
        \\
    );
    for (routes) |route| try writeHrefCase(allocator, &out, route);
    try out.appendSlice(allocator,
        \\    }
        \\    return out.toOwnedSlice(allocator);
        \\}
        \\
        \\pub fn match(path: []const u8, allocator: std.mem.Allocator) !?Match {
        \\    const clean = stripQueryHash(path);
        \\    const trimmed = std.mem.trim(u8, clean, "/");
        \\    const segs = try splitPath(allocator, trimmed);
        \\    defer allocator.free(segs);
        \\
    );
    for (routes) |route| try writeMatchCase(allocator, &out, route);
    try out.appendSlice(allocator,
        \\    return null;
        \\}
        \\
        \\fn splitPath(allocator: std.mem.Allocator, path: []const u8) ![][]const u8 {
        \\    if (path.len == 0) return allocator.alloc([]const u8, 0);
        \\    var count: usize = 1;
        \\    for (path) |c| {
        \\        if (c == '/') count += 1;
        \\    }
        \\    const segs = try allocator.alloc([]const u8, count);
        \\    var it = std.mem.splitScalar(u8, path, '/');
        \\    var i: usize = 0;
        \\    while (it.next()) |seg| {
        \\        segs[i] = seg;
        \\        i += 1;
        \\    }
        \\    return segs;
        \\}
        \\
        \\fn restTail(path: []const u8, segs: []const []const u8, start: usize) []const u8 {
        \\    if (segs.len <= start) return "";
        \\    const offset = @intFromPtr(segs[start].ptr) - @intFromPtr(path.ptr);
        \\    return path[offset..];
        \\}
        \\
        \\fn stripQueryHash(path: []const u8) []const u8 {
        \\    var end = path.len;
        \\    if (std.mem.indexOfScalar(u8, path, '?')) |i| end = @min(end, i);
        \\    if (std.mem.indexOfScalar(u8, path, '#')) |i| end = @min(end, i);
        \\    return path[0..end];
        \\}
        \\
        \\fn appendEscaped(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
        \\    const hex = "0123456789ABCDEF";
        \\    for (value) |c| {
        \\        if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.' or c == '~') {
        \\            try out.append(allocator, c);
        \\        } else {
        \\            try out.append(allocator, '%');
        \\            try out.append(allocator, hex[c >> 4]);
        \\            try out.append(allocator, hex[c & 15]);
        \\        }
        \\    }
        \\}
        \\
        \\fn appendEscapedPath(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
        \\    var it = std.mem.splitScalar(u8, value, '/');
        \\    var first = true;
        \\    while (it.next()) |part| {
        \\        if (!first) try out.append(allocator, '/');
        \\        first = false;
        \\        try appendEscaped(out, allocator, part);
        \\    }
        \\}
        \\
    );
    return out.toOwnedSlice(allocator);
}

/// A unique `+layout.load.zig` and its generated module name. The name is a
/// pure function of the file path (hash-based) so the runner codegen, the
/// subprocess build wiring, and the in-process `build.zig` all agree on it
/// without sharing any ordering or state.
pub const LayoutLoadEntry = struct {
    file: []const u8,
    name: []u8,
};

/// Module/import name for a layout loader, derived solely from its file path.
pub fn layoutLoadName(allocator: std.mem.Allocator, file: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "layout_load_{x}", .{std.hash.Wyhash.hash(0, file)});
}

/// The deduplicated, deterministically-ordered set of layout loaders across all
/// routes. Caller owns the returned slice and each entry's `name`.
pub fn collectLayoutLoads(allocator: std.mem.Allocator, routes: []const RoutePattern) ![]LayoutLoadEntry {
    var list: std.ArrayList(LayoutLoadEntry) = .empty;
    errdefer {
        for (list.items) |entry| allocator.free(entry.name);
        list.deinit(allocator);
    }
    for (routes) |route| {
        for (route.layouts) |layout| {
            const file = layout.load_file orelse continue;
            var seen = false;
            for (list.items) |entry| {
                if (std.mem.eql(u8, entry.file, file)) {
                    seen = true;
                    break;
                }
            }
            if (seen) continue;
            try list.append(allocator, .{ .file = file, .name = try layoutLoadName(allocator, file) });
        }
    }
    std.mem.sort(LayoutLoadEntry, list.items, {}, struct {
        fn lessThan(_: void, a: LayoutLoadEntry, b: LayoutLoadEntry) bool {
            return std.mem.lessThan(u8, a.file, b.file);
        }
    }.lessThan);
    return list.toOwnedSlice(allocator);
}

pub fn freeLayoutLoads(allocator: std.mem.Allocator, entries: []LayoutLoadEntry) void {
    for (entries) |entry| allocator.free(entry.name);
    allocator.free(entries);
}

fn routeHasLayoutLoad(route: RoutePattern) bool {
    for (route.layouts) |layout| {
        if (layout.load_file != null) return true;
    }
    return false;
}

fn firstRouteUsingLayout(routes: []const RoutePattern, file: []const u8) ?RoutePattern {
    for (routes) |route| {
        for (route.layouts) |layout| {
            if (std.mem.eql(u8, layout.file, file)) return route;
        }
    }
    return null;
}

pub fn generateLoadCheck(allocator: std.mem.Allocator, routes: []const RoutePattern) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator,
        \\const std = @import("std");
        \\const routes = @import("routes");
        \\
    );
    for (routes) |route| {
        if (route.load_file != null) {
            try out.print(allocator, "const load_{s} = @import(\"load_{s}\");\n", .{ route.name, route.name });
        }
    }
    const layout_loads = try collectLayoutLoads(allocator, routes);
    defer freeLayoutLoads(allocator, layout_loads);
    for (layout_loads) |entry| {
        try out.print(allocator, "const {s} = @import(\"{s}\");\n", .{ entry.name, entry.name });
    }
    try out.appendSlice(allocator,
        \\
        \\test "route loaders type-check" {
        \\    const allocator = std.testing.allocator;
        \\    const request = routes.Request{ .method = "GET", .path = "/" };
        \\
    );
    var load_index: usize = 0;
    for (routes) |route| {
        if (route.load_file != null) {
            try out.print(allocator,
                \\    const ctx_{d} = routes.LoadContext(.{s}){{ .allocator = allocator, .params =
            , .{ load_index, route.name });
            try writeParamsLiteral(allocator, &out, route);
            try out.print(allocator,
                \\, .request = request }};
                \\    const data_{d} = try load_{s}.load(ctx_{d});
                \\    _ = data_{d};
                \\
            , .{ load_index, route.name, load_index, load_index });
            load_index += 1;
        }
    }
    // Layout loaders are generic over the context; type-check each against a
    // representative route from its chain.
    for (layout_loads, 0..) |entry, i| {
        const rep = firstRouteUsingLayout(routes, layoutFileForLoad(routes, entry.file)) orelse continue;
        try out.print(allocator,
            \\    const lctx_{d} = routes.LoadContext(.{s}){{ .allocator = allocator, .params =
        , .{ i, rep.name });
        try writeParamsLiteral(allocator, &out, rep);
        try out.print(allocator,
            \\, .request = request }};
            \\    const ldata_{d} = try {s}.load(lctx_{d});
            \\    _ = ldata_{d};
            \\
        , .{ i, entry.name, i, i });
    }
    try out.appendSlice(allocator, "}\n");
    return out.toOwnedSlice(allocator);
}

/// The layout component file whose `+layout.load.zig` is `load_file`, so we can
/// find a representative route via its `.file` field.
fn layoutFileForLoad(routes: []const RoutePattern, load_file: []const u8) []const u8 {
    for (routes) |route| {
        for (route.layouts) |layout| {
            if (layout.load_file) |lf| {
                if (std.mem.eql(u8, lf, load_file)) return layout.file;
            }
        }
    }
    return load_file;
}

pub fn generateLoadRunner(allocator: std.mem.Allocator, routes: []const RoutePattern) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator,
        \\const std = @import("std");
        \\const routes = @import("routes");
        \\
    );
    for (routes) |route| {
        if (route.load_file != null) {
            try out.print(allocator, "const load_{s} = @import(\"load_{s}\");\n", .{ route.name, route.name });
        }
    }
    const layout_loads = try collectLayoutLoads(allocator, routes);
    defer freeLayoutLoads(allocator, layout_loads);
    for (layout_loads) |entry| {
        try out.print(allocator, "const {s} = @import(\"{s}\");\n", .{ entry.name, entry.name });
    }
    try out.appendSlice(allocator,
        \\
        \\pub fn run(io: std.Io, allocator: std.mem.Allocator, method: []const u8, path: []const u8, headers_json: []const u8, meta_json: []const u8) ![]u8 {
        \\    _ = io;
        \\    var arena = std.heap.ArenaAllocator.init(allocator);
        \\    defer arena.deinit();
        \\    const a = arena.allocator();
        \\    var out_writer: std.Io.Writer.Allocating = .init(a);
        \\    try dispatch(a, &out_writer.writer, method, path, headers_json, meta_json);
        \\    return try allocator.dupe(u8, out_writer.written());
        \\}
        \\
        \\fn dispatch(allocator: std.mem.Allocator, writer: *std.Io.Writer, method: []const u8, path: []const u8, headers_json: []const u8, meta_json: []const u8) !void {
        \\    const headers = try std.json.parseFromSliceLeaky([]routes.Header, allocator, headers_json, .{});
        \\    const meta = try std.json.parseFromSliceLeaky(routes.RequestMeta, allocator, meta_json, .{});
        \\    const matched = (try routes.match(path, allocator)) orelse {
        \\        try writer.writeAll("null");
        \\        return;
        \\    };
        \\    const request = routes.Request{ .method = method, .path = path, .headers = headers, .meta = meta };
        \\    switch (matched) {
        \\
    );
    for (routes) |route| {
        const has_page_load = route.load_file != null;
        const has_layout_load = routeHasLayoutLoad(route);
        const has_params = paramCount(route) > 0;

        if (!has_layout_load) {
            // No layout data: emit the plain page payload exactly as before.
            if (has_page_load) {
                try writeLoadArmHeader(allocator, &out, route, has_params);
                try out.print(allocator,
                    \\            const data = load_{s}.load(ctx) catch |err| return try writeUnexpected(allocator, writer, err, request);
                    \\            try writeRouteValue(allocator, writer, data);
                    \\        }},
                    \\
                , .{route.name});
            } else if (has_params) {
                try out.print(allocator,
                    \\        .{s} => |params| try std.json.Stringify.value(params, .{{}}, writer),
                    \\
                , .{route.name});
            } else {
                try out.print(allocator,
                    \\        .{s} => try writer.writeAll("{{}}"),
                    \\
                , .{route.name});
            }
            continue;
        }

        // Layout data present: emit the chain envelope the client unwraps into
        // per-level props ({ __yaan_chain, data, layouts: [...] }).
        try writeLoadArmHeader(allocator, &out, route, has_params);
        try out.appendSlice(allocator, "            try writer.writeAll(\"{\\\"__yaan_chain\\\":true,\\\"data\\\":\");\n");
        if (has_page_load) {
            try out.print(allocator,
                \\            const data = load_{s}.load(ctx) catch |err| return try writeUnexpected(allocator, writer, err, request);
                \\            try writeRouteValue(allocator, writer, data);
                \\
            , .{route.name});
        } else if (has_params) {
            try out.appendSlice(allocator, "            try std.json.Stringify.value(params, .{}, writer);\n");
        } else {
            try out.appendSlice(allocator, "            try writer.writeAll(\"{}\");\n");
        }
        try out.appendSlice(allocator, "            try writer.writeAll(\",\\\"layouts\\\":[\");\n");
        for (route.layouts, 0..) |layout, li| {
            if (li > 0) try out.appendSlice(allocator, "            try writer.writeAll(\",\");\n");
            if (layout.load_file) |load_file| {
                const lname = try layoutLoadName(allocator, load_file);
                defer allocator.free(lname);
                try out.print(allocator,
                    \\            const ld{d} = {s}.load(ctx) catch |err| return try writeUnexpected(allocator, writer, err, request);
                    \\            try writeRouteValue(allocator, writer, ld{d});
                    \\
                , .{ li, lname, li });
            } else {
                try out.appendSlice(allocator, "            try writer.writeAll(\"null\");\n");
            }
        }
        try out.appendSlice(allocator, "            try writer.writeAll(\"]}\");\n        },\n");
    }
    try out.appendSlice(allocator,
        \\    }
        \\}
        \\
        \\pub fn main(init: std.process.Init) !void {
        \\    const allocator = init.arena.allocator();
        \\    try @import("env").init(init.environ_map);
        \\    const args = try init.minimal.args.toSlice(allocator);
        \\    if (args.len < 3) return error.InvalidArguments;
        \\    const headers_json = if (args.len >= 4) args[3] else "[]";
        \\    const meta_json = if (args.len >= 5) args[4] else "{}";
        \\    const json = try run(init.io, allocator, args[1], args[2], headers_json, meta_json);
        \\    var stdout_buffer: [8192]u8 = undefined;
        \\    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
        \\    const w = &stdout_file_writer.interface;
        \\    try w.writeAll(json);
        \\    try w.flush();
        \\}
        \\
        \\fn writeRouteValue(allocator: std.mem.Allocator, writer: *std.Io.Writer, value: anytype) !void {
        \\    const T = @TypeOf(value);
        \\    if (T == routes.Response) {
        \\        return try writeResponseEnvelope(allocator, writer, value);
        \\    }
        \\    if (@hasDecl(T, "__yaan_result")) {
        \\        return switch (value) {
        \\            .value => |data| try std.json.Stringify.value(data, .{}, writer),
        \\            .fail => |response| try writeResponseEnvelope(allocator, writer, response),
        \\        };
        \\    }
        \\    try std.json.Stringify.value(value, .{}, writer);
        \\}
        \\
        \\fn writeUnexpected(allocator: std.mem.Allocator, writer: *std.Io.Writer, err: anyerror, request: routes.Request) !void {
        \\    std.debug.print("unexpected load error {s} for {s} {s}\n", .{ @errorName(err), request.method, request.path });
        \\    const id = try errorId(allocator, err, request.path);
        \\    try writeResponseEnvelope(allocator, writer, .{
        \\        .status = .internal_server_error,
        \\        .body = .{ .message = "Internal Error", .code = "internal_error", .id = id },
        \\    });
        \\}
        \\
        \\fn writeResponseEnvelope(allocator: std.mem.Allocator, writer: *std.Io.Writer, response: routes.Response) !void {
        \\    var body_writer: std.Io.Writer.Allocating = .init(allocator);
        \\    defer body_writer.deinit();
        \\    try std.json.Stringify.value(response.body, .{}, &body_writer.writer);
        \\    try writer.writeAll("{\"__yaan_response\":true,\"status\":");
        \\    try writer.print("{d}", .{@intFromEnum(response.status)});
        \\    try writer.writeAll(",\"content_type\":");
        \\    try std.json.Stringify.value(response.content_type, .{}, writer);
        \\    try writer.writeAll(",\"headers\":");
        \\    try std.json.Stringify.value(response.headers, .{}, writer);
        \\    try writer.writeAll(",\"body\":");
        \\    try std.json.Stringify.value(body_writer.written(), .{}, writer);
        \\    try writer.writeAll("}");
        \\}
        \\
        \\fn errorId(allocator: std.mem.Allocator, err: anyerror, path: []const u8) ![]const u8 {
        \\    var hasher = std.hash.Wyhash.init(0);
        \\    hasher.update(@errorName(err));
        \\    hasher.update(path);
        \\    return try std.fmt.allocPrint(allocator, "err-{x}", .{hasher.final()});
        \\}
        \\
    );
    return out.toOwnedSlice(allocator);
}

pub fn generateActionCheck(allocator: std.mem.Allocator, routes: []const RoutePattern) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator,
        \\const std = @import("std");
        \\const routes = @import("routes");
        \\
    );
    for (routes) |route| {
        if (route.actions_file != null) {
            try out.print(allocator, "const action_{s} = @import(\"action_{s}\");\n", .{ route.name, route.name });
        }
    }
    try out.appendSlice(allocator,
        \\
        \\test "route actions type-check" {
        \\
    );
    var action_index: usize = 0;
    for (routes) |route| {
        if (route.actions_file != null) {
            try out.print(allocator,
                \\    const action_fn_{d} = action_{s}.action;
                \\    _ = action_fn_{d};
                \\    const form_type_{d}: type = action_{s}.Form;
                \\    _ = form_type_{d};
                \\
            , .{ action_index, route.name, action_index, action_index, route.name, action_index });
            action_index += 1;
        }
    }
    try out.appendSlice(allocator, "}\n");
    return out.toOwnedSlice(allocator);
}

pub fn generateActionRunner(allocator: std.mem.Allocator, routes: []const RoutePattern) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator,
        \\const std = @import("std");
        \\const routes = @import("routes");
        \\
    );
    for (routes) |route| {
        if (route.actions_file != null) {
            try out.print(allocator, "const action_{s} = @import(\"action_{s}\");\n", .{ route.name, route.name });
        }
    }
    try out.appendSlice(allocator,
        \\
        \\pub fn run(io: std.Io, allocator: std.mem.Allocator, method: []const u8, path: []const u8, body: []const u8, uploads_json: []const u8, headers_json: []const u8, meta_json: []const u8) ![]u8 {
        \\    _ = io;
        \\    var arena = std.heap.ArenaAllocator.init(allocator);
        \\    defer arena.deinit();
        \\    const a = arena.allocator();
        \\    var out_writer: std.Io.Writer.Allocating = .init(a);
        \\    try dispatch(a, &out_writer.writer, method, path, body, uploads_json, headers_json, meta_json);
        \\    return try allocator.dupe(u8, out_writer.written());
        \\}
        \\
        \\fn dispatch(allocator: std.mem.Allocator, writer: *std.Io.Writer, method: []const u8, path: []const u8, body: []const u8, uploads_json: []const u8, headers_json: []const u8, meta_json: []const u8) !void {
        \\    const uploads = try std.json.parseFromSliceLeaky([]routes.Upload, allocator, uploads_json, .{});
        \\    const headers = try std.json.parseFromSliceLeaky([]routes.Header, allocator, headers_json, .{});
        \\    const meta = try std.json.parseFromSliceLeaky(routes.RequestMeta, allocator, meta_json, .{});
        \\    const matched = (try routes.match(path, allocator)) orelse {
        \\        try writeResponseEnvelope(allocator, writer, routes.notFound("Route not found"));
        \\        return;
        \\    };
        \\    const request = routes.Request{ .method = method, .path = path, .body = body, .uploads = uploads, .headers = headers, .meta = meta };
        \\    switch (matched) {
        \\
    );
    for (routes) |route| {
        if (route.actions_file != null) {
            if (paramCount(route) == 0) {
                try out.print(allocator,
                    \\        .{s} => {{
                    \\            const form = parseForm(action_{s}.Form, allocator, request) catch |err| return try writeUnexpected(allocator, writer, err, request);
                    \\            const ctx = routes.ActionContext(.{s}){{ .allocator = allocator, .params = .{{}}
                , .{ route.name, route.name, route.name });
            } else {
                try out.print(allocator,
                    \\        .{s} => |params| {{
                    \\            const form = parseForm(action_{s}.Form, allocator, request) catch |err| return try writeUnexpected(allocator, writer, err, request);
                    \\            const ctx = routes.ActionContext(.{s}){{ .allocator = allocator, .params =
                , .{ route.name, route.name, route.name });
                try writeParamsFromValue(allocator, &out, route, "params");
            }
            try out.print(allocator,
                \\, .request = request }};
                \\            const result = action_{s}.action(ctx, form) catch |err| return try writeUnexpected(allocator, writer, err, request);
                \\            try writeRouteValue(allocator, writer, result);
                \\        }},
                \\
            , .{route.name});
        } else {
            if (paramCount(route) == 0) {
                try out.print(allocator,
                    \\        .{s} => try writeResponseEnvelope(allocator, writer, routes.fail(.not_found, "no_action", "No action for route")),
                    \\
                , .{route.name});
            } else {
                try out.print(allocator,
                    \\        .{s} => try writeResponseEnvelope(allocator, writer, routes.fail(.not_found, "no_action", "No action for route")),
                    \\
                , .{route.name});
            }
        }
    }
    try out.appendSlice(allocator,
        \\    }
        \\}
        \\
        \\pub fn main(init: std.process.Init) !void {
        \\    const allocator = init.arena.allocator();
        \\    try @import("env").init(init.environ_map);
        \\    const args = try init.minimal.args.toSlice(allocator);
        \\    if (args.len < 4) return error.InvalidArguments;
        \\    const uploads_json = if (args.len >= 5) args[4] else "[]";
        \\    const headers_json = if (args.len >= 6) args[5] else "[]";
        \\    const meta_json = if (args.len >= 7) args[6] else "{}";
        \\    const json = try run(init.io, allocator, args[1], args[2], args[3], uploads_json, headers_json, meta_json);
        \\    var stdout_buffer: [8192]u8 = undefined;
        \\    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
        \\    const w = &stdout_file_writer.interface;
        \\    try w.writeAll(json);
        \\    try w.flush();
        \\}
        \\
        \\fn writeRouteValue(allocator: std.mem.Allocator, writer: *std.Io.Writer, value: anytype) !void {
        \\    const T = @TypeOf(value);
        \\    if (T == routes.Response) {
        \\        return try writeResponseEnvelope(allocator, writer, value);
        \\    }
        \\    if (@hasDecl(T, "__yaan_result")) {
        \\        return switch (value) {
        \\            .value => |data| try std.json.Stringify.value(data, .{}, writer),
        \\            .fail => |response| try writeResponseEnvelope(allocator, writer, response),
        \\        };
        \\    }
        \\    try std.json.Stringify.value(value, .{}, writer);
        \\}
        \\
        \\fn writeUnexpected(allocator: std.mem.Allocator, writer: *std.Io.Writer, err: anyerror, request: routes.Request) !void {
        \\    std.debug.print("unexpected action error {s} for {s} {s}\n", .{ @errorName(err), request.method, request.path });
        \\    const id = try errorId(allocator, err, request.path);
        \\    try writeResponseEnvelope(allocator, writer, .{
        \\        .status = .internal_server_error,
        \\        .body = .{ .message = "Internal Error", .code = "internal_error", .id = id },
        \\    });
        \\}
        \\
        \\fn writeResponseEnvelope(allocator: std.mem.Allocator, writer: *std.Io.Writer, response: routes.Response) !void {
        \\    var body_writer: std.Io.Writer.Allocating = .init(allocator);
        \\    defer body_writer.deinit();
        \\    try std.json.Stringify.value(response.body, .{}, &body_writer.writer);
        \\    try writer.writeAll("{\"__yaan_response\":true,\"status\":");
        \\    try writer.print("{d}", .{@intFromEnum(response.status)});
        \\    try writer.writeAll(",\"content_type\":");
        \\    try std.json.Stringify.value(response.content_type, .{}, writer);
        \\    try writer.writeAll(",\"headers\":");
        \\    try std.json.Stringify.value(response.headers, .{}, writer);
        \\    try writer.writeAll(",\"body\":");
        \\    try std.json.Stringify.value(body_writer.written(), .{}, writer);
        \\    try writer.writeAll("}");
        \\}
        \\
        \\fn errorId(allocator: std.mem.Allocator, err: anyerror, path: []const u8) ![]const u8 {
        \\    var hasher = std.hash.Wyhash.init(0);
        \\    hasher.update(@errorName(err));
        \\    hasher.update(path);
        \\    return try std.fmt.allocPrint(allocator, "err-{x}", .{hasher.final()});
        \\}
        \\
        \\fn parseForm(comptime T: type, allocator: std.mem.Allocator, request: routes.Request) !T {
        \\    var result: T = undefined;
        \\    inline for (@typeInfo(T).@"struct".fields) |field| {
        \\        if (comptime field.type == routes.Upload) {
        \\            @field(result, field.name) = request.upload(field.name) orelse return error.MissingFormField;
        \\        } else if (comptime isOptionalUpload(field.type)) {
        \\            @field(result, field.name) = request.upload(field.name);
        \\        } else if (try formValue(allocator, request.body, field.name)) |raw| {
        \\            @field(result, field.name) = try parseFormValue(field.type, raw);
        \\        } else {
        \\            @field(result, field.name) = try missingFormValue(field.type);
        \\        }
        \\    }
        \\    return result;
        \\}
        \\
        \\fn isOptionalUpload(comptime T: type) bool {
        \\    return switch (@typeInfo(T)) {
        \\        .optional => |opt| opt.child == routes.Upload,
        \\        else => false,
        \\    };
        \\}
        \\
        \\fn parseFormValue(comptime T: type, raw: []u8) !T {
        \\    switch (@typeInfo(T)) {
        \\        .pointer => {
        \\            if (T == []const u8 or T == []u8) return raw;
        \\            return error.UnsupportedFormField;
        \\        },
        \\        .int => return std.fmt.parseInt(T, raw, 10),
        \\        .bool => return std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "1") or std.mem.eql(u8, raw, "on"),
        \\        .optional => |opt| {
        \\            if (raw.len == 0) return null;
        \\            return try parseFormValue(opt.child, raw);
        \\        },
        \\        else => return error.UnsupportedFormField,
        \\    }
        \\}
        \\
        \\fn missingFormValue(comptime T: type) !T {
        \\    switch (@typeInfo(T)) {
        \\        .bool => return false,
        \\        .optional => return null,
        \\        else => return error.MissingFormField,
        \\    }
        \\}
        \\
        \\fn formValue(allocator: std.mem.Allocator, body: []const u8, name: []const u8) !?[]u8 {
        \\    var pairs = std.mem.splitScalar(u8, body, '&');
        \\    while (pairs.next()) |pair| {
        \\        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        \\        if (std.mem.eql(u8, pair[0..eq], name)) {
        \\            const raw = if (eq < pair.len) pair[eq + 1 ..] else "";
        \\            return try percentDecode(allocator, raw);
        \\        }
        \\    }
        \\    return null;
        \\}
        \\
        \\fn percentDecode(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
        \\    var out: std.ArrayList(u8) = .empty;
        \\    var i: usize = 0;
        \\    while (i < value.len) {
        \\        if (value[i] == '%' and i + 2 < value.len) {
        \\            const hi = try std.fmt.charToDigit(value[i + 1], 16);
        \\            const lo = try std.fmt.charToDigit(value[i + 2], 16);
        \\            try out.append(allocator, (hi << 4) | lo);
        \\            i += 3;
        \\        } else {
        \\            try out.append(allocator, if (value[i] == '+') ' ' else value[i]);
        \\            i += 1;
        \\        }
        \\    }
        \\    return out.toOwnedSlice(allocator);
        \\}
        \\
    );
    return out.toOwnedSlice(allocator);
}

pub fn generateOptionsCheck(allocator: std.mem.Allocator, routes: []const RoutePattern) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator,
        \\const routes = @import("routes");
        \\
    );
    var options_index: usize = 0;
    for (routes) |route| {
        if (route.options_file != null) {
            try out.print(allocator, "const options_{d} = @import(\"options_{d}\");\n", .{ options_index, options_index });
            options_index += 1;
        }
    }
    try out.appendSlice(allocator,
        \\
        \\test "route page options type-check" {
        \\
    );
    options_index = 0;
    for (routes) |route| {
        if (route.options_file != null) {
            try out.print(allocator,
                \\    const page_options_{d}: routes.PageOptions = options_{d}.options;
                \\    _ = page_options_{d};
                \\
            , .{ options_index, options_index, options_index });
            options_index += 1;
        }
    }
    try out.appendSlice(allocator, "}\n");
    return out.toOwnedSlice(allocator);
}

pub fn generateOptionsRunner(allocator: std.mem.Allocator, routes: []const RoutePattern) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator,
        \\const std = @import("std");
        \\const routes = @import("routes");
        \\
    );
    var options_index: usize = 0;
    for (routes) |route| {
        if (route.options_file != null) {
            try out.print(allocator, "const options_{d} = @import(\"options_{d}\");\n", .{ options_index, options_index });
            options_index += 1;
        }
    }
    try out.appendSlice(allocator,
        \\
        \\pub fn main(init: std.process.Init) !void {
        \\    var stdout_buffer: [8192]u8 = undefined;
        \\    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
        \\    const writer = &stdout_file_writer.interface;
        \\
    );
    options_index = 0;
    for (routes) |route| {
        if (route.options_file != null) {
            try out.print(allocator,
                \\    try writeOptions(writer, "{s}", options_{d}.options);
                \\
            , .{ route.name, options_index });
            options_index += 1;
        } else {
            try out.print(allocator,
                \\    try writeOptions(writer, "{s}", .{{}});
                \\
            , .{route.name});
        }
    }
    try out.appendSlice(allocator,
        \\    try writer.flush();
        \\}
        \\
        \\fn writeOptions(writer: *std.Io.Writer, name: []const u8, options: routes.PageOptions) !void {
        \\    try writer.print("{s}\t{s}\t{}\t{s}\n", .{
        \\        name,
        \\        @tagName(options.prerender),
        \\        options.csr,
        \\        @tagName(options.trailing_slash),
        \\    });
        \\}
        \\
    );
    return out.toOwnedSlice(allocator);
}

/// Emits a load-runner match arm prelude: the arm pattern (capturing `params`
/// for parameterized routes) and the `ctx` binding. Leaves the arm body open.
fn writeLoadArmHeader(allocator: std.mem.Allocator, out: *std.ArrayList(u8), route: RoutePattern, has_params: bool) !void {
    if (!has_params) {
        try out.print(allocator,
            \\        .{s} => {{
            \\            const ctx = routes.LoadContext(.{s}){{ .allocator = allocator, .params = .{{}}
        , .{ route.name, route.name });
    } else {
        try out.print(allocator,
            \\        .{s} => |params| {{
            \\            const ctx = routes.LoadContext(.{s}){{ .allocator = allocator, .params =
        , .{ route.name, route.name });
        try writeParamsFromValue(allocator, out, route, "params");
    }
    try out.appendSlice(allocator, ", .request = request };\n");
}

fn parseSegment(allocator: std.mem.Allocator, part: []const u8) !Segment {
    if (part.len >= 3 and part[0] == '[' and part[part.len - 1] == ']') {
        const body = part[1 .. part.len - 1];
        if (body.len == 0) return error.InvalidRouteParam;
        const is_rest = std.mem.startsWith(u8, body, "...");
        const param_body = if (is_rest) body[3..] else body;
        if (param_body.len == 0) return error.InvalidRouteParam;
        const colon = std.mem.indexOfScalar(u8, param_body, ':');
        const raw_name = if (colon) |i| param_body[0..i] else param_body;
        const raw_type = if (colon) |i| param_body[i + 1 ..] else "string";
        if (!isIdent(raw_name)) return error.InvalidRouteParam;
        const param_type: ParamType = if (std.mem.eql(u8, raw_type, "string"))
            .string
        else if (std.mem.eql(u8, raw_type, "int"))
            .int
        else if (std.mem.eql(u8, raw_type, "uint"))
            .uint
        else
            return error.InvalidRouteParam;
        if (is_rest and param_type != .string) return error.InvalidRouteParam;
        return .{ .kind = if (is_rest) .rest else .dynamic, .name = try allocator.dupe(u8, raw_name), .param_type = param_type };
    }
    if (std.mem.indexOfAny(u8, part, "[]:") != null) return error.InvalidRouteSegment;
    return .{ .kind = .static, .name = try allocator.dupe(u8, part) };
}

fn isRouteGroup(part: []const u8) bool {
    if (part.len < 3) return false;
    if (part[0] != '(' or part[part.len - 1] != ')') return false;
    const name = part[1 .. part.len - 1];
    return name.len > 0 and std.mem.indexOfAny(u8, name, "[]:/()") == null;
}

fn isIdent(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value, 0..) |c, i| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or (i > 0 and c >= '0' and c <= '9');
        if (!ok) return false;
    }
    return true;
}

fn buildPublicPath(allocator: std.mem.Allocator, segments: []const Segment) ![]u8 {
    if (segments.len == 0) return allocator.dupe(u8, "/");
    var out: std.ArrayList(u8) = .empty;
    for (segments) |segment| {
        try out.append(allocator, '/');
        if (segment.kind == .dynamic or segment.kind == .rest) try out.append(allocator, ':');
        try out.appendSlice(allocator, segment.name);
        if (segment.kind == .rest) try out.append(allocator, '*');
    }
    return out.toOwnedSlice(allocator);
}

fn buildShape(allocator: std.mem.Allocator, segments: []const Segment) ![]u8 {
    if (segments.len == 0) return allocator.dupe(u8, "/");
    var out: std.ArrayList(u8) = .empty;
    for (segments) |segment| {
        try out.append(allocator, '/');
        if (segment.kind == .dynamic) {
            try out.appendSlice(allocator, ":_");
        } else if (segment.kind == .rest) {
            try out.appendSlice(allocator, "**");
        } else {
            try out.appendSlice(allocator, segment.name);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn buildRouteName(allocator: std.mem.Allocator, segments: []const Segment) ![]u8 {
    if (segments.len == 0) return allocator.dupe(u8, "home");
    var out: std.ArrayList(u8) = .empty;
    for (segments, 0..) |segment, i| {
        if (i > 0) try out.append(allocator, '_');
        try appendSnake(allocator, &out, segment.name);
    }
    return out.toOwnedSlice(allocator);
}

fn appendSnake(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    var last_was_sep = false;
    for (value) |c| {
        if ((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9')) {
            try out.append(allocator, c);
            last_was_sep = false;
        } else if (c >= 'A' and c <= 'Z') {
            try out.append(allocator, c + 32);
            last_was_sep = false;
        } else if (!last_was_sep) {
            try out.append(allocator, '_');
            last_was_sep = true;
        }
    }
}

fn routeScore(segments: []const Segment) usize {
    if (segments.len == 0) return 1;
    var score: usize = 0;
    for (segments) |segment| {
        score *= 10;
        score += switch (segment.kind) {
            .static => 3,
            .dynamic => 2,
            .rest => 0,
        };
    }
    return score;
}

fn stripQueryHash(path: []const u8) []const u8 {
    var end = path.len;
    if (std.mem.indexOfScalar(u8, path, '?')) |i| end = @min(end, i);
    if (std.mem.indexOfScalar(u8, path, '#')) |i| end = @min(end, i);
    return path[0..end];
}

fn writeUnionField(allocator: std.mem.Allocator, out: *std.ArrayList(u8), route: RoutePattern) !void {
    if (paramCount(route) == 0) {
        try out.print(allocator, "    {s},\n", .{route.name});
        return;
    }
    try out.print(allocator, "    {s}: struct {{ ", .{route.name});
    var first = true;
    for (route.segments) |segment| {
        if (segment.kind == .static) continue;
        if (!first) try out.appendSlice(allocator, ", ");
        first = false;
        try out.print(allocator, "{s}: {s}", .{ segment.name, segment.param_type.?.zigType() });
    }
    try out.appendSlice(allocator, " },\n");
}

fn writeParamsCase(allocator: std.mem.Allocator, out: *std.ArrayList(u8), route: RoutePattern) !void {
    if (paramCount(route) == 0) {
        try out.print(allocator, "        .{s} => struct {{}},\n", .{route.name});
        return;
    }
    try out.print(allocator, "        .{s} => struct {{ ", .{route.name});
    var first = true;
    for (route.segments) |segment| {
        if (segment.kind == .static) continue;
        if (!first) try out.appendSlice(allocator, ", ");
        first = false;
        try out.print(allocator, "{s}: {s}", .{ segment.name, segment.param_type.?.zigType() });
    }
    try out.appendSlice(allocator, " },\n");
}

fn writeParamsLiteral(allocator: std.mem.Allocator, out: *std.ArrayList(u8), route: RoutePattern) !void {
    if (paramCount(route) == 0) {
        try out.appendSlice(allocator, ".{}");
        return;
    }
    try out.appendSlice(allocator, ".{ ");
    var first = true;
    for (route.segments) |segment| {
        if (segment.kind == .static) continue;
        if (!first) try out.appendSlice(allocator, ", ");
        first = false;
        try out.print(allocator, ".{s} = ", .{segment.name});
        switch (segment.param_type.?) {
            .string => if (segment.kind == .rest) try out.appendSlice(allocator, "\"example/path\"") else try out.appendSlice(allocator, "\"example\""),
            .int, .uint => try out.appendSlice(allocator, "1"),
        }
    }
    try out.appendSlice(allocator, " }");
}

fn writeParamsFromValue(allocator: std.mem.Allocator, out: *std.ArrayList(u8), route: RoutePattern, value_name: []const u8) !void {
    if (paramCount(route) == 0) {
        try out.appendSlice(allocator, ".{}");
        return;
    }
    try out.appendSlice(allocator, ".{ ");
    var first = true;
    for (route.segments) |segment| {
        if (segment.kind == .static) continue;
        if (!first) try out.appendSlice(allocator, ", ");
        first = false;
        try out.print(allocator, ".{s} = {s}.{s}", .{ segment.name, value_name, segment.name });
    }
    try out.appendSlice(allocator, " }");
}

fn writeHrefCase(allocator: std.mem.Allocator, out: *std.ArrayList(u8), route: RoutePattern) !void {
    if (paramCount(route) == 0) {
        const href_path = try hrefPathForRoute(allocator, route);
        defer allocator.free(href_path);
        try out.print(allocator, "        .{s} => try out.appendSlice(allocator, \"{s}\"),\n", .{ route.name, href_path });
        return;
    }
    try out.print(allocator, "        .{s} => |p| {{\n", .{route.name});
    if (route.segments.len == 0) {
        try out.appendSlice(allocator, "            try out.appendSlice(allocator, \"/\");\n");
    } else {
        for (route.segments) |segment| {
            if (segment.kind == .static) {
                try out.appendSlice(allocator, "            try out.append(allocator, '/');\n");
                try out.print(allocator, "            try out.appendSlice(allocator, \"{s}\");\n", .{segment.name});
            } else switch (segment.param_type.?) {
                .string => if (segment.kind == .rest) {
                    try out.print(allocator,
                        \\            if (p.{s}.len > 0) {{
                        \\                try out.append(allocator, '/');
                        \\                try appendEscapedPath(&out, allocator, p.{s});
                        \\            }}
                        \\
                    , .{ segment.name, segment.name });
                } else {
                    try out.appendSlice(allocator, "            try out.append(allocator, '/');\n");
                    try out.print(allocator, "            try appendEscaped(&out, allocator, p.{s});\n", .{segment.name});
                },
                .int, .uint => {
                    try out.appendSlice(allocator, "            try out.append(allocator, '/');\n");
                    try out.print(allocator, "            try out.print(allocator, \"{{d}}\", .{{p.{s}}});\n", .{segment.name});
                },
            }
        }
        if (route.options.trailing_slash == .always) {
            try out.appendSlice(allocator, "            try out.append(allocator, '/');\n");
        }
    }
    try out.appendSlice(allocator, "        },\n");
}

fn hrefPathForRoute(allocator: std.mem.Allocator, route: RoutePattern) ![]u8 {
    if (route.options.trailing_slash != .always or std.mem.eql(u8, route.path, "/")) {
        return allocator.dupe(u8, route.path);
    }
    return std.fmt.allocPrint(allocator, "{s}/", .{route.path});
}

fn writeOptionsLiteral(allocator: std.mem.Allocator, out: *std.ArrayList(u8), options: RouteOptions) !void {
    try out.print(allocator, ".{{ .prerender = .{s}, .csr = {}, .trailing_slash = .{s} }}", .{
        @tagName(options.prerender),
        options.csr,
        @tagName(options.trailing_slash),
    });
}

fn writeMatchCase(allocator: std.mem.Allocator, out: *std.ArrayList(u8), route: RoutePattern) !void {
    const rest_index = restSegmentIndex(route);
    if (rest_index) |idx| {
        try out.print(allocator, "    if (segs.len >= {d}", .{idx});
    } else {
        try out.print(allocator, "    if (segs.len == {d}", .{route.segments.len});
    }
    for (route.segments, 0..) |segment, i| {
        if (segment.kind == .static) try out.print(allocator, " and std.mem.eql(u8, segs[{d}], \"{s}\")", .{ i, segment.name });
    }
    try out.appendSlice(allocator, ") {\n");
    for (route.segments, 0..) |segment, i| {
        if (segment.kind == .static or segment.kind == .rest) continue;
        switch (segment.param_type.?) {
            .string => {},
            .int => try out.print(allocator, "        const {s}: ?i64 = std.fmt.parseInt(i64, segs[{d}], 10) catch null;\n        if ({s} == null) return null;\n", .{ segment.name, i, segment.name }),
            .uint => try out.print(allocator, "        const {s}: ?u64 = std.fmt.parseInt(u64, segs[{d}], 10) catch null;\n        if ({s} == null) return null;\n", .{ segment.name, i, segment.name }),
        }
    }
    if (paramCount(route) == 0) {
        try out.print(allocator, "        return .{s};\n", .{route.name});
    } else {
        try out.print(allocator, "        return .{{ .{s} = .{{ ", .{route.name});
        var first = true;
        for (route.segments, 0..) |segment, i| {
            if (segment.kind == .static) continue;
            if (!first) try out.appendSlice(allocator, ", ");
            first = false;
            if (segment.kind == .rest) {
                try out.print(allocator, ".{s} = restTail(trimmed, segs, {d})", .{ segment.name, i });
            } else switch (segment.param_type.?) {
                .string => try out.print(allocator, ".{s} = segs[{d}]", .{ segment.name, i }),
                .int, .uint => try out.print(allocator, ".{s} = {s}.?", .{ segment.name, segment.name }),
            }
        }
        try out.appendSlice(allocator, " } };\n");
    }
    try out.appendSlice(allocator, "    }\n");
}

fn paramCount(route: RoutePattern) usize {
    var count: usize = 0;
    for (route.segments) |segment| {
        if (segment.kind == .dynamic or segment.kind == .rest) count += 1;
    }
    return count;
}

fn restSegmentIndex(route: RoutePattern) ?usize {
    for (route.segments, 0..) |segment, i| {
        if (segment.kind == .rest) return i;
    }
    return null;
}

fn writeGroupsLiteral(allocator: std.mem.Allocator, out: *std.ArrayList(u8), groups: []const []const u8) !void {
    if (groups.len == 0) {
        try out.appendSlice(allocator, "&.{}");
        return;
    }
    try out.appendSlice(allocator, "&.{ ");
    for (groups, 0..) |group, i| {
        if (i > 0) try out.appendSlice(allocator, ", ");
        try out.print(allocator, "\"{s}\"", .{group});
    }
    try out.appendSlice(allocator, " }");
}

test "typed route parsing" {
    var route = try parseRouteFile(std.testing.allocator, "src/routes/users/[id:int]/+page.yn");
    defer route.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("/users/:id", route.path);
    try std.testing.expectEqualStrings("/users/:_", route.shape);
    try std.testing.expectEqualStrings("users_id", route.name);
    try std.testing.expectEqual(ParamType.int, route.segments[1].param_type.?);
}

test "routes prefer static siblings over dynamic" {
    var routes = [_]RoutePattern{
        try parseRouteFile(std.testing.allocator, "src/routes/blog/[slug]/+page.yn"),
        try parseRouteFile(std.testing.allocator, "src/routes/blog/about/+page.yn"),
        try parseRouteFile(std.testing.allocator, "src/routes/blog/[...path]/+page.yn"),
    };
    defer for (&routes) |*route| route.deinit(std.testing.allocator);
    sortRoutes(&routes);
    try std.testing.expectEqualStrings("/blog/about", routes[0].path);
    try std.testing.expectEqualStrings("/blog/:slug", routes[1].path);
    try std.testing.expectEqualStrings("/blog/:path*", routes[2].path);
}

test "route groups are pathless metadata" {
    var route = try parseRouteFile(std.testing.allocator, "src/routes/(app)/dashboard/+page.yn");
    defer route.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("/dashboard", route.path);
    try std.testing.expectEqualStrings("dashboard", route.name);
    try std.testing.expectEqual(@as(usize, 1), route.groups.len);
    try std.testing.expectEqualStrings("app", route.groups[0]);
}

test "rest params parse as final string tails" {
    var route = try parseRouteFile(std.testing.allocator, "src/routes/docs/[...path]/+page.yn");
    defer route.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("/docs/:path*", route.path);
    try std.testing.expectEqualStrings("/docs/**", route.shape);
    try std.testing.expectEqualStrings("docs_path", route.name);
    try std.testing.expectEqual(SegmentKind.rest, route.segments[1].kind);
    try std.testing.expect(matchesStaticPath(route, "/docs"));
    try std.testing.expect(matchesStaticPath(route, "/docs/a/b"));
    try std.testing.expect(!matchesStaticPath(route, "/other/a/b"));
}

test "rest params must be final" {
    try std.testing.expectError(error.InvalidRouteRest, parseRouteFile(std.testing.allocator, "src/routes/docs/[...path]/edit/+page.yn"));
}

test "generated routes contain typed href and match" {
    var routes = [_]RoutePattern{
        try parseRouteFile(std.testing.allocator, "src/routes/+page.yn"),
        try parseRouteFile(std.testing.allocator, "src/routes/users/[id:uint]/+page.yn"),
        try parseRouteFile(std.testing.allocator, "src/routes/(docs)/docs/[...path]/+page.yn"),
    };
    defer for (&routes) |*route| route.deinit(std.testing.allocator);
    sortRoutes(&routes);
    const source = try generateZigRoutes(std.testing.allocator, &routes);
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "users_id: struct { id: u64 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "docs_path: struct { path: []const u8 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, ".groups = &.{ \"docs\" }") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "appendEscapedPath") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "pub fn href") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "pub fn match") != null);
}

test "static path matching respects param types" {
    var route = try parseRouteFile(std.testing.allocator, "src/routes/users/[id:int]/+page.yn");
    defer route.deinit(std.testing.allocator);
    try std.testing.expect(matchesStaticPath(route, "/users/42"));
    try std.testing.expect(!matchesStaticPath(route, "/users/nope"));
}
