import 'reflect-metadata';

import { randomBytes, randomUUID } from 'node:crypto';
import type { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import request from 'supertest';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { PrismaService as PrismaServiceType } from '../src/database/prisma.service.js';

const bootstrapSecret = 'integration-bootstrap-secret-value-32';
const tokenPepper = 'integration-token-pepper-value-32-bytes';
const syntheticPlaintextCanary = 'EPISTORIA_SYNTHETIC_PLAINTEXT_CANARY_7E8D1D73';

function sealed(plaintextBytes: number): string {
  return randomBytes(plaintextBytes + 40).toString('base64url');
}

function envelope(payloadSize = 8) {
  return {
    cryptoVersion: 1,
    contentVersion: 1,
    sealedDek: sealed(32),
    sealedContent: sealed(payloadSize),
    payloadSize,
  };
}

describe('Epistoria API vertical boundary', () => {
  let app: INestApplication;
  let prisma: PrismaServiceType;
  let ownerId: string;
  let ipadId: string;
  let ipadToken: string;

  beforeAll(async () => {
    Object.assign(process.env, {
      NODE_ENV: 'test',
      DATABASE_URL:
        process.env.EPISTORIA_TEST_DATABASE_URL ??
        'postgresql://epistoria_test:epistoria-test-isolated@localhost:55433/epistoria_test?schema=public',
      BOOTSTRAP_SECRET: bootstrapSecret,
      TOKEN_PEPPER: tokenPepper,
      S3_ENDPOINT: 'http://localhost:9000',
      S3_REGION: 'us-east-1',
      S3_BUCKET: process.env.EPISTORIA_TEST_S3_BUCKET ?? 'epistoria-test-assets',
      S3_ACCESS_KEY_ID: 'epistoria',
      S3_SECRET_ACCESS_KEY: 'epistoria-local-secret',
      S3_FORCE_PATH_STYLE: 'true',
      S3_PRESIGN_TTL_SECONDS: '900',
    });
    const [{ AppModule, configureApplication }, { PrismaService }, environmentModule] =
      await Promise.all([
        import('../src/bootstrap.js'),
        import('../src/database/prisma.service.js'),
        import('../src/config/environment.js'),
      ]);
    environmentModule.resetEnvironmentForTests();
    const module = await Test.createTestingModule({ imports: [AppModule] }).compile();
    app = module.createNestApplication({ bodyParser: false });
    await configureApplication(app);
    await app.init();
    prisma = app.get(PrismaService);

    await prisma.aIJob.deleteMany();
    await prisma.assetObject.deleteMany();
    await prisma.conflictCandidate.deleteMany();
    await prisma.mutationReceipt.deleteMany();
    await prisma.changeLog.deleteMany();
    await prisma.entityEnvelope.deleteMany();
    await prisma.device.deleteMany();
    await prisma.user.deleteMany();

    ownerId = randomUUID();
    ipadId = randomUUID();
  });

  afterAll(async () => {
    await app?.close();
  });

  it('exposes public liveness and protects owner bootstrap', async () => {
    await request(app.getHttpServer()).get('/v1/health').expect(200).expect(({ body }) => {
      expect(body.status).toBe('ok');
    });
    await request(app.getHttpServer())
      .post('/v1/auth/bootstrap')
      .set('x-bootstrap-secret', 'incorrect')
      .send({ ownerId, deviceId: ipadId, kind: 'IPAD' })
      .expect(403);

    const response = await request(app.getHttpServer())
      .post('/v1/auth/bootstrap')
      .set('x-bootstrap-secret', bootstrapSecret)
      .send({ ownerId, deviceId: ipadId, kind: 'IPAD' })
      .expect(201);
    ipadToken = response.body.token as string;
    expect(ipadToken.length).toBeGreaterThan(32);

    const restoredIpadId = randomUUID();
    const restored = await request(app.getHttpServer())
      .post('/v1/auth/bootstrap')
      .set('x-bootstrap-secret', bootstrapSecret)
      .send({ ownerId, deviceId: restoredIpadId, kind: 'IPAD' })
      .expect(201);
    const firstRestoredToken = restored.body.token as string;

    const retried = await request(app.getHttpServer())
      .post('/v1/auth/bootstrap')
      .set('x-bootstrap-secret', bootstrapSecret)
      .send({ ownerId, deviceId: restoredIpadId, kind: 'IPAD' })
      .expect(201);
    expect(retried.body.token).not.toBe(firstRestoredToken);
    await request(app.getHttpServer())
      .get('/v1/auth/me')
      .set('authorization', `Bearer ${firstRestoredToken}`)
      .expect(401);
    await request(app.getHttpServer())
      .get('/v1/auth/me')
      .set('authorization', `Bearer ${retried.body.token as string}`)
      .expect(200);

    await request(app.getHttpServer())
      .post('/v1/auth/bootstrap')
      .set('x-bootstrap-secret', bootstrapSecret)
      .send({ ownerId: randomUUID(), deviceId: randomUUID(), kind: 'IPAD' })
      .expect(409);
  });

  it('accepts idempotent mutations, orders pull, and retains conflicts', async () => {
    const entityId = randomUUID();
    const mutationId = randomUUID();
    const initial = {
      wireVersion: 1,
      deviceId: ipadId,
      mutations: [
        {
          mutationId,
          entityId,
          entityType: 'NOTE',
          operation: 'UPSERT',
          baseRevision: 0,
          relationIds: [],
          clientModifiedAt: new Date().toISOString(),
          envelope: envelope(),
        },
      ],
    };
    // The server boundary must only receive the sealed wire representation. The
    // companion storage/log scan verifies this synthetic plaintext never persists.
    expect(JSON.stringify(initial)).not.toContain(syntheticPlaintextCanary);

    const first = await request(app.getHttpServer())
      .post('/v1/sync/push')
      .set('authorization', `Bearer ${ipadToken}`)
      .send(initial)
      .expect(201);
    expect(first.body.results[0]).toMatchObject({ status: 'ACCEPTED', revision: 1 });

    const repeated = await request(app.getHttpServer())
      .post('/v1/sync/push')
      .set('authorization', `Bearer ${ipadToken}`)
      .send(initial)
      .expect(201);
    expect(repeated.body.results[0].sequence).toBe(first.body.results[0].sequence);
    expect(await prisma.changeLog.count()).toBe(1);

    const stale = structuredClone(initial);
    stale.mutations[0]!.mutationId = randomUUID();
    stale.mutations[0]!.envelope = envelope(11);
    const conflict = await request(app.getHttpServer())
      .post('/v1/sync/push')
      .set('authorization', `Bearer ${ipadToken}`)
      .send(stale)
      .expect(201);
    expect(conflict.body.results[0]).toMatchObject({ status: 'CONFLICT', revision: null });
    expect(conflict.body.results[0].conflictId).toBeTruthy();

    const conflicts = await request(app.getHttpServer())
      .get('/v1/sync/conflicts')
      .set('authorization', `Bearer ${ipadToken}`)
      .expect(200);
    expect(conflicts.body.conflicts).toHaveLength(1);
    expect(conflicts.body.conflicts[0].envelope.sealedContent).toBe(
      stale.mutations[0]!.envelope.sealedContent,
    );

    const update = structuredClone(initial);
    update.mutations[0]!.mutationId = randomUUID();
    update.mutations[0]!.baseRevision = 1;
    update.mutations[0]!.envelope = envelope(12);
    await request(app.getHttpServer())
      .post('/v1/sync/push')
      .set('authorization', `Bearer ${ipadToken}`)
      .send(update)
      .expect(201)
      .expect(({ body }) => expect(body.results[0]).toMatchObject({ status: 'ACCEPTED', revision: 2 }));

    const pull = await request(app.getHttpServer())
      .get('/v1/sync/pull?after=0&limit=100')
      .set('authorization', `Bearer ${ipadToken}`)
      .expect(200);
    expect(pull.body.changes.map((change: { revision: number }) => change.revision)).toEqual([1, 2]);
    expect(pull.body.latestSequence).toBe(pull.body.nextSequence);
  });

  it('deduplicates and confirms private encrypted objects', async () => {
    const assetId = randomUUID();
    const bytes = randomBytes(256);
    const dedupeTag = randomBytes(32).toString('hex');
    const prepared = await request(app.getHttpServer())
      .post('/v1/assets/prepare')
      .set('authorization', `Bearer ${ipadToken}`)
      .send({ assetId, dedupeTag, encryptedByteSize: bytes.length })
      .expect(201);

    const upload = await fetch(prepared.body.upload.url as string, {
      method: 'PUT',
      headers: prepared.body.upload.headers as Record<string, string>,
      body: bytes,
    });
    expect(upload.ok).toBe(true);

    await request(app.getHttpServer())
      .post(`/v1/assets/${assetId}/confirm`)
      .set('authorization', `Bearer ${ipadToken}`)
      .send({ encryptedByteSize: bytes.length })
      .expect(201)
      .expect(({ body }) => expect(body.state).toBe('AVAILABLE'));

    const duplicate = await request(app.getHttpServer())
      .post('/v1/assets/prepare')
      .set('authorization', `Bearer ${ipadToken}`)
      .send({ assetId: randomUUID(), dedupeTag, encryptedByteSize: bytes.length })
      .expect(201);
    expect(duplicate.body).toMatchObject({ assetId, deduplicated: true, upload: null });

    const download = await request(app.getHttpServer())
      .get(`/v1/assets/${assetId}/download`)
      .set('authorization', `Bearer ${ipadToken}`)
      .expect(200);
    const downloaded = Buffer.from(await (await fetch(download.body.url as string)).arrayBuffer());
    expect(downloaded).toEqual(bytes);
  });

  it('leases opaque AI work only to a paired Mac and requires a synced artifact', async () => {
    const jobId = randomUUID();
    await request(app.getHttpServer())
      .post('/v1/ai-jobs')
      .set('authorization', `Bearer ${ipadToken}`)
      .send({
        jobId,
        jobType: 'SESSION_DIGEST',
        cryptoVersion: 1,
        contentVersion: 1,
        sealedDek: sealed(32),
        sealedPayload: sealed(20),
        payloadSize: 20,
      })
      .expect(201);

    await request(app.getHttpServer())
      .post('/v1/ai-jobs/claim')
      .set('authorization', `Bearer ${ipadToken}`)
      .send({ leaseSeconds: 120 })
      .expect(403);

    const macId = randomUUID();
    const enrolled = await request(app.getHttpServer())
      .post('/v1/auth/devices')
      .set('authorization', `Bearer ${ipadToken}`)
      .send({ deviceId: macId, kind: 'MAC' })
      .expect(201);
    const macToken = enrolled.body.token as string;

    const claim = await request(app.getHttpServer())
      .post('/v1/ai-jobs/claim')
      .set('authorization', `Bearer ${macToken}`)
      .send({ leaseSeconds: 120 })
      .expect(200);
    expect(claim.body.job).toMatchObject({ id: jobId, jobType: 'SESSION_DIGEST', attempts: 1 });

    const artifactEntityId = randomUUID();
    await request(app.getHttpServer())
      .post('/v1/sync/push')
      .set('authorization', `Bearer ${macToken}`)
      .send({
        wireVersion: 1,
        deviceId: macId,
        mutations: [
          {
            mutationId: randomUUID(),
            entityId: artifactEntityId,
            entityType: 'AI_ARTIFACT',
            operation: 'UPSERT',
            baseRevision: 0,
            relationIds: [],
            clientModifiedAt: new Date().toISOString(),
            envelope: envelope(30),
          },
        ],
      })
      .expect(201);

    await request(app.getHttpServer())
      .post(`/v1/ai-jobs/${jobId}/complete`)
      .set('authorization', `Bearer ${macToken}`)
      .send({ artifactEntityId })
      .expect(200)
      .expect(({ body }) => expect(body).toMatchObject({ status: 'COMPLETE', artifactEntityId }));

    const devices = await request(app.getHttpServer())
      .get('/v1/auth/devices')
      .set('authorization', `Bearer ${ipadToken}`)
      .expect(200);
    expect(devices.body).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ id: ipadId, kind: 'IPAD', revokedAt: null }),
        expect.objectContaining({ id: macId, kind: 'MAC', revokedAt: null }),
      ]),
    );

    await request(app.getHttpServer())
      .delete(`/v1/auth/devices/${ipadId}`)
      .set('authorization', `Bearer ${ipadToken}`)
      .expect(409);
    await request(app.getHttpServer())
      .delete(`/v1/auth/devices/${macId}`)
      .set('authorization', `Bearer ${ipadToken}`)
      .expect(204);
    await request(app.getHttpServer())
      .get('/v1/auth/me')
      .set('authorization', `Bearer ${macToken}`)
      .expect(401);

    const afterRevocation = await request(app.getHttpServer())
      .get('/v1/auth/devices')
      .set('authorization', `Bearer ${ipadToken}`)
      .expect(200);
    expect(
      afterRevocation.body.find((device: { id: string }) => device.id === macId)?.revokedAt,
    ).toBeTruthy();
  });
});
