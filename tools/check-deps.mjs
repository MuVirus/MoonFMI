#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

/**
 * The dependency direction from docs/design/architecture.md section 3.1.
 * Keep this table in sync with the document.
 */
const allowed = {
  "src/zip": [],
  "src/xml": [],
  "src/schema": ["src/xml"],
  "src/fmi": ["src/schema", "src/zip"],
  "src/backend/native": ["src/fmi"],
  "src/backend/wasm": ["src/fmi"],
  "src/sim": ["src/fmi"],
  "src/export": ["src/schema", "src/zip"],
  "src/cli": [
    "src/zip",
    "src/xml",
    "src/schema",
    "src/fmi",
    "src/backend/native",
    "src/backend/wasm",
    "src/sim",
    "src/export",
  ],
};

const targetRules = {
  "src/backend/native": "native",
  "src/backend/wasm": "wasm",
};

function readPackageConfig(dir) {
  const file = path.join(root, dir, "moon.pkg");
  if (!fs.existsSync(file)) {
    return null;
  }
  return fs.readFileSync(file, "utf8");
}

function importedPackages(text) {
  const result = [];
  const re = /"MuVirus\/MoonFMI\/(src\/[^"]+)"/g;
  let match;
  while ((match = re.exec(text)) !== null) {
    result.push(match[1]);
  }
  return result;
}

function checkGraph(graph) {
  const errors = [];

  for (const [from, deps] of Object.entries(graph)) {
    if (!(from in allowed)) {
      errors.push(`${from}: unknown package (add it to tools/check-deps.mjs)`);
      continue;
    }

    for (const to of deps) {
      if (!allowed[from].includes(to)) {
        errors.push(
          `${from} imports ${to}, but the allowed directions are: ${
            allowed[from].length === 0 ? "(none)" : allowed[from].join(", ")
          }`,
        );
      }
    }
  }

  return errors;
}

function readGraph() {
  const graph = {};

  for (const dir of Object.keys(allowed)) {
    const config = readPackageConfig(dir);
    if (config === null) {
      graph[dir] = [];
      continue;
    }

    graph[dir] = importedPackages(config);

    for (const [targetDir, target] of Object.entries(targetRules)) {
      if (dir === targetDir && !new RegExp(`supported_targets\\s*=\\s*"${target}"`).test(config)) {
        console.error(
          `${targetDir}: moon.pkg must contain supported_targets = "${target}"`,
        );
        process.exitCode = 1;
      }
    }

    if (!(dir in targetRules) && /supported_targets\s*=/.test(config)) {
      console.error(
        `${dir}: core packages must stay target-neutral; do not set supported_targets here`,
      );
      process.exitCode = 1;
    }
  }

  return graph;
}

function selfTest() {
  const errors = checkGraph({
    "src/zip": ["src/schema"],
    "src/xml": [],
    "src/schema": ["src/xml"],
    "src/fmi": ["src/schema", "src/zip"],
    "src/backend/native": ["src/fmi"],
    "src/backend/wasm": ["src/fmi"],
    "src/sim": ["src/fmi"],
    "src/export": ["src/schema", "src/zip"],
    "src/cli": ["src/sim", "src/export"],
  });
  const hit = errors.some((line) => line.includes("src/zip imports src/schema"));
  if (!hit) {
    console.error("self-test failed: reverse dependency was not detected");
    process.exit(1);
  }
  console.log("dependency checker self-test passed");
}

if (process.argv.includes("--self-test")) {
  selfTest();
  process.exit(0);
}

const graph = readGraph();
const errors = checkGraph(graph);

if (errors.length > 0) {
  console.error("Dependency check failed:");
  for (const error of errors) {
    console.error(`  ${error}`);
  }
  process.exit(1);
}

console.log(`dependency check passed (${Object.keys(graph).length} packages)`);
