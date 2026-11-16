// F-04/F-05 host test: instantiate the Adder CS component through jco, drive
// the CS lifecycle, verify y = u1 + u2, and capture the guest's log calls
// through the imported host callback shim (F-05).
import { resolve } from 'node:path';
import { dirname, join } from 'node:path';
import { pathToFileURL } from 'node:url';

const modulePath = process.argv[2];
if (!modulePath) {
  throw new Error('usage: node adder.test.mjs <transpiled adder.js>');
}
const { cs } = await import(pathToFileURL(resolve(modulePath)).href);
// The guest's log calls go through host_shim.mjs (mapped at transpile time).
const shimPath = join(dirname(resolve(modulePath)), 'host_shim.mjs');
const { captured } = await import(pathToFileURL(shimPath).href);



function assert(condition, message) {
  if (!condition) {
    console.error('FAIL: ' + message);
    process.exitCode = 1;
  } else {
    console.log('ok   ' + message);
  }
}

// F-02: get-version answers at both levels.
assert(cs.getVersion() === '3.0', 'get-version() === "3.0"');

const logCountBeforeInstantiate = captured.length;

// F-04: CS lifecycle — instantiate, set inputs, step, read output.
const fmu = new cs.Fmu();
assert(
  captured.length > logCountBeforeInstantiate,
  'guest logged through the host import at instantiation (F-05)',
);
assert(fmu.getVersion() === '3.0', 'fmu.getVersion() === "3.0"');

fmu.setReal(0, 10);
fmu.setReal(1, 20);
let stepOk = true;
try {
  fmu.doStep(0, 0.1);
} catch (error) {
  stepOk = false;
}
assert(stepOk, 'doStep(0, 0.1) returns ok');
assert(fmu.getReal(2) === 30, 'y = u1 + u2 === 30');

// The master algorithm advances the communication point; a second step from
// a new current point keeps the output correct.
try {
  fmu.doStep(0.1, 0.1);
  console.log('ok   doStep(0.1, 0.1) returns ok');
} catch (error) {
  assert(false, 'doStep(0.1, 0.1) threw: ' + error.message);
}
assert(fmu.getReal(2) === 30, 'y stays 30 (Adder has no states)');

// Unknown value references are logged, not crashed.
fmu.setReal(99, 1);
assert(
  captured.some((call) => call.message.includes('unknown vr 99')),
  'unknown vr logged through host callback',
);

// Error path: do-step after terminate returns an error.
fmu.terminate();
let threw = false;
try {
  fmu.doStep(0.2, 0.1);
} catch (error) {
  threw = error.message.includes('do-step called after terminate');
}
assert(threw, 'doStep after terminate errors with the guest message');

// F-05: dispose runs the guest destructor, visible through the log channel.
const destroyCount = captured.filter((call) =>
  call.message.includes('destroyed'),
).length;
fmu[Symbol.dispose]();
assert(
  captured.filter((call) => call.message.includes('destroyed')).length ===
    destroyCount + 1,
  'guest dtor logged after host drop',
);

console.log('done');
