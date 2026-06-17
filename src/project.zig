const std = @import("std");
const parser = @import("parser.zig");
const codegen = @import("codegen.zig");
const router = @import("router.zig");

const database_source = @embedFile("database.zig");

pub const CheckResult = struct {
    ok: bool,
    diagnostics: usize,
};

const BuildRoute = struct {
    route: router.RoutePattern,
    module: []u8,
};

/// A prerenderable route whose HTML document is written after the CSS bundle is
/// finalized and content-hashed (so every page links the same hashed stylesheet).
const PrerenderDoc = struct {
    page_index: usize,
    path: []u8,
    skeleton: []u8,
};

const RemoteFunction = struct {
    file: []u8,
    name: []u8,
    kind: ?[]u8 = null,

    fn deinit(self: *RemoteFunction, allocator: std.mem.Allocator) void {
        allocator.free(self.file);
        allocator.free(self.name);
        if (self.kind) |kind| allocator.free(kind);
    }
};

const AssetEntry = struct {
    logical: []u8,
    output: []u8,
    url: []u8,
    hash: [16]u8,
    size: usize,
    inline_data: ?[]u8 = null,

    fn deinit(self: *AssetEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.logical);
        allocator.free(self.output);
        allocator.free(self.url);
        if (self.inline_data) |data| allocator.free(data);
    }
};

const EnvVisibility = enum { private, public };
const EnvKind = enum { string, int, uint, bool };

const EnvVar = struct {
    name: []u8,
    visibility: EnvVisibility,
    kind: EnvKind,
    required: bool,
    static: bool,
    default_value: ?[]u8 = null,
    value: ?[]u8 = null,

    fn deinit(self: *EnvVar, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.default_value) |value| allocator.free(value);
        if (self.value) |value| allocator.free(value);
    }
};

const EnvFileValue = struct {
    name: []u8,
    value: []u8,

    fn deinit(self: *EnvFileValue, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.value);
    }
};

pub fn checkSource(allocator: std.mem.Allocator, path: []const u8, source: []const u8) !CheckResult {
    _ = path;
    var component = try parser.parse(allocator, source);
    defer parser.deinitComponent(&component, allocator);
    return .{ .ok = component.diagnostics.len == 0, .diagnostics = component.diagnostics.len };
}

pub fn checkProject(io: std.Io, allocator: std.mem.Allocator) !usize {
    var routes = try discoverRoutes(io, allocator);
    defer deinitRoutes(&routes, allocator);
    var remotes = try discoverRemotes(io, allocator);
    defer deinitRemotes(&remotes, allocator);
    var failures = validateRouteSet(routes.items);
    failures += validateRemoteSet(remotes.items);

    const cwd = std.Io.Dir.cwd();
    for (routes.items) |route| {
        const source = try cwd.readFileAlloc(io, route.file, allocator, .limited(4 * 1024 * 1024));
        var component = try parser.parse(allocator, source);
        defer parser.deinitComponent(&component, allocator);
        if (component.diagnostics.len > 0) {
            failures += component.diagnostics.len;
            for (component.diagnostics) |diag| {
                var toks = @import("tokenizer.zig").Tokenizer.init(allocator, source);
                defer toks.deinit();
                const pos = toks.position(diag.offset);
                std.debug.print("{s}:{d}:{d}: {s}\n", .{ route.file, pos.line, pos.column, diag.message });
            }
        }
        failures += validateStaticLinks(route.file, component.children, routes.items);
        warnHtmlHygiene(route.file, component.children);
    }

    if (failures == 0) {
        try prepareAssetArtifacts(io, allocator, null);
        failures += try prepareEnvArtifacts(io, allocator, null);
        if (failures == 0) {
            failures += try prepareHookArtifacts(io, allocator);
            failures += try prepareRouteArtifacts(io, allocator, routes.items);
            failures += try runLoadTypeCheck(io, allocator, routes.items);
            failures += try runActionTypeCheck(io, allocator, routes.items);
            failures += try prepareRemoteArtifacts(io, allocator, remotes.items);
        }
    }
    return failures;
}

/// Guards the clean step: only relative, non-traversing output dirs are wiped,
/// never "." (the project root), an absolute path, or anything containing "..".
fn isSafeOutputDir(out_dir: []const u8) bool {
    if (out_dir.len == 0) return false;
    if (std.mem.eql(u8, out_dir, ".")) return false;
    if (std.fs.path.isAbsolute(out_dir)) return false;
    if (std.mem.indexOf(u8, out_dir, "..") != null) return false;
    return true;
}

pub fn buildProject(io: std.Io, allocator: std.mem.Allocator, out_dir: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    // Clean the output directory so stale artifacts (old hashed assets, removed
    // routes, the pre-hash style.css) never linger between builds.
    if (isSafeOutputDir(out_dir)) cwd.deleteTree(io, out_dir) catch {};
    try cwd.createDirPath(io, out_dir);
    const pages_dir = try joinPath(allocator, out_dir, "pages");
    defer allocator.free(pages_dir);
    try cwd.createDirPath(io, pages_dir);

    var routes = try discoverRoutes(io, allocator);
    defer deinitRoutes(&routes, allocator);
    var remotes = try discoverRemotes(io, allocator);
    defer deinitRemotes(&remotes, allocator);
    if (validateRouteSet(routes.items) > 0) return error.CheckFailed;
    if (validateRemoteSet(remotes.items) > 0) return error.CheckFailed;
    try prepareAssetArtifacts(io, allocator, out_dir);
    if (try prepareEnvArtifacts(io, allocator, out_dir) > 0) return error.CheckFailed;
    if (try prepareHookArtifacts(io, allocator) > 0) return error.CheckFailed;
    if (try prepareRouteArtifacts(io, allocator, routes.items) > 0) return error.CheckFailed;
    if (try runLoadTypeCheck(io, allocator, routes.items) > 0) return error.CheckFailed;
    if (try runActionTypeCheck(io, allocator, routes.items) > 0) return error.CheckFailed;
    if (try prepareRemoteArtifacts(io, allocator, remotes.items) > 0) return error.CheckFailed;

    var build_routes: std.ArrayList(BuildRoute) = .empty;
    defer {
        for (build_routes.items) |r| {
            var route = r.route;
            route.deinit(allocator);
            allocator.free(r.module);
        }
        build_routes.deinit(allocator);
    }
    var css_bundle: std.ArrayList(u8) = .empty;
    defer css_bundle.deinit(allocator);
    try css_bundle.appendSlice(allocator, codegen.baseCss());

    // Prerenderable route documents, written after the CSS bundle is hashed.
    var prerender_docs: std.ArrayList(PrerenderDoc) = .empty;
    defer {
        for (prerender_docs.items) |doc| {
            allocator.free(doc.path);
            allocator.free(doc.skeleton);
        }
        prerender_docs.deinit(allocator);
    }

    for (routes.items, 0..) |route, page_index| {
        const source = try cwd.readFileAlloc(io, route.file, allocator, .limited(4 * 1024 * 1024));
        var component = try parser.parse(allocator, source);
        defer parser.deinitComponent(&component, allocator);
        if (component.diagnostics.len > 0) return error.CheckFailed;
        if (validateStaticLinks(route.file, component.children, routes.items) > 0) return error.CheckFailed;
        warnHtmlHygiene(route.file, component.children);

        const generated = try codegen.generateComponent(allocator, route.file, component);
        defer {
            allocator.free(generated.js);
            allocator.free(generated.css);
            allocator.free(generated.scope);
            allocator.free(generated.prerender);
        }

        const module_name = try std.fmt.allocPrint(allocator, "pages/page{d}.js", .{page_index});
        const module_path = try joinPath(allocator, out_dir, module_name);
        defer allocator.free(module_path);
        try cwd.writeFile(io, .{ .sub_path = module_path, .data = generated.js });
        try css_bundle.appendSlice(allocator, generated.css);
        try css_bundle.append(allocator, '\n');

        if (route.options.prerender != .never) {
            try prerender_docs.append(allocator, .{
                .page_index = page_index,
                .path = try allocator.dupe(u8, route.path),
                .skeleton = try allocator.dupe(u8, generated.prerender),
            });
        }

        try build_routes.append(allocator, .{
            .route = try cloneRoute(allocator, route),
            .module = try std.fmt.allocPrint(allocator, "./{s}", .{module_name}),
        });
    }

    const routes_json = try routesJson(allocator, build_routes.items);
    defer allocator.free(routes_json);
    const routes_js = try codegen.routesSource(allocator, routes_json);
    defer allocator.free(routes_js);
    const app_js = try codegen.appSource(allocator, routes_json);
    defer allocator.free(app_js);
    const remotes_js = try remotesJs(allocator, remotes.items);
    defer allocator.free(remotes_js);

    const runtime_path = try joinPath(allocator, out_dir, "runtime.js");
    defer allocator.free(runtime_path);
    const routes_path = try joinPath(allocator, out_dir, "routes.js");
    defer allocator.free(routes_path);
    const app_path = try joinPath(allocator, out_dir, "app.js");
    defer allocator.free(app_path);
    const remotes_path = try joinPath(allocator, out_dir, "remotes.js");
    defer allocator.free(remotes_path);

    try cwd.writeFile(io, .{ .sub_path = runtime_path, .data = codegen.runtimeSource() });
    try cwd.writeFile(io, .{ .sub_path = routes_path, .data = routes_js });
    try cwd.writeFile(io, .{ .sub_path = app_path, .data = app_js });
    try cwd.writeFile(io, .{ .sub_path = remotes_path, .data = remotes_js });

    // Content-hash the stylesheet and place it under /assets/ so it is served
    // with immutable caching; every document links this exact href.
    const style_hash = contentHash(css_bundle.items);
    const style_name = try std.fmt.allocPrint(allocator, "assets/style.{s}.css", .{style_hash});
    defer allocator.free(style_name);
    const assets_dir = try joinPath(allocator, out_dir, "assets");
    defer allocator.free(assets_dir);
    try cwd.createDirPath(io, assets_dir);
    const style_path = try joinPath(allocator, out_dir, style_name);
    defer allocator.free(style_path);
    try cwd.writeFile(io, .{ .sub_path = style_path, .data = css_bundle.items });
    const stylesheet_href = try std.fmt.allocPrint(allocator, "/{s}", .{style_name});
    defer allocator.free(stylesheet_href);

    const index_path = try joinPath(allocator, out_dir, "index.html");
    defer allocator.free(index_path);
    const index_html = try codegen.htmlSource(allocator, .{ .stylesheet = stylesheet_href });
    defer allocator.free(index_html);
    try cwd.writeFile(io, .{ .sub_path = index_path, .data = index_html });

    // Per-route prerendered documents + the server manifest, now that the
    // stylesheet href is known.
    var prerender_manifest: std.ArrayList(u8) = .empty;
    defer prerender_manifest.deinit(allocator);
    try prerender_manifest.append(allocator, '[');
    for (prerender_docs.items, 0..) |doc, i| {
        const page_html = try codegen.htmlSource(allocator, .{
            .app_html = doc.skeleton,
            .stylesheet = stylesheet_href,
        });
        defer allocator.free(page_html);
        const html_name = try std.fmt.allocPrint(allocator, "pages/page{d}.html", .{doc.page_index});
        defer allocator.free(html_name);
        const html_path = try joinPath(allocator, out_dir, html_name);
        defer allocator.free(html_path);
        try cwd.writeFile(io, .{ .sub_path = html_path, .data = page_html });

        if (i > 0) try prerender_manifest.append(allocator, ',');
        const path_lit = try jsonString(allocator, doc.path);
        defer allocator.free(path_lit);
        const file_lit = try jsonString(allocator, html_name);
        defer allocator.free(file_lit);
        try prerender_manifest.print(allocator, "{{\"path\":{s},\"file\":{s}}}", .{ path_lit, file_lit });
    }
    try prerender_manifest.append(allocator, ']');
    const prerender_path = try joinPath(allocator, out_dir, "prerender.json");
    defer allocator.free(prerender_path);
    try cwd.writeFile(io, .{ .sub_path = prerender_path, .data = prerender_manifest.items });
    try writeErrorPages(io, allocator, out_dir);
}

pub fn buildDevLoadRunner(io: std.Io, allocator: std.mem.Allocator) !void {
    var routes = try discoverRoutes(io, allocator);
    defer deinitRoutes(&routes, allocator);
    if (validateRouteSet(routes.items) > 0) return error.CheckFailed;
    if (try prepareEnvArtifacts(io, allocator, null) > 0) return error.CheckFailed;
    if (try prepareRouteArtifacts(io, allocator, routes.items) > 0) return error.CheckFailed;
    if (try runLoadTypeCheck(io, allocator, routes.items) > 0) return error.CheckFailed;
    if (!hasLoaders(routes.items)) return;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try appendLoadCompileArgs(allocator, &argv, routes.items);

    const result = try std.process.run(allocator, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        std.debug.print("{s}{s}", .{ result.stdout, result.stderr });
        return error.CheckFailed;
    }
}

pub fn buildDevActionRunner(io: std.Io, allocator: std.mem.Allocator) !void {
    var routes = try discoverRoutes(io, allocator);
    defer deinitRoutes(&routes, allocator);
    if (validateRouteSet(routes.items) > 0) return error.CheckFailed;
    if (try prepareEnvArtifacts(io, allocator, null) > 0) return error.CheckFailed;
    if (try prepareRouteArtifacts(io, allocator, routes.items) > 0) return error.CheckFailed;
    if (try runActionTypeCheck(io, allocator, routes.items) > 0) return error.CheckFailed;
    if (!hasActions(routes.items)) return;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try appendActionCompileArgs(allocator, &argv, routes.items);

    const result = try std.process.run(allocator, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        std.debug.print("{s}{s}", .{ result.stdout, result.stderr });
        return error.CheckFailed;
    }
}

