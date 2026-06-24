# Deploy to Azure Functions

A Yaan app deploys to [Azure Functions](https://azure.microsoft.com/products/functions)
as a **custom handler**. Azure terminates HTTPS, autoscales (to zero when idle on
the Consumption plan), and injects your app settings as env vars at runtime.
There is no image to build — Yaan zip-deploys the single static binary.

## How it works

A Functions **custom handler** is just a web server: Azure proxies inbound HTTP
to a process listening on the port in `$FUNCTIONS_CUSTOMHANDLER_PORT`. Yaan ships
these files in the deployment zip:

- `yaan-app` — the static-musl single binary (`dist/` embedded, no toolchain).
- `bootstrap` — an executable launcher; it execs
  `./yaan-app --host 0.0.0.0 --port "$FUNCTIONS_CUSTOMHANDLER_PORT" --trust-forwarded`.
- `host.json` — wires the custom handler with `enableForwardingHttpRequest`
  (so the raw HTTP request reaches the binary) and an empty `routePrefix` (so the
  app serves at `/`, not `/api`).
- `http/function.json` — a catch-all anonymous HTTP trigger (`route: {*path}`).

Azure terminates TLS and forwards `X-Forwarded-*`, so `--trust-forwarded` makes
`--force-https`, HSTS, and signed/secure cookies correct.

## Prerequisites

- A Yaan app (`yaan init my-app`).
- The [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli)
  (`az`), signed in:

  ```sh
  az login
  ```

- A subscription where you can create a resource group, a storage account
  (Functions requires one), and a function app — i.e. Contributor on the
  subscription or a resource group. No other setup: the `Microsoft.Web` and
  `Microsoft.Storage` providers register automatically on first use.

## 1. Generate the deploy files (optional)

```sh
cd my-app
yaan add azure
```

This writes `bootstrap` (the launcher), `host.json` (the custom-handler config —
edit it to change methods or add `--force-https` via `bootstrap`), and
`deploy.azure.sh` (the deploy pipeline). All are optional: `yaan deploy azure`
works without them, using built-in copies.

## Automated staging/production workflow

For GitHub Actions, generate the built-in production workflow instead of wiring
CI/CD by hand:

```sh
yaan add workflow azure
```

That writes `.github/workflows/yaan-ci.yml`,
`.github/workflows/yaan-deploy-azure.yml`, the Azure helper files, and
`docs/production-workflow.md`. Pull requests run checks and prove the deploy
artifact builds; pushes to `main` deploy to the GitHub `staging` environment;
production deploys are manual `workflow_dispatch` runs guarded by GitHub's
`production` environment.

Set `YAAN_AZURE_ENABLED=true` only after the GitHub environments and Azure OIDC
variables documented in `docs/production-workflow.md` are configured. Until then,
the deploy workflow exits successfully without deploying.

## 2. Deploy

```sh
yaan deploy azure --region eastus
```

This builds the static binary, ensures the resource group / storage account /
function app exist, disables the server-side Oryx build, packages everything, and
zip-deploys via `az`. It prints the URL `https://<function-app>.azurewebsites.net`.

The function-app and storage-account names default to globally-unique values
derived from your subscription id; override with `--function` /
`--storage-account`. Preview every step without building or mutating anything:

```sh
yaan deploy azure --dry-run
```

`bash ./deploy.azure.sh` (after `yaan add azure`) is the exact equivalent and takes
the same settings as environment variables
(`FUNCTION`, `REGION`, `RESOURCE_GROUP`, `STORAGE_ACCOUNT`, `SET_ENV_VARS`,
`DRY_RUN`).

## Environment variables and secrets

Pass runtime config with `--set-env-vars` as a comma-separated list of simple
`KEY=VALUE` pairs. These become function-app settings, which the process reads
as env vars:

```sh
yaan deploy azure --region eastus \
  --set-env-vars "DATABASE_URL=postgres://...,PUBLIC_SITE_NAME=Acme"
```

Yaan reads `env.private` variables (and `YAAN_COOKIE_SECRET`) from the process
environment at startup, so the same binary runs in any environment without a
rebuild.

The generated Bash helper treats commas as separators. Quote spaces, quotes, and
backslashes for your shell; comma-bearing or multiline values should be set
directly after deploy or provided through a [Key Vault reference](https://learn.microsoft.com/azure/app-service/app-service-key-vault-references)
instead of a plaintext value.

## HTTPS and cookies — nothing to configure

Azure terminates TLS and forwards HTTP. `bootstrap` runs the server with
`--trust-forwarded`, so `--force-https`, HSTS, and secure cookies all behave
correctly. You never manage certificates.

## Updating

Re-run the same `yaan deploy azure` command. It detects the existing resources,
skips creation, and zip-deploys the new build in place — same URL.

## Options

| Flag | Default | Meaning |
|---|---|---|
| `--function NAME` | `yaan-<subid>` | function app name (globally unique) |
| `--region R` | `eastus` | Azure region |
| `--resource-group NAME` | `yaan-rg` | resource group |
| `--storage-account NAME` | `yaan<subid>` | storage account (Functions needs one) |
| `--set-env-vars K=V,...` | — | app settings / runtime env vars |
| `--dry-run` | — | print the steps, change nothing |

## Troubleshooting

- **`Could not detect runtime` / `Bad Request` on deploy** — the server-side
  Oryx build is interfering; the deploy sets `SCM_DO_BUILD_DURING_DEPLOYMENT=false`
  and `ENABLE_ORYX_BUILD=false` to prevent this (custom handlers ship a built
  binary, not source).
- **`az not found`** — install the Azure CLI and run `az login`.
- **Storage-account name taken / invalid** — names are globally unique, 3–24
  lowercase alphanumeric chars. Pass `--storage-account <name>` to choose your own.

For the full picture (the artifact, runtime env, concurrency, health checks,
other targets), see [deployment.md](deployment.md).
