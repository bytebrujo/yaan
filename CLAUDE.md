# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Yaan is a Zig-first, Svelte-like web framework prototype (V1). It compiles `.yn`
single-file components to browser ESM, discovers file-based routes, generates
typed Zig route helpers, scopes component CSS, and serves built assets with a
small HTTP dev server. There is **no Node toolchain**: no bundler, tree-shaker,
minifier, JS transformer, custom file watcher, or package cache. Watching and
incremental recompilation are delegated to Zig's build system.

Requires **Zig 0.16.0+** (`minimum_zig_version` in `build.zig.zon`).

This repo is both the framework *and* its CLI. `examples/app/` is a separate Zig
package that consumes the framework as a dependency — it is the canonical
reference for how an app project is structured and built.

## Commands

Framework repo (run from root):

```sh
zig build                 # build the `yaan` CLI binary (installed to zig-out/bin)
zig build test            # run all framework tests (lib + exe test modules)
zig build -Dapp-root=examples/app check       # run yaan check against an app
zig build -Dapp-root=examples/app app-build   # build an app into dist/
zig build -Dapp-root=examples/app dev --watch -fincremental   # dev server
```

App project (run from `examples/app/`, the reference app):

```sh
cd examples/app
zig build check        # framework-aware checks (type-checks loaders/actions/remotes/hooks)
zig build test         # app tests through the in-process Yaan harness
zig build dev          # dev server, subprocess runner model (default)
zig build dev-inproc   # in-process server: handlers linked in, no runner subprocesses
```

The dev loop is a Zig build step, not a JS-style daemon. Use
`zig build dev --watch -fincremental` so Zig handles rebuild-on-change.

### Looking up Zig APIs

This is a **Zig 0.16** codebase (`minimum_zig_version = "0.16.0"`). Its `std`
idioms differ from older Zig and from model training data — e.g. `std.Io`
threaded through call sites, `std.ArrayList` used unmanaged via `.empty`, the
`std.Build` module graph. **Do not trust remembered Zig API shapes; they are
likely stale.**

