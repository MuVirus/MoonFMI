#!/usr/bin/env node
// Prepares browser/build from an already-built component (F-06).
// Usage: node prepare.mjs <component.wasm> <jcoName>
import { spawnSync } from 'node:child_process';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const [component, jcoName = 'adder'] = process.argv.slice(2);
if (!component) {
  console.error('usage: node prepare.mjs <component.wasm> [jcoName]');
  process.exit(2);
}
const out = join(here, 'build');
rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });
writeFileSync(
  join(out, 'host_shim.mjs'),
  ['export const captured = [];', 'export function log(level, message) {', '  captured.push({ level, message });', '}'].join(String.fromCharCode(10)) +
    String.fromCharCode(10),
);
const jco = process.env.MOONFMI_JCO || 'jco';
const result = spawnSync(
  jco,
  ['transpile', resolve(component), '-o', out, '--name', jcoName, '--map', 'moonfmi:adder/host=./host_shim.mjs'],
  { stdio: 'inherit', cwd: here, shell: process.platform === 'win32' },
);
if (result.status !== 0) {
  console.error('jco transpile failed');
  process.exit(1);
}
writeFileSync(join(out, 'package.json'), '{"type":"module"}' + String.fromCharCode(10));
console.log('browser assets ready: ' + out);
