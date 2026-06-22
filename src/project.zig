const std = @import("std");
const parser = @import("parser.zig");
const tokenizer = @import("tokenizer.zig");
const codegen = @import("codegen.zig");
const router = @import("router.zig");
const diagnostics = @import("diagnostics.zig");

const database_source = @embedFile("database.zig");

pub const CheckResult = struct {
    ok: bool,
    diagnostics: usize,
};

const BuildRoute = struct {
    route: router.RoutePattern,
    module: []u8,
    /// Browser module URLs for this route's layout chain (outermost first).
    layouts: [][]u8 = &.{},
};

/// A deduplicated layout compiled once and shared by every route whose chain
/// includes it. Sharing one module URL per layout file is what lets the client
/// router keep a parent layout mounted across sibling navigations.
const LayoutModule = struct {
    file: []const u8, // borrowed from the owning route's LayoutRef
    module: []u8, // "./pages/layoutN.js"
    skeleton: []u8, // prerender skeleton (carries the slot sentinel)
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
    /// How many components/layouts reference this asset via `asset("...")`.
    /// Counted during `phaseAnalyze`; `refs == 0` assets are warned about and
    /// pruned from the install (§4).
    refs: u32 = 0,

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

// ── Phase-based build pipeline (§1, §2) ──────────────────────────────────────
//
// `checkProject` and `buildProject` share one `Build` context that flows through
// explicit phases: scan → parse → analyze → emit → (render). Each phase advances
// `stage`; debug builds assert the ordering. Semantic checks append source-located
// `Diagnostic`s to `diags` instead of printing ad-hoc, and rendering only runs once
// the error tally is zero. Output bytes for a valid app are byte-identical to the
// previous straight-line orchestrator.

const Stage = enum(u8) { init, scanned, parsed, analyzed, emitted, rendered };

/// Per-route pipeline state (§1). `index` points into `Build.routes`; the parsed
/// component (and the source buffer it borrows from) are owned here and live until
/// `Build.deinit`, so the source is parsed once and `phaseRender` reuses it.
const RouteNode = struct {
    index: usize,
    /// Owns this node's source buffer and parsed component. Backed by the
    /// thread-safe page allocator so each parse job (§6) allocates without
    /// contending on a shared allocator; freed wholesale at `deinit`.
    arena: std.heap.ArenaAllocator,
    source: []const u8 = "",
    component: parser.Component = .{ .source = "" },
    parsed: bool = false,
    /// Set by a parse job that failed; surfaced after the parse barrier since
    /// `std.Io.Group` swallows task errors.
    err: ?anyerror = null,

    fn deinit(self: *RouteNode) void {
        self.arena.deinit();
    }
};

/// Parse one route into its own arena. Runs on a worker thread under
/// `std.Io.Group`, which discards the return value, so failures are recorded on
/// `node.err` for the caller to surface after the barrier.
fn parseRouteNode(node: *RouteNode, io: std.Io, file: []const u8) void {
    const allocator = node.arena.allocator();
    const source = std.Io.Dir.cwd().readFileAlloc(io, file, allocator, .limited(4 * 1024 * 1024)) catch |e| {
        node.err = e;
        return;
    };
    node.component = parser.parse(allocator, source) catch |e| {
        node.err = e;
        return;
    };
    node.source = source;
    node.parsed = true;
}

/// A layout deduplicated by source path, parsed once and shared by every route
/// whose chain includes it. `module`/`skeleton` are filled during `phaseRender`.
const LayoutNode = struct {
    file: []const u8, // borrowed from a route's LayoutRef
    source: []const u8 = "",
    component: parser.Component = .{ .source = "" },
    parsed: bool = false,
    module: []u8 = &.{}, // "./pages/layoutN.js"
    skeleton: []u8 = &.{}, // prerender skeleton (carries the slot sentinel)
    rendered: bool = false,

    fn deinit(self: *LayoutNode, allocator: std.mem.Allocator) void {
        if (self.parsed) {
            parser.deinitComponent(&self.component, allocator);
            allocator.free(self.source);
        }
        if (self.rendered) {
            allocator.free(self.module);
            allocator.free(self.skeleton);
        }
    }
};

/// The unified build context threaded through every phase. `out_dir` is the dist
/// output directory in build mode and `null` in check mode (no browser assets are
/// written). All cross-phase state lives here; phase-internal state stays local to
/// its phase function.
const Build = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    out_dir: ?[]const u8,
    diags: diagnostics.Bag,
    routes: std.ArrayList(router.RoutePattern) = .empty,
    remotes: std.ArrayList(RemoteFunction) = .empty,
    assets: std.ArrayList(AssetEntry) = .empty,
    nodes: []RouteNode = &.{},
    layouts: std.ArrayList(LayoutNode) = .empty,
    stage: Stage = .init,

    fn init(io: std.Io, gpa: std.mem.Allocator, out_dir: ?[]const u8) Build {
        return .{ .io = io, .gpa = gpa, .out_dir = out_dir, .diags = diagnostics.Bag.init(gpa) };
    }

    fn deinit(self: *Build) void {
        for (self.nodes) |*n| n.deinit();
        self.gpa.free(self.nodes);
        for (self.layouts.items) |*l| l.deinit(self.gpa);
        self.layouts.deinit(self.gpa);
        deinitRoutes(&self.routes, self.gpa);
        deinitRemotes(&self.remotes, self.gpa);
        deinitAssets(&self.assets, self.gpa);
        self.diags.deinit();
    }

    fn advance(self: *Build, from: Stage, to: Stage) void {
        std.debug.assert(self.stage == from);
        self.stage = to;
    }

    fn errorCount(self: *const Build) usize {
        return self.diags.errorCount();
    }

    fn findLayout(self: *const Build, file: []const u8) ?usize {
        for (self.layouts.items, 0..) |l, i| {
            if (std.mem.eql(u8, l.file, file)) return i;
        }
        return null;
    }

    /// Run the pipeline. Emit and render are gated on a clean error tally so that
    /// `check` and `build` surface the same diagnostics; `phaseRender` additionally
    /// requires build mode (a non-null `out_dir`).
    fn run(self: *Build) !void {
        try self.phaseScan();
        try self.phaseParse();
        try self.phaseAnalyze();
        if (self.errorCount() == 0) try self.phaseEmit();
        if (self.out_dir != null and self.errorCount() == 0) try self.phaseRender();
    }

    /// Discover the route set and remote functions. An invalid route param is
    /// reported as a diagnostic and the offending page skipped, so one bad route no
    /// longer aborts the whole walk.
    fn phaseScan(self: *Build) !void {
        self.routes = try discoverRoutes(self.io, self.gpa, &self.diags);
        self.remotes = try discoverRemotes(self.io, self.gpa);
        self.assets = try discoverAssets(self.io, self.gpa);
        self.advance(.init, .scanned);
    }

    /// Read and parse each route source once (stored on its `RouteNode`) and parse
    /// every unique layout once (deduped by path, in discovery order).
    fn phaseParse(self: *Build) !void {
        const cwd = std.Io.Dir.cwd();
        const nodes = try self.gpa.alloc(RouteNode, self.routes.items.len);
        for (nodes, 0..) |*n, i| n.* = .{ .index = i, .arena = .init(std.heap.page_allocator) };
        self.nodes = nodes; // assign before parsing so Build.deinit reclaims arenas
        // §6: parse every route concurrently. Each job writes only its own node
        // (into that node's arena), so there is no shared mutable state; errors
        // are collected after the barrier since Group discards task results.
        var group: std.Io.Group = .init;
        for (self.nodes) |*node| {
            group.async(self.io, parseRouteNode, .{ node, self.io, self.routes.items[node.index].file });
        }
        group.await(self.io) catch {};
        for (self.nodes) |*node| {
            if (node.err) |err| return err;
        }
        // Layouts (deduped, far fewer) stay serial on the build allocator.
        for (self.routes.items) |route| {
            for (route.layouts) |layout| {
                if (self.findLayout(layout.file) != null) continue;
                const source = try cwd.readFileAlloc(self.io, layout.file, self.gpa, .limited(4 * 1024 * 1024));
                errdefer self.gpa.free(source);
                var component = try parser.parse(self.gpa, source);
                errdefer parser.deinitComponent(&component, self.gpa);
                try self.layouts.append(self.gpa, .{
                    .file = layout.file,
                    .source = source,
                    .component = component,
                    .parsed = true,
                });
            }
        }
        self.advance(.scanned, .parsed);
    }

    /// The dedicated semantic-analysis pass (§2): parse diagnostics, duplicate
    /// route/remote shapes and names, layout `<slot>` cardinality, unknown static
    /// hrefs, and HTML hygiene warnings — all emitted as source-located diagnostics.
    fn phaseAnalyze(self: *Build) !void {
        try validateRouteSet(&self.diags, self.routes.items);
        try validateRemoteSet(&self.diags, self.remotes.items);
        for (self.nodes) |*node| {
            const route = self.routes.items[node.index];
            try collectParseDiagnostics(&self.diags, route.file, &node.component);
            try validateStaticLinks(&self.diags, route.file, node.component.children, self.routes.items);
            try warnHtmlHygiene(&self.diags, route.file, node.component.children);
        }
        for (self.layouts.items) |*layout| {
            try collectParseDiagnostics(&self.diags, layout.file, &layout.component);
            try validateLayoutSlots(&self.diags, layout.file, &layout.component);
        }
        // §4: reference-count assets across every page + layout source and every
        // Zig sidecar, then warn about (and later prune) any that nothing
        // references via asset().
        for (self.nodes) |*node| countAssetReferences(self.assets.items, node.component.source);
        for (self.layouts.items) |*layout| countAssetReferences(self.assets.items, layout.component.source);
        try countZigAssetReferences(self.io, self.gpa, self.assets.items);
        try warnUnreferencedAssets(&self.diags, self.gpa, self.assets.items);
        self.advance(.parsed, .analyzed);
    }

    /// Generate `.yaan/*` artifacts and run the type-check backstops, preserving the
    /// previous orchestrator's order and gating. Backstop failures (the `*_check.zig`
    /// shims, which print their own compiler output) feed the shared error tally via
    /// `noteExternal` rather than being re-rendered.
    fn phaseEmit(self: *Build) !void {
        try prepareAssetArtifacts(self.io, self.gpa, self.out_dir, self.assets.items);
        self.diags.noteExternal(try prepareEnvArtifacts(self.io, self.gpa, self.out_dir));
        if (self.errorCount() == 0) {
            self.diags.noteExternal(try prepareHookArtifacts(self.io, self.gpa));
            self.diags.noteExternal(try prepareRouteArtifacts(self.io, self.gpa, self.routes.items, &self.diags));
            self.diags.noteExternal(try runLoadTypeCheck(self.io, self.gpa, self.routes.items));
            self.diags.noteExternal(try runActionTypeCheck(self.io, self.gpa, self.routes.items));
            self.diags.noteExternal(try prepareRemoteArtifacts(self.io, self.gpa, self.remotes.items));
        }
        self.advance(.analyzed, .emitted);
    }

    /// Codegen the browser ESM + scoped CSS and write the prerendered documents.
    /// Reuses the components parsed in `phaseParse` (no second parse). Only runs in
    /// build mode after a clean emit, so its output for a valid app is unchanged.
    fn phaseRender(self: *Build) !void {
        const out_dir = self.out_dir.?;
        const io = self.io;
        const allocator = self.gpa;
        const cwd = std.Io.Dir.cwd();

        var build_routes: std.ArrayList(BuildRoute) = .empty;
        defer {
            for (build_routes.items) |r| {
                var route = r.route;
                route.deinit(allocator);
                allocator.free(r.module);
                for (r.layouts) |url| allocator.free(url);
                allocator.free(r.layouts);
            }
            build_routes.deinit(allocator);
        }
        var css_bundle: std.ArrayList(u8) = .empty;
        defer css_bundle.deinit(allocator);
        try css_bundle.appendSlice(allocator, codegen.baseCss());

        // Codegen each already-parsed, already-validated layout once, writing
        // pages/layoutN.js in discovery order, and build a LayoutModule view for
        // skeleton composition / route layout URLs.
        const modules = try allocator.alloc(LayoutModule, self.layouts.items.len);
        defer allocator.free(modules);
        for (self.layouts.items, 0..) |*layout, i| {
            const generated = try codegen.generateComponent(allocator, layout.file, layout.component);
            defer {
                allocator.free(generated.js);
                allocator.free(generated.css);
                allocator.free(generated.scope);
                allocator.free(generated.prerender);
            }
            const module_name = try std.fmt.allocPrint(allocator, "pages/layout{d}.js", .{i});
            defer allocator.free(module_name);
            const module_path = try joinPath(allocator, out_dir, module_name);
            defer allocator.free(module_path);
            try cwd.writeFile(io, .{ .sub_path = module_path, .data = generated.js });
            try css_bundle.appendSlice(allocator, generated.css);
            try css_bundle.append(allocator, '\n');
            // Allocate both owned fields before committing them together: a failure
            // between the two must not leave `rendered` false with one field already
            // owned, which LayoutNode.deinit would then leak.
            const module = try std.fmt.allocPrint(allocator, "./pages/layout{d}.js", .{i});
            errdefer allocator.free(module);
            const skeleton = try allocator.dupe(u8, generated.prerender);
            layout.module = module;
            layout.skeleton = skeleton;
            layout.rendered = true;
            modules[i] = .{ .file = layout.file, .module = module, .skeleton = skeleton };
        }

        // Prerenderable route documents, written after the CSS bundle is hashed.
        var prerender_docs: std.ArrayList(PrerenderDoc) = .empty;
        defer {
            for (prerender_docs.items) |doc| {
                allocator.free(doc.path);
                allocator.free(doc.skeleton);
            }
            prerender_docs.deinit(allocator);
        }

        for (self.nodes, 0..) |*node, page_index| {
            const route = self.routes.items[node.index];
            const generated = try codegen.generateComponent(allocator, route.file, node.component);
            defer {
                allocator.free(generated.js);
                allocator.free(generated.css);
                allocator.free(generated.scope);
                allocator.free(generated.prerender);
            }

            const module_name = try std.fmt.allocPrint(allocator, "pages/page{d}.js", .{page_index});
            defer allocator.free(module_name);
            const module_path = try joinPath(allocator, out_dir, module_name);
            defer allocator.free(module_path);
            try cwd.writeFile(io, .{ .sub_path = module_path, .data = generated.js });
            try css_bundle.appendSlice(allocator, generated.css);
            try css_bundle.append(allocator, '\n');

            if (route.options.prerender != .never) {
                // Wrap the page skeleton with each layout's skeleton (root outermost)
                // by substituting the slot sentinel at every level.
                const composed = try composeSkeleton(allocator, generated.prerender, route.layouts, modules);
                try prerender_docs.append(allocator, .{
                    .page_index = page_index,
                    .path = try allocator.dupe(u8, route.path),
                    .skeleton = composed,
                });
            }

            const layout_urls = try layoutUrlsForRoute(allocator, route.layouts, modules);
            try build_routes.append(allocator, .{
                .route = try cloneRoute(allocator, route),
                .module = try std.fmt.allocPrint(allocator, "./{s}", .{module_name}),
                .layouts = layout_urls,
            });
        }

        const routes_json = try routesJson(allocator, build_routes.items);
        defer allocator.free(routes_json);
        const routes_js = try codegen.routesSource(allocator, routes_json);
        defer allocator.free(routes_js);
        const app_js = try codegen.appSource(allocator, routes_json);
        defer allocator.free(app_js);
        const remotes_js = try remotesJs(allocator, self.remotes.items);
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

        self.advance(.emitted, .rendered);
    }
};

