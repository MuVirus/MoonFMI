# MuVirus/MoonFMI

English | [简体中文](README_ZH.md)

An experimental MoonBit interface to FMI-compliant FMUs (FMI 2.0.4 and
FMI 3.0.2, Co-Simulation and Model Exchange).

## Quickstart (10 minutes)

1. Install MoonBit and get the code:

   ```bash
   # https://docs.moonbitlang.com covers the toolchain install
   git clone https://github.com/MuVirus/MoonFMI.git
   cd MoonFMI
   moon test --target native   # 110 tests, should all pass
   ```

2. Download the test FMUs (Reference-FMUs, BSD-2-Clause; one command,
   checksums verified against `tests/data/manifest.json`):

   ```bash
   moon run tests/data/fetch-fmus.mbtx --target native
   ```

3. Validate, inspect, simulate — the three everyday commands:

   ```bash
   moon run cmd/main --target native -- validate tests/data/.cache/fmi2/BouncingBall.fmu
   # → 0 error(s), 0 warning(s)

   moon run cmd/main --target native -- info tests/data/.cache/fmi2/BouncingBall.fmu
   # → modelName: BouncingBall, interfaces, variable types, platforms, sha256

   moon run cmd/main --target native -- simulate tests/data/.cache/fmi2/BouncingBall.fmu \
       --stop-time 3 --step-size 0.01 --output ball.csv
   # → 300 steps; ball.csv holds time,h,v

   moon run cmd/main --target native -- simulate tests/data/.cache/fmi2/VanDerPol.fmu \
       --interface me --solver rk4 --stop-time 5 --output vdp.csv
   ```

   Everything also works for the FMI 3 FMUs in `tests/data/.cache/fmi3/`
   (`simulate` auto-detects the version). Add `--json` for machine-readable
   output — the shapes are versioned contracts, see
   [docs/cli-json.md](docs/cli-json.md).

4. Build your own FMU from a directory:

   ```bash
   moon run cmd/main --target native -- package build/MyModel --output MyModel.fmu
   # deterministic: same input → same bytes (sha256 in the output)
   ```

Tip: `moon build --target native` produces the standalone binary under
`_build/native/release/build/cmd/main/main.exe`; run `moonfmi --help`
for the full command set and the exit code table. `moonfmi doctor`
checks the local environment.

## Known limits

- The model-exchange integrators are fixed-step Euler and classic RK4 only.
  MoonFMI is **not a general-purpose ME solver**: stiff systems, large DAEs,
  and adaptive step control are out of scope; use an external solver for
  those (see `docs/design/master-algorithm.md` §4.1).
- One FMU per run; coupling multiple FMUs (connections, algebraic loops) is
  future work (see `docs/design/master-algorithm.md` §8 of the roadmap).
- FMI 3 Scheduled Execution is supported for fixed/calculated/countdown
  input clocks, host-triggered clocks and output-clock cascades; there is
  no real-time guarantee (priority only orders same-instant activations).
- The source-FMU exporter emits restricted explicit models (continuous
  states, feedthrough outputs, parameters/inputs) — it is not a Modelica
  compiler; array equations are not generated yet (arrays roundtrip as
  values on FMI 3).
- The WebAssembly backend is **experimental**: a minimal CS component and
  LS-WASM packaging are verified (see `tests/fmu-wasm/README.md`), but the
  full LS-WASM world and browser hosts are future work; `simulate
  --backend wasm` intentionally exits with code 4.
- `package` output is verified by MoonFMI's own reader; validating with
  FMPy as an external check: `uv run --with fmpy python tools/fmpy_compare.py
  --cli <moonfmi>` compares both tools' CS trajectories; results live in
  `docs/reports/fmpy-comparison.md`.

## Layout

- `src/{xml,zip,schema}` — hardened XML/ZIP readers, typed model
  descriptions, semantic rules MD-001..MD-063;
- `src/fmi` — FMU container layer, `CsInstance`/`MeInstance` traits;
- `src/backend/native` — FMI 2/3 dynamic library bindings (C shims);
- `src/sim` — CS master algorithm and the ME Euler/RK4 master with event
  detection;
- `src/cli` — the `moonfmi` command line (`cmd/main` is the entry);
- `docs/roadmap` — phased roadmap and backlog; `docs/design` — design
  documents; `docs/records` — dated implementation logs.
