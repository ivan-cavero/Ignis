import { Hono } from 'hono';
import { cors, errorHandler, logger } from './middleware';
import { healthCheck } from './controllers/health.controller';
import { exampleRouter } from './routes';
import { config } from './config';

// Initialize the Hono app
const app = new Hono();

// Global middleware
app.use('*', logger);
app.use('*', cors);
app.use('*', errorHandler);

// Health check endpoint
app.get('/health', healthCheck);

// API routes
const api = new Hono();
api.route('/example', exampleRouter);

// Mount API routes
app.route('/api', api);

// Root endpoint
app.get('/', (c) => {
  return c.text('🔥 Ignis Backend is running!');
});

// Not found handler
app.notFound((c) => {
  return c.json({ error: 'Not Found' }, 404);
});

// Error handling
app.onError((err, c) => {
  console.error('Error:', err);
  return c.json(
    { 
      error: 'Internal Server Error',
      message: err.message 
    }, 
    500
  );
});

// Start the server
console.log(`🚀 Server running on http://${config.host}:${config.port}`);

// Export the app for testing
export default {
  port: config.port,
  fetch: app.fetch,
  config,
};

// Start the server if this file is run directly
if (import.meta.main) {
  Bun.serve({
    port: config.port,
    hostname: config.host,
    fetch: app.fetch,
  });
}
