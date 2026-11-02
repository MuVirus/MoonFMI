#!/usr/bin/env node
// Compare the ABI that the FMI headers produce on this machine with the
// checked-in baseline for the same platform.
//
// Usage: node tests/abi/check-abi.mjs [path-to-probe]

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const binary =
  process.argv[2] ??
  join(here, ".cache", process.platform === "win32" ? "probe.exe" : "probe");

if (!existsSync(binary)) {
  console.error(`ABI probe not found: ${binary}`);
  console.error("run tests/abi/build-fixture.ps1 or tests/abi/build-fixture.sh first");
  process.exit(1);
}

function run(args) {
  return execFileSync(binary, args, { encoding: "utf8" });
}

const baselineName = run(["--header"]).trim();
const baselinePath = join(here, "baselines", baselineName);
if (!existsSync(baselinePath)) {
  console.error(`no baseline for this platform: ${baselinePath}`);
  console.error("generate one with:");
  console.error(`  ${binary} > tests/abi/baselines/${baselineName}`);
  process.exit(1);
}

const actual = JSON.parse(run([]));
const expected = JSON.parse(readFileSync(baselinePath, "utf8"));

const differences = [];

function walk(path, expectedValue, actualValue) {
  if (expectedValue !== null && typeof expectedValue === "object") {
    if (actualValue === null || typeof actualValue !== "object") {
      differences.push(`${path}: expected an object, got ${JSON.stringify(actualValue)}`);
      return;
    }
    for (const key of Object.keys(expectedValue)) {
      if (!(key in actualValue)) {
        differences.push(`${path}.${key}: missing (baseline ${JSON.stringify(expectedValue[key])})`);
      } else {
        walk(`${path}.${key}`, expectedValue[key], actualValue[key]);
      }
    }
    for (const key of Object.keys(actualValue)) {
      if (!(key in expectedValue)) {
        differences.push(`${path}.${key}: unexpected (actual ${JSON.stringify(actualValue[key])})`);
      }
    }
    return;
  }
  if (expectedValue !== actualValue) {
    differences.push(`${path}: expected ${JSON.stringify(expectedValue)}, got ${JSON.stringify(actualValue)}`);
  }
}

walk("abi", expected, actual);

if (differences.length > 0) {
  console.error(`ABI baseline mismatch (${baselineName}):`);
  for (const difference of differences) {
    console.error(`  ${difference}`);
  }
  console.error("");
  console.error("If the change is intended and the headers were really updated,");
  console.error(`regenerate ${baselinePath} and review the diff of every field.`);
  process.exit(1);
}

console.log(`ABI baseline matches: ${baselineName}`);
