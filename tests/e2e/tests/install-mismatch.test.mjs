// #76: binaries that don't fit this system reach the Packages tab. toyA,
// the package failing-dep.R loads, was built for a newer system; toyB, its
// dependency, against another version of a library. One card, toyA's,
// says both, says the install command would install the version already here, and offers
// Try again (for once the right version is installed) but no command.
// The toy CRAN repository is a file:// fixture, so nothing touches the
// network.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, runCell } from "../browser.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const FIXTURES = path.join(HERE, "..", "..", "testthat", "fixtures");
const INSTALLER = path.join(FIXTURES, "mismatch-installer.R");
const REPOS = {
  cran: `file://${path.join(FIXTURES, "repos", "toy")}`,
  bioc_config: null,
};

test("failing-dep.R: a binary built for a newer system, and one against another library version", async (t) => {
  const notebook = tempNotebook("failing-dep.R");
  const server = await startServer([notebook], {
    repos: REPOS,
    installerScript: INSTALLER,
    logFile: path.join(artifactsDir(), "install-mismatch.server.log"),
  });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await runCell(page, "S");

  await page.getByRole("button", { name: "Packages", exact: true }).click();
  // toyB folds into toyA's card once the index the failure asked for arrives.
  const card = page.locator(".ember-install-failure-card", { hasText: "toyA couldn't install" });
  await card.locator(".ember-install-failure-sentence", { hasText: "toyB" }).waitFor({ timeout: 0 });
  assert.deepEqual(await card.locator(".ember-install-failure-sentence").allInnerTexts(), [
    "It was built for a newer system than this one, and needs GLIBC_2.38 from libraries here that are older (/lib/x86_64-linux-gnu/libc.so.6).",
    "A package it needs, toyB 1.0, was built against libtoy.so.1, and this system has libtoy.so.2 instead.",
  ]);
  const fixes = await card.locator(".ember-install-failure-fix").allInnerTexts();
  assert.ok(fixes.some((text) => /The install command would install the version already here/.test(text)));
  assert.ok(fixes.some((text) => /conda or a loaded module/.test(text)));
  assert.equal(await card.locator(".ember-install-failure-command").count(), 0);
  assert.equal(await card.locator("button", { hasText: "Try again" }).count(), 1);
  assert.equal(await card.locator("button", { hasText: "Update" }).count(), 0);
  assert.equal(await page.locator(".ember-install-failure-card").count(), 1);

  assertNoProblems(page);
});
