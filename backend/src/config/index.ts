import { z } from 'zod';

// Define the shape of our environment variables
type Env = {
  NODE_ENV: 'development' | 'production' | 'test';
  PORT: string;
  HOST: string;
  [key: string]: string | undefined;
};

// Default environment variables
const defaultEnv: Partial<Env> = {
  NODE_ENV: 'development',
  PORT: '3000',
  HOST: '0.0.0.0',
};

// Merge defaults with process.env
const env: Env = {
  ...defaultEnv,
  ...process.env,
} as Env;

// Validate environment variables
const envSchema = z.object({
  NODE_ENV: z.enum(['development', 'production', 'test']).default('development'),
  PORT: z.string().default('3000'),
  HOST: z.string().default('0.0.0.0'),
});

const parsed = envSchema.safeParse(env);

if (!parsed.success) {
  console.error('❌ Invalid environment variables:', parsed.error.format());
  process.exit(1);
}

// Export the validated environment variables
export const config = {
  env: parsed.data.NODE_ENV,
  isProduction: parsed.data.NODE_ENV === 'production',
  isDevelopment: parsed.data.NODE_ENV === 'development',
  isTest: parsed.data.NODE_ENV === 'test',
  port: parseInt(parsed.data.PORT, 10),
  host: parsed.data.HOST,
} as const;
