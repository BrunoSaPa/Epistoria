import { describe, expect, it } from 'vitest';
import { decodeBase64Url, encodeBase64Url } from './base64url.js';

describe('base64url', () => {
  it('round trips canonical unpadded values', () => {
    const bytes = Uint8Array.from([0, 1, 2, 250, 255]);
    expect(decodeBase64Url(encodeBase64Url(bytes), 'value', 5)).toEqual(bytes);
  });

  it('rejects padded and oversized values', () => {
    expect(() => decodeBase64Url('AQ==', 'value', 10)).toThrow(/unpadded/);
    expect(() => decodeBase64Url('AQI', 'value', 1)).toThrow(/exceeds/);
  });
});

