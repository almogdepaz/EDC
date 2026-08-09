export function formatBackgroundElapsed(status, now = Date.now()) {
  const startedAt = Date.parse(status.started_at || "");
  if (!Number.isFinite(startedAt)) return "";

  const finishedAt = Date.parse(status.finished_at || "");
  const end = Number.isFinite(finishedAt) ? finishedAt : now;
  const elapsedSeconds = Math.max(0, Math.floor((end - startedAt) / 1000));
  if (elapsedSeconds < 60) return `${elapsedSeconds}s`;

  const elapsedMinutes = Math.floor(elapsedSeconds / 60);
  if (elapsedMinutes < 60) return `${elapsedMinutes}m`;

  const elapsedHours = Math.floor(elapsedMinutes / 60);
  const remainingMinutes = elapsedMinutes % 60;
  return `${elapsedHours}h ${remainingMinutes}m`;
}

export function renderBackgroundFooterStatus(status) {
  const kind = status.kind || "review";
  if (status.status === "running") {
    const elapsed = formatBackgroundElapsed(status);
    return `edc ${kind}: running${elapsed ? ` ${elapsed}` : ""}`;
  }
  if (status.status === "success") return `edc ${kind}: ✓ complete`;
  if (status.status === "failed") return `edc ${kind}: ✗ failed`;
  return `edc ${kind}: ${status.status || "unknown"}`;
}

export function backgroundJobStartedMessage(result) {
  const kind = result.kind || "job";
  return [
    `Background EDC ${kind} started.`,
    "",
    `Run ID: ${result.runId}`,
    `PID: ${result.pid}`,
    result.logFile ? `Log: ${result.logFile}` : "",
  ].filter(Boolean).join("\n");
}

export function backgroundJobAlreadyRunningMessage(result) {
  const kind = result.status?.kind || "job";
  return [
    `A background EDC ${kind} is already running for this repo.`,
    "",
    `Run ID: ${result.runId}`,
    result.status?.log ? `Log: ${result.status.log}` : "",
    "",
    "Check progress: `/edc` → Job status.",
  ].filter(Boolean).join("\n");
}
