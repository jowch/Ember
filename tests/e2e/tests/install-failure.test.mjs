// Piece 4 (docs/ui-3-plan.md, "4. Notebooks and packages from the
// browser"), docs/ui-3-tests.md item 99: a real install failure, through
// the failing-installer fixture, reaches the Packages tab as a card.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, runCell } from "../browser.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const FAILING_INSTALLER = path.join(HERE, "..", "..", "testthat", "fixtures", "failing-installer.R");

// 99. failing.R: run; the Packages tab shows "brokenpkg couldn't install"
// with the build sentence; "Show the error" shows text containing
// "compilation failed".
test('failing.R: the Packages tab shows a failure card with "Show the error" (99)', async (t) => {
  const notebook = tempNotebook("failing.R");
  const server = await startServer([notebook], {
    installerScript: FAILING_INSTALLER,
    logFile: path.join(artifactsDir(), "install-failure-99.server.log"),
  });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await runCell(page, "S");

  await page.getByRole("button", { name: "Packages", exact: true }).click();
  await page.waitForSelector(".ember-install-failure-card", { timeout: 30000 });

  const title = await page.locator(".ember-install-failure-title").innerText();
  assert.match(title, /brokenpkg couldn't install/);

  const sentence = await page.locator(".ember-install-failure-sentence").innerText();
  assert.match(sentence, /doesn't build on R/);

  await page.locator(".ember-install-failure-card button", { hasText: "Show the error" }).click();
  const log = await page.locator(".ember-install-failure-log").innerText();
  assert.match(log, /compilation failed/);

  assertNoProblems(page);
});
