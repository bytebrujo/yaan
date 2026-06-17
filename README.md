# Yaan

Yaan is a Zig-first, Svelte-like framework prototype. It compiles `.yn`
single-file components to browser ESM, discovers file routes, generates typed
Zig route helpers, scopes component CSS, and serves built assets with a small
static dev server.

```sh
zig build
zig build test
zig build -Dapp-root=examples/app check
zig build -Dapp-root=examples/app app-build
zig build -Dapp-root=examples/app dev --watch -fincremental
zig build -Dapp-root=examples/app -Dotel-endpoint=http://127.0.0.1:4318/v1/traces dev
cd examples/app && zig build test
cd examples/app && zig build dev-inproc   # in-process server: handlers linked in, no runner subprocesses
```

Start a new app with the `yaan` CLI:

```sh
yaan init my-app   # scaffold a project (creates my-app/ with src/, static/, build.zig)
cd my-app
yaan dev           # build and serve; no build.zig dependency needed for the dev loop
```

`yaan init` with no name scaffolds into the current directory. The generated
`build.zig`/`build.zig.zon` wrap the CLI so `zig build dev` works too, but the
`yaan` binary alone is enough to develop, check, and build an app.

For production, build once and serve the output:

```sh
yaan build         # optimized output into dist/
yaan start         # serve dist/ with production-safe error pages
```

`yaan start` mirrors `yaan dev` but does not rebuild `dist/` and defaults to
production-safe errors (pass `--debug-errors` for verbose local pages). It
accepts the same security/observability flags as `dev` (`--force-https`,
`--hsts`, `--csrf`, `--trusted-proxy`, `--otel-endpoint`, …). For the
linked-in, no-subprocess deployment artifact, see the in-process server
(`zig build dev-inproc`) below.

V1 is intentionally small: browser SPA output only, opaque JavaScript in
`<script>`, keyed and index-based `{#each}`, component-scoped CSS, and no Node
toolchain requirement.

Yaan's dev loop is a Zig build step. `zig build dev --watch -fincremental`
delegates watching and incremental recompilation to Zig, then runs the Yaan dev
server as the build step process. The raw `yaan dev` command still exists as the
small executable behind the step, but the intended app workflow is through
`build.zig`, not a separate JS-style daemon. In app projects, plain `zig build`
is the production build and `zig build -Doptimize=ReleaseFast` uses Zig's native
optimization pipeline. Yaan does not implement a bundler, tree-shaker, minifier,
JS transformer, custom file watcher, or package cache.

State uses explicit Dioxus-style signal handles:

```html
<script>
const count = $signal(0);
const doubled = $memo(() => count.read() * 2);
const user = $resource(async () => {
  const response = await fetch(`/api/users/${count.read()}`);
  return response.json();
});

$effect(() => {
  console.log("count", count.read());
});
</script>

<button on:click={() => count.update(n => n + 1)}>
  Count {count.read()} / {doubled.read()}
</button>
{#if user.pending()}<p>Loading</p>{:else}<p>{user.value().name}</p>{/if}
```

`$signal(initial)` returns a handle with `.read()`, `.peek()`, `.set(value)`,
`.update(fn)`, `.write(fn)`, and `.subscribe(fn)`. `.read()` participates in
reactive tracking; `.peek()` does not. `$memo(fn)` tracks signal reads and
updates a derived handle. `$resource(fn)` tracks synchronous signal reads,
executes async work, and exposes `{ status, value, error }` through `.read()` plus
helpers like `.pending()`, `.value()`, `.error()`, and `.reload()`. `$state` and
`$derived` remain aliases for compatibility, but new code should prefer
`$signal` and `$memo`.

Routes are discovered from `src/routes`:

```txt
src/routes/+page.yn                    -> /
src/routes/blog/[slug:string]/+page.yn -> /blog/:slug
src/routes/users/[id:int]/+page.yn     -> /users/:id
```

`yaan check`, `yaan build`, and `yaan dev` generate `.yaan/routes.zig`:

```zig
const routes = @import(".yaan/routes.zig");

const href = try routes.href(allocator, .{ .users_id = .{ .id = 42 } });
defer allocator.free(href);
```

Advanced routing keeps the same file-routing source of truth:

```txt
src/routes/(app)/dashboard/+page.yn       -> /dashboard
src/routes/docs/[...path]/+page.yn        -> /docs and /docs/*
```

