// #38: the Packages tab says how much disk the libraries, the package cache
// and the indexes use, measured by the server when the tab opens. It only
// reports; nothing is deleted.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { startServer, tempNotebook, artifactsDir, tempDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook } from "../browser.mjs";

/** A cache folder of the test's own, one file in each part. Not the shared
 * cache: every other server in the run installs into that one, and its size
 * is whatever this machine has gathered (#327). */
function seedCache() {
  const root = tempDir("ember-e2e-disk-use-");
  for (const [dir, bytes] of [["libraries/R-4.6/testplat/key", 300000], ["renv-cache/v5/pkg", 200000], ["indexes", 100000]]) {
    mkdirSync(path.join(root, dir), { recursive: true });
    writeFileSync(path.join(root, dir, "file"), Buffer.alloc(bytes));
  }
  return root;
}

test("packages tab: a line gives the disk use of the libraries, the cache and the indexes (#38)", async (t) => {
  const cache = seedCache();
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { cacheDir: cache, logFile: path.join(artifactsDir(), "disk-use.server.log") });
  const browser = await launchBrowser();
  t.after(async () => {
    await browser.close();
    await server.stop();
    rmSync(cache, { recursive: true, force: true });
  });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.getByRole("button", { name: "Packages", exact: true }).click();

  // The line says "Measuring disk use…" until the reply, then the use or
  // "Couldn't measure disk use."; a timeout says which it was.
  const line = page.locator("#ember-packages-tab .ember-packages-disk-use");
  await page.waitForFunction(
    () => !/^Measuring/.test(document.querySelector("#ember-packages-tab .ember-packages-disk-use")?.innerText ?? "Measuring"),
    null, { timeout: 30000 }).catch(async (e) => { throw new Error(`${e.message}; the line says: ${await line.innerText()}`); });
  assert.match(await line.innerText(),
    /^Disk use for all notebooks: libraries 3\d\d KB, package cache 2\d\d KB, indexes 1\d\d KB\. /);

  assertNoProblems(page);
});
