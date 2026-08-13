import type { DeviceKind } from '../generated/prisma/enums.js';

export interface AuthContext {
  ownerId: string;
  deviceId: string;
  deviceKind: DeviceKind;
}

