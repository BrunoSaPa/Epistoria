import { Type } from 'class-transformer';
import {
  ArrayMaxSize,
  ArrayUnique,
  IsArray,
  IsEnum,
  IsISO8601,
  IsInt,
  IsOptional,
  IsString,
  IsUUID,
  Matches,
  Max,
  MaxLength,
  Min,
  ValidateNested,
} from 'class-validator';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { EntityType, MutationOperation } from '../generated/prisma/enums.js';

export class EncryptedEnvelopeDto {
  @ApiProperty({ minimum: 1, maximum: 255 })
  @IsInt()
  @Min(1)
  @Max(255)
  cryptoVersion!: number;

  @ApiProperty({ minimum: 1, maximum: 65_535 })
  @IsInt()
  @Min(1)
  @Max(65_535)
  contentVersion!: number;

  @ApiProperty({ description: 'XChaCha20-Poly1305 sealed 32-byte DEK, unpadded base64url' })
  @IsString()
  @MaxLength(128)
  @Matches(/^[A-Za-z0-9_-]+$/)
  sealedDek!: string;

  @ApiProperty({ description: 'XChaCha20-Poly1305 content, unpadded base64url' })
  @IsString()
  @MaxLength(2_796_256)
  @Matches(/^[A-Za-z0-9_-]+$/)
  sealedContent!: string;

  @ApiPropertyOptional({ description: 'Opaque HMAC-SHA256 tag as lowercase hex' })
  @IsOptional()
  @Matches(/^[0-9a-f]{64}$/)
  dedupeTag?: string;

  @ApiProperty({ minimum: 0, maximum: 2_097_152 })
  @IsInt()
  @Min(0)
  @Max(2_097_152)
  payloadSize!: number;
}

export class SyncMutationDto {
  @ApiProperty({ format: 'uuid' })
  @IsUUID()
  mutationId!: string;

  @ApiProperty({ format: 'uuid' })
  @IsUUID()
  entityId!: string;

  @ApiProperty({ enum: EntityType })
  @IsEnum(EntityType)
  entityType!: EntityType;

  @ApiProperty({ enum: MutationOperation })
  @IsEnum(MutationOperation)
  operation!: MutationOperation;

  @ApiProperty({ minimum: 0 })
  @IsInt()
  @Min(0)
  baseRevision!: number;

  @ApiPropertyOptional({ format: 'uuid' })
  @IsOptional()
  @IsUUID()
  parentId?: string;

  @ApiProperty({ type: [String], maxItems: 64 })
  @IsArray()
  @ArrayMaxSize(64)
  @ArrayUnique()
  @IsUUID(undefined, { each: true })
  relationIds: string[] = [];

  @ApiProperty({ format: 'date-time' })
  @IsISO8601({ strict: true })
  clientModifiedAt!: string;

  @ApiProperty({ type: EncryptedEnvelopeDto })
  @ValidateNested()
  @Type(() => EncryptedEnvelopeDto)
  envelope!: EncryptedEnvelopeDto;
}

export class SyncPushDto {
  @ApiProperty({ enum: [1], example: 1 })
  @IsInt()
  @Min(1)
  @Max(1)
  wireVersion!: number;

  @ApiProperty({ format: 'uuid' })
  @IsUUID()
  deviceId!: string;

  @ApiProperty({ type: [SyncMutationDto], maxItems: 100 })
  @IsArray()
  @ArrayMaxSize(100)
  @ValidateNested({ each: true })
  @Type(() => SyncMutationDto)
  mutations!: SyncMutationDto[];
}

export class ResolveConflictDto {
  @ApiProperty({ format: 'uuid', description: 'The replacement conflict-copy entity' })
  @IsUUID()
  replacementEntityId!: string;
}

export interface WireEnvelope {
  cryptoVersion: number;
  contentVersion: number;
  sealedDek: string;
  sealedContent: string;
  dedupeTag: string | null;
  payloadSize: number;
}

export interface WireChange {
  sequence: string;
  mutationId: string;
  entityId: string;
  entityType: EntityType;
  operation: MutationOperation;
  revision: number;
  parentId: string | null;
  relationIds: string[];
  clientModifiedAt: string;
  changedAt: string;
  envelope: WireEnvelope;
}
