/**
 * GitHub webhook server for Ignis deployment automation
 * Listens for GitHub push events and triggers component-specific deployments
 *
 * @author v0
 * @version 2.0.0
 */
import { serve } from "bun"
import { spawnSync } from "child_process"
import { createLogger } from "./logger"
import crypto from "crypto"
import fs from "fs"

// Configuration
const WEBHOOK_SECRET: string = process.env.WEBHOOK_SECRET || ""
const DEPLOY_SCRIPT: string = "/opt/ignis/deployments/scripts/deploy.sh"
const LOG_DIR: string = "/opt/ignis/logs/webhook"
const PORT: number = Number.parseInt(process.env.WEBHOOK_PORT || "3333", 10)

// Debug info - write environment information at startup
const debugInfo = {
  cwd: process.cwd(),
  env: {
    NODE_ENV: process.env.NODE_ENV,
    PATH: process.env.PATH,
    WEBHOOK_SECRET: WEBHOOK_SECRET ? "***SET***" : "***NOT SET***",
    BUN_VERSION: process.env.BUN_VERSION,
  },
  files: {
    deployScript: fs.existsSync(DEPLOY_SCRIPT),
    serverTs: fs.existsSync("./server.ts"),
    logDir: fs.existsSync(LOG_DIR),
  },
}

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
}

// Initialize logger - disable console output since we're redirecting to file
const logger = createLogger({
  directory: LOG_DIR,
  prefix: "webhook",
  consoleOutput: false, // Disable console output to avoid duplication
})

// Log debug info at startup
logger.info(`Server starting with config: ${JSON.stringify(debugInfo, null, 2)}`)
// Use console.log directly for startup message
console.log(`Webhook server starting on port ${PORT}`)

/**
 * Verifies the GitHub webhook signature
 * @param {string} body - Request body
 * @param {string} signature - GitHub signature
 * @returns {boolean} Whether the signature is valid
 */
const verifySignature = (body: string, signature: string): boolean => {
  if (!WEBHOOK_SECRET) {
    logger.warning("WEBHOOK_SECRET not set - signature verification disabled")
    return true // For testing, allow without verification if no secret
  }

  try {
    const hmac = crypto.createHmac("sha256", WEBHOOK_SECRET)
    hmac.update(body)
    const expected = `sha256=${hmac.digest("hex")}`

    return crypto.timingSafeEqual(Buffer.from(signature), Buffer.from(expected))
  } catch (error) {
    logger.error(`Signature verification error: ${String(error)}`)
    return false
  }
}

/**
 * Simple health check handler
 * @returns {Response} Health check response
 */
const handleHealthCheck = (): Response => {
  return new Response(
    JSON.stringify({
      status: "ok",
      timestamp: new Date().toISOString(),
      uptime: process.uptime(),
    }),
    {
      headers: {
        "Content-Type": "application/json",
      },
    },
  )
}

/**
 * Type for GitHub commit structure
 */
type GitHubCommit = {
  readonly added?: readonly string[]
  readonly modified?: readonly string[]
  readonly removed?: readonly string[]
}

/**
 * Extracts changed components from a list of files
 * @param {string[]} files - List of changed files
 * @returns {string[]} List of affected components
 */
const extractComponents = (files: readonly string[]): string[] => {
  const uniqueFiles = [...new Set(files)]

  return uniqueFiles
    .flatMap((file) =>
      Object.entries(COMPONENT_MAP)
        .filter(([prefix]) => file.startsWith(prefix))
        .map(([, component]) => component),
    )
    .filter((value, index, self) => self.indexOf(value) === index)
}

/**
 * Deploys a component using the deploy script
 * @param {string} component - Component to deploy
 * @param {string} environment - Deployment environment
 * @param {string} branch - Git branch
 * @returns {boolean} Whether the deployment was successful
 */
const deployComponent = (component: string, environment: string, branch: string): boolean => {
  logger.info(`Deploying component: ${component}`)

  const result = spawnSync(
    "bash",
    [DEPLOY_SCRIPT, `--component=${component}`, `--environment=${environment}`, `--branch=${branch}`],
    {
      cwd: "/opt/ignis",
      env: process.env,
      encoding: "utf-8",
    },
  )

  if (result.status === 0) {
    logger.success(`Deployment of ${component} completed`)
    return true
  } else {
    logger.error(`Deployment of ${component} failed: ${result.stderr}`)
    return false
  }
}

