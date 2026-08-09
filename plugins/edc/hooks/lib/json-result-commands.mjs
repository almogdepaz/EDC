import { existsSync, lstatSync, mkdirSync, readFileSync, realpathSync, renameSync, statSync, writeFileSync } from "node:fs";
import { dirname, relative } from "node:path";

function die(message, code = 1) {
  console.error(message);
  process.exit(code);
}

function readJson(path) {
  return JSON.parse(readFileSync(path, "utf8"));
}

function writeJsonFileAtomic(path, value) {
  mkdirSync(dirname(path), { recursive: true });
  const tmp = `${path}.${process.pid}.tmp`;
  writeFileSync(tmp, `${JSON.stringify(value, null, 2)}\n`);
  renameSync(tmp, path);
}

function validateStagedOutput(args) {
  const [path, allowedRoot] = args;
  let rootReal;
  let pathReal;
  let linkStat;
  let fileStat;
  try {
    rootReal = realpathSync(allowedRoot);
    linkStat = lstatSync(path);
    pathReal = realpathSync(path);
    fileStat = statSync(path);
  } catch (error) {
    die(`staged output validation failed: ${error.message}`);
  }
  const rel = relative(rootReal, pathReal);
  if (linkStat.isSymbolicLink() || !fileStat.isFile() || fileStat.nlink !== 1 || rel === ".." || rel.startsWith(`..${process.platform === "win32" ? "\\" : "/"}`)) {
    die(`staged output is not a private, single-link regular file: ${path}`);
  }
}

function inferResultStatus(exitCode, reasonCode) {
  if (Number(exitCode) !== 0) return "failed";
  return reasonCode === "success-with-warning" ? "success-with-warning" : "success";
}

function resultOutputs(result) {
  const outputs = Array.isArray(result.outputs) ? result.outputs.filter((item) => typeof item === "string" && item.length > 0) : [];
  if (typeof result.finalReview === "string" && result.finalReview.length > 0 && !outputs.includes(result.finalReview)) {
    outputs.push(result.finalReview);
  }
  return outputs;
}

function normalizeReviewAllPhase(phase, resultFile, childExitCode) {
  const childRc = Number(childExitCode);
  if (!existsSync(resultFile)) {
    return {
      phase,
      status: "failed",
      exitCode: childRc === 0 ? 1 : childRc,
      reasonCode: `${phase}-result-missing`,
      message: `${phase} phase did not write a result file`,
      hint: `inspect the ${phase} phase log output; durable result validation could not run`,
      resultFile,
      childExitCode: childRc,
    };
  }

  let result;
  try {
    result = readJson(resultFile);
  } catch {
    return {
      phase,
      status: "failed",
      exitCode: childRc === 0 ? 1 : childRc,
      reasonCode: `${phase}-result-invalid`,
      message: `${phase} phase wrote an invalid result file`,
      hint: `inspect ${resultFile}; it must be valid JSON`,
      resultFile,
      childExitCode: childRc,
    };
  }

  const resultExitCode = Number(result.exitCode ?? childRc);
  let status = typeof result.status === "string" ? result.status : inferResultStatus(resultExitCode, result.reasonCode);
  if (!new Set(["success", "failed", "success-with-warning"]).has(status)) status = inferResultStatus(resultExitCode, result.reasonCode);
  if (childRc !== 0 && resultExitCode === 0 && status === "success") status = "success-with-warning";

  return {
    phase,
    status,
    exitCode: resultExitCode,
    reasonCode: result.reasonCode || inferResultStatus(resultExitCode, result.reasonCode),
    message: result.message || result.failureReason || `${phase} phase ${status}`,
    hint: result.hint || result.failureHint || "",
    outputs: resultOutputs(result),
    details: result.details || {},
    resultFile,
    childExitCode: childRc,
  };
}

function formatPhaseLine(phase) {
  const suffix = phase.outputs?.length > 0 ? ` -> ${phase.outputs.join(", ")}` : "";
  return `- ${phase.phase}: ${phase.status}${suffix}`;
}

function applyResultScope(result) {
  if (process.env.EDC_RESULT_SCOPE) result.scope = process.env.EDC_RESULT_SCOPE;
  if (process.env.EDC_RESULT_BASE) result.base = process.env.EDC_RESULT_BASE;
  if (process.env.EDC_RESULT_TARGET) result.target = process.env.EDC_RESULT_TARGET;
  if (process.env.EDC_RESULT_CANDIDATE_KIND) result.candidateKind = process.env.EDC_RESULT_CANDIDATE_KIND;
  if (process.env.EDC_RESULT_CANDIDATE_COMMIT) result.candidateCommit = process.env.EDC_RESULT_CANDIDATE_COMMIT;
  if (process.env.EDC_RESULT_DIRTY_TRACKED_INCLUDED) result.dirtyTrackedIncluded = process.env.EDC_RESULT_DIRTY_TRACKED_INCLUDED === "1";
  if (process.env.EDC_RESULT_UNTRACKED_INCLUDED) result.untrackedIncluded = process.env.EDC_RESULT_UNTRACKED_INCLUDED === "1";
}

