# Changelog

All notable, user-visible changes to MoonFMI are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/MuVirus/MoonFMI/compare/v0.7.0...HEAD
[0.7.0]: https://github.com/MuVirus/MoonFMI/releases/tag/v0.7.0
[0.6.0]: https://github.com/MuVirus/MoonFMI/releases/tag/v0.6.0
