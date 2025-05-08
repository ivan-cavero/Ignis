/**
 * GitHub webhook server for Ignis deployment automation
 * Listens for GitHub push events and triggers component-specific deployments
 * 
 * @author v0
 * @version 1.0.0
 */
import { serve } from "bun";
import { spawnSync } from "child_process";
import { createLogger } from "./logger";
import crypto from "crypto";

// Configuration
const WEBHOOK_SECRET: string = process.env.WEBHOOK_SECRET || "";
const DEPLOY_SCRIPT: string = "/opt/ignis/deployments/scripts/deploy.sh";
const LOG_DIR: string = "/opt/ignis/logs/webhook";
const PORT: number = parseInt(process.env.WEBHOOK_PORT || "3333", 10);

// Component mapping
const COMPONENT_MAP: Record<string, string> = {
  "backend/": "backend",
  "frontend/user/": "user-frontend",
  "frontend/admin/": "admin-frontend",
  "frontend/landing/": "landing-frontend",
  "proxy/": "proxy",
  "deployments/service/": "services",
  "deployments/scripts/": "infrastructure",
  "docker-compose": "infrastructure",
};

// Types
type DeploymentResult = {
  readonly stdout: string;
  readonly stderr: string;
  readonly status: number;
};

type GitHubCommit = {
  readonly added?: readonly string[];
  readonly modified?: readonly string[];
  readonly removed?: readonly string[];
};

// Initialize logger
const logger = createLogger({ directory: LOG_DIR });

/**
 * Verifies the GitHub webhook signature
 * @param body - Request body as string
 * @param signature - GitHub signature header
 * @returns Boolean indicating if signature is valid
 */
const verifySignature = (body: string, signature: string): boolean => {
  if (!WEBHOOK_SECRET) {
    return false;
  }
  
  const hmac = crypto.createHmac("sha256", WEBHOOK_SECRET);
  hmac.update(body);
  const expected = `sha256=${hmac.digest("hex")}`;
  
  try {
    return crypto.timingSafeEqual(Buffer.from(signature), Buffer.from(expected));
  } catch {
    return false;
  }
};

/**
 * Extracts changed files from GitHub webhook payload
 * @param commits - Array of commit objects from GitHub
 * @returns Array of unique changed file paths
 */
const extractChangedFiles = (commits: readonly GitHubCommit[]): readonly string[] => {
  if (!Array.isArray(commits)) {
    return [];
  }
  
  const allFiles = commits.flatMap(commit => [
    ...(Array.isArray(commit.added) ? commit.added : []),
    ...(Array.isArray(commit.modified) ? commit.modified : []),
    ...(Array.isArray(commit.removed) ? commit.removed : [])
  ]);
  
  return [...new Set(allFiles)];
};

/**
 * Detects which components were changed based on modified files
 * @param files - Array of changed file paths
 * @returns Array of component names that need deployment
 */
const detectChangedComponents = (files: readonly string[]): readonly string[] => {
  const components = files
    .flatMap(file => 
      Object.entries(COMPONENT_MAP)
        .filter(([prefix]) => file.startsWith(prefix))
        .map(([, component]) => component)
    )
    .filter((value, index, self) => self.indexOf(value) === index);
  
  return components;
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
): DeploymentResult => {
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
 * Handles the GitHub webhook request
 * @param req - HTTP request
 * @returns HTTP response
 */
const handleWebhook = async (req: Request): Promise<Response> => {
  const url = new URL(req.url);
  
  // Only process POST requests to /webhook endpoint
  if (req.method !== "POST" || url.pathname !== "/webhook") {
    return new Response("Not found", { status: 404 });
  }
  
  // Get request body and signature
  const bodyText = await req.text();
  const signature = req.headers.get("x-hub-signature-256");
  
  // Verify signature
  if (!signature || !verifySignature(bodyText, signature)) {
    await logger.warning("Invalid signature received");
    return new Response("Invalid signature", { status: 403 });
  }
  
  // Parse payload
  let payload: any;
  try {
    payload = JSON.parse(bodyText);
  } catch (error) {
    await logger.error("Invalid JSON payload received");
    return new Response("Invalid JSON", { status: 400 });
  }
  
  // Extract branch from ref
  const ref: string = payload.ref || "";
  const branch: string = ref.replace("refs/heads/", "");
  const validBranches: readonly string[] = ["main", "dev"];
  
  // Only process valid branches
  if (!validBranches.includes(branch)) {
    await logger.info(`Ignored branch: ${branch}`);
    return new Response("Ignored branch", { status: 200 });
  }
  
  // Determine environment based on branch
  const environment: string = branch === "main" ? "production" : "development";
  
  // Extract changed files and detect components
  const commits: readonly GitHubCommit[] = Array.isArray(payload.commits) ? payload.commits : [];
  const changedFiles: readonly string[] = extractChangedFiles(commits);
  const components: readonly string[] = detectChangedComponents(changedFiles);
  
  // Skip deployment if no components changed
  if (components.length === 0) {
    await logger.info("No components changed");
    return new Response("No deployment needed", { status: 200 });
  }
  
  // Log deployment start
  await logger.info(`Deploying ${components.length} components: ${components.join(", ")}`);
  
  // Deploy each component
  const deploymentResults = components.map(component => {
    const result = deployComponent(component, environment, branch);
    const success = result.status === 0;
    
    if (success) {
      logger.success(`Deployment of ${component} completed`);
    } else {
      logger.error(`Deployment of ${component} failed`);
    }
    
    return { component, success };
  });
  
  // Check if all deployments were successful
  const allSuccessful = deploymentResults.every(r => r.success);
  
  // Return appropriate response
  return new Response(
    allSuccessful ? "Deployment OK" : "Deployment partial/failure",
    { status: allSuccessful ? 200 : 500 }
  );
};

// Start the server
serve({
  port: PORT,
  fetch: handleWebhook,
});

// Log server startup
void logger.info(`Webhook server started on port ${PORT}`);