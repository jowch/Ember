// Piece 5 ("Identity and layout"), docs/ui-3-plan.md's "Theme switching".
// docs/ui-3-tests.md 115.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook } from "../browser.mjs";

// 115. System dark mode by default; an explicit THEME setting wins over
// the system; changing the system while the setting is "system" switches
// live, with no reload.
test("theme: system default, an explicit setting wins, live system switch (115)", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "theme-115.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await page.emulateMedia({ colorScheme: "dark" });
  await openNotebook(page, server.origin, server.secret, notebook);

  assert.equal(await page.evaluate(() => document.documentElement.getAttribute("data-theme")), "dark");
  assert.equal(
    await page.evaluate(() => getComputedStyle(document.body).backgroundColor),
    "rgb(21, 25, 23)"
  );

  await page.evaluate(() => localStorage.setItem("pluto_setting_THEME", JSON.stringify("light")));
  await page.reload();
  await page.waitForSelector("pluto-cell", { timeout: 30000 });

  assert.equal(await page.evaluate(() => document.documentElement.getAttribute("data-theme")), "light");
  assert.equal(
    await page.evaluate(() => getComputedStyle(document.body).backgroundColor),
    "rgb(245, 246, 243)"
  );

  await page.evaluate(() => localStorage.removeItem("pluto_setting_THEME"));
  await page.reload();
  await page.waitForSelector("pluto-cell", { timeout: 30000 });
  assert.equal(await page.evaluate(() => document.documentElement.getAttribute("data-theme")), "dark");

  await page.emulateMedia({ colorScheme: "light" });
  await page.waitForFunction(() => document.documentElement.getAttribute("data-theme") === "light", null, { timeout: 5000 });

  assertNoProblems(page);
});
