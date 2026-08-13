import { BadRequestException, ConflictException, Injectable, NotFoundException } from '@nestjs/common';
import { randomUUID } from 'node:crypto';
import type { AuthContext } from '../auth/auth.types.js';
import { PrismaService } from '../database/prisma.service.js';
import { AssetState } from '../generated/prisma/enums.js';
import type { PrepareAssetDto } from './assets.dto.js';
import { ObjectStorage } from './object-storage.js';

@Injectable()
export class AssetsService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly storage: ObjectStorage,
  ) {}

  async prepare(auth: AuthContext, dto: PrepareAssetDto) {
    const byTag = await this.prisma.assetObject.findUnique({
      where: { ownerId_dedupeTag: { ownerId: auth.ownerId, dedupeTag: dto.dedupeTag } },
    });
    if (byTag) {
      return {
        assetId: byTag.id,
        deduplicated: true,
        state: byTag.state,
        upload: byTag.state === AssetState.PREPARED
          ? await this.storage.prepareUpload(byTag.objectKey, Number(byTag.byteSize))
          : null,
      };
    }

    const byId = await this.prisma.assetObject.findUnique({ where: { id: dto.assetId } });
    if (byId) throw new ConflictException('Asset ID is already registered');

    const objectKey = `${auth.ownerId}/${randomUUID()}.epistoria`;
    const asset = await this.prisma.assetObject.create({
      data: {
        id: dto.assetId,
        ownerId: auth.ownerId,
        dedupeTag: dto.dedupeTag,
        objectKey,
        byteSize: BigInt(dto.encryptedByteSize),
      },
    });
    return {
      assetId: asset.id,
      deduplicated: false,
      state: asset.state,
      upload: await this.storage.prepareUpload(objectKey, dto.encryptedByteSize),
    };
  }

  async confirm(auth: AuthContext, assetId: string, encryptedByteSize: number) {
    const asset = await this.findOwned(auth, assetId);
    if (asset.byteSize !== BigInt(encryptedByteSize)) {
      throw new BadRequestException('Confirmed size differs from prepared size');
    }
    const actual = await this.storage.size(asset.objectKey);
    if (actual === null) throw new ConflictException('Encrypted object is not available yet');
    if (BigInt(actual) !== asset.byteSize) {
      throw new ConflictException('Encrypted object size does not match prepared metadata');
    }
    const availableAt = asset.availableAt ?? new Date();
    await this.prisma.assetObject.update({
      where: { id: asset.id },
      data: { state: AssetState.AVAILABLE, availableAt },
    });
    return { assetId: asset.id, state: AssetState.AVAILABLE, availableAt: availableAt.toISOString() };
  }

  async download(auth: AuthContext, assetId: string) {
    const asset = await this.findOwned(auth, assetId);
    if (asset.state !== AssetState.AVAILABLE) {
      throw new ConflictException('Asset upload has not been confirmed');
    }
    return {
      assetId,
      encryptedByteSize: asset.byteSize.toString(),
      ...(await this.storage.prepareDownload(asset.objectKey)),
    };
  }

  async status(auth: AuthContext, assetId: string) {
    const asset = await this.findOwned(auth, assetId);
    return {
      assetId: asset.id,
      state: asset.state,
      encryptedByteSize: asset.byteSize.toString(),
      availableAt: asset.availableAt?.toISOString() ?? null,
    };
  }

  private async findOwned(auth: AuthContext, assetId: string) {
    const asset = await this.prisma.assetObject.findFirst({
      where: { id: assetId, ownerId: auth.ownerId },
    });
    if (!asset) throw new NotFoundException('Asset not found');
    return asset;
  }
}

