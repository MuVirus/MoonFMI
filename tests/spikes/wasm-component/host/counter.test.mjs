import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const modulePath = process.argv[2];
if (!modulePath) {
  throw new Error('usage: node counter.test.mjs <transpiled counter.js>');
}
const { counter } = await import(pathToFileURL(resolve(modulePath)).href);

function assert(condition, message) {
  if (!condition) {
    console.error('FAIL: ' + message);
    process.exitCode = 1;
  } else {
    console.log('ok   ' + message);
  }
}

assert(counter.dropped() === 0, 'no drops before any handle is released');

const a = new counter.Counter(10);
const b = new counter.Counter(100);
assert(a.value() === 10, 'a.value() === 10');
assert(a.bump(5) === 15, 'a.bump(5) === 15');
assert(a.value() === 15, 'a.value() after bump');
assert(b.value() === 100, 'b.value() is independent');
assert(b.bump(1) === 101, 'b.bump(1) === 101');
assert(counter.dropped() === 0, 'no drops while both handles are live');

a[Symbol.dispose]();
assert(counter.dropped() === 1, 'guest dtor ran after host drop of a');

{
  using scoped = new counter.Counter(7);
  assert(scoped.value() === 7, 'scoped counter value');
}
assert(counter.dropped() === 2, 'guest dtor ran when using-scoped handle left the block');

const many = [];
for (let i = 0; i < 1000; i++) many.push(new counter.Counter(i));
assert(counter.dropped() === 2, 'no drops for 1000 live handles');
for (const handle of many) handle[Symbol.dispose]();
assert(counter.dropped() === 1002, '1000 guest dtors ran after 1000 host drops');

b[Symbol.dispose]();
assert(counter.dropped() === 1003, 'final drop counted');

console.log('done');
