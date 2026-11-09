import assert from "node:assert/strict";
import test from "node:test";
import { createLoader } from "../src/loader.mjs";

function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

test("current success publishes data and clears loading", async () => {
  const loader = createLoader();
  const response = deferred();
  const run = loader.load(() => response.promise);
  assert.equal(loader.snapshot().loading, true);
  response.resolve("A");
  await run;
  assert.deepEqual(loader.snapshot(), { data: "A", error: null, loading: false, panelOpen: false });
});

test("cancellation clears loading before the response arrives", () => {
  const loader = createLoader();
  loader.load(() => new Promise(() => {}));
  loader.cancel();
  assert.equal(loader.snapshot().loading, false);
});

test("retry after current failure clears the error and publishes new data", async () => {
  const loader = createLoader();
  await loader.load(() => Promise.reject(new Error("offline")));
  assert.equal(loader.snapshot().error, "offline");
  assert.equal(loader.snapshot().loading, false);
  await loader.load(() => Promise.resolve("retry"));
  assert.equal(loader.snapshot().error, null);
  assert.equal(loader.snapshot().data, "retry");
});

for (const event of ["resolve", "reject"]) {
  test(`late ${event} from cancelled A cannot clear pending B loading`, async () => {
    const loader = createLoader();
    const a = deferred();
    const b = deferred();
    const runA = loader.load(() => a.promise);
    loader.cancel();
    const runB = loader.load(() => b.promise);
    if (event === "resolve") a.resolve("stale A");
    else a.reject(new Error("stale A failure"));
    await runA;
    assert.deepEqual(loader.snapshot(), { data: null, error: null, loading: true, panelOpen: false });
    b.resolve("B");
    await runB;
    assert.deepEqual(loader.snapshot(), { data: "B", error: null, loading: false, panelOpen: false });
  });
}

test("panelOpen and loading vary independently without changing request ownership", async () => {
  const loader = createLoader();
  loader.setPanelOpen(true);
  const response = deferred();
  const run = loader.load(() => response.promise);
  assert.equal(loader.snapshot().panelOpen, true);
  assert.equal(loader.snapshot().loading, true);
  loader.setPanelOpen(false);
  assert.equal(loader.snapshot().loading, true);
  response.resolve("visible");
  await run;
  assert.equal(loader.snapshot().panelOpen, false);
  assert.equal(loader.snapshot().loading, false);
  loader.setPanelOpen(true);
  assert.equal(loader.snapshot().loading, false);
});