/// Convert a component's parser diagnostics (message + byte offset) into
/// source-located `Diagnostic`s under the `E_PARSE` code.
fn collectParseDiagnostics(bag: *diagnostics.Bag, file: []const u8, component: *const parser.Component) !void {
    if (component.diagnostics.len == 0) return;
    var toks = tokenizer.Tokenizer.init(bag.allocator, component.source);
    defer toks.deinit();
    for (component.diagnostics) |diag| {
        const pos = toks.position(diag.offset);
        try bag.addf(.@"error", file, @intCast(pos.line), @intCast(pos.column), "E_PARSE", "{s}", .{diag.message});
    }
}

/// A layout must mark exactly one `<slot>` outlet (where the child level mounts);
/// zero or many is a build error.
fn validateLayoutSlots(bag: *diagnostics.Bag, file: []const u8, component: *const parser.Component) !void {
    const slots = codegen.countSlots(component.children);
    if (slots == 0) {
        try bag.add(.{
            .file = file,
            .code = "E_LAYOUT_NO_SLOT",
            .message = "a layout must contain exactly one <slot> outlet (found none)",
        });
    } else if (slots > 1) {
        try bag.addf(.@"error", file, 0, 0, "E_LAYOUT_MULTI_SLOT", "a layout must contain exactly one <slot> outlet (found {d})", .{slots});
    }
}

/// Runs the pipeline in check mode (no `dist/` output) and returns the number of
/// errors. Located diagnostics are printed; the `*_check.zig` backstops printed
/// their own compiler output during the emit phase.
pub fn checkProject(io: std.Io, allocator: std.mem.Allocator) !usize {
    var build = Build.init(io, allocator, null);
    defer build.deinit();
    try build.run();
    build.diags.flush();
    return build.errorCount();
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

/// Runs the full pipeline in build mode, emitting browser assets and prerendered
/// HTML into `out_dir`. Any diagnostics are printed and `error.CheckFailed` is
/// returned without producing output.
pub fn buildProject(io: std.Io, allocator: std.mem.Allocator, out_dir: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    // Clean the output directory so stale artifacts (old hashed assets, removed
    // routes, the pre-hash style.css) never linger between builds.
    if (isSafeOutputDir(out_dir)) cwd.deleteTree(io, out_dir) catch {};
    try cwd.createDirPath(io, out_dir);
    const pages_dir = try joinPath(allocator, out_dir, "pages");
    defer allocator.free(pages_dir);
    try cwd.createDirPath(io, pages_dir);

    var build = Build.init(io, allocator, out_dir);
    defer build.deinit();
    try build.run();
    if (build.errorCount() > 0) {
        build.diags.flush();
        return error.CheckFailed;
    }

    // Emit the embed map so the in-process deploy artifact can @embedFile the
    // whole dist/ tree and serve it from inside the binary — a true single-file
    // artifact that needs no dist/ on disk at runtime. Generated after dist/ is
    // complete so it enumerates exactly what was built.
    try generateDistEmbed(io, allocator, out_dir);
}

fn lessThanU8Slice(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Name of the generated embed module, written INSIDE `out_dir`. It must live
/// in the served tree because `@embedFile` cannot escape its own module's
/// package directory (a `.yaan/` module cannot embed `../dist/*`). Excluded from
/// the asset map here, and from being served by `readAsset` in server.zig, which
/// hardcodes the same ".embed.zig" suffix (keep the two in sync).
pub const dist_embed_basename = ".embed.zig";

/// Writes `<out_dir>/.embed.zig`: a `@embedFile` map from request path to bytes
/// for every file under `out_dir`. The in-process server consults this before
/// the filesystem, so the binary carries its own assets and needs no dist/ on
/// disk. Keys are the request path ("/index.html", "/assets/style.<hash>.css");
/// embed paths are relative to the embed module (i.e. plain `<rel>` within
/// `out_dir`).
fn generateDistEmbed(io: std.Io, allocator: std.mem.Allocator, out_dir: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, out_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);

    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        // The embed module is written after this walk, so it should never appear;
        // skip defensively in case a stale copy survived.
        if (std.mem.eql(u8, entry.basename, dist_embed_basename)) continue;
        try paths.append(allocator, try allocator.dupe(u8, entry.path));
    }
    // Deterministic order so the generated module is reproducible build-to-build.
    std.mem.sort([]u8, paths.items, {}, lessThanU8Slice);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator,
        \\// Generated by Yaan. Do not edit.
        \\const std = @import("std");
        \\
        \\pub const Entry = struct { path: []const u8, bytes: []const u8 };
        \\
        \\pub const entries = [_]Entry{
        \\
    );
    for (paths.items) |p| {
        try out.print(allocator, "    .{{ .path = \"/{s}\", .bytes = @embedFile(\"{s}\") }},\n", .{ p, p });
    }
    try out.appendSlice(allocator,
        \\};
        \\
        \\/// Returns the embedded bytes for a normalized request path (leading
        \\/// slash, "/" already mapped to "/index.html" by the caller), or null.
        \\pub fn lookup(rel_path: []const u8) ?[]const u8 {
        \\    for (entries) |e| {
        \\        if (std.mem.eql(u8, e.path, rel_path)) return e.bytes;
        \\    }
        \\    return null;
        \\}
        \\
    );
    const embed_path = try joinPath(allocator, out_dir, dist_embed_basename);
    defer allocator.free(embed_path);
    try cwd.writeFile(io, .{ .sub_path = embed_path, .data = out.items });
}

