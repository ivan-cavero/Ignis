/**
 * GitHub webhook server for Ignis deployment automation
 * Listens for GitHub push events and triggers component-specific deployments
 * Implements intelligent component detection for minimal downtime
 *
 * @author v0
 * @version 4.0.0
 * @license MIT
 */

import { serve } from "bun"
import { spawnSync } from "child_process"
import crypto from "crypto"
import fs from "fs"

// === CONFIGURATION ===

// Environment variables with defaults
const WEBHOOK_SECRET: string = process.env.WEBHOOK_SECRET || ""
const DEPLOY_SCRIPT: string = process.env.DEPLOY_SCRIPT || "/opt/ignis/deployments/scripts/deploy.sh"
const LOG_DIR: string = process.env.LOG_DIR || "/opt/ignis/logs/webhook"
const PORT: number = Number.parseInt(process.env.WEBHOOK_PORT || "3333", 10)
const HOST: string = process.env.WEBHOOK_HOST || "0.0.0.0" // Listen on all interfaces
const PROJECT_ROOT: string = process.env.PROJECT_ROOT || "/opt/ignis"
const LOCK_FILE: string = process.env.LOCK_FILE || "/tmp/ignis-webhook.lock"
const DEPLOYMENT_TIMEOUT: number = Number.parseInt(process.env.DEPLOYMENT_TIMEOUT || "600", 10) // 10 minutes

// Valid branches and environments
const VALID_BRANCHES: readonly string[] = ["main", "dev", "staging"]
const BRANCH_TO_ENV: Record<string, string> = {
  main: "production",
  dev: "development",
  staging: "staging",
}

// === TYPES ===

/**
 * Type for GitHub commit structure
 */
type GitHubCommit = {
  readonly id: string
  readonly message: string
  readonly timestamp: string
  readonly author?: {
    readonly name: string
    readonly email: string
  }
  readonly added?: readonly string[]
  readonly modified?: readonly string[]
  readonly removed?: readonly string[]
}

/**
 * Type for GitHub webhook payload
 */
type GitHubPayload = {
  readonly ref?: string
  readonly repository?: {
    readonly name: string
    readonly full_name: string
  }
  readonly commits?: readonly GitHubCommit[]
  readonly head_commit?: GitHubCommit
  readonly pusher?: {
    readonly name: string
    readonly email: string
  }
}

/**
 * Type for deployment result
 */
type DeploymentResult = {
  readonly component: string
  readonly success: boolean
  readonly message: string
  readonly duration: number
}

/**
 * Type for component mapping
 */
type ComponentMapping = {
  readonly pattern: string
  readonly component: string
  readonly priority: number
  readonly dependencies?: readonly string[]
}

// === COMPONENT MAPPING ===

/**
 * Component mapping with patterns, priorities and dependencies
 * Higher priority components are deployed first
 * Dependencies are deployed if the component changes
 */
const COMPONENT_MAPPINGS: readonly ComponentMapping[] = [
  // Infrastructure components (highest priority)
  { pattern: "docker-compose", component: "infrastructure", priority: 100 },
  { pattern: "deployments/scripts/", component: "infrastructure", priority: 90 },
  { pattern: "proxy/", component: "proxy", priority: 80, dependencies: ["infrastructure"] },

  // Service components
  { pattern: "deployments/service/", component: "services", priority: 70 },
  { pattern: "deployments/webhook/", component: "services", priority: 65 },

  // Backend components
  { pattern: "backend/", component: "backend", priority: 60 },
  { pattern: "backend/api/", component: "backend", priority: 60 },
  { pattern: "backend/services/", component: "backend", priority: 60 },
  { pattern: "backend/models/", component: "backend", priority: 60 },

  // Frontend components
  { pattern: "frontend/user/", component: "user-frontend", priority: 50 },
  { pattern: "frontend/admin/", component: "admin-frontend", priority: 50 },
  { pattern: "frontend/landing/", component: "landing-frontend", priority: 50 },

  // Shared components
  { pattern: "shared/", component: "backend", priority: 40, dependencies: ["user-frontend", "admin-frontend"] },

  // Configuration files
  { pattern: ".env", component: "infrastructure", priority: 30 },
  { pattern: "config/", component: "infrastructure", priority: 30 },

  // Documentation (lowest priority)
  { pattern: "docs/", component: "none", priority: 10 },
  { pattern: "README.md", component: "none", priority: 10 },
]

