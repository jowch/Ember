// docs/packages.md, "Install checks": an install stopped by the
// system-library check reaches the Packages tab as a card that shows the
// libraries, the command to run, what to do without admin rights, and
// Try again.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, runCell } from "../browser.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const INSTALLER = path.join(HERE, "..", "..", "testthat", "fixtures", "missing-system-installer.R");

test("failing.R: a missing system library shows the command and Try again", async (t) => {
  const notebook = tempNotebook("failing.R");
  const server = await startServer([notebook], {
    installerScript: INSTALLER,
    logFile: path.join(artifactsDir(), "install-missing.server.log"),
  });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await runCell(page, "S");

  await page.getByRole("button", { name: "Packages", exact: true }).click();
  await page.waitForSelector(".ember-install-failure-card", { timeout: 30000 });

  const sentence = await page.locator(".ember-install-failure-sentence").innerText();
  assert.match(sentence, /system libraries that aren't installed: libbroken\.so\.1/);

  const command = await page.locator(".ember-install-failure-command").innerText();
  assert.equal(command.trim(), "sudo apt-get install -y libbroken-dev");
  const fixes = await page.locator(".ember-install-failure-fix").allInnerTexts();
  assert.ok(fixes.some((text) => /ask its administrator/.test(text)));

  assert.equal(await page.locator(".ember-install-failure-card button", { hasText: "Try again" }).count(), 1);

  assertNoProblems(page);
});
