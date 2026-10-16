// #17: a notebook opened with its lock never resolves, so no package index
// is loaded when its install fails. The failure fetches the index, so a
// failed dependency still points back at the package the notebook loads:
// toyB's card says toyA needs it, and toyA's row reads failed. The toy
// CRAN repository is a file:// fixture, so nothing touches the network.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, runCell } from "../browser.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const FIXTURES = path.join(HERE, "..", "..", "testthat", "fixtures");
const INSTALLER = path.join(FIXTURES, "failing-dep-installer.R");
const REPOS = {
  cran: `file://${path.join(FIXTURES, "repos", "toy")}`,
  bioc_config: null,
};

test("failing-dep.R: a locked notebook's failed dependency names the package that needs it", async (t) => {
  const notebook = tempNotebook("failing-dep.R");
  const server = await startServer([notebook], {
    repos: REPOS,
    installerScript: INSTALLER,
    logFile: path.join(artifactsDir(), "install-failure-needed-by.server.log"),
  });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await runCell(page, "S");

  await page.getByRole("button", { name: "Packages", exact: true }).click();
  const card = page.locator(".ember-install-failure-card", { hasText: "toyB couldn't install" });
  // The line appears once the index the failure asked for arrives.
  await card.locator(".ember-install-failure-needed-by").waitFor({ timeout: 30000 });
  assert.equal(await card.locator(".ember-install-failure-needed-by").innerText(), "Needed by toyA.");
  await page.locator("tr.ember-package-row.ember-package-failed", { hasText: "toyA" }).waitFor({ timeout: 10000 });

  assertNoProblems(page);
});
