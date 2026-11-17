// Browser host for the transpiled Adder CS component (roadmap F-06).
// Mirrors the Node host test: get-version, instantiate, set inputs, step,
// read y = u1 + u2, terminate and drop; logs arrive through host_shim.
import { captured } from './build/host_shim.mjs';
import { cs } from './build/adder.js';

const status = document.getElementById('status');
const table = document.getElementById('results');
const logView = document.getElementById('log');

let failures = 0;
function check(name, value, ok) {
  if (!ok) failures += 1;
  const row = document.createElement('tr');
  const a = document.createElement('td');
  a.textContent = name;
  const b = document.createElement('td');
  b.textContent = String(value);
  row.append(a, b);
  table.append(row);
}

try {
  check('world get-version', cs.getVersion(), cs.getVersion() === '3.0');
  const fmu = new cs.Fmu();
  check('resource get-version', fmu.getVersion(), fmu.getVersion() === '3.0');
  fmu.setReal(0, 10);
  fmu.setReal(1, 20);
  let stepped = true;
  try {
    fmu.doStep(0, 0.1);
  } catch (error) {
    stepped = false;
    check('doStep error', error.message, false);
  }
  const y = fmu.getReal(2);
  check('doStep ok', stepped, stepped);
  check('y = u1 + u2', y, y === 30);
  fmu.setReal(1, 5);
  fmu.doStep(0.1, 0.1);
  check('y after u2 = 5', fmu.getReal(2), fmu.getReal(2) === 15);
  fmu.terminate();
  let terminatedError = '';
  try {
    fmu.doStep(0.2, 0.1);
  } catch (error) {
    terminatedError = error.message;
  }
  check(
    'do-step after terminate errors',
    terminatedError || '(no error)',
    terminatedError.includes('terminate'),
  );
  fmu[Symbol.dispose]();
  check(
    'guest logged through host import',
    captured.length + ' message(s)',
    captured.length > 0,
  );
  status.textContent = failures === 0 ? 'all browser checks passed' : failures + ' check(s) failed';
  status.className = failures === 0 ? 'pass' : 'fail';
  document.documentElement.dataset.result = failures === 0 ? 'pass' : 'fail';
} catch (error) {
  status.textContent = 'error: ' + (error instanceof Error ? error.message : String(error));
  status.className = 'fail';
  document.documentElement.dataset.result = 'fail';
  console.error(error);
}
logView.textContent = captured.map((c) => `[${c.level}] ${c.message}`).join('\n') || '(no log messages)';
