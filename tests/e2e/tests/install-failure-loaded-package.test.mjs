// #17: a notebook opened with its lock never resolves, so no package index
// is loaded when its install fails. The failure fetches the index, so a
// failed dependency still points back at the package the notebook loads.
// #91: the card is then the loaded package's, toyA's, and names toyB in
// its sentence; toyA's row reads failed. The toy CRAN repository is a
// file:// fixture, so nothing touches the network.

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

test("failing-dep.R: a locked notebook's failed dependency shows on the card of the package that needs it", async (t) => {
  const notebook = tempNotebook("failing-dep.R");
  const server = await startServer([notebook], {
    repos: REPOS,
    installerScript: INSTALLER,
    logFile: path.join(artifactsDir(), "install-failure-loaded-package.server.log"),
  });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await runCell(page, "S");

  await page.getByRole("button", { name: "Packages", exact: true }).click();
  // toyA's card appears once the index the failure asked for arrives.
  const card = page.locator(".ember-install-failure-card", { hasText: "toyA couldn't install" });
  await card.waitFor();
  const sentences = await card.locator(".ember-install-failure-sentence").allInnerTexts();
  assert.equal(sentences.length, 1);
  assert.match(sentences[0], /^A package it needs, toyB 1\.0, doesn't build on R \S+\.$/);
  assert.equal(await card.locator("button", { hasText: "Update" }).count(), 1);
  assert.equal(await page.locator(".ember-install-failure-card").count(), 1);
  await page.locator("tr.ember-package-row.ember-package-failed", { hasText: "toyA" }).waitFor();

  assertNoProblems(page);
});
