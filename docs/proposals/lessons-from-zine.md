# Lessons from Zine

Status: **Reference / design target — not implemented.** This document distills
architectural patterns from [Zine](https://github.com/kristoff-it/zine)
(kristoff-it's Zig static site generator) that are worth adopting in Yaan, with
concrete implementation guidance grounded in the current codebase.

Zine and Yaan are different tools — Zine is **content-out** (filesystem content
tree → static HTML, no request lifecycle); Yaan is **request-in/response-out**
(hooks, loaders, actions, two server execution models). So none of these are
copy-paste ports. They are *patterns* whose discipline maps onto Yaan's compiler
and runtime split. Each section below states what Zine does, why it matters for
Yaan, where Yaan stands today, and how to implement it.

## Table of contents

1. [Explicit phase-based pipeline with state on domain objects](#1-explicit-phase-based-pipeline-with-state-on-domain-objects)
2. [A dedicated semantic-analysis phase before render](#2-a-dedicated-semantic-analysis-phase-before-render)
3. [Typed context model, not loose JSON](#3-typed-context-model-not-loose-json)
4. [Reference-counted assets](#4-reference-counted-assets)
5. [Dev-server: in-memory build snapshot + RW-lock swap](#5-dev-server-in-memory-build-snapshot--rw-lock-swap)
6. [Coarse-grained, phase-based parallelism](#6-coarse-grained-phase-based-parallelism)

Suggested order of adoption: **2 → 1 → 4 → 6 → 5 → 3**. Analysis (2) and the
explicit pipeline (1) pay off immediately and unblock the rest; typed context (3)
is the largest surface and best done last.

---

## 1. Explicit phase-based pipeline with state on domain objects

### What Zine does

Zine runs a fixed phase sequence — scan → activate sections → parse →
**analyze** → render → install — and stores each phase's output **directly on the
domain object** (`Page._scan`, `Page._parse`, `Page._analysis`, `Page._render`).
In debug builds it tracks stage transitions with an atomic enum and asserts the
pipeline never runs a stage out of order. The orchestrator
(`root.run`) is a readable list of phases with a `worker.wait()` barrier between
each.

### Why it matters for Yaan

`project.zig` is 3,488 lines and the largest module. Its compile flow threads
intermediate values (`BuildRoute`, `LayoutModule`, `PrerenderDoc`, `AssetEntry`,
`RemoteFunction`) through ad-hoc locals and maps. Making the phases and per-route
state explicit makes the orchestrator inspectable, testable phase-by-phase, and
much easier to extend (e.g. inserting an analysis phase, §2).

### Where Yaan stands today

- Orchestration entry points: [`checkProject`](file:///Users/louis/Documents/yaan/src/project.zig#L101),
  [`buildProject`](file:///Users/louis/Documents/yaan/src/project.zig#L152) in
  [src/project.zig](file:///Users/louis/Documents/yaan/src/project.zig).
- Per-route data is spread across `BuildRoute`, `LayoutModule`, `PrerenderDoc`
  structs that are built and consumed in the same long functions.
- There is no single "route node" that accumulates state across phases.

### How to implement

**Step 1 — Define a per-route node that owns stage outputs.** Mirror Zine's
`Page` with optional fields populated as phases run:

```zig
// src/project.zig
const RouteNode = struct {
    // _scan: discovered on the filesystem walk
    pattern: router.RoutePattern,
    page_file: []u8,            // +page.yn
    load_file: ?[]u8 = null,    // +load.zig
    actions_file: ?[]u8 = null, // +actions.zig
    options_file: ?[]u8 = null, // +page.options.zig

    // _parse: codegen output
    module: ?[]u8 = null,       // ./pages/N.js
    skeleton: ?[]u8 = null,     // prerender skeleton w/ slot sentinel
    layouts: [][]u8 = &.{},     // browser module URLs, outermost first

    // _analysis: see §2
    diagnostics: std.ArrayListUnmanaged(Diagnostic) = .empty,

    // _render: see §4 for assets
    prerender: ?PrerenderDoc = null,

    stage: if (builtin.mode == .Debug) Stage else void = undefined,
};

const Stage = enum { scanned, parsed, analyzed, rendered };
```

**Step 2 — Split the orchestrator into named phase functions** that each take and
mutate `[]RouteNode`, in place of inlined loops:

```zig
fn phaseScan(io, alloc, nodes: *std.ArrayListUnmanaged(RouteNode)) !void { ... }
fn phaseParse(io, alloc, nodes: []RouteNode) !void { ... }
fn phaseAnalyze(alloc, nodes: []RouteNode) !void { ... }   // §2
fn phaseRender(io, alloc, nodes: []RouteNode) !void { ... }
```

`buildProject` becomes a readable sequence:

```zig
try phaseScan(io, alloc, &nodes);
try phaseParse(io, alloc, nodes.items);
try phaseAnalyze(alloc, nodes.items);
if (anyDiagnostics(nodes.items)) return error.CheckFailed;
try phaseRender(io, alloc, nodes.items);
```

**Step 3 — Assert ordering in debug.** Before each phase, assert
`node.stage == .previous`, then set it. This catches accidental reordering for
free, exactly as Zine does.

**Validation:** `zig build test` plus `zig build -Dapp-root=examples/app app-build`
must produce byte-identical `dist/` output before/after the refactor (it is a
pure restructuring). Diff `dist/` against a saved copy.

---

## 2. A dedicated semantic-analysis phase before render

### What Zine does

Before rendering any HTML, Zine runs an explicit analysis phase that resolves and
validates: asset references, internal page links, layout existence, alternatives,
code-block languages, and content directives. Errors are **source-located and
accumulated** (not thrown on first failure), so one build reports every problem
at once. Rendering only runs on a graph that already type-checks.

### Why it matters for Yaan

This is the single highest-value lesson. Yaan's `check` command is the natural
home for it. Today many failures (missing layout slot, bad route param, a loader
that references a nonexistent route) surface late — during codegen, during the
Zig compile of generated `.yaan/*`, or at runtime — with errors phrased in terms
of generated code rather than the author's source. A real analysis phase moves
these to `yaan check` with messages pointing at the user's `.yn`/`.zig` file.

### Where Yaan stands today

- Diagnostics exist but are **per-component parse diagnostics only**, counted as a
  `usize`: see [`checkProject`](file:///Users/louis/Documents/yaan/src/project.zig#L101)
  and the `component.diagnostics` checks throughout
  [project.zig](file:///Users/louis/Documents/yaan/src/project.zig).
- Cross-cutting validation is scattered: duplicate route detection lives in
  [`hasDuplicateShapes`](file:///Users/louis/Documents/yaan/src/router.zig#L149)
  / [`hasDuplicateNames`](file:///Users/louis/Documents/yaan/src/router.zig#L158);
  layout-chain validation is inline in project.zig (~L984+).
- There is no unified, source-located `Diagnostic` type or accumulation
  mechanism.

### How to implement

**Step 1 — Introduce a source-located `Diagnostic` type** (replace the bare
`usize` count):

```zig
// src/project.zig (or a new src/diagnostics.zig re-exported from root.zig)
pub const Severity = enum { @"error", warning };

pub const Diagnostic = struct {
    severity: Severity,
    file: []const u8,    // author source path, not generated .yaan/*
    line: u32 = 0,
    col: u32 = 0,
    code: []const u8,    // stable id, e.g. "E_LAYOUT_NO_SLOT"
    message: []const u8,

    pub fn render(self: Diagnostic, w: anytype) !void { ... } // "file:line:col: error[CODE]: message"
};
```

**Step 2 — Add `phaseAnalyze(nodes)`** (between parse and render, per §1) that
runs each check and appends to `node.diagnostics`. Concrete checks to move/add,
each with a stable code:

| Code | Check | Source today |
|---|---|---|
| `E_DUP_ROUTE_SHAPE` | two routes resolve to same path shape | [router.hasDuplicateShapes](file:///Users/louis/Documents/yaan/src/router.zig#L149) |
| `E_DUP_ROUTE_NAME` | two routes generate the same helper name | [router.hasDuplicateNames](file:///Users/louis/Documents/yaan/src/router.zig#L158) |
| `E_LAYOUT_NO_SLOT` | `+layout.yn` lacks exactly one `<slot>` | layout parse in project.zig |
| `E_LAYOUT_MULTI_SLOT` | `+layout.yn` has >1 `<slot>` | same |
| `E_BAD_PARAM_TYPE` | `[id:int]` uses an unknown type | [router.parseRouteFile](file:///Users/louis/Documents/yaan/src/router.zig#L83) |
| `E_LOAD_SIG` | `+load.zig` signature mismatch | currently caught by `*_check.zig` shim — surface it earlier with a clearer message |
| `E_ASSET_MISSING` | a referenced asset doesn't exist | new (ties into §4) |

**Step 3 — Make `checkProject` the aggregator.** Run scan → parse → analyze, then
print all diagnostics sorted by file/line and return non-zero if any are
`.@"error"`. Keep the Zig compile of `*_check.zig` shims as a *backstop* for
things the analysis phase can't see, but aim to pre-empt the common cases with
better messages.

**Step 4 — Keep the value/error split (per CLAUDE.md).** Analysis failures are
*values* accumulated in `diagnostics`; only truly unexpected I/O failures use the
`!` channel.

**Validation:** add fixture apps under a test dir with each error class and assert
`checkProject` returns the expected diagnostic codes. This is straightforward to
unit-test because analysis is pure over `[]RouteNode`.

---

## 3. Typed context model, not loose JSON

### What Zine does

Templates don't see a loose JSON-like map. They see a typed Zig object graph:
`context.Value` is a union of every value type (`site`, `page`, `build`, `asset`,
arrays, maps, dates, errors…), and each type (`context/Site.zig`,
`context/Page.zig`) owns its fields, its callable builtins, doc strings, and
explicit error values. The template engine dispatches against Zig declarations.

### Why it matters for Yaan

Yaan's subprocess runner model passes data across the process boundary as JSON
(`headers_json`, `meta_json`, loader results). That's fine as a transport, but the
*contract* a loader/action/remote exposes to a `.yn` component and to the client
router could be a typed, documented model rather than implied JSON shape. A typed
context improves error messages (§2), enables autocompletion/doc generation, and
makes the in-process and subprocess models share one source of truth.

### Where Yaan stands today

- Generated typed helpers already exist:
  [`Params`](file:///Users/louis/Documents/yaan/src/router.zig#L490),
  [`LoadContext`](file:///Users/louis/Documents/yaan/src/router.zig#L499),
  [`ActionContext`](file:///Users/louis/Documents/yaan/src/router.zig#L509),
  [`Result(T)`](file:///Users/louis/Documents/yaan/src/router.zig#L302) in
  [`generateZigRoutes`](file:///Users/louis/Documents/yaan/src/router.zig#L200).
  So Yaan is *partway there* on the Zig side.
- The gap is the boundary to `.yn` components and the client: that contract is
  carried as JSON without a single typed schema both sides derive from.

### How to implement

This is the largest item; do it incrementally and last.

**Step 1 — Define one canonical per-route data schema in the route graph.** For
each route, the loader return type `T`, the action input/output types, and the
params type already exist as Zig types. Emit a machine-readable description of
them (field names + types) once, during codegen, into `.yaan/`.

**Step 2 — Generate both sides from that schema.** The Zig runner already uses the
Zig types; have codegen *also* emit the client-side accessor/validator for the
`.yn` component from the same schema, so a field rename can't silently desync.

**Step 3 — Model framework-provided context as a typed surface**, à la Zine's
`$page`/`$site`/`$build`. Yaan's equivalent globals are request/params/form/env.
Give each a small typed accessor in generated route code with doc comments,
instead of reaching into raw JSON.

**Note:** keep JSON as the *transport* between processes; the lesson is to have a
single typed *schema* both the transport and the templates derive from. Don't
introduce a new IPC format.

**Validation:** a round-trip test — define a loader returning a struct, assert the
generated client accessor and the Zig runner agree on field names/types; rename a
field and assert codegen output changes on both sides.

---

## 4. Reference-counted assets

### What Zine does

Assets install/serve **only when referenced** by content or templates (with an
explicit `install_always` / static-asset escape hatch starting at refcount 1).
References found during analysis (§2) act as the dependency graph. The dev server
even distinguishes "asset does not exist" from "asset exists but was never
referenced," returning a special, explanatory 404 for the latter.

### Why it matters for Yaan

Yaan currently treats assets as a flat list to emit. Reference-counting means
unused assets don't bloat `dist/`, and the dev server can give precise feedback.
It also composes with content-hashing already done for the CSS bundle.

### Where Yaan stands today

- Assets are modeled by
  [`AssetEntry`](file:///Users/louis/Documents/yaan/src/project.zig#L52) (logical
  path, output, url, 16-byte hash, size, optional inline data) and written
  unconditionally; there is no `referenced` / refcount field.
- The CSS bundle is already content-hashed and shared across pages (good — keep).

### How to implement

**Step 1 — Add a refcount to `AssetEntry`:**

```zig
const AssetEntry = struct {
    logical: []u8,
    output: []u8,
    url: []u8,
    hash: [16]u8,
    size: usize,
    inline_data: ?[]u8 = null,
    refs: u32 = 0,            // NEW; static/always assets start at 1
    install_always: bool = false,
};
```

**Step 2 — Increment during analysis (§2).** When a `.yn` component, layout, or
prerendered skeleton references an asset URL, bump `entry.refs`. This makes the
reference graph a product of the analysis phase, not a separate pass.

**Step 3 — Install only referenced assets.** In `phaseRender`/install, skip
`entry.refs == 0 and !install_always`. Emit a `warning` diagnostic
(`W_ASSET_UNREFERENCED`) so authors see dead assets at `yaan check`.

**Step 4 — Dev-server 404 nuance.** In [server.zig](file:///Users/louis/Documents/yaan/src/server.zig)
static handling, if a requested path matches a known-but-unreferenced asset,
return a 404 whose body explains "exists but not referenced" (dev/`--debug-errors`
only; production stays generic per CLAUDE.md).

**Validation:** fixture app with one referenced and one orphan asset; assert
`dist/` contains only the referenced one and `check` emits `W_ASSET_UNREFERENCED`.

---

## 5. Dev-server: in-memory build snapshot + RW-lock swap

### What Zine does

`Build.Mode` is a union of `memory` (dev) and `disk` (release), so both share one
pipeline. The dev server builds the whole site **into memory**, serves from that
snapshot under a read-write lock, and on file change rebuilds a fresh snapshot
and swaps it under the write lock, then pushes a websocket reload. No fine-grained
invalidation DAG — full rebuild, kept fast by parallelism (§6) and a debounce
window (~25ms).

### Why it matters for Yaan

Yaan's dev loop already delegates *watching/incremental compile of app code* to
the Zig build system (`zig build dev --watch -fincremental`) — that's the right
call and shouldn't change. The Zine lesson applies to the **non-compiled graph**:
route metadata, layout chains, prerender skeletons, the CSS bundle, the asset
table. Those can be rebuilt as one in-memory snapshot and atomically swapped,
rather than mutated in place while requests read them.

### Where Yaan stands today

- [server.zig](file:///Users/louis/Documents/yaan/src/server.zig) is the
  HTTP/static server and in-process harness; `serve()` runs the pipeline.
- App code reload is handled by Zig's build watcher (subprocess runners are
  recompiled). There is no explicit "current build snapshot" object guarded by a
  lock for the generated graph.

### How to implement

**Step 1 — Introduce a `BuildSnapshot`** that bundles the generated graph the
server reads per request: route table, layout chains, asset table (§4),
prerendered HTML, CSS bundle URL.

**Step 2 — Add a `Mode` split mirroring Zine** so build and dev share the
pipeline: `disk` writes `dist/`; `memory` keeps the snapshot in RAM for dev.

**Step 3 — Guard with an RW lock.** Request handlers take the read lock and use
the current `*BuildSnapshot`. A rebuild builds a *new* snapshot off to the side,
then takes the write lock only to swap the pointer (cheap), then frees the old
one. This avoids tearing without holding a lock across the whole rebuild.

**Step 4 — Keep the existing Zig watcher** as the trigger for app-code rebuilds;
add a lightweight content/layout/CSS rebuild that produces a new snapshot. Don't
build a custom file watcher (CLAUDE.md: watching is Zig's job).

**Validation:** concurrent test — drive `testRequest` on one thread while swapping
snapshots on another; assert no torn reads and that post-swap requests see new
content. The `yaan.testing` harness already drives the pipeline without a socket.

---

## 6. Coarse-grained, phase-based parallelism

### What Zine does

A global worker pool (one thread per CPU) processes a bounded queue of `Job`s
(template parse, scan, parse page, analyze page, render page, install asset). The
orchestrator schedules a batch of jobs per phase, then `worker.wait()`s before the
next phase. Workers use thread-local parsers and per-job arenas reset after each
job. Concurrency is **coarse-grained and phase-based**, not a reactive DAG —
simple to reason about, still parallel.

### Why it matters for Yaan

Yaan's compile is currently single-threaded. The per-`.yn` work
(tokenize → parse → codegen → scoped CSS) is embarrassingly parallel: each
component is independent within a phase. On apps with many routes this is the
cheapest large speedup, and the phase structure from §1 makes it a clean drop-in.

### Where Yaan stands today

- No worker pool / job system in the compiler; `database.Pool` is unrelated
  (connection pooling).
- Compile loops in [project.zig](file:///Users/louis/Documents/yaan/src/project.zig)
  iterate routes serially.

### How to implement

**Prerequisite: do §1 first.** Parallelism is trivial once phases operate over
`[]RouteNode` with a barrier between them.

**Step 1 — Add a small job pool.** Use `std.Thread.Pool` + `std.Thread.WaitGroup`
(check exact 0.16 API with `zigdoc std.Thread.Pool` — APIs differ from older Zig).

```zig
var pool: std.Thread.Pool = undefined;
try pool.init(.{ .allocator = gpa, .n_jobs = null }); // null = CPU count
defer pool.deinit();
```

**Step 2 — Parallelize the parse phase** (the heavy one) — each node is
independent:

```zig
fn phaseParse(pool: *std.Thread.Pool, alloc, nodes: []RouteNode) !void {
    var wg: std.Thread.WaitGroup = .{};
    for (nodes) |*node| pool.spawnWg(&wg, parseOne, .{ alloc, node });
    pool.waitAndWork(&wg);
}
```

**Step 3 — Per-job arenas, no shared mutable state.** Each `parseOne` writes only
into its own `*RouteNode` and uses a thread-local/per-job arena for scratch.
Results that must outlive the job (module/skeleton strings) are allocated from the
shared allocator and stored on the node. This matches Zine's "arena reset per
job" discipline and avoids `std.testing.allocator` leak-checker failures.

**Step 4 — Keep `analyze` deterministic.** Run analysis (§2) and any
duplicate-detection single-threaded (or collect then sort) so diagnostic ordering
is stable across runs — important for testable output.

**Validation:** `zig build test`; then build `examples/app` and diff `dist/`
before/after to confirm identical output. Parallelism must not change results,
only speed. Watch for leak-checker errors (each job must free its scratch).

---

## How these compose

```diagram
                 ┌──────────────────── §1 explicit phases ─────────────────────┐
   scan ──▶ parse ──▶ analyze ──▶ render ──▶ install
            │ §6        │ §2                   │ §4
            │ parallel  │ diagnostics          │ refcount → skip orphans
            ▼           ▼                      ▼
        []RouteNode  Diagnostic[]          AssetEntry.refs
                                  ╲
                                   ╲ produces
                                    ▼
                            §5 BuildSnapshot ──(RW-lock swap)──▶ dev server
                                    ▲
                                    │ derives from
                            §3 typed schema (one source for Zig runner + .yn client)
```

- **§1** is the backbone; **§2**, **§4**, **§6** all hang off the explicit phases.
- **§2** produces the reference graph **§4** consumes.
- **§5** packages the phase outputs into a swappable snapshot.
- **§3** is orthogonal and largest — tackle last.

## Non-goals / what NOT to copy

- **Don't replace the Zig build watcher.** Zine ships OS-specific inotify/kqueue
  watchers because it's standalone; Yaan deliberately delegates watching to Zig's
  build system (CLAUDE.md). Keep that.
- **Don't adopt full whole-app rebuilds for compiled code.** Zine rebuilds the
  whole site because it has no runtime app code to link. Yaan's app code stays on
  Zig incremental compilation; the in-memory-snapshot lesson (§5) applies only to
  the generated *graph*, not to recompiling loaders/actions.
- **Don't introduce a new template/markdown language.** Zine's SuperHTML/SuperMD
  are its content layer; Yaan's content layer is `.yn`. The lessons are about
  *pipeline structure*, not adopting Zine's languages.
- **Don't over-generalize for i18n yet.** Zine's per-locale `Variant` system is
  elegant but a large commitment; note it as prior art if localization becomes a
  requirement, but it's out of scope here.

## References

- Zine source: https://github.com/kristoff-it/zine (`src/root.zig`,
  `src/Build.zig`, `src/Variant.zig`, `src/context/Page.zig`, `src/worker.zig`,
  `src/cli/serve.zig`).
- Yaan orchestrator: [src/project.zig](file:///Users/louis/Documents/yaan/src/project.zig).
- Yaan route graph: [src/router.zig](file:///Users/louis/Documents/yaan/src/router.zig).
- Yaan server/harness: [src/server.zig](file:///Users/louis/Documents/yaan/src/server.zig).
- Project conventions: [CLAUDE.md](file:///Users/louis/Documents/yaan/CLAUDE.md).
