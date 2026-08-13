import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import {
  IsBoolean,
  IsEnum,
  IsInt,
  IsOptional,
  IsString,
  IsUUID,
  Matches,
  Max,
  MaxLength,
  Min,
} from 'class-validator';
import { AIJobType } from '../generated/prisma/enums.js';

export class CreateAIJobDto {
  @ApiProperty({ format: 'uuid' })
  @IsUUID()
  jobId!: string;

  @ApiProperty({ enum: AIJobType })
  @IsEnum(AIJobType)
  jobType!: AIJobType;

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

  @ApiProperty()
  @Matches(/^[A-Za-z0-9_-]+$/)
  @MaxLength(128)
  sealedDek!: string;

  @ApiProperty()
  @Matches(/^[A-Za-z0-9_-]+$/)
  @MaxLength(1_398_208)
  sealedPayload!: string;

  @ApiProperty({ minimum: 1, maximum: 1_048_576 })
  @IsInt()
  @Min(1)
  @Max(1_048_576)
  payloadSize!: number;
}

export class ClaimAIJobDto {
  @ApiPropertyOptional({ default: 120, minimum: 30, maximum: 900 })
  @IsOptional()
  @IsInt()
  @Min(30)
  @Max(900)
  leaseSeconds?: number;
}

export class CompleteAIJobDto {
  @ApiProperty({ format: 'uuid' })
  @IsUUID()
  artifactEntityId!: string;
}

export class FailAIJobDto {
  @ApiProperty({ pattern: '^[A-Z0-9_]{1,64}$' })
  @IsString()
  @Matches(/^[A-Z0-9_]{1,64}$/)
  errorCode!: string;

  @ApiProperty({ default: true })
  @IsBoolean()
  retryable!: boolean;
}