pub fn buildDevRemoteRunner(io: std.Io, allocator: std.mem.Allocator) !void {
    var remotes = try discoverRemotes(io, allocator);
    defer deinitRemotes(&remotes, allocator);
    if (validateRemoteSet(remotes.items) > 0) return error.CheckFailed;
    if (try prepareEnvArtifacts(io, allocator, null) > 0) return error.CheckFailed;
    if (try prepareRemoteArtifacts(io, allocator, remotes.items) > 0) return error.CheckFailed;
    if (remotes.items.len == 0) return;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try appendRemoteCompileArgs(allocator, &argv, remotes.items);

    const result = try std.process.run(allocator, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        std.debug.print("{s}{s}", .{ result.stdout, result.stderr });
        return error.CheckFailed;
    }
}

pub fn buildDevHookRunner(io: std.Io, allocator: std.mem.Allocator) !void {
    if (!try hasHooks(io)) {
        std.Io.Dir.cwd().deleteFile(io, ".yaan/hook_runner") catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        return;
    }
    if (try prepareEnvArtifacts(io, allocator, null) > 0) return error.CheckFailed;
    if (try prepareHookArtifacts(io, allocator) > 0) return error.CheckFailed;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try appendHookCompileArgs(allocator, &argv);

    const result = try std.process.run(allocator, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        std.debug.print("{s}{s}", .{ result.stdout, result.stderr });
        return error.CheckFailed;
    }
}

pub fn writeExampleApp(io: std.Io, allocator: std.mem.Allocator, project_name: ?[]const u8) !void {
    const base = std.Io.Dir.cwd();
    // When a name is given, scaffold into a fresh `<name>/` directory
    // (sv-create style); otherwise scaffold into the current directory.
    var project_dir: ?std.Io.Dir = null;
    defer if (project_dir) |*d| d.close(io);
    const cwd: std.Io.Dir = if (project_name) |name| blk: {
        if (base.access(io, name, .{})) |_| {
            std.debug.print("'{s}' already exists; choose a new name or remove it\n", .{name});
            return error.PathAlreadyExists;
        } else |_| {}
        try base.createDirPath(io, name);
        const dir = try base.openDir(io, name, .{});
        project_dir = dir;
        break :blk dir;
    } else base;

    try cwd.createDirPath(io, "src/routes");
    try cwd.createDirPath(io, "src/routes/blog/[slug:string]");
    try cwd.createDirPath(io, "src/routes/login");
    try cwd.createDirPath(io, "src/routes/users/[id:int]");
    try cwd.createDirPath(io, "src/remotes");
    try cwd.createDirPath(io, "src/error");
    try cwd.createDirPath(io, "static");
    try cwd.writeFile(io, .{ .sub_path = "static/logo.svg", .data =
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" role="img" aria-label="Yaan mark">
        \\  <rect width="64" height="64" rx="12" fill="#111827"/>
        \\  <path d="M16 18h10l7 13 7-13h10L38 38v12H28V38L16 18z" fill="#f9fafb"/>
        \\</svg>
    });
    try cwd.writeFile(io, .{ .sub_path = "src/error/404.html", .data =
        \\<!doctype html>
        \\<html>
        \\<head>
        \\  <meta charset="utf-8">
        \\  <meta name="viewport" content="width=device-width, initial-scale=1">
        \\  <title>Not Found</title>
        \\</head>
        \\<body>
        \\  <main>
        \\    <h1>Not Found</h1>
        \\    <p>This page does not exist in the Yaan example app.</p>
        \\  </main>
        \\</body>
        \\</html>
    });
    try cwd.writeFile(io, .{ .sub_path = "src/env.zig", .data =
        \\const env = @import("env_config");
        \\
        \\pub const variables = env.define(.{
        \\    .GREETING_PREFIX = env.private(.string, .{ .default = "Hello" }),
        \\    .PUBLIC_SITE_NAME = env.public(.string, .{ .default = "Yaan" }),
        \\    .PUBLIC_DEBUG = env.public(.bool, .{ .default = false, .static = true }),
        \\});
    });
    try cwd.writeFile(io, .{ .sub_path = "src/hooks.zig", .data =
        \\const std = @import("std");
        \\const hooks = @import("hooks");
        \\
        \\pub const Locals = struct {
        \\    request_id: []const u8 = "dev",
        \\};
        \\
        \\pub fn handle(ctx: *hooks.Context(Locals)) !hooks.Decision {
        \\    if (std.mem.eql(u8, ctx.request.path, "/healthz")) {
        \\        return hooks.text(200, "ok");
        \\    }
        \\    if (std.mem.eql(u8, ctx.request.path, "/old-docs")) {
        \\        return hooks.redirect("/docs/intro/setup");
        \\    }
        \\    if (std.mem.eql(u8, ctx.request.path, "/start")) {
        \\        return hooks.rewrite("/");
        \\    }
        \\    return hooks.pass();
        \\}
    });
    try cwd.writeFile(io, .{ .sub_path = "src/routes/+page.yn", .data =
        \\<script>
        \\import { greeting } from '/remotes.js';
        \\import { PUBLIC_SITE_NAME } from '/env.public.js';
        \\
        \\const count = $signal(0);
        \\const items = $signal([{ id: 1, name: "one" }, { id: 2, name: "two" }]);
        \\const hello = $resource(() => greeting({ name: PUBLIC_SITE_NAME }));
        \\</script>
        \\
        \\<style>
        \\main > button { color: white; background: #1f6feb; }
        \\:global(body) { font-family: system-ui, sans-serif; }
        \\</style>
        \\
        \\<main>
        \\  <img src={asset("logo.svg")} alt="Yaan mark" width="64" height="64" />
        \\  <h1>{PUBLIC_SITE_NAME}</h1>
        \\  {#if hello.ready()}<p>{hello.value().message}</p>{:else}<p>Loading remote.</p>{/if}
        \\  <button on:click={() => count.update(n => n + 1)}>Count {count.read()}</button>
        \\  {#if count.read() > 2}<p>Reactive enough.</p>{:else}<p>Click the button.</p>{/if}
        \\  {#each items.read() as item (item.id)}<p>{item.name}</p>{/each}
        \\  <a href="/blog/hello">String route</a>
        \\  <a href="/users/42">Int route</a>
        \\  <a href="/login">Form action</a>
        \\</main>
    });
    try cwd.writeFile(io, .{ .sub_path = "src/routes/blog/[slug:string]/+page.yn", .data =
        \\<script>
        \\const title = $memo(() => props.data.title);
        \\</script>
        \\<h1>{title.read()}</h1>
    });
    try cwd.writeFile(io, .{ .sub_path = "src/routes/blog/[slug:string]/+load.zig", .data =
        \\const routes = @import("routes");
        \\
        \\pub const Data = struct {
        \\    title: []const u8,
        \\};
        \\
        \\pub fn load(ctx: routes.LoadContext(.blog_slug)) !Data {
        \\    return .{ .title = ctx.params.slug };
        \\}
    });
    try cwd.writeFile(io, .{ .sub_path = "src/routes/blog/[slug:string]/+page.options.zig", .data =
        \\const routes = @import("routes");
        \\
        \\pub const options: routes.PageOptions = .{
        \\    .trailing_slash = .never,
        \\};
    });
    try cwd.writeFile(io, .{ .sub_path = "src/routes/users/[id:int]/+page.yn", .data =
        \\<script>
        \\const id = $memo(() => props.data.id);
        \\</script>
        \\<h1>User {id.read()}</h1>
    });
    try cwd.writeFile(io, .{ .sub_path = "src/routes/users/[id:int]/+load.zig", .data =
        \\const routes = @import("routes");
        \\
        \\pub const Data = struct {
        \\    id: i64,
        \\};
        \\
        \\pub fn load(ctx: routes.LoadContext(.users_id)) !Data {
        \\    return .{ .id = ctx.params.id };
        \\}
    });
    try cwd.writeFile(io, .{ .sub_path = "src/routes/login/+page.yn", .data =
        \\<script>
        \\const message = $memo(() => props.form?.message ?? "Sign in");
        \\</script>
        \\
        \\<form method="POST" enctype="multipart/form-data">
        \\  <label>Email <input name="email" value="person@example.com" /></label>
        \\  <label>Password <input name="password" type="password" value="secret" /></label>
        \\  <label>Avatar <input name="avatar" type="file" /></label>
        \\  <button>Submit</button>
        \\</form>
        \\<p>{message.read()}</p>
    });
    try cwd.writeFile(io, .{ .sub_path = "src/routes/login/+actions.zig", .data =
        \\const routes = @import("routes");
        \\
        \\pub const Form = struct {
        \\    email: []const u8,
        \\    password: []const u8,
        \\    avatar: ?routes.Upload,
        \\};
        \\
        \\pub const Result = struct {
        \\    ok: bool,
        \\    message: []const u8,
        \\};
        \\
        \\pub fn action(ctx: routes.ActionContext(.login), form: Form) !Result {
        \\    _ = ctx;
        \\    return .{
        \\        .ok = form.password.len >= 6,
        \\        .message = if (form.avatar) |upload|
        \\            upload.filename
        \\        else if (form.password.len >= 6)
        \\            form.email
        \\        else
        \\            "Password is too short",
        \\    };
        \\}
    });
    try cwd.writeFile(io, .{ .sub_path = "src/remotes/greeting.remote.zig", .data =
        \\const std = @import("std");
        \\const app_env = @import("env");
        \\const remote = @import("remote");
        \\
        \\pub const kind: remote.Kind = .query;
        \\
        \\pub const Input = struct {
        \\    name: []const u8,
        \\};
        \\
        \\pub const Output = struct {
        \\    message: []const u8,
        \\};
        \\
        \\pub fn call(ctx: remote.Context, input: Input) !Output {
        \\    return .{
        \\        .message = try std.fmt.allocPrint(ctx.allocator, "{s}, {s}", .{ app_env.GREETING_PREFIX, input.name }),
        \\    };
        \\}
    });

    try writeProjectBuildFiles(io, allocator, cwd, project_name orelse "app");
}

/// Emits `build.zig` and `build.zig.zon` for a scaffolded app. The dev/build/
/// check loop is driven by the global `yaan` CLI and needs no package
/// dependency, so these are thin wrappers plus a valid package manifest. Files
/// that already exist are left untouched so re-running init never clobbers a
/// user's build setup.
fn writeProjectBuildFiles(io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir, raw_name: []const u8) !void {
    const name = try packageName(allocator, raw_name);
    defer allocator.free(name);

    if (dir.access(io, "build.zig", .{})) |_| {
        std.debug.print("build.zig exists; leaving it untouched\n", .{});
    } else |_| {
        try dir.writeFile(io, .{ .sub_path = "build.zig", .data =
            \\const std = @import("std");
            \\
            \\// Yaan apps are driven by the `yaan` CLI (install it once, then it is on
            \\// your PATH). The dev/build/check loop is self-contained: the CLI
            \\// generates everything under .yaan/ and dist/, so no package dependency
            \\// is required here. These steps are thin wrappers so `zig build dev`
            \\// works alongside `yaan dev`.
            \\pub fn build(b: *std.Build) void {
            \\    const host = b.option([]const u8, "host", "Dev server host") orelse "127.0.0.1";
            \\    const port = b.option([]const u8, "port", "Dev server port") orelse "5173";
            \\
            \\    const dev = b.step("dev", "Run the Yaan dev server");
            \\    dev.dependOn(&b.addSystemCommand(&.{ "yaan", "dev", "--host", host, "--port", port }).step);
            \\
            \\    const check = b.step("check", "Run Yaan framework checks");
            \\    check.dependOn(&b.addSystemCommand(&.{ "yaan", "check" }).step);
            \\
            \\    const build_app = b.step("build-app", "Build the app into dist/");
            \\    build_app.dependOn(&b.addSystemCommand(&.{ "yaan", "build", "--out", "dist" }).step);
            \\}
            \\
        });
    }

    if (dir.access(io, "build.zig.zon", .{})) |_| {
        std.debug.print("build.zig.zon exists; leaving it untouched\n", .{});
    } else |_| {
        // Fingerprint layout (validated by the Zig compiler): the high 32 bits
        // are Crc32(name); the low 32 bits are an arbitrary non-reserved id.
        const checksum: u32 = std.hash.Crc32.hash(name);
        var id: u32 = @truncate(std.hash.Wyhash.hash(0, name));
        if (id == 0) id = 1;
        if (id == 0xffff_ffff) id = 0xffff_fffe;
        const fingerprint: u64 = (@as(u64, checksum) << 32) | id;

        const zon = try std.fmt.allocPrint(allocator,
            \\.{{
            \\    .name = .{s},
            \\    .version = "0.0.0",
            \\    .fingerprint = 0x{x},
            \\    .minimum_zig_version = "0.16.0",
            \\    .dependencies = .{{}},
            \\    .paths = .{{
            \\        "build.zig",
            \\        "build.zig.zon",
            \\        "src",
            \\        "static",
            \\    }},
            \\}}
            \\
        , .{ name, fingerprint });
        defer allocator.free(zon);
        try dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = zon });
    }
}

/// Sanitizes a project name into a valid Zig identifier usable as the `.name`
/// enum literal in build.zig.zon. Non-identifier bytes become `_`; a leading
/// digit is prefixed with `_`.
fn packageName(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (raw) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
        try out.append(allocator, if (ok) c else '_');
    }
    if (out.items.len == 0 or (out.items[0] >= '0' and out.items[0] <= '9')) {
        try out.insert(allocator, 0, '_');
    }
    return out.toOwnedSlice(allocator);
}

fn discoverRoutes(io: std.Io, allocator: std.mem.Allocator) !std.ArrayList(router.RoutePattern) {
    const cwd = std.Io.Dir.cwd();
    var routes_dir = try cwd.openDir(io, "src/routes", .{ .iterate = true });
    defer routes_dir.close(io);

    var routes: std.ArrayList(router.RoutePattern) = .empty;
    errdefer deinitRoutes(&routes, allocator);

    var walker = try routes_dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, "+page.yn")) continue;
        const src_path = try std.fmt.allocPrint(allocator, "src/routes/{s}", .{entry.path});
        const route = router.parseRouteFile(allocator, src_path) catch |err| {
            allocator.free(src_path);
            std.debug.print("src/routes/{s}: invalid route segment: {t}\n", .{ entry.path, err });
            return err;
        };
        var route_with_load = route;
        const load_path = try loadPathFromPage(allocator, src_path);
        if (cwd.access(io, load_path, .{ .read = true })) {
            route_with_load.load_file = load_path;
        } else |err| switch (err) {
            error.FileNotFound => allocator.free(load_path),
            else => {
                allocator.free(load_path);
                return err;
            },
        }
        const actions_path = try actionsPathFromPage(allocator, src_path);
        if (cwd.access(io, actions_path, .{ .read = true })) {
            route_with_load.actions_file = actions_path;
        } else |err| switch (err) {
            error.FileNotFound => allocator.free(actions_path),
            else => {
                allocator.free(actions_path);
                return err;
            },
        }
        const options_path = try optionsPathFromPage(allocator, src_path);
        if (cwd.access(io, options_path, .{ .read = true })) {
            route_with_load.options_file = options_path;
        } else |err| switch (err) {
            error.FileNotFound => allocator.free(options_path),
            else => {
                allocator.free(options_path);
                return err;
            },
        }
        allocator.free(src_path);
        try routes.append(allocator, route_with_load);
    }

    if (routes.items.len == 0) return error.NoRoutes;
    router.sortRoutes(routes.items);
    return routes;
}