pub fn buildDevLoadRunner(io: std.Io, allocator: std.mem.Allocator) !void {
    var routes = try discoverRoutes(io, allocator, null);
    defer deinitRoutes(&routes, allocator);
    try devValidateRoutes(allocator, routes.items);
    if (try prepareEnvArtifacts(io, allocator, null) > 0) return error.CheckFailed;
    try devPrepareRouteArtifacts(io, allocator, routes.items);
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
    var routes = try discoverRoutes(io, allocator, null);
    defer deinitRoutes(&routes, allocator);
    try devValidateRoutes(allocator, routes.items);
    if (try prepareEnvArtifacts(io, allocator, null) > 0) return error.CheckFailed;
    try devPrepareRouteArtifacts(io, allocator, routes.items);
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
    try devValidateRemotes(allocator, remotes.items);
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

/// Writes a deployment file (`yaan add docker` / `yaan add systemd`) into the
/// app root, targeting the in-process single-binary artifact (TLS terminated
/// upstream, dist/ embedded, private env at runtime). Existing files are left
/// untouched.
pub fn addDeployFile(io: std.Io, allocator: std.mem.Allocator, target: []const u8, framework_url: []const u8, framework_version: []const u8) !void {
    _ = allocator;
    const cwd = std.Io.Dir.cwd();
    if (std.mem.eql(u8, target, "docker")) {
        try writeDeployFileIfAbsent(io, cwd, "Dockerfile", dockerfile_template);
        try writeDeployFileIfAbsent(io, cwd, ".dockerignore", dockerignore_template);
    } else if (std.mem.eql(u8, target, "systemd")) {
        try writeDeployFileIfAbsent(io, cwd, "yaan.service", systemd_template);
    } else if (std.mem.eql(u8, target, "cloudrun")) {
        try writeDeployFileIfAbsent(io, cwd, "Dockerfile", cloudrun_dockerfile_template);
        try writeDeployFileIfAbsent(io, cwd, ".gcloudignore", gcloudignore_template);
        try writeDeployFileIfAbsent(io, cwd, "deploy.sh", cloudrun_deploy_sh_template);
        std.debug.print(
            \\
            \\Cloud Run notes:
            \\  - Deploy with `yaan deploy gcp --project <id> --region <region>` or `sh deploy.sh`.
            \\  - `gcloud run deploy --source` builds in Cloud Build, whose context is THIS
            \\    directory, so a local `.path` framework dependency is NOT visible there.
            \\    Depend on the published framework instead (replaces the .path dep):
            \\      zig fetch --save git+{s}#v{s}
            \\
        , .{ framework_url, framework_version });
    } else {
        return error.UnknownAddTarget;
    }
}

fn writeDeployFileIfAbsent(io: std.Io, cwd: std.Io.Dir, path: []const u8, data: []const u8) !void {
    if (cwd.access(io, path, .{})) |_| {
        std.debug.print("{s} exists; leaving it untouched\n", .{path});
        return;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    try cwd.writeFile(io, .{ .sub_path = path, .data = data });
    std.debug.print("wrote {s}\n", .{path});
}

const dockerfile_template =
    \\# Generated by `yaan add docker`. Builds the in-process single-binary
    \\# artifact: dist/ is @embedFile'd in, private env resolves at runtime, and no
    \\# Zig toolchain (or dist/ on disk) is needed to run it — so the final image is
    \\# just the binary. Requires `b.installArtifact(app_server)` in build.zig
    \\# (see examples/app/build.zig).
    \\
    \\FROM ziglang/zig:0.16.0 AS build
    \\WORKDIR /app
    \\COPY . .
    \\# Static musl build so the binary runs on `scratch`. For arm64, use
    \\# aarch64-linux-musl. Drop -Dtarget to build for the host instead.
    \\RUN zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux-musl
    \\
    \\FROM scratch AS runtime
    \\COPY --from=build /app/zig-out/bin/yaan-app /yaan-app
    \\# If your app makes outbound TLS calls (e.g. --otel-endpoint), also copy CA
    \\# certs: COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
    \\#
    \\# Provide secrets at RUN time, never baked into the image:
    \\#   docker run -e YAAN_COOKIE_SECRET=... -e DATABASE_URL=... -p 8080:8080 <img>
    \\EXPOSE 8080
    \\# TLS is terminated upstream; add --trusted-proxy/--force-https/--hsts/--csrf
    \\# as your edge requires.
    \\ENTRYPOINT ["/yaan-app", "--host", "0.0.0.0", "--port", "8080"]
    \\
;

const dockerignore_template =
    \\# Build artifacts and local state are regenerated inside the image.
    \\.git
    \\.zig-cache
    \\zig-out
    \\dist
    \\.yaan
    \\
;

const systemd_template =
    \\# Generated by `yaan add systemd`. Install with:
    \\#   sudo cp yaan.service /etc/systemd/system/
    \\#   sudo systemctl daemon-reload && sudo systemctl enable --now yaan
    \\[Unit]
    \\Description=Yaan app
    \\After=network.target
    \\
    \\[Service]
    \\Type=simple
    \\# The installed single-binary artifact (zig build -Doptimize=ReleaseFast):
    \\ExecStart=/usr/local/bin/yaan-app --host 127.0.0.1 --port 8080
    \\# Secrets / private env, one KEY=VALUE per line, kept out of the unit file.
    \\# The leading '-' makes the file optional.
    \\EnvironmentFile=-/etc/yaan/yaan.env
    \\Restart=on-failure
    \\RestartSec=2
    \\# yaan drains in-flight requests on SIGTERM before exiting.
    \\KillSignal=SIGTERM
    \\TimeoutStopSec=30
    \\# Hardening. PrivateTmp gives the process its own /tmp (where uploads live).
    \\DynamicUser=yes
    \\NoNewPrivileges=yes
    \\ProtectSystem=strict
    \\ProtectHome=yes
    \\PrivateTmp=yes
    \\
    \\[Install]
    \\WantedBy=multi-user.target
    \\
;

const cloudrun_dockerfile_template =
    \\# Generated by `yaan add cloudrun`. Builds the in-process single-binary
    \\# artifact for Cloud Run: a static musl binary on `scratch`, no Zig toolchain
    \\# or dist/ at runtime. Cloud Run terminates TLS and forwards HTTP with
    \\# X-Forwarded-*, so the entrypoint enables --trust-forwarded; the server reads
    \\# Cloud Run's $PORT.
    \\#
    \\# NOTE: `gcloud run deploy --source` builds in Cloud Build, whose context is
    \\# this directory. Your `yaan` dependency must be reachable from here (a
    \\# published url+hash dep, or vendored) — a local `.path` dep outside this dir
    \\# is not visible to Cloud Build.
    \\
    \\FROM ziglang/zig:0.16.0 AS build
    \\WORKDIR /app
    \\COPY . .
    \\RUN zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux-musl
    \\
    \\FROM scratch AS runtime
    \\COPY --from=build /app/zig-out/bin/yaan-app /yaan-app
    \\# Provide secrets at deploy time (gcloud run --set-env-vars / --update-secrets),
    \\# never baked into the image.
    \\# Cloud Run sets $PORT (8080) and the server binds it. TLS is terminated by
    \\# Cloud Run; --trust-forwarded makes --force-https / secure cookies correct.
    \\ENTRYPOINT ["/yaan-app", "--host", "0.0.0.0", "--trust-forwarded"]
    \\
;

const gcloudignore_template =
    \\# Build artifacts and local state are regenerated inside Cloud Build.
    \\.git
    \\.zig-cache
    \\zig-out
    \\dist
    \\.yaan
    \\deploy.sh
    \\
;

const cloudrun_deploy_sh_template =
    \\#!/usr/bin/env bash
    \\# Generated by `yaan add cloudrun`. Deploy this app to Google Cloud Run via
    \\# Cloud Build (builds the Dockerfile from source). Override with env vars:
    \\#   SERVICE=my-svc REGION=us-central1 PROJECT=my-proj sh deploy.sh
    \\# Extra `gcloud run deploy` flags pass through, e.g.:
    \\#   sh deploy.sh --set-env-vars DATABASE_URL=... --no-allow-unauthenticated
    \\set -euo pipefail
    \\
    \\SERVICE="${SERVICE:-yaan-app}"
    \\REGION="${REGION:-us-central1}"
    \\PROJECT="${PROJECT:-$(gcloud config get-value project 2>/dev/null)}"
    \\
    \\exec gcloud run deploy "$SERVICE" \
    \\  --source . \
    \\  --region "$REGION" \
    \\  --project "$PROJECT" \
    \\  --allow-unauthenticated \
    \\  "$@"
    \\
;

pub const CloudRunDeploy = struct {
    service: []const u8,
    project: ?[]const u8,
    region: ?[]const u8,
    allow_unauthenticated: bool,
    /// Passed straight to `gcloud run deploy --set-env-vars` (e.g. "K=V,K2=V2").
    set_env_vars: ?[]const u8,
    dry_run: bool,
    /// Baked framework coordinates, used to print the fix command when the app
    /// uses a local `.path` dependency Cloud Build cannot reach.
    framework_url: []const u8,
    framework_version: []const u8,
    /// Skip the local-path-dependency preflight (e.g. when the framework is
    /// vendored into the build context).
    skip_dep_check: bool,
};

/// Deploys the app to Google Cloud Run by shelling out to `gcloud run deploy
/// --source .` (Cloud Build builds the Dockerfile, pushes to Artifact Registry,
/// and deploys). Streams gcloud's output live. `dry_run` prints the command
/// without running it. The app's `yaan` dependency must be reachable inside
/// Cloud Build's context (published url+hash dep, or vendored) — a local `.path`
/// dep outside this directory is not uploaded.
pub fn deployCloudRun(io: std.Io, allocator: std.mem.Allocator, opts: CloudRunDeploy) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "gcloud", "run", "deploy", opts.service, "--source", ".", "--platform", "managed" });
    if (opts.project) |p| try argv.appendSlice(allocator, &.{ "--project", p });
    if (opts.region) |r| try argv.appendSlice(allocator, &.{ "--region", r });
    try argv.append(allocator, if (opts.allow_unauthenticated) "--allow-unauthenticated" else "--no-allow-unauthenticated");
    if (opts.set_env_vars) |e| try argv.appendSlice(allocator, &.{ "--set-env-vars", e });

    // Preflight (real deploys only): a local `.path` framework dependency isn't
    // uploaded to Cloud Build, so `--source` would fail to resolve it. Catch it
    // before printing/spawning instead of after the (slow) build.
    if (!opts.dry_run and !opts.skip_dep_check) try checkCloudBuildReachable(io, allocator, opts.framework_url, opts.framework_version);

    // Print the exact command for transparency.
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);
    for (argv.items, 0..) |a, i| {
        if (i > 0) try line.append(allocator, ' ');
        try line.appendSlice(allocator, a);
    }
    std.debug.print("{s} {s}\n", .{ if (opts.dry_run) "[dry-run]" else "deploying:", line.items });
    if (opts.dry_run) return;

    var child = std.process.spawn(io, .{ .argv = argv.items }) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("gcloud not found. Install the Google Cloud SDK and run `gcloud auth login`:\n  https://cloud.google.com/sdk/docs/install\n", .{});
            return error.GcloudNotFound;
        },
        else => return err,
    };
    const term = child.wait(io) catch return error.DeployFailed;
    switch (term) {
        .exited => |code| if (code != 0) return error.DeployFailed,
        else => return error.DeployFailed,
    }
}

