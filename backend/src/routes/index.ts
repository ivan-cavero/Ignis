import { Hono } from 'hono';

// Initialize router
const router = new Hono();

// Example route
router.get('/example', (c) => {
  return c.json({ message: 'This is an example route' });
});

// Export the router
export { router as exampleRouter };
