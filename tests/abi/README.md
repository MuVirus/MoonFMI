# ABI baselines

`tests/abi` holds generated `sizeof` / `offsetof` baselines for FMI 2 and FMI 3.

P0 week 1 only reserves the directory. The C probe and the checked-in baseline
files arrive in week 3, together with the C shim.

Planned contents:

- `fmi2/` — Windows and Linux baselines for `fmi2*` types and callback structs;
- `fmi3/` — Windows and Linux baselines for `fmi3*` types and callback structs;
- `README.md` — how to regenerate and how CI compares the baseline.