/// Errors if the app's `yaan` dependency is a local `.path` (Cloud Build can't
/// reach it). A `git+` URL dependency is reachable. Missing/unreadable
/// build.zig.zon does not block (a vendored or unusual setup may be fine).
fn checkCloudBuildReachable(io: std.Io, allocator: std.mem.Allocator, framework_url: []const u8, framework_version: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const data = cwd.readFileAlloc(io, "build.zig.zon", allocator, .limited(64 * 1024)) catch return;
    defer allocator.free(data);
    // A git URL dependency is fetched by Cloud Build — reachable.
    if (std.mem.indexOf(u8, data, "git+") != null) return;
    // The dependency path field is `.path = "..."`; the package's own top-level
    // `.paths = .{` does not match this needle, so it is not a false positive.
    if (std.mem.indexOf(u8, data, ".path = \"") != null) {
        std.debug.print(
            \\error: this app uses a local `.path` framework dependency, which Cloud
            \\Build cannot reach (its build context is this directory). Depend on the
            \\published framework first:
            \\  zig fetch --save git+{s}#v{s}
            \\then re-run, or pass --skip-dep-check to deploy anyway.
            \\
        , .{ framework_url, framework_version });
        return error.LocalPathDependency;
    }
}

pub fn writeExampleApp(io: std.Io, allocator: std.mem.Allocator, project_name: ?[]const u8, framework_root: []const u8, cwd_abs: []const u8) !void {
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
    // Root layout: wraps every page. The <slot> is where the matched page (or a
    // nested layout) is mounted; props.data comes from +layout.load.zig.
    try cwd.writeFile(io, .{ .sub_path = "src/routes/+layout.yn", .data =
        \\<script>
        \\import { PUBLIC_SITE_NAME } from '/env.public.js';
        \\
        \\const data = props.data || {};
        \\</script>
        \\
        \\<style>
        \\header { display: flex; gap: 1rem; padding: 0.5rem 1rem; border-bottom: 1px solid #d0d7de; }
        \\header a { color: #1f6feb; text-decoration: none; }
        \\footer { padding: 1rem; color: #57606a; border-top: 1px solid #d0d7de; }
        \\</style>
        \\
        \\<header>
        \\  <strong>{PUBLIC_SITE_NAME}</strong>
        \\  <a href="/">Home</a>
        \\  <a href="/blog/hello">Blog</a>
        \\</header>
        \\<slot></slot>
        \\<footer>{data.framework} — © {data.year}</footer>
    });
    try cwd.writeFile(io, .{ .sub_path = "src/routes/+layout.load.zig", .data =
        \\const std = @import("std");
        \\
        \\// Data for the root layout, available on every route. Layout loaders are
        \\// generic over the request context (`ctx: anytype`) because one layout
        \\// wraps many routes; use `ctx.allocator` / `ctx.request` as needed.
        \\pub const Data = struct {
        \\    framework: []const u8,
        \\    year: u16,
        \\};
        \\
        \\pub fn load(ctx: anytype) !Data {
        \\    _ = ctx;
        \\    return .{ .framework = "Yaan", .year = 2026 };
        \\}
        \\
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

    // Compute the framework path RELATIVE to this app's build root (Zig `.path`
    // deps must be relative). Empty when the framework isn't resolvable or $PWD
    // is unknown → the toolchain-only scaffold.
    const framework_rel = frameworkRelPath(io, allocator, cwd, project_name, framework_root, cwd_abs);
    defer if (framework_rel.len > 0) allocator.free(framework_rel);

    try writeProjectBuildFiles(io, allocator, cwd, project_name orelse "app", framework_rel);
}

/// Returns the framework's path relative to the scaffolded app's build root, or
/// "" if it can't be determined. Computes the candidate from $PWD (logical), then
/// VERIFIES it resolves from `app_dir` (the real app directory handle) — this
/// rejects symlink mismatches (e.g. /tmp -> /private/tmp where $PWD is logical),
/// falling back to the toolchain-only scaffold rather than emitting a broken dep.
fn frameworkRelPath(io: std.Io, allocator: std.mem.Allocator, app_dir: std.Io.Dir, project_name: ?[]const u8, framework_root: []const u8, cwd_abs: []const u8) []const u8 {
    if (framework_root.len == 0 or cwd_abs.len == 0) return "";
    const fw_build = std.fmt.allocPrint(allocator, "{s}/build.zig", .{framework_root}) catch return "";
    defer allocator.free(fw_build);
    std.Io.Dir.cwd().access(io, fw_build, .{}) catch return "";

    const app_abs = if (project_name) |n|
        (std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd_abs, n }) catch return "")
    else
        cwd_abs;
    defer if (project_name != null) allocator.free(app_abs);
    // app_abs and framework_root are absolute, so cwd/environ_map are unused.
    const rel = std.fs.path.relative(allocator, cwd_abs, null, app_abs, framework_root) catch return "";

    // Verify the candidate resolves from the REAL app dir before committing to it.
    const probe = std.fmt.allocPrint(allocator, "{s}/build.zig", .{rel}) catch {
        allocator.free(rel);
        return "";
    };
    defer allocator.free(probe);
    app_dir.access(io, probe, .{}) catch {
        allocator.free(rel);
        return "";
    };
    return rel;
}

/// Emits `build.zig` and `build.zig.zon` for a scaffolded app. The dev/build/
/// check loop is driven by the global `yaan` CLI and needs no package
/// dependency, so these are thin wrappers plus a valid package manifest. Files
/// that already exist are left untouched so re-running init never clobbers a
/// user's build setup.
fn writeProjectBuildFiles(io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir, raw_name: []const u8, framework_rel: []const u8) !void {
    const name = try packageName(allocator, raw_name);
    defer allocator.free(name);

    // Use the in-process (single-binary) scaffold when the framework resolves as
    // a Zig package dependency (relative path computed by the caller); otherwise
    // the toolchain-only scaffold that drives everything through the `yaan` CLI.
    const has_framework = framework_rel.len > 0;

    if (dir.access(io, "build.zig", .{})) |_| {
        std.debug.print("build.zig exists; leaving it untouched\n", .{});
    } else |_| {
        const data = if (has_framework) inprocess_build_zig else thin_build_zig;
        try dir.writeFile(io, .{ .sub_path = "build.zig", .data = data });
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

        const deps = if (has_framework)
            try std.fmt.allocPrint(allocator, ".{{ .yaan = .{{ .path = \"{s}\" }} }}", .{framework_rel})
        else
            try allocator.dupe(u8, ".{}");
        defer allocator.free(deps);

        const zon = try std.fmt.allocPrint(allocator,
            \\.{{
            \\    .name = .{s},
            \\    .version = "0.0.0",
            \\    .fingerprint = 0x{x},
            \\    .minimum_zig_version = "0.16.0",
            \\    .dependencies = {s},
            \\    .paths = .{{
            \\        "build.zig",
            \\        "build.zig.zon",
            \\        "src",
            \\        "static",
            \\    }},
            \\}}
            \\
        , .{ name, fingerprint, deps });
        defer allocator.free(zon);
        try dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = zon });
    }
}

/// Toolchain-only scaffold: thin wrappers over the `yaan` CLI (subprocess
/// model). Used when the framework cannot be resolved as a package dependency.
const thin_build_zig =
    \\const std = @import("std");
    \\
    \\// Yaan apps are driven by the `yaan` CLI (install it once, then it is on
    \\// your PATH). The dev/build/check loop is self-contained: the CLI generates
    \\// everything under .yaan/ and dist/, so no package dependency is required
    \\// here. These steps are thin wrappers so `zig build dev` works alongside
    \\// `yaan dev`. To build the single-binary deploy artifact, add the framework
    \\// dependency (`zig fetch --save <path-or-url-to-yaan>`) and switch to the
    \\// in-process build.zig (see the framework's examples/app/build.zig).
    \\pub fn build(b: *std.Build) void {
    \\    const host = b.option([]const u8, "host", "Dev server host") orelse "127.0.0.1";
    \\    const port = b.option([]const u8, "port", "Dev server port") orelse "5173";
    \\
    \\    const dev = b.step("dev", "Run the Yaan dev server");
    \\    dev.dependOn(&b.addSystemCommand(&.{ "yaan", "dev", "--host", host, "--port", port }).step);
    \\
    \\    const start = b.step("start", "Serve a production build (run `yaan build` first)");
    \\    start.dependOn(&b.addSystemCommand(&.{ "yaan", "start", "--host", host, "--port", port }).step);
    \\
    \\    const check = b.step("check", "Run Yaan framework checks");
    \\    check.dependOn(&b.addSystemCommand(&.{ "yaan", "check" }).step);
    \\
    \\    const build_app = b.step("build-app", "Build the app into dist/");
    \\    build_app.dependOn(&b.addSystemCommand(&.{ "yaan", "build", "--out", "dist" }).step);
    \\}
    \\
;

/// In-process scaffold: the recommended single-binary deploy artifact. `zig
/// build -Doptimize=ReleaseFast` produces zig-out/bin/yaan-app with dist/
/// embedded — no Zig toolchain or dist/ needed to run it. `yaan add docker`
/// emits a Dockerfile for it.
const inprocess_build_zig =
    \\const std = @import("std");
    \\const yaan = @import("yaan");
    \\
    \\pub fn build(b: *std.Build) void {
    \\    const target = b.standardTargetOptions(.{});
    \\    const optimize = b.standardOptimizeOption(.{});
    \\    const host = b.option([]const u8, "host", "Dev server host") orelse "127.0.0.1";
    \\    const port = b.option([]const u8, "port", "Dev server port") orelse "5173";
    \\
    \\    // The framework dependency provides the `yaan` module, the `yaan` CLI, and
    \\    // the in-process server builder. The CLI runs DURING the build (codegen),
    \\    // so it targets the host even when cross-compiling the app for deploy.
    \\    const yaan_dep = b.dependency("yaan", .{ .target = target, .optimize = optimize });
    \\    const yaan_host_dep = b.dependency("yaan", .{ .target = b.graph.host, .optimize = .ReleaseFast });
    \\    const yaan_exe = yaan_host_dep.artifact("yaan");
    \\
    \\    // `yaan build` generates .yaan/* + dist/.
    \\    const app_build_cmd = b.addRunArtifact(yaan_exe);
    \\    app_build_cmd.addArgs(&.{ "build", "--out", "dist" });
    \\    const build_app = b.step("build-app", "Build the app into dist/");
    \\    build_app.dependOn(&app_build_cmd.step);
    \\
    \\    const check = b.step("check", "Run Yaan framework checks");
    \\    const check_cmd = b.addRunArtifact(yaan_exe);
    \\    check_cmd.addArg("check");
    \\    check.dependOn(&check_cmd.step);
    \\
    \\    const dev = b.step("dev", "Run the Yaan dev server (subprocess runners)");
    \\    const dev_cmd = b.addRunArtifact(yaan_exe);
    \\    dev_cmd.addArgs(&.{ "dev", "--host", host, "--port", port });
    \\    dev.dependOn(&dev_cmd.step);
    \\
    \\    // Serve a production build (subprocess model). Build WITH runners first
    \\    // so the server needs no Zig toolchain at boot.
    \\    const start = b.step("start", "Serve a production build (subprocess runners)");
    \\    const start_build = b.addRunArtifact(yaan_exe);
    \\    start_build.addArgs(&.{ "build", "--out", "dist", "--runners" });
    \\    const start_cmd = b.addRunArtifact(yaan_exe);
    \\    start_cmd.step.dependOn(&start_build.step);
    \\    start_cmd.addArgs(&.{ "start", "--host", host, "--port", port });
    \\    start.dependOn(&start_cmd.step);
    \\
    \\    // The deploy artifact: the in-process single binary with dist/ embedded.
    \\    // `zig build -Doptimize=ReleaseFast` puts it at zig-out/bin/yaan-app; it
    \\    // needs no Zig toolchain or dist/ on disk to run. `yaan add docker` emits
    \\    // a Dockerfile for it.
    \\    const app_server = yaan.addInProcessServer(b, .{
    \\        .target = target,
    \\        .optimize = optimize,
    \\        .yaan_dep = yaan_dep,
    \\        .app_build_step = &app_build_cmd.step,
    \\    });
    \\    b.installArtifact(app_server);
    \\
    \\    const dev_inproc = b.step("dev-inproc", "Run the in-process server");
    \\    const dev_inproc_cmd = b.addRunArtifact(app_server);
    \\    dev_inproc_cmd.addArgs(&.{ "--host", host, "--port", port, "--debug-errors" });
    \\    dev_inproc.dependOn(&dev_inproc_cmd.step);
    \\}
    \\
;

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

/// A discovered page before its layout chain is resolved. `rel_dir` is the
/// page's directory relative to `src/routes` ("" for the root page), used to
/// match against discovered layout directories.
const PendingPage = struct {
    route: router.RoutePattern,
    rel_dir: []u8,

    fn deinit(self: *PendingPage, allocator: std.mem.Allocator) void {
        self.route.deinit(allocator);
        allocator.free(self.rel_dir);
    }
};

/// Walks `src/routes`, building the sorted route set and collecting layout dirs.
/// When `bag` is non-null (the pipeline), a page with an invalid route segment is
/// reported as an `E_BAD_PARAM_TYPE` diagnostic and skipped so the walk continues;
/// when null (the standalone dev runners), the first bad segment aborts as before.
fn discoverRoutes(io: std.Io, allocator: std.mem.Allocator, bag: ?*diagnostics.Bag) !std.ArrayList(router.RoutePattern) {
    const cwd = std.Io.Dir.cwd();
    var routes_dir = try cwd.openDir(io, "src/routes", .{ .iterate = true });
    defer routes_dir.close(io);

    // Pages and layout directories are collected in one walk (which yields
    // entries in arbitrary order), then chains are resolved once both are known.
    var pages: std.ArrayList(PendingPage) = .empty;
    defer {
        for (pages.items) |*page| page.deinit(allocator);
        pages.deinit(allocator);
    }
    var layout_dirs: std.ArrayList([]u8) = .empty;
    defer {
        for (layout_dirs.items) |dir| allocator.free(dir);
        layout_dirs.deinit(allocator);
    }

    var walker = try routes_dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.eql(u8, entry.basename, "+layout.yn")) {
            const dir = std.fs.path.dirname(entry.path) orelse "";
            try layout_dirs.append(allocator, try allocator.dupe(u8, dir));
            continue;
        }
        if (!std.mem.eql(u8, entry.basename, "+page.yn")) continue;
        const src_path = try std.fmt.allocPrint(allocator, "src/routes/{s}", .{entry.path});
        const route = router.parseRouteFile(allocator, src_path) catch |err| {
            if (bag) |b| switch (err) {
                error.InvalidRouteParam, error.InvalidRouteRest, error.InvalidRouteGroup, error.InvalidRouteSegment => {
                    try b.addf(.@"error", src_path, 0, 0, "E_BAD_PARAM_TYPE", "invalid route segment: {t}", .{err});
                    allocator.free(src_path);
                    continue;
                },
                else => {
                    allocator.free(src_path);
                    return err;
                },
            };
            allocator.free(src_path);
            std.debug.print("src/routes/{s}: invalid route segment: {t}\n", .{ entry.path, err });
            return err;
        };
        var route_with_load = route;
        errdefer route_with_load.deinit(allocator);
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
        const rel_dir = try allocator.dupe(u8, std.fs.path.dirname(entry.path) orelse "");
        errdefer allocator.free(rel_dir);
        try pages.append(allocator, .{ .route = route_with_load, .rel_dir = rel_dir });
    }

    if (pages.items.len == 0) {
        // Every page was rejected with a diagnostic: return an empty set so the
        // pipeline reports those instead of a bare NoRoutes error. A genuinely
        // empty routes dir (no diagnostics) is still an error.
        if (bag) |b| {
            if (b.errorCount() > 0) return .empty;
        }
        return error.NoRoutes;
    }

    // Resolve chains first (fallible; `pages` still owns each route so the defer
    // cleans up correctly on error), then move ownership into `routes` through a
    // preallocated, infallible loop so there is no double-free window.
    for (pages.items) |*page| {
        page.route.layouts = try resolveLayoutChain(io, allocator, page.rel_dir, layout_dirs.items);
    }
    var routes: std.ArrayList(router.RoutePattern) = .empty;
    errdefer deinitRoutes(&routes, allocator);
    try routes.ensureTotalCapacity(allocator, pages.items.len);
    for (pages.items) |*page| {
        routes.appendAssumeCapacity(page.route);
        allocator.free(page.rel_dir);
    }
    pages.clearRetainingCapacity(); // ownership moved; skip the per-page defer

    router.sortRoutes(routes.items);
    return routes;
}

