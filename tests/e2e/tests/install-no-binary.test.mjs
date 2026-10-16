// docs/packages.md, "Install checks" (#19): a package that failed to build
// and had no binary for this R (an old snapshot date) reaches the Packages
// tab as a card that says why it was built, what to do, and offers Update.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, runCell } from "../browser.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const INSTALLER = path.join(HERE, "..", "..", "testthat", "fixtures", "no-binary-installer.R");

test("failing.R: a build with no binary for this R says why and offers Update", async (t) => {
  const notebook = tempNotebook("failing.R");
  const server = await startServer([notebook], {
    installerScript: INSTALLER,
    logFile: path.join(artifactsDir(), "install-no-binary.server.log"),
  });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await runCell(page, "S");

  await page.getByRole("button", { name: "Packages", exact: true }).click();
  await page.waitForSelector(".ember-install-failure-card", { timeout: 30000 });

  const sentence = await page.locator(".ember-install-failure-sentence").innerText();
  assert.match(sentence, /no binary of version 0\.1\.0 for R \S+ at this snapshot date/);
  const fix = await page.locator(".ember-install-failure-fix").innerText();
  assert.match(fix, /Update moves the packages to a newer date/);

  assert.equal(await page.locator(".ember-install-failure-card button", { hasText: "Update" }).count(), 1);
  assert.equal(await page.locator(".ember-install-failure-card button", { hasText: "Try again" }).count(), 0);

  assertNoProblems(page);
});