fn loadPathFromPage(allocator: std.mem.Allocator, page_path: []const u8) ![]u8 {
    if (!std.mem.endsWith(u8, page_path, "+page.yn")) return allocator.dupe(u8, page_path);
    return std.fmt.allocPrint(allocator, "{s}+load.zig", .{page_path[0 .. page_path.len - "+page.yn".len]});
}

fn actionsPathFromPage(allocator: std.mem.Allocator, page_path: []const u8) ![]u8 {
    if (!std.mem.endsWith(u8, page_path, "+page.yn")) return allocator.dupe(u8, page_path);
    return std.fmt.allocPrint(allocator, "{s}+actions.zig", .{page_path[0 .. page_path.len - "+page.yn".len]});
}

fn optionsPathFromPage(allocator: std.mem.Allocator, page_path: []const u8) ![]u8 {
    if (!std.mem.endsWith(u8, page_path, "+page.yn")) return allocator.dupe(u8, page_path);
    return std.fmt.allocPrint(allocator, "{s}+page.options.zig", .{page_path[0 .. page_path.len - "+page.yn".len]});
}

fn deinitRoutes(routes: *std.ArrayList(router.RoutePattern), allocator: std.mem.Allocator) void {
    for (routes.items) |*route| route.deinit(allocator);
    routes.deinit(allocator);
}

fn discoverRemotes(io: std.Io, allocator: std.mem.Allocator) !std.ArrayList(RemoteFunction) {
    const cwd = std.Io.Dir.cwd();
    var remotes: std.ArrayList(RemoteFunction) = .empty;
    errdefer deinitRemotes(&remotes, allocator);

    var remotes_dir = cwd.openDir(io, "src/remotes", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return remotes,
        else => return err,
    };
    defer remotes_dir.close(io);

    var walker = try remotes_dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".remote.zig")) continue;
        const src_path = try std.fmt.allocPrint(allocator, "src/remotes/{s}", .{entry.path});
        errdefer allocator.free(src_path);
        const name = remoteNameFromPath(allocator, entry.path) catch |err| {
            std.debug.print("src/remotes/{s}: invalid remote function file name: {t}\n", .{ entry.path, err });
            return err;
        };
        try remotes.append(allocator, .{ .file = src_path, .name = name });
    }
    return remotes;
}

fn deinitRemotes(remotes: *std.ArrayList(RemoteFunction), allocator: std.mem.Allocator) void {
    for (remotes.items) |*remote| remote.deinit(allocator);
    remotes.deinit(allocator);
}

fn remoteNameFromPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse 0;
    const basename = if (slash == 0 and (path.len == 0 or path[0] != '/')) path else path[slash + 1 ..];
    const suffix = ".remote.zig";
    if (!std.mem.endsWith(u8, basename, suffix)) return error.InvalidRemoteName;
    const name = basename[0 .. basename.len - suffix.len];
    if (!isJsIdent(name)) return error.InvalidRemoteName;
    return allocator.dupe(u8, name);
}

fn isJsIdent(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value, 0..) |c, i| {
        const start = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$';
        const cont = start or (c >= '0' and c <= '9');
        if (i == 0) {
            if (!start) return false;
        } else if (!cont) return false;
    }
    return true;
}

fn validateRemoteSet(remotes: []const RemoteFunction) usize {
    var failures: usize = 0;
    for (remotes, 0..) |a, i| {
        for (remotes[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.name, b.name)) {
                std.debug.print("duplicate remote function name '{s}'\n", .{a.name});
                failures += 1;
            }
        }
    }
    return failures;
}

fn validateRouteSet(routes: []const router.RoutePattern) usize {
    var failures: usize = 0;
    if (router.hasDuplicateShapes(routes)) {
        std.debug.print("duplicate route pattern detected\n", .{});
        failures += 1;
    }
    if (router.hasDuplicateNames(routes)) {
        std.debug.print("duplicate generated route name detected\n", .{});
        failures += 1;
    }
    return failures;
}

fn validateRouteOptions(routes: []const router.RoutePattern) usize {
    var failures: usize = 0;
    for (routes) |route| {
        if (!route.options.csr) {
            std.debug.print("{s}: csr=false requires SSR/static page output and is not supported in v1\n", .{route.file});
            failures += 1;
        }
        if (route.options.prerender == .always and routeHasDynamicSegments(route)) {
            std.debug.print("{s}: prerender=.always for dynamic routes requires static params and is not supported in v1\n", .{route.file});
            failures += 1;
        }
    }
    return failures;
}

fn routeHasDynamicSegments(route: router.RoutePattern) bool {
    for (route.segments) |segment| {
        if (segment.kind == .dynamic or segment.kind == .rest) return true;
    }
    return false;
}

fn validateStaticLinks(file: []const u8, nodes: []const parser.Node, routes: []const router.RoutePattern) usize {
    var failures: usize = 0;
    for (nodes) |node| switch (node) {
        .element => |element| {
            for (element.attrs) |attr| {
                if (std.mem.eql(u8, attr.name, "href")) {
                    if (attr.value) |value| {
                        if (value.len > 0 and value[0] == '/' and !router.anyRouteMatchesStaticPath(routes, value)) {
                            std.debug.print("{s}: unknown static href '{s}'\n", .{ file, value });
                            failures += 1;
                        }
                    }
                }
            }
            failures += validateStaticLinks(file, element.children, routes);
        },
        .if_block => |block| {
            failures += validateStaticLinks(file, block.then_children, routes);
            failures += validateStaticLinks(file, block.else_children, routes);
        },
        .each_block => |block| failures += validateStaticLinks(file, block.children, routes),
        else => {},
    };
    return failures;
}

fn warnHtmlHygiene(file: []const u8, nodes: []const parser.Node) void {
    for (nodes) |node| switch (node) {
        .element => |element| {
            if (std.mem.eql(u8, element.name, "img") and !hasAttr(element, "alt")) {
                std.debug.print("{s}: warning: <img> is missing alt text\n", .{file});
            }
            warnHtmlHygiene(file, element.children);
        },
        .if_block => |block| {
            warnHtmlHygiene(file, block.then_children);
            warnHtmlHygiene(file, block.else_children);
        },
        .each_block => |block| warnHtmlHygiene(file, block.children),
        else => {},
    };
}

fn hasAttr(element: parser.Element, name: []const u8) bool {
    for (element.attrs) |attr| {
        if (std.mem.eql(u8, attr.name, name)) return true;
    }
    return false;
}

fn prepareEnvArtifacts(io: std.Io, allocator: std.mem.Allocator, out_dir: ?[]const u8) !usize {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, ".yaan");
    const config_source = try generateEnvConfig(allocator);
    defer allocator.free(config_source);
    try cwd.writeFile(io, .{ .sub_path = ".yaan/env_config.zig", .data = config_source });

    var vars: std.ArrayList(EnvVar) = .empty;
    defer deinitEnvVars(&vars, allocator);

    if (cwd.access(io, "src/env.zig", .{ .read = true })) {
        const manifest_source = try generateEnvManifest(allocator);
        defer allocator.free(manifest_source);
        try cwd.writeFile(io, .{ .sub_path = ".yaan/env_manifest.zig", .data = manifest_source });
        if (try runEnvManifest(io, allocator, &vars) > 0) return 1;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    var file_values = try loadEnvFiles(io, allocator);
    defer deinitEnvFileValues(&file_values, allocator);

    var failures: usize = 0;
    for (vars.items) |*env_var| {
        const maybe_value = resolveEnvValue(allocator, env_var.*, file_values.items) catch |err| {
            std.debug.print("invalid value for env variable {s}: {t}\n", .{ env_var.name, err });
            failures += 1;
            continue;
        };
        if (maybe_value) |value| {
            env_var.value = value;
        } else if (env_var.required) {
            std.debug.print("missing required env variable {s}\n", .{env_var.name});
            failures += 1;
        }
    }

    const env_source = try generateEnvModule(allocator, vars.items);
    defer allocator.free(env_source);
    try cwd.writeFile(io, .{ .sub_path = ".yaan/env.zig", .data = env_source });

    if (out_dir) |dir| {
        const public_source = try generatePublicEnvJs(allocator, vars.items);
        defer allocator.free(public_source);
        const public_path = try joinPath(allocator, dir, "env.public.js");
        defer allocator.free(public_path);
        try cwd.writeFile(io, .{ .sub_path = public_path, .data = public_source });
    }

    return failures;
}

fn deinitEnvVars(vars: *std.ArrayList(EnvVar), allocator: std.mem.Allocator) void {
    for (vars.items) |*env_var| env_var.deinit(allocator);
    vars.deinit(allocator);
}

fn deinitEnvFileValues(values: *std.ArrayList(EnvFileValue), allocator: std.mem.Allocator) void {
    for (values.items) |*value| value.deinit(allocator);
    values.deinit(allocator);
}

fn generateEnvConfig(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8,
        \\pub const Visibility = enum { private, public };
        \\pub const Kind = enum { string, int, uint, bool };
        \\
        \\pub const Value = union(enum) {
        \\    string: []const u8,
        \\    int: i64,
        \\    uint: u64,
        \\    bool: bool,
        \\};
        \\
        \\pub const Var = struct {
        \\    visibility: Visibility,
        \\    kind: Kind,
        \\    required: bool = false,
        \\    static: bool = false,
        \\    default: ?Value = null,
        \\    description: []const u8 = "",
        \\};
        \\
        \\pub fn define(vars: anytype) @TypeOf(vars) {
        \\    return vars;
        \\}
        \\
        \\pub fn private(kind: Kind, options: anytype) Var {
        \\    return make(.private, kind, options);
        \\}
        \\
        \\pub fn public(kind: Kind, options: anytype) Var {
        \\    return make(.public, kind, options);
        \\}
        \\
        \\fn make(visibility: Visibility, kind: Kind, options: anytype) Var {
        \\    const Options = @TypeOf(options);
        \\    var out = Var{ .visibility = visibility, .kind = kind };
        \\    if (@hasField(Options, "required")) out.required = options.required;
        \\    if (@hasField(Options, "static")) out.static = options.static;
        \\    if (@hasField(Options, "description")) out.description = options.description;
        \\    if (@hasField(Options, "default")) out.default = value(options.default);
        \\    return out;
        \\}
        \\
        \\fn value(raw: anytype) Value {
        \\    const T = @TypeOf(raw);
        \\    if (T == Value) return raw;
        \\    return switch (@typeInfo(T)) {
        \\        .bool => .{ .bool = raw },
        \\        .int => |info| if (info.signedness == .signed) .{ .int = raw } else .{ .uint = raw },
        \\        .comptime_int => if (raw < 0) .{ .int = raw } else .{ .uint = raw },
        \\        .pointer => |ptr| switch (ptr.size) {
        \\            .slice => .{ .string = raw },
        \\            .one => switch (@typeInfo(ptr.child)) {
        \\                .array => .{ .string = raw[0..] },
        \\                else => @compileError("unsupported env default pointer"),
        \\            },
        \\            else => @compileError("unsupported env default pointer"),
        \\        },
        \\        .array => .{ .string = raw[0..] },
        \\        else => @compileError("unsupported env default type"),
        \\    };
        \\}
        \\
    );
}

fn generateEnvManifest(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8,
        \\const std = @import("std");
        \\const env_config = @import("env_config");
        \\const app_env = @import("app_env");
        \\
        \\pub fn main(init: std.process.Init) !void {
        \\    var stdout_buffer: [8192]u8 = undefined;
        \\    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
        \\    const writer = &stdout_file_writer.interface;
        \\    inline for (@typeInfo(@TypeOf(app_env.variables)).@"struct".fields) |field| {
        \\        try writeVar(writer, field.name, @field(app_env.variables, field.name));
        \\    }
        \\    try writer.flush();
        \\}
        \\
        \\fn writeVar(writer: *std.Io.Writer, name: []const u8, env_var: env_config.Var) !void {
        \\    try writer.print("{s}\t{s}\t{s}\t{}\t{}\t", .{
        \\        name,
        \\        @tagName(env_var.visibility),
        \\        @tagName(env_var.kind),
        \\        env_var.required,
        \\        env_var.static,
        \\    });
        \\    if (env_var.default) |default| {
        \\        try writer.writeAll("true\t");
        \\        switch (default) {
        \\            .string => |value| try std.json.Stringify.value(value, .{}, writer),
        \\            .int => |value| try std.json.Stringify.value(value, .{}, writer),
        \\            .uint => |value| try std.json.Stringify.value(value, .{}, writer),
        \\            .bool => |value| try std.json.Stringify.value(value, .{}, writer),
        \\        }
        \\    } else {
        \\        try writer.writeAll("false\tnull");
        \\    }
        \\    try writer.writeAll("\n");
        \\}
        \\
    );
}

