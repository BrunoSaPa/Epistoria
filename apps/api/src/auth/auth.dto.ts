import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { IsEnum, IsOptional, IsString, IsUUID, Matches, MaxLength } from 'class-validator';
import { DeviceKind } from '../generated/prisma/enums.js';

export class EnrollDeviceDto {
  @ApiProperty({ format: 'uuid' })
  @IsUUID()
  deviceId!: string;

  @ApiProperty({ enum: DeviceKind })
  @IsEnum(DeviceKind)
  kind!: DeviceKind;

  @ApiPropertyOptional({ description: 'Encrypted device display name, unpadded base64url' })
  @IsOptional()
  @IsString()
  @MaxLength(1024)
  @Matches(/^[A-Za-z0-9_-]+$/)
  displayNameSealed?: string;
}

export class BootstrapDto extends EnrollDeviceDto {
  @ApiProperty({ format: 'uuid', description: 'Account ID included in the recovery kit' })
  @IsUUID()
  ownerId!: string;
}

export class DeviceTokenResponseDto {
  @ApiProperty({ format: 'uuid' })
  ownerId!: string;

  @ApiProperty({ format: 'uuid' })
  deviceId!: string;

  @ApiProperty({ description: 'Shown once; store in Keychain' })
  token!: string;
}

