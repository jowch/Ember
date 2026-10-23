// #106: the failure card's Try again retries the install. Before, it ran
// only the cells that hadn't run, and after a failed install every cell
// had (library(toyA) had stopped on a package that isn't installed), so
// nothing happened. The fixture installer fails once, the way the
// system-library check does, then installs for real from the toy file://
// repository, as if the user had installed what was missing in between.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, runCell, cellSelector } from "../browser.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const FIXTURES = path.join(HERE, "..", "..", "testthat", "fixtures");
const INSTALLER = path.join(FIXTURES, "fail-once-installer.R");
const REPOS = {
  cran: `file://${path.join(FIXTURES, "repos", "toy")}`,
  bioc_config: null,
};

test("failing-dep.R: Try again on the failure card retries the install and reruns the cell", async (t) => {
  const notebook = tempNotebook("failing-dep.R");
  const server = await startServer([notebook], {
    repos: REPOS,
    installerScript: INSTALLER,
    logFile: path.join(artifactsDir(), "install-retry.server.log"),
  });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await runCell(page, "S");
  await page.locator(`${cellSelector("S")}.errored`).waitFor();

  await page.getByRole("button", { name: "Packages", exact: true }).click();
  const card = page.locator(".ember-install-failure-card", { hasText: "toyA couldn't install" });
  await card.waitFor();
  await card.getByRole("button", { name: "Try again" }).click();

  // The install runs again, the card goes, and library(toyA) runs clean.
  await page.locator(".ember-install-failure-card").waitFor({ state: "detached" });
  await page.waitForFunction((sel) => {
    const cell = document.querySelector(sel);
    return cell != null && !cell.classList.contains("errored") && !cell.classList.contains("queued") && !cell.classList.contains("running");
  }, cellSelector("S"));
  assert.equal(await page.locator(".ember-install-failure-card").count(), 0);

  assertNoProblems(page);
});