// === UTILITY FUNCTIONS ===

/**
 * Creates a formatted timestamp for file names
 * @returns {string} Timestamp in YYYYMMDD format
 */
const getDateString = (): string => {
  const now = new Date()
  const year = now.getFullYear()
  const month = String(now.getMonth() + 1).padStart(2, "0")
  const day = String(now.getDate()).padStart(2, "0")
  return `${year}${month}${day}`
}

/**
 * Ensures a directory exists without mutation
 * @param {string} directory - Directory path to ensure
 * @returns {Promise<string>} The directory path
 */
const ensureDirectory = (directory: string): Promise<string> =>
  new Promise((resolve, reject) => {
    fs.stat(directory, (err) => {
      if (err) {
        if (err.code === "ENOENT") {
          fs.mkdir(directory, { recursive: true }, (mkdirErr) => {
            if (mkdirErr) {
              reject(mkdirErr)
            } else {
              resolve(directory)
            }
          })
        } else {
          reject(err)
        }
      } else {
        resolve(directory)
      }
    })
  })

// Initialize log file
const LOG_FILE: string = `${LOG_DIR}/webhook-${getDateString()}.log`

// Create log directory if it doesn't exist
ensureDirectory(LOG_DIR).catch((error) => {
  console.error(`Failed to create log directory: ${String(error)}`)
})

/**
 * Formats a log message with timestamp and level
 * @param {string} level - Log level
 * @param {string} message - Message to log
 * @returns {string} Formatted log message
 */
const formatLogMessage = (level: string, message: string): string => {
  const timestamp = new Date().toISOString()
  return `[${timestamp}] [${level}] ${message}\n`
}

/**
 * Logs a message to console and file
 * @param {string} level - Log level
 * @param {string} message - Message to log
 */
const log = (level: string, message: string): void => {
  const formattedMessage = formatLogMessage(level, message)

  // Log to console
  console.log(formattedMessage.trim())

  // Log to file
  fs.appendFile(LOG_FILE, formattedMessage, (err) => {
    if (err) {
      console.error(`Failed to write to log file: ${String(err)}`)
    }
  })
}

/**
 * Checks if another instance of the webhook server is running
 * @returns {boolean} Whether another instance is running
 */
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
 * Extracts components affected by changed files
 * @param {string[]} files - List of changed files
 * @returns {string[]} List of affected components with dependencies
 */
const extractComponents = (files: readonly string[]): string[] => {
  if (!files.length) {
    return []
  }

  // Create a set to track unique components
  const componentsSet = new Set<string>()

  // Create a set to track dependencies that need to be added
  const dependenciesToAdd = new Set<string>()

  // Process each file
  files.forEach((file) => {
    // Find matching component mappings
    const matchingMappings = COMPONENT_MAPPINGS.filter((mapping) => file.startsWith(mapping.pattern))

    // Add components from matching mappings
    matchingMappings.forEach((mapping) => {
      if (mapping.component !== "none") {
        componentsSet.add(mapping.component)

        // Add dependencies if specified
        if (mapping.dependencies) {
          mapping.dependencies.forEach((dep) => dependenciesToAdd.add(dep))
        }
      }
    })
  })

  // Add all dependencies
  dependenciesToAdd.forEach((dep) => componentsSet.add(dep))

  // Convert set to array
  const components = Array.from(componentsSet)

  // Sort components by priority
  return components.sort((a, b) => {
    const mappingA = COMPONENT_MAPPINGS.find((m) => m.component === a)
    const mappingB = COMPONENT_MAPPINGS.find((m) => m.component === b)

    const priorityA = mappingA ? mappingA.priority : 0
    const priorityB = mappingB ? mappingB.priority : 0

    return priorityB - priorityA // Higher priority first
  })
}

