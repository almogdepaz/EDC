import { execFileSync } from "node:child_process";
import { getContextFreshness } from "../../plugins/edc/hooks/lib/route.mjs";
import { argTokens } from "./args.mjs";

const LOCAL_GIT_TIMEOUT_MS = 10000;

export const DIRTY_REVIEW_MENU = Object.freeze({
  INCLUDE: "review complete working tree (staged, unstaged, deleted, and untracked)",
  COMMITTED: "review committed changes only (exclude all working-tree changes)",
  CANCEL: "cancel",
});

function reviewSkipsContextPrompt(args) {
  const tokens = argTokens(args);
  return tokens.includes("--no-context-refresh") || tokens.includes("--ignore-context");
}

function gitRefExists(cwd, ref) {
  try {
    execFileSync("git", ["rev-parse", "--verify", `${ref}^{commit}`], {
      cwd,
      timeout: LOCAL_GIT_TIMEOUT_MS,
      stdio: ["ignore", "ignore", "ignore"],
    });
    return true;
  } catch {
    return false;
  }
}

export function detectDefaultBaseRef(cwd) {
  try {
    const remoteHead = execFileSync("git", ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], {
      cwd,
      timeout: LOCAL_GIT_TIMEOUT_MS,
      encoding: "utf-8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
    if (remoteHead && gitRefExists(cwd, remoteHead)) return remoteHead;
  } catch {
    // origin/HEAD is optional in local/test repos.
  }

  for (const ref of ["main", "master", "origin/main", "origin/master"]) {
    if (gitRefExists(cwd, ref)) return ref;
  }

  return "main";
}

export function defaultBaseReviewArgs(cwd) {
  return ["HEAD", "--base", detectDefaultBaseRef(cwd)];
}

export function defaultBaseUpdateArgs(cwd) {
  return ["--base", detectDefaultBaseRef(cwd)];
}

function operationalUntracked(path) {
  return path === ".edc" || path.startsWith(".edc/") || path === ".edc.install.lock" || path.startsWith(".edc.install.lock/")
    || path === "edc-context" || path.startsWith("edc-context/")
    || /^review-[^/]+\.md$/.test(path) || /^delivery-review-[^/]+\.md$/.test(path);
}

export function hasReviewableWorkingTreeChanges(cwd) {
  try {
    execFileSync("git", ["diff", "--quiet", "HEAD", "--"], {
      cwd,
      timeout: LOCAL_GIT_TIMEOUT_MS,
      stdio: ["ignore", "ignore", "ignore"],
    });
  } catch (error) {
    if (Number(error?.status) === 1) return true;
    return false;
  }

  try {
    const untracked = execFileSync("git", ["ls-files", "--others", "--exclude-standard", "-z"], {
      cwd,
      timeout: LOCAL_GIT_TIMEOUT_MS,
      encoding: "utf-8",
      stdio: ["ignore", "pipe", "ignore"],
    }).split("\0").filter(Boolean);
    return untracked.some((path) => !operationalUntracked(path));
  } catch {
    return false;
  }
}

export async function applyDirtyReviewPolicy(args, ctx) {
  const tokens = argTokens(args);
  if (tokens.includes("--full") || tokens.includes("--include-working-tree") || tokens.includes("--committed-only")) {
    return { args: tokens };
  }
  if (!hasReviewableWorkingTreeChanges(ctx.cwd)) return { args: tokens };
  if (!ctx.ui?.select || ctx.hasUI === false) return { args: tokens };

  const choice = await ctx.ui.select("working tree has uncommitted reviewable changes", [
    DIRTY_REVIEW_MENU.INCLUDE,
    DIRTY_REVIEW_MENU.COMMITTED,
    DIRTY_REVIEW_MENU.CANCEL,
  ]);
  if (choice === DIRTY_REVIEW_MENU.CANCEL || !choice) return { cancelled: true };
  if (choice === DIRTY_REVIEW_MENU.COMMITTED) return { args: [...tokens, "--committed-only"] };
  if (choice === DIRTY_REVIEW_MENU.INCLUDE) {
    const resolved = [...tokens];
    if (resolved.length > 0 && !resolved[0].startsWith("--")) resolved[0] = "HEAD";
    else resolved.unshift("HEAD");
    return { args: [...resolved, "--include-working-tree"] };
  }
  return { cancelled: true };
}

function commitDistance(cwd, sourceCommit, headCommit) {
  if (!sourceCommit || !headCommit) return "unknown";
  try {
    return execFileSync("git", ["rev-list", "--count", `${sourceCommit}..${headCommit}`], {
      cwd,
      timeout: LOCAL_GIT_TIMEOUT_MS,
      encoding: "utf-8",
    }).trim() || "0";
  } catch {
    return "unknown";
  }
}

export function reviewContextSummary(ctx, freshness = getContextFreshness(ctx.cwd)) {
  switch (freshness.state) {
    case "fresh":
      return "EDC context: fresh.";
    case "missing":
      return [
        "EDC context: missing/incomplete.",
        `reason: ${freshness.reason || "unknown"}`,
        "review will build context before reviewing unless you pass --no-context-refresh or --ignore-context.",
      ].join("\n");
    case "stale": {
      const source = String(freshness.sourceCommit || "unknown");
      const head = String(freshness.headCommit || "unknown");
      const behind = commitDistance(ctx.cwd, freshness.sourceCommit, freshness.headCommit);
      return [
        "EDC context: stale.",
        `built at: ${source.slice(0, 8)}`,
        `HEAD: ${head.slice(0, 8)}`,
        `behind by: ${behind} commit${behind === "1" ? "" : "s"}`,
        "review will update context before reviewing unless you pass --no-context-refresh or --ignore-context.",
      ].join("\n");
    }
    case "unknown":
      return ["EDC context: unknown.", `reason: ${freshness.reason || "unknown"}`].join("\n");
    default:
      return `EDC context: ${freshness.state || "unknown"}.`;
  }
}

export async function shouldProceedWithReview(args, ctx, freshness = getContextFreshness(ctx.cwd)) {
  if (reviewSkipsContextPrompt(args)) return true;
  if (freshness.state !== "missing" && freshness.state !== "stale") return true;
  if (!ctx.ui?.confirm || ctx.hasUI === false) return true;

  const action = freshness.state === "missing" ? "build" : "update";
  return ctx.ui.confirm(
    `EDC context ${freshness.state}`,
    `${reviewContextSummary(ctx, freshness)}\n\nRun edc ${action} before reviewing? This may spawn agent subprocesses and can take several minutes.`,
  );
}

function canonicalReviewCli(commandName, args, scope = "") {
  const tokens = argTokens(args);
  if (scope === "full" || tokens.includes("--full")) return `edc ${commandName} full --agent pi`;
  const baseIndex = tokens.indexOf("--base");
  const base = baseIndex >= 0 ? tokens[baseIndex + 1] : "<base>";
  return `edc ${commandName} diff ${base || "<base>"} --agent pi`;
}

export function reviewDeclinedMessage(args, commandName = "review", scope = "") {
  const canonical = canonicalReviewCli(commandName, args, scope);
  const directBase = canonicalReviewCli("security", args, scope);
  return [
    "Review cancelled; EDC context was not refreshed.",
    "",
    "Refresh context, then rerun:",
    `\`${canonical}\``,
    "",
    "Security-only direct review can skip context refresh:",
    `\`${directBase} --no-context-refresh\``,
    "",
    "Or ignore existing context entirely:",
    `\`${directBase} --ignore-context\``,
  ].join("\n");
}
