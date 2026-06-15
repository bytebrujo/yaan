//! Prototype: an in-process, tower-style request/response foundation.
//!
//! This module is a standalone proof-of-concept for the architecture discussed
//! in the review — it does NOT replace Yaan's current subprocess runners, it
//! shows what the "request/response foundation" would look like if user code
//! were linked into the server instead of spawned as separate executables.
//!
//! It prototypes all five gaps:
//!   1. Composable layers — `Server(Locals, .{ Logger, Auth, RateLimit }, Router)`
//!      monomorphizes an ordered chain at comptime, each layer gets `next()`,
//!      and short-circuit is an explicit tagged return (`Outcome.halt`).
//!   2. Unified tagged halt — handlers return `Result(T)` (ok | halt), no
//!      exceptions used for control flow.
//!   3. First-class route guards — a per-route `guard` runs after match and
//!      before the handler, with the matched params already in the context.
//!   4. Response builder on the context — layers mutate `ctx.response` on the
//!      way in AND on the way out (post-processing after `next`).
//!   5. Process model — everything runs in-process as a pure
//!      request-in/response-out function; no socket, no subprocess.

const std = @import("std");

pub const Header = struct { name: []const u8, value: []const u8 };
pub const Param = struct { name: []const u8, value: []const u8 };

/// Request-in. Params are filled by the router once a route matches.
pub const Request = struct {
    method: []const u8 = "GET",
    path: []const u8 = "/",
    query: []const u8 = "",
    body: []const u8 = "",
    headers: []const Header = &.{},
    params: []const Param = &.{},

    pub fn header(self: Request, name: []const u8) ?[]const u8 {
        for (self.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }

    pub fn param(self: Request, name: []const u8) ?[]const u8 {
        for (self.params) |p| {
            if (std.mem.eql(u8, p.name, name)) return p.value;
        }
        return null;
    }
};

/// Gap #4: a mutable response builder threaded through the context, so layers
/// and handlers can shape the response on the way in and the way out.
pub const Response = struct {
    allocator: std.mem.Allocator,
    status: u16 = 200,
    content_type: []const u8 = "text/plain; charset=utf-8",
    location: ?[]const u8 = null,
    headers: std.ArrayList(Header) = .empty,
    body: []const u8 = "",

    pub fn setHeader(self: *Response, name: []const u8, value: []const u8) !void {
        try self.headers.append(self.allocator, .{ .name = name, .value = value });
    }

    pub fn redirect(self: *Response, status: u16, location: []const u8) void {
        self.status = status;
        self.location = location;
        self.body = "";
    }

    pub fn text(self: *Response, status: u16, body: []const u8) void {
        self.status = status;
        self.content_type = "text/plain; charset=utf-8";
        self.body = body;
    }

    pub fn json(self: *Response, status: u16, body: []const u8) void {
        self.status = status;
        self.content_type = "application/json; charset=utf-8";
        self.body = body;
    }
};

/// Gap #2: the request-scoped context — request, response builder, allocator,
/// and typed per-request state (`locals`). No globals; everything is threaded.
pub fn Context(comptime Locals: type) type {
    return struct {
        allocator: std.mem.Allocator,
        request: Request,
        response: *Response,
        locals: Locals,
    };
}

/// Gap #1/#2: explicit, tagged control flow. A layer returns `.halt` to
/// short-circuit (the response builder already holds the response) or `.done`
/// to indicate the chain ran to completion. Never panics or uses errors for
/// ordinary flow control.
pub const Outcome = enum { done, halt };

/// Gap #2: handlers return a typed result rather than throwing — `.ok` carries
/// the value to render, `.halt` means the response builder is already set.
pub fn Result(comptime T: type) type {
    return union(enum) {
        ok: T,
        halt,
    };
}

// --- comptime middleware composition (gap #1) -------------------------------

/// One link in the monomorphized chain: runs layer `i`, handing it a `next`
/// that recurses into link `i + 1`; the final link calls the terminal handler.
fn Link(comptime Ctx: type, comptime layers: anytype, comptime Terminal: type, comptime i: usize) type {
    return struct {
        pub fn run(_: @This(), ctx: *Ctx) anyerror!Outcome {
            if (comptime i == layers.len) {
                return Terminal.handle(ctx);
            } else {
                const next = Link(Ctx, layers, Terminal, i + 1){};
                return layers[i].handle(ctx, next);
            }
        }
    };
}

/// Composes an ordered tuple of layer types and a terminal handler into a
/// single monomorphized function. `layers` is a tuple like `.{ Logger, Auth }`
/// where each element is a type exposing
/// `pub fn handle(ctx: *Ctx, next: anytype) !Outcome`.
pub fn Pipeline(comptime Ctx: type, comptime layers: anytype, comptime Terminal: type) type {
    return struct {
        pub fn run(ctx: *Ctx) anyerror!Outcome {
            const chain = Link(Ctx, layers, Terminal, 0){};
            return chain.run(ctx);
        }
    };
}

// --- router with first-class route guards (gap #3) --------------------------

pub fn Route(comptime Ctx: type) type {
    return struct {
        method: []const u8 = "GET",
        pattern: []const u8,
        /// Runs after the route matches (params available) and before the
        /// handler. Returning `.halt` blocks the handler.
        guard: ?*const fn (*Ctx) anyerror!Outcome = null,
        handler: *const fn (*Ctx) anyerror!Outcome,
    };
}

/// Terminal handler: matches the request against a comptime route table,
/// fills params, runs the route guard, then the handler.
pub fn Router(comptime Ctx: type, comptime routes: []const Route(Ctx)) type {
    return struct {
        pub fn handle(ctx: *Ctx) anyerror!Outcome {
            inline for (routes) |route| {
                if (std.mem.eql(u8, route.method, ctx.request.method)) {
                    if (try matchRoute(ctx.allocator, route.pattern, ctx.request.path)) |params| {
                        ctx.request.params = params;
                        if (route.guard) |guard| {
                            if (try guard(ctx) == .halt) return .halt;
                        }
                        return route.handler(ctx);
                    }
                }
            }
            ctx.response.text(404, "not found");
            return .done;
        }
    };
}

/// Matches `path` against a `/a/:b/c`-style pattern, returning the captured
/// params (caller-owned) or null. Allocations come from the per-request arena.
fn matchRoute(allocator: std.mem.Allocator, pattern: []const u8, path: []const u8) !?[]Param {
    if (std.mem.eql(u8, pattern, "/")) {
        return if (std.mem.eql(u8, path, "/")) try allocator.alloc(Param, 0) else null;
    }
    var params: std.ArrayList(Param) = .empty;
    errdefer params.deinit(allocator);
    var pat_it = std.mem.tokenizeScalar(u8, pattern, '/');
    var path_it = std.mem.tokenizeScalar(u8, path, '/');
    while (pat_it.next()) |seg| {
        const actual = path_it.next() orelse {
            params.deinit(allocator);
            return null;
        };
        if (seg.len > 0 and seg[0] == ':') {
            try params.append(allocator, .{ .name = seg[1..], .value = actual });
        } else if (!std.mem.eql(u8, seg, actual)) {
            params.deinit(allocator);
            return null;
        }
    }
    if (path_it.next() != null) {
        params.deinit(allocator);
        return null;
    }
    return try params.toOwnedSlice(allocator);
}

// --- in-process driver (gap #5) ---------------------------------------------

/// A response copied out of the per-request arena so callers can inspect it
/// after the request scope is torn down.
pub const Rendered = struct {
    allocator: std.mem.Allocator,
    status: u16,
    content_type: []u8,
    body: []u8,
    headers: []Header,

    pub fn header(self: Rendered, name: []const u8) ?[]const u8 {
        for (self.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }

    pub fn deinit(self: *Rendered) void {
        for (self.headers) |h| {
            self.allocator.free(h.name);
            self.allocator.free(h.value);
        }
        self.allocator.free(self.headers);
        self.allocator.free(self.content_type);
        self.allocator.free(self.body);
    }
};

fn render(gpa: std.mem.Allocator, resp: *const Response) !Rendered {
    const headers = try gpa.alloc(Header, resp.headers.items.len);
    errdefer gpa.free(headers);
    for (resp.headers.items, 0..) |h, i| {
        headers[i] = .{ .name = try gpa.dupe(u8, h.name), .value = try gpa.dupe(u8, h.value) };
    }
    return .{
        .allocator = gpa,
        .status = resp.status,
        .content_type = try gpa.dupe(u8, resp.content_type),
        .body = try gpa.dupe(u8, resp.body),
        .headers = headers,
    };
}

/// Gap #1 + #5: the monomorphized `Server(Logger, Auth, Router)` analog. The
/// composition happens entirely at comptime; `handle` is a pure
/// request-in/response-out function — no socket, no subprocess.
pub fn Server(comptime Locals: type, comptime layers: anytype, comptime Terminal: type) type {
    const Ctx = Context(Locals);
    const Pipe = Pipeline(Ctx, layers, Terminal);
    return struct {
        pub const RequestContext = Ctx;

        pub fn handle(gpa: std.mem.Allocator, request: Request, initial_locals: Locals) !Rendered {
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            const a = arena.allocator();
            var response = Response{ .allocator = a };
            var ctx = Ctx{
                .allocator = a,
                .request = request,
                .response = &response,
                .locals = initial_locals,
            };
            // Uncaught errors still degrade safely, but layers/handlers are
            // expected to use the tagged Outcome/Result for control flow.
            _ = Pipe.run(&ctx) catch {
                response.text(500, "internal error");
            };
            return render(gpa, &response);
        }
    };
}

// --- worked example, exercised by the tests below ---------------------------

const demo = struct {
    const Locals = struct {
        user: []const u8 = "",
        request_no: u32 = 0,
        rate_limited_after: u32 = 3,
    };
    const Ctx = Context(Locals);

    // Layer: logs and stamps the response on the way OUT (after `next`),
    // proving the back-half of the chain runs (gap #4).
    const Logger = struct {
        pub fn handle(ctx: *Ctx, next: anytype) anyerror!Outcome {
            const outcome = try next.run(ctx);
            try ctx.response.setHeader("x-handled-by", "yaan-pipeline");
            const status_text = try std.fmt.allocPrint(ctx.allocator, "{d}", .{ctx.response.status});
            try ctx.response.setHeader("x-final-status", status_text);
            return outcome;
        }
    };

    // Layer: authenticates, populating typed locals; short-circuits with a
    // tagged halt when the bearer token is missing/invalid (gap #1).
    const Auth = struct {
        pub fn handle(ctx: *Ctx, next: anytype) anyerror!Outcome {
            const token = ctx.request.header("authorization") orelse {
                ctx.response.text(401, "unauthorized");
                return .halt;
            };
            if (!std.mem.eql(u8, token, "Bearer secret")) {
                ctx.response.text(401, "unauthorized");
                return .halt;
            }
            ctx.locals.user = "alice";
            return next.run(ctx);
        }
    };

    // Layer: another short-circuit, driven by per-request state.
    const RateLimit = struct {
        pub fn handle(ctx: *Ctx, next: anytype) anyerror!Outcome {
            if (ctx.locals.request_no > ctx.locals.rate_limited_after) {
                ctx.response.text(429, "slow down");
                return .halt;
            }
            return next.run(ctx);
        }
    };

    // Route guard (gap #3): runs after match, before the handler. Only the
    // owner may read their own record.
    fn ownerGuard(ctx: *Ctx) anyerror!Outcome {
        const id = ctx.request.param("id") orelse "";
        if (!std.mem.eql(u8, id, ctx.locals.user)) {
            ctx.response.text(403, "forbidden");
            return .halt;
        }
        return .done;
    }

    // Handler using the tagged Result(T) model (gap #2) — no exceptions.
    fn getUser(ctx: *Ctx) anyerror!Outcome {
        const result: Result([]const u8) = blk: {
            const id = ctx.request.param("id") orelse break :blk .halt;
            break :blk .{ .ok = id };
        };
        switch (result) {
            .ok => |id| {
                const body = try std.fmt.allocPrint(ctx.allocator, "{{\"id\":\"{s}\",\"viewer\":\"{s}\"}}", .{ id, ctx.locals.user });
                ctx.response.json(200, body);
                return .done;
            },
            .halt => {
                ctx.response.text(400, "bad request");
                return .halt;
            },
        }
    }

    fn health(ctx: *Ctx) anyerror!Outcome {
        ctx.response.text(200, "ok");
        return .done;
    }

    const routes = [_]Route(Ctx){
        .{ .method = "GET", .pattern = "/healthz", .handler = &health },
        .{ .method = "GET", .pattern = "/users/:id", .guard = &ownerGuard, .handler = &getUser },
    };

    const RouterT = Router(Ctx, &routes);

    // The whole point: a comptime-composed, monomorphized server.
    const App = Server(Locals, .{ Logger, Auth, RateLimit }, RouterT);

    fn authed() [1]Header {
        return .{.{ .name = "authorization", .value = "Bearer secret" }};
    }
};

test "layers compose in order and post-process on the way out" {
    const auth = demo.authed();
    var res = try demo.App.handle(std.testing.allocator, .{
        .method = "GET",
        .path = "/users/alice",
        .headers = &auth,
    }, .{});
    defer res.deinit();

    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"id\":\"alice\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"viewer\":\"alice\"") != null);
    // Logger ran AFTER the router (gap #4: back-half of the chain).
    try std.testing.expectEqualStrings("yaan-pipeline", res.header("x-handled-by").?);
    try std.testing.expectEqualStrings("200", res.header("x-final-status").?);
}

