#!/usr/bin/env node
// Builds and tests the P7 WASM CS FMU component (tasks F-02/F-04/F-05) and
// packages a WASM FMU with the LS-WASM layout (task F-07).
//
// Everything generated stays in `.cache/` (gitignored) so the repository
// keeps a single MoonBit module. See README.md for prerequisites.
//
// Commands:
//   node tests/fmu-wasm/run.mjs build      build the component
//   node tests/fmu-wasm/run.mjs test       build + host test (jco/Node)
//   node tests/fmu-wasm/run.mjs package    build + write .cache/MoonfmiAdder.fmu
//   node tests/fmu-wasm/run.mjs clean      remove .cache

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
import { createHash } from 'node:crypto';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const cache = join(here, '.cache');
const buildRoot = join(cache, 'build');
const jcoHome = join(cache, 'jco');
const JCO_VERSION = '1.40.0';

// The Adder CS model description, identical in structure to what the native
// exporter emits: u1=0, u2=1, y=2, CS interface, no event mode.
const MODEL_DESCRIPTION = `<?xml version="1.0" encoding="UTF-8"?>
<fmiModelDescription
  fmiVersion="3.0"
  modelName="MoonfmiAdder"
  description="y = u1 + u2 (WebAssembly CS component)"
  generationTool="MoonFMI fmu-wasm test"
  instantiationToken="{a3ddf8a2-4c33-5b31-9e04-7c1f22d5aa61}">

    <CoSimulation
      modelIdentifier="MoonfmiAdder"
      needsExecutionTool="false"
      canHandleVariableCommunicationStepSize="true"
      canInterpolateInputs="false"
      canGetAndSetFMUstate="false"
      canSerializeFMUstate="false"
      providesDirectionalDerivative="false"
      providesIntermediateUpdate="false"
      hasEventMode="false"/>

    <DefaultExperiment startTime="0" stopTime="1" stepSize="0.1"/>

    <ModelVariables>
        <Float64 name="u1" valueReference="0" causality="input" variability="discrete" initial="exact" start="0"/>
        <Float64 name="u2" valueReference="1" causality="input" variability="discrete" initial="exact" start="0"/>
        <Float64 name="y" valueReference="2" causality="output" variability="discrete" initial="calculated"/>
    </ModelVariables>

    <ModelStructure>
        <Output valueReference="2"/>
    </ModelStructure>

</fmiModelDescription>
`;

// LS-WASM manifest (org.modelica.fmi-ls-wasm profile). The wasm32-wasip2
// binary lives in binaries/wasm32-wasip2/ like any other FMI platform.
const LS_WASM_MANIFEST = `<?xml version="1.0" encoding="UTF-8"?>
<fmiLSWASMManifest fmiVersion="3.0">
  <Binary
    path="binaries/wasm32-wasip2/MoonfmiAdder.wasm"
    entrypoint="MoonfmiAdder.wasm"
    world="moonfmi:adder/adder"/>
</fmiLSWASMManifest>
`;

const spikes = [
  {
    name: 'adder',
    wit: 'wit/adder.wit',
    guest: [
      {
        from: 'guest/adder/fmu.mbt',
        to: 'gen/interface/moonfmi/adder/cs/fmu_impl.mbt',
      },
    ],
    // The guest logs through the imported host interface, so the generated
    // export package needs the import package on its classpath.
    pkgImport: {
      pkg: 'gen/interface/moonfmi/adder/cs/moon.pkg',
      line: '"moonfmi/adder/interface/moonfmi/adder/host" @host,',
    },
    hostTest: 'host/adder.test.mjs',
    jcoName: 'adder',
    componentBase: 'MoonfmiAdder',
  },
];

function log(message) {
  process.stdout.write(message + '\n');
}

const HOME_BIN = join(
  process.env.USERPROFILE || process.env.HOME || '',
  '.moonfmi',
  'bin',
);

function findTool(name) {
  const envDir = process.env.MOONFMI_WASM_BIN || HOME_BIN;
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
  // Fall back to the P0 spike's installation when present.
  const spikeJco = join(
    here,
    '..',
    'spikes',
    'wasm-component',
    '.cache',
    'jco',
    'node_modules',
    '.bin',
    process.platform === 'win32' ? 'jco.cmd' : 'jco',
  );
  if (existsSync(spikeJco)) return spikeJco;
  return findTool('jco');
}

const tools = {
  moon: () => findTool('moon'),
  'wit-bindgen': () => findTool('wit-bindgen'),
  'wasm-tools': () => findTool('wasm-tools'),
  npm: () => findTool('npm'),
  jco: findJco,
  node: () => process.execPath,
};

