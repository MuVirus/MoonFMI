import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const modulePath = process.argv[2];
if (!modulePath) {
  throw new Error('usage: node codec.test.mjs <transpiled codec.js>');
}
const { codec } = await import(pathToFileURL(resolve(modulePath)).href);

function assert(condition, message) {
  if (!condition) {
    console.error('FAIL: ' + message);
    process.exitCode = 1;
  } else {
    console.log('ok   ' + message);
  }
}

function sameBytes(a, b) {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

for (const value of [
  '',
  'hello',
  '中文🙂',
  'a"b',
  'line\nbreak',
  '\u{1F600}\u{1F601}',
  'x'.repeat(100_000),
]) {
  assert(codec.echoString(value) === value, `echo-string round-trip (len=${value.length})`);
}

for (const value of [
  new Uint8Array(),
  new Uint8Array([0, 1, 2, 255]),
  Uint8Array.from({ length: 1 << 20 }, (_, i) => i & 0xff),
]) {
  assert(sameBytes(codec.echoBytes(value), value), `echo-bytes round-trip (len=${value.length})`);
}

const record = {
  name: '中文🙂',
  values: Float64Array.from([1.5, 2.5, -3.25]),
};
assert(codec.summarize(record) === '中文🙂/3/0.75', 'summarize record');

console.log('done');
