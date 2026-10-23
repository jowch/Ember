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
  await page.waitForSelector(".ember-install-failure-card");

  const sentence = await page.locator(".ember-install-failure-sentence").innerText();
  assert.match(sentence, /no binary of version 0\.1\.0 for R \S+, so it was built on this computer/);
  assert.match(sentence, /the snapshot date is older than this R/);
  const fix = await page.locator(".ember-install-failure-fix").innerText();
  assert.match(fix, /Update moves the packages to a newer date/);

  assert.equal(await page.locator(".ember-install-failure-card button", { hasText: "Update" }).count(), 1);
  assert.equal(await page.locator(".ember-install-failure-card button", { hasText: "Try again" }).count(), 0);

  assertNoProblems(page);
});

const NOTICE_INSTALLER = path.join(HERE, "..", "..", "testthat", "fixtures", "no-binary-notice-installer.R");

test("failing.R: packages with no binary for this R are named under Installing while they build", async (t) => {
  const notebook = tempNotebook("failing.R");
  const server = await startServer([notebook], {
    installerScript: NOTICE_INSTALLER,
    logFile: path.join(artifactsDir(), "install-no-binary-notice.server.log"),
  });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await runCell(page, "S");

  await page.getByRole("button", { name: "Packages", exact: true }).click();
  const notice = page.locator(".ember-packages-library-installing .ember-packages-no-binary");
  await notice.waitFor();

  const text = await notice.innerText();
  assert.match(text, /^2 packages have no binary for R \S+ at this snapshot date, so they're being built on this computer: brokenpkg 0\.1\.0 and rlang 1\.1\.3\./);
  assert.match(text, /Update moves the packages to a newer date/);
  // A notice, not a stop: no card, and Update is the header's.
  assert.equal(await page.locator(".ember-install-failure-card, .ember-install-ask-card").count(), 0);
  assert.equal(await page.locator(".ember-packages-update button", { hasText: "Update" }).count(), 1);

  assertNoProblems(page);
});
