import { performance } from 'node:perf_hooks';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const [codecPath, counterPath] = process.argv.slice(2);
if (!codecPath || !counterPath) {
  throw new Error('usage: node bench.mjs <transpiled codec.js> <transpiled counter.js>');
}
const { codec } = await import(pathToFileURL(resolve(codecPath)).href);
const { counter } = await import(pathToFileURL(resolve(counterPath)).href);

function bench(label, iterations, fn) {
  for (let i = 0; i < Math.min(iterations, 1000); i++) fn(i);
  const start = performance.now();
  for (let i = 0; i < iterations; i++) fn(i);
  const ms = performance.now() - start;
  const perOp = (ms * 1000) / iterations;
  console.log(
    label.padEnd(34) +
      String(iterations).padStart(8) +
      ' ops ' +
      ms.toFixed(1).padStart(9) +
      ' ms ' +
      perOp.toFixed(2).padStart(8) +
      ' us/op',
  );
}

const small = 'hello';
const medium = 'x'.repeat(4096);
const bytes = Uint8Array.from({ length: 4096 }, (_, i) => i & 0xff);
const record = { name: 'sample', values: Float64Array.from([1.5, 2.5, 3.5]) };

bench('echo-string 5 char', 200_000, () => codec.echoString(small));
bench('echo-string 4096 char', 20_000, () => codec.echoString(medium));
bench('echo-bytes 4096 B', 20_000, () => codec.echoBytes(bytes));
bench('summarize 3 f64', 100_000, () => codec.summarize(record));
bench('counter new + bump(1) + drop', 100_000, () => {
  using handle = new counter.Counter(0);
  handle.bump(1);
});
