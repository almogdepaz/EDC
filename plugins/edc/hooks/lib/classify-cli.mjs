#!/usr/bin/env node
import { readFileSync } from "node:fs";
import { stdin, stderr } from "node:process";
import { classifyPathSync, InvalidGlobPatternError, validateClassifierGlobs } from "./route.mjs";

function usage() {
  stderr.write("usage: classify-cli.mjs [--ignore <glob>]... <manifest-path>\n");
  process.exit(64);
}

function reportClassifierError(error) {
  if (!(error instanceof InvalidGlobPatternError)) return false;
  stderr.write(`classify-cli: ${error.message}\n`);
  return true;
}

const ignorePatterns = [];
const args = process.argv.slice(2);
while (args.length > 0) {
  const arg = args[0];
  if (arg === "--ignore") {
    if (args.length < 2) usage();
    ignorePatterns.push(args[1]);
    args.splice(0, 2);
    continue;
  }
  if (arg === "--") {
    args.shift();
    break;
  }
  if (arg.startsWith("-")) usage();
  break;
}

if (args.length !== 1) usage();

let manifest;
try {
  manifest = JSON.parse(readFileSync(args[0], "utf-8"));
} catch (error) {
  stderr.write(`classify-cli: could not read manifest ${args[0]}: ${error.message}\n`);
  process.exit(64);
}

try {
  validateClassifierGlobs(manifest, ignorePatterns);
} catch (error) {
  if (reportClassifierError(error)) process.exit(1);
  throw error;
}

let input = "";
stdin.setEncoding("utf-8");
stdin.on("data", (chunk) => {
  input += chunk;
});
stdin.on("end", () => {
  let output = "";
  try {
    for (const path of input.split(/\r?\n/)) {
      if (path.length === 0) continue;
      output += `${path}\t${classifyPathSync(manifest, path, ignorePatterns)}\n`;
    }
  } catch (error) {
    if (reportClassifierError(error)) {
      process.exitCode = 1;
      return;
    }
    throw error;
  }
  process.stdout.write(output);
});
