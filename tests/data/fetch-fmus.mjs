#!/usr/bin/env node

/**
 * Download and verify the P0 test FMUs.
 *
 * The FMU files are deliberately not stored in git. This script keeps a
 * local cache under tests/data/.cache and verifies every byte against
 * tests/data/manifest.json.
 *
 * Usage:
 *   node tests/data/fetch-fmus.mjs            # download if needed, then verify
 *   node tests/data/fetch-fmus.mjs --offline  # never download; verify cache only
 *   node tests/data/fetch-fmus.mjs --force    # discard cache and download again
 *   node tests/data/fetch-fmus.mjs --list     # print sample ids
 */

import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const manifestPath = path.join(here, "manifest.json");
const cacheDir = path.join(here, ".cache");
const archivePath = path.join(cacheDir, "Reference-FMUs.zip");
const extractDir = path.join(cacheDir, "extract");

const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
const args = new Set(process.argv.slice(2));

if (args.has("--list")) {
  for (const sample of manifest.samples) {
    console.log(`${sample.id}\t${sample.fmiVersion}\t${sample.interfaces.join(",")}\t${sample.archivePath}`);
  }
  process.exit(0);
}

function sha256(file) {
  const hash = crypto.createHash("sha256");
  hash.update(fs.readFileSync(file));
  return hash.digest("hex");
}

function verifyFile(file, expectedHash, expectedBytes) {
  if (!fs.existsSync(file)) {
    return `missing: ${path.relative(here, file)}`;
  }
  const actualBytes = fs.statSync(file).size;
  if (actualBytes !== expectedBytes) {
    return `size mismatch: ${path.relative(here, file)} (expected ${expectedBytes}, got ${actualBytes})`;
  }
  const actualHash = sha256(file);
  if (actualHash !== expectedHash) {
    return `sha256 mismatch: ${path.relative(here, file)} (expected ${expectedHash}, got ${actualHash})`;
  }
  return null;
}

function verifyAll() {
  const errors = [];
  for (const sample of manifest.samples) {
    const file = path.join(cacheDir, sample.cachePath);
    const error = verifyFile(file, sample.sha256, sample.bytes);
    if (error !== null) {
      errors.push(error);
    }
  }
  return errors;
}

async function download(url, destination) {
  process.stdout.write(`downloading ${url}\n`);
  const response = await fetch(url, { redirect: "follow" });
  if (!response.ok) {
    throw new Error(`download failed: HTTP ${response.status} ${response.statusText}`);
  }
  const bytes = Buffer.from(await response.arrayBuffer());
  fs.writeFileSync(destination, bytes);
  process.stdout.write(`downloaded ${bytes.length} bytes\n`);
}

function extractSelected() {
  fs.rmSync(extractDir, { recursive: true, force: true });
  fs.mkdirSync(extractDir, { recursive: true });

  const entries = manifest.samples.map((sample) => sample.archivePath);
  const isWindows = process.platform === "win32";
  const command = isWindows ? "tar" : "unzip";
  const commandArgs = isWindows
    ? ["-xf", archivePath, "-C", extractDir, ...entries]
    : ["-o", archivePath, ...entries, "-d", extractDir];

  const result = spawnSync(command, commandArgs, { stdio: "inherit" });
  if (result.error) {
    throw new Error(`cannot run ${command}: ${result.error.message}`);
  }
  if (result.status !== 0) {
    throw new Error(`${command} failed with exit code ${result.status}`);
  }

  for (const sample of manifest.samples) {
    const source = path.join(extractDir, ...sample.archivePath.split("/"));
    const destination = path.join(cacheDir, ...sample.cachePath.split("/"));
    fs.mkdirSync(path.dirname(destination), { recursive: true });
    fs.copyFileSync(source, destination);
  }

  fs.rmSync(extractDir, { recursive: true, force: true });
}

async function main() {
  fs.mkdirSync(cacheDir, { recursive: true });

  const offline = args.has("--offline");
  const force = args.has("--force");

  if (force) {
    fs.rmSync(cacheDir, { recursive: true, force: true });
    fs.mkdirSync(cacheDir, { recursive: true });
  }

  let errors = verifyAll();
  if (errors.length === 0) {
    console.log(`all ${manifest.samples.length} test FMUs are present and verified`);
    return;
  }

  if (offline) {
    console.error("cache is incomplete or corrupt:");
    for (const error of errors) console.error(`  ${error}`);
    console.error("run without --offline to download the samples");
    process.exit(1);
  }

  const archiveError = verifyFile(
    archivePath,
    manifest.bundle.sha256,
    manifest.bundle.bytes,
  );
  if (archiveError !== null) {
    if (fs.existsSync(archivePath)) {
      console.log(`cached archive is invalid (${archiveError}); downloading again`);
    }
    await download(manifest.bundle.url, archivePath);
  }

  const archiveHash = sha256(archivePath);
  if (archiveHash !== manifest.bundle.sha256) {
    fs.rmSync(archivePath, { force: true });
    throw new Error(
      `bundle sha256 mismatch: expected ${manifest.bundle.sha256}, got ${archiveHash}`,
    );
  }

  extractSelected();
  errors = verifyAll();
  if (errors.length > 0) {
    for (const error of errors) console.error(`  ${error}`);
    throw new Error("one or more test FMUs failed verification");
  }

  console.log(`all ${manifest.samples.length} test FMUs are present and verified`);
}

main().catch((error) => {
  console.error(`error: ${error.message}`);
  process.exit(1);
});
