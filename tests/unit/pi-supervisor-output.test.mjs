import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { setTimeout as delay } from "node:timers/promises";
import test from "node:test";

const supervisor = fileURLToPath(new URL("../../plugins/edc/hooks/lib/pi-supervisor.mjs", import.meta.url));
const emitter = `
  const fs = require("node:fs");
  fs.writeFileSync(process.argv[2], String(process.pid));
  process.stdout.write(fs.readFileSync(process.argv[1]));
  setInterval(() => {}, 1000);
`;

async function fixture(t, {
  size = 2 * 1024 * 1024, stopReason = "stop", pipeline = false, errorMessage, consumeStderr = true,
} = {}) {
  const directory = await mkdtemp(join(tmpdir(), "edc-pi-output-"));
  const input = join(directory, "input.jsonl");
  const pidFile = join(directory, "emitter.pid");
  const expected = Buffer.from(`${JSON.stringify({
    type: "agent_end",
    messages: [{ role: "assistant", stopReason, errorMessage, content: [{ type: "text", text: "x".repeat(size) }] }],
  })}\n`);
  await writeFile(input, expected);
  const capture = join(directory, "captured.jsonl");
  const library = fileURLToPath(new URL("../../plugins/edc/scripts/edc-lib.sh", import.meta.url));
  const child = pipeline
    ? spawn("bash", ["-c", `source "$1"; EDC_AGENT_CLI=pi;
        edc_run_filtered_stream 10 output-test "$2" synthetic stdin-null "" "$3" "$4" "$3" -e "$5" "$6" "$7"`,
      "output-test", library, capture, process.execPath, supervisor, emitter, input, pidFile], {
      cwd: directory, env: { ...process.env, EDC_CONFIG_FILE: "/dev/null" }, stdio: ["ignore", "pipe", "pipe"],
    })
    : spawn(process.execPath, [supervisor, process.execPath, "-e", emitter, input, pidFile], {
      stdio: ["ignore", "pipe", "pipe"],
    });
  let errors = "";
  if (consumeStderr) child.stderr.setEncoding("utf8").on("data", (chunk) => { errors += chunk; });
  const exited = new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("exit", (code, signal) => resolve({ code, signal }));
  });
  const watchdog = setTimeout(() => child.kill("SIGKILL"), 8000);
  t.after(async () => {
    child.stdout.destroy();
    child.stderr.destroy();
    if (child.exitCode === null && child.signalCode === null) child.kill("SIGTERM");
    try {
      const pid = Number(await readFile(pidFile, "utf8"));
      try { process.kill(-pid, "SIGKILL"); } catch (error) { if (error.code !== "ESRCH") throw error; }
    } catch (error) { if (error.code !== "ENOENT") throw error; }
    await exited;
    clearTimeout(watchdog);
    await rm(directory, { recursive: true, force: true });
  });
  // readable fills Node's buffer without draining the pipe. The terminal event
  // exceeds both buffers, so the supervisor must retain queued output.
  if (!pipeline) {
    await new Promise((resolve, reject) => {
      child.stdout.once("readable", resolve);
      child.stdout.once("error", reject);
      child.stdout.once("end", () => reject(new Error("supervisor emitted no data")));
    });
  }
  return { child, exited, expected, pidFile, capture, errors: () => errors };
}

async function waitForEmitterExit(pidFile) {
  const pid = Number(await readFile(pidFile, "utf8"));
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    try { process.kill(pid, 0); } catch (error) {
      if (error.code === "ESRCH") return;
      throw error;
    }
    await delay(5);
  }
  throw new Error("supervised emitter did not exit");
}

async function collect(stream) {
  const chunks = [];
  for await (const chunk of stream) chunks.push(chunk);
  return Buffer.concat(chunks);
}

for (const stopReason of ["stop", "error"]) {
  test(`Pi supervisor preserves a large terminal ${stopReason} event under backpressure`, { timeout: 10000 }, async (t) => {
    const f = await fixture(t, { stopReason });
    // Deliberately model a temporarily stalled reader. The assertion is byte
    // equality, not how quickly the child exits. A permanently stalled reader
    // has separate bounded-failure coverage below.
    await Promise.race([f.exited, delay(200)]);
    const actual = await collect(f.child.stdout);
    const result = await f.exited;
    assert.equal(result.code, stopReason === "stop" ? 0 : 1, f.errors());
    assert.equal(actual.length, f.expected.length, "terminal transcript was truncated");
    assert.deepEqual(actual, f.expected);
    assert.equal(JSON.parse(actual).type, "agent_end");
  });
}