/// Builds the layout chain for a page: every discovered layout whose directory
/// is an ancestor of (or equal to) the page's directory, ordered outermost
/// (root) to innermost.
fn resolveLayoutChain(io: std.Io, allocator: std.mem.Allocator, page_rel_dir: []const u8, layout_dirs: []const []const u8) ![]router.LayoutRef {
    const cwd = std.Io.Dir.cwd();
    var applicable: std.ArrayList([]const u8) = .empty;
    defer applicable.deinit(allocator);
    for (layout_dirs) |dir| {
        if (layoutApplies(dir, page_rel_dir)) try applicable.append(allocator, dir);
    }
    std.mem.sort([]const u8, applicable.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return dirDepth(a) < dirDepth(b);
        }
    }.lessThan);

    const refs = try allocator.alloc(router.LayoutRef, applicable.items.len);
    var len: usize = 0;
    errdefer {
        for (refs[0..len]) |*ref| ref.deinit(allocator);
        allocator.free(refs);
    }
    for (applicable.items) |dir| {
        const file = if (dir.len == 0)
            try allocator.dupe(u8, "src/routes/+layout.yn")
        else
            try std.fmt.allocPrint(allocator, "src/routes/{s}/+layout.yn", .{dir});
        errdefer allocator.free(file);
        const load_candidate = if (dir.len == 0)
            try allocator.dupe(u8, "src/routes/+layout.load.zig")
        else
            try std.fmt.allocPrint(allocator, "src/routes/{s}/+layout.load.zig", .{dir});
        var load_file: ?[]u8 = null;
        if (cwd.access(io, load_candidate, .{ .read = true })) {
            load_file = load_candidate;
        } else |err| switch (err) {
            error.FileNotFound => allocator.free(load_candidate),
            else => {
                allocator.free(load_candidate);
                return err;
            },
        }
        errdefer if (load_file) |lf| allocator.free(lf);
        const name = try layoutName(allocator, dir);
        refs[len] = .{ .file = file, .load_file = load_file, .name = name };
        len += 1;
    }
    return refs;
}

/// Parses each unique layout, reporting parse diagnostics and enforcing the
/// exactly-one-`<slot>` rule. Returns the number of failures.
fn layoutApplies(layout_dir: []const u8, page_dir: []const u8) bool {
    if (layout_dir.len == 0) return true; // root layout wraps every page
    if (std.mem.eql(u8, layout_dir, page_dir)) return true;
    return page_dir.len > layout_dir.len and
        std.mem.startsWith(u8, page_dir, layout_dir) and
        page_dir[layout_dir.len] == '/';
}

fn dirDepth(dir: []const u8) usize {
    if (dir.len == 0) return 0;
    var depth: usize = 1;
    for (dir) |c| {
        if (c == '/') depth += 1;
    }
    return depth;
}

fn layoutName(allocator: std.mem.Allocator, dir: []const u8) ![]u8 {
    if (dir.len == 0) return allocator.dupe(u8, "root");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var last_sep = false;
    for (dir) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9');
        if (ok) {
            try out.append(allocator, c);
            last_sep = false;
        } else if (!last_sep) {
            try out.append(allocator, '_');
            last_sep = true;
        }
    }
    return out.toOwnedSlice(allocator);
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

fn validateRemoteSet(bag: *diagnostics.Bag, remotes: []const RemoteFunction) !void {
    for (remotes, 0..) |a, i| {
        for (remotes[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.name, b.name)) {
                try bag.addf(.@"error", b.file, 0, 0, "E_DUP_REMOTE_NAME", "duplicate remote function name '{s}'", .{a.name});
            }
        }
    }
}

fn validateRouteSet(bag: *diagnostics.Bag, routes: []const router.RoutePattern) !void {
    for (routes, 0..) |a, i| {
        for (routes[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.shape, b.shape)) {
                try bag.addf(.@"error", b.file, 0, 0, "E_DUP_ROUTE_SHAPE", "duplicate route pattern (collides with {s})", .{a.file});
            }
        }
    }
    for (routes, 0..) |a, i| {
        for (routes[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.name, b.name)) {
                try bag.addf(.@"error", b.file, 0, 0, "E_DUP_ROUTE_NAME", "duplicate generated route name '{s}' (collides with {s})", .{ b.name, a.file });
            }
        }
    }
}

/// Route-set check for the standalone dev runners, which compile a single runner
/// subprocess outside the full pipeline. Prints any diagnostics and fails fast.
fn devValidateRoutes(allocator: std.mem.Allocator, routes: []const router.RoutePattern) !void {
    var bag = diagnostics.Bag.init(allocator);
    defer bag.deinit();
    try validateRouteSet(&bag, routes);
    if (bag.errorCount() > 0) {
        bag.flush();
        return error.CheckFailed;
    }
}

fn devValidateRemotes(allocator: std.mem.Allocator, remotes: []const RemoteFunction) !void {
    var bag = diagnostics.Bag.init(allocator);
    defer bag.deinit();
    try validateRemoteSet(&bag, remotes);
    if (bag.errorCount() > 0) {
        bag.flush();
        return error.CheckFailed;
    }
}

/// Route-artifact build for the standalone dev runners: fails if either the
/// options type-check backstop or the located route-option diagnostics report an
/// error, mirroring how the full pipeline gates the same step.
fn devPrepareRouteArtifacts(io: std.Io, allocator: std.mem.Allocator, routes: []router.RoutePattern) !void {
    var bag = diagnostics.Bag.init(allocator);
    defer bag.deinit();
    const failures = try prepareRouteArtifacts(io, allocator, routes, &bag);
    if (failures > 0 or bag.errorCount() > 0) {
        bag.flush();
        return error.CheckFailed;
    }
}

