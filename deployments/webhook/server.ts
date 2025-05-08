/**
 * GitHub webhook server for Ignis deployment automation
 * Listens for GitHub push events and triggers component-specific deployments
 *
 * @author v0
 * @version 3.0.0
 */
import { serve } from "bun"
import { spawnSync } from "child_process"
import crypto from "crypto"
import fs from "fs"

// Configuration
const WEBHOOK_SECRET: string = process.env.WEBHOOK_SECRET || ""
const DEPLOY_SCRIPT: string = "/opt/ignis/deployments/scripts/deploy.sh"
const LOG_DIR: string = "/opt/ignis/logs/webhook"
const PORT: number = Number.parseInt(process.env.WEBHOOK_PORT || "3333", 10)
const HOST: string = process.env.WEBHOOK_HOST || "127.0.0.1" // Escuchar solo en localhost por defecto

// Create date string for log file name (YYYYMMDD format)
const getDateString = (): string => {
  const now = new Date()
  const year = now.getFullYear()
  const month = String(now.getMonth() + 1).padStart(2, "0")
  const day = String(now.getDate()).padStart(2, "0")
  return `${year}${month}${day}`
}

const LOG_FILE: string = `${LOG_DIR}/webhook-${getDateString()}.log`

// Create log directory if it doesn't exist
try {
  if (!fs.existsSync(LOG_DIR)) {
    fs.mkdirSync(LOG_DIR, { recursive: true })
  }
} catch (error) {
  console.error(`Failed to create log directory: ${String(error)}`)
}

// Simple logging function
const log = (level: string, message: string): void => {
  const timestamp = new Date().toISOString()
  const logMessage = `[${timestamp}] [${level}] ${message}\n`

  // Log to console
  console.log(logMessage.trim())

  // Log to file
  try {
    fs.appendFileSync(LOG_FILE, logMessage)
  } catch (error) {
    console.error(`Failed to write to log file: ${String(error)}`)
  }
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

// Create a lock file to prevent multiple instances
const LOCK_FILE = "/tmp/ignis-webhook.lock"

// Check if another instance is running
const checkLock = (): boolean => {
  try {
    // Check if lock file exists
    if (fs.existsSync(LOCK_FILE)) {
      const pid = fs.readFileSync(LOCK_FILE, "utf-8").trim()

      // Check if process with PID is still running
      try {
        process.kill(Number(pid), 0)
        // Process exists, another instance is running
        return true
      } catch (e) {
        // Process doesn't exist, stale lock file
        fs.unlinkSync(LOCK_FILE)
      }
    }

    // Create lock file with current PID
    fs.writeFileSync(LOCK_FILE, process.pid.toString())

    // Register cleanup on exit
    process.on("exit", () => {
      try {
        fs.unlinkSync(LOCK_FILE)
      } catch (e) {
        // Ignore errors during cleanup
      }
    })

    return false
  } catch (e) {
    // Error checking lock, assume no lock
    return false
  }
}

// Log startup information
log("INFO", `Server starting on port ${PORT}`)

/**
 * Verifies the GitHub webhook signature
 * @param {string} body - Request body
 * @param {string} signature - GitHub signature
 * @returns {boolean} Whether the signature is valid
 */
const verifySignature = (body: string, signature: string): boolean => {
  if (!WEBHOOK_SECRET) {
    log("WARNING", "WEBHOOK_SECRET not set - signature verification disabled")
    return true // For testing, allow without verification if no secret
  }

  try {
    const hmac = crypto.createHmac("sha256", WEBHOOK_SECRET)
    hmac.update(body)
    const expected = `sha256=${hmac.digest("hex")}`

    return crypto.timingSafeEqual(Buffer.from(signature), Buffer.from(expected))
  } catch (error) {
    log("ERROR", `Signature verification error: ${String(error)}`)
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
  log("INFO", `Deploying component: ${component}`)

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
    log("SUCCESS", `Deployment of ${component} completed`)
    return true
  } else {
    log("ERROR", `Deployment of ${component} failed: ${result.stderr}`)
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

  // Only process POST requests to /webhook endpoint or root path
  if (req.method !== "POST" || (url.pathname !== "/webhook" && url.pathname !== "/")) {
    log("INFO", `Received request to ${url.pathname} with method ${req.method}`)
    return Promise.resolve(new Response("Not found", { status: 404 }))
  }

  return req
    .text()
    .then((bodyText) => {
      log("INFO", `Received webhook request`)

      // Get signature
      const signature = req.headers.get("x-hub-signature-256") || ""

      // Verify signature
      if (!signature) {
        log("WARNING", "No signature header found")
        return new Response("No signature provided", { status: 403 })
      }

      if (!verifySignature(bodyText, signature)) {
        log("WARNING", "Invalid signature received")
        return new Response("Invalid signature", { status: 403 })
      }

      // Parse payload
      let payload: GitHubPayload
      try {
        payload = JSON.parse(bodyText) as GitHubPayload
      } catch (error) {
        log("ERROR", `Invalid JSON payload: ${String(error)}`)
        return new Response("Invalid JSON", { status: 400 })
      }

      // Extract branch from ref
      const ref: string = payload.ref || ""
      const branch: string = ref.replace("refs/heads/", "")
      const validBranches: readonly string[] = ["main", "dev"]

      log("INFO", `Webhook for branch: ${branch}`)

      // Only process valid branches
      if (!validBranches.includes(branch)) {
        log("INFO", `Ignored branch: ${branch}`)
        return new Response("Ignored branch", { status: 200 })
      }

      // Determine environment based on branch
      const environment: string = branch === "main" ? "production" : "development"

      // Extract changed files and detect components
      const commits: readonly GitHubCommit[] = Array.isArray(payload.commits) ? payload.commits : []
      const changedFiles = extractChangedFiles(commits)

      // Detect components
      const components = extractComponents(changedFiles)

      log("INFO", `Changed files: ${changedFiles.length}, Detected components: ${components.join(", ")}`)

      // Skip deployment if no components changed
      if (components.length === 0) {
        log("INFO", "No components changed")
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
      log("ERROR", `Unhandled error: ${String(error)}`)
      return new Response(`Server error: ${String(error)}`, { status: 500 })
    })
}

// Start the server
try {
  // Check if another instance is already running
  if (checkLock()) {
    log("WARNING", "Another instance is already running, exiting")
    process.exit(0)
  }

  // Start the server
  serve({
    port: PORT,
    hostname: "127.0.0.1",
    fetch: handleWebhook,
  })

} catch (error) {
  log("ERROR", `Failed to start server: ${String(error)}`)
}
