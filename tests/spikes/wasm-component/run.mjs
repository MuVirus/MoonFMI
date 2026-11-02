#!/usr/bin/env node
// Builds and runs the P0 WebAssembly component spikes.
//
// Everything generated stays in `.cache/` (gitignored) so the repository keeps
// a single MoonBit module. See README.md for prerequisites and expected output.

import { spawnSync } from 'node:child_process';
import {
  cpSync,
  existsSync,
  mkdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const cache = join(here, '.cache');
const buildRoot = join(cache, 'build');
const jcoHome = join(cache, 'jco');
const JCO_VERSION = '1.40.0';

const spikes = [
  {
    name: 'adder',
    wit: 'wit/adder.wit',
    guest: [{ from: 'guest/adder/add.mbt', to: 'gen/interface/docs/adder/add/add.mbt' }],
  },
  {
    name: 'codec',
    wit: 'wit/codec.wit',
    guest: [
      {
        from: 'guest/codec/codec.mbt',
        to: 'gen/interface/moonfmi/codec/codec/codec.mbt',
      },
    ],
    hostTest: 'host/codec.test.mjs',
    jcoName: 'codec',
  },
  {
    name: 'counter',
    wit: 'wit/counter.wit',
    guest: [
      {
        from: 'guest/counter/counter.mbt',
        to: 'gen/interface/moonfmi/store/counter/counter_impl.mbt',
      },
    ],
    hostTest: 'host/counter.test.mjs',
    jcoName: 'counter',
  },
];

function log(message) {
  process.stdout.write(message + '\n');
}

function findTool(name) {
  const envDir = process.env.MOONFMI_WASM_BIN;
  if (envDir) {
    const candidates =
      process.platform === 'win32'
        ? [join(envDir, name + '.exe'), join(envDir, name + '.cmd'), join(envDir, name)]
        : [join(envDir, name)];
    for (const candidate of candidates) {
      if (existsSync(candidate)) return candidate;
    }
  }
  const probe = spawnSync(process.platform === 'win32' ? 'where' : 'which', [name], {
    encoding: 'utf8',
  });
  if (probe.status === 0) {
    const lines = probe.stdout
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean);
    if (process.platform === 'win32') {
      const executable = lines.find((line) => /\.(exe|cmd|bat)$/i.test(line));
      if (executable) return executable;
    }
    if (lines[0]) return lines[0];
  }
  return null;
}

function findJco() {
  if (process.env.MOONFMI_JCO) return process.env.MOONFMI_JCO;
  const local = join(
    jcoHome,
    'node_modules',
    '.bin',
    process.platform === 'win32' ? 'jco.cmd' : 'jco',
  );
  if (existsSync(local)) return local;
  return findTool('jco');
}

const tools = {
  moon: () => findTool('moon'),
  'wit-bindgen': () => findTool('wit-bindgen'),
  'wasm-tools': () => findTool('wasm-tools'),
  wasmtime: () => findTool('wasmtime'),
  npm: () => findTool('npm'),
  jco: findJco,
  node: () => process.execPath,
};

function requireTool(name) {
  const path = tools[name]();
  if (!path) {
    const hint =
      name === 'jco'
        ? 'run `node tests/spikes/wasm-component/run.mjs setup-jco`, or put jco on PATH'
        : 'put it on PATH or set MOONFMI_WASM_BIN to the directory that contains it';
    throw new Error(`missing tool: ${name} (${hint})`);
  }
  return path;
}

function usesShell(cmd) {
  return process.platform === 'win32' && /\.(cmd|bat)$/i.test(cmd);
}

function run(cmd, args, options = {}) {
  const result = spawnSync(cmd, args, {
    stdio: 'inherit',
    cwd: options.cwd ?? here,
    env: process.env,
    shell: usesShell(cmd),
  });
  if (result.error) throw new Error(`${cmd}: ${result.error.message}`);
  if (result.status !== 0) {
    throw new Error(`${cmd} ${args.join(' ')} exited with ${result.status}`);
  }
}

function capture(cmd, args, options = {}) {
  const result = spawnSync(cmd, args, {
    cwd: options.cwd ?? here,
    env: process.env,
    encoding: 'utf8',
    shell: usesShell(cmd),
  });
  if (result.error) throw new Error(`${cmd}: ${result.error.message}`);
  if (result.status !== 0) {
    throw new Error(
      `${cmd} ${args.join(' ')} exited with ${result.status}\n${result.stderr ?? ''}`,
    );
  }
  return { stdout: result.stdout ?? '', stderr: result.stderr ?? '' };
}

function sizeOf(path) {
  return `${statSync(path).size} B`;
}

