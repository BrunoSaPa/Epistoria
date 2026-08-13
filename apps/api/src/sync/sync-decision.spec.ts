import { describe, expect, it } from 'vitest';
import { decideMutation } from './sync-decision.js';

describe('decideMutation', () => {
  it('accepts a new entity only from revision zero', () => {
    expect(decideMutation(null, 0)).toEqual({ kind: 'accept', revision: 1 });
    expect(decideMutation(null, 4)).toEqual({ kind: 'conflict', currentRevision: 0 });
  });

  it('increments an entity whose base revision matches', () => {
    expect(decideMutation(7, 7)).toEqual({ kind: 'accept', revision: 8 });
  });

  it('never silently overwrites a concurrent value', () => {
    expect(decideMutation(8, 7)).toEqual({ kind: 'conflict', currentRevision: 8 });
    expect(decideMutation(7, 8)).toEqual({ kind: 'conflict', currentRevision: 7 });
  });
});