Use [`zigdoc`](https://github.com/rockorager/zigdoc) to read signatures and doc
comments. It reads docs from the **toolchain that is actually installed**, so it
always reflects the correct, current Zig version (not a remembered one), and it
covers both std symbols and modules imported in `build.zig`:

```sh
zig version                     # confirm the toolchain in use (expect 0.16.x)
zigdoc std.ArrayList            # std library symbol, for the installed Zig
zigdoc std.mem.Allocator
zigdoc std.Build.Step.Compile
zigdoc --dump-imports           # JSON of modules imported from build.zig
```

Install once with `zig build install -Doptimize=ReleaseFast --prefix $HOME/.local`
from the zigdoc checkout. Prefer `zigdoc <symbol>` over guessing an API shape.

### Tests

Tests use Zig's standard runner with `std.testing.allocator` (leak-checked).
There is **no custom test runner, tag system, or `--test-filter` wired into the
build steps**. To run a subset:

- Single self-contained module: `zig test src/parser.zig` (works for files whose
  imports are relative, e.g. `tokenizer`, `parser`, `css`).
- App-level integration tests live in `examples/app/tests/app_test.zig` and run
  via `cd examples/app && zig build test`; they need `zig build` first because
  they exercise generated `.yaan/*` + `dist/`.

The web test harness is `yaan.testing` — `TestApp`/`connCase` build synthetic
requests and drive the *same* pipeline as the dev server (hooks, HTTPS/HSTS
middleware, loaders/actions/remotes, static assets, error rendering) with **no
socket opened**. Use `yaan.testing.memoryDatabase(...)` for hermetic data tests.

## Architecture

### Two layers: framework module vs CLI

- `src/root.zig` is the public `yaan` library module. It re-exports every
  subsystem: `tokenizer`, `parser`, `css`, `router`, `codegen`, `project`,
  `server`, `observability`, `database`, `testing`, `pipeline`.
- `src/main.zig` is the `yaan` CLI binary. It dispatches four commands —
  `init`, `check`, `build`, `dev` — and parses all the server flags
  (`--csrf`, `--force-https`, `--hsts`, `--trusted-proxy`, `--otel-endpoint`,
  the `--max-*` limits, etc.). Each command delegates into `project.zig`.

### Compilation pipeline

`project.zig` is the orchestrator (the largest module). Its entry points map to
CLI commands: `checkProject`, `buildProject`, `buildDev{Load,Action,Remote,Hook}Runner`,
`writeExampleApp`. The compile flow for a `.yn` component is:

```
.yn source → tokenizer.zig → parser.zig → codegen.zig → browser ESM
                                         ↘ css.zig (component-scoped CSS)
```

`router.zig` discovers file routes under `src/routes` and drives generation of
typed Zig route helpers + metadata.

### Generated code lives in `.yaan/`, build output in `dist/`

`yaan check`/`build`/`dev` generate Zig modules into the app's `.yaan/`
directory (`routes.zig`, `hooks.zig`, `env.zig`, `assets.zig`, `database.zig`,
the `*_check.zig` type-check shims, and the `*_runner.zig` runner entry points).
**Do not hand-edit `.yaan/*` — it is regenerated.** App-authored Zig (loaders,
actions, remotes, hooks, env) imports these as named modules (`routes`, `hooks`,
`env`, `assets`, `database`, `remote`). `dist/` holds the built browser assets
and prerendered HTML.

App source conventions (see `examples/app/src/`):

- `src/routes/**/+page.yn` — file routes (`[id:int]`, `[slug:string]`,
  `[...path]` rest params, `(group)` pathless groups).
- `+load.zig`, `+actions.zig`, `+page.options.zig` — typed Zig sidecars next to a page.
- `src/remotes/*.remote.zig` — Dioxus-style server functions (`.query`/`.command`).
- `src/hooks.zig` — Plug-style request pipeline hooks (`continue_`/`halt`, returns
  `hooks.Decision`); also the centralized `onError` seam.
- `src/env.zig` — explicit typed env var declarations (`env.private`/`env.public`).

### Request pipeline and the two server models

`server.zig` (the other large module) is the HTTP/static server plus the
in-process request harness used by both dev and tests. `serve()` runs the
pipeline; `testRequest()`/`testing` drive it without a socket.

`pipeline.zig` is a comptime-composed, Tower-style **layer pipeline**: hooks
compose with explicit tagged short-circuit, a threaded request context with a
response builder, and per-route guards. The whole path is request-in/response-out
so it stays drivable in tests.

Two ways app code executes, sharing the same generated `.yaan/*` runtime and the
same `routes.Result(T)` / `hooks.Decision` types:

1. **Subprocess runners (default, `zig build dev`)** — `main.zig` compiles
   `.yaan/{hook,load,action,remote}_runner` as separate executables invoked
   per-request over JSON, keeping the generic `yaan` binary free of app code.
   `server.frameworkHook` bridges the pipeline to the hook runner subprocess.
2. **In-process (`zig build dev-inproc`)** — `app_server.zig` is the per-app
   server entry; the app's handlers are linked directly into one binary, no
   subprocess spawned. Wired by `addInProcessServer` in the framework's
   `build.zig`, which **discovers** every `+load.zig`/`+actions.zig`/`*.remote.zig`
   under `src/` and builds the module graph (no hardcoded route list). The
   server exposes per-stage function-pointer seams (`hook`/`load`/`action`/`remote`);
   an unset seam falls back to the subprocess runner. This build is
   production-safe by default (`--debug-errors` opts into verbose error pages).

`build.zig`'s `addInProcessServer` is the public framework build helper that app
`build.zig` files call. `examples/app/build.zig` is the copyable reference.

### Other subsystems

- `database.zig` — a *seam, not an ORM*: vtable-style `Database` interface,
  driver-agnostic pool, parameterized SQL-shaped calls, comptime row→struct
  mapping, and an in-memory `Memory` driver for tests (supports only
  `select * from table` and `select * from table where column = $1`).
- `observability.zig` — OpenTelemetry trace model, emits OTLP/HTTP JSON when
  `--otel-endpoint` is set (off by default). One root span per request, child
  spans per framework stage; app code adds attributes via `ctx.tracing`.

## Conventions

- **Server errors follow Zig's value/error split**: expected HTTP failures are
  *values* (`routes.Response` / `routes.Result(T).fail`, e.g. `routes.notFound`);
  unexpected failures use the `!` error channel and are transformed by a
  centralized renderer into a safe generic response correlated by a stable
  `err-<hash>` id. Don't surface internals through the `!` channel — return a
  failure value for anything the client should see.
- Error pages are raw self-contained HTML, intentionally **not** run through
  layouts/hooks/loaders (avoids recursive failure when rendering is what broke).
- The server negotiates on `Accept`: browsers get HTML, fetch/API get the stable
  JSON error body (`{ message, code, id }`).
- TLS is terminated upstream (Caddy/nginx/LB/Cloudflare); Yaan speaks HTTP and
  handles only the HTTP-level security layer (trusted forwarded headers,
  optional HTTPS redirect, HSTS, signed cookies via `YAAN_COOKIE_SECRET`, CSRF).
- Untrusted client metadata (e.g. upload `filename`) is never used as a server
  filesystem path; use the request-scoped temp `path` instead.