Route groups are pathless and are emitted as explicit metadata:

```zig
for (routes.route_meta) |meta| {
    _ = meta.groups;
}
```

Rest params are typed string tails:

```zig
const docs = try routes.href(allocator, .{ .docs_path = .{ .path = "intro/setup" } });
defer allocator.free(docs);
```

Environment variables are declared explicitly in `src/env.zig`:

```zig
const env = @import("env_config");

pub const variables = env.define(.{
    .DATABASE_URL = env.private(.string, .{ .required = true }),
    .GREETING_PREFIX = env.private(.string, .{ .default = "Hello" }),
    .PUBLIC_SITE_NAME = env.public(.string, .{ .default = "Yaan" }),
    .PUBLIC_DEBUG = env.public(.bool, .{ .default = false, .static = true }),
});
```

`yaan check`, `yaan build`, and `yaan dev` load `.env` and `.env.local`.
Values from the process environment win over `.env.local`, and `.env.local`
wins over `.env`. Missing required variables or invalid typed values fail the
command.

Server-side Zig files can import the generated private/public env module:

```zig
const app_env = @import("env");

pub fn call(ctx: remote.Context, input: Input) !Output {
    return .{
        .message = try std.fmt.allocPrint(ctx.allocator, "{s}, {s}", .{
            app_env.GREETING_PREFIX,
            input.name,
        }),
    };
}
```

Only public variables are emitted to the browser:

```js
import { PUBLIC_SITE_NAME } from '/env.public.js';
```

App-wide request hooks live in `src/hooks.zig`. They follow a Plug-style
explicit request pipeline: the hook receives a mutable typed context and returns
either `continue_` or `halt`.

```zig
const std = @import("std");
const hooks = @import("hooks");

pub const Locals = struct {
    request_id: []const u8 = "dev",
};

pub fn handle(ctx: *hooks.Context(Locals)) !hooks.Decision {
    if (std.mem.eql(u8, ctx.request.path, "/healthz")) {
        return hooks.text(200, "ok");
    }
    if (std.mem.eql(u8, ctx.request.path, "/old-docs")) {
        return hooks.redirect("/docs/intro/setup");
    }
    if (std.mem.eql(u8, ctx.request.path, "/start")) {
        return hooks.rewrite("/");
    }
    return hooks.pass();
}
```

`yaan check`, `yaan build`, and `yaan dev` type-check hooks against generated
`.yaan/hooks.zig`. In dev, `handle` runs before remotes, actions, loaders, and
static file serving. V1 supports request halt, redirects, and path rewrites;
propagating typed `Locals` into route loaders/actions is a later layer.

Server-side errors follow Zig's value/error split:

- Expected HTTP failures are values, not Zig errors.
- Unexpected failures use the `!` channel and are transformed into a safe
  generic response.

Loaders and actions can return ordinary data, a `routes.Response`, or
`routes.Result(T)`:

```zig
pub const Data = struct {
    title: []const u8,
};

pub fn load(ctx: routes.LoadContext(.blog_slug)) !routes.Result(Data) {
    if (std.mem.eql(u8, ctx.params.slug, "missing")) {
        return .{ .fail = routes.notFound("Post not found") };
    }
    return .{ .value = .{ .title = ctx.params.slug } };
}
```

Remote functions have the same shape with `remote.Response` and
`remote.Result(T)`. Expected failures serialize as a stable JSON body:

```json
{ "message": "Post not found", "code": "not_found", "id": "" }
```

Unexpected errors are logged server-side and become:

```json
{ "message": "Internal Error", "code": "internal_error", "id": "err-..." }
```

Hooks can provide the centralized unexpected-error seam:

```zig
pub fn onError(ctx: *hooks.ErrorContext) hooks.Response {
    return hooks.defaultOnError(ctx);
}
```

Error pages are rendered by a centralized, self-contained renderer. Expected
failures returned as `routes.Response`/`routes.Result(T).fail` and unexpected
failures transformed by `onError` both converge there. The server negotiates on
`Accept`: browser requests receive HTML, API/fetch requests receive the stable
JSON body.

Default pages are generated for common statuses under `dist/error/`, and
`dist/404.html` is also written for static hosts:

```txt
src/error/404.html -> dist/error/404.html and dist/404.html
```

