# Changelog

All notable, user-visible changes to MoonFMI are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/MuVirus/MoonFMI/compare/v0.6.0...HEAD
[0.6.0]: https://github.com/MuVirus/MoonFMI/releases/tag/v0.6.0
