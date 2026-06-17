# Proposal: `yaan add` and `yaan migrate`

Status: **Draft / not implemented.** This document scopes two future CLI
capabilities modeled on the Svelte CLI's `sv add` (add-ons) and `sv migrate`
(codemods), adapted to Yaan's Zig-first, no-Node, compiler-driven design. It is
a design target for future work, not a description of current behavior.

## Background

The `yaan` CLI today exposes `init`, `check`, `build`, and `dev`. The dev loop is
self-contained: the CLI generates everything under `.yaan/` and `dist/` and shells
out to `zig build-exe`, so an app needs no package dependency to develop. See the
[CLI comparison](#relationship-to-sv) for where Yaan stands relative to `sv`.

Two capabilities separate "a binary" from "a product people build on":

- **`yaan add <integration>`** — apply a vetted integration to an existing project
  (database driver, CSS pipeline, auth, testing harness, deploy adapter, …),
  editing the project's files idempotently. Svelte's `sv add` is the model.
- **`yaan migrate [version]`** — run codemods that move a project across a Yaan
  breaking change. Svelte's `sv migrate` is the model.

Both are explicitly **post-distribution** work: they only matter once people have
projects worth maintaining, which depends on the binary being installable and
`yaan init` producing a real project (both tracked separately on the roadmap).

## Design principles

1. **Compiler-first, not package.json-first.** `sv add` mostly edits
   `package.json`, config files, and installs npm packages. Yaan has no Node
   layer. A Yaan add-on instead: scaffolds `.zig`/`.yn`/static files, edits the
   typed seams (`src/env.zig`, `src/hooks.zig`), and — when an integration needs
   framework or third-party Zig code — adds a dependency to `build.zig.zon` and
   wiring to `build.zig`.
2. **Idempotent and detectable.** Re-running an add-on must be a no-op (or a
   clean upgrade), mirroring how `yaan init` already refuses to clobber existing
   `build.zig`/`build.zig.zon`. Each add-on declares how to detect it is already
   applied.
3. **Type-checked end state.** After any `add` or `migrate`, `yaan check` must
   pass. The Zig compiler is the backstop: a bad transform should fail `check`,
   not silently corrupt the app.
4. **Small, vetted core; community beyond.** Like `sv`, ship a handful of
   first-party add-ons that address widely-held needs and are best-in-class;
   everything else is community-distributed.
5. **Dry-run by default-able.** Both commands support `--dry-run` to print the
   planned file writes/edits without applying them.

## `yaan add`

### UX

```sh
yaan add                 # interactive picker of available add-ons
yaan add postgres        # apply one add-on with defaults
yaan add tailwind auth   # apply several
yaan add postgres --dry-run
```

### What an add-on can do

An add-on is a declarative transform over a project. The capabilities it needs:

| Capability | Example | Mechanism |
|---|---|---|
| Create files | `tailwind.config`, a `+layout` style, a deploy `Dockerfile` | write into the project tree (skip-if-exists) |
| Edit `src/env.zig` | add `DATABASE_URL` (required) | structured insert into the `env.define(.{ … })` literal |
| Edit `src/hooks.zig` | add an auth guard to the request pipeline | structured insert into `handle`/`Locals` |
| Add a Zig dependency | a real Postgres driver behind `database.Database` | append to `build.zig.zon` `.dependencies` + `build.zig` wiring |
| Register runtime config | wire a driver into the server's `db` seam | generate a small `.yaan/`-adjacent module the server picks up |

### Candidate first-party add-ons

Chosen to mirror real Yaan seams that already exist but ship empty/in-memory:

- **`postgres` / `sqlite`** — real adapters behind the existing
  `database.Database` interface (today only the in-memory `Memory` driver
  exists). Adds `DATABASE_URL` to `env.zig`, the driver dependency, and the pool
  wiring. The highest-value add-on because the DB seam is already designed for it.
- **`tailwind`** — a CSS pipeline step. Must respect Yaan's "no Node toolchain"
  stance: prefer a Zig/standalone Tailwind binary invocation over an npm install,
  or document the tradeoff explicitly.
- **`auth`** — session/cookie auth scaffolding on top of the existing signed-cookie
  and CSRF helpers; adds a hook guard and `Locals` fields.
- **`otel`** — flip on the OpenTelemetry tracing that already exists, with a
  sensible endpoint/service preset and a `.env` entry.
- **deploy adapters** (`docker`, `caddy`, `fly`, …) — emit deployment artifacts
  consistent with Yaan's "TLS terminated upstream, app speaks HTTP" model.

### Add-on definition (sketch)

An add-on is identified by name and implemented as a transform with a detector.
Two viable homes:

- **Built-in (Zig):** add-ons compiled into the `yaan` binary, each a struct with
  `id`, `detect(project) bool`, and `apply(project, options)`. Simplest to ship,
  no third-party code execution, version-locked to the CLI.
- **External (manifest):** a fetchable add-on package described by a manifest
  (files to template, edits to perform, deps to add). Enables a community
  ecosystem but raises trust/security questions — running third-party transforms
  must be opt-in and auditable (print the plan; `--dry-run`).

Recommendation: **start built-in** for the first-party set; design the manifest
format in parallel but gate external add-ons behind explicit consent once the
internal transform API has stabilized.

### Structured edits

The risky part is editing existing `.zig` files (`env.zig`, `hooks.zig`) without
breaking them. Options, least-to-most robust:

1. **Anchored text insertion** — insert before a known marker comment that
   `yaan init` emits (e.g. `// yaan:env-vars`). Cheap; brittle if the user
   reformats.
2. **Zig tokenizer-assisted insertion** — locate the `env.define(.{ … })` call /
   `handle` body via the tokenizer Yaan already vendors and splice at the AST
   boundary. More robust, reuses existing infrastructure.
3. **Regenerate-from-spec** — keep declarations in a Yaan-owned manifest and
   regenerate the file. Cleanest but changes how users author these files.

Recommendation: anchored markers for V1 (emit them from `yaan init`), graduating
to tokenizer-assisted edits as the set of add-ons grows.

## `yaan migrate`

### UX

```sh
yaan migrate             # detect current version, run the next migration(s)
yaan migrate 0.2         # migrate to a specific target
yaan migrate --dry-run
```

### When it matters

Only once Yaan has versioned breaking changes to move *between*. Today the README
explicitly defers several "later layer" items (typed `Locals` into loaders, SSR /
static-param generation, returning trace attributes across runner boundaries).
Each of those, when it lands, is a candidate for a migration: e.g. a future
loader-context signature change, or the `$state`/`$derived` → `$signal`/`$memo`
rename (already aliased for compatibility — a migration could rewrite call sites
and drop the aliases).

### What migrations transform

Harder than `sv migrate` because Yaan projects span two languages:

- **`.yn` components** — script/markup using the reactive runes (`$signal`,
  `$memo`, `$resource`, `{#each}`, `on:` handlers). Transforms here need the Yaan
  parser/tokenizer.
- **`.zig` sidecars** — loaders, actions, remotes, hooks, env, options, whose
  context types (`routes.LoadContext(...)`, `remote.Context`, …) are framework
  API surface that can change shape.

A migration is therefore a versioned bundle of codemods, each targeting a file
class, with a detector for whether it still needs to run.

### Mechanics

- **Version detection** — record the Yaan version a project targets (e.g. a
  `.yaan-version` file or a field in `build.zig.zon`) so `migrate` knows the
  starting point. `yaan init` should stamp it.
- **Ordered, idempotent steps** — migrations run in sequence; each is safe to
  re-run and reports what it changed.
- **Type-check gate** — run `yaan check` after each step; abort and report on
  failure rather than leaving a half-migrated tree.
- **Report + dry-run** — summarize files touched and manual follow-ups, like
  `sv migrate` does.

### Versioning policy dependency

Migrations are only meaningful with a stated compatibility policy (semver, a
documented "breaking changes get a migration" promise). That policy should be
decided before the first migration ships, otherwise there's no contract for
`migrate` to honor.

## Relationship to `sv`

| `sv` | Yaan analog | Notes |
|---|---|---|
| `sv create` | `yaan init [name]` | implemented |
| `sv check` | `yaan check` | implemented; Zig-compiler-backed |
| `sv add` | `yaan add` | this proposal |
| `sv migrate` | `yaan migrate` | this proposal |
| `vite dev` / `vite build` | `yaan dev` / `yaan build` | Yaan's CLI owns these; `sv` defers to Vite |

The key divergence: `sv` is a scaffolding/maintenance toolkit that sits beside
Vite, whereas `yaan` is the whole toolchain. `add`/`migrate` are the maintenance
half Yaan is missing; the build/dev half it already has.

## Suggested phasing

1. **Prereqs (separate roadmap items):** distribute the `yaan` binary; `yaan
   init` ergonomics (done). Stamp a project version for `migrate` to read.
2. **`yaan add` — internal transform API + first add-on.** Build the project-edit
   primitives (file scaffold with skip-if-exists, anchored env/hooks edits,
   `build.zig.zon` dependency append) and ship `postgres` end-to-end. Highest
   value: the DB seam is already designed for a real adapter.
3. **`yaan add` — broaden first-party set** (`sqlite`, `auth`, `otel`, a deploy
   adapter) and add the interactive picker + `--dry-run`.
4. **Compatibility policy + `yaan migrate` skeleton** — version detection, the
   ordered/idempotent runner, the check gate, with the first real codemod (e.g.
   finalize the `$state`/`$derived` rename).
5. **External add-on manifest + ecosystem** — only after the internal transform
   API is stable; gated behind explicit consent for third-party code.

## Open questions

- How does `yaan add tailwind` honor "no Node toolchain"? Bundled binary, or an
  explicit, documented exception?
- Built-in vs manifest add-ons: do we commit to the manifest format now, or let
  the built-in transform API harden first?
- Where is a project's Yaan version recorded, and does `build.zig.zon` or a
  dedicated file own it?
- Do external add-ons ever run arbitrary code, or are they restricted to a
  declarative transform schema the CLI interprets?
