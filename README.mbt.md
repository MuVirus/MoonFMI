# MoonFMI

English | [简体中文](README_ZH.md)

MoonFMI is an experimental MoonBit library and command-line tool (`moonfmi`)
for FMUs that follow FMI 2.0.4 or 3.0.2. It runs Co-Simulation and Model
Exchange models natively, handles FMI 3 Scheduled Execution, checks model
descriptions, builds FMU archives, and exports simple models back to FMU.

The mooncakes module is `MuVirus/fmi`; the repository keeps the `MoonFMI`
name.

## What you can do

- Check a `modelDescription.xml` against rules MD-001..MD-063 and print a
  summary (`validate`, `info`); LS-WASM layered-standard manifests are
  validated too when the archive carries WebAssembly components.
- Run a Co-Simulation or Model Exchange simulation with CSV or JSON output,
  or a Scheduled Execution run for FMI 3 clocks (`simulate`); set inputs and
  parameters per type with `--set name=value` before initialization.
- Couple several FMUs into one co-simulation with typed signal connections
  (Real, Integer, Boolean), opt-in algebraic-loop solving and per-connection
  signal-type inference (`couple`).
- Build a deterministic `.fmu` from an unpacked directory (`package`).
- Export restricted explicit models back to source-code FMUs (FMI 2/3) or an
  experimental WASM component FMU, including FMI 3 arrays and dense matrix
  equations expanded per element.
- Verify an FMU archive digest before anything is loaded (`--sha256`), run a
  command in a crash-isolated child process (`--sandbox`), and check the CLI
  binary builds reproducibly (`scripts/repro-build.mbtx`).
- Use the same code as a library: `MuVirus/fmi/src/{fmi,sim,backend/native}`.

## Install

