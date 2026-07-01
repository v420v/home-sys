# infra — Cloudflare Workers scheduler

GitHub Actions is a great executor but a poor scheduler: its `schedule:` cron is
best-effort and drops most short-interval ticks (a `*/15` cron really fires
roughly once an hour). So scheduling lives here, on **Cloudflare Workers Cron
Triggers**, while execution stays on GitHub Actions.

A single Worker ([`scheduler/src/index.ts`](scheduler/src/index.ts)) has cron triggers.
When one fires, the Worker calls the GitHub [`workflow_dispatch` API][dispatch]
for the workflows mapped to that cron — reliably, on time. The workflows are
otherwise unchanged: their GitHub `schedule:` triggers were removed (Cloudflare
is now the only scheduler), but `workflow_dispatch` and the `workflow_run` chains
remain.

| Cron (UTC) | Dispatches |
| --- | --- |
| `*/15 * * * *` | resolve-conflicts, review-prs, address-review, slack |
| `0 18 * * *` (03:00 JST) | suggest-issues → chains to implement → review → address; usage-report (daily cost digest) |

## Layout

```
infra/
  scheduler/             the Worker (TypeScript, compiled to JS for upload)
    src/index.ts         source of truth (strictly typed)
    dist/index.js        build output Terraform uploads (gitignored)
    package.json         tsc + @cloudflare/workers-types
  terraform/             deploys the Worker + its cron triggers
```

## Deploy

Prerequisites: a Cloudflare account and a GitHub PAT. `nix develop` provides the
`terraform` and `node` CLIs (or install Terraform ≥ 1.6 and Node ≥ 22 yourself).

1. **GitHub token** — fine-grained PAT scoped to this repo with **Actions: Read
   and write** (or a classic PAT with `repo` + `workflow`). The Worker uses it to
   dispatch workflows. You can reuse the repo's existing `GH_TOKEN` value.

2. **Cloudflare API token** — create one with the **Workers Scripts: Edit**
   account permission. Note your **Account ID** (dashboard → Workers & Pages, or
   any zone's overview pane).

3. **Build the Worker** (TypeScript → `dist/index.js`, which Terraform uploads):

   ```sh
   cd infra/scheduler
   npm ci
   npm run build
   ```

4. **Configure & apply** (state is in R2 — do the one-time
   [R2 setup](#continuous-deployment) first):

   ```sh
   cd ../terraform
   cp terraform.tfvars.example terraform.tfvars   # set cloudflare_account_id
   export CLOUDFLARE_API_TOKEN=...                 # Cloudflare token (step 2)
   export TF_VAR_github_token=...                  # GitHub PAT (step 1)
   export AWS_ACCESS_KEY_ID=...  AWS_SECRET_ACCESS_KEY=...  # R2 S3 keys
   terraform init -backend-config=r2.backend.hcl
   terraform plan
   terraform apply
   ```

## Verify

- `npx wrangler tail autopilot-scheduler` — live logs; each cron tick prints
  `dispatched <workflow> …` (npx fetches wrangler on demand; or use the
  dashboard → the Worker → Logs).
- Dashboard → Workers & Pages → `autopilot-scheduler` → Settings → Triggers shows
  the cron schedules; **Cron Events** lets you fire one manually.
- After a tick, the runs appear under the repo's **Actions** tab marked
  "triggered via workflow_dispatch".

## Continuous deployment

[`deploy-scheduler.yml`](../.github/workflows/deploy-scheduler.yml) runs
`terraform apply` automatically on **push to `main`** that touches
`infra/scheduler/**` or `infra/terraform/**` (also runnable via *Run workflow*).
It builds the Worker and applies, so editing the worker or its schedule
redeploys itself. It is **main-only** and serialized (one apply at a time).

CI needs **shared remote state** — a fresh runner has no local state — so state
lives in **Cloudflare R2** (S3-compatible), keeping everything on Cloudflare.

**One-time setup:**

1. **R2 bucket** — create a *private* bucket, e.g. `autopilot-tfstate`
   (dashboard → R2 → Create bucket). It stores Terraform state, which contains
   the `github_token`, so it must stay private.
2. **R2 API token** — R2 → *Manage R2 API Tokens* → create a token with **Object
   Read & Write**; this yields an S3 **Access Key ID** and **Secret Access Key**.
3. **Repo secrets** (Settings → Secrets and variables → Actions → *Secrets*):

   | Secret | Value |
   | --- | --- |
   | `CLOUDFLARE_API_TOKEN` | Cloudflare token (Workers Scripts: Edit) |
   | `R2_ACCESS_KEY_ID` | R2 Access Key ID |
   | `R2_SECRET_ACCESS_KEY` | R2 Secret Access Key |
   | `GH_TOKEN` | already set — reused as the Worker's dispatch token |

4. **Repo variables** (same page → *Variables*):

   | Variable | Value |
   | --- | --- |
   | `CLOUDFLARE_ACCOUNT_ID` | your Cloudflare account ID |
   | `TFSTATE_BUCKET` | the R2 bucket name (e.g. `autopilot-tfstate`) |

5. **Migrate your existing local state to R2** (one time, locally). Create
   `infra/terraform/r2.backend.hcl` (gitignored):

   ```hcl
   bucket    = "autopilot-tfstate"
   endpoints = { s3 = "https://<ACCOUNT_ID>.r2.cloudflarestorage.com" }
   ```

   then move the state:

   ```sh
   cd infra/terraform
   export AWS_ACCESS_KEY_ID=...  AWS_SECRET_ACCESS_KEY=...   # R2 S3 keys
   terraform init -migrate-state -backend-config=r2.backend.hcl   # answer "yes"
   ```

After that, pushing a worker or Terraform change to `main` deploys it
automatically, and local + CI share the R2 state.

## Notes

- **Cutover order:** apply Terraform and confirm a dispatch works *before* merging
  the workflow changes that drop the GitHub `schedule:` triggers, so there's no
  scheduling gap. A brief overlap is harmless — each workflow's skip-guard drops a
  duplicate tick if a run is already active.
- The `github_token` is a Worker `secret_text` binding, so it lands in Terraform
  state — which is why the R2 state bucket must stay private.
- After editing `scheduler/src/index.ts`, run `npm run build` so `dist/index.js`
  (and thus `content_sha256`) changes — the next `terraform apply` redeploys.
  Keep the cron strings in `src/index.ts` and `terraform/main.tf` in sync.

[dispatch]: https://docs.github.com/en/rest/actions/workflows#create-a-workflow-dispatch-event