fn runEnvManifest(io: std.Io, allocator: std.mem.Allocator, vars: *std.ArrayList(EnvVar)) !usize {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "zig");
    try argv.append(allocator, "run");
    try argv.append(allocator, "--dep");
    try argv.append(allocator, "env_config");
    try argv.append(allocator, "--dep");
    try argv.append(allocator, "app_env");
    try argv.append(allocator, "-Mroot=.yaan/env_manifest.zig");
    try argv.append(allocator, "-Menv_config=.yaan/env_config.zig");
    try argv.append(allocator, "--dep");
    try argv.append(allocator, "env_config");
    try argv.append(allocator, "-Mapp_env=src/env.zig");

    const result = try std.process.run(allocator, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(128 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        std.debug.print("{s}{s}", .{ result.stdout, result.stderr });
        return 1;
    }
    try parseEnvManifest(allocator, vars, result.stdout);
    return 0;
}

fn parseEnvManifest(allocator: std.mem.Allocator, vars: *std.ArrayList(EnvVar), output: []const u8) !void {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const name = fields.next() orelse return error.InvalidEnvManifest;
        const visibility_text = fields.next() orelse return error.InvalidEnvManifest;
        const kind_text = fields.next() orelse return error.InvalidEnvManifest;
        const required_text = fields.next() orelse return error.InvalidEnvManifest;
        const static_text = fields.next() orelse return error.InvalidEnvManifest;
        const has_default_text = fields.next() orelse return error.InvalidEnvManifest;
        const default_json = fields.next() orelse return error.InvalidEnvManifest;
        if (fields.next() != null) return error.InvalidEnvManifest;
        if (!isEnvName(name)) return error.InvalidEnvName;

        const visibility = try parseEnvVisibility(visibility_text);
        const kind = try parseEnvKind(kind_text);
        const required = try parseBool(required_text);
        const is_static = try parseBool(static_text);
        const has_default = try parseBool(has_default_text);
        const default_value = if (has_default) try parseDefaultEnvValue(allocator, kind, default_json) else null;

        try vars.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .visibility = visibility,
            .kind = kind,
            .required = required,
            .static = is_static,
            .default_value = default_value,
        });
    }
}

fn isEnvName(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value, 0..) |c, i| {
        const ok = (c >= 'A' and c <= 'Z') or c == '_' or (i > 0 and c >= '0' and c <= '9');
        if (!ok) return false;
    }
    return true;
}

fn parseEnvVisibility(value: []const u8) !EnvVisibility {
    if (std.mem.eql(u8, value, "private")) return .private;
    if (std.mem.eql(u8, value, "public")) return .public;
    return error.InvalidEnvManifest;
}

fn parseEnvKind(value: []const u8) !EnvKind {
    if (std.mem.eql(u8, value, "string")) return .string;
    if (std.mem.eql(u8, value, "int")) return .int;
    if (std.mem.eql(u8, value, "uint")) return .uint;
    if (std.mem.eql(u8, value, "bool")) return .bool;
    return error.InvalidEnvManifest;
}

fn parseDefaultEnvValue(allocator: std.mem.Allocator, kind: EnvKind, json: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, json, .{});
    switch (kind) {
        .string => return switch (parsed) {
            .string => |value| try allocator.dupe(u8, value),
            else => error.InvalidEnvDefault,
        },
        .bool => return switch (parsed) {
            .bool => |value| try allocator.dupe(u8, if (value) "true" else "false"),
            else => error.InvalidEnvDefault,
        },
        .int => return switch (parsed) {
            .integer => |value| try std.fmt.allocPrint(allocator, "{d}", .{value}),
            else => error.InvalidEnvDefault,
        },
        .uint => return switch (parsed) {
            .integer => |value| if (value >= 0) try std.fmt.allocPrint(allocator, "{d}", .{@as(u64, @intCast(value))}) else error.InvalidEnvDefault,
            else => error.InvalidEnvDefault,
        },
    }
}

fn loadEnvFiles(io: std.Io, allocator: std.mem.Allocator) !std.ArrayList(EnvFileValue) {
    var values: std.ArrayList(EnvFileValue) = .empty;
    errdefer deinitEnvFileValues(&values, allocator);
    try loadEnvFile(io, allocator, ".env", &values);
    try loadEnvFile(io, allocator, ".env.local", &values);
    return values;
}

fn loadEnvFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, values: *std.ArrayList(EnvFileValue)) !void {
    const cwd = std.Io.Dir.cwd();
    const source = cwd.readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer allocator.free(source);
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const trimmed_line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (trimmed_line.len == 0 or trimmed_line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, trimmed_line, '=') orelse continue;
        const name = std.mem.trim(u8, trimmed_line[0..eq], " \t");
        if (!isEnvName(name)) continue;
        const raw_value = std.mem.trim(u8, trimmed_line[eq + 1 ..], " \t");
        const value = unquoteEnvValue(raw_value);
        try upsertEnvFileValue(allocator, values, name, value);
    }
}

fn upsertEnvFileValue(allocator: std.mem.Allocator, values: *std.ArrayList(EnvFileValue), name: []const u8, value: []const u8) !void {
    for (values.items) |*item| {
        if (std.mem.eql(u8, item.name, name)) {
            allocator.free(item.value);
            item.value = try allocator.dupe(u8, value);
            return;
        }
    }
    try values.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .value = try allocator.dupe(u8, value),
    });
}

fn unquoteEnvValue(value: []const u8) []const u8 {
    if (value.len >= 2) {
        const first = value[0];
        const last = value[value.len - 1];
        if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) return value[1 .. value.len - 1];
    }
    return value;
}

fn resolveEnvValue(allocator: std.mem.Allocator, env_var: EnvVar, file_values: []const EnvFileValue) !?[]u8 {
    const key_z = try allocator.dupeZ(u8, env_var.name);
    defer allocator.free(key_z);
    if (std.c.getenv(key_z.ptr)) |process_value| {
        const value = std.mem.span(process_value);
        return try normalizeEnvValue(allocator, env_var.kind, value);
    }
    for (file_values) |file_value| {
        if (std.mem.eql(u8, file_value.name, env_var.name)) {
            return try normalizeEnvValue(allocator, env_var.kind, file_value.value);
        }
    }
    if (env_var.default_value) |value| {
        return try allocator.dupe(u8, value);
    }
    return null;
}

fn normalizeEnvValue(allocator: std.mem.Allocator, kind: EnvKind, raw: []const u8) ![]u8 {
    switch (kind) {
        .string => return allocator.dupe(u8, raw),
        .int => {
            const value = std.fmt.parseInt(i64, raw, 10) catch return error.InvalidEnvValue;
            return std.fmt.allocPrint(allocator, "{d}", .{value});
        },
        .uint => {
            const value = std.fmt.parseInt(u64, raw, 10) catch return error.InvalidEnvValue;
            return std.fmt.allocPrint(allocator, "{d}", .{value});
        },
        .bool => {
            if (std.ascii.eqlIgnoreCase(raw, "true") or std.mem.eql(u8, raw, "1")) return allocator.dupe(u8, "true");
            if (std.ascii.eqlIgnoreCase(raw, "false") or std.mem.eql(u8, raw, "0")) return allocator.dupe(u8, "false");
            return error.InvalidEnvValue;
        },
    }
}

fn generateEnvModule(allocator: std.mem.Allocator, vars: []const EnvVar) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, "// Generated by Yaan. Do not edit.\n\n");
    for (vars) |env_var| {
        const value = env_var.value orelse continue;
        try out.print(allocator, "pub const {s}: {s} = ", .{ env_var.name, envZigType(env_var.kind) });
        try appendZigValue(allocator, &out, env_var.kind, value);
        try out.appendSlice(allocator, ";\n");
    }
    return out.toOwnedSlice(allocator);
}

fn generatePublicEnvJs(allocator: std.mem.Allocator, vars: []const EnvVar) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, "// Generated by Yaan. Do not edit.\n");
    for (vars) |env_var| {
        if (env_var.visibility != .public) continue;
        const value = env_var.value orelse continue;
        try out.print(allocator, "export const {s} = ", .{env_var.name});
        try appendJsValue(allocator, &out, env_var.kind, value);
        try out.appendSlice(allocator, ";\n");
    }
    return out.toOwnedSlice(allocator);
}

fn envZigType(kind: EnvKind) []const u8 {
    return switch (kind) {
        .string => "[]const u8",
        .int => "i64",
        .uint => "u64",
        .bool => "bool",
    };
}

fn appendZigValue(allocator: std.mem.Allocator, out: *std.ArrayList(u8), kind: EnvKind, value: []const u8) !void {
    switch (kind) {
        .string => {
            const lit = try jsonString(allocator, value);
            defer allocator.free(lit);
            try out.appendSlice(allocator, lit);
        },
        .int, .uint, .bool => try out.appendSlice(allocator, value),
    }
}

fn appendJsValue(allocator: std.mem.Allocator, out: *std.ArrayList(u8), kind: EnvKind, value: []const u8) !void {
    switch (kind) {
        .string => {
            const lit = try jsonString(allocator, value);
            defer allocator.free(lit);
            try out.appendSlice(allocator, lit);
        },
        .int, .uint, .bool => try out.appendSlice(allocator, value),
    }
}

fn prepareRouteArtifacts(io: std.Io, allocator: std.mem.Allocator, routes: []router.RoutePattern) !usize {
    try writeTypedRoutes(io, allocator, routes);
    var failures = try runOptionsTypeCheck(io, allocator, routes);
    if (failures == 0) {
        try applyRouteOptions(io, allocator, routes);
        failures += validateRouteOptions(routes);
    }
    try writeTypedRoutes(io, allocator, routes);
    return failures;
}

fn prepareRemoteArtifacts(io: std.Io, allocator: std.mem.Allocator, remotes: []RemoteFunction) !usize {
    try writeRemoteArtifacts(io, allocator, remotes);
    const failures = try runRemoteTypeCheck(io, allocator, remotes);
    if (failures == 0) {
        try applyRemoteKinds(io, allocator, remotes);
    }
    try writeRemoteArtifacts(io, allocator, remotes);
    return failures;
}

fn prepareHookArtifacts(io: std.Io, allocator: std.mem.Allocator) !usize {
    try writeHookArtifacts(io, allocator);
    if (!try hasHooks(io)) return 0;
    return try runHookTypeCheck(io, allocator);
}

fn prepareAssetArtifacts(io: std.Io, allocator: std.mem.Allocator, out_dir: ?[]const u8) !void {
    var assets = try discoverAssets(io, allocator);
    defer deinitAssets(&assets, allocator);
    if (out_dir) |dir| try writeBuiltAssets(io, allocator, dir, assets.items);
    try writeAssetManifestArtifacts(io, allocator, out_dir, assets.items);
}

fn discoverAssets(io: std.Io, allocator: std.mem.Allocator) !std.ArrayList(AssetEntry) {
    const cwd = std.Io.Dir.cwd();
    var assets: std.ArrayList(AssetEntry) = .empty;
    errdefer deinitAssets(&assets, allocator);

    var static_dir = cwd.openDir(io, "static", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return assets,
        else => return err,
    };
    defer static_dir.close(io);

    var walker = try static_dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const static_path = try joinPath(allocator, "static", entry.path);
        defer allocator.free(static_path);
        const data = try cwd.readFileAlloc(io, static_path, allocator, .limited(64 * 1024 * 1024));
        defer allocator.free(data);
        const hash = contentHash(data);
        const output = try hashedAssetOutput(allocator, entry.path, hash);
        errdefer allocator.free(output);
        const url = try std.fmt.allocPrint(allocator, "/{s}", .{output});
        errdefer allocator.free(url);
        try assets.append(allocator, .{
            .logical = try allocator.dupe(u8, entry.path),
            .output = output,
            .url = url,
            .hash = hash,
            .size = data.len,
        });
    }
    return assets;
}

fn deinitAssets(assets: *std.ArrayList(AssetEntry), allocator: std.mem.Allocator) void {
    for (assets.items) |*asset_entry| asset_entry.deinit(allocator);
    assets.deinit(allocator);
}

fn writeBuiltAssets(io: std.Io, allocator: std.mem.Allocator, out_dir: []const u8, assets: []const AssetEntry) !void {
    const cwd = std.Io.Dir.cwd();
    const assets_dir = try joinPath(allocator, out_dir, "assets");
    defer allocator.free(assets_dir);
    try cwd.createDirPath(io, assets_dir);
    for (assets) |asset_entry| {
        const source_path = try joinPath(allocator, "static", asset_entry.logical);
        defer allocator.free(source_path);
        const data = try cwd.readFileAlloc(io, source_path, allocator, .limited(64 * 1024 * 1024));
        defer allocator.free(data);
        const output_path = try joinPath(allocator, out_dir, asset_entry.output);
        defer allocator.free(output_path);
        if (parentPath(output_path)) |parent| try cwd.createDirPath(io, parent);
        try cwd.writeFile(io, .{ .sub_path = output_path, .data = data });
    }
}

