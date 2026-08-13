import { BadRequestException } from '@nestjs/common';

export function parseDate(value: string, field: string): Date {
  const parsed = new Date(value);
  if (Number.isNaN(parsed.valueOf())) {
    throw new BadRequestException(`${field} is not a valid timestamp`);
  }
  return parsed;
}

export function parseSequence(value: string | undefined): bigint {
  if (value === undefined) return 0n;
  if (!/^(0|[1-9][0-9]*)$/.test(value)) {
    throw new BadRequestException('after must be a non-negative decimal sequence');
  }
  return BigInt(value);
}

