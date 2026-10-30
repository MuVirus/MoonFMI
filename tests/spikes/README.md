# P0 spikes

`tests/spikes` holds throwaway probes that answer the five P0 questions.

P0 week 1 only reserves the directory. Week 2–4 add:

- `xml/` — read a real `modelDescription.xml`, including malformed and hostile inputs;
- `zip/` — unpack a real FMU, including path traversal and zip-bomb cases;
- `dl/` — load and unload a small C shared library;
- `wasm/` — compile MoonBit to a component and call it from wasmtime.

Each spike records the exact commands and observed output in `docs/roadmap/p0-week*.md`.