Custom error pages are raw, self-contained HTML. They are intentionally not run
through layouts, hooks, loaders, or component rendering, which avoids recursive
failures when the normal rendering path is what broke. The default verbosity
depends on which server you run:

- The `yaan dev` subprocess server shows safe details such as code/id by
  default; pass `--prod-errors` or `-Dprod-errors=true` to force
  production-safe generic 500 output.
- The in-process server (`dev-inproc` / the deploy artifact) is the production
  build, so it is production-safe by default and never leaks internals. Pass
  `--debug-errors` to opt into verbose error pages for local development; the
  `dev-inproc` build step adds it for you unless `-Dprod-errors=true` is set.

Either way, unexpected errors are correlated by a stable `err-<hash>` id (a hash
of the error name and request path) that appears both in the server log and, in
debug mode, in the rendered page — the same id regardless of transport.

TLS is intentionally terminated upstream in the recommended production setup:
Caddy, nginx, a cloud load balancer, or Cloudflare handles HTTPS, and Yaan
speaks HTTP on a private interface. Yaan's job is the HTTP-level security layer
around that topology: trusted forwarded headers, optional HTTP-to-HTTPS
redirects, and optional HSTS.

```sh
yaan dev \
  --trusted-proxy 127.0.0.1,::1 \
  --force-https \
  --hsts \
  --hsts-max-age 31536000 \
  --csrf
```

`X-Forwarded-Proto`, `X-Forwarded-Host`, and `X-Forwarded-Port` are honored only
when the socket peer is listed in `--trusted-proxy`; headers from any other
client are ignored so a public client cannot spoof HTTPS. When proxies append
header values, Yaan uses the value nearest the trusted proxy. `--force-https`
redirects insecure requests to the effective `https://` URL with `308 Permanent
Redirect`. `--hsts` emits `Strict-Transport-Security` only for requests Yaan
considers secure. HSTS is off by default because enabling it on localhost can
poison browser state and force HTTPS for future local requests. `--csrf` requires
`YAAN_COOKIE_SECRET` or `--cookie-secret`.

Yaan does not terminate production TLS in-process. If local/simple HTTPS is
added later, it should be framed as a dev convenience backed by a vetted TLS
library, not the default internet-facing deployment model.

Server observability uses OpenTelemetry's trace model and emits OTLP/HTTP JSON
when explicitly enabled:

```sh
yaan dev \
  --otel-endpoint http://127.0.0.1:4318/v1/traces \
  --otel-service my-yaan-app
```

Tracing is off by default. When enabled, the dev server creates one root span per
HTTP request and child spans for framework operations such as hooks, route
loads, form actions, remote functions, and static asset serving. The generated
hook, loader, action, and remote contexts expose a `tracing` field with `root`
and `current` span handles:

```zig
pub fn load(ctx: routes.LoadContext(.users_id)) !Data {
    var tracing = ctx.tracing;
    tracing.setAttribute("app.user_id", .{ .int = ctx.params.id });
    return .{ .id = ctx.params.id };
}
```

V1 exports framework spans from the dev server process. App-side trace
attributes are type-checked through the generated context API; returning those
attributes from runner subprocesses into the parent request span is a later
transport layer.

Database access is deliberately a seam, not an ORM. Yaan ships a small
`database` module with a vtable-style `Database` interface, a driver-agnostic
pool, parameterized SQL-shaped calls, comptime row-to-struct mapping, and a tiny
in-memory driver for tests and zero-dependency examples.

```zig
const database = @import("database");

const User = struct {
    id: i64,
    name: []const u8,
};

pub fn load(ctx: routes.LoadContext(.users_id)) !Data {
    const db = ctx.db orelse return routes.badRequest("Database is not configured");
    var users = try db.queryAs(ctx.allocator, User, "select * from users where id = $1", &.{
        .{ .int = ctx.params.id },
    });
    defer users.deinit();
    // users.items is []User
    return .{ .id = users.items[0].id };
}
```

Real adapters should expose existing drivers such as PostgreSQL, SQLite, or
MySQL behind `database.Database`. The built-in `database.Memory` driver supports
only `select * from table` and `select * from table where column = $1`; it is a
test/local fake, not a production relational store. Yaan does not provide a
query builder, schema system, migrations, lazy loading, or identity map.