function buildOne(spike) {
  const work = join(buildRoot, spike.name);
  rmSync(work, { recursive: true, force: true });
  mkdirSync(join(work, 'wit'), { recursive: true });
  cpSync(join(here, spike.wit), join(work, 'wit', 'world.wit'));

  log(`--- ${spike.name}: wit-bindgen ---`);
  run(requireTool('wit-bindgen'), ['moonbit', join(work, 'wit'), '--out-dir', work, '--derive-debug'], {
    cwd: work,
  });

  for (const guest of spike.guest) {
    const destination = join(work, guest.to);
    mkdirSync(dirname(destination), { recursive: true });
    cpSync(join(here, guest.from), destination);
  }

  log(`--- ${spike.name}: moon build --target wasm --release ---`);
  run(requireTool('moon'), ['build', '--target', 'wasm', '--release'], { cwd: work });

  const core = join(work, '_build', 'wasm', 'release', 'build', 'gen', 'gen.wasm');
  if (!existsSync(core)) {
    throw new Error(`moon build did not produce ${core}`);
  }
  const embedded = join(work, `${spike.name}.core.wasm`);
  const component = join(work, `${spike.name}.component.wasm`);

  log(`--- ${spike.name}: wasm-tools component embed/new ---`);
  run(requireTool('wasm-tools'), [
    'component',
    'embed',
    join(work, 'wit'),
    core,
    '--encoding',
    'utf16',
    '-o',
    embedded,
  ]);
  run(requireTool('wasm-tools'), ['component', 'new', embedded, '-o', component]);
  run(requireTool('wasm-tools'), ['validate', '--features', 'all', component]);

  log(`    ${spike.name}: core ${sizeOf(core)}, component ${sizeOf(component)}`);
  return { ...spike, work, core, component };
}

function testAdder(built) {
  const result = capture(requireTool('wasmtime'), [
    'run',
    '--invoke',
    'add(10, 20)',
    built.component,
  ]);
  const output = result.stdout.trim();
  if (output !== '30') {
    throw new Error(`adder: expected 30, got ${JSON.stringify(output)}`);
  }
  log('ok   adder: wasmtime --invoke add(10, 20) -> 30');
}

function transpile(built) {
  const out = join(built.work, 'js');
  run(requireTool('jco'), [
    'transpile',
    built.component,
    '-o',
    out,
    '--name',
    built.jcoName,
  ], { cwd: built.work });
  writeFileSync(join(built.work, 'package.json'), '{"type":"module"}\n');
  return join(out, `${built.jcoName}.js`);
}

function runHostTest(built, modulePath) {
  run(requireTool('node'), [join(here, built.hostTest), modulePath], { cwd: built.work });
}

function commandBuild() {
  const built = spikes.map(buildOne);
  log('built: ' + built.map((item) => item.name).join(', '));
  return built;
}

function commandTest() {
  const built = spikes.map(buildOne);
  const byName = Object.fromEntries(built.map((item) => [item.name, item]));
  testAdder(byName.adder);
  const codecJs = transpile(byName.codec);
  runHostTest(byName.codec, codecJs);
  const counterJs = transpile(byName.counter);
  runHostTest(byName.counter, counterJs);
  log('all WebAssembly spike checks passed');
}

function commandBench() {
  const built = spikes.map(buildOne);
  const byName = Object.fromEntries(built.map((item) => [item.name, item]));
  const codecJs = transpile(byName.codec);
  const counterJs = transpile(byName.counter);
  run(
    requireTool('node'),
    [join(here, 'host', 'bench.mjs'), codecJs, counterJs],
    { cwd: cache },
  );
}

function commandSetupJco() {
  mkdirSync(jcoHome, { recursive: true });
  const packageJson = join(jcoHome, 'package.json');
  if (!existsSync(packageJson)) {
    writeFileSync(
      packageJson,
      JSON.stringify(
        { name: 'moonfmi-wasm-spike-tools', private: true, type: 'module' },
        null,
        2,
      ) + '\n',
    );
  }
  log(`--- npm install @bytecodealliance/jco@${JCO_VERSION} (into .cache/jco) ---`);
  run(
    requireTool('npm'),
    ['install', '--no-audit', '--no-fund', `@bytecodealliance/jco@${JCO_VERSION}`],
    { cwd: jcoHome },
  );
  log('jco installed at ' + join(jcoHome, 'node_modules', '.bin'));
}

function commandClean() {
  rmSync(cache, { recursive: true, force: true });
  log('removed ' + cache);
}

const command = process.argv[2] ?? 'test';
try {
  switch (command) {
    case 'build':
      commandBuild();
      break;
    case 'test':
      commandTest();
      break;
    case 'bench':
      commandBench();
      break;
    case 'setup-jco':
      commandSetupJco();
      break;
    case 'clean':
      commandClean();
      break;
    default:
      console.error(`unknown command: ${command}`);
      console.error('usage: node run.mjs [build|test|bench|setup-jco|clean]');
      process.exit(2);
  }
} catch (error) {
  console.error('error: ' + (error instanceof Error ? error.message : String(error)));
  process.exit(1);
}
