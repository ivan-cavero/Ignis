/**
 * Ignis Deployment Webhook Server
 *
 * This server listens for GitHub webhook events and triggers selective deployments
 * based on which components have changed. It supports multiple environments (main/dev)
 * and provides detailed logging.
 */
import { createHmac, timingSafeEqual } from "crypto"
import { existsSync, mkdirSync, appendFileSync } from "fs"
import { join } from "path"
import { spawn } from "child_process"

// Configuration constants
const CONFIG = {
  PORT: 3333,
  WEBHOOK_PATH: "/webhook",
  ENV_FILE: ".env",
  CERT_DIR: join(import.meta.dir, "../../proxy/certs"),
  LOGS_DIR: join(import.meta.dir, "../../logs/webhook"),
  DEPLOYMENT_SCRIPT: join(import.meta.dir, "../scripts/deploy-component.sh"),
}

// Ensure logs directory exists
if (!existsSync(CONFIG.LOGS_DIR)) {
  mkdirSync(CONFIG.LOGS_DIR, { recursive: true })
}

/**
 * Logger utility for consistent log formatting
 */
const logger = {
  info: (message: string) => console.log(`[INFO] ${message}`),
  success: (message: string) => console.log(`[SUCCESS] ${message}`),
  warn: (message: string) => console.warn(`[WARNING] ${message}`),
  error: (message: string) => console.error(`[ERROR] ${message}`),

  // Log to file with timestamp
  logToFile: (message: string, level = "INFO") => {
    const timestamp = new Date().toISOString()
    const logFile = join(CONFIG.LOGS_DIR, `webhook-${new Date().toISOString().split("T")[0]}.log`)
    const logMessage = `[${timestamp}] [${level}] ${message}\n`

    appendFileSync(logFile, logMessage)
  },
}

/**
 * Verifies the GitHub webhook signature against the request body
 */
const verifySignature = (body: string, signature: string): boolean => {
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
 * Creates a response object with the given status and message
 */
const createResponse = (message: string, status: number): Response => new Response(message, { status })

/**
 * Determines which components have changed based on the modified files
 */
const getChangedComponents = (files: string[]): string[] => {
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
 * Handles webhook requests by validating and triggering deployments
 */
const handleWebhook = async (req: Request): Promise<Response> => {
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
    const files =
      payload.commits?.flatMap((commit: any) => [
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

    // Trigger deployment for each changed component
    changedComponents.forEach((component) => {
      spawn("bash", [CONFIG.DEPLOYMENT_SCRIPT, component, environment, branch], {
        stdio: "inherit",
        env: { ...process.env },
      })
    })

    return createResponse(`Deployment triggered for ${changedComponents.join(", ")} in ${environment} environment`, 200)
  } catch (error) {
    logger.error(`Error processing webhook: ${error}`)
    logger.logToFile(`Error processing webhook: ${error}`, "ERROR")
    return createResponse("Error processing webhook", 500)
  }
}

/**
 * Validates if the required environment variables and files exist
 */
const validateRequirements = (): boolean => {
  const checks = [{ condition: !!process.env.WEBHOOK_SECRET, message: "WEBHOOK_SECRET environment variable" }]

  // Check for TLS certificates
  const domains = ["vps.ivancavero.com", "api.ivancavero.com", "admin.ivancavero.com", "app.ivancavero.com"]

  domains.forEach((domain) => {
    const certPath = join(CONFIG.CERT_DIR, `${domain}.crt`)
    const keyPath = join(CONFIG.CERT_DIR, `${domain}.key`)

    if (existsSync(certPath) && existsSync(keyPath)) {
      // At least one domain has valid certificates
      checks.push({ condition: true, message: "TLS certificates" })
    }
  })

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
const startServer = (): void => {
  if (!validateRequirements()) {
    logger.error("Server startup aborted due to missing requirements")
    process.exit(1)
  }

  // Find available TLS certificates
  const domain = "vps.ivancavero.com"
  const certPath = join(CONFIG.CERT_DIR, `${domain}.crt`)
  const keyPath = join(CONFIG.CERT_DIR, `${domain}.key`)

  const serverConfig = {
    hostname: "0.0.0.0",
    port: CONFIG.PORT,
    tls:
      existsSync(certPath) && existsSync(keyPath)
        ? {
            cert: Bun.file(certPath),
            key: Bun.file(keyPath),
          }
        : undefined,
    fetch: handleWebhook,
  }

  // Bun.serve(serverConfig)
  import("bun").then((bun) => {
    bun.serve(serverConfig)
  })

  const protocol = serverConfig.tls ? "https" : "http"
  logger.success(`Webhook server running at ${protocol}://0.0.0.0:${CONFIG.PORT}${CONFIG.WEBHOOK_PATH}`)
  logger.logToFile(`Webhook server started on port ${CONFIG.PORT}`, "INFO")
}

// Start the server
startServer()
