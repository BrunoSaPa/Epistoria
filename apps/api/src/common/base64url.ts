import { BadRequestException } from '@nestjs/common';

const BASE64URL = /^[A-Za-z0-9_-]+$/;

export function decodeBase64Url(
  value: string,
  field: string,
  maxBytes: number,
): Uint8Array<ArrayBuffer> {
  if (!value || !BASE64URL.test(value) || value.includes('=')) {
    throw new BadRequestException(`${field} must be unpadded base64url`);
  }
  const decoded = Buffer.from(value, 'base64url');
  const bytes = Uint8Array.from(decoded);
  if (bytes.length > maxBytes) {
    throw new BadRequestException(`${field} exceeds ${maxBytes} bytes`);
  }
  if (Buffer.from(bytes).toString('base64url') !== value) {
    throw new BadRequestException(`${field} is not canonical base64url`);
  }
  return bytes;
}

export function encodeBase64Url(value: Uint8Array<ArrayBufferLike>): string {
  return Buffer.from(value).toString('base64url');
}
