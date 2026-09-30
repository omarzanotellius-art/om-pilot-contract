#!/usr/bin/env node
// Evidence bundles — fingerprint a folder of evidence files (spec §10).
//
//   node scripts/evidence.mjs bundle <folder>
//       Fingerprints every file in <folder> with SHA-256, writes <folder>/manifest.json
//       in one fixed format, and prints the manifest's fingerprint — the value that
//       goes on-chain.
//
//   node scripts/evidence.mjs check <file> <manifest.json>
//       Confirms one file is listed in the manifest with the same fingerprint, and
//       prints the manifest's fingerprint to compare with the contract's verifyRecord.
//
// Plain Node.js, no dependencies. The same files always give the same manifest:
// files are sorted by name, there are no dates, and the format never changes.
// Only the folder's top level is read; hidden files and manifest.json are skipped.

import { createHash } from "node:crypto";
import { readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { basename, join } from "node:path";

const MANIFEST = "manifest.json";

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

/** The exact bytes of a manifest: fixed format, so the fingerprint is reproducible. */
function manifestBytes(files) {
  return Buffer.from(JSON.stringify({ files }, null, 2) + "\n", "utf8");
}

function bundle(folder) {
  const names = readdirSync(folder)
    .filter((n) => !n.startsWith(".") && n !== MANIFEST && statSync(join(folder, n)).isFile())
    .sort();
  if (names.length === 0) throw new Error(`no evidence files in ${folder}`);
  const files = names.map((name) => ({ name, sha256: sha256(readFileSync(join(folder, name))) }));
  const bytes = manifestBytes(files);
  writeFileSync(join(folder, MANIFEST), bytes);
  for (const f of files) console.log(`  ${f.sha256}  ${f.name}`);
  console.log(`manifest: ${join(folder, MANIFEST)}`);
  console.log(`fingerprint (on-chain): 0x${sha256(bytes)}`);
}

function check(file, manifestPath) {
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  const name = basename(file);
  const actual = sha256(readFileSync(file));
  const listed = manifest.files.find((f) => f.name === name);
  if (!listed) {
    console.log(`NOT LISTED: ${name} is not in ${manifestPath}`);
    process.exitCode = 1;
  } else if (listed.sha256 !== actual) {
    console.log(`MISMATCH: ${name} differs from the version in the manifest`);
    process.exitCode = 1;
  } else {
    console.log(`MATCH: ${name} is exactly the file listed in the manifest`);
  }
  console.log(`manifest fingerprint: 0x${sha256(readFileSync(manifestPath))}`);
  console.log("Compare it with verifyRecord(entry, fingerprint) on the contract.");
}

const [command, a, b] = process.argv.slice(2);
if (command === "bundle" && a) bundle(a);
else if (command === "check" && a && b) check(a, b);
else {
  console.log("usage:\n  node scripts/evidence.mjs bundle <folder>\n  node scripts/evidence.mjs check <file> <manifest.json>");
  process.exitCode = 2;
}
