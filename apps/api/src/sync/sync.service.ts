import { BadRequestException, Injectable, NotFoundException } from '@nestjs/common';
import { decodeBase64Url, encodeBase64Url } from '../common/base64url.js';
import { parseDate } from '../common/time.js';
import { PrismaService } from '../database/prisma.service.js';
import { Prisma } from '../generated/prisma/client.js';
import { MutationOperation, MutationStatus } from '../generated/prisma/enums.js';
import type { AuthContext } from '../auth/auth.types.js';
import { decideMutation } from './sync-decision.js';
import type { SyncMutationDto, SyncPushDto, WireChange } from './sync.dto.js';

export interface MutationResult {
  mutationId: string;
  entityId: string;
  status: MutationStatus;
  revision: number | null;
  sequence: string | null;
  conflictId: string | null;
}

interface PreparedMutation {
  dto: SyncMutationDto;
  sealedDek: Uint8Array<ArrayBuffer>;
  sealedContent: Uint8Array<ArrayBuffer>;
  clientModifiedAt: Date;
}

@Injectable()
export class SyncService {
  constructor(private readonly prisma: PrismaService) {}

  async push(auth: AuthContext, dto: SyncPushDto) {
    if (auth.deviceId !== dto.deviceId) {
      throw new BadRequestException('deviceId must match the authenticated device');
    }

    const prepared = dto.mutations.map((mutation) => this.prepare(mutation));
    const total = prepared.reduce(
      (sum, mutation) => sum + mutation.sealedDek.byteLength + mutation.sealedContent.byteLength,
      0,
    );
    if (total > 8 * 1024 * 1024) throw new BadRequestException('Push batch exceeds 8 MiB');

    const results: MutationResult[] = [];
    for (const mutation of prepared) {
      results.push(await this.applyWithRetry(auth, mutation));
    }
    const latest = await this.latestSequence(auth.ownerId);
    return { wireVersion: 1, results, serverSequence: latest.toString() };
  }

  async pull(auth: AuthContext, after: bigint, limit: number) {
    const changes = await this.prisma.changeLog.findMany({
      where: { ownerId: auth.ownerId, sequence: { gt: after } },
      orderBy: { sequence: 'asc' },
      take: limit + 1,
    });
    const hasMore = changes.length > limit;
    const page = hasMore ? changes.slice(0, limit) : changes;
    const latest = await this.latestSequence(auth.ownerId);
    return {
      wireVersion: 1,
      changes: page.map((change): WireChange => ({
        sequence: change.sequence.toString(),
        mutationId: change.mutationId,
        entityId: change.entityId,
        entityType: change.entityType,
        operation: change.operation,
        revision: change.revision,
        parentId: change.parentId,
        relationIds: change.relationIds,
        clientModifiedAt: change.clientModifiedAt.toISOString(),
        changedAt: change.changedAt.toISOString(),
        envelope: {
          cryptoVersion: change.cryptoVersion,
          contentVersion: change.contentVersion,
          sealedDek: encodeBase64Url(change.sealedDek),
          sealedContent: encodeBase64Url(change.sealedContent),
          dedupeTag: change.dedupeTag,
          payloadSize: change.payloadSize,
        },
      })),
      nextSequence: (page.at(-1)?.sequence ?? after).toString(),
      latestSequence: latest.toString(),
      hasMore,
    };
  }

  async conflicts(auth: AuthContext) {
    const conflicts = await this.prisma.conflictCandidate.findMany({
      where: { ownerId: auth.ownerId, resolvedAt: null },
      orderBy: { createdAt: 'asc' },
    });
    return {
      conflicts: conflicts.map((conflict) => ({
        id: conflict.id,
        mutationId: conflict.mutationId,
        entityId: conflict.entityId,
        entityType: conflict.entityType,
        operation: conflict.operation,
        baseRevision: conflict.baseRevision,
        currentRevision: conflict.currentRevision,
        parentId: conflict.parentId,
        relationIds: conflict.relationIds,
        clientModifiedAt: conflict.clientModifiedAt.toISOString(),
        createdAt: conflict.createdAt.toISOString(),
        envelope: {
          cryptoVersion: conflict.cryptoVersion,
          contentVersion: conflict.contentVersion,
          sealedDek: encodeBase64Url(conflict.sealedDek),
          sealedContent: encodeBase64Url(conflict.sealedContent),
          dedupeTag: conflict.dedupeTag,
          payloadSize: conflict.payloadSize,
        },
      })),
    };
  }

