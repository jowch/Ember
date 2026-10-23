// #37: an install whose Bioconductor data packages add up to more than
// `ember.ask_above` stops before downloading anything, opens the Packages
// tab on a card with the size, and installs once Install is clicked. The
// fixture Bioconductor repositories are copied with a 2 kB GO.db tarball,
// and the fake installer stands in for renv.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { cpSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, runCell, cellSelector } from "../browser.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(HERE, "..", "..", "..");
const FIXTURES = path.join(HERE, "..", "..", "testthat", "fixtures");

test("large-download.R: the install asks first, and Install installs it", async (t) => {
  const bioc = mkdtempSync(path.join(tmpdir(), "ember-e2e-bioc-"));
  cpSync(path.join(FIXTURES, "bioc"), bioc, { recursive: true });
  writeFileSync(path.join(bioc, "2026-09-01", "packages", "3.23", "data", "annotation", "src", "contrib", "GO.db_3.22.0.tar.gz"), Buffer.alloc(2048));

  const notebook = tempNotebook("large-download.R");
  const server = await startServer([notebook], {
    repos: {
      cran: `file://${path.join(FIXTURES, "repos", "cran")}`,
      bioc: `file://${bioc}`,
      bioc_config: `file://${path.join(FIXTURES, "bioc-config", "config.yaml")}`,
    },
    installerScript: path.join(ROOT, "inst", "fake-installer.R"),
    askAbove: 1000,
    logFile: path.join(artifactsDir(), "install-large-download.server.log"),
  });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await runCell(page, "S");

  // The Packages tab opens by itself on the question.
  const card = page.locator(".ember-install-ask-card");
  await card.waitFor({ timeout: 60000 });
  assert.match(await card.innerText(), /This install downloads 2 kB/);
  assert.match(await card.innerText(), /GO\.db \(2 kB\)/);
  assert.equal(await page.locator(`${cellSelector("S")}.errored`).count(), 0);

  await card.getByRole("button", { name: "Install" }).click();
  await card.waitFor({ state: "detached", timeout: 60000 });
  await page.locator(".ember-packages-library-ready").waitFor({ timeout: 60000 });

  assertNoProblems(page);
});
