/**
 * Ignis Deployment Webhook Server
 *
 * This server listens for GitHub webhook events and triggers deployments
 * based on component changes. It supports multiple environments and provides
 * detailed logging with a functional approach.
 */
import { createHmac, timingSafeEqual } from "crypto"
import { existsSync, mkdirSync, appendFileSync } from "fs"
import { join } from "path"
import { exec } from "child_process"

// Configuration constants
const CONFIG = {
  PORT: 3333,
  WEBHOOK_PATH: "/webhook",
  ENV_FILE: ".env",
  LOGS_DIR: join(process.cwd(), "logs/webhook"),
  PROJECT_ROOT: process.cwd(),
}

// Ensure logs directory exists
if (!existsSync(CONFIG.LOGS_DIR)) {
  mkdirSync(CONFIG.LOGS_DIR, { recursive: true })
}

/**
 * Pure function to create a logger with consistent formatting
 * @returns Object with logging functions
 */
const createLogger = () => ({
  info: (message) => console.log(`[INFO] ${message}`),
  success: (message) => console.log(`[SUCCESS] ${message}`),
  warn: (message) => console.warn(`[WARNING] ${message}`),
  error: (message) => console.error(`[ERROR] ${message}`),

  // Pure function to log to file with timestamp
  logToFile: (message, level = "INFO") => {
    const timestamp = new Date().toISOString()
    const logFile = join(CONFIG.LOGS_DIR, `webhook-${new Date().toISOString().split("T")[0]}.log`)
    const logMessage = `[${timestamp}] [${level}] ${message}\n`

    appendFileSync(logFile, logMessage)
    return message
  },
})

const logger = createLogger()

/**
 * Pure function to verify the GitHub webhook signature against the request body
 * @param body - The raw request body
 * @param signature - The signature from GitHub
 * @returns Boolean indicating if signature is valid
 */
const verifySignature = (body, signature) => {
  const secret = process.env.WEBHOOK_SECRET ?? ""

  if (!secret) {
    logger.error("WEBHOOK_SECRET environment variable is not set")
    logger.logToFile("WEBHOOK_SECRET environment variable is not set", "ERROR")
    return false
  }

  const hmac = createHmac("sha256", secret)
  const digest = "sha256=" + hmac.update(body).digest("hex")

  try {
    return timingSafeEqual(Buffer.from(digest), Buffer.from(signature))
  } catch (error) {
    logger.error(`Signature verification error: ${error}`)
    logger.logToFile(`Signature verification error: ${error}`, "ERROR")
    return false
  }
}

/**
 * Pure function to create a response object
 * @param message - Response message
 * @param status - HTTP status code
 * @returns Response object
 */
const createResponse = (message, status) => new Response(message, { status })

/**
 * Pure function to determine which components have changed based on modified files
 * @param files - Array of modified file paths
 * @returns Array of component names that have changed
 */
const getChangedComponents = (files) => {
  const componentPaths = {
    backend: ["backend/"],
    "admin-frontend": ["frontend/admin/"],
    "user-frontend": ["frontend/user/"],
    "landing-frontend": ["frontend/landing/"],
    proxy: ["proxy/"],
    infrastructure: ["docker-compose.yml", "deployments/"],
  }

  return Object.entries(componentPaths)
    .filter(([_, paths]) => paths.some((path) => files.some((file) => file.startsWith(path))))
    .map(([component]) => component)
}

/**
 * Pure function to execute a shell command
 * @param command - Command to execute
 * @returns Promise that resolves when command completes
 */
const executeCommand = (command) => 
  new Promise((resolve, reject) => {
    exec(command, (error, stdout, stderr) => {
      if (error) {
        logger.error(`Command execution error: ${error.message}`)
        logger.logToFile(`Command execution error: ${error.message}`, "ERROR")
        reject(error)
        return
      }
      
      if (stderr) {
        logger.warn(`Command stderr: ${stderr}`)
        logger.logToFile(`Command stderr: ${stderr}`, "WARNING")
      }
      
      logger.info(`Command stdout: ${stdout}`)
      logger.logToFile(`Command stdout: ${stdout}`, "INFO")
      resolve(stdout)
    })
  })

/**
 * Pure function to deploy a component
 * @param component - Component name to deploy
 * @param environment - Environment to deploy to
 * @param branch - Git branch to deploy
 * @returns Promise that resolves when deployment completes
 */
const deployComponent = (component, environment, branch) => {
  const command = `cd ${CONFIG.PROJECT_ROOT} && bash deployments/scripts/deploy-infrastructure.sh --component=${component} --environment=${environment} --branch=${branch}`
  logger.info(`Executing: ${command}`)
  return executeCommand(command)
}