/**
 * Deploys a component using the deploy script
 * @param {string} component - Component to deploy
 * @param {string} environment - Deployment environment
 * @param {string} branch - Git branch
 * @returns {DeploymentResult} Deployment result
 */
const deployComponent = (component: string, environment: string, branch: string): DeploymentResult => {
  log("INFO", `Deploying component: ${component} (${environment} environment, ${branch} branch)`)

  const startTime = Date.now()

  // Build command arguments
  const args = [DEPLOY_SCRIPT, `--component=${component}`, `--environment=${environment}`, `--branch=${branch}`, '--pull']

  // Execute deployment with timeout
  const result = spawnSync("bash", args, {
    cwd: PROJECT_ROOT,
    env: process.env,
    encoding: "utf-8",
    timeout: DEPLOYMENT_TIMEOUT * 1000, // Convert to milliseconds
  })

  const duration = (Date.now() - startTime) / 1000 // Convert to seconds

  // Check for timeout
  if (result.error && result.error.name === "ETIMEDOUT") {
    log("ERROR", `Deployment of ${component} timed out after ${DEPLOYMENT_TIMEOUT} seconds`)
    return {
      component,
      success: false,
      message: `Deployment timed out after ${DEPLOYMENT_TIMEOUT} seconds`,
      duration,
    }
  }

  // Check for success
  if (result.status === 0) {
    log("SUCCESS", `Deployment of ${component} completed in ${duration.toFixed(2)} seconds`)
    return {
      component,
      success: true,
      message: `Deployment completed in ${duration.toFixed(2)} seconds`,
      duration,
    }
  } else {
    log("ERROR", `Deployment of ${component} failed: ${result.stderr}`)
    return {
      component,
      success: false,
      message: result.stderr || `Exit code: ${result.status}`,
      duration,
    }
  }
}

// === HANDLERS ===

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
      version: "4.0.0",
    }),
    {
      headers: {
        "Content-Type": "application/json",
      },
    },
  )
}

/**
 * Handles the GitHub webhook request
 * @param {Request} req - HTTP request
 * @returns {Promise<Response>} HTTP response
 */