/// Route-options semantic check (§2). Options are only known after the
/// `+page.options.zig` sidecar is compiled and applied in the emit phase, so this
/// runs there rather than in `phaseAnalyze`, emitting located diagnostics for the
/// combinations that v1 does not support.
fn validateRouteOptions(bag: *diagnostics.Bag, routes: []const router.RoutePattern) !void {
    for (routes) |route| {
        if (!route.options.csr) {
            try bag.add(.{
                .file = route.file,
                .code = "E_CSR_REQUIRED",
                .message = "csr=false requires SSR/static page output and is not supported in v1",
            });
        }
        if (route.options.prerender == .always and routeHasDynamicSegments(route)) {
            try bag.add(.{
                .file = route.file,
                .code = "E_PRERENDER_DYNAMIC",
                .message = "prerender=.always for dynamic routes requires static params and is not supported in v1",
            });
        }
    }
}

fn routeHasDynamicSegments(route: router.RoutePattern) bool {
    for (route.segments) |segment| {
        if (segment.kind == .dynamic or segment.kind == .rest) return true;
    }
    return false;
}

fn validateStaticLinks(bag: *diagnostics.Bag, file: []const u8, nodes: []const parser.Node, routes: []const router.RoutePattern) !void {
    for (nodes) |node| switch (node) {
        .element => |element| {
            for (element.attrs) |attr| {
                if (std.mem.eql(u8, attr.name, "href")) {
                    if (attr.value) |value| {
                        if (value.len > 0 and value[0] == '/' and !router.anyRouteMatchesStaticPath(routes, value)) {
                            try bag.addf(.@"error", file, 0, 0, "E_UNKNOWN_STATIC_HREF", "unknown static href '{s}'", .{value});
                        }
                    }
                }
            }
            try validateStaticLinks(bag, file, element.children, routes);
        },
        .if_block => |block| {
            try validateStaticLinks(bag, file, block.then_children, routes);
            try validateStaticLinks(bag, file, block.else_children, routes);
        },
        .each_block => |block| try validateStaticLinks(bag, file, block.children, routes),
        else => {},
    };
}

fn warnHtmlHygiene(bag: *diagnostics.Bag, file: []const u8, nodes: []const parser.Node) !void {
    for (nodes) |node| switch (node) {
        .element => |element| {
            if (std.mem.eql(u8, element.name, "img") and !hasAttr(element, "alt")) {
                try bag.add(.{ .severity = .warning, .file = file, .code = "W_IMG_NO_ALT", .message = "<img> is missing alt text" });
            }
            try warnHtmlHygiene(bag, file, element.children);
        },
        .if_block => |block| {
            try warnHtmlHygiene(bag, file, block.then_children);
            try warnHtmlHygiene(bag, file, block.else_children);
        },
        .each_block => |block| try warnHtmlHygiene(bag, file, block.children),
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
        } else if (env_var.required and !isRuntimeEnv(env_var.*)) {
            // Runtime vars are validated at server startup by env.init(), not at
            // build time — a required secret may legitimately be absent on the
            // build host and supplied only in the deploy environment.
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

/// A var is resolved at runtime (server startup) rather than baked at build
/// time when it is private AND not explicitly static. Public vars must be
/// inlined into the client `env.public.js` at build time, and `static` is an
/// explicit opt-in to build-time baking — so both stay constants. Everything
/// else reads from the process environment via `env.init()` so a single build
/// artifact can serve many environments without a rebuild.
fn isRuntimeEnv(env_var: EnvVar) bool {
    return env_var.visibility == .private and !env_var.static;
}

fn envZeroValue(kind: EnvKind) []const u8 {
    return switch (kind) {
        .string => "\"\"",
        .int, .uint => "0",
        .bool => "false",
    };
}

fn generateEnvModule(allocator: std.mem.Allocator, vars: []const EnvVar) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, "// Generated by Yaan. Do not edit.\n\n");

    var any_runtime = false;
    for (vars) |env_var| {
        if (isRuntimeEnv(env_var)) any_runtime = true;
    }
    if (any_runtime) try out.appendSlice(allocator, "const std = @import(\"std\");\n\n");

    // Build-time vars (public or static): compiled-in constants.
    for (vars) |env_var| {
        if (isRuntimeEnv(env_var)) continue;
        const value = env_var.value orelse continue;
        try out.print(allocator, "pub const {s}: {s} = ", .{ env_var.name, envZigType(env_var.kind) });
        try appendZigValue(allocator, &out, env_var.kind, value);
        try out.appendSlice(allocator, ";\n");
    }

    // Runtime vars (private, non-static): mutable globals seeded with the
    // declared default (or a zero value), then overwritten by init() at startup.
    // We deliberately use the DECLARED DEFAULT here, not the build-time resolved
    // value, so the build environment never leaks into the artifact.
    for (vars) |env_var| {
        if (!isRuntimeEnv(env_var)) continue;
        try out.print(allocator, "pub var {s}: {s} = ", .{ env_var.name, envZigType(env_var.kind) });
        if (env_var.default_value) |dv| {
            try appendZigValue(allocator, &out, env_var.kind, dv);
        } else {
            try out.appendSlice(allocator, envZeroValue(env_var.kind));
        }
        try out.appendSlice(allocator, ";\n");
    }

    if (any_runtime) {
        try out.appendSlice(allocator,
            \\
            \\var __env_initialized: bool = false;
            \\
            \\/// Resolve runtime (private, non-static) env vars from the process
            \\/// environment. Idempotent, so it is safe to call from every entry
            \\/// point (server boot and each subprocess runner). `env_map` is
            \\/// anything exposing `get([]const u8) ?[]const u8` — e.g. the
            \\/// process `environ_map`. Build-time vars are already constants.
            \\pub fn init(env_map: anytype) !void {
            \\    if (__env_initialized) return;
            \\    __env_initialized = true;
            \\
        );
        for (vars) |env_var| {
            if (!isRuntimeEnv(env_var)) continue;
            try appendRuntimeEnvResolution(allocator, &out, env_var);
        }
        try out.appendSlice(allocator, "}\n");
    } else {
        try out.appendSlice(allocator,
            \\/// No runtime env vars; init() is a no-op kept so every entry point
            \\/// can call `env.init()` uniformly.
            \\pub fn init(env_map: anytype) !void {
            \\    _ = env_map;
            \\}
            \\
        );
    }

    return out.toOwnedSlice(allocator);
}

/// Emits one runtime env var's resolution line inside init(). Missing required
/// vars without a default fail at startup; invalid numeric values fail too.
fn appendRuntimeEnvResolution(allocator: std.mem.Allocator, out: *std.ArrayList(u8), env_var: EnvVar) !void {
    const name = env_var.name;
    switch (env_var.kind) {
        .string => try out.print(allocator, "    if (env_map.get(\"{s}\")) |v| {{ {s} = v; }}", .{ name, name }),
        .int => try out.print(allocator, "    if (env_map.get(\"{s}\")) |v| {{ {s} = std.fmt.parseInt(i64, v, 10) catch return error.InvalidEnvValue; }}", .{ name, name }),
        .uint => try out.print(allocator, "    if (env_map.get(\"{s}\")) |v| {{ {s} = std.fmt.parseInt(u64, v, 10) catch return error.InvalidEnvValue; }}", .{ name, name }),
        // Mirror the build-time normalizer: case-insensitive true/false/1/0,
        // error on anything else (rather than silently defaulting to false).
        .bool => try out.print(allocator, "    if (env_map.get(\"{s}\")) |v| {{ if (std.ascii.eqlIgnoreCase(v, \"true\") or std.mem.eql(u8, v, \"1\")) {{ {s} = true; }} else if (std.ascii.eqlIgnoreCase(v, \"false\") or std.mem.eql(u8, v, \"0\")) {{ {s} = false; }} else return error.InvalidEnvValue; }}", .{ name, name, name }),
    }
    if (env_var.required and env_var.default_value == null) {
        try out.appendSlice(allocator, " else { return error.MissingRequiredEnv; }\n");
    } else {
        try out.appendSlice(allocator, "\n");
    }
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

/// Returns the number of options *type-check* failures (an external backstop that
/// prints its own compiler output); v1-unsupported option combinations are emitted
/// into `bag` as located diagnostics instead.
fn prepareRouteArtifacts(io: std.Io, allocator: std.mem.Allocator, routes: []router.RoutePattern, bag: *diagnostics.Bag) !usize {
    try writeTypedRoutes(io, allocator, routes);
    const failures = try runOptionsTypeCheck(io, allocator, routes);
    if (failures == 0) {
        try applyRouteOptions(io, allocator, routes);
        try validateRouteOptions(bag, routes);
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

/// Install and manifest only referenced assets (refs > 0); orphans are pruned
/// (§4). When any asset is pruned in build mode, a `dist/assets.unreferenced.json`
/// records them so the dev server can give an "exists but unreferenced" 404.
fn prepareAssetArtifacts(io: std.Io, allocator: std.mem.Allocator, out_dir: ?[]const u8, assets: []const AssetEntry) !void {
    var referenced: std.ArrayList(AssetEntry) = .empty;
    defer referenced.deinit(allocator); // shallow view; entries are owned by `assets`
    var pruned: usize = 0;
    for (assets) |entry| {
        if (entry.refs > 0) try referenced.append(allocator, entry) else pruned += 1;
    }
    if (out_dir) |dir| try writeBuiltAssets(io, allocator, dir, referenced.items);
    try writeAssetManifestArtifacts(io, allocator, out_dir, referenced.items);
    if (out_dir) |dir| {
        if (pruned > 0) try writeUnreferencedManifest(io, allocator, dir, assets);
    }
}

/// Record pruned assets (logical name + would-be url) for the dev server. Written
/// only when at least one asset was pruned, so a fully-referenced app's `dist/` is
/// unchanged.
fn writeUnreferencedManifest(io: std.Io, allocator: std.mem.Allocator, out_dir: []const u8, assets: []const AssetEntry) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.append(allocator, '[');
    var first = true;
    for (assets) |entry| {
        if (entry.refs > 0) continue;
        if (!first) try out.append(allocator, ',');
        first = false;
        const logical = try jsonString(allocator, entry.logical);
        defer allocator.free(logical);
        const url = try jsonString(allocator, entry.url);
        defer allocator.free(url);
        try out.print(allocator, "{{\"logical\":{s},\"url\":{s}}}", .{ logical, url });
    }
    try out.append(allocator, ']');
    const path = try joinPath(allocator, out_dir, "assets.unreferenced.json");
    defer allocator.free(path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items });
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

/// Bump `refs` for every asset named by a static `asset("literal")` call in
/// `source`. Matching is deliberately liberal (any quoted-literal arg counts):
/// over-counting only keeps an asset installed, while under-counting would prune
/// a live one. Dynamic `asset(expr)` calls can't be resolved and are skipped —
/// the documented limitation of static pruning. CSS `url(...)` is not a Yaan
/// asset channel, so it is not scanned.
fn countAssetReferences(assets: []AssetEntry, source: []const u8) void {
    const needle = "asset(";
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, source, i, needle)) |start| {
        i = start + needle.len;
        var j = i;
        while (j < source.len and std.ascii.isWhitespace(source[j])) j += 1;
        if (j >= source.len) continue;
        const quote = source[j];
        if (quote != '"' and quote != '\'') continue; // dynamic arg — can't resolve
        j += 1;
        const lit_start = j;
        while (j < source.len and source[j] != quote) j += 1;
        if (j >= source.len) break; // unterminated literal
        const literal = source[lit_start..j];
        const key = if (literal.len > 0 and literal[0] == '/') literal[1..] else literal;
        for (assets) |*entry| {
            if (std.mem.eql(u8, entry.logical, key)) entry.refs +|= 1;
        }
        i = j + 1;
    }
}

/// Emit a `W_ASSET_UNREFERENCED` warning for every asset that nothing references
/// (refs == 0) — these are pruned from the install. Warnings don't gate the build.
fn warnUnreferencedAssets(bag: *diagnostics.Bag, allocator: std.mem.Allocator, assets: []const AssetEntry) !void {
    for (assets) |entry| {
        if (entry.refs != 0) continue;
        const path = try std.fmt.allocPrint(allocator, "static/{s}", .{entry.logical});
        defer allocator.free(path);
        try bag.add(.{
            .severity = .warning,
            .file = path,
            .code = "W_ASSET_UNREFERENCED",
            .message = "asset is never referenced via asset() and will not be installed",
        });
    }
}

/// Scan every `.zig` sidecar under `src/` for `asset("literal")` references too,
/// so an asset used only from a loader/action/remote/hook (via the generated
/// `assets` module) is not mistaken for an orphan and pruned.
fn countZigAssetReferences(io: std.Io, allocator: std.mem.Allocator, assets: []AssetEntry) !void {
    const cwd = std.Io.Dir.cwd();
    var src_dir = cwd.openDir(io, "src", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer src_dir.close(io);
    var walker = try src_dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const path = try joinPath(allocator, "src", entry.path);
        defer allocator.free(path);
        const source = try cwd.readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024));
        defer allocator.free(source);
        countAssetReferences(assets, source);
    }
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
        \\    try @import("env").init(init.environ_map);
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
        \\    try @import("env").init(init.environ_map);
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
        \\    // Do NOT deinit aw: parseFromSliceLeaky returns strings that point
        \\    // into aw.written() (zero-copy for unescaped strings). On an arena,
        \\    // deinit() rolls back this buffer, leaving those strings dangling
        \\    // into reusable memory — a later allocation (e.g. the handler's own
        \\    // writer) reuses the slot and @memcpy aliases. The arena reclaims aw
        \\    // when the request arena is reset.
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
    const layout_loads = try router.collectLayoutLoads(allocator, routes);
    defer router.freeLayoutLoads(allocator, layout_loads);
    for (layout_loads) |entry| {
        try argv.append(allocator, "--dep");
        try argv.append(allocator, try allocator.dupe(u8, entry.name));
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
            try appendLoadHandlerModule(allocator, argv, route.name, load_file, "load_");
        }
    }
    for (layout_loads) |entry| {
        try appendLoadHandlerModuleNamed(allocator, argv, entry.name, entry.file);
    }
}