fn writeAssetManifestArtifacts(io: std.Io, allocator: std.mem.Allocator, out_dir: ?[]const u8, assets: []const AssetEntry) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, ".yaan");
    const zig_source = try assetsZigSource(allocator, assets);
    defer allocator.free(zig_source);
    try cwd.writeFile(io, .{ .sub_path = ".yaan/assets.zig", .data = zig_source });
    if (out_dir) |dir| {
        const json_source = try assetsJsonSource(allocator, assets);
        defer allocator.free(json_source);
        const manifest_source = try assetsManifestJsonSource(allocator, assets);
        defer allocator.free(manifest_source);
        const js_source = try assetsJsSource(allocator, json_source, manifest_source);
        defer allocator.free(js_source);
        const json_path = try joinPath(allocator, dir, "assets.json");
        defer allocator.free(json_path);
        const manifest_path = try joinPath(allocator, dir, "assets.manifest.json");
        defer allocator.free(manifest_path);
        const js_path = try joinPath(allocator, dir, "assets.js");
        defer allocator.free(js_path);
        try cwd.writeFile(io, .{ .sub_path = json_path, .data = json_source });
        try cwd.writeFile(io, .{ .sub_path = manifest_path, .data = manifest_source });
        try cwd.writeFile(io, .{ .sub_path = js_path, .data = js_source });
    }
}

fn writeErrorPages(io: std.Io, allocator: std.mem.Allocator, out_dir: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const error_dir = try joinPath(allocator, out_dir, "error");
    defer allocator.free(error_dir);
    try cwd.createDirPath(io, error_dir);
    const statuses = [_]u16{ 400, 401, 403, 404, 405, 409, 422, 500 };
    for (statuses) |status| {
        const body = (try readCustomErrorPage(io, allocator, status)) orelse try defaultErrorPage(allocator, status);
        defer allocator.free(body);
        const name = try std.fmt.allocPrint(allocator, "{d}.html", .{status});
        defer allocator.free(name);
        const nested_path = try joinPath(allocator, error_dir, name);
        defer allocator.free(nested_path);
        try cwd.writeFile(io, .{ .sub_path = nested_path, .data = body });
        if (status == 404) {
            const not_found_path = try joinPath(allocator, out_dir, "404.html");
            defer allocator.free(not_found_path);
            try cwd.writeFile(io, .{ .sub_path = not_found_path, .data = body });
        }
    }
}

fn readCustomErrorPage(io: std.Io, allocator: std.mem.Allocator, status: u16) !?[]u8 {
    const path = try std.fmt.allocPrint(allocator, "src/error/{d}.html", .{status});
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(512 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

fn defaultErrorPage(allocator: std.mem.Allocator, status: u16) ![]u8 {
    const title = statusTitle(status);
    return std.fmt.allocPrint(allocator,
        \\<!doctype html>
        \\<html>
        \\<head>
        \\  <meta charset="utf-8">
        \\  <meta name="viewport" content="width=device-width, initial-scale=1">
        \\  <title>{s}</title>
        \\  <style>body{{font-family:system-ui,sans-serif;margin:4rem;line-height:1.5;color:#111827}}main{{max-width:42rem}}</style>
        \\</head>
        \\<body><main><h1>{s}</h1><p>{s}</p></main></body>
        \\</html>
        \\
    , .{ title, title, defaultErrorMessage(status) });
}

fn statusTitle(status: u16) []const u8 {
    return switch (status) {
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        422 => "Unprocessable Entity",
        500 => "Internal Error",
        else => "Error",
    };
}

fn defaultErrorMessage(status: u16) []const u8 {
    return switch (status) {
        404 => "The requested page could not be found.",
        500 => "The server encountered an internal error.",
        else => "The request could not be completed.",
    };
}

fn writeTypedRoutes(io: std.Io, allocator: std.mem.Allocator, routes: []const router.RoutePattern) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, ".yaan");
    try writeDatabaseArtifact(io);
    const source = try router.generateZigRoutes(allocator, routes);
    defer allocator.free(source);
    try cwd.writeFile(io, .{ .sub_path = ".yaan/routes.zig", .data = source });
    const load_check = try router.generateLoadCheck(allocator, routes);
    defer allocator.free(load_check);
    try cwd.writeFile(io, .{ .sub_path = ".yaan/load_check.zig", .data = load_check });
    const load_runner = try router.generateLoadRunner(allocator, routes);
    defer allocator.free(load_runner);
    try cwd.writeFile(io, .{ .sub_path = ".yaan/load_runner.zig", .data = load_runner });
    const action_check = try router.generateActionCheck(allocator, routes);
    defer allocator.free(action_check);
    try cwd.writeFile(io, .{ .sub_path = ".yaan/action_check.zig", .data = action_check });
    const action_runner = try router.generateActionRunner(allocator, routes);
    defer allocator.free(action_runner);
    try cwd.writeFile(io, .{ .sub_path = ".yaan/action_runner.zig", .data = action_runner });
    const options_check = try router.generateOptionsCheck(allocator, routes);
    defer allocator.free(options_check);
    try cwd.writeFile(io, .{ .sub_path = ".yaan/options_check.zig", .data = options_check });
    const options_runner = try router.generateOptionsRunner(allocator, routes);
    defer allocator.free(options_runner);
    try cwd.writeFile(io, .{ .sub_path = ".yaan/options_runner.zig", .data = options_runner });
}

fn writeHookArtifacts(io: std.Io, allocator: std.mem.Allocator) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, ".yaan");
    try writeDatabaseArtifact(io);
    const hook_support = try generateHookSupport(allocator);
    defer allocator.free(hook_support);
    try cwd.writeFile(io, .{ .sub_path = ".yaan/hooks.zig", .data = hook_support });
    const hook_check = try generateHookCheck(allocator);
    defer allocator.free(hook_check);
    try cwd.writeFile(io, .{ .sub_path = ".yaan/hook_check.zig", .data = hook_check });
    const hook_runner = try generateHookRunner(allocator);
    defer allocator.free(hook_runner);
    try cwd.writeFile(io, .{ .sub_path = ".yaan/hook_runner.zig", .data = hook_runner });
}

fn writeRemoteArtifacts(io: std.Io, allocator: std.mem.Allocator, remotes: []const RemoteFunction) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, ".yaan");
    try writeDatabaseArtifact(io);
    const remote_support = try generateRemoteSupport(allocator);
    defer allocator.free(remote_support);
    try cwd.writeFile(io, .{ .sub_path = ".yaan/remote.zig", .data = remote_support });
    const remote_check = try generateRemoteCheck(allocator, remotes);
    defer allocator.free(remote_check);
    try cwd.writeFile(io, .{ .sub_path = ".yaan/remote_check.zig", .data = remote_check });
    const remote_manifest = try generateRemoteManifest(allocator, remotes);
    defer allocator.free(remote_manifest);
    try cwd.writeFile(io, .{ .sub_path = ".yaan/remote_manifest.zig", .data = remote_manifest });
    const remote_runner = try generateRemoteRunner(allocator, remotes);
    defer allocator.free(remote_runner);
    try cwd.writeFile(io, .{ .sub_path = ".yaan/remote_runner.zig", .data = remote_runner });
}

fn writeDatabaseArtifact(io: std.Io) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ".yaan/database.zig", .data = database_source });
}

fn generateHookSupport(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8,
        \\const std = @import("std");
        \\const database = @import("database");
        \\
        \\pub const Header = struct {
        \\    name: []const u8,
        \\    value: []const u8,
        \\};
        \\
        \\pub const Status = enum(u16) {
        \\    ok = 200,
        \\    bad_request = 400,
        \\    unauthorized = 401,
        \\    forbidden = 403,
        \\    not_found = 404,
        \\    conflict = 409,
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
        \\pub const Request = struct {
        \\    method: []const u8,
        \\    target: []const u8,
        \\    path: []const u8,
        \\    query: []const u8 = "",
        \\    headers: []const Header = &.{},
        \\    body: []const u8 = "",
        \\};
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
        \\pub const Response = struct {
        \\    status: u16 = 200,
        \\    content_type: []const u8 = "text/plain; charset=utf-8",
        \\    location: ?[]const u8 = null,
        \\    headers: []const Header = &.{},
        \\    body: []const u8 = "",
        \\};
        \\
        \\pub const Continue = struct {
        \\    path: ?[]const u8 = null,
        \\    headers: []const Header = &.{},
        \\};
        \\
        \\pub const Decision = union(enum) {
        \\    continue_: Continue,
        \\    halt: Response,
        \\};
        \\
        \\pub const EmptyLocals = struct {};
        \\
        \\pub const ErrorContext = struct {
        \\    allocator: std.mem.Allocator,
        \\    request: Request,
        \\    err: anyerror,
        \\    id: []const u8,
        \\    db: ?database.Database = null,
        \\    tracing: Tracing = .{},
        \\};
        \\
        \\pub fn Context(comptime Locals: type) type {
        \\    return struct {
        \\        allocator: std.mem.Allocator,
        \\        request: Request,
        \\        locals: Locals,
        \\        db: ?database.Database = null,
        \\        tracing: Tracing = .{},
        \\    };
        \\}
        \\
        \\pub fn Handler(comptime Locals: type) type {
        \\    return fn (*Context(Locals)) anyerror!Decision;
        \\}
        \\
        \\pub fn pass() Decision {
        \\    return .{ .continue_ = .{} };
        \\}
        \\
        \\pub fn rewrite(path: []const u8) Decision {
        \\    return .{ .continue_ = .{ .path = path } };
        \\}
        \\
        \\pub fn text(status: u16, body: []const u8) Decision {
        \\    return .{ .halt = .{ .status = status, .body = body } };
        \\}
        \\
        \\pub fn fail(allocator: std.mem.Allocator, status: Status, code: []const u8, message: []const u8) !Decision {
        \\    return .{ .halt = try errorResponse(allocator, status, .{ .message = message, .code = code }) };
        \\}
        \\
        \\pub fn errorResponse(allocator: std.mem.Allocator, status: Status, body: ErrorBody) !Response {
        \\    var body_writer: std.Io.Writer.Allocating = .init(allocator);
        \\    defer body_writer.deinit();
        \\    try std.json.Stringify.value(body, .{}, &body_writer.writer);
        \\    const json_body = try allocator.dupe(u8, body_writer.written());
        \\    return .{
        \\        .status = @intFromEnum(status),
        \\        .content_type = "application/json; charset=utf-8",
        \\        .body = json_body,
        \\    };
        \\}
        \\
        \\/// Canonical correlation id for an unexpected error: a stable hash of the
        \\/// error name and request path. Shared by every transport (in-process
        \\/// server and subprocess runners) so the same failure yields the same id
        \\/// in logs and in the response body.
        \\pub fn errorId(allocator: std.mem.Allocator, err: anyerror, path: []const u8) ![]const u8 {
        \\    var hasher = std.hash.Wyhash.init(0);
        \\    hasher.update(@errorName(err));
        \\    hasher.update(path);
        \\    return try std.fmt.allocPrint(allocator, "err-{x}", .{hasher.final()});
        \\}
        \\
        \\pub fn defaultOnError(ctx: *ErrorContext) Response {
        \\    std.debug.print("unexpected hook error {s} for {s} {s}; id={s}\n", .{ @errorName(ctx.err), ctx.request.method, ctx.request.path, ctx.id });
        \\    return errorResponse(ctx.allocator, .internal_server_error, .{
        \\        .message = "Internal Error",
        \\        .code = "internal_error",
        \\        .id = ctx.id,
        \\    }) catch .{
        \\        .status = 500,
        \\        .content_type = "application/json; charset=utf-8",
        \\        .body = "{\"message\":\"Internal Error\",\"code\":\"internal_error\",\"id\":\"allocation-failed\"}",
        \\    };
        \\}
        \\
        \\pub fn json(status: u16, body: []const u8) Decision {
        \\    return .{ .halt = .{ .status = status, .content_type = "application/json; charset=utf-8", .body = body } };
        \\}
        \\
        \\pub fn redirect(location: []const u8) Decision {
        \\    return .{ .halt = .{
        \\        .status = 302,
        \\        .location = location,
        \\        .body = "",
        \\    } };
        \\}
        \\
    );
}

fn generateHookCheck(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8,
        \\const hooks = @import("hooks");
        \\const app_hooks = @import("app_hooks");
        \\
        \\const Locals = if (@hasDecl(app_hooks, "Locals")) app_hooks.Locals else hooks.EmptyLocals;
        \\
        \\test "hooks type-check" {
        \\    const Handler = hooks.Handler(Locals);
        \\    const handle_fn: *const Handler = app_hooks.handle;
        \\    _ = handle_fn;
        \\    if (@hasDecl(app_hooks, "onError")) {
        \\        const OnError = fn (*hooks.ErrorContext) hooks.Response;
        \\        const on_error_fn: *const OnError = app_hooks.onError;
        \\        _ = on_error_fn;
        \\    }
        \\}
        \\
    );
}