  async resolveConflict(auth: AuthContext, conflictId: string, replacementEntityId: string) {
    const conflict = await this.prisma.conflictCandidate.findFirst({
      where: { id: conflictId, ownerId: auth.ownerId },
    });
    if (!conflict) throw new NotFoundException('Conflict not found');
    if (conflict.resolvedAt) return { resolvedAt: conflict.resolvedAt.toISOString() };

    const replacement = await this.prisma.entityEnvelope.findFirst({
      where: { id: replacementEntityId, ownerId: auth.ownerId, tombstone: false },
    });
    if (!replacement) {
      throw new BadRequestException('Replacement conflict-copy entity must be synchronized first');
    }
    const resolved = await this.prisma.conflictCandidate.update({
      where: { id: conflictId },
      data: { resolvedAt: new Date() },
    });
    return { resolvedAt: resolved.resolvedAt!.toISOString() };
  }

  private prepare(dto: SyncMutationDto): PreparedMutation {
    const sealedDek = decodeBase64Url(dto.envelope.sealedDek, 'sealedDek', 128);
    const sealedContent = decodeBase64Url(
      dto.envelope.sealedContent,
      'sealedContent',
      2 * 1024 * 1024 + 40,
    );
    if (sealedDek.byteLength !== 72) {
      throw new BadRequestException('sealedDek must contain a sealed 32-byte key');
    }
    if (sealedContent.byteLength !== dto.envelope.payloadSize + 40) {
      throw new BadRequestException('payloadSize does not match sealedContent');
    }
    return { dto, sealedDek, sealedContent, clientModifiedAt: parseDate(dto.clientModifiedAt, 'clientModifiedAt') };
  }

  private async applyWithRetry(auth: AuthContext, mutation: PreparedMutation): Promise<MutationResult> {
    for (let attempt = 0; attempt < 4; attempt += 1) {
      try {
        return await this.prisma.$transaction(
          (tx) => this.apply(tx, auth, mutation),
          { isolationLevel: 'Serializable' },
        );
      } catch (error) {
        const retryable =
          error instanceof Prisma.PrismaClientKnownRequestError &&
          (error.code === 'P2034' || error.code === 'P2002');
        if (!retryable || attempt === 3) throw error;
      }
    }
    throw new Error('Unreachable transaction retry state');
  }

