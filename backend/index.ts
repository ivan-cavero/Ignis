import { Hono } from 'hono'

const app = new Hono()

app.get('/', (c) => {
  return c.text('🔥 Hello from Ignis Bun Backend!')
})

Bun.serve({
  port: 3000,
  fetch: app.fetch,
})
