const server = Bun.serve({
  port: 3333,
  fetch: async (req) => {
    if (req.method === "POST" && new URL(req.url).pathname === "/webhook") {
      console.log("📬 Webhook received from GitHub");
      const proc = Bun.spawn(["bash", "./scripts/webhook-handler.sh"]);
      const text = await new Response(proc.stdout).text();
      console.log(text);
      return new Response("✅ Webhook handled\n");
    }
    return new Response("Not found", { status: 404 });
  },
});

console.log(`🚀 Webhook server listening on http://localhost:${server.port}/webhook`);
