# Deploy to Alibaba Cloud Function Compute

> 🚧 **Coming soon.** This target is implemented and validated against Function
> Compute's API schema + dry-run, but not yet run against a live deploy — it's
> blocked on Alibaba account setup (credentials with FC + OSS permissions; see
> [Prerequisites](#prerequisites)). The `yaan deploy alibaba` command works today;
> the steps below are the intended flow.

A Yaan app deploys to [Alibaba Cloud Function Compute](https://www.alibabacloud.com/product/function-compute)
(FC 3.0) as a **custom-runtime HTTP function**. FC terminates HTTPS, autoscales
(to zero when idle), and injects your env vars at runtime. There is no image to
build — Yaan uploads the single static binary as a code zip.

## How it works

FC custom-runtime functions run an executable **`bootstrap`** and proxy inbound
HTTP to a server listening on `0.0.0.0:9000`. Yaan ships two files in the code
zip:

- `yaan-app` — the static-musl single binary (`dist/` embedded, no toolchain).
- `bootstrap` — an executable launcher; it execs
  `./yaan-app --host 0.0.0.0 --port 9000 --trust-forwarded`.

The declared runtime (`custom.debian10`) is just a carrier — the static binary
needs nothing from the base image. FC terminates TLS and forwards
`X-Forwarded-*`, so `--trust-forwarded` makes `--force-https`, HSTS, and
signed/secure cookies correct.

Because the `aliyun` CLI can't inline a multi-MB zip on the command line (past
`ARG_MAX`), the code zip is uploaded to **OSS** and the function references it by
bucket/object. The deploy auto-creates a bucket `yaan-fc-<accountid>` (override
with `--oss-bucket`). A public **HTTP trigger** (anonymous auth) gives the URL.

## Prerequisites

- A Yaan app (`yaan init my-app`).
- The [Alibaba Cloud CLI](https://www.alibabacloud.com/help/en/cli) (`aliyun`),
  configured with credentials:

  ```sh
  aliyun configure
  ```

- Credentials (a RAM user or role) with **Function Compute + OSS** permissions —
  enough to create functions/triggers and to create a bucket and upload an
  object. The managed policies `AliyunFCFullAccess` and `AliyunOSSFullAccess`
  cover it; a least-privilege policy needs `fc:CreateFunction`,
  `fc:UpdateFunction`, `fc:GetFunction`, `fc:CreateTrigger`, `fc:GetTrigger`,
  `oss:PutBucket`, and `oss:PutObject`. If you pass `--role`, the credentials
  also need `ram:PassRole` for `fc.aliyuncs.com`.

## 1. Generate the deploy files (optional)

```sh
cd my-app
yaan add alibaba
```

This writes `bootstrap` (the launcher — edit it to add flags like
`--force-https`) and `deploy.alibaba.sh` (the deploy pipeline). Both are
optional: `yaan deploy alibaba` works without them, using a built-in copy.

## 2. Deploy

```sh
yaan deploy alibaba --region ap-southeast-1 --function my-app
```

This builds the static binary, packages it with `bootstrap`, uploads the zip to
OSS, and creates the function (or updates its code if it already exists) plus an
anonymous HTTP trigger via `aliyun`, then prints the public URL.

Preview every step without building or mutating anything:

```sh
yaan deploy alibaba --dry-run
```

`sh deploy.alibaba.sh` (after `yaan add alibaba`) is the exact equivalent and
takes the same settings as environment variables
(`FUNCTION`, `REGION`, `MEMORY`, `CPU`, `OSS_BUCKET`, `ROLE`, `SET_ENV_VARS`,
`DRY_RUN`).

## Environment variables and secrets

Pass runtime config with `--set-env-vars` (comma-separated `KEY=VALUE`):

```sh
yaan deploy alibaba --region ap-southeast-1 \
  --set-env-vars "DATABASE_URL=postgres://...,PUBLIC_SITE_NAME=Acme"
```

Yaan reads `env.private` variables (and `YAAN_COOKIE_SECRET`) from the process
environment at startup, so the same binary runs in any environment without a
rebuild. For secrets, prefer [KMS Secrets Manager](https://www.alibabacloud.com/help/en/kms)
over plaintext env vars.

## HTTPS and cookies — nothing to configure

FC terminates TLS and forwards HTTP. `bootstrap` runs the server with
`--trust-forwarded`, so `--force-https`, HSTS, and secure cookies all behave
correctly behind FC. You never manage certificates.

## Updating

Re-run the same `yaan deploy alibaba` command. The script detects the existing
function, uploads the new zip to OSS, and updates the function code in place,
keeping the same URL and trigger.

## Options

| Flag | Default | Meaning |
|---|---|---|
| `--function NAME` | `yaan-app` | FC function name |
| `--region R` | `ap-southeast-1` | FC region |
| `--memory MB` | `512` | function memory |
| `--cpu vCPU` | `0.35` | function CPU (memory:cpu must be 1–4 GB/vCPU) |
| `--oss-bucket NAME` | `yaan-fc-<accountid>` | OSS bucket for the code zip |
| `--role ARN` | — | RAM role the function assumes |
| `--set-env-vars K=V,...` | — | runtime env vars |
| `--dry-run` | — | print the steps, change nothing |

## Troubleshooting

- **`AccessDenied` / `Forbidden.RAM`** — the credentials lack FC or OSS
  permissions; attach the policies above (prerequisites).
- **`aliyun not found`** — install the Alibaba Cloud CLI and run
  `aliyun configure`.
- **`InvalidArgument` on cpu/memory** — FC requires `memorySize` (MB) to be a
  multiple of 64 and the memory-to-CPU ratio to be 1–4 GB per vCPU. The defaults
  (512 MB / 0.35 vCPU) satisfy this.

For the full picture (the artifact, runtime env, concurrency, health checks,
other targets), see [deployment.md](deployment.md).
