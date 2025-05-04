/**
 * GitHub webhook server for automated deployments
 * Validates incoming webhooks and triggers deployment scripts
 * @module webhook-server
 */
import { createHmac, timingSafeEqual } from "crypto";
import { env } from "bun";

/**
 * Verifies the GitHub webhook signature against the request body
 * @param {string} body - The raw request body
 * @param {string} signature - The signature from GitHub (x-hub-signature-256 header)
 * @returns {boolean} Whether the signature is valid
 */
const verifySignature = (body: string, signature: string): boolean => {
  const secret = env.WEBHOOK_SECRET ?? "";
  const hmac = createHmac("sha256", secret);
  const digest = "sha256=" + hmac.update(body).digest("hex");
  return timingSafeEqual(Buffer.from(digest), Buffer.from(signature));
};

/**
 * Creates a response object with the given status and message
 * @param {string} message - Response message
 * @param {number} status - HTTP status code
 * @returns {Response} The HTTP response
 */
const createResponse = (message: string, status: number): Response => 
  new Response(message, { status });

/**
 * Handles webhook requests by validating and triggering deployments
 * @param {Request} req - The HTTP request object
 * @returns {Promise<Response>} The HTTP response
 */
const handleWebhook = async (req: Request): Promise<Response> => {
  const url = new URL(req.url);
  
  // Early return for invalid requests
  if (req.method !== "POST" || url.pathname !== "/webhook") {
    return createResponse("Not found", 404);
  }

  const body = await req.text();
  const signature = req.headers.get("x-hub-signature-256") ?? "";
  
  // Validate signature
  if (!signature || !verifySignature(body, signature)) {
    console.warn("❌ Invalid signature");
    return createResponse("Invalid signature", 401);
  }

  console.log("✅ Valid webhook received from GitHub");
  
  // Trigger deployment script
  Bun.spawn(["bash", "./scripts/webhook-handler.sh"]);
  return createResponse("OK\n", 200);
};

/**
 * Server configuration with TLS
 */
const serverConfig = {
  hostname: "0.0.0.0",
  port: 3333,
  tls: {
    cert: Bun.file("/home/ignis/Ignis/proxy/certs/vps.ivancavero.com.crt"),
    key: Bun.file("/home/ignis/Ignis/proxy/certs/vps.ivancavero.com.key"),
  },
  fetch: handleWebhook
};

Bun.serve(serverConfig);

console.log(`🚀 Webhook server running at https://vps.ivancavero.com:${serverConfig.port}/webhook`);