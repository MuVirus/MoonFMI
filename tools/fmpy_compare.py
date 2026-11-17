#!/usr/bin/env python3
"""FMPy cross-validation for MoonFMI (roadmap P6/P8 follow-up).

Runs every co-simulation sample twice — once with FMPy, once with the
`moonfmi` CLI — and compares the recorded output trajectories.

Usage (uv resolves the Python + fmpy environment, no system install):

    uv run --with fmpy python tools/fmpy_compare.py \
        --cli _build/native/release/build/cmd/main/main.exe

Writes docs/reports/fmpy-comparison.md and prints a summary table.
Exit code 1 when any sample deviates beyond the tolerance or FMPy rejects a
file that MoonFMI accepts.
"""

from __future__ import annotations

import argparse
import csv
import json
import subprocess
import sys
from pathlib import Path

TOLERANCE = 1e-6
START, STOP, STEP = 0.0, 1.0, 0.1

# Samples with a Co-Simulation interface; SE-only Clocks is out of scope for
# FMPy's CS harness here.
SAMPLES = [
    "fmi2/BouncingBall.fmu",
    "fmi2/Dahlquist.fmu",
    "fmi2/Feedthrough.fmu",
    "fmi2/VanDerPol.fmu",
    "fmi3/BouncingBall.fmu",
    "fmi3/Feedthrough.fmu",
    "fmi3/StateSpace.fmu",
]


def run_cli(cli: str, fmu: Path, csv_out: Path) -> tuple[bool, str]:
    result = subprocess.run(
        [
            cli,
            "simulate",
            str(fmu),
            "--start-time",
            str(START),
            "--stop-time",
            str(STOP),
            "--step-size",
            str(STEP),
            "--output",
            str(csv_out),
        ],
        capture_output=True,
        text=True,
    )
    return result.returncode == 0, (result.stdout + result.stderr).strip()


def read_moonfmi_csv(path: Path) -> tuple[list[str], list[list[float]]]:
    with path.open(newline="") as handle:
        rows = list(csv.reader(handle))
    header = rows[0]
    data = [[float(cell) for cell in row] for row in rows[1:] if row]
    return header, data


def fmpy_simulate(fmu: Path) -> tuple[list[str], list[list[float]]] | None:
    from fmpy import read_model_description, simulate_fmu

    description = read_model_description(str(fmu), validate=False)
    outputs = [
        v.name
        for v in description.modelVariables
        if v.causality in (None, "output") and v.type in ("Real", "Float64")
    ]
    if not outputs:
        return None
    result = simulate_fmu(
        str(fmu),
        start_time=START,
        stop_time=STOP,
        step_size=STEP,
        # FMPy defaults to ~100 output points; pin it to the communication
        # grid so both tools record the same rows.
        output_interval=STEP,
        output=outputs,
        validate=False,
    )
    names = list(result.dtype.names or [])
    data = [[float(value) for value in row] for row in result]
    return names, data


