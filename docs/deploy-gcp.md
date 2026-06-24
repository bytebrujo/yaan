# Deploy to Google Cloud Run

A Yaan app deploys to Cloud Run as a single container. Cloud Run terminates
HTTPS, autoscales (to zero when idle), and injects your env vars at runtime — so
you ship one binary and nothing else.

## Prerequisites

- A Yaan app (`yaan init my-app`).
- The [Google Cloud SDK](https://cloud.google.com/sdk/docs/install): install
  `gcloud`, then sign in:

  ```sh
  gcloud auth login
  ```

- A Google Cloud project with billing enabled. Set it as the default (or pass
  `--project` on every deploy):

  ```sh
  gcloud config set project YOUR_PROJECT_ID
  ```

## 1. Generate the Cloud Run files

```sh
cd my-app
yaan add cloudrun
```

This writes a `Dockerfile` (a static binary on `scratch`), a `.gcloudignore`,
and a `deploy.sh`. It also prints the command you need for step 2.

## Automated staging/production workflow

For GitHub Actions, generate the built-in production workflow instead of wiring
CI/CD by hand:

```sh
yaan add workflow cloudrun
```

That writes `.github/workflows/yaan-ci.yml`,
`.github/workflows/yaan-deploy-cloudrun.yml`, the Cloud Run helper files, and
`docs/production-workflow.md`. Pull requests run checks and prove the deploy
artifact builds; pushes to `main` deploy to the GitHub `staging` environment;
production deploys are manual `workflow_dispatch` runs guarded by GitHub's
`production` environment.

Set `YAAN_CLOUDRUN_ENABLED=true` only after the GitHub environments and OIDC
variables documented in `docs/production-workflow.md` are configured. Until then,
the deploy workflow exits successfully without deploying.

## 2. Depend on a published framework version

Cloud Build (which builds your image) can fetch dependencies from published URLs
and from files copied into the source context. Yaan's preflight only checks the
app's `yaan` dependency: a `.path` that resolves inside your app directory is
acceptable, but a `.path` pointing outside that directory is not uploaded to
Cloud Build. The usual fix is to point your app at a released version:

```sh
zig fetch --save git+https://github.com/bytebrujo/yaan#v0.1.0
```

`yaan add cloudrun` prints the exact version to use. Skip this if you've vendored
the framework into your app so the local path stays inside the build context. If
no release exists yet, see [releasing.md](releasing.md).

## 3. Deploy

```sh
yaan deploy gcp --project YOUR_PROJECT_ID --region us-central1 --service my-app
```

That's it. The command uses Cloud Build to build your image, pushes it to
Artifact Registry, deploys it to Cloud Run, and prints your service URL. On the
first run, `gcloud` may ask to enable the Cloud Run / Cloud Build / Artifact
Registry APIs — say yes.

Preview the exact `gcloud` command without running it:

```sh
yaan deploy gcp --project YOUR_PROJECT_ID --region us-central1 --dry-run
```

By default the service is public. For a private service (require auth), add
`--no-allow-unauthenticated`.

## Environment variables and secrets

Pass runtime config with `--set-env-vars` (comma-separated `KEY=VALUE`):

```sh
yaan deploy gcp --project YOUR_PROJECT_ID --region us-central1 \
  --set-env-vars "DATABASE_URL=postgres://...,PUBLIC_SITE_NAME=Acme"
```

For secrets (cookie keys, DB passwords), prefer Secret Manager over plain env
vars:

```sh
gcloud run services update my-app --region us-central1 \
  --update-secrets YAAN_COOKIE_SECRET=yaan-cookie-secret:latest
```

Yaan reads `env.private` variables (and `YAAN_COOKIE_SECRET`) from the process
environment at startup, so the same image runs in any environment without a
rebuild.

## HTTPS and cookies — nothing to configure

Cloud Run terminates TLS and forwards HTTP. The generated Dockerfile runs the
server with `--trust-forwarded`, so `--force-https`, HSTS, and signed/secure
cookies all behave correctly behind Cloud Run. You never manage certificates.

## Updating

Re-run the same `yaan deploy gcp` command. Cloud Run rolls out a new revision
with zero downtime and keeps the same URL.

## Custom domain (optional)

```sh
gcloud run domain-mappings create \
  --service my-app --domain www.example.com --region us-central1
```

Then add the DNS records `gcloud` prints.

## Troubleshooting

- **"this app uses a local `.path` framework dependency"** — your app's `yaan`
  dependency points outside the Cloud Build source context. Do step 2, or vendor
  the framework into the app directory and deploy with `--skip-dep-check`.
- **"gcloud not found"** — install the Google Cloud SDK and run `gcloud auth
  login` (prerequisites above).
- **Build fails fetching `yaan`** — make sure the release tag in step 2 exists
  (`git ls-remote --tags https://github.com/bytebrujo/yaan`).

For the full picture (the artifact, runtime env, concurrency, health checks,
other targets), see [deployment.md](deployment.md).
