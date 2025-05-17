import { Context, Next } from 'hono';

export const logger = async (c: Context, next: Next) => {
  const start = Date.now();
  await next();
  const ms = Date.now() - start;
  console.log(`${c.req.method} ${c.req.path} - ${ms}ms`);
};

export const cors = async (c: Context, next: Next) => {
  // Ensure response headers exist
  if (!c.res.headers) {
    c.res = new Response();
  }
  
  // Set CORS headers
  const allowedOrigin = (c.env as any)?.ALLOWED_ORIGIN || '*';
  c.res.headers.set('Access-Control-Allow-Origin', allowedOrigin);
  c.res.headers.set('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS');
  c.res.headers.set('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  c.res.headers.set('Access-Control-Allow-Credentials', 'true');
  
  // Handle preflight requests
  if (c.req.method === 'OPTIONS') {
    return new Response(null, { 
      status: 204,
      headers: Object.fromEntries(c.res.headers.entries())
    });
  }
  
  await next();
};

export const errorHandler = async (c: Context, next: Next) => {
  try {
    await next();
  } catch (err) {
    console.error('Error:', err);
    return c.json({ 
      error: 'Internal Server Error',
      message: err instanceof Error ? err.message : 'An unknown error occurred'
    }, 500);
  }
};
