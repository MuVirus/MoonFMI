#!/usr/bin/env node
// Compare the C reference host output with the checked-in baseline.
//
// Usage: node tests/abi/check-host.mjs [path-to-output.json]

import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const outputPath = process.argv[2] ?? join(here, ".cache", "fmi2-host.json");
const baselinePath = join(here, "baselines", "fmi2-bouncingball.json");

if (!existsSync(outputPath)) {
  console.error(`reference host output not found: ${outputPath}`);
  process.exit(1);
}

const actual = JSON.parse(readFileSync(outputPath, "utf8"));
const expected = JSON.parse(readFileSync(baselinePath, "utf8"));

function closeEnough(a, b) {
  const scale = Math.max(1, Math.abs(a), Math.abs(b));
  return Math.abs(a - b) <= 1e-9 * scale;
}

const differences = [];
if (!Array.isArray(actual.samples)) {
  differences.push("output has no samples array");
} else if (actual.samples.length !== expected.samples.length) {
  differences.push(
    `expected ${expected.samples.length} samples, got ${actual.samples.length}`,
  );
} else {
  for (let index = 0; index < expected.samples.length; index++) {
    const [expectedTime, expectedH, expectedV] = expected.samples[index];
    const [time, h, v] = actual.samples[index];
    if (!closeEnough(time, expectedTime)) {
      differences.push(`sample ${index}: time ${time} != ${expectedTime}`);
    }
    if (!closeEnough(h, expectedH)) {
      differences.push(`sample ${index}: h ${h} != ${expectedH}`);
    }
    if (!closeEnough(v, expectedV)) {
      differences.push(`sample ${index}: v ${v} != ${expectedV}`);
    }
  }
}

if (differences.length > 0) {
  console.error("the C reference host no longer matches the baseline:");
  for (const difference of differences) {
    console.error(`  ${difference}`);
  }
  process.exit(1);
}

console.log(`reference host matches the baseline: ${expected.samples.length} samples`);
