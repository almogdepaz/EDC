type RawStatus = "queued" | "running" | "done" | "failed";

export function parseJobStatus(value: string): RawStatus {
  if (value === "queued" || value === "running" || value === "done" || value === "failed") return value;
  throw new Error(`invalid job status ${value}`);
}

export function parseWorkerStatus(value: string): RawStatus {
  if (value === "queued" || value === "running" || value === "done" || value === "failed") return value;
  throw new Error(`invalid worker status ${value}`);
}

export function isTerminalStatus(value: string): boolean {
  return value === "done" || value === "failed";
}
