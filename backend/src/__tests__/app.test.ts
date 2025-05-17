import { describe, it, expect } from 'bun:test';
import app from '..';

describe('Application', () => {
  it('should return 200 for the root endpoint', async () => {
    const req = new Request('http://localhost/')
    const res = await app.fetch(req);
    expect(res.status).toBe(200);
  });

  it('should return 200 for the health check', async () => {
    const req = new Request('http://localhost/health')
    const res = await app.fetch(req);
    expect(res.status).toBe(200);
    
    const data = await res.json();
    expect(data.status).toBe('ok');
    expect(data.timestamp).toBeDefined();
  });

  it('should return 404 for unknown routes', async () => {
    const req = new Request('http://localhost/unknown-route')
    const res = await app.fetch(req);
    expect(res.status).toBe(404);
    
    const data = await res.json();
    expect(data.error).toBe('Not Found');
  });
});