def compare(
    moon_header: list[str],
    moon_rows: list[list[float]],
    fmpy_header: list[str],
    fmpy_rows: list[list[float]],
) -> tuple[float | None, str]:
    if len(moon_rows) != len(fmpy_rows):
        return None, f"row count differs (moonfmi {len(moon_rows)}, fmpy {len(fmpy_rows)})"
    worst = 0.0
    compared = 0
    for name in fmpy_header:
        if name not in moon_header:
            continue
        moon_index = moon_header.index(name)
        fmpy_index = fmpy_header.index(name)
        compared += 1
        for moon_row, fmpy_row in zip(moon_rows, fmpy_rows):
            delta = abs(moon_row[moon_index] - fmpy_row[fmpy_index])
            worst = max(worst, delta)
    if compared == 0:
        return None, "no shared output columns"
    return worst, f"{compared} column(s) compared"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", required=True, help="path to the moonfmi executable")
    parser.add_argument("--cache", default="tests/data/.cache", help="FMU corpus root")
    parser.add_argument(
        "--report",
        default="docs/reports/fmpy-comparison.md",
        help="markdown report path",
    )
    args = parser.parse_args()

    cache = Path(args.cache)
    scratch = Path(".moonfmi-tmp/fmpy")
    scratch.mkdir(parents=True, exist_ok=True)
    report_rows: list[dict[str, object]] = []
    failures = 0

    for relative in SAMPLES:
        fmu = cache / relative
        if not fmu.exists():
            report_rows.append({"sample": relative, "verdict": "skip", "detail": "not in cache"})
            continue
        csv_path = scratch / (relative.replace("/", "-") + ".csv")
        moon_ok, moon_detail = run_cli(args.cli, fmu, csv_path)
        if not moon_ok:
            report_rows.append({"sample": relative, "verdict": "moonfmi failed", "detail": moon_detail})
            failures += 1
            continue
        try:
            moon_header, moon_rows = read_moonfmi_csv(csv_path)
        except (OSError, ValueError) as error:
            report_rows.append({"sample": relative, "verdict": "csv error", "detail": str(error)})
            failures += 1
            continue
        try:
            fmpy_result = fmpy_simulate(fmu)
        except Exception as error:  # noqa: BLE001 - report the FMPy error verbatim
            message = str(error).splitlines()[0] if str(error) else type(error).__name__
            # Array-valued outputs are known to break FMPy's structured
            # result conversion; record that as a skip, not a MoonFMI defect.
            verdict = "skip" if "0-dimensional" in message or "array" in message.lower() else "fmpy error"
            report_rows.append({"sample": relative, "verdict": verdict, "detail": message})
            if verdict != "skip":
                failures += 1
            continue
        if fmpy_result is None:
            report_rows.append({"sample": relative, "verdict": "skip", "detail": "no Real outputs"})
            continue
        fmpy_header, fmpy_rows = fmpy_result
        worst, detail = compare(moon_header, moon_rows, fmpy_header, fmpy_rows)
        if worst is None:
            report_rows.append({"sample": relative, "verdict": "shape mismatch", "detail": detail})
            failures += 1
        elif worst <= TOLERANCE:
            report_rows.append(
                {"sample": relative, "verdict": "match", "detail": f"max abs diff {worst:.3g} ({detail})"}
            )
        else:
            report_rows.append(
                {"sample": relative, "verdict": "deviation", "detail": f"max abs diff {worst:.3g} ({detail})"}
            )
            failures += 1

    # Exported source FMUs (P6): FMPy must open them and reproduce the
    # trajectory. Pick the newest export directory produced by the tests.
    preferred = sorted(Path(".moonfmi-tmp/export-built").glob("MoonfmiDahlquist-*.fmu"))
    if preferred:
        exported = preferred
    else:
        # Source-only exports have no binary; prefer a packaged build.
        exported = [
            path
            for path in sorted(Path(".moonfmi-tmp").glob("export-*/MoonfmiDahlquist.fmu"))
            if "binaries" in str(path)
        ] or sorted(Path(".moonfmi-tmp").glob("export-*/MoonfmiDahlquist.fmu"))
    for fmu in exported:
        try:
            from fmpy import read_model_description, simulate_fmu

            read_model_description(str(fmu), validate=True)
            csv_path = scratch / (fmu.stem + ".csv")
            moon_ok, moon_detail = run_cli(args.cli, fmu, csv_path)
            if not moon_ok:
                report_rows.append(
                    {"sample": f"exported {fmu.name}", "verdict": "moonfmi failed", "detail": moon_detail}
                )
                failures += 1
            else:
                moon_header, moon_rows = read_moonfmi_csv(csv_path)
                result = simulate_fmu(
                    str(fmu),
                    start_time=START,
                    stop_time=STOP,
                    step_size=STEP,
                    output_interval=STEP,
                    validate=False,
                )
                worst, detail = compare(
                    moon_header,
                    moon_rows,
                    list(result.dtype.names or []),
                    [[float(value) for value in row] for row in result],
                )
                if worst is not None and worst <= TOLERANCE:
                    report_rows.append(
                        {
                            "sample": f"exported {fmu.parent.name}",
                            "verdict": "match",
                            "detail": f"FMPy XSD validate ok; max abs diff {worst:.3g} ({detail})",
                        }
                    )
                else:
                    report_rows.append(
                        {
                            "sample": f"exported {fmu.parent.name}",
                            "verdict": "deviation",
                            "detail": detail if worst is None else f"max abs diff {worst:.3g}",
                        }
                    )
                    failures += 1
        except Exception as error:  # noqa: BLE001
            report_rows.append(
                {
                    "sample": f"exported {fmu.parent.name}",
                    "verdict": "fmpy error",
                    "detail": str(error).splitlines()[0],
                }
            )
            failures += 1

    lines = [
        "# FMPy comparison (cross-validation)",
        "",
        "> Generated by `uv run --with fmpy python tools/fmpy_compare.py --cli <moonfmi>`.",
        f"> Both tools run CS with start {START}, stop {STOP}, step {STEP}; tolerance {TOLERANCE:g}.",
        "",
        "| sample | verdict | detail |",
        "| --- | --- | --- |",
    ]
    for row in report_rows:
        lines.append(f"| {row['sample']} | {row['verdict']} | {row.get('detail', '')} |")
    report = Path(args.report)
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text("\n".join(lines) + "\n", encoding="utf-8")

    print("\n".join(lines))
    print(json.dumps({"failures": failures, "samples": len(report_rows)}))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
