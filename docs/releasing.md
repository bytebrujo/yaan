# Releasing Yaan

Yaan is consumed as a Zig package. "Publishing" a version is just **pushing a
git tag** — Zig fetches the framework from the repo at that tag. A published
version is what makes apps reproducible and what lets **Cloud Build deploys**
work (Cloud Build can't reach a local `.path` dependency; it can fetch a tagged
URL).

## Cut a release

1. Pick the version and update `.version` in `build.zig.zon` (e.g. `0.1.0`).
   Keep `minimum_zig_version` accurate. Commit on `main`.
2. Tag and push:

   ```sh
   git tag v0.1.0
   git push origin v0.1.0
   ```

3. The `release` workflow validates the tagged commit (`zig build test`, example
   app build/test/check) and creates a GitHub Release. The tag itself is the
   consumable — no artifact upload is required.

## Depend on a published version

In an app's `build.zig.zon`:

```sh
zig fetch --save git+https://github.com/bytebrujo/yaan#v0.1.0
```

This writes a `url`+`hash` dependency:

```zig
.dependencies = .{
    .yaan = .{
        .url = "git+https://github.com/bytebrujo/yaan#v0.1.0",
        .hash = "...",
    },
},
```

Then `zig build -Doptimize=ReleaseFast` builds the single-binary artifact, and
`gcloud run deploy --source .` works because Cloud Build fetches the framework
from the URL instead of a local path.

## Local development vs deployment

- `yaan init` writes a **local `.path`** dependency to your framework checkout —
  best for hacking on an app against an unpublished/local framework, but not
  reachable by Cloud Build.
- For deployment (or to pin a reproducible version), switch to the published
  URL dependency with the `zig fetch --save` command above. `yaan add cloudrun`
  prints the exact command for the framework's current version.

## CI

`ci.yml` builds and tests the framework and the example app (including the
static-musl cross-build) on every push to `main` and every PR.
