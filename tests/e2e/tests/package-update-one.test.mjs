// #23: a row whose package CRAN has a newer version of says so, with an
// Update that shows what moving the notebook's date changes before
// anything does. failing-dep.R has toyA 0.1 at 2026-09-01; toy-meta is
// CRAN's index of its files for toyA (0.2 out on 2026-09-30). The toy
// repository and that index are file:// fixtures, so nothing touches the
// network, and no cell runs, so nothing installs.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook } from "../browser.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const FIXTURES = path.join(HERE, "..", "..", "testthat", "fixtures");
const REPOS = {
  cran: `file://${path.join(FIXTURES, "repos", "toy")}`,
  cran_meta: `file://${path.join(FIXTURES, "repos", "toy-meta")}`,
  bioc_config: null,
};

test("packages tab: a row's Update says what moving the date changes, then moves it (#23)", async (t) => {
  const notebook = tempNotebook("failing-dep.R");
  const server = await startServer([notebook], {
    repos: REPOS,
    logFile: path.join(artifactsDir(), "package-update-one.server.log"),
  });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.getByRole("button", { name: "Packages", exact: true }).click();

  const row = page.locator(".ember-package-row", { has: page.locator("td", { hasText: /^toyA$/ }) });
  const available = row.locator(".ember-package-available");
  await available.waitFor();
  assert.equal((await available.innerText()).replace(/\s+/g, " ").trim(), "0.2 available · Update");

  await row.getByRole("button", { name: "Update toyA to 0.2" }).click();
  const question = page.locator(".ember-package-update-question");
  await question.waitFor();
  assert.equal(
    (await question.innerText()).trim(),
    "Updating toyA to 0.2 moves the notebook's date to 2026-09-30. No other package changes."
  );
  // Nothing has moved yet, and the row's own Update is gone while it asks.
  assert.equal(await page.locator(".ember-packages-title").innerText(), "Versions as of 2026-09-01");
  assert.equal(await row.getByRole("button", { name: "Update toyA to 0.2" }).count(), 0);

  await page.locator(".ember-package-update").getByRole("button", { name: "Update toyA" }).click();
  await page.locator(".ember-packages-title", { hasText: "Versions as of 2026-09-30" }).waitFor();
  await row.locator("td", { hasText: /^0\.2/ }).waitFor();
  await available.waitFor({ state: "detached" });
  assert.equal(await page.locator(".ember-package-update").count(), 0);

  assertNoProblems(page);
});

test("packages tab: Cancel on a row's Update leaves the notebook where it was (#23)", async (t) => {
  const notebook = tempNotebook("failing-dep.R");
  const server = await startServer([notebook], {
    repos: REPOS,
    logFile: path.join(artifactsDir(), "package-update-one-cancel.server.log"),
  });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.getByRole("button", { name: "Packages", exact: true }).click();

  const row = page.locator(".ember-package-row", { has: page.locator("td", { hasText: /^toyA$/ }) });
  await row.getByRole("button", { name: "Update toyA to 0.2" }).click();
  const detail = page.locator(".ember-package-update");
  await detail.locator(".ember-package-update-question").waitFor();
  await detail.getByRole("button", { name: "Cancel" }).click();
  await detail.waitFor({ state: "detached" });
  await row.getByRole("button", { name: "Update toyA to 0.2" }).waitFor();
  assert.equal(await page.locator(".ember-packages-title").innerText(), "Versions as of 2026-09-01");

  assertNoProblems(page);
});
