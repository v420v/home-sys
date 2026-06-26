# autopilot

Life-automation batches: scheduled / manual GitHub Actions that run
[Claude Code Action](https://github.com/anthropics/claude-code-action)

## Flow

```mermaid
flowchart LR
    S["suggest-issues<br/>(daily)"] -->|opens| I["Issues"]
    I --> M["implement-issues<br/>(after suggest-issues)"]
    M -->|draft| P["Pull Requests"]
    R["resolve-conflicts<br/>(daily)"] -->|keep mergeable| P
    P --> V["review-prs<br/>(after implement)"]
    V -->|changes requested| A["address-review"]
    A -->|push fixes| P
    V -->|approved → ready| U["You<br/>review / merge"]
    U -.->|repos improve| S

    classDef job fill:#f0f0f0,stroke:#888,color:#222;
    classDef artifact fill:#fafafa,stroke:#bbb,color:#222;
    classDef human fill:#ffffff,stroke:#444,stroke-width:2px,color:#111;
    class S,M,R,V,A job
    class I,P artifact
    class U human
```

## Batches

| Workflow | What it does | Trigger |
| --- | --- | --- |
| [resolve-conflicts](.github/workflows/resolve-conflicts.yml) | Auto-resolve merge conflicts on your open PRs | daily + manual |
| [suggest-issues](.github/workflows/suggest-issues.yml) | Review your starred-own repos; open improvement/bug issues | daily + manual |
| [implement-issues](.github/workflows/implement-issues.yml) | Implement open issues as draft PRs | after suggest-issues + manual |
| [review-prs](.github/workflows/review-prs.yml) | Review your open PRs for correctness; record an approve / changes-requested verdict on each | after implement-issues / address-review + daily + manual |
| [address-review](.github/workflows/address-review.yml) | Read changes-requested verdicts and push fixes to the PR's head branch (the "redo" worker) | after review-prs + manual |

The **review-prs ⇄ address-review** loop is bounded: `review-prs` records a verdict in a
machine-readable marker comment on the PR, `address-review` fixes and pushes (moving the head
SHA), and the next `review-prs` run re-reviews. It converges when the review approves (the
draft PR is marked ready for you) or stops after `max_rounds` rounds (default 3), after which a
still-failing PR is left for you. GitHub forbids formally approving your own PRs, so the verdict
lives in the comment marker — not a GitHub "review" — and drives the automation.

## Setup

1. Install the [Claude GitHub App](https://github.com/apps/claude) on this repo.
2. Add two secrets under **Settings → Secrets and variables → Actions**:

   | Secret | Purpose |
   | --- | --- |
   | `CLAUDE_CODE_OAUTH_TOKEN` | Claude Max token — generate with `claude setup-token` (valid ~1 year). |
   | `GH_TOKEN` | PAT with `repo` + `workflow` scope (cross-repo read / clone / push / PR / issue). |

`claude setup-token` needs Claude Code locally — `nix develop` provides `claude-code`, `git`, `gh`, `jq`.

## Cost

GitHub Actions is free (public repo); model usage draws on your Claude Max limits with no
monetary overage. Per-run caps (`--max-turns`, `max_issues`, `timeout-minutes`) and the
model choice live in each workflow's `claude_args`.
