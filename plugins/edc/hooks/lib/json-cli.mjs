#!/usr/bin/env node
import { readFileSync, writeFileSync, appendFileSync, mkdirSync } from "node:fs";
import { basename, dirname } from "node:path";

function die(message, code = 1) {
  console.error(message);
  process.exit(code);
}

function readStdin() {
  return readFileSync(0, "utf8");
}

function parseJsonText(text, label = "input") {
  try {
    return JSON.parse(text);
  } catch {
    die(`${label} is not valid JSON`);
  }
}

function readJson(path) {
  return parseJsonText(readFileSync(path, "utf8"), path);
}

function writeJson(value) {
  process.stdout.write(`${JSON.stringify(value, null, 2)}\n`);
}

function hasOwn(obj, key) {
  return Object.prototype.hasOwnProperty.call(obj, key);
}

function array(value) {
  return Array.isArray(value) ? value : [];
}

function lines(text) {
  return text.split(/\r?\n/).filter((line) => line.length > 0);
}

function kebab(value) {
  return String(value).replace(/[_ ]+/g, "-").toLowerCase();
}

function manifestReject(message) {
  die(`edc-manifest: ${message}`);
}

function buildPlanReject(message) {
  die(`edc-build-plan: ${message}`);
}

function validateManifestInput(input) {
  for (const field of ["schemaVersion", "edcVersion", "repoContextFile", "reports", "build", "policy", "modules"]) {
    if (!hasOwn(input, field)) manifestReject(`missing required field: ${field}`);
  }
  if (!input.unmapped || !Array.isArray(input.unmapped.allowedGlobs)) {
    manifestReject("missing required field: unmapped.allowedGlobs");
  }
  if (!Array.isArray(input.modules) || input.modules.length === 0) {
    manifestReject("modules must be a non-empty array");
  }
  if (input.contextless?.entries !== undefined && !Array.isArray(input.contextless.entries)) {
    manifestReject("contextless.entries must be an array when present");
  }

  const invalidContextless = array(input.contextless?.entries)
    .filter((entry) => {
      const validId = typeof entry.id === "string" && /^[a-z0-9]+(-[a-z0-9]+)*$/.test(entry.id);
      const validGlobs = Array.isArray(entry.globs) && entry.globs.length > 0;
      const validReason = typeof entry.reason === "string" && entry.reason.length > 0;
      const validPolicy = ["account-only", "promotion-check", "no-context-review"].includes(entry.reviewPolicy);
      return !validId || !validGlobs || !validReason || !validPolicy;
    })
    .map((entry) => entry.id || "<missing-id>");
  if (invalidContextless.length > 0) {
    manifestReject(`contextless.entries invalid id/globs/reason/reviewPolicy: ${invalidContextless.join(",")}`);
  }

  if (!input.policy || !hasOwn(input.policy, "defaultMode")) manifestReject("missing policy.defaultMode");
  if (!hasOwn(input.policy, "unmatchedPathPolicy")) manifestReject("missing policy.unmatchedPathPolicy");
  if (!["advisory", "inject"].includes(input.policy.defaultMode)) {
    manifestReject(`policy.defaultMode must be one of: advisory, inject (got: ${input.policy.defaultMode})`);
  }

  const missingPriority = input.modules
    .filter((module) => !hasOwn(module, "priority"))
    .map((module) => module.name || "<unnamed>");
  if (missingPriority.length > 0) manifestReject(`modules missing priority: ${missingPriority.join(",")}`);

  if (hasOwn(input, "generatedAt")) manifestReject("generatedAt must not be authored by the LLM; the post-step fills it");
  if (hasOwn(input, "sourceCommit")) manifestReject("sourceCommit must not be authored by the LLM; the post-step fills it");
  if (hasOwn(input, "coverage") && input.coverage && Object.keys(input.coverage).length !== 0) {
    manifestReject("coverage.* must not be authored by the LLM; the post-step fills it");
  }
}

function reviewManifestModuleFromMeta(line, filesDir) {
  const [index, name, type = "module", policy = "", contextlessId = "", doc = ""] = line.split("\t");
  const files = lines(readFileSync(`${filesDir}/${index}.files`, "utf8"));
  const module = { name, doc, files };
  if (type === "contextless") {
    module.type = "contextless";
    module.contextlessId = contextlessId;
    module.reviewPolicy = policy;
  } else if (type === "unmapped") {
    module.type = "uncovered";
  }
  return module;
}