fn generateHookRunner(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8,
        \\const std = @import("std");
        \\const hooks = @import("hooks");
        \\const app_hooks = @import("app_hooks");
        \\
        \\const Locals = if (@hasDecl(app_hooks, "Locals")) app_hooks.Locals else hooks.EmptyLocals;
        \\
        \\pub fn main(init: std.process.Init) !void {
        \\    const allocator = init.arena.allocator();
        \\    const args = try init.minimal.args.toSlice(allocator);
        \\    if (args.len < 5) return error.InvalidArguments;
        \\    var stdout_buffer: [8192]u8 = undefined;
        \\    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
        \\    const writer = &stdout_file_writer.interface;
        \\    const request = hooks.Request{
        \\        .method = args[1],
        \\        .target = args[2],
        \\        .path = args[3],
        \\        .query = queryPart(args[2]),
        \\        .body = args[4],
        \\    };
        \\    var ctx = hooks.Context(Locals){
        \\        .allocator = allocator,
        \\        .request = request,
        \\        .locals = .{},
        \\    };
        \\    const decision = app_hooks.handle(&ctx) catch |err| {
        \\        const id = try hooks.errorId(allocator, err, request.path);
        \\        var error_ctx = hooks.ErrorContext{
        \\            .allocator = allocator,
        \\            .request = request,
        \\            .err = err,
        \\            .id = id,
        \\        };
        \\        const response = if (@hasDecl(app_hooks, "onError")) app_hooks.onError(&error_ctx) else hooks.defaultOnError(&error_ctx);
        \\        try writeDecision(writer, .{ .halt = response });
        \\        try writer.flush();
        \\        return;
        \\    };
        \\    try writeDecision(writer, decision);
        \\    try writer.flush();
        \\}
        \\
        \\fn queryPart(target: []const u8) []const u8 {
        \\    const i = std.mem.indexOfScalar(u8, target, '?') orelse return "";
        \\    return target[i + 1 ..];
        \\}
        \\
        \\fn writeDecision(writer: *std.Io.Writer, decision: hooks.Decision) !void {
        \\    switch (decision) {
        \\        .continue_ => |next| {
        \\            try writer.writeAll("{\"action\":\"continue\",\"path\":");
        \\            if (next.path) |path| {
        \\                try std.json.Stringify.value(path, .{}, writer);
        \\            } else {
        \\                try writer.writeAll("null");
        \\            }
        \\            try writer.writeAll(",\"headers\":");
        \\            try std.json.Stringify.value(next.headers, .{}, writer);
        \\            try writer.writeAll("}");
        \\        },
        \\        .halt => |response| {
        \\            try writer.writeAll("{\"action\":\"halt\",\"status\":");
        \\            try writer.print("{d}", .{response.status});
        \\            try writer.writeAll(",\"content_type\":");
        \\            try std.json.Stringify.value(response.content_type, .{}, writer);
        \\            try writer.writeAll(",\"location\":");
        \\            if (response.location) |location| {
        \\                try std.json.Stringify.value(location, .{}, writer);
        \\            } else {
        \\                try writer.writeAll("null");
        \\            }
        \\            try writer.writeAll(",\"headers\":");
        \\            try std.json.Stringify.value(response.headers, .{}, writer);
        \\            try writer.writeAll(",\"body\":");
        \\            try std.json.Stringify.value(response.body, .{}, writer);
        \\            try writer.writeAll("}");
        \\        },
        \\    }
        \\}
        \\
    );
}

fn generateRemoteSupport(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8,
        \\const std = @import("std");
        \\const database = @import("database");
        \\
        \\pub const Kind = enum { query, command };
        \\
        \\pub const Status = enum(u16) {
        \\    ok = 200,
        \\    bad_request = 400,
        \\    unauthorized = 401,
        \\    forbidden = 403,
        \\    not_found = 404,
        \\    conflict = 409,
        \\    unprocessable_entity = 422,
        \\    internal_server_error = 500,
        \\};
        \\
        \\pub const Header = struct {
        \\    name: []const u8,
        \\    value: []const u8,
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
        \\pub const Request = struct {
        \\    method: []const u8,
        \\    path: []const u8,
        \\    body: []const u8 = "",
        \\};
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
        \\pub const Context = struct {
        \\    allocator: std.mem.Allocator,
        \\    request: Request,
        \\    db: ?database.Database = null,
        \\    tracing: Tracing = .{},
        \\};
        \\
    );
}

fn generateRemoteCheck(allocator: std.mem.Allocator, remotes: []const RemoteFunction) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator,
        \\const remote = @import("remote");
        \\
    );
    for (remotes) |remote_fn| {
        try out.print(allocator, "const remote_{s} = @import(\"remote_{s}\");\n", .{ remote_fn.name, remote_fn.name });
    }
    try out.appendSlice(allocator,
        \\
        \\test "remote functions type-check" {
        \\
    );
    for (remotes, 0..) |remote_fn, i| {
        try out.print(allocator,
            \\    const kind_{d}: remote.Kind = remote_{s}.kind;
            \\    _ = kind_{d};
            \\    const input_type_{d}: type = remote_{s}.Input;
            \\    _ = input_type_{d};
            \\    const remote_fn_{d} = remote_{s}.call;
            \\    _ = remote_fn_{d};
            \\
        , .{ i, remote_fn.name, i, i, remote_fn.name, i, i, remote_fn.name, i });
    }
    try out.appendSlice(allocator, "}\n");
    return out.toOwnedSlice(allocator);
}

fn generateRemoteManifest(allocator: std.mem.Allocator, remotes: []const RemoteFunction) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator,
        \\const std = @import("std");
        \\const remote = @import("remote");
        \\
    );
    for (remotes) |remote_fn| {
        try out.print(allocator, "const remote_{s} = @import(\"remote_{s}\");\n", .{ remote_fn.name, remote_fn.name });
    }
    try out.appendSlice(allocator,
        \\
        \\pub fn main(init: std.process.Init) !void {
        \\    var stdout_buffer: [8192]u8 = undefined;
        \\    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
        \\    const writer = &stdout_file_writer.interface;
        \\
    );
    for (remotes) |remote_fn| {
        try out.print(allocator,
            \\    try writeRemote(writer, "{s}", remote_{s}.kind);
            \\
        , .{ remote_fn.name, remote_fn.name });
    }
    try out.appendSlice(allocator,
        \\    try writer.flush();
        \\}
        \\
        \\fn writeRemote(writer: *std.Io.Writer, name: []const u8, kind: remote.Kind) !void {
        \\    try writer.print("{s}\t{s}\n", .{ name, @tagName(kind) });
        \\}
        \\
    );
    return out.toOwnedSlice(allocator);
}