Testing builds on Zig's standard runner. Yaan does not provide a custom test
runner, tag system, or code generator; use `zig build test` and
`std.testing.allocator` for leak-checked tests.

The web-specific layer is an in-process request harness. `yaan.testing.TestApp`
constructs synthetic requests and drives the same framework pipeline used by the
dev server: hooks, HTTPS/HSTS middleware, route loaders/actions/remotes, static
assets, and centralized error rendering. No socket is opened.

```zig
const std = @import("std");
const yaan = @import("yaan");

test "home page renders" {
    const app = yaan.testing.connCase(std.testing.io, std.testing.allocator, .{
        .root = "dist",
    });
    var response = try app.get("/");
    defer response.deinit(std.testing.allocator);

    try response.expectStatus(200);
    try response.expectBodyContains("<!doctype html>");
}
```

For data tests, use `yaan.testing.memoryDatabase(std.testing.allocator)` to get
a per-test in-memory database instance. This keeps tests hermetic and avoids a
standing Postgres/MySQL dependency. The example app includes copyable tests in
`examples/app/tests/app_test.zig`.

Route page options live in typed Zig sidecars, not in `.yn` or JavaScript
exports:

```txt
src/routes/blog/[slug:string]/+page.options.zig
```

```zig
const routes = @import("routes");

pub const options: routes.PageOptions = .{
    .prerender = .auto,
    .csr = true,
    .trailing_slash = .never,
};
```

`yaan check` type-checks these files and folds the resolved values back into
generated route metadata:

```zig
const meta = routes.route_meta;
const opts = routes.pageOptions(.blog_slug);
```

V1 supports `prerender`, `csr`, `trailing_slash`, and route groups as typed
metadata.
`csr = false` and `prerender = .always` on dynamic routes are rejected until
Yaan has SSR/static-param generation. Layout options should extend this
generated metadata path rather than hidden page exports.

The browser router supports SvelteKit-style opt-in snapshots for ephemeral page
state. Define a local `snapshot` object in a page script with JSON-serializable
`capture` and `restore` functions:

```html
<script>
const snapshot = {
  capture() {
    const form = document.querySelector("form");
    return form ? { email: form.email.value } : null;
  },
  restore(value) {
    const form = document.querySelector("form");
    if (form && value?.email) form.email.value = value.email;
  },
};
</script>
```

Snapshots are keyed to the browser history entry and stored in
`sessionStorage`. They are captured before SPA link navigation, back/forward
navigation, and page unload, then restored after the destination page is
created. They are intentionally for small client-only UI state, not server data
or durable persistence.

Static assets live in `static/`. `yaan build` fingerprints each file by content,
writes it under `dist/assets/`, and emits both browser and Zig manifests:

```txt
static/logo.svg -> dist/assets/logo.4e9d8c25a60e4261.svg
dist/assets.js
dist/assets.json
dist/assets.manifest.json
.yaan/assets.zig
```

Use the browser helper from `.yn` markup or script:

```html
<img src={asset("logo.svg")} alt="Yaan mark" width="64" height="64" />
```

Server-side Zig can import the generated manifest:

```zig
const assets = @import("assets");

const logo = assets.asset("logo.svg");
const entry = assets.assetEntry("logo.svg");
```

Hashed `/assets/...` files are served with
`Cache-Control: public, max-age=31536000, immutable`. `assets.js` also exports
`assetManifest` and `assetEntry()` for service-worker precache manifests and
observability tags. Yaan does not implement
image resizing/transcoding or icon processing; use a CDN or shell out to image
tools for that, and prefer CSS/icon-font/SVG-sprite approaches for icons.
`yaan check` and `yaan build` warn when an `<img>` lacks `alt`.

Route-level loaders live next to pages as `+load.zig`:

```txt
src/routes/users/[id:int]/+page.yn
src/routes/users/[id:int]/+load.zig
```

```zig
const routes = @import("routes");

pub const Data = struct {
    id: i64,
};

pub fn load(ctx: routes.LoadContext(.users_id)) !Data {
    return .{ .id = ctx.params.id };
}
```

`yaan check` generates `.yaan/routes.zig` and `.yaan/load_check.zig`, then runs
a Zig type check for every discovered loader. Loaders usually export `Data` and
can return that type directly, `routes.Result(Data)`, or `routes.Response`.
The generated context includes typed route params plus an explicit `Request`
boundary with method, path, query, headers, and body fields.