/// Wires one load-handler module (route loaders) with its standard deps.
fn appendLoadHandlerModule(allocator: std.mem.Allocator, argv: *std.ArrayList([]const u8), name: []const u8, file: []const u8, prefix: []const u8) !void {
    const module_name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, name });
    try appendLoadHandlerModuleNamed(allocator, argv, module_name, file);
}

fn appendLoadHandlerModuleNamed(allocator: std.mem.Allocator, argv: *std.ArrayList([]const u8), module_name: []const u8, file: []const u8) !void {
    try argv.append(allocator, "--dep");
    try argv.append(allocator, "routes");
    try argv.append(allocator, "--dep");
    try argv.append(allocator, "env");
    try argv.append(allocator, "--dep");
    try argv.append(allocator, "database");
    try argv.append(allocator, "--dep");
    try argv.append(allocator, "assets");
    try argv.append(allocator, try std.fmt.allocPrint(allocator, "-M{s}={s}", .{ module_name, file }));
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

    var layouts = try allocator.alloc(router.LayoutRef, route.layouts.len);
    var layouts_len: usize = 0;
    errdefer {
        for (layouts[0..layouts_len]) |*layout| layout.deinit(allocator);
        allocator.free(layouts);
    }
    for (route.layouts, 0..) |layout, i| {
        layouts[i] = .{
            .file = try allocator.dupe(u8, layout.file),
            .load_file = if (layout.load_file) |lf| try allocator.dupe(u8, lf) else null,
            .name = try allocator.dupe(u8, layout.name),
        };
        layouts_len += 1;
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
        .layouts = layouts,
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
        try out.print(allocator, "{{\"path\":{s},\"module\":{s},\"layouts\":", .{ path_lit, module_lit });
        try appendStringsJson(allocator, &out, route.layouts);
        try out.appendSlice(allocator, ",\"groups\":");
        try appendGroupsJson(allocator, &out, route.route.groups);
        try out.appendSlice(allocator, ",\"options\":");
        try appendOptionsJson(allocator, &out, route.route.options);
        try out.append(allocator, '}');
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

fn findLayoutModule(modules: []const LayoutModule, file: []const u8) ?usize {
    for (modules, 0..) |m, i| {
        if (std.mem.eql(u8, m.file, file)) return i;
    }
    return null;
}

/// Browser module URLs for a route's layout chain, outermost first.
fn layoutUrlsForRoute(allocator: std.mem.Allocator, layouts: []const router.LayoutRef, modules: []const LayoutModule) ![][]u8 {
    const urls = try allocator.alloc([]u8, layouts.len);
    var len: usize = 0;
    errdefer {
        for (urls[0..len]) |url| allocator.free(url);
        allocator.free(urls);
    }
    for (layouts) |layout| {
        const idx = findLayoutModule(modules, layout.file) orelse return error.UnknownLayout;
        urls[len] = try allocator.dupe(u8, modules[idx].module);
        len += 1;
    }
    return urls;
}

/// Folds the page skeleton into its layout chain, innermost-out: each layout's
/// skeleton has its slot sentinel replaced with the already-composed inner HTML,
/// ending with the root layout outermost.
fn composeSkeleton(allocator: std.mem.Allocator, page_skeleton: []const u8, layouts: []const router.LayoutRef, modules: []const LayoutModule) ![]u8 {
    var current = try allocator.dupe(u8, page_skeleton);
    var i = layouts.len;
    while (i > 0) {
        i -= 1;
        const idx = findLayoutModule(modules, layouts[i].file) orelse return error.UnknownLayout;
        const wrapped = try replaceFirst(allocator, modules[idx].skeleton, codegen.slot_sentinel, current);
        allocator.free(current);
        current = wrapped;
    }
    return current;
}

/// Returns `haystack` with the first occurrence of `needle` replaced by
/// `replacement`. If `needle` is absent, returns a copy of `haystack`.
fn replaceFirst(allocator: std.mem.Allocator, haystack: []const u8, needle: []const u8, replacement: []const u8) ![]u8 {
    const at = std.mem.indexOf(u8, haystack, needle) orelse return allocator.dupe(u8, haystack);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, haystack[0..at]);
    try out.appendSlice(allocator, replacement);
    try out.appendSlice(allocator, haystack[at + needle.len ..]);
    return out.toOwnedSlice(allocator);
}

fn appendStringsJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), values: []const []u8) !void {
    try out.append(allocator, '[');
    for (values, 0..) |value, i| {
        if (i > 0) try out.append(allocator, ',');
        const lit = try jsonString(allocator, value);
        defer allocator.free(lit);
        try out.appendSlice(allocator, lit);
    }
    try out.append(allocator, ']');
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

test "collectParseDiagnostics locates parser errors under E_PARSE" {
    const allocator = std.testing.allocator;
    var component = try parser.parse(allocator, "<p>{oops</p>");
    defer parser.deinitComponent(&component, allocator);
    try std.testing.expect(component.diagnostics.len > 0);

    var bag = diagnostics.Bag.init(allocator);
    defer bag.deinit();
    try collectParseDiagnostics(&bag, "src/routes/+page.yn", &component);

    try std.testing.expectEqual(@as(usize, component.diagnostics.len), bag.errorCount());
    try std.testing.expectEqualStrings("E_PARSE", bag.items.items[0].code);
    try std.testing.expectEqualStrings("src/routes/+page.yn", bag.items.items[0].file);
    try std.testing.expect(bag.items.items[0].line >= 1);
}

test "validateStaticLinks flags unknown hrefs, hygiene warns on missing alt" {
    const allocator = std.testing.allocator;
    const source =
        \\<a href="/missing">broken</a>
        \\<img src="/logo.svg" />
        \\<img src="/ok.svg" alt="ok" />
    ;
    var component = try parser.parse(allocator, source);
    defer parser.deinitComponent(&component, allocator);
    try std.testing.expectEqual(@as(usize, 0), component.diagnostics.len);

    var bag = diagnostics.Bag.init(allocator);
    defer bag.deinit();
    // No routes exist, so the leading-slash href is unresolvable.
    try validateStaticLinks(&bag, "src/routes/+page.yn", component.children, &.{});
    try warnHtmlHygiene(&bag, "src/routes/+page.yn", component.children);

    // One error (unknown static href) and one warning (the alt-less <img>).
    try std.testing.expectEqual(@as(usize, 1), bag.errorCount());
    try std.testing.expectEqual(@as(usize, 1), bag.warningCount());
}

// Minimal RoutePattern fixture: only the fields the route-set/options validators
// read are meaningful; the rest are dummies that are never freed (nothing is
// allocated, so no deinit is needed).
fn fixtureRoute(file: []const u8, shape: []const u8, name: []const u8, segments: []router.Segment, options: router.RouteOptions) router.RoutePattern {
    return .{
        .file = @constCast(file),
        .path = @constCast("/x"),
        .shape = @constCast(shape),
        .name = @constCast(name),
        .groups = &.{},
        .segments = segments,
        .score = 0,
        .options = options,
    };
}

test "validateRouteSet flags duplicate shapes (against the colliding file)" {
    const a = std.testing.allocator;
    var no_segs = [_]router.Segment{};
    const routes = [_]router.RoutePattern{
        fixtureRoute("src/routes/a/+page.yn", "/dup", "a", &no_segs, .{}),
        fixtureRoute("src/routes/b/+page.yn", "/dup", "b", &no_segs, .{}),
    };
    var bag = diagnostics.Bag.init(a);
    defer bag.deinit();
    try validateRouteSet(&bag, &routes);
    try std.testing.expectEqual(@as(usize, 1), bag.errorCount());
    try std.testing.expectEqualStrings("E_DUP_ROUTE_SHAPE", bag.items.items[0].code);
    try std.testing.expectEqualStrings("src/routes/b/+page.yn", bag.items.items[0].file);
}

test "validateRouteSet flags duplicate generated names" {
    const a = std.testing.allocator;
    var no_segs = [_]router.Segment{};
    const routes = [_]router.RoutePattern{
        fixtureRoute("src/routes/a/+page.yn", "/x", "dup", &no_segs, .{}),
        fixtureRoute("src/routes/b/+page.yn", "/y", "dup", &no_segs, .{}),
    };
    var bag = diagnostics.Bag.init(a);
    defer bag.deinit();
    try validateRouteSet(&bag, &routes);
    try std.testing.expectEqual(@as(usize, 1), bag.errorCount());
    try std.testing.expectEqualStrings("E_DUP_ROUTE_NAME", bag.items.items[0].code);
}

test "validateRemoteSet flags duplicate remote names" {
    const a = std.testing.allocator;
    const remotes = [_]RemoteFunction{
        .{ .file = @constCast("src/remotes/a.remote.zig"), .name = @constCast("getUser") },
        .{ .file = @constCast("src/remotes/b.remote.zig"), .name = @constCast("getUser") },
    };
    var bag = diagnostics.Bag.init(a);
    defer bag.deinit();
    try validateRemoteSet(&bag, &remotes);
    try std.testing.expectEqual(@as(usize, 1), bag.errorCount());
    try std.testing.expectEqualStrings("E_DUP_REMOTE_NAME", bag.items.items[0].code);
}

test "validateRouteOptions rejects v1-unsupported option combos" {
    const a = std.testing.allocator;
    var no_segs = [_]router.Segment{};
    var dyn_segs = [_]router.Segment{.{ .kind = .dynamic, .name = @constCast("id") }};
    const routes = [_]router.RoutePattern{
        fixtureRoute("src/routes/a/+page.yn", "/a", "a", &no_segs, .{ .csr = false }),
        fixtureRoute("src/routes/b/+page.yn", "/b/[id]", "b", &dyn_segs, .{ .prerender = .always }),
    };
    var bag = diagnostics.Bag.init(a);
    defer bag.deinit();
    try validateRouteOptions(&bag, &routes);
    try std.testing.expectEqual(@as(usize, 2), bag.errorCount());
    bag.sort(); // deterministic order by file: a before b
    try std.testing.expectEqualStrings("E_CSR_REQUIRED", bag.items.items[0].code);
    try std.testing.expectEqualStrings("E_PRERENDER_DYNAMIC", bag.items.items[1].code);
}

test "validateLayoutSlots requires exactly one slot outlet" {
    const a = std.testing.allocator;

    var none = try parser.parse(a, "<div>no outlet</div>");
    defer parser.deinitComponent(&none, a);
    var bag0 = diagnostics.Bag.init(a);
    defer bag0.deinit();
    try validateLayoutSlots(&bag0, "src/routes/+layout.yn", &none);
    try std.testing.expectEqual(@as(usize, 1), bag0.errorCount());
    try std.testing.expectEqualStrings("E_LAYOUT_NO_SLOT", bag0.items.items[0].code);

    var one = try parser.parse(a, "<main><slot></slot></main>");
    defer parser.deinitComponent(&one, a);
    var bag1 = diagnostics.Bag.init(a);
    defer bag1.deinit();
    try validateLayoutSlots(&bag1, "src/routes/+layout.yn", &one);
    try std.testing.expectEqual(@as(usize, 0), bag1.errorCount());

    var two = try parser.parse(a, "<div><slot></slot><slot></slot></div>");
    defer parser.deinitComponent(&two, a);
    var bag2 = diagnostics.Bag.init(a);
    defer bag2.deinit();
    try validateLayoutSlots(&bag2, "src/routes/+layout.yn", &two);
    try std.testing.expectEqual(@as(usize, 1), bag2.errorCount());
    try std.testing.expectEqualStrings("E_LAYOUT_MULTI_SLOT", bag2.items.items[0].code);
}

// End-to-end negative path: an on-disk app whose only route declares an unknown
// param type. This drives the real pipeline (filesystem walk → scan → parse →
// analyze) and proves both that the bad param surfaces as E_BAD_PARAM_TYPE and
// that a route error gates emit/render — the one diagnostic the pure-helper unit
// tests above can't reach.
test "pipeline emits E_BAD_PARAM_TYPE and gates emit/render on a bad route param" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    // Isolated app fixture: parseRouteFile rejects "[id:bogus]" from the path
    // alone, so the +page.yn contents are irrelevant.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src/routes/[id:bogus]");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/routes/[id:bogus]/+page.yn", .data = "<h1>x</h1>" });

    // cwd is process-global; capture the original through a real fd and restore
    // it (cwd() yields AT_FDCWD, which fchdir ignores — open "." for a real fd).
    var orig = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer orig.close(io);
    const tmp_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(tmp_path);
    try std.Io.Threaded.chdir(tmp_path);
    defer std.Io.Threaded.fchdir(orig.handle) catch {};

    // Build mode (out_dir set) so a clean gate proves render is skipped too.
    var build = Build.init(io, a, "dist");
    defer build.deinit();
    try build.run();

    try std.testing.expect(build.errorCount() > 0);
    var found = false;
    for (build.diags.items.items) |d| {
        if (std.mem.eql(u8, d.code, "E_BAD_PARAM_TYPE")) found = true;
    }
    try std.testing.expect(found);
    // Emit and render never ran: the build never advanced past analyze.
    try std.testing.expectEqual(Stage.analyzed, build.stage);
}

