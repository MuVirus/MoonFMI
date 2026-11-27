# Changelog

All notable, user-visible changes to MoonFMI are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Version numbers always take the smallest possible increment (patch first,
no skipping): fixes go to the patch number, features to the minor number,
and a breaking JSON-contract change bumps the `/vN` suffix before it may
touch the module version. The module version also stays below `1.0.0` for as
long as mooncakes refuses major versions: publishing `1.0.0` or later is
gated on the MoonBit 1.0 **stable** release, so the `1.0` milestone content
ships as `0.9.0` until that gate opens.

## [Unreleased]

## [0.9.0] - 2026-11-27

The `1.0` milestone content — hardening, docs, cross-check standards met —
shipped under the largest version mooncakes currently accepts. The registry
rejects a major version greater than 0 (`Publishing versions with a major
version greater than 0 is not enabled`), because publishing `1.0.0` or later
is gated on the MoonBit 1.0 stable release and the toolchain in use is still
the 1.0 release candidate. `1.0.0` remains the planned version for when that
gate opens.

### Added

- `examples/`: runnable examples for the library API — `validate-model`
  (static model-description validation, no dynamic library involved),
  `simulate-cs`, `simulate-me`, `couple-fmus` (two FMUs in one coupled run,
  with the value references looked up by variable name) and
  `export-source-fmu` (model IR to a source FMU plus a deterministic `.fmu`)
  — together with a `moonfmi` command-line cheat sheet (commands, options,
  exit codes, the configuration layer). The quality gate runs every example,
  so the documented code cannot rot.

### Changed

- MoonBit 1.0 is now the minimum toolchain. The release is verified against
  `moonc v1.0.0-rc1+3c0520448`, and CI pins that exact build instead of
  tracking `latest`: upstream now publishes versioned toolchain artifacts and
  both install scripts accept a version, so the pin is reproducible.
- The configuration layer moves to `MuVirus/moonfig@0.2.5`. The library API is
  unchanged from 0.2.4 — 0.2.5 is the upstream build that pins the MoonBit 1.0
  release candidate — and it adds no transitive dependency (`moonbitlang/x@0.5.7`
  was already locked here).
- The module's canonical backend is now `native` (`preferred_target` in
  `moon.mod`), matching the project's first usable path. The native-only
  packages — `src/backend/native`, `src/cli`, `cmd/main` and
  `tests/integration` — gain a generated interface, so their public API
  changes are now caught by the CI interface check, and editors can
  complete and navigate inside them. The already generated interfaces are
  byte-identical; `wasm` remains a supported target
  (`moon check --target wasm`, `moon test --target wasm`).
- `src/backend/wasm/pkg.generated.mbti` is removed: the package is
  wasm-only, and `moon info` only writes interfaces for the canonical
  backend, so the file could no longer be regenerated (verified for
  `moon info`, `moon check --target wasm`, `moon build --target wasm` and
  `moon test --target wasm`). Its public interface is therefore no longer
  covered by the CI interface check until the wasm backend has real
  content to expose.

### Fixed

- FMI 3 FMUs that ship a `resources/` directory could not be initialized: the
  host handed them an FMI 2 style `file://` URI, while FMI 3.0.2 §2.3 asks
  for the native path of the `resources/` directory, terminated by a file
  separator. The Reference-FMU `Resource` model failed in
  `fmi3ExitInitializationMode`; it now initializes and runs.

## [0.8.2] - 2026-11-23

### Added

- The intermediate-update channel is real: `fmi3IntermediateUpdateCallback`
  forwards each in-step report into a MoonBit callback (time, variable
  access flags, early-return offer), the host's decision is carried back
  to the FMU, and `fmi3DoStep` early returns are resumed from
  `lastSuccessfulTime` by the existing step body. `eventModeUsed` and
  `earlyReturnAllowed` follow the model description's capability bits
  instead of being hardcoded, and `fmi3Instance::intermediate_update_count`
  exposes the callback volume. Reference-FMUs Roberts raises ~20000
  callbacks over its 0.02 s horizon.
