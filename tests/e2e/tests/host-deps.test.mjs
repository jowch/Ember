// A page that can't reach Ember's server (a host's sandboxed frame, like the
// notebook view in Claude's desktop app) gets a widget's files from the host
// through window.ember_dep_file (common/HostDeps.js). Here the browser can't
// load /deps/ at all, and the host's hook reads the files instead.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, runCell, cellSelector } from "../browser.mjs";

// Installing htmltools into the notebook's own library needs CRAN's index
// (network), as export.test.mjs's widget test does.
test("a widget's files come from the host's ember_dep_file, once each", {
  skip: !process.env.EMBER_E2E_INSTALLS && "set EMBER_E2E_INSTALLS=1 (needs network to resolve the lock)",
}, async (t) => {
  const notebook = tempNotebook("host-deps.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "host-deps.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  // The browser itself can't reach the files, as in the sandboxed frame.
  const blocked = [];
  await page.route(/\/deps\//, (route) => { blocked.push(route.request().url()); return route.abort(); });
  // The host reads them its own way (the view's tool) and hands them over.
  const asked = [];
  await page.exposeFunction("__host_read_dep", async (p) => {
    asked.push(p);
    const res = await fetch(`${server.origin}${p}?secret=${server.secret}`);
    assert.equal(res.status, 200, p);
    return { mime: res.headers.get("content-type") || "", data: Buffer.from(await res.arrayBuffer()).toString("base64") };
  });
  await page.addInitScript(() => { window.ember_dep_file = (p) => window.__host_read_dep(p); });

  await openNotebook(page, server.origin, server.secret, notebook);
  await page.locator("#ember-safe-preview button").click();
  for (const id of ["DEP", "WIDGET", "WIDGET2"]) await runCell(page, id);
  await page.waitForFunction(() => [...document.querySelectorAll(".host-marker")].length === 2 && [...document.querySelectorAll(".host-marker")].every((el) => el.textContent === "widget-ran"));

  assert.equal(await page.evaluate(() => window.__host_dep_runs), 1, "the library loads once, and both outputs use it");
  assert.equal(await page.locator("#marker-2").evaluate((el) => getComputedStyle(el).color), "rgb(1, 2, 3)", "the stylesheet applies, as a <style>");
  assert.equal(await page.locator(`${cellSelector("WIDGET")} link[rel~='stylesheet']`).count(), 0, "no stylesheet link is left to load");
  assert.deepEqual([...new Set(asked)].sort(), asked.slice().sort(), "each file is read from the host once");
  assert.equal(asked.length, 2, `the script and the stylesheet: ${JSON.stringify(asked)}`);
  assert.equal(blocked.length, 0, `nothing went to /deps/: ${JSON.stringify(blocked)}`);

  assertNoProblems(page);
  await page.close();
});
