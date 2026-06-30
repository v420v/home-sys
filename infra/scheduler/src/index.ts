// Cloudflare Worker: autopilot scheduler.
//
// Cloudflare Cron Triggers fire this Worker's `scheduled` handler, which calls
// the GitHub `workflow_dispatch` API to run the autopilot GitHub Actions
// workflows. We schedule here because GitHub's own cron is best-effort and
// drops most short-interval ticks (~1 run/hour instead of every 15 min).
// Execution stays on GitHub Actions — this Worker only triggers it.
//
// This is the source of truth; `npm run build` emits ../dist/index.js, which
// Terraform uploads. The cron expressions below MUST stay in sync with the
// `schedules` in ../../terraform/main.tf — Cloudflare passes the matched
// expression as `controller.cron`.

/** Bindings configured by Terraform (see ../../terraform/main.tf). */
export interface Env {
  readonly GITHUB_OWNER: string;
  readonly GITHUB_REPO: string;
  readonly GIT_REF: string;
  readonly GITHUB_TOKEN: string;
}

/** Outcome of one workflow_dispatch attempt, logged for observability. */
interface DispatchResult {
  readonly workflowFile: string;
  readonly ok: boolean;
  readonly status?: number;
  readonly detail?: string;
  readonly error?: string;
}

/** Each registered cron expression maps to the workflow files it dispatches. */
const SCHEDULES: Readonly<Record<string, readonly string[]>> = {
  // Every 15 minutes: the review<->fix loop plus the standalone workers.
  // resolve-conflicts has no `workflow_run` chain, so reliable ticking matters
  // most for it; the others also chain but keep this as a safety net.
  "*/15 * * * *": [
    "resolve-conflicts.yml",
    "review-prs.yml",
    "address-review.yml",
    "slack.yml",
  ],
  // 18:00 UTC = 03:00 JST daily: kicks the suggest -> implement -> review chain, and
  // dispatches the AI-free usage digest (it reports the trailing 24h/7d, so running it
  // alongside the nightly kickoff is fine — the night's spend lands in tomorrow's report).
  "0 18 * * *": ["suggest-issues.yml", "usage-report.yml"],
};

/** Collapse whitespace so a lookup is robust to any cron normalization. */
function normalizeCron(cron: string): string {
  return cron.trim().replace(/\s+/g, " ");
}

async function dispatchWorkflow(
  env: Env,
  workflowFile: string,
): Promise<DispatchResult> {
  const url = `https://api.github.com/repos/${env.GITHUB_OWNER}/${env.GITHUB_REPO}/actions/workflows/${workflowFile}/dispatches`;

  let res: Response;
  try {
    res = await fetch(url, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env.GITHUB_TOKEN}`,
        Accept: "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        // GitHub rejects requests without a User-Agent.
        "User-Agent": "autopilot-scheduler",
        "Content-Type": "application/json",
      },
      // No `inputs`: GitHub applies each workflow_dispatch input's `default`,
      // which reproduces the behaviour of the old schedule-triggered runs.
      body: JSON.stringify({ ref: env.GIT_REF }),
    });
  } catch (err) {
    console.error(`dispatch ${workflowFile} threw: ${String(err)}`);
    return { workflowFile, ok: false, error: String(err) };
  }

  // The dispatch API returns 204 No Content on success.
  if (res.status === 204) {
    console.log(`dispatched ${workflowFile} on ${env.GIT_REF}`);
    return { workflowFile, ok: true, status: 204 };
  }

  const detail = await res.text();
  console.error(`dispatch ${workflowFile} failed: ${res.status} ${detail}`);
  return { workflowFile, ok: false, status: res.status, detail };
}

async function runCron(env: Env, cron: string): Promise<DispatchResult[]> {
  const workflows = SCHEDULES[normalizeCron(cron)] ?? [];
  if (workflows.length === 0) {
    console.warn(`no workflows mapped for cron "${cron}"`);
    return [];
  }
  // allSettled so one failing dispatch never blocks the others.
  const settled = await Promise.allSettled(
    workflows.map((workflow) => dispatchWorkflow(env, workflow)),
  );
  return settled.map((s) =>
    s.status === "fulfilled"
      ? s.value
      : { workflowFile: "unknown", ok: false, error: String(s.reason) },
  );
}

export default {
  // The runtime keeps the Worker alive until this promise settles, so we await
  // directly instead of using ctx.waitUntil.
  async scheduled(controller, env): Promise<void> {
    const results = await runCron(env, controller.cron);
    const failed = results.filter((r) => !r.ok);
    if (failed.length > 0) {
      throw new Error(
        `workflow_dispatch failed: ${failed.map((f) => `${f.workflowFile}(${f.status ?? f.error})`).join(", ")}`,
      );
    }
  },

  // Health endpoint: no side effects, returns no secrets — safe to expose.
  // Only reachable if a workers.dev subdomain or route is enabled (optional).
  fetch(_request, env): Response {
    return Response.json({
      service: "autopilot-scheduler",
      target: `${env.GITHUB_OWNER}/${env.GITHUB_REPO}@${env.GIT_REF}`,
      schedules: SCHEDULES,
    });
  },
} satisfies ExportedHandler<Env>;