/**
 * Extracts changed files from GitHub commits
 * @param {GitHubCommit[]} commits - Array of GitHub commits
 * @returns {string[]} Array of changed files
 */
const extractChangedFiles = (commits: readonly GitHubCommit[]): string[] => {
  return commits.flatMap((commit: GitHubCommit) => [
    ...(Array.isArray(commit.added) ? commit.added : []),
    ...(Array.isArray(commit.modified) ? commit.modified : []),
    ...(Array.isArray(commit.removed) ? commit.removed : []),
  ])
}

/**
 * Type for GitHub webhook payload
 */
type GitHubPayload = {
  readonly ref?: string
  readonly commits?: readonly GitHubCommit[]
}

/**
 * Handles the GitHub webhook request
 * @param {Request} req - HTTP request
 * @returns {Promise<Response>} HTTP response
 */
const handleWebhook = (req: Request): Promise<Response> => {
  const url = new URL(req.url)

  // Health check endpoint
  if (req.method === "GET" && url.pathname === "/health") {
    return Promise.resolve(handleHealthCheck())
  }

  // Only process POST requests to /webhook endpoint
  if (req.method !== "POST" || url.pathname !== "/webhook") {
    logger.info(`Received request to ${url.pathname} with method ${req.method}`)
    return Promise.resolve(new Response("Not found", { status: 404 }))
  }

  return req
    .text()
    .then((bodyText) => {
      logger.info(`Received webhook request: ${bodyText.substring(0, 100)}...`)

      // Get signature
      const signature = req.headers.get("x-hub-signature-256") || ""

      // Verify signature
      if (!signature) {
        logger.warning("No signature header found")
        return new Response("No signature provided", { status: 403 })
      }

      if (!verifySignature(bodyText, signature)) {
        logger.warning("Invalid signature received")
        return new Response("Invalid signature", { status: 403 })
      }

      // Parse payload
      let payload: GitHubPayload
      try {
        payload = JSON.parse(bodyText) as GitHubPayload
      } catch (error) {
        logger.error(`Invalid JSON payload: ${String(error)}`)
        return new Response("Invalid JSON", { status: 400 })
      }

      // Extract branch from ref
      const ref: string = payload.ref || ""
      const branch: string = ref.replace("refs/heads/", "")
      const validBranches: readonly string[] = ["main", "dev"]

      logger.info(`Webhook for branch: ${branch}`)

      // Only process valid branches
      if (!validBranches.includes(branch)) {
        logger.info(`Ignored branch: ${branch}`)
        return new Response("Ignored branch", { status: 200 })
      }

      // Determine environment based on branch
      const environment: string = branch === "main" ? "production" : "development"

      // Extract changed files and detect components
      const commits: readonly GitHubCommit[] = Array.isArray(payload.commits) ? payload.commits : []
      const changedFiles = extractChangedFiles(commits)

      // Detect components
      const components = extractComponents(changedFiles)

      logger.info(`Changed files: ${changedFiles.join(", ")}`)
      logger.info(`Detected components: ${components.join(", ")}`)

      // Skip deployment if no components changed
      if (components.length === 0) {
        logger.info("No components changed")
        return new Response("No deployment needed", { status: 200 })
      }

      // Deploy each component
      const deployResults = components.map((component) => deployComponent(component, environment, branch))

      const allSuccessful = deployResults.every((result) => result)

      if (allSuccessful) {
        return new Response("Deployment completed successfully", { status: 200 })
      } else {
        return new Response("Some deployments failed", { status: 500 })
      }
    })
    .catch((error) => {
      logger.error(`Unhandled error: ${String(error)}`)
      return new Response(`Server error: ${String(error)}`, { status: 500 })
    })
}

// Start the server
try {
  // Check if server is already running on this port
  try {
    const server = serve({
      port: PORT,
      fetch: handleWebhook,
    })

    logger.info(`Webhook server started on port ${PORT}`)
    console.log(`Webhook server started on port ${PORT}`)
  } catch (error) {
    if (String(error).includes("EADDRINUSE")) {
      logger.warning(`Port ${PORT} already in use, another instance may be running`)
      console.log(`Port ${PORT} already in use, another instance may be running`)
      // Exit gracefully
      process.exit(0)
    } else {
      throw error
    }
  }
} catch (error) {
  logger.error(`Failed to start server: ${String(error)}`)
  console.error(`Failed to start server: ${String(error)}`)
}