function readableError(value) {
  if (typeof value === "string") {
    try {
      const parsed = JSON.parse(value);
      return parsed?.error?.message || parsed?.message || value;
    } catch {
      return value;
    }
  }
  if (value && typeof value === "object") {
    return value.error?.message || value.message || JSON.stringify(value);
  }
  return String(value);
}

function command() {
  const [cmd, ...args] = process.argv.slice(2);
  switch (cmd) {
    case "valid-json": {
      parseJsonText(readFileSync(args[0], "utf8"), args[0]);
      return;
    }
    case "schema-version-is-2": {
      const json = readJson(args[0]);
      process.exit(json.schemaVersion === 2 ? 0 : 1);
    }
    case "mode-get": {
      const json = readJson(args[0]);
      process.stdout.write(json.policy?.defaultMode || "");
      return;
    }
    case "mode-set": {
      const [path, mode] = args;
      const json = readJson(path);
      json.policy ||= {};
      json.policy.defaultMode = mode;
      writeJson(json);
      return;
    }
    case "doctor": {
      const json = readJson(args[0]);
      if (json.schemaVersion !== 2) console.log("FAIL\tmanifest schemaVersion must equal 2");
      if (!["advisory", "inject"].includes(json.policy?.defaultMode)) console.log("FAIL\tpolicy.defaultMode must be advisory or inject");
      if (!["warn-allow", "allow", "fail"].includes(json.policy?.unmatchedPathPolicy)) console.log("FAIL\tpolicy.unmatchedPathPolicy must be warn-allow, allow, or fail");
      for (const module of array(json.modules)) if (module.doc) console.log(`DOC\t${module.doc}`);
      for (const glob of array(json.coverage?.ignoreGlobs)) if (glob) console.log(`IGNORE\t${glob}`);
      return;
    }
    case "manifest-finalize": {
      const [generatedAt, sourceCommit, ignoreSource, contextMapped, contextless, uncovered, ambiguous, ignored, ...ignoreGlobs] = args;
      const input = parseJsonText(readStdin(), "input");
      validateManifestInput(input);
      const legacyUnmapped = Number(contextless) + Number(uncovered);
      input.generatedAt = generatedAt;
      input.sourceCommit = sourceCommit;
      input.coverage = {
        contextMappedFileCount: Number(contextMapped),
        contextlessFileCount: Number(contextless),
        uncoveredFileCount: Number(uncovered),
        ambiguousPathCount: Number(ambiguous),
        ignoredFileCount: Number(ignored),
        ignoreSource,
        ignoreGlobs,
        mappedFileCount: Number(contextMapped),
        unmappedFileCount: legacyUnmapped,
      };
      writeJson(input);
      return;
    }
    case "build-plan": {
      const [modulesDir, changedFilter = ""] = args;
      const input = parseJsonText(readStdin(), "input");
      if (!hasOwn(input, "modules")) buildPlanReject("missing required field: modules");
      if (!Array.isArray(input.modules) || input.modules.length === 0) buildPlanReject("modules must be a non-empty array");
      const invalid = input.modules.filter((module) => !hasOwn(module, "name") || !hasOwn(module, "paths")).map((module) => module.name || "<unnamed>");
      if (invalid.length > 0) buildPlanReject(`modules missing required fields (name/paths): ${invalid.join("\n")}`);
      const seen = new Set();
      const duplicates = [];
      for (const module of input.modules) {
        if (seen.has(module.name)) duplicates.push(module.name);
        seen.add(module.name);
      }
      if (duplicates.length > 0) buildPlanReject(`duplicate module names: ${duplicates.join("\n")}`);
      const allowed = changedFilter ? changedFilter.split(",") : [];
      for (const name of allowed) if (!seen.has(name)) buildPlanReject(`--changed references unknown module: ${name}`);
      const modules = allowed.length > 0 ? input.modules.filter((module) => allowed.includes(module.name)) : input.modules;
      writeJson({
        tasks: modules.map((module) => ({
          kind: "module-context",
          module: module.name,
          paths: module.paths,
          out: `${modulesDir}/${kebab(module.name)}.md`,
          prompt: `Build deep architectural context for module \`${module.name}\`. Files in scope: \`${array(module.paths).join(", ")}\`. Invoke the \`edc-module-context-impl\` skill on these files. You may read sibling-module source if it materially improves this module's context. Write distilled high-signal context directly to \`${modulesDir}/${kebab(module.name)}.md\`; include decision-useful read boundaries and source-truth pointers for exact details, but do not dump scratch analysis, empty template sections, or obvious code inventory. Return a ≤500-token summary for the orchestrator.`,
        })),
      });
      return;
    }
    case "audit-modules": {
      const json = readJson(args[0]);
      for (const module of array(json.modules)) {
        if ((module.type || "module") === "module") console.log(`${module.name}\t${module.doc}`);
      }
      return;
    }
    case "review-target": {
      const json = readJson(args[0]);
      if (!json.target) process.exit(1);
      process.stdout.write(json.target);
      return;
    }
    case "review-modules": {
      const json = readJson(args[0]);
      for (const module of array(json.modules)) if (module.name) console.log(module.name);
      return;
    }
    case "review-context-mode": {
      const json = readJson(args[0]);
      process.stdout.write(json.contextMode || "context");
      return;
    }
    case "unmatched-policy": {
      const json = readJson(args[0]);
      process.stdout.write(json.policy?.unmatchedPathPolicy || "warn-allow");
      return;
    }
    case "review-direct-manifest": {
      const [target, baseline, head, contextMode, module] = args;
      writeJson({ target, baseline, head, contextMode, modules: [{ name: module, doc: "", files: lines(readStdin()) }] });
      return;
    }
    case "review-routed-manifest": {
      const [target, baseline, head, contextMode, metaPath, filesDir] = args;
      const modules = lines(readFileSync(metaPath, "utf8")).map((line) => reviewManifestModuleFromMeta(line, filesDir));
      writeJson({ target, baseline, head, contextMode, modules });
      return;
    }
    case "result-write": {
      const [path, kind, exitCode, reasonCode, failureReason, failureHint, failedModule, finalReview, startedHead, finishedHead] = args;
      const result = {
        kind,
        exitCode: Number(exitCode),
        reasonCode,
        finishedAt: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
      };
      if (failureReason) result.failureReason = failureReason;
      if (failureHint) result.failureHint = failureHint;
      if (failedModule) result.failedModule = failedModule;
      if (finalReview) result.finalReview = finalReview;
      if (startedHead) result.startedHead = startedHead;
      if (finishedHead) result.finishedHead = finishedHead;
      mkdirSync(dirname(path), { recursive: true });
      writeFileSync(path, `${JSON.stringify(result, null, 2)}\n`);
      return;
    }
    case "spawn-metrics": {
      const [phase, backend, modelRequested, duration, capture, logPath] = args;
      const captureLines = lines(readFileSync(capture, "utf8"));
      const resultLine = [...captureLines].reverse().find((line) => line.includes('"type":"result"'));
      if (!resultLine) return;
      let result;
      try { result = JSON.parse(resultLine); } catch { return; }
      let init = null;
      const initLine = captureLines.find((line) => line.includes('"type":"system"'));
      if (initLine) { try { init = JSON.parse(initLine); } catch {} }
      const rec = {
        ts: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
        phase,
        backend,
        session_id: result.session_id ?? null,
        model_requested: modelRequested || null,
        model_observed: init?.model ?? result.model ?? null,
        duration_s: Number(duration),
        num_turns: result.num_turns ?? null,
        input_tokens: result.usage?.input_tokens ?? 0,
        output_tokens: result.usage?.output_tokens ?? 0,
        cache_read_tokens: result.usage?.cache_read_input_tokens ?? 0,
        cache_write_tokens: result.usage?.cache_creation_input_tokens ?? 0,
        total_cost_usd: result.total_cost_usd ?? null,
      };
      appendFileSync(logPath, `${JSON.stringify(rec)}\n`);
      if (rec.model_requested && rec.model_observed && !String(rec.model_observed).includes(rec.model_requested)) {
        console.error(`WARNING: model_observed='${rec.model_observed}' does not match model_requested='${rec.model_requested}' (phase=${phase})`);
      }
      return;
    }
    case "readable-error": {
      process.stdout.write(readableError(parseJsonText(readStdin(), "input")));
      return;
    }
    default:
      die(`usage: ${basename(process.argv[1])} <command> [...]`, 64);
  }
}

command();
