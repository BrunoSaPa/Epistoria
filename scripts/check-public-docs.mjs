import { readFile, readdir } from 'node:fs/promises';
import { isAbsolute, relative, resolve, sep } from 'node:path';

const repositoryRoot = resolve(import.meta.dirname, '..');
const publicRoot = resolve(repositoryRoot, 'docs/public');

const allowedFiles = [
  'FAQ.md',
  'FEATURES.md',
  'GET_STARTED.md',
  'KNOWN_LIMITATIONS.md',
  'PRIVACY.md',
  'README.md',
  'RELEASE_NOTES.md',
  'ROADMAP.md',
  'USER_GUIDE.md',
].sort();

const blockedContent = [
  ['engineering process language', /\b(?:architecture|implementation|engineering|developer|contributors?)\b/i],
  ['architecture decision record reference', /\b(?:ADR(?:-\d+)?|architecture decision records?)\b/i],
  ['database or framework detail', /\b(?:database|SQLCipher|FTS5|PostgreSQL|Prisma|MinIO|NestJS|SwiftUI|PencilKit|XcodeGen)\b/i],
  ['cryptographic format detail', /\b(?:XChaCha20|HKDF|BIP-39|secretstream|authenticated additional data)\b/i],
  ['internal synchronization detail', /\b(?:outbox|tombstone|deduplication|ciphertext|wire version|schema migration|database migration|baseRevision|sync cursor)\b/i],
  ['internal entity or job constant', /\b(?:NOTE_BLOCK|AI_ARTIFACT|SESSION_DIGEST|NOTE_QUERY|PDF_EXTRACTION)\b/],
  ['internal source path', /(?:^|[\s`])(?:apps|services|packages|infra|scripts|\.github|\.agents)\//m],
  ['development command', /\b(?:make\s+[a-z]|xcodebuild|swift\s+test|npm\s+(?:run|ci)|docker\s+compose|pytest|mypy|ruff)\b/i],
  ['internal provider or cost configuration', /\b(?:OpenAI|gpt-[\w.-]+|token rates?|soft budget|per million tokens)\b/i],
  ['legacy product terminology', /\b(?:Courses?|Collections?|Resources?|Universit(?:y|ies))\b/],
  ['internal QA identifier', /\b(?:A|IP|CN|SY|RC|EX|MW|AI|TF|PV|OP)-\d{2}\b/],
  ['exact currency amount', /(?:\$|USD\s*)\d/i],
  ['fenced code block', /^```/m],
];

function lineNumber(source, index) {
  return source.slice(0, index).split('\n').length;
}

function headingSlug(value) {
  return value
    .trim()
    .toLowerCase()
    .replace(/<[^>]+>/g, '')
    .replace(/[`*_~]/g, '')
    .replace(/[^\p{L}\p{N}\s-]/gu, '')
    .replace(/\s+/g, '-');
}

const directoryEntries = await readdir(publicRoot, { withFileTypes: true });
const unexpectedEntries = directoryEntries
  .filter((entry) => !entry.isFile() || !allowedFiles.includes(entry.name))
  .map((entry) => entry.name)
  .sort();
const actualFiles = directoryEntries
  .filter((entry) => entry.isFile())
  .map((entry) => entry.name)
  .sort();
const missingFiles = allowedFiles.filter((file) => !actualFiles.includes(file));

if (unexpectedEntries.length > 0 || missingFiles.length > 0) {
  const details = [];
  if (unexpectedEntries.length > 0) details.push(`unexpected: ${unexpectedEntries.join(', ')}`);
  if (missingFiles.length > 0) details.push(`missing: ${missingFiles.join(', ')}`);
  throw new Error(`Public documentation allowlist mismatch (${details.join('; ')})`);
}

const documents = new Map();
const problems = [];

for (const file of allowedFiles) {
  const source = await readFile(resolve(publicRoot, file), 'utf8');
  const anchors = new Set();
  const duplicateCounts = new Map();
  let topLevelHeadingCount = 0;
  let previousHeadingLevel = 0;

  for (const [index, line] of source.split('\n').entries()) {
    const heading = line.match(/^(#{1,6})\s+(.+?)\s*#*$/);
    if (!heading) continue;

    const level = heading[1].length;
    if (level === 1) topLevelHeadingCount += 1;
    if (previousHeadingLevel > 0 && level > previousHeadingLevel + 1) {
      problems.push(`${file}:${index + 1}: heading level skips from ${previousHeadingLevel} to ${level}`);
    }
    previousHeadingLevel = level;

    const baseAnchor = headingSlug(heading[2]);
    const duplicateCount = duplicateCounts.get(baseAnchor) ?? 0;
    duplicateCounts.set(baseAnchor, duplicateCount + 1);
    anchors.add(duplicateCount === 0 ? baseAnchor : `${baseAnchor}-${duplicateCount}`);
  }

  if (topLevelHeadingCount !== 1) {
    problems.push(`${file}: expected one level-1 heading, found ${topLevelHeadingCount}`);
  }

  for (const [label, pattern] of blockedContent) {
    const match = source.match(pattern);
    if (match?.index !== undefined) {
      problems.push(`${file}:${lineNumber(source, match.index)}: blocked ${label}`);
    }
  }

  documents.set(file, { source, anchors });
}

for (const [file, document] of documents) {
  for (const match of document.source.matchAll(/!?\[[^\]]*\]\(([^)]+)\)/g)) {
    let destination = match[1].trim().replace(/^<|>$/g, '');

    if (/^https:\/\//i.test(destination) || /^mailto:/i.test(destination)) continue;
    if (/^[a-z][a-z0-9+.-]*:/i.test(destination)) {
      problems.push(`${file}:${lineNumber(document.source, match.index)}: unsupported link scheme`);
      continue;
    }

    const [encodedPath, encodedFragment] = destination.split('#');
    let decodedPath;
    let decodedFragment;
    try {
      decodedPath = decodeURIComponent(encodedPath || file);
      decodedFragment = encodedFragment ? decodeURIComponent(encodedFragment).toLowerCase() : undefined;
    } catch {
      problems.push(`${file}:${lineNumber(document.source, match.index)}: invalid encoded link`);
      continue;
    }

    const target = resolve(publicRoot, decodedPath);
    const targetRelative = relative(publicRoot, target).split(sep).join('/');
    if (targetRelative.startsWith('../') || targetRelative === '..' || isAbsolute(targetRelative)) {
      problems.push(`${file}:${lineNumber(document.source, match.index)}: link escapes docs/public`);
      continue;
    }
    if (!allowedFiles.includes(targetRelative)) {
      problems.push(`${file}:${lineNumber(document.source, match.index)}: link target is not allowlisted: ${targetRelative}`);
      continue;
    }
    if (decodedFragment && !documents.get(targetRelative)?.anchors.has(decodedFragment)) {
      problems.push(`${file}:${lineNumber(document.source, match.index)}: missing target heading: ${destination}`);
    }
  }
}

for (const [file, document] of documents) {
  if (file === 'RELEASE_NOTES.md') continue;
  for (const match of document.source.matchAll(/\bversion\s+(\d+)\s+(?:readable\s+)?export\b/gi)) {
    if (match[1] !== '8') {
      problems.push(`${file}:${lineNumber(document.source, match.index)}: unsupported current export version ${match[1]}`);
    }
  }
}

const publicIndex = documents.get('README.md')?.source ?? '';
for (const file of allowedFiles) {
  if (file === 'README.md') continue;
  if (!publicIndex.includes(`](${file})`)) {
    problems.push(`README.md: missing index link for ${file}`);
  }
}

if (problems.length > 0) {
  throw new Error(`Public documentation validation failed:\n${problems.join('\n')}`);
}

process.stdout.write(`Validated ${allowedFiles.length} allowlisted public documentation files.\n`);
