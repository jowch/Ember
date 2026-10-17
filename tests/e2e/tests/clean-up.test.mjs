// #128: the Packages tab's "Clean up…" button. It first shows what it
// would delete (libraries no open notebook uses and unused for 30 days, and
// the package cache entries only they list) with Delete and Cancel, and
// deletes nothing until Delete.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { mkdtempSync, existsSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook } from "../browser.mjs";

/** A cache folder holding one library last used 40 days ago, the one
 * cache entry its manifest lists, and one library used 10 days ago. */
function seedCache() {
  const root = mkdtempSync(path.join(tmpdir(), "ember-e2e-clean-up-"));
  const stale = path.join(root, "libraries", "R-4.6", "testplat", "stalekey");
  const recent = path.join(root, "libraries", "R-4.6", "testplat", "recentkey");
  const entry = path.join(root, "renv-cache", "v5", "os", "R-4.6", "triplet", "pkgStale", "1.0", "hashpkgStale");
  const expr = `
    lib <- function(path, days, entries) {
      dir.create(path, recursive = TRUE)
      saveRDS(list(lock_lines = character(), r = list(version = "4.6.0", minor = "4.6", platform = "testplat"),
                   installed = character(), exports = list(), cache_entries = entries, created = Sys.time()),
              file.path(path, "ember-library.rds"))
      marker <- file.path(path, "ember-last-used")
      file.create(marker)
      Sys.setFileTime(marker, Sys.time() - days * 86400)
    }
    dir.create(file.path(${JSON.stringify(entry)}, "pkgStale"), recursive = TRUE)
    writeBin(raw(100000), file.path(${JSON.stringify(entry)}, "pkgStale", "R.rdb"))
    Sys.setFileTime(${JSON.stringify(entry)}, Sys.time() - 7 * 86400)
    lib(${JSON.stringify(stale)}, 40, ${JSON.stringify(entry)})
    lib(${JSON.stringify(recent)}, 10, character())`;
  const res = spawnSync(process.env.EMBER_RSCRIPT ?? "Rscript", ["--vanilla", "-e", expr], { encoding: "utf8" });
  assert.equal(res.status, 0, res.stderr);
  return { root, stale, recent, entry };
}

async function openPackagesTab(t, cache, name) {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { cacheDir: cache.root, logFile: path.join(artifactsDir(), `${name}.server.log`) });
  const browser = await launchBrowser();
  t.after(async () => {
    await browser.close();
    await server.stop();
    rmSync(cache.root, { recursive: true, force: true });
  });
  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.getByRole("button", { name: "Packages", exact: true }).click();
  return page;
}

test("packages tab: Clean up… shows what it would delete, and Delete deletes it (#128)", async (t) => {
  const cache = seedCache();
  const page = await openPackagesTab(t, cache, "clean-up");

  await page.getByRole("button", { name: "Clean up…", exact: true }).click();
  const question = page.locator("#ember-packages-tab .ember-packages-clean-up-question");
  await question.waitFor({ timeout: 60000 });
  assert.match(await question.innerText(),
    /^Delete 1 library not used by an open notebook or in the last 30 days, and 1 package cache entry no other library uses\? This frees about [\d.,]+ [KMGT]?B\./);
  // The preview deleted nothing.
  assert.ok(existsSync(cache.stale) && existsSync(cache.entry) && existsSync(cache.recent));

  await question.getByRole("button", { name: "Delete", exact: true }).click();
  const done = page.locator("#ember-packages-tab .ember-packages-disk p", { hasText: /^Deleted / });
  await done.waitFor({ timeout: 60000 });
  assert.match(await done.innerText(), /^Deleted 1 library and 1 package cache entry, about [\d.,]+ [KMGT]?B\.$/);
  assert.ok(!existsSync(cache.stale), "the stale library is deleted");
  assert.ok(!existsSync(cache.entry), "the cache entry only it listed is deleted");
  assert.ok(existsSync(cache.recent), "a library used in the last 30 days is kept");
  // The button comes back for another go.
  await page.getByRole("button", { name: "Clean up…", exact: true }).waitFor();

  assertNoProblems(page);
});

test("packages tab: Cancel on the clean-up question deletes nothing (#128)", async (t) => {
  const cache = seedCache();
  const page = await openPackagesTab(t, cache, "clean-up-cancel");

  await page.getByRole("button", { name: "Clean up…", exact: true }).click();
  const question = page.locator("#ember-packages-tab .ember-packages-clean-up-question");
  await question.waitFor({ timeout: 60000 });
  await question.getByRole("button", { name: "Cancel", exact: true }).click();
  await page.getByRole("button", { name: "Clean up…", exact: true }).waitFor();
  assert.ok(existsSync(cache.stale) && existsSync(cache.entry) && existsSync(cache.recent));

  assertNoProblems(page);
});
