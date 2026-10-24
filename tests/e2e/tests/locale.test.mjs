// #560: a language tag Intl.Locale can't read ("en-US@posix", what
// Playwright's headless shell reports under LANG=C.UTF-8) left every page
// blank: lang.js's getLanguage() threw on it during the first render. The
// tag here comes from localStorage, which getCurrentLanguage() reads first,
// so the test doesn't depend on which browser runs it.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook } from "../browser.mjs";

test("a language tag Intl.Locale rejects falls back to English: the start page and a notebook draw (#560)", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "locale.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await page.addInitScript(() => localStorage.setItem("i18nextLng", "en-US@posix"));

  await page.goto(`${server.origin}?secret=${server.secret}`);
  await page.waitForSelector("text=New notebook");

  await openNotebook(page, server.origin, server.secret, notebook);
  assert.match(await page.locator("pluto-editor").innerText(), /Run this notebook/);
  assert.equal(await page.evaluate(async () => (await import("./common/lang.js")).getLanguage(["en-US@posix"])), "en");
  assertNoProblems(page);
});