test "countAssetReferences counts static asset() calls and skips dynamic args" {
    var assets = [_]AssetEntry{
        .{ .logical = @constCast("logo.svg"), .output = @constCast(""), .url = @constCast(""), .hash = undefined, .size = 0 },
        .{ .logical = @constCast("orphan.txt"), .output = @constCast(""), .url = @constCast(""), .hash = undefined, .size = 0 },
    };
    const source =
        \\<img src={asset("logo.svg")} />
        \\<a href={asset( '/logo.svg' )}>x</a>
        \\const u = asset(dynamicName);
    ;
    countAssetReferences(&assets, source);
    // Double-quoted + single-quoted (leading slash normalized) both match; the
    // dynamic asset(expr) call is skipped.
    try std.testing.expectEqual(@as(u32, 2), assets[0].refs);
    try std.testing.expectEqual(@as(u32, 0), assets[1].refs);
}

test "warnUnreferencedAssets warns once per orphan" {
    const a = std.testing.allocator;
    const assets = [_]AssetEntry{
        .{ .logical = @constCast("used.svg"), .output = @constCast(""), .url = @constCast(""), .hash = undefined, .size = 0, .refs = 1 },
        .{ .logical = @constCast("orphan.txt"), .output = @constCast(""), .url = @constCast(""), .hash = undefined, .size = 0, .refs = 0 },
    };
    var bag = diagnostics.Bag.init(a);
    defer bag.deinit();
    try warnUnreferencedAssets(&bag, a, &assets);
    try std.testing.expectEqual(@as(usize, 0), bag.errorCount());
    try std.testing.expectEqual(@as(usize, 1), bag.warningCount());
    try std.testing.expectEqualStrings("W_ASSET_UNREFERENCED", bag.items.items[0].code);
    try std.testing.expectEqualStrings("static/orphan.txt", bag.items.items[0].file);
}

test "prepareAssetArtifacts installs only referenced assets and records orphans" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "static");
    try tmp.dir.writeFile(io, .{ .sub_path = "static/used.txt", .data = "used" });
    try tmp.dir.writeFile(io, .{ .sub_path = "static/orphan.txt", .data = "orphan" });

    var orig = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer orig.close(io);
    const tmp_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(tmp_path);
    try std.Io.Threaded.chdir(tmp_path);
    defer std.Io.Threaded.fchdir(orig.handle) catch {};

    var assets = try discoverAssets(io, a);
    defer deinitAssets(&assets, a);
    try std.testing.expectEqual(@as(usize, 2), assets.items.len);
    for (assets.items) |*e| {
        if (std.mem.eql(u8, e.logical, "used.txt")) e.refs = 1; // orphan.txt stays 0
    }

    try prepareAssetArtifacts(io, a, "dist", assets.items);

    const cwd = std.Io.Dir.cwd();
    for (assets.items) |e| {
        const installed_path = try joinPath(a, "dist", e.output);
        defer a.free(installed_path);
        const installed = if (cwd.access(io, installed_path, .{})) true else |_| false;
        if (std.mem.eql(u8, e.logical, "used.txt")) {
            try std.testing.expect(installed); // referenced -> installed
        } else {
            try std.testing.expect(!installed); // orphan -> pruned
        }
    }

    const unref = try cwd.readFileAlloc(io, "dist/assets.unreferenced.json", a, .limited(64 * 1024));
    defer a.free(unref);
    try std.testing.expect(std.mem.indexOf(u8, unref, "orphan.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, unref, "used.txt") == null);
}

test "layout chain resolution follows directory nesting" {
    const a = std.testing.allocator;
    const dirs = [_][]const u8{ "", "(docs)", "blog" };
    // Root layout wraps every page, in outermost-first order.
    try std.testing.expect(layoutApplies("", "blog/x"));
    try std.testing.expect(layoutApplies("blog", "blog/x"));
    try std.testing.expect(!layoutApplies("blog", "blogger/x")); // prefix must be a path boundary
    try std.testing.expect(layoutApplies("(docs)", "(docs)/docs/intro"));
    _ = dirs;
    try std.testing.expectEqual(@as(usize, 0), dirDepth(""));
    try std.testing.expectEqual(@as(usize, 2), dirDepth("(docs)/docs"));
    const name = try layoutName(a, "(docs)/docs");
    defer a.free(name);
    try std.testing.expectEqualStrings("_docs_docs", name);
}

test "skeleton composition nests layouts outermost-first" {
    const a = std.testing.allocator;
    const modules = [_]LayoutModule{
        .{ .file = "src/routes/+layout.yn", .module = @constCast("./pages/layout0.js"), .skeleton = @constCast("<root>" ++ codegen.slot_sentinel ++ "</root>") },
        .{ .file = "src/routes/(docs)/+layout.yn", .module = @constCast("./pages/layout1.js"), .skeleton = @constCast("<docs>" ++ codegen.slot_sentinel ++ "</docs>") },
    };
    const layouts = [_]router.LayoutRef{
        .{ .file = @constCast("src/routes/+layout.yn"), .name = @constCast("root") },
        .{ .file = @constCast("src/routes/(docs)/+layout.yn"), .name = @constCast("_docs") },
    };
    const composed = try composeSkeleton(a, "<page/>", &layouts, &modules);
    defer a.free(composed);
    try std.testing.expectEqualStrings("<root><docs><page/></docs></root>", composed);

    const urls = try layoutUrlsForRoute(a, &layouts, &modules);
    defer {
        for (urls) |u| a.free(u);
        a.free(urls);
    }
    try std.testing.expectEqualStrings("./pages/layout0.js", urls[0]);
    try std.testing.expectEqualStrings("./pages/layout1.js", urls[1]);
}

test "routesJson includes the layout chain" {
    const a = std.testing.allocator;
    var route = try router.parseRouteFile(a, "src/routes/+page.yn");
    defer route.deinit(a);
    var layout_urls = [_][]u8{@constCast("./pages/layout0.js")};
    const build_routes = [_]BuildRoute{.{
        .route = route,
        .module = @constCast("./pages/page0.js"),
        .layouts = &layout_urls,
    }};
    const json = try routesJson(a, &build_routes);
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"layouts\":[\"./pages/layout0.js\"]") != null);
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