`yaan dev` also generates and compiles `.yaan/load_runner`, which imports the
project loaders and executes them through `/_yaan/load?path=...`. The browser
router fetches that endpoint before creating the page and passes the JSON result
as `props.data`.

## Layouts

A `+layout.yn` wraps every page in its directory subtree. It is an ordinary
component with exactly one `<slot></slot>` marking where the child — the next
nested layout, or the page — is mounted:

```txt
src/routes/+layout.yn            -> wraps every route (root layout)
src/routes/(docs)/+layout.yn     -> wraps every route under the (docs) group
src/routes/blog/+layout.yn       -> wraps /blog and everything beneath it
```

```html
<header>…site chrome…</header>
<slot></slot>
<footer>…</footer>
```

Each page resolves to an ordered chain of layouts, outermost (root) first, with
the page innermost. Layouts compose by nesting: the root layout's slot holds the
next layout, whose slot holds the page. `(group)` directories — already pathless
in the URL — scope a layout to just that group, exactly like SvelteKit.

The chain is prerendered nested into `#app` and surfaced in `.yaan/routes.zig`
metadata, so each route record carries its `layouts` module list. On client
navigation the router keeps a layout **mounted** as long as both its module and
its loaded data are unchanged, and rebuilds only the divergent tail — so a parent
layout's state survives sibling navigations, while a layout whose data changed
(or the page itself, whose params/data/form vary every navigation) is rebuilt.

A layout can load its own data with a sibling `+layout.load.zig`. Because one
layout wraps many routes with different param shapes, layout loaders are generic
over the context:

```zig
pub const Data = struct { framework: []const u8, year: u16 };

pub fn load(ctx: anytype) !Data { // ctx.allocator / ctx.request available
    _ = ctx;
    return .{ .framework = "Yaan", .year = 2026 };
}
```

When any layout in a chain has a loader, `/_yaan/load` returns a chain envelope
(`{ data, layouts: [...] }`) that the router unwraps into each level's
`props.data`. Layouts without a loader receive `null`. `yaan init` scaffolds a
root `+layout.yn` + `+layout.load.zig` so new projects start with site chrome.

Dioxus-style server functions live in `src/remotes` as one remote per
`*.remote.zig` file:

```txt
src/remotes/greeting.remote.zig -> greeting(...)
```

```zig
const std = @import("std");
const remote = @import("remote");

pub const kind: remote.Kind = .query; // .query or .command

pub const Input = struct {
    name: []const u8,
};

pub const Output = struct {
    message: []const u8,
};

pub fn call(ctx: remote.Context, input: Input) !Output {
    return .{
        .message = try std.fmt.allocPrint(ctx.allocator, "Hello, {s}", .{input.name}),
    };
}
```

`yaan check` verifies the remote kind plus `call(ctx, input) !Output`.
`yaan build` writes `dist/remotes.js`; `yaan dev` compiles
`.yaan/remote_runner` and serves `POST /_yaan/remote`.

```js
import { greeting } from '/remotes.js';

const hello = $resource(() => greeting({ name: 'Yaan' }));
await greeting.refresh({ name: 'Yaan' });
```

Queries are cached by stable JSON input on the client and can be refreshed.
Commands always execute and are intended for mutations.

Route-level form actions live next to pages as `+actions.zig`:

```txt
src/routes/login/+page.yn
src/routes/login/+actions.zig
```

```zig
const routes = @import("routes");

pub const Form = struct {
    email: []const u8,
    password: []const u8,
};

pub const Result = struct {
    ok: bool,
    message: []const u8,
};

pub fn action(ctx: routes.ActionContext(.login), form: Form) !Result {
    _ = ctx;
    return .{ .ok = true, .message = form.email };
}
```

The page uses a normal form:

```html
<form method="POST">
  <input name="email" />
  <input name="password" type="password" />
  <button>Submit</button>
</form>
```

`yaan check` type-checks each action against the generated route params and the
explicit request boundary. `yaan dev` compiles `.yaan/action_runner`; enhanced
browser submits post urlencoded form data to the route, executes the Zig action,
and passes the JSON result back to the page as `props.form`.

Forms with file inputs use standard multipart uploads. The dev server parses
`multipart/form-data`, writes file parts to request-scoped temp files under
`.yaan/tmp`, and passes minimal typed handles to the action:

