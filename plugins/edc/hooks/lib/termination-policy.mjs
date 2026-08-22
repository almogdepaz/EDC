export const SUBPROCESS_TERMINATION_GRACE_MS = 1000;
export const WORKER_PROCESS_GROUP_TERMINATION_GRACE_MS = SUBPROCESS_TERMINATION_GRACE_MS;
// Keep the worker pool alive for one full child grace window after its own
// escalation deadline so it can reap nested detached groups before Pi exits.
export const BACKGROUND_JOB_SUPERVISOR_MARGIN_MS = 1000;
export const BACKGROUND_JOB_TERMINATION_GRACE_MS =
  WORKER_PROCESS_GROUP_TERMINATION_GRACE_MS + BACKGROUND_JOB_SUPERVISOR_MARGIN_MS;
