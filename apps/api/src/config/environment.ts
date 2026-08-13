import { Logger } from '@nestjs/common';

export interface Environment {
  nodeEnv: 'development' | 'test' | 'production';
  port: number;
  databaseUrl: string;
  bootstrapSecret: string;
  tokenPepper: string;
  s3: {
    endpoint?: string;
    region: string;
    bucket: string;
    accessKeyId: string;
    secretAccessKey: string;
    forcePathStyle: boolean;
    presignTtlSeconds: number;
  };
}

let cached: Environment | undefined;

function required(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

function integer(name: string, fallback: number, minimum: number, maximum: number): number {
  const raw = process.env[name];
  const value = raw === undefined ? fallback : Number.parseInt(raw, 10);
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
    throw new Error(`${name} must be an integer between ${minimum} and ${maximum}`);
  }
  return value;
}

function boolean(name: string, fallback: boolean): boolean {
  const raw = process.env[name];
  if (raw === undefined) return fallback;
  if (raw === 'true') return true;
  if (raw === 'false') return false;
  throw new Error(`${name} must be true or false`);
}

export function environment(): Environment {
  if (cached) return cached;

  const nodeEnv = (process.env.NODE_ENV ?? 'development') as Environment['nodeEnv'];
  if (!['development', 'test', 'production'].includes(nodeEnv)) {
    throw new Error('NODE_ENV must be development, test, or production');
  }

  const bootstrapSecret = required('BOOTSTRAP_SECRET');
  const tokenPepper = required('TOKEN_PEPPER');
  if (bootstrapSecret.length < 32 || tokenPepper.length < 32) {
    throw new Error('BOOTSTRAP_SECRET and TOKEN_PEPPER must each contain at least 32 characters');
  }

  if (nodeEnv === 'production' && bootstrapSecret.includes('replace-with')) {
    throw new Error('Refusing to start production with the example bootstrap secret');
  }

  cached = {
    nodeEnv,
    port: integer('API_PORT', 3000, 1, 65_535),
    databaseUrl: required('DATABASE_URL'),
    bootstrapSecret,
    tokenPepper,
    s3: {
      endpoint: process.env.S3_ENDPOINT || undefined,
      region: process.env.S3_REGION ?? 'auto',
      bucket: required('S3_BUCKET'),
      accessKeyId: required('S3_ACCESS_KEY_ID'),
      secretAccessKey: required('S3_SECRET_ACCESS_KEY'),
      forcePathStyle: boolean('S3_FORCE_PATH_STYLE', false),
      presignTtlSeconds: integer('S3_PRESIGN_TTL_SECONDS', 900, 60, 3600),
    },
  };

  Logger.log(`Configuration loaded for ${nodeEnv}`, 'Environment');
  return cached;
}

export function resetEnvironmentForTests(): void {
  cached = undefined;
}

