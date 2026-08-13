import { afterEach, describe, expect, it } from 'vitest';
import { environment, resetEnvironmentForTests } from './environment.js';

const original = { ...process.env };

afterEach(() => {
  process.env = { ...original };
  resetEnvironmentForTests();
});

describe('environment', () => {
  it('rejects placeholder-length secrets that are too short', () => {
    process.env.DATABASE_URL = 'postgresql://example';
    process.env.BOOTSTRAP_SECRET = 'short';
    process.env.TOKEN_PEPPER = 'also-short';
    process.env.S3_BUCKET = 'test';
    process.env.S3_ACCESS_KEY_ID = 'test';
    process.env.S3_SECRET_ACCESS_KEY = 'test';
    expect(() => environment()).toThrow(/at least 32/);
  });

  it('parses a complete local environment', () => {
    process.env.NODE_ENV = 'test';
    process.env.DATABASE_URL = 'postgresql://example';
    process.env.BOOTSTRAP_SECRET = 'b'.repeat(32);
    process.env.TOKEN_PEPPER = 'p'.repeat(32);
    process.env.S3_BUCKET = 'test';
    process.env.S3_ACCESS_KEY_ID = 'test';
    process.env.S3_SECRET_ACCESS_KEY = 'test';
    expect(environment().port).toBe(3000);
    expect(environment().s3.forcePathStyle).toBe(false);
  });
});

