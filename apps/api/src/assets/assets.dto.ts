import { ApiProperty } from '@nestjs/swagger';
import { IsInt, IsUUID, Matches, Max, Min } from 'class-validator';

export class PrepareAssetDto {
  @ApiProperty({ format: 'uuid' })
  @IsUUID()
  assetId!: string;

  @ApiProperty({ description: 'HMAC-SHA256(dedupeKey, SHA256(plaintext)), lowercase hex' })
  @Matches(/^[0-9a-f]{64}$/)
  dedupeTag!: string;

  @ApiProperty({ minimum: 1, maximum: 536_870_912 })
  @IsInt()
  @Min(1)
  @Max(536_870_912)
  encryptedByteSize!: number;
}

export class ConfirmAssetDto {
  @ApiProperty({ minimum: 1, maximum: 536_870_912 })
  @IsInt()
  @Min(1)
  @Max(536_870_912)
  encryptedByteSize!: number;
}

