import {
  ConflictException,
  ForbiddenException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import { createHmac, randomBytes, timingSafeEqual } from 'node:crypto';
import { decodeBase64Url } from '../common/base64url.js';
import { environment } from '../config/environment.js';
import { PrismaService } from '../database/prisma.service.js';
import type { AuthContext } from './auth.types.js';
import type { BootstrapDto, DeviceTokenResponseDto, EnrollDeviceDto } from './auth.dto.js';

@Injectable()
export class AuthService {
  constructor(private readonly prisma: PrismaService) {}

  hashToken(token: string): string {
    return createHmac('sha256', environment().tokenPepper).update(token, 'utf8').digest('hex');
  }

  isBootstrapSecretValid(candidate: string | undefined): boolean {
    if (!candidate) return false;
    const expected = Buffer.from(environment().bootstrapSecret, 'utf8');
    const actual = Buffer.from(candidate, 'utf8');
    return actual.length === expected.length && timingSafeEqual(actual, expected);
  }

  async authenticate(token: string): Promise<AuthContext | null> {
    if (token.length < 32 || token.length > 256) return null;
    const device = await this.prisma.device.findUnique({ where: { tokenHash: this.hashToken(token) } });
    if (!device || device.revokedAt) return null;

    void this.prisma.device
      .update({ where: { id: device.id }, data: { lastSeenAt: new Date() } })
      .catch(() => undefined);

    return { ownerId: device.ownerId, deviceId: device.id, deviceKind: device.kind };
  }

  async bootstrap(secret: string | undefined, dto: BootstrapDto): Promise<DeviceTokenResponseDto> {
    if (!this.isBootstrapSecretValid(secret)) throw new ForbiddenException('Invalid bootstrap secret');

    return this.prisma.$transaction(async (tx) => {
      // Serialize the single-owner decision. Without a transaction-scoped lock, two first-run
      // requests could both observe an empty table and create different owners.
      await tx.$executeRaw`SELECT pg_advisory_xact_lock(1162898516)`;
      const owners = await tx.user.findMany({ select: { id: true }, take: 2 });
      if (owners.length === 0) {
        await tx.user.create({ data: { id: dto.ownerId } });
      } else if (owners.length !== 1 || owners[0]?.id !== dto.ownerId) {
        throw new ConflictException('This server belongs to another owner');
      }

      // A valid administrative bootstrap secret may attach a restored primary iPad to the
      // same personal account. Repeating the same request rotates that device token so a
      // network interruption cannot strand the app after the server committed its first call.
      return this.createOrRotateBootstrapDevice(tx, dto.ownerId, dto);
    });
  }

  async enroll(auth: AuthContext, dto: EnrollDeviceDto): Promise<DeviceTokenResponseDto> {
    const existing = await this.prisma.device.findUnique({ where: { id: dto.deviceId } });
    if (existing) throw new ConflictException('Device ID is already registered');
    return this.createDevice(this.prisma, auth.ownerId, dto);
  }

  async revoke(auth: AuthContext, deviceId: string): Promise<void> {
    if (deviceId === auth.deviceId) {
      throw new ConflictException('Enroll another device before revoking the current device');
    }
    const result = await this.prisma.device.updateMany({
      where: { id: deviceId, ownerId: auth.ownerId, revokedAt: null },
      data: { revokedAt: new Date() },
    });
    if (result.count === 0) throw new NotFoundException('Device not found');
  }

  async list(auth: AuthContext) {
    const devices = await this.prisma.device.findMany({
      where: { ownerId: auth.ownerId },
      orderBy: { createdAt: 'asc' },
      select: {
        id: true,
        kind: true,
        displayNameSealed: true,
        createdAt: true,
        lastSeenAt: true,
        revokedAt: true,
      },
    });
    return devices.map((device) => ({
      ...device,
      displayNameSealed: device.displayNameSealed
        ? Buffer.from(device.displayNameSealed).toString('base64url')
        : null,
    }));
  }

  private async createDevice(
    tx: Pick<PrismaService, 'device'>,
    ownerId: string,
    dto: EnrollDeviceDto,
  ): Promise<DeviceTokenResponseDto> {
    const token = randomBytes(32).toString('base64url');
    await tx.device.create({
      data: {
        id: dto.deviceId,
        ownerId,
        kind: dto.kind,
        tokenHash: this.hashToken(token),
        displayNameSealed: dto.displayNameSealed
          ? decodeBase64Url(dto.displayNameSealed, 'displayNameSealed', 768)
          : undefined,
      },
    });
    return { ownerId, deviceId: dto.deviceId, token };
  }

  private async createOrRotateBootstrapDevice(
    tx: Pick<PrismaService, 'device'>,
    ownerId: string,
    dto: EnrollDeviceDto,
  ): Promise<DeviceTokenResponseDto> {
    const existing = await tx.device.findUnique({ where: { id: dto.deviceId } });
    if (existing && (existing.ownerId !== ownerId || existing.kind !== dto.kind)) {
      throw new ConflictException('Device ID is already registered');
    }
    const token = randomBytes(32).toString('base64url');
    const deviceData = {
      tokenHash: this.hashToken(token),
      displayNameSealed: dto.displayNameSealed
        ? decodeBase64Url(dto.displayNameSealed, 'displayNameSealed', 768)
        : null,
      revokedAt: null,
      lastSeenAt: new Date(),
    };
    if (existing) {
      await tx.device.update({ where: { id: dto.deviceId }, data: deviceData });
    } else {
      await tx.device.create({
        data: {
          id: dto.deviceId,
          ownerId,
          kind: dto.kind,
          ...deviceData,
        },
      });
    }
    return { ownerId, deviceId: dto.deviceId, token };
  }
}