const handleWebhook = async (req: Request): Promise<Response> => {
  const url = new URL(req.url)

  log("INFO", `Received request to ${url.pathname} with method ${req.method}`)

  // Health check endpoint
  if (req.method === "GET" && (url.pathname === "/health" || url.pathname === "/healthz")) {
    return handleHealthCheck()
  }

  // Root path handler for GitHub webhook
  if (req.method === "POST" && (url.pathname === "/" || url.pathname === "/webhook")) {
    try {
      const bodyText = await req.text()
      log("INFO", `Received webhook request to ${url.pathname}`)

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

      // Extract repository information
      const repoName = payload.repository?.name || "unknown"
      const repoFullName = payload.repository?.full_name || "unknown"
      log("INFO", `Repository: ${repoFullName}`)

      // Extract branch from ref
      const ref: string = payload.ref || ""
      const branch: string = ref.replace("refs/heads/", "")

      log("INFO", `Webhook for branch: ${branch}`)

      // Only process valid branches
      if (!VALID_BRANCHES.includes(branch)) {
        log("INFO", `Ignored branch: ${branch}`)
        return new Response("Ignored branch", { status: 200 })
      }

      // Determine environment based on branch
      const environment: string = BRANCH_TO_ENV[branch] || "development"

      // Extract pusher information
      const pusherName = payload.pusher?.name || "unknown"
      const pusherEmail = payload.pusher?.email || "unknown"
      log("INFO", `Push by: ${pusherName} <${pusherEmail}>`)

      // Extract changed files and detect components
      const commits: readonly GitHubCommit[] = Array.isArray(payload.commits) ? payload.commits : []

      // Log commit information
      if (commits.length > 0) {
        log("INFO", `Received ${commits.length} commits`)

        // Log first and last commit if available
        const firstCommit = commits[0]
        if (firstCommit) {
          log("INFO", `First commit: ${firstCommit.id.substring(0, 7)} - ${firstCommit.message.split("\n")[0]}`)
        }

        if (commits.length > 1) {
          const lastCommit = commits[commits.length - 1]
          if (lastCommit) {
            log("INFO", `Last commit: ${lastCommit.id.substring(0, 7)} - ${lastCommit.message.split("\n")[0]}`)
          }
        }
      } else {
        log("WARNING", "No commits found in payload")
      }

      // Extract changed files
      const changedFiles = extractChangedFiles(commits)

      // Log changed files if not too many
      if (changedFiles.length > 0 && changedFiles.length <= 10) {
        log("INFO", `Changed files: ${changedFiles.join(", ")}`)
      } else if (changedFiles.length > 10) {
        log("INFO", `Changed files: ${changedFiles.length} files`)
      } else {
        log("WARNING", "No changed files detected")
      }

      // Detect components
      const components = extractComponents(changedFiles)

      if (components.length > 0) {
        log("INFO", `Detected components to deploy: ${components.join(", ")}`)
      } else {
        log("INFO", "No components need to be deployed")
        return new Response("No deployment needed", { status: 200 })
      }

      // Deploy each component
      const deploymentResults: DeploymentResult[] = []

      for (const component of components) {
        const result = deployComponent(component, environment, branch)
        deploymentResults.push(result)

        // If infrastructure deployment fails, stop further deployments
        if (component === "infrastructure" && !result.success) {
          log("ERROR", "Infrastructure deployment failed, stopping further deployments")
          break
        }
      }

      // Check if all deployments were successful
      const allSuccessful = deploymentResults.every((result) => result.success)
      const successCount = deploymentResults.filter((result) => result.success).length
      const failureCount = deploymentResults.length - successCount

      // Create response summary
      const summary = {
        repository: repoFullName,
        branch,
        environment,
        components: deploymentResults.map((r) => r.component),
        results: {
          total: deploymentResults.length,
          successful: successCount,
          failed: failureCount,
        },
        details: deploymentResults,
      }

      if (allSuccessful) {
        log("SUCCESS", `All ${deploymentResults.length} components deployed successfully`)
        return new Response(JSON.stringify(summary), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        })
      } else {
        log("ERROR", `${failureCount} of ${deploymentResults.length} deployments failed`)
        return new Response(JSON.stringify(summary), {
          status: 500,
          headers: { "Content-Type": "application/json" },
        })
      }
    } catch (error) {
      log("ERROR", `Unhandled error: ${String(error)}`)
      return new Response(`Server error: ${String(error)}`, { status: 500 })
    }
  }

  // Default response for other paths
  return new Response("Not found", { status: 404 })
}

// === MAIN ===

// Start the server
try {
  // Check if another instance is already running
  if (checkLock()) {
    log("WARNING", "Another instance is already running, exiting")
    process.exit(0)
  }

  // Start the server
  const server = serve({
    port: PORT,
    hostname: HOST,
    fetch: handleWebhook,
  })

  log("INFO", `Webhook server started on ${HOST}:${PORT}`)

  // Log component mappings for debugging
  log("INFO", `Configured ${COMPONENT_MAPPINGS.length} component mappings`)

  // Register signal handlers for graceful shutdown
  process.on("SIGINT", () => {
    log("INFO", "Received SIGINT, shutting down")
    process.exit(0)
  })

  process.on("SIGTERM", () => {
    log("INFO", "Received SIGTERM, shutting down")
    process.exit(0)
  })
} catch (error) {
  log("ERROR", `Failed to start server: ${String(error)}`)
  process.exit(1)
}