test "auth layer short-circuits with a tagged halt" {
    var res = try demo.App.handle(std.testing.allocator, .{
        .method = "GET",
        .path = "/users/alice",
    }, .{}); // no Authorization header
    defer res.deinit();

    try std.testing.expectEqual(@as(u16, 401), res.status);
    try std.testing.expectEqualStrings("unauthorized", res.body);
    // The Logger still post-processed even though Auth short-circuited.
    try std.testing.expectEqualStrings("401", res.header("x-final-status").?);
}

test "route guard blocks the handler after matching" {
    const auth = demo.authed();
    // Authenticated as alice, but requesting bob's record.
    var res = try demo.App.handle(std.testing.allocator, .{
        .method = "GET",
        .path = "/users/bob",
        .headers = &auth,
    }, .{});
    defer res.deinit();

    try std.testing.expectEqual(@as(u16, 403), res.status);
    try std.testing.expectEqualStrings("forbidden", res.body);
}

test "rate-limit layer short-circuits from per-request state" {
    const auth = demo.authed();
    var res = try demo.App.handle(std.testing.allocator, .{
        .method = "GET",
        .path = "/users/alice",
        .headers = &auth,
    }, .{ .request_no = 99 });
    defer res.deinit();

    try std.testing.expectEqual(@as(u16, 429), res.status);
    try std.testing.expectEqualStrings("slow down", res.body);
}

test "unmatched route falls through to 404" {
    const auth = demo.authed();
    var res = try demo.App.handle(std.testing.allocator, .{
        .method = "GET",
        .path = "/nope",
        .headers = &auth,
    }, .{});
    defer res.deinit();
    try std.testing.expectEqual(@as(u16, 404), res.status);
}

test "guardless route runs without a guard" {
    const auth = demo.authed();
    var res = try demo.App.handle(std.testing.allocator, .{
        .method = "GET",
        .path = "/healthz",
        .headers = &auth,
    }, .{});
    defer res.deinit();
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expectEqualStrings("ok", res.body);
}

test "empty layer set runs the terminal directly" {
    const Locals = struct {};
    const Ctx = Context(Locals);
    const H = struct {
        fn ping(ctx: *Ctx) anyerror!Outcome {
            ctx.response.text(200, "pong");
            return .done;
        }
    };
    const routes = [_]Route(Ctx){.{ .pattern = "/", .handler = &H.ping }};
    const App = Server(Locals, .{}, Router(Ctx, &routes));
    var res = try App.handle(std.testing.allocator, .{ .path = "/" }, .{});
    defer res.deinit();
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expectEqualStrings("pong", res.body);
}
