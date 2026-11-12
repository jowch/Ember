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
  // The first read of the stylesheet fails: the next output that needs it tries again.
  let failOnce = true;
  await page.exposeFunction("__host_read_dep", async (p) => {
    asked.push(p);
    if (failOnce && p.endsWith(".css")) { failOnce = false; throw new Error("not now"); }
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
  assert.match(await page.locator("#marker-2").evaluate((el) => getComputedStyle(el).backgroundImage), /^url\("data:image\/svg\+xml;base64,/, "the image next to the stylesheet comes as a data: URL");
  assert.equal(await page.locator(`${cellSelector("WIDGET2")} link[rel~='stylesheet']`).count(), 0, "no stylesheet link is left to load");
  assert.deepEqual(asked.slice().sort(), [
    "deps/emberhostdep-1.0.0/img/dot.svg",
    "deps/emberhostdep-1.0.0/widget.css",
    "deps/emberhostdep-1.0.0/widget.css",
    "deps/emberhostdep-1.0.0/widget.js",
  ], "each file is read once, and the stylesheet again after its read failed");
  assert.equal(blocked.length, 0, `nothing went to /deps/: ${JSON.stringify(blocked)}`);

  // The failed read is logged as a warning, which is all it should do.
  assertNoProblems(page);
  await page.close();
});
