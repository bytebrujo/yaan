# Deploy to Tencent Cloud SCF

> 🚧 **Coming soon.** This target is implemented and dry-run-verified, but not yet
> validated against a live deploy — it's blocked on Tencent account setup
> (real-name authentication + an SCF execution role; see [Prerequisites](#prerequisites)).
> The `yaan deploy tencent` command works today; the steps below are the intended flow.

A Yaan app deploys to [Tencent Cloud SCF](https://www.tencentcloud.com/products/scf)
(Serverless Cloud Functions) as an HTTP **web function**. SCF terminates HTTPS,
autoscales (to zero when idle), and injects your env vars at runtime — and unlike
a container target, there is **no image registry**: Yaan uploads the single
static binary directly (a ~3 MB zip), well under SCF's 50 MB code limit.

## How it works

SCF "web functions" proxy inbound HTTP to a process listening on
`0.0.0.0:9000`. Yaan ships two files in the code zip:

- `yaan-app` — the static-musl single binary (`dist/` embedded, no toolchain).
- `scf_bootstrap` — an executable launcher SCF runs at startup; it execs
  `./yaan-app --host 0.0.0.0 --port 9000 --trust-forwarded`.

`scf_bootstrap` is SCF's universal startup hook, so the declared `Runtime` is
just a carrier (Yaan uses `Go1`) — the static binary needs nothing from the base
image. SCF terminates TLS and forwards `X-Forwarded-*`, so `--trust-forwarded`
makes `--force-https`, HSTS, and signed/secure cookies correct.

## Prerequisites

- A Yaan app (`yaan init my-app`).
- The [Tencent Cloud CLI](https://www.tencentcloud.com/document/product/1013)
  (`tccli`), configured with credentials:

  ```sh
  tccli configure
  ```

- A **real-name authenticated** (实名认证) Tencent Cloud account. SCF refuses to
  create any function until the account is verified — this is a one-time step in
  the [console](https://console.tencentcloud.com/), done with a passport or ID.
  Until then deploys fail with `FailedOperation.AccountUnauthenticated`.
- An SCF execution role. The first time you use SCF the console offers to create
  the default `SCF_QcsRole` for you; the deploy uses that name by default
  (override with `--role`). To create it from the CLI:

  ```sh
  tccli cam CreateRole --RoleName SCF_QcsRole \
    --PolicyDocument '{"version":"2.0","statement":[{"effect":"allow","principal":{"service":"scf.qcloud.com"},"action":"name/sts:AssumeRole"}]}'
  tccli cam AttachRolePolicy --AttachRoleName SCF_QcsRole --PolicyName QcloudAccessForScfRole
  ```

## 1. Generate the deploy files (optional)

```sh
cd my-app
yaan add tencent
```

This writes `scf_bootstrap` (the launcher — edit it to add flags like
`--force-https`) and `deploy.tencent.sh` (the deploy pipeline). Both are
optional: `yaan deploy tencent` works without them, using a built-in copy.

## Automated staging/production workflow

For GitHub Actions, generate the built-in production workflow instead of wiring
CI/CD by hand:

```sh
yaan add workflow tencent
```

That writes `.github/workflows/yaan-ci.yml`,
`.github/workflows/yaan-deploy-tencent.yml`, the Tencent helper files, and
`docs/production-workflow.md`. Pull requests run checks and prove the deploy
artifact builds; pushes to `main` deploy to the GitHub `staging` environment;
production deploys are manual `workflow_dispatch` runs guarded by GitHub's
`production` environment.

Tencent is the secrets-based exception: configure `TENCENTCLOUD_SECRET_ID` and
`TENCENTCLOUD_SECRET_KEY` as GitHub environment secrets. Set
`YAAN_TENCENT_ENABLED=true` only after the GitHub environments and Tencent
variables documented in `docs/production-workflow.md` are configured. Until then,
the deploy workflow exits successfully without deploying.

## 2. Deploy

```sh
yaan deploy tencent --region ap-guangzhou --function my-app
```

This builds the static binary, packages it with `scf_bootstrap`, and creates the
web function (or updates its code if it already exists) via `tccli`. On success
it waits for the function to become `Active` and prints the public URL.

Preview every step without building or mutating anything:

```sh
yaan deploy tencent --dry-run
```

`bash ./deploy.tencent.sh` (after `yaan add tencent`) is the exact equivalent and
takes the same settings as environment variables
(`FUNCTION`, `REGION`, `NAMESPACE`, `MEMORY`, `ROLE`, `SET_ENV_VARS`, `DRY_RUN`).

## Environment variables and secrets

Pass runtime config with `--set-env-vars` as a comma-separated list of simple
`KEY=VALUE` pairs:

```sh
yaan deploy tencent --region ap-guangzhou \
  --set-env-vars "DATABASE_URL=postgres://...,PUBLIC_SITE_NAME=Acme"
```

Yaan reads `env.private` variables (and `YAAN_COOKIE_SECRET`) from the process
environment at startup, so the same binary runs in any environment without a
rebuild.

The generated Bash helper treats commas as separators before building the SCF
environment JSON. Quote spaces, quotes, and backslashes for your shell;
comma-bearing or multiline values should be set as encrypted SCF env vars after
deploy or stored in [Secrets Manager](https://www.tencentcloud.com/products/ssm)
instead of plaintext.

## HTTPS and cookies — nothing to configure

SCF terminates TLS and forwards HTTP. `scf_bootstrap` runs the server with
`--trust-forwarded`, so `--force-https`, HSTS, and secure cookies all behave
correctly behind SCF. You never manage certificates.

## Updating

Re-run the same `yaan deploy tencent` command. The script detects the existing
function and updates its code (and memory/env) in place, keeping the same URL.

## Options

| Flag | Default | Meaning |
|---|---|---|
| `--function NAME` | `yaan-app` | SCF function name |
| `--region R` | `ap-guangzhou` | SCF region |
| `--namespace NS` | `default` | SCF namespace |
| `--memory MB` | `256` | function memory |
| `--role NAME` | `SCF_QcsRole` | CAM execution role |
| `--set-env-vars K=V,...` | — | runtime env vars |
| `--dry-run` | — | print the steps, change nothing |

## Troubleshooting

- **`FailedOperation.AccountUnauthenticated` / `未实名认证`** — complete real-name
  authentication for the account in the console (prerequisites above).
- **`ResourceNotFound.Role`** — the execution role doesn't exist; create
  `SCF_QcsRole` (prerequisites above) or pass `--role <existing-role>`.
- **`tccli not found`** — install the Tencent Cloud CLI and run `tccli configure`.

For the full picture (the artifact, runtime env, concurrency, health checks,
other targets), see [deployment.md](deployment.md).