```zig
const routes = @import("routes");

pub const Form = struct {
    title: []const u8,
    photo: ?routes.Upload,
};

pub fn action(ctx: routes.ActionContext(.login), form: Form) !routes.Response {
    _ = ctx;
    if (form.photo) |upload| {
        // upload.filename is untrusted client metadata. Use upload.path to read
        // the request-scoped temp file, or copy it to durable storage here.
        _ = upload;
    }
    return routes.fail(.created, "uploaded", "Upload accepted");
}
```

`routes.Upload` contains `{ name, filename, content_type, path, size }`, and the
same handles are available from `ctx.request.upload("photo")`. Temp files are
deleted when the request finishes unless the action copies them elsewhere. Yaan
does not provide storage backends, file validation policy, virus scanning, or
image processing. The original `filename` is never used as a server filesystem
path. Request bodies and individual file parts are capped at 8 MiB by default;
multipart uploads also cap file count, form-field bytes, multipart header bytes,
and total HTTP header bytes. Oversized uploads return `413 Payload Too Large`;
malformed multipart bodies return `400 Bad Request`.

Signed cookies and CSRF helpers are available from generated route contexts:
`ctx.request.cookie("name")`, `ctx.request.signedCookie(...)`,
`routes.signedCookieHeader(...)`, `routes.clearCookie(...)`, and
`routes.csrfPair(...)`. Signed cookies use HMAC-SHA256 with
`YAAN_COOKIE_SECRET` (or explicit `--cookie-secret`). When `--csrf` is enabled,
unsafe action POSTs must include the signed CSRF value in either `_csrf` or
`X-CSRF-Token`, matching the `yaan_csrf` cookie.

By default the dev server runs app code as separately-compiled runner
executables — `.yaan/hook_runner`, `.yaan/load_runner`, `.yaan/action_runner`,
and `.yaan/remote_runner` — invoked per request over JSON. This keeps the
generic `yaan` binary free of app code.

Yaan can also run the whole request path in-process: the app's hooks, loaders,
actions, and remotes are linked into a single server binary, and no runner
subprocess is spawned. This is an opt-in build, not a separate runtime — the
same handlers, the same generated `.yaan/*` runtime, and the same
`routes.Result(T)`/`hooks.Decision` types.

The wiring is a framework build helper. Consume Yaan as a dependency in
`build.zig.zon`:

```zig
.{
    .name = .my_app,
    .version = "0.0.0",
    .fingerprint = 0x..., // zig prints the value to use on first build
    .dependencies = .{
        .yaan = .{ .path = "../path/to/yaan" },
    },
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
```

Then a single call in `build.zig` builds the in-process server:

```zig
const yaan = @import("yaan");

const yaan_dep = b.dependency("yaan", .{ .target = target, .optimize = optimize });

// app_build_cmd runs `yaan build`, generating dist/ and .yaan/*.
const app_server = yaan.addInProcessServer(b, .{
    .target = target,
    .optimize = optimize,
    .yaan_dep = yaan_dep,
    .app_build_step = &app_build_cmd.step,
});

const dev_inproc = b.step("dev-inproc", "Run the in-process server");
dev_inproc.dependOn(&b.addRunArtifact(app_server).step);
```

`addInProcessServer` discovers every `+load.zig`, `+actions.zig`, and
`*.remote.zig` under `src/` and wires their module graph — no hardcoded route
list. `examples/app/build.zig` is a copyable reference. Run it with:

```sh
zig build dev-inproc
```

Internally the server exposes per-stage seams (`hook`, `load`, `action`,
`remote`) as function pointers on its options; the in-process build points them
at the linked handlers, and leaving a seam unset falls back to the runner
subprocess. Hooks compose through a comptime-composed, Tower-style layer
pipeline (`src/pipeline.zig`) with explicit tagged short-circuit, a threaded
request context with a response builder, and per-route guards. The whole path
stays request-in/response-out, so it remains drivable in tests without a socket.

The subprocess model (`zig build dev`) remains the default and is unchanged; the
in-process build is the path toward linking user code directly into the server
and retiring the per-request runner processes.

Static `yaan build` output is still plain browser assets. If served without the
Yaan dev server, load endpoint requests fall back to route params in the client.
