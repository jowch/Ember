// #78: a package that isn't found gets a GitHub source from its row in the
// Packages tab. A typo stays on the row with the reason; fixing it (with a
// link pasted from the browser, #85) locks the package from GitHub, saved
// as a github: source; Remove source sends it back to not found. The
// notebook resolves against the toy CRAN repository and the file://
// GitHub fixture (tests/testthat/fixtures, through githubFixtureDir()), so
// nothing touches the network.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { startServer, tempNotebook, artifactsDir, githubFixtureDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook } from "../browser.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const FIXTURES = path.join(HERE, "..", "..", "testthat", "fixtures");
const REPOS = {
  cran: `file://${path.join(FIXTURES, "repos", "toy")}`,
  github: `file://${githubFixtureDir()}`,
  bioc_config: null,
};

test("packages tab: add a GitHub source to a not-found package, fix a typo, remove it", async (t) => {
  const notebook = tempNotebook("github-add.R");
  const server = await startServer([notebook], {
    repos: REPOS,
    logFile: path.join(artifactsDir(), "github-source-add.server.log"),
  });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.getByRole("button", { name: "Packages", exact: true }).click();

  const row = page.locator("tr.ember-package-row", { hasText: "toyC" });
  const detail = page.locator("tr.ember-package-row:has-text('toyC') + tr.ember-package-detail");
  await page.locator("tr.ember-package-row.ember-package-not_found", { hasText: "toyC" }).waitFor({ timeout: 30000 });

  // A refusal stays in the form, under the field.
  await detail.getByRole("button", { name: "Add a source" }).click();
  const input = detail.getByLabel("Source for toyC");
  // The form focuses its field in an effect, after the click's render.
  await input.evaluate((el) => new Promise((resolve) => {
    const check = () => (el === document.activeElement ? resolve() : requestAnimationFrame(check));
    check();
  }));
  await input.fill("https://github.com/lab/toyC/blob/main/README.md");
  await detail.getByRole("button", { name: "Add", exact: true }).click();
  await detail.getByRole("alert").waitFor({ timeout: 10000 });
  assert.match(await detail.getByRole("alert").innerText(), /github:user\/repo/);

  // A repository that isn't there: the row stays, saying why, with the
  // source to change.
  await input.fill("lab/nope");
  await detail.getByRole("button", { name: "Add", exact: true }).click();
  await page.locator("tr.ember-package-row.ember-package-source_failed", { hasText: "toyC" }).waitFor({ timeout: 30000 });
  const reason = await detail.locator(".ember-package-source-failed").innerText();
  assert.match(reason, /^couldn't look up github:lab\/nope for toyC: could not find github:lab\/nope@HEAD on GitHub/);
  assert.doesNotMatch(reason, /Execution halted/);
  assert.match(readFileSync(notebook, "utf8"), /# toyC = "github:lab\/nope"/);

  // Fixed: the form starts from the current source.
  await detail.getByRole("button", { name: "Change source" }).click();
  assert.equal(await input.inputValue(), "lab/nope");
  await input.fill("https://github.com/lab/toyC");
  await input.press("Enter");
  await row.locator(".ember-package-source").waitFor({ timeout: 30000 });
  assert.equal(await row.locator(".ember-package-source").innerText(), "GitHub lab/toyC@8e4b7d2");
  assert.match(await row.locator("td").nth(1).innerText(), /^0\.4\.0/);
  assert.equal(await detail.locator(".ember-package-source-failed").count(), 0);
  const text = readFileSync(notebook, "utf8");
  assert.match(text, /# toyC = "github:lab\/toyC"/);
  assert.match(text, /# toyC 0\.4\.0 github:lab\/toyC@8e4b7d2c1f0a9b8c7d6e5f4a3b2c1d0e9f8a7b6c/);

  await detail.getByRole("button", { name: "Remove source" }).click();
  await page.locator("tr.ember-package-row.ember-package-not_found", { hasText: "toyC" }).waitFor({ timeout: 30000 });
  assert.doesNotMatch(readFileSync(notebook, "utf8"), /\[sources\]/);

  assertNoProblems(page);
});
