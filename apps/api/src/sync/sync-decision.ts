export type MutationDecision =
  | { kind: 'accept'; revision: number }
  | { kind: 'conflict'; currentRevision: number };

export function decideMutation(
  currentRevision: number | null,
  baseRevision: number,
): MutationDecision {
  if (currentRevision === null) {
    return baseRevision === 0
      ? { kind: 'accept', revision: 1 }
      : { kind: 'conflict', currentRevision: 0 };
  }
  return currentRevision === baseRevision
    ? { kind: 'accept', revision: currentRevision + 1 }
    : { kind: 'conflict', currentRevision };
}

