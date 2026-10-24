// Scenario 49 (docs/ui-tests.md): when one of the editor's own files fails
// to load, the page reloads once on its own; if the file fails again, it
// says so and offers a reload, instead of a blank page under the loading
// bar (#578). The failures are made with page.route, so these pages don't
// use newPage()'s console checks: the failed loads are the point.

import { test } from "node:test";
import path from "node:path";
import assert from "node:assert/strict";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser } from "../browser.mjs";

const openUrl = (server, notebook) =>
  `${server.origin}open?path=${encodeURIComponent(notebook)}&secret=${server.secret}`;

// Fails the first `times` requests for `file`, then lets them through.
async function failing(page, file, times) {
  let failed = 0;
  await page.route(`**/${file}*`, (r) => (failed++ < times ? r.abort("failed") : r.continue()));
  return () => failed;
}

const editorLoaded = (page) => page.waitForFunction(() => {
  const ed = document.querySelector("pluto-editor");
  return ed && !ed.classList.contains("loading") && document.querySelector("pluto-cell");
});

test("load failed: a script that fails once is retried by one reload, with no message (#578)", async (t) => {
  const notebook = tempNotebook();
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "load-failed-once.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await (await browser.newContext()).newPage();
  const failed = await failing(page, "common/SliderServerClient.js", 1);
  await page.goto(openUrl(server, notebook));
  await editorLoaded(page);
  assert.equal(failed(), 2, "the file failed once, then loaded after the reload");
  assert.equal(await page.locator("#ember-load-failed").count(), 0);
  assert.equal(await page.evaluate(() => sessionStorage.getItem("ember_reloaded_after_failed_load")), null,
               "a load that worked clears the reload mark");
});

test("load failed: a script that keeps failing says so, and Reload loads the editor once it can (#578)", async (t) => {
  const notebook = tempNotebook();
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "load-failed-script.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await (await browser.newContext()).newPage();
  await failing(page, "common/SliderServerClient.js", Infinity);
  await page.goto(openUrl(server, notebook));
  const bar = page.locator("#ember-load-failed");
  await bar.waitFor();
  assert.match(await bar.innerText(), /couldn't load the editor's code.*Reload the page to try again/s);
  assert.equal(await bar.getAttribute("role"), "alert");

  await page.unroute("**/common/SliderServerClient.js*");
  await bar.getByRole("button", { name: "Reload" }).click();
  await editorLoaded(page);
  assert.equal(await bar.count(), 0);
});

test("load failed: a stylesheet @import that keeps failing says so (#578)", async (t) => {
  const notebook = tempNotebook();
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "load-failed-css.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await (await browser.newContext()).newPage();
  await failing(page, "editor.css", Infinity);
  await page.goto(openUrl(server, notebook));
  const bar = page.locator("#ember-load-failed");
  await bar.waitFor();
  assert.match(await bar.innerText(), /couldn't load the page's styles/);
});