/**
 * Handles webhook requests by validating and triggering deployments
 * @param req - Request object
 * @returns Response object
 */
const handleWebhook = async (req) => {
  const url = new URL(req.url)

  // Early return for invalid requests
  if (req.method !== "POST" || url.pathname !== CONFIG.WEBHOOK_PATH) {
    return createResponse("Not found", 404)
  }

  const body = await req.text()
  const signature = req.headers.get("x-hub-signature-256") ?? ""

  // Validate signature
  if (!signature || !verifySignature(body, signature)) {
    logger.warn("Invalid signature received")
    logger.logToFile("Invalid signature received", "WARNING")
    return createResponse("Invalid signature", 401)
  }

  try {
    // Parse the webhook payload
    const payload = JSON.parse(body)
    const event = req.headers.get("x-github-event") ?? "unknown"

    // Only process push events
    if (event !== "push") {
      logger.info(`Ignoring non-push event: ${event}`)
      logger.logToFile(`Ignoring non-push event: ${event}`, "INFO")
      return createResponse(`Event type ${event} ignored`, 200)
    }

    // Extract repository and branch information
    const repo = payload.repository?.name ?? "unknown"
    const branch = payload.ref?.replace("refs/heads/", "") ?? "unknown"
    const files = payload.commits?.flatMap((commit) => [
      ...(commit.added || []),
      ...(commit.modified || []),
      ...(commit.removed || []),
    ]) || []

    // Determine environment based on branch
    const environment = branch === "main" ? "production" : branch === "dev" ? "development" : null

    if (!environment) {
      logger.info(`Ignoring push to branch ${branch}`)
      logger.logToFile(`Ignoring push to branch ${branch}`, "INFO")
      return createResponse(`Branch ${branch} is not configured for deployment`, 200)
    }

    // Determine which components have changed
    const changedComponents = getChangedComponents(files)

    if (changedComponents.length === 0) {
      logger.info(`No deployable components changed in this push`)
      logger.logToFile(`No deployable components changed in this push to ${branch}`, "INFO")
      return createResponse("No deployable components changed", 200)
    }

    logger.success(`Valid webhook received for ${repo}/${branch}`)
    logger.info(`Changed components: ${changedComponents.join(", ")}`)
    logger.logToFile(`Deploying components ${changedComponents.join(", ")} to ${environment}`, "INFO")

    // Deploy each changed component using Promise.all for parallel execution
    Promise.all(
      changedComponents.map((component) => 
        deployComponent(component, environment, branch)
      )
    ).catch((error) => {
      logger.error(`Deployment error: ${error}`)
      logger.logToFile(`Deployment error: ${error}`, "ERROR")
    })

    return createResponse(`Deployment triggered for ${changedComponents.join(", ")} in ${environment} environment`, 200)
  } catch (error) {
    logger.error(`Error processing webhook: ${error}`)
    logger.logToFile(`Error processing webhook: ${error}`, "ERROR")
    return createResponse("Error processing webhook", 500)
  }
}

/**
 * Pure function to validate if required environment variables exist
 * @returns Boolean indicating if all requirements are met
 */
const validateRequirements = () => {
  const checks = [
    { condition: !!process.env.WEBHOOK_SECRET, message: "WEBHOOK_SECRET environment variable" }
  ]

  const failedChecks = checks.filter((check) => !check.condition)

  if (failedChecks.length > 0) {
    logger.error("Missing requirements:")
    failedChecks.forEach((check) => logger.error(`   - ${check.message}`))
    return false
  }

  return true
}

/**
 * Starts the webhook server
 */
const startServer = async () => {
  if (!validateRequirements()) {
    logger.error("Server startup aborted due to missing requirements")
    process.exit(1)
  }

  try {
    // Dynamically import Bun
    const { default: Bun } = await import("bun")

    const serverConfig = {
      hostname: "0.0.0.0",
      port: CONFIG.PORT,
      fetch: handleWebhook,
    }

    Bun.serve(serverConfig)

    logger.success(`Webhook server running at http://0.0.0.0:${CONFIG.PORT}${CONFIG.WEBHOOK_PATH}`)
    logger.logToFile(`Webhook server started on port ${CONFIG.PORT}`, "INFO")
  } catch (error) {
    logger.error(`Failed to start server: ${error}`)
    process.exit(1)
  }
}

// Start the server
startServer().catch((error) => {
  logger.error(`Unhandled error: ${error}`)
  process.exit(1)
})
