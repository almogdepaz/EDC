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