fn generateRemoteRunner(allocator: std.mem.Allocator, remotes: []const RemoteFunction) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator,
        \\const std = @import("std");
        \\const remote = @import("remote");
        \\
    );
    for (remotes) |remote_fn| {
        try out.print(allocator, "const remote_{s} = @import(\"remote_{s}\");\n", .{ remote_fn.name, remote_fn.name });
    }
    try out.appendSlice(allocator,
        \\
        \\const Envelope = struct {
        \\    name: []const u8,
        \\    kind: []const u8,
        \\    input: std.json.Value = .null,
        \\};
        \\
        \\pub fn run(io: std.Io, allocator: std.mem.Allocator, method: []const u8, path: []const u8, body: []const u8) ![]u8 {
        \\    _ = io;
        \\    var arena = std.heap.ArenaAllocator.init(allocator);
        \\    defer arena.deinit();
        \\    const a = arena.allocator();
        \\    var out_writer: std.Io.Writer.Allocating = .init(a);
        \\    try dispatch(a, &out_writer.writer, method, path, body);
        \\    return try allocator.dupe(u8, out_writer.written());
        \\}
        \\
        \\pub fn main(init: std.process.Init) !void {
        \\    const allocator = init.arena.allocator();
        \\    const args = try init.minimal.args.toSlice(allocator);
        \\    if (args.len < 4) return error.InvalidArguments;
        \\    const json = try run(init.io, allocator, args[1], args[2], args[3]);
        \\    var stdout_buffer: [8192]u8 = undefined;
        \\    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
        \\    const w = &stdout_file_writer.interface;
        \\    try w.writeAll(json);
        \\    try w.flush();
        \\}
        \\
        \\fn dispatch(allocator: std.mem.Allocator, writer: *std.Io.Writer, method: []const u8, path: []const u8, body: []const u8) !void {
        \\    const envelope = try std.json.parseFromSliceLeaky(Envelope, allocator, body, .{});
        \\    const request = remote.Request{ .method = method, .path = path, .body = body };
        \\
    );
    for (remotes) |remote_fn| {
        try out.print(allocator,
            \\    if (std.mem.eql(u8, envelope.name, "{s}")) {{
            \\        if (!std.mem.eql(u8, envelope.kind, @tagName(remote_{s}.kind))) return try writeResponseEnvelope(allocator, writer, remote.fail(.bad_request, "remote_kind_mismatch", "Remote kind mismatch"));
            \\        const input = parseInput(remote_{s}.Input, allocator, envelope.input) catch |err| return try writeUnexpected(allocator, writer, err, request);
            \\        const ctx = remote.Context{{ .allocator = allocator, .request = request }};
            \\        const value = remote_{s}.call(ctx, input) catch |err| return try writeUnexpected(allocator, writer, err, request);
            \\        if (@TypeOf(value) == void) {{
            \\            return try writeVoidResult(writer);
            \\        }} else {{
            \\            return try writeRemoteValue(allocator, writer, value);
            \\        }}
            \\    }}
            \\
        , .{ remote_fn.name, remote_fn.name, remote_fn.name, remote_fn.name });
    }
    try out.appendSlice(allocator,
        \\    return try writeResponseEnvelope(allocator, writer, remote.fail(.not_found, "remote_not_found", "Remote not found"));
        \\}
        \\
        \\fn parseInput(comptime T: type, allocator: std.mem.Allocator, value: std.json.Value) !T {
        \\    if (T == void) return {};
        \\    var aw: std.Io.Writer.Allocating = .init(allocator);
        \\    defer aw.deinit();
        \\    try std.json.Stringify.value(value, .{}, &aw.writer);
        \\    return try std.json.parseFromSliceLeaky(T, allocator, aw.written(), .{});
        \\}
        \\
        \\fn writeRemoteValue(allocator: std.mem.Allocator, writer: *std.Io.Writer, value: anytype) !void {
        \\    const T = @TypeOf(value);
        \\    if (T == remote.Response) {
        \\        return try writeResponseEnvelope(allocator, writer, value);
        \\    }
        \\    if (@hasDecl(T, "__yaan_result")) {
        \\        return switch (value) {
        \\            .value => |data| try writeResult(writer, data),
        \\            .fail => |response| try writeResponseEnvelope(allocator, writer, response),
        \\        };
        \\    }
        \\    try writeResult(writer, value);
        \\}
        \\
        \\fn writeResult(writer: *std.Io.Writer, value: anytype) !void {
        \\    try writer.writeAll("{\"value\":");
        \\    try std.json.Stringify.value(value, .{}, writer);
        \\    try writer.writeAll("}");
        \\}
        \\
        \\fn writeVoidResult(writer: *std.Io.Writer) !void {
        \\    try writer.writeAll("{\"value\":null}");
        \\}
        \\
        \\fn writeUnexpected(allocator: std.mem.Allocator, writer: *std.Io.Writer, err: anyerror, request: remote.Request) !void {
        \\    std.debug.print("unexpected remote error {s} for {s} {s}\n", .{ @errorName(err), request.method, request.path });
        \\    const id = try errorId(allocator, err, request.path);
        \\    try writeResponseEnvelope(allocator, writer, .{
        \\        .status = .internal_server_error,
        \\        .body = .{ .message = "Internal Error", .code = "internal_error", .id = id },
        \\    });
        \\}
        \\
        \\fn writeResponseEnvelope(allocator: std.mem.Allocator, writer: *std.Io.Writer, response: remote.Response) !void {
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
        \\    try writer.flush();
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

fn runLoadTypeCheck(io: std.Io, allocator: std.mem.Allocator, routes: []const router.RoutePattern) !usize {
    var load_count: usize = 0;
    for (routes) |route| {
        if (route.load_file != null) load_count += 1;
    }
    if (load_count == 0) return 0;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try appendLoadTestArgs(allocator, &argv, routes);

    const result = try std.process.run(allocator, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        std.debug.print("{s}{s}", .{ result.stdout, result.stderr });
        return 1;
    }
    return 0;
}

fn hasLoaders(routes: []const router.RoutePattern) bool {
    for (routes) |route| {
        if (route.load_file != null) return true;
    }
    return false;
}

fn runActionTypeCheck(io: std.Io, allocator: std.mem.Allocator, routes: []const router.RoutePattern) !usize {
    if (!hasActions(routes)) return 0;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try appendActionTestArgs(allocator, &argv, routes);

    const result = try std.process.run(allocator, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        std.debug.print("{s}{s}", .{ result.stdout, result.stderr });
        return 1;
    }
    return 0;
}

fn hasActions(routes: []const router.RoutePattern) bool {
    for (routes) |route| {
        if (route.actions_file != null) return true;
    }
    return false;
}

fn runOptionsTypeCheck(io: std.Io, allocator: std.mem.Allocator, routes: []const router.RoutePattern) !usize {
    if (!hasOptions(routes)) return 0;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try appendOptionsTestArgs(allocator, &argv, routes);

    const result = try std.process.run(allocator, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        std.debug.print("{s}{s}", .{ result.stdout, result.stderr });
        return 1;
    }
    return 0;
}

fn applyRouteOptions(io: std.Io, allocator: std.mem.Allocator, routes: []router.RoutePattern) !void {
    if (!hasOptions(routes)) return;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try appendOptionsRunArgs(allocator, &argv, routes);

    const result = try std.process.run(allocator, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(128 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        std.debug.print("{s}{s}", .{ result.stdout, result.stderr });
        return error.CheckFailed;
    }
    try parseOptionsOutput(routes, result.stdout);
}

fn parseOptionsOutput(routes: []router.RoutePattern, output: []const u8) !void {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const name = fields.next() orelse return error.InvalidOptionsOutput;
        const prerender = fields.next() orelse return error.InvalidOptionsOutput;
        const csr = fields.next() orelse return error.InvalidOptionsOutput;
        const trailing_slash = fields.next() orelse return error.InvalidOptionsOutput;
        if (fields.next() != null) return error.InvalidOptionsOutput;

        const route = findRouteByName(routes, name) orelse return error.InvalidOptionsOutput;
        route.options = .{
            .prerender = try parsePrerender(prerender),
            .csr = try parseBool(csr),
            .trailing_slash = try parseTrailingSlash(trailing_slash),
        };
    }
}

fn findRouteByName(routes: []router.RoutePattern, name: []const u8) ?*router.RoutePattern {
    for (routes) |*route| {
        if (std.mem.eql(u8, route.name, name)) return route;
    }
    return null;
}

fn parsePrerender(value: []const u8) !router.Prerender {
    if (std.mem.eql(u8, value, "auto")) return .auto;
    if (std.mem.eql(u8, value, "always")) return .always;
    if (std.mem.eql(u8, value, "never")) return .never;
    return error.InvalidOptionsOutput;
}

fn parseTrailingSlash(value: []const u8) !router.TrailingSlash {
    if (std.mem.eql(u8, value, "ignore")) return .ignore;
    if (std.mem.eql(u8, value, "always")) return .always;
    if (std.mem.eql(u8, value, "never")) return .never;
    return error.InvalidOptionsOutput;
}

fn parseBool(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return error.InvalidOptionsOutput;
}

fn hasOptions(routes: []const router.RoutePattern) bool {
    for (routes) |route| {
        if (route.options_file != null) return true;
    }
    return false;
}

fn hasHooks(io: std.Io) !bool {
    const cwd = std.Io.Dir.cwd();
    cwd.access(io, "src/hooks.zig", .{ .read = true }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn runHookTypeCheck(io: std.Io, allocator: std.mem.Allocator) !usize {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try appendHookTestArgs(allocator, &argv);

    const result = try std.process.run(allocator, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        std.debug.print("{s}{s}", .{ result.stdout, result.stderr });
        return 1;
    }
    return 0;
}

fn runRemoteTypeCheck(io: std.Io, allocator: std.mem.Allocator, remotes: []const RemoteFunction) !usize {
    if (remotes.len == 0) return 0;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try appendRemoteTestArgs(allocator, &argv, remotes);

    const result = try std.process.run(allocator, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        std.debug.print("{s}{s}", .{ result.stdout, result.stderr });
        return 1;
    }
    return 0;
}

fn applyRemoteKinds(io: std.Io, allocator: std.mem.Allocator, remotes: []RemoteFunction) !void {
    if (remotes.len == 0) return;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try appendRemoteManifestArgs(allocator, &argv, remotes);

    const result = try std.process.run(allocator, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(128 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        std.debug.print("{s}{s}", .{ result.stdout, result.stderr });
        return error.CheckFailed;
    }
    try parseRemoteManifest(allocator, remotes, result.stdout);
}

fn parseRemoteManifest(allocator: std.mem.Allocator, remotes: []RemoteFunction, output: []const u8) !void {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const name = fields.next() orelse return error.InvalidRemoteManifest;
        const kind = fields.next() orelse return error.InvalidRemoteManifest;
        if (fields.next() != null) return error.InvalidRemoteManifest;
        if (!std.mem.eql(u8, kind, "query") and !std.mem.eql(u8, kind, "command")) return error.InvalidRemoteManifest;
        const remote_fn = findRemoteByName(remotes, name) orelse return error.InvalidRemoteManifest;
        if (remote_fn.kind) |old_kind| allocator.free(old_kind);
        remote_fn.kind = try allocator.dupe(u8, kind);
    }
}

fn findRemoteByName(remotes: []RemoteFunction, name: []const u8) ?*RemoteFunction {
    for (remotes) |*remote_fn| {
        if (std.mem.eql(u8, remote_fn.name, name)) return remote_fn;
    }
    return null;
}

fn appendLoadTestArgs(allocator: std.mem.Allocator, argv: *std.ArrayList([]const u8), routes: []const router.RoutePattern) !void {
    try argv.append(allocator, "zig");
    try argv.append(allocator, "test");
    try appendLoadModuleArgs(allocator, argv, routes, ".yaan/load_check.zig");
}

fn appendLoadCompileArgs(allocator: std.mem.Allocator, argv: *std.ArrayList([]const u8), routes: []const router.RoutePattern) !void {
    try argv.append(allocator, "zig");
    try argv.append(allocator, "build-exe");
    try argv.append(allocator, "-femit-bin=.yaan/load_runner");
    try appendLoadModuleArgs(allocator, argv, routes, ".yaan/load_runner.zig");
}

fn appendRemoteTestArgs(allocator: std.mem.Allocator, argv: *std.ArrayList([]const u8), remotes: []const RemoteFunction) !void {
    try argv.append(allocator, "zig");
    try argv.append(allocator, "test");
    try appendRemoteModuleArgs(allocator, argv, remotes, ".yaan/remote_check.zig");
}

fn appendRemoteManifestArgs(allocator: std.mem.Allocator, argv: *std.ArrayList([]const u8), remotes: []const RemoteFunction) !void {
    try argv.append(allocator, "zig");
    try argv.append(allocator, "run");
    try appendRemoteModuleArgs(allocator, argv, remotes, ".yaan/remote_manifest.zig");
}

fn appendRemoteCompileArgs(allocator: std.mem.Allocator, argv: *std.ArrayList([]const u8), remotes: []const RemoteFunction) !void {
    try argv.append(allocator, "zig");
    try argv.append(allocator, "build-exe");
    try argv.append(allocator, "-femit-bin=.yaan/remote_runner");
    try appendRemoteModuleArgs(allocator, argv, remotes, ".yaan/remote_runner.zig");
}

fn appendHookTestArgs(allocator: std.mem.Allocator, argv: *std.ArrayList([]const u8)) !void {
    try argv.append(allocator, "zig");
    try argv.append(allocator, "test");
    try appendHookModuleArgs(allocator, argv, ".yaan/hook_check.zig");
}

fn appendHookCompileArgs(allocator: std.mem.Allocator, argv: *std.ArrayList([]const u8)) !void {
    try argv.append(allocator, "zig");
    try argv.append(allocator, "build-exe");
    try argv.append(allocator, "-femit-bin=.yaan/hook_runner");
    try appendHookModuleArgs(allocator, argv, ".yaan/hook_runner.zig");
}

fn appendHookModuleArgs(allocator: std.mem.Allocator, argv: *std.ArrayList([]const u8), root: []const u8) !void {
    try argv.append(allocator, "--dep");
    try argv.append(allocator, "hooks");
    try argv.append(allocator, "--dep");
    try argv.append(allocator, "app_hooks");
    try argv.append(allocator, "--dep");
    try argv.append(allocator, "env");
    try argv.append(allocator, "--dep");
    try argv.append(allocator, "database");
    try argv.append(allocator, "--dep");
    try argv.append(allocator, "assets");
    try argv.append(allocator, try std.fmt.allocPrint(allocator, "-Mroot={s}", .{root}));
    try argv.append(allocator, "--dep");
    try argv.append(allocator, "database");
    try argv.append(allocator, "--dep");
    try argv.append(allocator, "assets");
    try argv.append(allocator, "-Mhooks=.yaan/hooks.zig");
    try argv.append(allocator, "-Menv=.yaan/env.zig");
    try argv.append(allocator, "-Mdatabase=.yaan/database.zig");
    try argv.append(allocator, "-Massets=.yaan/assets.zig");
    try argv.append(allocator, "--dep");
    try argv.append(allocator, "hooks");
    try argv.append(allocator, "--dep");
    try argv.append(allocator, "env");
    try argv.append(allocator, "--dep");
    try argv.append(allocator, "database");
    try argv.append(allocator, "--dep");
    try argv.append(allocator, "assets");
    try argv.append(allocator, "-Mapp_hooks=src/hooks.zig");
}

fn appendRemoteModuleArgs(allocator: std.mem.Allocator, argv: *std.ArrayList([]const u8), remotes: []const RemoteFunction, root: []const u8) !void {
    try argv.append(allocator, "--dep");
    try argv.append(allocator, "remote");
    try argv.append(allocator, "--dep");
    try argv.append(allocator, "env");
    try argv.append(allocator, "--dep");
    try argv.append(allocator, "database");
    try argv.append(allocator, "--dep");
    try argv.append(allocator, "assets");
    for (remotes) |remote_fn| {
        try argv.append(allocator, "--dep");
        try argv.append(allocator, try std.fmt.allocPrint(allocator, "remote_{s}", .{remote_fn.name}));
    }
    try argv.append(allocator, try std.fmt.allocPrint(allocator, "-Mroot={s}", .{root}));
    try argv.append(allocator, "--dep");
    try argv.append(allocator, "database");
    try argv.append(allocator, "--dep");
    try argv.append(allocator, "assets");
    try argv.append(allocator, "-Mremote=.yaan/remote.zig");
    try argv.append(allocator, "-Menv=.yaan/env.zig");
    try argv.append(allocator, "-Mdatabase=.yaan/database.zig");
    try argv.append(allocator, "-Massets=.yaan/assets.zig");

    for (remotes) |remote_fn| {
        try argv.append(allocator, "--dep");
        try argv.append(allocator, "remote");
        try argv.append(allocator, "--dep");
        try argv.append(allocator, "env");
        try argv.append(allocator, "--dep");
        try argv.append(allocator, "database");
        try argv.append(allocator, "--dep");
        try argv.append(allocator, "assets");
        try argv.append(allocator, try std.fmt.allocPrint(allocator, "-Mremote_{s}={s}", .{ remote_fn.name, remote_fn.file }));
    }
}

fn appendOptionsTestArgs(allocator: std.mem.Allocator, argv: *std.ArrayList([]const u8), routes: []const router.RoutePattern) !void {
    try argv.append(allocator, "zig");
    try argv.append(allocator, "test");
    try appendOptionsModuleArgs(allocator, argv, routes, ".yaan/options_check.zig");
}

fn appendOptionsRunArgs(allocator: std.mem.Allocator, argv: *std.ArrayList([]const u8), routes: []const router.RoutePattern) !void {
    try argv.append(allocator, "zig");
    try argv.append(allocator, "run");
    try appendOptionsModuleArgs(allocator, argv, routes, ".yaan/options_runner.zig");
}

fn appendOptionsModuleArgs(allocator: std.mem.Allocator, argv: *std.ArrayList([]const u8), routes: []const router.RoutePattern, root: []const u8) !void {
    var options_count: usize = 0;
    for (routes) |route| {
        if (route.options_file != null) options_count += 1;
    }

    try argv.append(allocator, "--dep");
    try argv.append(allocator, "routes");
    try argv.append(allocator, "--dep");
    try argv.append(allocator, "database");
    try argv.append(allocator, "--dep");
    try argv.append(allocator, "assets");
    for (0..options_count) |i| {
        try argv.append(allocator, "--dep");
        try argv.append(allocator, try std.fmt.allocPrint(allocator, "options_{d}", .{i}));
    }
    try argv.append(allocator, try std.fmt.allocPrint(allocator, "-Mroot={s}", .{root}));
    try argv.append(allocator, "--dep");
    try argv.append(allocator, "database");
    try argv.append(allocator, "--dep");
    try argv.append(allocator, "assets");
    try argv.append(allocator, "-Mroutes=.yaan/routes.zig");
    try argv.append(allocator, "-Mdatabase=.yaan/database.zig");
    try argv.append(allocator, "-Massets=.yaan/assets.zig");

    var options_index: usize = 0;
    for (routes) |route| {
        if (route.options_file) |options_file| {
            try argv.append(allocator, "--dep");
            try argv.append(allocator, "routes");
            try argv.append(allocator, "--dep");
            try argv.append(allocator, "database");
            try argv.append(allocator, "--dep");
            try argv.append(allocator, "assets");
            try argv.append(allocator, try std.fmt.allocPrint(allocator, "-Moptions_{d}={s}", .{ options_index, options_file }));
            options_index += 1;
        }
    }
}

fn appendActionTestArgs(allocator: std.mem.Allocator, argv: *std.ArrayList([]const u8), routes: []const router.RoutePattern) !void {
    try argv.append(allocator, "zig");
    try argv.append(allocator, "test");
    try appendActionModuleArgs(allocator, argv, routes, ".yaan/action_check.zig");
}

fn appendActionCompileArgs(allocator: std.mem.Allocator, argv: *std.ArrayList([]const u8), routes: []const router.RoutePattern) !void {
    try argv.append(allocator, "zig");
    try argv.append(allocator, "build-exe");
    try argv.append(allocator, "-femit-bin=.yaan/action_runner");
    try appendActionModuleArgs(allocator, argv, routes, ".yaan/action_runner.zig");
}

fn appendActionModuleArgs(allocator: std.mem.Allocator, argv: *std.ArrayList([]const u8), routes: []const router.RoutePattern, root: []const u8) !void {
    try argv.append(allocator, "--dep");
    try argv.append(allocator, "routes");
    try argv.append(allocator, "--dep");
    try argv.append(allocator, "env");
    try argv.append(allocator, "--dep");
    try argv.append(allocator, "database");
    try argv.append(allocator, "--dep");
    try argv.append(allocator, "assets");
    for (routes) |route| {
        if (route.actions_file != null) {
            try argv.append(allocator, "--dep");
            try argv.append(allocator, try std.fmt.allocPrint(allocator, "action_{s}", .{route.name}));
        }
    }
    try argv.append(allocator, try std.fmt.allocPrint(allocator, "-Mroot={s}", .{root}));
    try argv.append(allocator, "--dep");
    try argv.append(allocator, "database");
    try argv.append(allocator, "--dep");
    try argv.append(allocator, "assets");
    try argv.append(allocator, "-Mroutes=.yaan/routes.zig");
    try argv.append(allocator, "-Menv=.yaan/env.zig");
    try argv.append(allocator, "-Mdatabase=.yaan/database.zig");
    try argv.append(allocator, "-Massets=.yaan/assets.zig");

    for (routes) |route| {
        if (route.actions_file) |actions_file| {
            try argv.append(allocator, "--dep");
            try argv.append(allocator, "routes");
            try argv.append(allocator, "--dep");
            try argv.append(allocator, "env");
            try argv.append(allocator, "--dep");
            try argv.append(allocator, "database");
            try argv.append(allocator, "--dep");
            try argv.append(allocator, "assets");
            try argv.append(allocator, try std.fmt.allocPrint(allocator, "-Maction_{s}={s}", .{ route.name, actions_file }));
        }
    }
}

fn appendLoadModuleArgs(allocator: std.mem.Allocator, argv: *std.ArrayList([]const u8), routes: []const router.RoutePattern, root: []const u8) !void {
    try argv.append(allocator, "--dep");
    try argv.append(allocator, "routes");
    try argv.append(allocator, "--dep");
    try argv.append(allocator, "env");
    try argv.append(allocator, "--dep");
    try argv.append(allocator, "database");
    try argv.append(allocator, "--dep");
    try argv.append(allocator, "assets");
    for (routes) |route| {
        if (route.load_file != null) {
            try argv.append(allocator, "--dep");
            try argv.append(allocator, try std.fmt.allocPrint(allocator, "load_{s}", .{route.name}));
        }
    }
    try argv.append(allocator, try std.fmt.allocPrint(allocator, "-Mroot={s}", .{root}));
    try argv.append(allocator, "--dep");
    try argv.append(allocator, "database");
    try argv.append(allocator, "--dep");
    try argv.append(allocator, "assets");
    try argv.append(allocator, "-Mroutes=.yaan/routes.zig");
    try argv.append(allocator, "-Menv=.yaan/env.zig");
    try argv.append(allocator, "-Mdatabase=.yaan/database.zig");
    try argv.append(allocator, "-Massets=.yaan/assets.zig");

    for (routes) |route| {
        if (route.load_file) |load_file| {
            try argv.append(allocator, "--dep");
            try argv.append(allocator, "routes");
            try argv.append(allocator, "--dep");
            try argv.append(allocator, "env");
            try argv.append(allocator, "--dep");
            try argv.append(allocator, "database");
            try argv.append(allocator, "--dep");
            try argv.append(allocator, "assets");
            try argv.append(allocator, try std.fmt.allocPrint(allocator, "-Mload_{s}={s}", .{ route.name, load_file }));
        }
    }
}

fn cloneRoute(allocator: std.mem.Allocator, route: router.RoutePattern) !router.RoutePattern {
    var groups = try allocator.alloc([]u8, route.groups.len);
    var groups_len: usize = 0;
    errdefer {
        for (groups[0..groups_len]) |group| allocator.free(group);
        allocator.free(groups);
    }
    for (route.groups, 0..) |group, i| {
        groups[i] = try allocator.dupe(u8, group);
        groups_len += 1;
    }

    var segments = try allocator.alloc(router.Segment, route.segments.len);
    var segments_len: usize = 0;
    errdefer {
        for (segments[0..segments_len]) |segment| allocator.free(segment.name);
        allocator.free(segments);
    }
    for (route.segments, 0..) |segment, i| {
        segments[i] = .{
            .kind = segment.kind,
            .name = try allocator.dupe(u8, segment.name),
            .param_type = segment.param_type,
        };
        segments_len += 1;
    }
    return .{
        .file = try allocator.dupe(u8, route.file),
        .load_file = if (route.load_file) |load_file| try allocator.dupe(u8, load_file) else null,
        .actions_file = if (route.actions_file) |actions_file| try allocator.dupe(u8, actions_file) else null,
        .options_file = if (route.options_file) |options_file| try allocator.dupe(u8, options_file) else null,
        .options = route.options,
        .path = try allocator.dupe(u8, route.path),
        .shape = try allocator.dupe(u8, route.shape),
        .name = try allocator.dupe(u8, route.name),
        .groups = groups,
        .segments = segments,
        .score = route.score,
    };
}

fn routesJson(allocator: std.mem.Allocator, routes: []const BuildRoute) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(allocator, '[');
    for (routes, 0..) |route, i| {
        if (i > 0) try out.append(allocator, ',');
        const path_lit = try jsonString(allocator, route.route.path);
        defer allocator.free(path_lit);
        const module_lit = try jsonString(allocator, route.module);
        defer allocator.free(module_lit);
        try out.print(allocator, "{{\"path\":{s},\"module\":{s},\"groups\":", .{ path_lit, module_lit });
        try appendGroupsJson(allocator, &out, route.route.groups);
        try out.appendSlice(allocator, ",\"options\":");
        try appendOptionsJson(allocator, &out, route.route.options);
        try out.append(allocator, '}');
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

fn remotesJs(allocator: std.mem.Allocator, remotes: []const RemoteFunction) ![]u8 {
    var entries = try allocator.alloc(codegen.RemoteEntry, remotes.len);
    defer allocator.free(entries);
    for (remotes, 0..) |remote_fn, i| {
        entries[i] = .{
            .name = remote_fn.name,
            .kind = remote_fn.kind orelse "query",
        };
    }
    return codegen.remotesSource(allocator, entries);
}

fn appendGroupsJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), groups: []const []const u8) !void {
    try out.append(allocator, '[');
    for (groups, 0..) |group, i| {
        if (i > 0) try out.append(allocator, ',');
        const lit = try jsonString(allocator, group);
        defer allocator.free(lit);
        try out.appendSlice(allocator, lit);
    }
    try out.append(allocator, ']');
}

fn appendOptionsJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), options: router.RouteOptions) !void {
    try out.print(allocator, "{{\"prerender\":\"{s}\",\"csr\":{},\"trailingSlash\":\"{s}\"}}", .{
        @tagName(options.prerender),
        options.csr,
        @tagName(options.trailing_slash),
    });
}

fn contentHash(data: []const u8) [16]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    var out: [16]u8 = undefined;
    writeHexBytes(out[0..], digest[0..8]);
    return out;
}

