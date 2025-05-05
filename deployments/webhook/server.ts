/**
 * GitHub webhook server for Ignis deployment automation
 * Listens for GitHub push events and triggers component-specific deployments
 */
import { serve } from "bun";
import { spawnSync } from "child_process";
import { createLogger } from "./logger";
import { join } from "path";
import crypto from "crypto";

// Configuration constants
const WEBHOOK_SECRET = process.env.WEBHOOK_SECRET || "";
const DEPLOY_SCRIPT = "/opt/ignis/deployments/scripts/deploy.sh";
const LOG_DIR = "/opt/ignis/logs/webhook";

// Component mapping for deployment targeting
const COMPONENT_MAP: Readonly<Record<string, string>> = {
  "backend/": "backend",
  "frontend/user/": "user-frontend",
  "frontend/admin/": "admin-frontend",
  "frontend/landing/": "landing-frontend",
  "proxy/": "proxy",
  "deployments/webhook/": "webhook",
  "scripts/": "infrastructure",
};

// Initialize logger
const logger = createLogger({ directory: LOG_DIR });

/**
 * Verifies the GitHub webhook signature
 * @param body - Request body as string
 * @param signature - GitHub signature header
 * @returns True if signature is valid
 */
const verifySignature = (body: string, signature: string): boolean => {
  const hmac = crypto.createHmac("sha256", WEBHOOK_SECRET);
  hmac.update(body);
  const expected = `sha256=${hmac.digest("hex")}`;
  return crypto.timingSafeEqual(Buffer.from(signature), Buffer.from(expected));
};

/**
 * Detects which components were changed based on modified files
 * @param files - Array of changed file paths
 * @returns Array of component names that need deployment
 */
const detectChangedComponents = (files: readonly string[]): readonly string[] => {
  const componentEntries = Object.entries(COMPONENT_MAP);
  
  return files
    .flatMap(file => 
      componentEntries
        .filter(([prefix]) => file.startsWith(prefix))
        .map(([, component]) => component)
    )
    .filter((value, index, self) => self.indexOf(value) === index);
};

/**
 * Extracts changed files from GitHub webhook payload
 * @param commits - Array of commit objects from GitHub
 * @returns Array of unique changed file paths
 */
const extractChangedFiles = (commits: readonly any[]): readonly string[] => {
  const allFiles = commits.flatMap(commit => [
    ...(commit.added || []),
    ...(commit.modified || []),
    ...(commit.removed || [])
  ]);
  
  return [...new Set(allFiles)];
};

/**
 * Deploys a specific component
 * @param component - Component name to deploy
 * @param environment - Deployment environment
 * @param branch - Git branch
 * @returns Deployment result object
 */
const deployComponent = (
  component: string,
  environment: string,
  branch: string
): Readonly<{
  stdout: string;
  stderr: string;
  status: number;
}> => {
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
  
  return {
    stdout: result.stdout || "",
    stderr: result.stderr || "",
    status: result.status || 0,
  };
};

/**
 * Creates a deployment summary
 * @param branch - Git branch
 * @param environment - Deployment environment
 * @param components - Array of components to deploy
 * @returns Summary string
 */
const createDeploymentSummary = (
  branch: string,
  environment: string,
  components: readonly string[]
): string => 
  `Branch: ${branch} (${environment})\nDetected changes in: ${components.join(", ") || "none"}`;

/**
 * Handles the GitHub webhook request
 * @param req - HTTP request
 * @returns HTTP response
 */
const handleWebhook = async (req: Request): Promise<Response> => {
  const url = new URL(req.url);
  
  if (req.method !== "POST" || url.pathname !== "/webhook") {
    return new Response("Not found", { status: 404 });
  }
  
  const bodyText = await req.text();
  const signature = req.headers.get("x-hub-signature-256");
  
  if (!signature || !verifySignature(bodyText, signature)) {
    await logger.warning("Invalid signature received");
    return new Response("Invalid signature", { status: 403 });
  }
  
  let payload: any;
  try {
    payload = JSON.parse(bodyText);
  } catch {
    await logger.error("Invalid JSON payload received");
    return new Response("Invalid JSON", { status: 400 });
  }
  
  const ref = payload.ref || "";
  const branch = ref.replace("refs/heads/", "");
  const validBranches = ["main", "dev"];
  
  if (!validBranches.includes(branch)) {
    await logger.info(`Ignored branch: ${branch}`);
    return new Response("Ignored branch", { status: 200 });
  }
  
  const environment = branch === "main" ? "production" : "development";
  const commits = Array.isArray(payload.commits) ? payload.commits : [];
  const changedFiles = extractChangedFiles(commits);
  const components = detectChangedComponents(changedFiles);
  const summary = createDeploymentSummary(branch, environment, components);
  
  if (components.length === 0) {
    await logger.info("No components changed", summary);
    return new Response("No deployment needed", { status: 200 });
  }
  
  await logger.info(`Deploying ${components.length} components`, summary);
  
  const deploymentResults = components.map(component => {
    const result = deployComponent(component, environment, branch);
    const success = result.status === 0;
    const logMessage = `Deployment of ${component} ${success ? "completed" : "failed"}`;
    
    if (success) {
      logger.success(logMessage, result.stdout);
    } else {
      logger.error(logMessage, `${result.stdout}\n${result.stderr}`);
    }
    
    return { component, success, result };
  });
  
  const allSuccessful = deploymentResults.every(r => r.success);
  
  return new Response(
    allSuccessful ? "Deployment OK" : "Deployment partial/failure",
    { status: allSuccessful ? 200 : 500 }
  );
};

// Start the server
serve({
  port: 3333,
  fetch: handleWebhook,
});

// Log server startup
logger.info("Webhook server started on port 3333");