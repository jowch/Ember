// A package from the header's [sources]: the Packages tab says where it
// comes from under its version, since the snapshot date doesn't speak for
// it. The lock already answers the code, so opening needs no network.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook } from "../browser.mjs";

test("packages tab: a GitHub package shows its repository and commit under its version", async (t) => {
  const notebook = tempNotebook("github.R");
  const server = await startServer([notebook], {
    logFile: path.join(artifactsDir(), "github-source.server.log"),
  });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.getByRole("button", { name: "Packages", exact: true }).click();
  const row = page.locator("tr.ember-package-row", { hasText: "toyC" });
  await row.waitFor({ timeout: 30000 });
  const label = row.locator(".ember-package-source");
  assert.equal(await label.innerText(), "GitHub lab/toyC@8e4b7d2");
  const title = await label.getAttribute("title");
  assert.ok(title.startsWith("github:lab/toyC@8e4b7d2c1f0a9b8c7d6e5f4a3b2c1d0e9f8a7b6c\nUnchecked:"), title);
  assert.match(await row.locator("td").nth(1).innerText(), /^0\.4\.0/);

  assertNoProblems(page);
});
