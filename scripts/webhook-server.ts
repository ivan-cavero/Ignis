import { createHmac, timingSafeEqual } from "crypto";
import { env } from "bun";
import { readFileSync } from "fs";

const secret = env.WEBHOOK_SECRET;

function verifySignature(body: string, signature: string): boolean {
  const hmac = createHmac("sha256", secret);
  const digest = "sha256=" + hmac.update(body).digest("hex");
  return timingSafeEqual(Buffer.from(digest), Buffer.from(signature));
}

const server = Bun.serve({
  port: 3333,
  tls: {
    cert: Bun.file("/etc/letsencrypt/live/vps.ivancavero.com/fullchain.pem"),
    key: Bun.file("/etc/letsencrypt/live/vps.ivancavero.com/privkey.pem"),
  },
  async fetch(req) {
    const url = new URL(req.url);
    if (req.method !== "POST" || url.pathname !== "/webhook") {
      return new Response("Not found", { status: 404 });
    }

    const body = await req.text();
    const sig = req.headers.get("x-hub-signature-256");
    if (!sig || !verifySignature(body, sig)) {
      console.warn("❌ Invalid signature");
      return new Response("Invalid signature", { status: 401 });
    }

    console.log("✅ Valid webhook received from GitHub");
    Bun.spawn(["bash", "./scripts/webhook-handler.sh"]);
    return new Response("OK\n");
  },
});

console.log(`🚀 Webhook server running at https://vps.ivancavero.com:3333/webhook`);