function printReviewAllSummary(result) {
  if (result.status === "failed") {
    console.log("EDC review failed.");
    console.log("");
    console.log(`failed phase: ${result.failedPhase}`);
    console.log(`reason: ${result.message}`);
    console.log(`code: ${result.reasonCode}`);
    if (result.hint) console.log(`next step: ${result.hint}`);
    console.log("");
    console.log("phases:");
    for (const phase of result.phases) console.log(formatPhaseLine(phase));
    return;
  }

  console.log(result.status === "success-with-warning" ? "EDC review succeeded with warning." : "EDC review succeeded.");
  console.log("");
  console.log("phases:");
  for (const phase of result.phases) console.log(formatPhaseLine(phase));
}

function writeResult(args) {
  const [path, kind, exitCode, reasonCode, failureReason, failureHint, failedModule, finalReview, startedHead, finishedHead] = args;
  const numericExitCode = Number(exitCode);
  const status = inferResultStatus(numericExitCode, reasonCode);
  const result = {
    schemaVersion: 1,
    kind,
    phase: kind,
    status,
    exitCode: numericExitCode,
    reasonCode,
    message: failureReason || `${kind} ${status}`,
    finishedAt: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
  };
  if (failureReason && status === "failed") result.failureReason = failureReason;
  if (failureHint) {
    result.hint = failureHint;
    if (status === "failed") result.failureHint = failureHint;
  }
  if (process.env.EDC_RESULT_DETAILS_JSON) {
    try { result.details = JSON.parse(process.env.EDC_RESULT_DETAILS_JSON); } catch {}
  }
  if (failedModule) result.failedModule = failedModule;
  if (finalReview) {
    result.finalReview = finalReview;
    result.outputs = [finalReview];
  } else if (["build", "update", "context-recovery"].includes(kind)) {
    result.outputs = ["edc-context/manifest.json", "edc-context/index.md", "edc-context/modules/"];
  } else if (kind === "audit") {
    result.outputs = ["edc-context/reports/issues.md", "edc-context/reports/complexity.md"];
  } else {
    result.outputs = [];
  }
  if (["build", "update", "context-recovery"].includes(kind) && status !== "failed") {
    result.checks = [{ name: "edc-doctor", status: "success", message: "ok" }];
  }
  if (startedHead) result.startedHead = startedHead;
  if (finishedHead) result.finishedHead = finishedHead;
  applyResultScope(result);
  writeJsonFileAtomic(path, result);
}

function aggregateReviewAll(args) {
  const [path, startedHead, finishedHead, ...phaseArgs] = args;
  if (phaseArgs.length === 0 || phaseArgs.length % 3 !== 0) die("review-all-aggregate requires phase/result/exit triples", 64);
  const phases = [];
  for (let index = 0; index < phaseArgs.length; index += 3) {
    phases.push(normalizeReviewAllPhase(phaseArgs[index], phaseArgs[index + 1], phaseArgs[index + 2]));
  }
  const failed = phases.find((phase) => phase.status === "failed" || Number(phase.exitCode) !== 0);
  const warning = phases.some((phase) => phase.status === "success-with-warning");
  const status = failed ? "failed" : warning ? "success-with-warning" : "success";
  const outputs = [...new Set(phases.flatMap((phase) => phase.outputs || []))];
  const result = {
    schemaVersion: 1,
    kind: "review-all",
    phase: "review-all",
    status,
    exitCode: failed ? 1 : 0,
    reasonCode: failed ? failed.reasonCode : warning ? "success-with-warning" : "success",
    message: failed ? failed.message : status === "success-with-warning" ? "review-all completed with warnings" : "review-all completed successfully",
    hint: failed ? failed.hint : warning ? "inspect warning phase logs for transport/provider diagnostics" : "",
    outputs,
    phases,
    finishedAt: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
  };
  if (startedHead) result.startedHead = startedHead;
  if (finishedHead) result.finishedHead = finishedHead;
  applyResultScope(result);
  if (failed) {
    result.failedPhase = failed.phase;
    result.failureReason = failed.message;
    result.failureHint = failed.hint;
    result.childResult = failed.resultFile;
    if (failed.details && Object.keys(failed.details).length > 0) result.details = failed.details;
  }
  writeJsonFileAtomic(path, result);
  printReviewAllSummary(result);
  process.exit(result.exitCode);
}

export function dispatchResultCommand(cmd, args) {
  switch (cmd) {
    case "result-write":
      writeResult(args);
      return true;
    case "review-phase-status": {
      const [phase, resultFile, childExitCode] = args;
      process.stdout.write(normalizeReviewAllPhase(phase, resultFile, childExitCode).status);
      return true;
    }
    case "validate-staged-output":
      validateStagedOutput(args);
      return true;
    case "review-all-aggregate":
      aggregateReviewAll(args);
      return true;
    default:
      return false;
  }
}