test("Pi supervisor drains a large error diagnostic after temporary stderr backpressure", { timeout: 10000 }, async (t) => {
  const errorMessage = "diagnostic-".repeat(256 * 1024);
  const f = await fixture(t, { size: 0, stopReason: "error", errorMessage, consumeStderr: false });
  const output = collect(f.child.stdout);
  await Promise.race([f.exited, delay(200)]);
  const diagnostic = await collect(f.child.stderr);
  const result = await f.exited;
  assert.equal(result.signal, null);
  assert.equal(result.code, 1);
  const expectedDiagnostic = Buffer.from(`ERROR: pi subprocess: ${errorMessage}\n`);
  assert.equal(diagnostic.length, expectedDiagnostic.length, "error diagnostic was truncated");
  assert.deepEqual(diagnostic, expectedDiagnostic);
  assert.deepEqual(await output, f.expected);
  await waitForEmitterExit(f.pidFile);
});

test("Pi supervisor bounds shutdown when only stderr remains blocked", { timeout: 10000 }, async (t) => {
  const errorMessage = "diagnostic-".repeat(256 * 1024);
  const f = await fixture(t, { size: 0, stopReason: "error", errorMessage, consumeStderr: false });
  const output = collect(f.child.stdout);
  const result = await f.exited; // Keep stderr blocked until the bounded exit.
  const diagnostic = await collect(f.child.stderr);
  assert.equal(result.signal, null, "external watchdog had to kill the supervisor");
  assert.equal(result.code, 1);
  assert.deepEqual(await output, f.expected);
  assert.ok(diagnostic.length < Buffer.byteLength(errorMessage));
  await waitForEmitterExit(f.pidFile);
});

test("Pi supervisor fails when stderr breaks after managed-child cleanup", { timeout: 10000 }, async (t) => {
  const f = await fixture(t, {
    size: 0, stopReason: "error", errorMessage: "diagnostic-".repeat(256 * 1024), consumeStderr: false,
  });
  f.child.stdout.resume();
  await waitForEmitterExit(f.pidFile);
  f.child.stderr.destroy();
  const result = await f.exited;
  assert.equal(result.signal, null);
  assert.equal(result.code, 1);
});

test("Pi supervisor preserves the full terminal event through the real filtered capture pipeline", { timeout: 12000 }, async (t) => {
  const f = await fixture(t, { pipeline: true });
  await collect(f.child.stdout);
  const result = await f.exited;
  assert.equal(result.code, 0, f.errors());
  assert.deepEqual(await readFile(f.capture), f.expected);
});

test("Pi supervisor fails rather than succeeding or hanging on a permanently blocked reader", { timeout: 10000 }, async (t) => {
  const f = await fixture(t);
  const result = await f.exited; // Do not consume stdout until the exit is observed.
  const actual = await collect(f.child.stdout);
  assert.equal(result.signal, null, "external watchdog had to kill the supervisor");
  assert.equal(result.code, 1, "incomplete output must not report success");
  assert.ok(actual.length < f.expected.length);
  assert.match(f.errors(), /output.*drain|drain.*output/i);
});

test("Pi supervisor treats a broken output pipe after terminal success as failure", { timeout: 10000 }, async (t) => {
  const f = await fixture(t);
  f.child.stdout.destroy();
  const result = await f.exited;
  assert.equal(result.signal, null);
  assert.equal(result.code, 1);
});

for (const [signal, code] of [["SIGTERM", 143], ["SIGINT", 130], ["SIGHUP", 129]]) {
  test(`Pi supervisor respects ${signal} during output drain`, { timeout: 10000 }, async (t) => {
    const f = await fixture(t);
    // Ensure the child has stopped before signalling its output-draining parent.
    // This probes the second shutdown phase, not ordinary signal forwarding.
    await waitForEmitterExit(f.pidFile);
    f.child.kill(signal);
    const result = await f.exited;
    await collect(f.child.stdout);
    assert.equal(result.signal, null);
    assert.equal(result.code, code);
  });
}
