import { readFile, readdir } from 'node:fs/promises';
import { resolve } from 'node:path';

const root = resolve(import.meta.dirname, '..');
const contracts = resolve(root, 'packages/contracts');
const files = (await readdir(contracts)).filter((name) => name.endsWith('.json')).sort();

if (files.length === 0) throw new Error('No JSON contracts found');
for (const file of files) {
  const parsed = JSON.parse(await readFile(resolve(contracts, file), 'utf8'));
  if (file.endsWith('.schema.json') && parsed.$schema !== 'https://json-schema.org/draft/2020-12/schema') {
    throw new Error(`${file} does not declare JSON Schema 2020-12`);
  }
}

process.stdout.write(`Validated ${files.length} JSON contract files.\n`);

