// #38: the Packages tab says how much disk the libraries, the package cache
// and the indexes use, measured by the server when the tab opens. It only
// reports; nothing is deleted.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook } from "../browser.mjs";

test("packages tab: a line gives the disk use of the libraries, the cache and the indexes (#38)", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "disk-use.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.getByRole("button", { name: "Packages", exact: true }).click();

  const line = page.locator("#ember-packages-tab .ember-packages-disk-use");
  await page.waitForFunction(
    () => /^Disk use for all notebooks:/.test(document.querySelector("#ember-packages-tab .ember-packages-disk-use")?.innerText ?? ""),
    null, { timeout: 30000 });
  assert.match(await line.innerText(),
    /^Disk use for all notebooks: libraries [\d.,]+ [KMGT]?B, package cache [\d.,]+ [KMGT]?B, indexes [\d.,]+ [KMGT]?B\. /);

  assertNoProblems(page);
});
