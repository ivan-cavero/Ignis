import { serve } from "bun";
import { spawnSync } from "child_process";
import { writeFileSync, mkdirSync } from "fs";
import { join } from "path";

const WEBHOOK_SECRET = process.env.WEBHOOK_SECRET || "";
const DEPLOY_SCRIPT = "/opt/ignis/deployments/scripts/deploy.sh";
const LOG_DIR = "/opt/ignis/logs/webhook";

const COMPONENT_MAP: Record<string, string> = {
  "backend/": "backend",
  "frontend/user/": "user-frontend",
  "frontend/admin/": "admin-frontend",
  "frontend/landing/": "landing-frontend",
  "proxy/": "proxy",
  "deployments/webhook/": "webhook",
  "scripts/": "infrastructure",
};

function verifySignature(body: string, signature: string): boolean {
  const crypto = require("crypto");
  const hmac = crypto.createHmac("sha256", WEBHOOK_SECRET);
  hmac.update(body);
  const expected = `sha256=${hmac.digest("hex")}`;
  return crypto.timingSafeEqual(Buffer.from(signature), Buffer.from(expected));
}

function detectChangedComponents(files: string[]): string[] {
  const detected = new Set<string>();
  for (const file of files) {
    for (const [prefix, component] of Object.entries(COMPONENT_MAP)) {
      if (file.startsWith(prefix)) {
        detected.add(component);
        break;
      }
    }
  }
  return [...detected];
}

function logWebhookEvent(data: unknown, logText: string): void {
  try {
    mkdirSync(LOG_DIR, { recursive: true });
    const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
    const file = join(LOG_DIR, `webhook-${timestamp}.log`);
    writeFileSync(file, logText + "\n\n--- RAW PAYLOAD ---\n" + JSON.stringify(data, null, 2));
  } catch (err) {
    console.error("Failed to write log:", err);
  }
}

type Commit = {
  added?: string[];
  modified?: string[];
  removed?: string[];
};

serve({
  port: 3333,
  async fetch(req) {
    const url = new URL(req.url);

    if (req.method !== "POST" || url.pathname !== "/webhook") {
      return new Response("Not found", { status: 404 });
    }

    const bodyText = await req.text();
    const signature = req.headers.get("x-hub-signature-256");

    if (!signature || !verifySignature(bodyText, signature)) {
      return new Response("Invalid signature", { status: 403 });
    }

    let payload: any;
    try {
      payload = JSON.parse(bodyText);
    } catch {
      return new Response("Invalid JSON", { status: 400 });
    }

    const ref = payload.ref || "";
    const branch = ref.replace("refs/heads/", "");
    const validBranches = ["main", "dev"];
    if (!validBranches.includes(branch)) {
      return new Response("Ignored branch", { status: 200 });
    }

    const environment = branch === "main" ? "production" : "development";

    const commits = Array.isArray(payload.commits) ? (payload.commits as Commit[]) : [];

    const changedFiles: string[] = [
      ...new Set(
        commits.flatMap((commit) => {
          const added = commit.added ?? [];
          const modified = commit.modified ?? [];
          const removed = commit.removed ?? [];
          return [...added, ...modified, ...removed];
        })
      ),
    ];

    const components = detectChangedComponents(changedFiles);
    const summary = `Branch: ${branch} (${environment})\nDetected changes in: ${components.join(", ") || "none"}`;

    if (components.length === 0) {
      logWebhookEvent(payload, `No components changed.\n\n${summary}`);
      return new Response("No deployment needed", { status: 200 });
    }

    let fullLog = summary + "\n";

    for (const component of components) {
      fullLog += `\n>>> Deploying ${component}...\n`;
      const result = spawnSync("bash", [
        DEPLOY_SCRIPT,
        `--component=${component}`,
        `--environment=${environment}`,
        `--branch=${branch}`,
      ], {
        cwd: "/opt/ignis",
        env: process.env,
        encoding: "utf-8",
      });

      fullLog += result.stdout || "";
      if (result.status !== 0) {
        fullLog += result.stderr || "";
        fullLog += `>>> Deployment of ${component} failed.\n`;
      } else {
        fullLog += `>>> Deployment of ${component} completed.\n`;
      }
    }

    logWebhookEvent(payload, fullLog);
    const ok = !fullLog.includes("failed");
    return new Response(ok ? "Deployment OK" : "Deployment partial/failure", {
      status: ok ? 200 : 500,
    });
  },
});