Requires the [MoonBit toolchain](https://docs.moonbitlang.com) and a C
compiler: `moon` builds the bundled native shims.

```bash
moon add MuVirus/fmi
```

To work from a checkout instead:

```bash
git clone https://github.com/MuVirus/MoonFMI.git
cd MoonFMI
moon build --target native
```

The built binary lands under `_build/native/release/build/cmd/main/`;
`moon run cmd/main --target native -- --help` works without a separate
build.

## Minimal example

Fetch the Reference-FMUs used by the examples and the tests (BSD-2-Clause;
checksums are verified against `tests/data/manifest.json`):

```bash
moon run tests/data/fetch-fmus.mbtx --target native
```

Run the bouncing-ball model for three seconds:

```bash
moon run cmd/main --target native -- simulate tests/data/.cache/fmi2/BouncingBall.fmu \
    --stop-time 3 --step-size 0.01 --output ball.csv
```

`ball.csv` then holds 300 steps of `time,h,v`.

## Usage

Validate and inspect a model description without running it:

```bash
moon run cmd/main --target native -- validate tests/data/.cache/fmi2/BouncingBall.fmu
moon run cmd/main --target native -- info tests/data/.cache/fmi2/BouncingBall.fmu
```

Model Exchange uses the same entry point, and FMI 3 is detected
automatically:

```bash
moon run cmd/main --target native -- simulate tests/data/.cache/fmi2/VanDerPol.fmu \
    --interface me --solver rk4 --stop-time 5 --output vdp.csv
```

Build a deterministic `.fmu` from an unpacked directory:

```bash
moon run cmd/main --target native -- package build/MyModel --output MyModel.fmu
```

`moonfmi doctor` checks the local environment, and `moonfmi --help` lists
every command and exit code. Add `--json` for machine-readable output; the
shapes are versioned contracts, documented in
[`docs/cli-json.md`](docs/cli-json.md).

### Use as a library

The packages under `src/` are ordinary MoonBit packages. Build with
`--target native` and import only what you need. The example also uses
`moonbitlang/x/fs` for file helpers; add it with `moon add moonbitlang/x` if
it is not already a direct dependency.

In `moon.pkg`:

```moonbit nocheck
import {
  "MuVirus/fmi/src/backend/native" @native,
  "MuVirus/fmi/src/fmi" @fmi,
  "MuVirus/fmi/src/sim" @sim,
  "moonbitlang/core/env",
  "moonbitlang/x/fs",
}

supported_targets = "native"
```

In a `.mbt` file, run a Co-Simulation model and print the step count:

```moonbit nocheck
///|
fn run_ball(fmu_path : String) -> Unit {
  let data = @fs.read_file_to_bytes(fmu_path) catch {
    _ => return println("cannot read " + fmu_path)
  }
  let host = @fmi.parse_host_platform(@native.host_platform_name()).unwrap()
  @fs.create_dir(".moonfmi-tmp") catch {
    _ => ()
  }
  let work_dir = ".moonfmi-tmp/run-\{@env.now()}"
  let loaded = @native.load_fmi2_fmu(data, host~, temp_directory=work_dir) catch {
    _ => return println("load failed")
  }
  let config = @sim.CsConfig::new(
    start_time=0.0,
    stop_time=3.0,
    step_size=0.01,
    record=[1U, 2U],
  )
  let result = @sim.run_cs_simulation(loaded.instance(), config~) catch {
    _ => {
      loaded.dispose()
      return println("simulation failed")
    }
  }
  loaded.dispose()
  println("\{result.steps()} steps, \{result.series().length()} series")
}
```

`temp_directory` must be a fresh, empty directory: the loader unpacks the
whole FMU there so the native library and its resources have real paths.
`dispose()` releases the instance, unloads the library, and removes the
directory. FMI 3 uses the same shape through `load_fmi3_fmu`.

## Known limits

- The Model Exchange integrators are fixed-step Euler and classic RK4 only.
  MoonFMI is not a general-purpose ME solver: stiff systems, large DAEs, and
  adaptive step control are out of scope (see
  [`docs/design/master-algorithm.md`](docs/design/master-algorithm.md)).
- Coupling several CS FMUs is available as a library master
  (`MuVirus/fmi/src/sim`: participants, connections, topological stepping
  with constant extrapolation, coordinated multi-FMU rollback on `Discard`,
  Integer/Boolean signal connections, opt-in Jacobi fixed-point solving for
  algebraic loops with minimal-SCC loop blocks and inter-iteration state
  restore) and through the `moonfmi couple` command. FMUs that require FMI 3
  intermediate updates (e.g. the corpus Roberts model under CS) are not
  loadable by the CS host yet — their ME path runs. Loop solving re-steps
  real FMUs between Jacobi iterations without restoring FMU state only when
  capture is unavailable — a documented approximation (see
  [`docs/design/coupling.md`](docs/design/coupling.md) §3.5/§5).
- FMI 3 Scheduled Execution supports fixed, calculated and countdown input
  clocks, host-triggered clocks, and output-clock cascades, but gives no
  real-time guarantee: priority only orders activations at the same instant.
- The source-FMU exporter emits restricted explicit models (continuous
  states, feedthrough outputs, parameters and inputs); it is not a Modelica
  compiler. FMI 3 array variables support element-wise equations and dense
  matrix products expanded into per-element sums; symbolic loop/sum
  constructs are not part of the IR.
- The WebAssembly backend is experimental: a minimal CS component and
  LS-WASM packaging are verified (see
  [`tests/fmu-wasm/README.md`](tests/fmu-wasm/README.md)), while the full
  LS-WASM world and browser import are future work. `simulate --backend
  wasm` intentionally exits with code 4; `validate`/`info` check the LS-WASM
  manifest but nothing executes WASM components yet.
- `--sandbox` gives crash isolation and a hard watchdog only: the child
  FMU still runs with the host user's permissions. It is not a permission
  sandbox.
- Log delivery from FMU threads is serialized by a process-wide lock in the
  shim, but the shim does not queue or format messages: no `vsnprintf` on
  foreign format strings, 4 KiB truncation, synchronous delivery.

## Documentation

- [`docs/AGENTS.md`](docs/AGENTS.md) — the documentation map.
- [`docs/design/architecture.md`](docs/design/architecture.md) — package
  layout and design decisions.
- [`docs/roadmap/roadmap.md`](docs/roadmap/roadmap.md) — phases and open
  work.
- [`docs/records/`](docs/records/README.md) — dated logs with commands and
  evidence.

Licensed under [Apache-2.0](LICENSE).