function requireTool(name) {
  const path = tools[name]();
  if (!path) {
    const hint =
      name === 'jco'
        ? 'run `node tests/fmu-wasm/run.mjs setup-jco`, or put jco on PATH'
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
  if (spike.pkgImport) {
    const pkgPath = join(work, spike.pkgImport.pkg);
    let content = readFileSync(pkgPath, 'utf8');
    if (!content.includes(spike.pkgImport.line)) {
      content = content.replace(
        /^import \{\n/m,
        `import {\n  ${spike.pkgImport.line}\n`,
      );
      if (!content.includes('import {')) {
        content = `import {\n  ${spike.pkgImport.line}\n}\n\n${content}`;
      }
      writeFileSync(pkgPath, content);
    }
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

function transpile(built) {
  const out = join(built.work, 'js');
  mkdirSync(out, { recursive: true });
  // The component imports `moonfmi:adder/host`; map it to a local shim so
  // Node can resolve it and the test can capture the calls (F-05).
  writeFileSync(
    join(out, 'host_shim.mjs'),
    'export const captured = [];\n' +
      'export function log(level, message) {\n' +
      '  captured.push({ level, message });\n' +
      '}\n',
  );
  run(
    requireTool('jco'),
    [
      'transpile',
      built.component,
      '-o',
      out,
      '--name',
      built.jcoName,
      '--map',
      'moonfmi:adder/host=./host_shim.mjs',
    ],
    { cwd: built.work },
  );
  writeFileSync(join(built.work, 'package.json'), '{"type":"module"}\n');
  return join(out, `${built.jcoName}.js`);
}

// ---------------------------------------------------------------------------
// Minimal deterministic ZIP writer (STORE method) for the F-07 packaging —
// the FMU layout is validated by MoonFMI's own reader, which accepts stored
// entries.
// ---------------------------------------------------------------------------

const CRC_TABLE = (() => {
  const table = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) {
      c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    }
    table[n] = c;
  }
  return table;
})();

function crc32(buffer) {
  let crc = -1;
  for (let i = 0; i < buffer.length; i++) {
    crc = (crc >>> 8) ^ CRC_TABLE[(crc ^ buffer[i]) & 0xff];
  }
  return (crc ^ -1) >>> 0;
}

function dosDateTime() {
  // Fixed timestamp like MoonFMI's deterministic writer: 1980-01-01.
  return { time: 0, date: (1 << 5) | 1 };
}

function buildZip(entries) {
  const localParts = [];
  const centralParts = [];
  let offset = 0;
  for (const [name, data] of entries) {
    const nameBuffer = Buffer.from(name, 'utf8');
    const dataBuffer = Buffer.isBuffer(data) ? data : Buffer.from(data, 'utf8');
    const crc = crc32(dataBuffer);
    const { time, date } = dosDateTime();
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4); // version needed
    local.writeUInt16LE(0, 6); // flags
    local.writeUInt16LE(0, 8); // stored
    local.writeUInt16LE(time, 10);
    local.writeUInt16LE(date, 12);
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(dataBuffer.length, 18);
    local.writeUInt32LE(dataBuffer.length, 22);
    local.writeUInt16LE(nameBuffer.length, 26);
    local.writeUInt16LE(0, 28);
    localParts.push(local, nameBuffer, dataBuffer);

    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(20, 4);
    central.writeUInt16LE(20, 6);
    central.writeUInt16LE(0, 8);
    central.writeUInt16LE(0, 10);
    central.writeUInt16LE(time, 12);
    central.writeUInt16LE(date, 14);
    central.writeUInt32LE(crc, 16);
    central.writeUInt32LE(dataBuffer.length, 20);
    central.writeUInt32LE(dataBuffer.length, 24);
    central.writeUInt16LE(nameBuffer.length, 28);
    central.writeUInt32LE(offset, 42);
    centralParts.push(central, nameBuffer);
    offset += local.length + nameBuffer.length + dataBuffer.length;
  }
  const centralSize = centralParts.reduce((sum, part) => sum + part.length, 0);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(entries.length, 8);
  end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(centralSize, 12);
  end.writeUInt32LE(offset, 16);
  return Buffer.concat([...localParts, ...centralParts, end]);
}

function commandPackage(built) {
  const spike = built[0];
  const entries = [
    ['modelDescription.xml', MODEL_DESCRIPTION],
    [
      'extra/org.modelica.fmi-ls-wasm/manifest.xml',
      LS_WASM_MANIFEST,
    ],
    [
      `binaries/wasm32-wasip2/${spike.componentBase}.wasm`,
      readFileSync(spike.component),
    ],
  ];
  const archive = buildZip(entries);
  const outPath = join(cache, `${spike.componentBase}.fmu`);
  writeFileSync(outPath, archive);
  const sha = createHash('sha256').update(archive).digest('hex');
  log(`packaged ${entries.length} entries, ${archive.length} B into ${outPath}`);
  log(`sha256 ${sha}`);
  return outPath;
}

function commandSetupJco() {
  mkdirSync(jcoHome, { recursive: true });
  const packageJson = join(jcoHome, 'package.json');
  if (!existsSync(packageJson)) {
    writeFileSync(
      packageJson,
      JSON.stringify({ name: 'moonfmi-wasm-tools', private: true, type: 'module' }, null, 2) + '\n',
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
  // `build-export <dir>` builds a Wasm FMU produced by the MoonFMI exporter
  // (F-08): the exported tree ships its own build.mjs, so delegate to it.
  if (command === 'build-export') {
    const dir = process.argv[3];
    if (!dir) {
      console.error('usage: node run.mjs build-export <export-dir>');
      process.exit(2);
    }
    const script = join(resolve(dir), 'build.mjs');
    if (!existsSync(script)) {
      throw new Error('no build.mjs in ' + dir);
    }
    run(requireTool('node'), [script], { cwd: dir });
    log('build-export done: ' + dir);
    process.exit(0);
  }
  const built = spikes.map(buildOne);
  switch (command) {
    case 'build':
      log('built: ' + built.map((item) => item.name).join(', '));
      break;
    case 'test': {
      const js = transpile(built[0]);
      run(requireTool('node'), [join(here, built[0].hostTest), js], {
        cwd: built[0].work,
      });
      log('all fmu-wasm checks passed');
      break;
    }
    case 'package':
      commandPackage(built);
      break;
    case 'setup-jco':
      commandSetupJco();
      break;
    case 'clean':
      commandClean();
      break;
    default:
      console.error(`unknown command: ${command}`);
      console.error('usage: node run.mjs [build|test|package|build-export|setup-jco|clean]');
      process.exit(2);
  }
} catch (error) {
  console.error('error: ' + (error instanceof Error ? error.message : String(error)));
  process.exit(1);
}
