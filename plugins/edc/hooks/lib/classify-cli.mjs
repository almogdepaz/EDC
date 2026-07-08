#!/usr/bin/env node
import { readFileSync } from "node:fs";
import { stdin, stderr } from "node:process";
import { classifyPathSync } from "./route.mjs";

function usage() {
  stderr.write("usage: classify-cli.mjs [--ignore <glob>]... <manifest-path>\n");
  process.exit(64);
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

let input = "";
stdin.setEncoding("utf-8");
stdin.on("data", (chunk) => {
  input += chunk;
});
stdin.on("end", () => {
  for (const path of input.split(/\r?\n/)) {
    if (path.length === 0) continue;
    process.stdout.write(`${path}\t${classifyPathSync(manifest, path, ignorePatterns)}\n`);
  }
});