  private async apply(
    tx: Prisma.TransactionClient,
    auth: AuthContext,
    prepared: PreparedMutation,
  ): Promise<MutationResult> {
    const dto = prepared.dto;
    const prior = await tx.mutationReceipt.findUnique({
      where: { ownerId_mutationId: { ownerId: auth.ownerId, mutationId: dto.mutationId } },
    });
    if (prior) return this.receiptResult(prior);

    const current = await tx.entityEnvelope.findUnique({ where: { id: dto.entityId } });
    if (current && current.ownerId !== auth.ownerId) {
      // Do not reveal whether another account owns a guessed UUID.
      return this.createConflict(tx, auth, prepared, 0);
    }
    const decision = decideMutation(current?.revision ?? null, dto.baseRevision);
    if (decision.kind === 'conflict') {
      return this.createConflict(tx, auth, prepared, decision.currentRevision);
    }

    const envelopeData = {
      ownerId: auth.ownerId,
      entityType: dto.entityType,
      parentId: dto.parentId ?? null,
      relationIds: dto.relationIds,
      revision: decision.revision,
      tombstone: dto.operation === MutationOperation.DELETE,
      cryptoVersion: dto.envelope.cryptoVersion,
      contentVersion: dto.envelope.contentVersion,
      sealedDek: prepared.sealedDek,
      sealedContent: prepared.sealedContent,
      dedupeTag: dto.envelope.dedupeTag ?? null,
      payloadSize: dto.envelope.payloadSize,
      clientModifiedAt: prepared.clientModifiedAt,
    };

    if (current) {
      await tx.entityEnvelope.update({ where: { id: dto.entityId }, data: envelopeData });
    } else {
      await tx.entityEnvelope.create({ data: { id: dto.entityId, ...envelopeData } });
    }

    const change = await tx.changeLog.create({
      data: {
        ownerId: auth.ownerId,
        deviceId: auth.deviceId,
        mutationId: dto.mutationId,
        entityId: dto.entityId,
        entityType: dto.entityType,
        operation: dto.operation,
        revision: decision.revision,
        parentId: dto.parentId ?? null,
        relationIds: dto.relationIds,
        cryptoVersion: dto.envelope.cryptoVersion,
        contentVersion: dto.envelope.contentVersion,
        sealedDek: prepared.sealedDek,
        sealedContent: prepared.sealedContent,
        dedupeTag: dto.envelope.dedupeTag ?? null,
        payloadSize: dto.envelope.payloadSize,
        clientModifiedAt: prepared.clientModifiedAt,
      },
    });
    const receipt = await tx.mutationReceipt.create({
      data: {
        ownerId: auth.ownerId,
        deviceId: auth.deviceId,
        mutationId: dto.mutationId,
        entityId: dto.entityId,
        status: MutationStatus.ACCEPTED,
        revision: decision.revision,
        sequence: change.sequence,
      },
    });
    return this.receiptResult(receipt);
  }

  private async createConflict(
    tx: Prisma.TransactionClient,
    auth: AuthContext,
    prepared: PreparedMutation,
    currentRevision: number,
  ): Promise<MutationResult> {
    const dto = prepared.dto;
    const conflict = await tx.conflictCandidate.create({
      data: {
        ownerId: auth.ownerId,
        deviceId: auth.deviceId,
        mutationId: dto.mutationId,
        entityId: dto.entityId,
        entityType: dto.entityType,
        operation: dto.operation,
        baseRevision: dto.baseRevision,
        currentRevision,
        parentId: dto.parentId ?? null,
        relationIds: dto.relationIds,
        cryptoVersion: dto.envelope.cryptoVersion,
        contentVersion: dto.envelope.contentVersion,
        sealedDek: prepared.sealedDek,
        sealedContent: prepared.sealedContent,
        dedupeTag: dto.envelope.dedupeTag ?? null,
        payloadSize: dto.envelope.payloadSize,
        clientModifiedAt: prepared.clientModifiedAt,
      },
    });
    const receipt = await tx.mutationReceipt.create({
      data: {
        ownerId: auth.ownerId,
        deviceId: auth.deviceId,
        mutationId: dto.mutationId,
        entityId: dto.entityId,
        status: MutationStatus.CONFLICT,
        conflictId: conflict.id,
      },
    });
    return this.receiptResult(receipt);
  }

  private receiptResult(receipt: {
    mutationId: string;
    entityId: string;
    status: MutationStatus;
    revision: number | null;
    sequence: bigint | null;
    conflictId: string | null;
  }): MutationResult {
    return {
      mutationId: receipt.mutationId,
      entityId: receipt.entityId,
      status: receipt.status,
      revision: receipt.revision,
      sequence: receipt.sequence?.toString() ?? null,
      conflictId: receipt.conflictId,
    };
  }

  private async latestSequence(ownerId: string): Promise<bigint> {
    const result = await this.prisma.changeLog.aggregate({
      where: { ownerId },
      _max: { sequence: true },
    });
    return result._max.sequence ?? 0n;
  }
}