fn writeHexBytes(out: []u8, bytes: []const u8) void {
    const alphabet = "0123456789abcdef";
    for (bytes, 0..) |byte, i| {
        out[i * 2] = alphabet[byte >> 4];
        out[i * 2 + 1] = alphabet[byte & 0x0f];
    }
}

fn hashedAssetOutput(allocator: std.mem.Allocator, logical: []const u8, hash: [16]u8) ![]u8 {
    const slash = std.mem.lastIndexOfScalar(u8, logical, '/');
    const dir = if (slash) |i| logical[0..i] else "";
    const base = if (slash) |i| logical[i + 1 ..] else logical;
    const dot = std.mem.lastIndexOfScalar(u8, base, '.');
    const stem = if (dot) |i| base[0..i] else base;
    const ext = if (dot) |i| base[i..] else "";
    if (dir.len > 0) {
        return std.fmt.allocPrint(allocator, "assets/{s}/{s}.{s}{s}", .{ dir, stem, hash, ext });
    }
    return std.fmt.allocPrint(allocator, "assets/{s}.{s}{s}", .{ stem, hash, ext });
}

fn assetsJsonSource(allocator: std.mem.Allocator, assets: []const AssetEntry) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(allocator, '{');
    for (assets, 0..) |asset_entry, i| {
        if (i > 0) try out.append(allocator, ',');
        const logical = try jsonString(allocator, asset_entry.logical);
        defer allocator.free(logical);
        const url = try jsonString(allocator, asset_entry.url);
        defer allocator.free(url);
        try out.print(allocator, "{s}:{s}", .{ logical, url });
    }
    try out.append(allocator, '}');
    try out.append(allocator, '\n');
    return out.toOwnedSlice(allocator);
}

fn assetsManifestJsonSource(allocator: std.mem.Allocator, assets: []const AssetEntry) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(allocator, '[');
    for (assets, 0..) |asset_entry, i| {
        if (i > 0) try out.append(allocator, ',');
        const logical = try jsonString(allocator, asset_entry.logical);
        defer allocator.free(logical);
        const url = try jsonString(allocator, asset_entry.url);
        defer allocator.free(url);
        const output = try jsonString(allocator, asset_entry.output);
        defer allocator.free(output);
        const inline_json = if (asset_entry.inline_data) |data| try jsonString(allocator, data) else try allocator.dupe(u8, "null");
        defer allocator.free(inline_json);
        try out.print(allocator, "{{\"logical\":{s},\"path\":{s},\"output\":{s},\"hash\":\"{s}\",\"size\":{d},\"inline\":{s}}}", .{
            logical,
            url,
            output,
            asset_entry.hash,
            asset_entry.size,
            inline_json,
        });
    }
    try out.append(allocator, ']');
    try out.append(allocator, '\n');
    return out.toOwnedSlice(allocator);
}

fn assetsJsSource(allocator: std.mem.Allocator, manifest_json: []const u8, metadata_json: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\export const assets = {s};
        \\export const assetManifest = {s};
        \\export function asset(name) {{
        \\  const key = String(name).startsWith('/') ? String(name).slice(1) : String(name);
        \\  return assets[key] ?? assets[String(name)] ?? name;
        \\}}
        \\export function assetEntry(name) {{
        \\  const key = String(name).startsWith('/') ? String(name).slice(1) : String(name);
        \\  return assetManifest.find((entry) => entry.logical === key || entry.logical === String(name)) ?? null;
        \\}}
        \\
    , .{ std.mem.trim(u8, manifest_json, " \t\r\n"), std.mem.trim(u8, metadata_json, " \t\r\n") });
}

fn assetsZigSource(allocator: std.mem.Allocator, assets: []const AssetEntry) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator,
        \\const std = @import("std");
        \\
        \\pub const Entry = struct {
        \\    logical: []const u8,
        \\    path: []const u8,
        \\    output: []const u8,
        \\    hash: []const u8,
        \\    size: usize,
        \\    inline_data: ?[]const u8 = null,
        \\};
        \\
        \\pub const manifest = [_]Entry{
        \\
    );
    for (assets) |asset_entry| {
        const logical = try zigString(allocator, asset_entry.logical);
        defer allocator.free(logical);
        const url = try zigString(allocator, asset_entry.url);
        defer allocator.free(url);
        const output = try zigString(allocator, asset_entry.output);
        defer allocator.free(output);
        const inline_data = if (asset_entry.inline_data) |data| try zigString(allocator, data) else try allocator.dupe(u8, "null");
        defer allocator.free(inline_data);
        try out.print(allocator, "    .{{ .logical = {s}, .path = {s}, .output = {s}, .hash = \"{s}\", .size = {d}, .inline_data = {s} }},\n", .{ logical, url, output, asset_entry.hash, asset_entry.size, inline_data });
    }
    try out.appendSlice(allocator,
        \\};
        \\
        \\pub fn asset(logical: []const u8) []const u8 {
        \\    const key = if (logical.len > 0 and logical[0] == '/') logical[1..] else logical;
        \\    for (manifest) |entry| {
        \\        if (std.mem.eql(u8, entry.logical, key) or std.mem.eql(u8, entry.logical, logical)) return entry.path;
        \\    }
        \\    return logical;
        \\}
        \\
        \\pub fn assetEntry(logical: []const u8) ?Entry {
        \\    const key = if (logical.len > 0 and logical[0] == '/') logical[1..] else logical;
        \\    for (manifest) |entry| {
        \\        if (std.mem.eql(u8, entry.logical, key) or std.mem.eql(u8, entry.logical, logical)) return entry;
        \\    }
        \\    return null;
        \\}
        \\
    );
    return out.toOwnedSlice(allocator);
}

fn zigString(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(allocator, '"');
    for (value) |c| switch (c) {
        '"' => try out.appendSlice(allocator, "\\\""),
        '\\' => try out.appendSlice(allocator, "\\\\"),
        '\n' => try out.appendSlice(allocator, "\\n"),
        '\r' => try out.appendSlice(allocator, "\\r"),
        else => try out.append(allocator, c),
    };
    try out.append(allocator, '"');
    return out.toOwnedSlice(allocator);
}

fn jsonString(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(allocator, '"');
    for (value) |c| switch (c) {
        '"' => try out.appendSlice(allocator, "\\\""),
        '\\' => try out.appendSlice(allocator, "\\\\"),
        '\n' => try out.appendSlice(allocator, "\\n"),
        '\r' => try out.appendSlice(allocator, "\\r"),
        else => try out.append(allocator, c),
    };
    try out.append(allocator, '"');
    return out.toOwnedSlice(allocator);
}

fn parentPath(path: []const u8) ?[]const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return null;
    if (slash == 0) return null;
    return path[0..slash];
}

fn joinPath(allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]u8 {
    if (a.len == 0) return allocator.dupe(u8, b);
    if (a[a.len - 1] == '/') return std.fmt.allocPrint(allocator, "{s}{s}", .{ a, b });
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ a, b });
}

test "check source fails malformed input" {
    const result = try checkSource(std.testing.allocator, "bad.yn", "<p>{oops</p>");
    try std.testing.expect(!result.ok);
}

test "asset manifest helpers emit hashed assets" {
    const hash = contentHash("hello");
    const output = try hashedAssetOutput(std.testing.allocator, "icons/logo.svg", hash);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.startsWith(u8, output, "assets/icons/logo."));
    try std.testing.expect(std.mem.endsWith(u8, output, ".svg"));

    var entries = [_]AssetEntry{.{
        .logical = try std.testing.allocator.dupe(u8, "icons/logo.svg"),
        .output = try std.testing.allocator.dupe(u8, output),
        .url = try std.testing.allocator.dupe(u8, "/assets/icons/logo.abc.svg"),
        .hash = hash,
        .size = 5,
    }};
    defer entries[0].deinit(std.testing.allocator);
    const json = try assetsJsonSource(std.testing.allocator, &entries);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"icons/logo.svg\"") != null);
    const metadata = try assetsManifestJsonSource(std.testing.allocator, &entries);
    defer std.testing.allocator.free(metadata);
    try std.testing.expect(std.mem.indexOf(u8, metadata, "\"size\":5") != null);
    const js = try assetsJsSource(std.testing.allocator, json, metadata);
    defer std.testing.allocator.free(js);
    try std.testing.expect(std.mem.indexOf(u8, js, "export function asset") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "export const assetManifest") != null);
}
