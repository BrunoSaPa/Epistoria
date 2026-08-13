import {
  BadRequestException,
  ConflictException,
  ForbiddenException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import type { AuthContext } from '../auth/auth.types.js';
import { decodeBase64Url, encodeBase64Url } from '../common/base64url.js';
import { PrismaService } from '../database/prisma.service.js';
import { Prisma } from '../generated/prisma/client.js';
import { AIJobStatus, DeviceKind, EntityType } from '../generated/prisma/enums.js';
import type { CreateAIJobDto } from './ai-jobs.dto.js';

@Injectable()
export class AIJobsService {
  constructor(private readonly prisma: PrismaService) {}

  async create(auth: AuthContext, dto: CreateAIJobDto) {
    const sealedDek = decodeBase64Url(dto.sealedDek, 'sealedDek', 128);
    const sealedPayload = decodeBase64Url(dto.sealedPayload, 'sealedPayload', 1_048_576 + 40);
    if (sealedDek.byteLength !== 72) {
      throw new BadRequestException('sealedDek must contain a sealed 32-byte key');
    }
    if (sealedPayload.byteLength !== dto.payloadSize + 40) {
      throw new BadRequestException('payloadSize does not match sealedPayload');
    }
    const existing = await this.prisma.aIJob.findUnique({ where: { id: dto.jobId } });
    if (existing) {
      if (existing.ownerId !== auth.ownerId) throw new ConflictException('Job ID is unavailable');
      return this.summary(existing);
    }
    const job = await this.prisma.aIJob.create({
      data: {
        id: dto.jobId,
        ownerId: auth.ownerId,
        requestedByDeviceId: auth.deviceId,
        jobType: dto.jobType,
        cryptoVersion: dto.cryptoVersion,
        contentVersion: dto.contentVersion,
        sealedDek,
        sealedPayload,
        payloadSize: dto.payloadSize,
      },
    });
    return this.summary(job);
  }

  async claim(auth: AuthContext, leaseSeconds = 120) {
    if (auth.deviceKind !== DeviceKind.MAC) {
      throw new ForbiddenException('Only a paired Mac worker can claim processing jobs');
    }
    const now = new Date();
    const expires = new Date(now.valueOf() + leaseSeconds * 1000);

    for (let attempt = 0; attempt < 4; attempt += 1) {
      try {
        return await this.prisma.$transaction(
          async (tx) => {
            const job = await tx.aIJob.findFirst({
              where: {
                ownerId: auth.ownerId,
                OR: [
                  { status: AIJobStatus.PENDING },
                  { status: AIJobStatus.LEASED, leaseExpiresAt: { lt: now } },
                ],
              },
              orderBy: { createdAt: 'asc' },
            });
            if (!job) return { job: null };
            const leased = await tx.aIJob.update({
              where: { id: job.id },
              data: {
                status: AIJobStatus.LEASED,
                leasedByDeviceId: auth.deviceId,
                leaseExpiresAt: expires,
                attempts: { increment: 1 },
                errorCode: null,
              },
            });
            return { job: this.wireJob(leased) };
          },
          { isolationLevel: 'Serializable' },
        );
      } catch (error) {
        const retryable = error instanceof Prisma.PrismaClientKnownRequestError && error.code === 'P2034';
        if (!retryable || attempt === 3) throw error;
      }
    }
    throw new Error('Unreachable transaction retry state');
  }

  async complete(auth: AuthContext, jobId: string, artifactEntityId: string) {
    const job = await this.leasedBy(auth, jobId);
    const artifact = await this.prisma.entityEnvelope.findFirst({
      where: {
        id: artifactEntityId,
        ownerId: auth.ownerId,
        entityType: EntityType.AI_ARTIFACT,
        tombstone: false,
      },
    });
    if (!artifact) {
      throw new BadRequestException('Synchronize the encrypted AI artifact before completing its job');
    }
    const completedAt = new Date();
    const completed = await this.prisma.aIJob.update({
      where: { id: job.id },
      data: {
        status: AIJobStatus.COMPLETE,
        artifactEntityId,
        completedAt,
        leaseExpiresAt: null,
      },
    });
    return this.summary(completed);
  }

  async fail(auth: AuthContext, jobId: string, errorCode: string, retryable: boolean) {
    const job = await this.leasedBy(auth, jobId);
    const willRetry = retryable && job.attempts < 5;
    const updated = await this.prisma.aIJob.update({
      where: { id: job.id },
      data: {
        status: willRetry ? AIJobStatus.PENDING : AIJobStatus.FAILED,
        errorCode,
        leasedByDeviceId: null,
        leaseExpiresAt: null,
        completedAt: willRetry ? null : new Date(),
      },
    });
    return this.summary(updated);
  }

  async cancel(auth: AuthContext, jobId: string) {
    const job = await this.prisma.aIJob.findFirst({ where: { id: jobId, ownerId: auth.ownerId } });
    if (!job) throw new NotFoundException('AI job not found');
    if (job.status === AIJobStatus.COMPLETE || job.status === AIJobStatus.FAILED) {
      throw new ConflictException('A terminal job cannot be cancelled');
    }
    return this.summary(
      await this.prisma.aIJob.update({
        where: { id: job.id },
        data: {
          status: AIJobStatus.CANCELLED,
          leasedByDeviceId: null,
          leaseExpiresAt: null,
          completedAt: new Date(),
        },
      }),
    );
  }

  async get(auth: AuthContext, jobId: string) {
    const job = await this.prisma.aIJob.findFirst({ where: { id: jobId, ownerId: auth.ownerId } });
    if (!job) throw new NotFoundException('AI job not found');
    return this.summary(job);
  }

  private async leasedBy(auth: AuthContext, jobId: string) {
    if (auth.deviceKind !== DeviceKind.MAC) throw new ForbiddenException('Mac worker required');
    const job = await this.prisma.aIJob.findFirst({ where: { id: jobId, ownerId: auth.ownerId } });
    if (!job) throw new NotFoundException('AI job not found');
    if (job.status !== AIJobStatus.LEASED || job.leasedByDeviceId !== auth.deviceId) {
      throw new ConflictException('Job is not leased by this worker');
    }
    if (!job.leaseExpiresAt || job.leaseExpiresAt < new Date()) {
      throw new ConflictException('Job lease has expired');
    }
    return job;
  }

  private wireJob(job: {
    id: string;
    jobType: string;
    cryptoVersion: number;
    contentVersion: number;
    sealedDek: Uint8Array;
    sealedPayload: Uint8Array;
    payloadSize: number;
    attempts: number;
    leaseExpiresAt: Date | null;
  }) {
    return {
      id: job.id,
      jobType: job.jobType,
      cryptoVersion: job.cryptoVersion,
      contentVersion: job.contentVersion,
      sealedDek: encodeBase64Url(job.sealedDek),
      sealedPayload: encodeBase64Url(job.sealedPayload),
      payloadSize: job.payloadSize,
      attempts: job.attempts,
      leaseExpiresAt: job.leaseExpiresAt?.toISOString() ?? null,
    };
  }

  private summary(job: {
    id: string;
    jobType: string;
    status: string;
    attempts: number;
    artifactEntityId: string | null;
    errorCode: string | null;
    createdAt: Date;
    updatedAt: Date;
    completedAt: Date | null;
  }) {
    return {
      id: job.id,
      jobType: job.jobType,
      status: job.status,
      attempts: job.attempts,
      artifactEntityId: job.artifactEntityId,
      errorCode: job.errorCode,
      createdAt: job.createdAt.toISOString(),
      updatedAt: job.updatedAt.toISOString(),
      completedAt: job.completedAt?.toISOString() ?? null,
    };
  }
}
