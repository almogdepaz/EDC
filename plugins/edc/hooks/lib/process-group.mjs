import { spawn } from "node:child_process";

export function spawnProcessGroup(command, args, options = {}) {
  return spawn(command, args, { ...options, detached: true });
}

export function processGroupIsRunning(child) {
  if (!child?.pid) return false;
  try {
    process.kill(-child.pid, 0);
    return true;
  } catch (error) {
    if (error?.code !== "EPERM") return false;
    return child.exitCode === null && child.signalCode === null;
  }
}

export function signalProcessGroup(child, signal) {
  if (!child?.pid) return false;
  try {
    process.kill(-child.pid, signal);
    return true;
  } catch (error) {
    if (error?.code === "ESRCH") return false;
    if (error?.code === "EPERM") {
      if (child.exitCode !== null || child.signalCode !== null) return false;
      return child.kill(signal);
    }
    throw error;
  }
}
