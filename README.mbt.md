# MuVirus/MoonFMI

An experimental MoonBit interface to FMI-compliant FMUs.

## Known limits

- The model-exchange integrators are fixed-step Euler and classic RK4 only.
  MoonFMI is **not a general-purpose ME solver**: stiff systems, large DAEs,
  and adaptive step control are out of scope; use an external solver for
  those (see `docs/design/master-algorithm.md` §4.1).