- Roberts (fmi3) finally runs under CS: the loader honors the declared
  event mode and retries without it when the FMU's binaries reject
  `eventModeUsed = true` (its sources ship without `EVENT_UPDATE`, though
  the XML declares `hasEventMode` — the old "requires intermediate-update
  support" attribution in the reports was wrong).
- The self-built clock fixture `tests/clock-fmu/` (MoonfmiClocks) gives
  the CS/ME clock paths and the cross-FMU clock connections their first
  real-FMU evidence: CS grid activation of constant/triggered/countdown
  clocks, ME event-mode rounds, an end-to-end early-return negotiation,
  and a `couple` clock connection between two instances. The tests
  compile the C source with clang and skip cleanly without one.
- `CsInstance` exposes `intermediate_update_count` (0 for backends
  without the channel).

### Fixed

- The 0.8.1 attribution: Roberts' CS rejection came from binaries
  compiled without `EVENT_UPDATE` rejecting `eventModeUsed = true`, not
  from a missing intermediate-update host channel —
  `docs/reports/crosscheck.md`, the roadmap backlog and the test file
  comments say so now.

## [0.8.1] - 2026-11-22

### Added

- The Model Exchange master schedules FMI 2/3 time events:
  `EventInfo.nextEventTime` is now consumed — the integrator never steps
  past a declared event, the event is settled when the step lands on it
  (adaptive and fixed-step paths), and fixed-grid recording stays on the
  grid. Until now only indicator crossings and `completedIntegratorStep`
  could trigger event handling, so a model reporting only time events
  was integrated across them.
- FMI 3 gains the six missing typed setters (`fmi3SetFloat32`,
  `fmi3SetUInt8`, `fmi3SetInt16`, `fmi3SetUInt16`, `fmi3SetUInt32`,
  `fmi3SetInt64`) with per-value `set_*_one` forms; the C shim already
  resolved them, so no shim change was needed. The `--set` override
  accepts every numeric FMI 3 kind (including `UInt64`, previously
  absent from `--set`); Binary and Clock remain non-settable scalars.
- Array variables generalize: ten numeric `get_<type>_values(references,
  n_values)` bulk reads join `get_float64_values`, and the simulation
  recorder supports Float64 array outputs — `CsConfig`/`MeConfig`/
  `SeConfig` accept `record_arrays` and the CLI expands each element
  into its own `name[i]` CSV/JSON column (FMI 2 through consecutive
  references, FMI 3 through the native `nValues` read).
- FMI 3 clocked partitions under CS/ME (previously Scheduled Execution
  only): the SE activation rounds were extracted into a shared
  `run_clock_rounds` over a closure-based `ClockScheduling`; `CsConfig`
  and `MeConfig` accept `clocks` and run the rounds at communication
  points (CS) and inside event mode (ME). The CLI wires the schedule
  automatically when the model declares clocks. `fmi3GetIntervalDecimal`
  and `fmi3ActivateModelPartition` resolve independently of the
  Scheduled Execution instantiate, so clocked CS/ME-only FMUs work, and
  the FMI 3 CS step body consumes `nextEventTime` so `do_step` never
  crosses a declared FMU time event.
- `moonfmi couple` supports cross-FMU clock connections: `SignalType`
  gains `Clock`; after every communication step the master observes the
  source participant's output clock and, on a pulse, fires the target's
  input clock through new `ParticipantClocks` hooks. Both endpoints
  need hooks (FMI 2 participants are rejected). Clock connections are
  excluded from the algebraic-loop analysis.
- Validation rules MD-007 and MD-052 now carry their own codes:
  an unknown `variableNamingConvention` reports MD-007 (previously the
  generic `STRUCTURE`), and a non-integer `<BaseUnit>` exponent reports
  MD-052 (previously rejected as a generic structure error). All 44
  implemented rules plus MD-037/MD-038 now have explicit positive and
  negative cases, machine-checked by a data-driven rule-matrix test.
- Integration tests cover the remaining corpus samples: fmi2/Stair and
  fmi3/Stair under CS (second counting through the typed integer
  channel) and fmi3/Roberts under ME (Robertson kinetics on a short
  horizon). Every corpus FMU now runs in at least one supported
  interface.
- New `docs/guides/quick-start.md` walks from fetching the reference
  corpus to the first simulations and JSON outputs.

### Fixed

- The CLI version string (`moonfmi version`, previously `0.7.0`) now
  matches the module version; a root-package test locks the two
  together. Releases take the smallest possible version increment.
- Documentation drift: the exit-code table in
  `docs/design/cli-and-testing.md` disagreed with the authoritative
  contract in `docs/cli-json.md` (1 = validation failure, 3 = unreadable
  input); `doctor` and `tests/data/README.md` still pointed at the
  retired `fetch-fmus.mjs` script instead of `fetch-fmus.mbtx`.

## [0.8.0] - 2026-11-21

### Added

- `moonfmi simulate` and `moonfmi couple` accept `--config <path>`: a JSON,
  INI or dotenv file (format detected from suffix and content) whose
  `simulate` / `couple` sections carry the same options as the command
  line. Keys are snake_case; kebab-case spellings are accepted too.
  Precedence is command line > environment > config file > built-in
  defaults, so an experiment spec can be stored, reviewed and replayed
  in CI instead of being copied into a long command line.
- `MOONFMI_*` environment variables join the same merge:
  `MOONFMI_SIMULATE__STOP_TIME` maps to `simulate.stop_time` (double
  underscore separates levels, single underscore stays in the key).
- The configuration layer is built on the first-party library
  `MuVirus/moonfig`, locked at `0.2.4` (Apache-2.0). It adds no new
  transitive dependency and does not change the public API surface
  (`moon info` reports no `.mbti` change).
- Config-file failures use the existing exit-code matrix: a missing or
  unreadable file exits 1, a syntax, type or value error exits 2.

### Changed

- Unknown keys inside the `simulate` / `couple` sections of a config
  file are reported as warnings on stderr instead of aborting the run,
  so a file may carry comment-like fields. Root-level `MOONFMI_*`
  variables belonging to other tools are not checked.

### Fixed

- The `0.7.0` release link was missing from the link references at the
  end of this file.

## [0.7.0] - 2026-11-20

### Added

- Coupling refinements: algebraic-loop blocks are now minimal strongly
  connected components (Tarjan) — cycle members iterate while downstream
  consumers step once after the block — and every Jacobi iteration after
  the first restores block members to the grid-point state when they
  support capture (block-local lifecycle when the run is non-coordinated),
  removing the compounding-doStep approximation for capturable FMUs.
- The cross-check corpus grows from 9 to 13 FMUs: Stair (FMI 2 and FMI 3,
  time events) and Roberts (FMI 3) join the smoke matrix; the corpus
  Robertson model under CS is documented as requiring FMI 3 intermediate
  updates MoonFMI's CS host does not provide yet (its ME path runs).
- `moonfmi simulate --set name=value`: set inputs and parameters per type
  (FMI 2 Real/Integer/Boolean/String/Enumeration; FMI 3 Float64/Int32/
  Boolean/String/Enumeration) before initialization, with the type inferred
  from the model description and wrong-kind or unknown names rejected with
  exit 1.
- `moonfmi couple --loop-iterations N` / `--loop-tolerance T`: expose the
  existing Jacobi fixed-point loop solver on the command line.
- `moonfmi couple --connect` infers the signal type (Real, Integer,
  Boolean) from the producer's declared variable type and rejects
  cross-type connections up front instead of failing mid-run.
- `--sha256 <hex>` on `simulate` and `couple`: the archive digest is
  verified before anything is extracted or loaded (security review R2).
- `--sandbox` on `simulate` and `couple`: the command re-executes in a
  child process (via `moonbitlang/async`, admitted 2026-11-19) with live
  stdout/stderr forwarding and a hard watchdog derived from `--timeout`.
  Crash isolation only — not a permission sandbox (R11 mitigation).
- LS-WASM layered-standard validation: `validate` now checks
  `extra/org.modelica.fmi-ls-wasm/manifest.xml` structurally (root,
  `fmiVersion`, `Binary` path/entrypoint/world, model-identifier match,
  archive presence) and rejects wasm-only FMUs without a manifest;
  wasm components next to native binaries stay diagnostic-free (the
  Reference-FMUs corpus ships those). `info` reports the WASM layer
  (`lsWasm` in the JSON output).
- Source-FMU exporter: two-dimensional FMI 3 arrays (matrix states, inputs,
  outputs, parameters) with a `add_matrix_state_equation` helper that
  expands dense `x'[i][j] = Σₖ A[i][k]·x[k][j]` into per-element sums;
  arrays are stored flat and the multi-dimensional shape surfaces in the
  XML `<Dimension>` elements. A 2×2 matrix state-space example matches the
  analytic solution end to end.
- FMI 2 `<VendorAnnotations><Tool name="...">` is parsed (payload skipped,
  name required) and carried on the model description; the exporter writes
  its generation tool as a vendor `Tool`. XSD field coverage is now
  FMI 2 92/92 and FMI 3 144/144 (`docs/reports/field-coverage.md`).
- `scripts/repro-build.mbtx`: two clean release builds of the CLI are
  compared byte for byte, tolerating only link-timestamp bytes (release
  checklist §3 automation).
- Random suffixes for private `.moonfmi-tmp` directories (8 bytes from the
  platform entropy source, hex-encoded), replacing wall-clock-only names
  (security review R7).
- Aarch64 CI coverage: `ubuntu-24.04-arm` builds the ABI baseline (new
  `tests/abi/baselines/aarch64-linux.json`), compiles the source-FMU export
  tests for the host and runs the corpus suites natively.
- Concurrent log callbacks from FMU threads are verified end to end: the
  shim serializes delivery with a process-wide lock, and a fixture test
  drives 4 threads × 25 messages through one instance (security review R4).

### Fixed

- The FMI 2 exporter wrote the synthetic `der(x)` variable's `derivative`
  attribute as a value reference; the FMI 2 semantics require the 1-based
  `ModelVariables` position. Models whose first declaration is a state (no
  parameter/output declared before it) produced XML that failed validation.
  Found by the new export→reparse differential fuzz.
- FMI 2 platform selection was bitness-only: an arm64 Linux host selected
  `binaries/linux64/` (x86-64 binaries). It now selects `aarch64-linux` /
  `aarch64-darwin`, matching the Reference-FMUs corpus layout.

## [0.6.0] - 2026-11-18

First release. This entry summarizes the project from its first commit
(2026-10-30) through the 0.6.0 release; it is not a diff against a previous
tag.

### Added

- `moonfmi` CLI with `validate`, `info`, `simulate`, `package`, `doctor` and
  `completion` commands, a documented exit-code matrix, and shell completion
  generation for bash, zsh and pwsh.
- Typed model descriptions for FMI 2.0 and FMI 3.0 (XSD element order
  enforced) with semantic validation rules MD-001..MD-063, including the
  Scheduled Execution clock rules (MD-034, MD-036, MD-037) and the
  `Annotations` rule MD-038.
- Co-Simulation, Model Exchange and Scheduled Execution simulation:
  - FMI 2 CS master algorithm, and FMI 2 ME with Euler/RK4 solvers and
    event detection and localization.
  - FMI 3 CS/ME backends with grouped capability probing, event mode support
    and CLI interface auto-detection.
  - FMI 3 Scheduled Execution with full clock semantics (constant,
    countdown and triggered intervals, priority ordering, cascading output
    clocks) via `--interface se`.
- FMI 2 Integer and Boolean value channels (`get`/`set`, array and scalar).
- CS `Discard` handling: the master rolls back to a captured state and
  retries with a halved step; FMI 3 continues from `lastSuccessfulTime`,
  FMI 2 reports an explicit error.
- Multi-FMU coupling as a library API (`src/sim`): topologically ordered
  stepping without a one-step lag, rejection of algebraic loops, duplicate
  names, unknown endpoints and unobservable connection sources. Not yet
  exposed through the CLI.
- Source-code FMU exporter for FMI 2/3: model IR with explicit equations,
  XML generation, C code generation, deterministic ZIP packaging
  (stable sha256), including element-wise array equations for FMI 3.
- Experimental WASM FMU exporter (Float64 scalar subset, FMI Layered
  Standard WASM manifest) and a browser proof of concept running a full CS
  lifecycle against a WASM component.
- FMU state save/restore/serialize for FMI 2, with explicit capability
  errors when the FMU lacks the required functions.
- Cross-check tooling: a corpus smoke matrix with FMI 2/FMI 3 trajectory
  comparison (`docs/reports/crosscheck.md` and `.json`, schema
  `moonfmi.crosscheck/v1`), an external FMPy cross-validation harness, and
  generation of the official fmi-cross-check submission layout.
- Security measures documented and tested: XML limits (size, depth,
  attribute count) and DOCTYPE/entity rejection, ZIP hardening (entry
  limits, compression-ratio and path checks), fuzz regressions, a security
  review document and performance gates.

### Changed

- The field coverage report classifies XSD names by source schema file and
  reports known out-of-scope files (buildDescription, terminals and icons,
  layered-standard manifest) separately; FMI 3 model-description coverage
  is 144/144, all-FMI-3 XSD coverage 150/195, FMI 2 coverage 89/92.

### Fixed

- FMI 3 CS: a `Discard` status was silently ignored and recorded as a
  completed step; the master now rolls back and retries, or continues from
  `lastSuccessfulTime`.
- FMI 3 ME: continuous states and event indicators are now counted per
  array element (`Dimension` value references are parsed), fixing ME runs
  of models such as StateSpace whose nominal-value queries failed before.
- Exported FMI 2 model descriptions: removed CS-only attributes from the
  `ModelExchange` element, added the missing `time` variable, and completed
  the exported symbol surface (found by FMPy validation).
- Source hygiene: replaced raw NUL bytes in `src/fmi/fmi3.mbt` with
  `b'\x00'` escapes so the file is plain ASCII again.

## Link references

[Unreleased]: https://github.com/MuVirus/MoonFMI/compare/v0.9.0...HEAD
[0.9.0]: https://github.com/MuVirus/MoonFMI/releases/tag/v0.9.0
[0.8.2]: https://github.com/MuVirus/MoonFMI/releases/tag/v0.8.2
[0.8.1]: https://github.com/MuVirus/MoonFMI/releases/tag/v0.8.1
[0.8.0]: https://github.com/MuVirus/MoonFMI/releases/tag/v0.8.0
[0.7.0]: https://github.com/MuVirus/MoonFMI/releases/tag/v0.7.0
[0.6.0]: https://github.com/MuVirus/MoonFMI/releases/tag/v0.6.0
